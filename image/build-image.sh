#!/usr/bin/env bash
# -----------------------------------------------------------------------------------------------
# Build a Raspberry Pi OS image with ConsolePi pre-installed.
#
# Takes the official Raspberry Pi OS Lite (arm64) image, installs ConsolePi into it via chroot
# using the regular installer in silent mode and writes a compressed .img.xz.
#
# Runs as root on an arm64 Linux host (e.g. GitHub runner ubuntu-24.04-arm).  On x86 it also
# works if qemu-user-static + binfmt are installed, just a lot slower.
#
# The resulting image boots on every Pi that runs 64 bit Raspberry Pi OS:
#   Pi Zero 2 W, Pi 3B/3B+, Pi 4, Pi 400, Pi 5, CM3/CM4
#
# Settings (environment variables, all optional):
#   BASE_IMAGE_URL   Raspberry Pi OS Lite arm64 image (.img.xz)   default: latest bookworm
#   CONSOLEPI_REPO   GitHub repo owner/name to install from       default: StofflHD/ConsolePi
#   CONSOLEPI_BRANCH branch to install                            default: master
#   IMG_HOSTNAME     hostname                                     default: consolepi
#   WLAN_COUNTRY     WiFi regulatory domain                       default: DE
#   TIMEZONE         timezone                                     default: Europe/Berlin
#   HOTSPOT_SSID     SSID of the fallback hotspot                 default: ConsolePi
#   HOTSPOT_PSK      PSK of the fallback hotspot (8-63 chars)     default: ConsolePiR0cks!!
#   OUT_DIR          output directory                             default: ./out
#   WORK_DIR         work directory (needs ~6 GB)                 default: ./work
# -----------------------------------------------------------------------------------------------
set -euo pipefail

BASE_IMAGE_URL="${BASE_IMAGE_URL:-https://downloads.raspberrypi.com/raspios_oldstable_lite_arm64_latest}"
CONSOLEPI_REPO="${CONSOLEPI_REPO:-StofflHD/ConsolePi}"
CONSOLEPI_BRANCH="${CONSOLEPI_BRANCH:-master}"
IMG_HOSTNAME="${IMG_HOSTNAME:-consolepi}"
WLAN_COUNTRY="${WLAN_COUNTRY:-DE}"
TIMEZONE="${TIMEZONE:-Europe/Berlin}"
HOTSPOT_SSID="${HOTSPOT_SSID:-ConsolePi}"
HOTSPOT_PSK="${HOTSPOT_PSK:-ConsolePiR0cks!!}"
OUT_DIR="$(realpath -m "${OUT_DIR:-./out}")"
WORK_DIR="$(realpath -m "${WORK_DIR:-./work}")"
EXTRA_MB=2048   # space added to the root fs for ConsolePi (venv, deps).  RPi OS grows the fs to the card on first boot.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
MNT="$WORK_DIR/mnt"
LOOP=""

log() { echo -e "\n\e[96m==> $*\e[0m"; }
die() { echo -e "\n\e[31mERROR: $*\e[0m" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ ${#HOTSPOT_PSK} -ge 8 ] && [ ${#HOTSPOT_PSK} -le 63 ] || die "HOTSPOT_PSK must be 8-63 characters"
[[ "$IMG_HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || die "invalid IMG_HOSTNAME"
for bin in curl xz parted losetup e2fsck resize2fs zerofree sha256sum chroot; do
    command -v $bin >/dev/null || die "missing tool: $bin"
done
if [ "$(uname -m)" != "aarch64" ] && [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    die "not an arm64 host and qemu-aarch64 binfmt is not registered (install qemu-user-static)"
fi

cleanup() {
    set +e
    if [ -n "$LOOP" ]; then
        for m in dev/pts dev proc sys run boot/firmware ""; do
            mountpoint -q "$MNT/$m" && umount -l "$MNT/$m"
        done
        losetup -d "$LOOP"
    fi
}
trap cleanup EXIT

mkdir -p "$WORK_DIR" "$OUT_DIR" "$MNT"
cd "$WORK_DIR"

# -- download + verify base image ----------------------------------------------------------------
log "Downloading base image $BASE_IMAGE_URL"
real_url=$(curl -sSLf -o base.img.xz -w '%{url_effective}' "$BASE_IMAGE_URL")
echo "resolved: $real_url"
curl -sSLf -o base.img.xz.sha256 "${real_url}.sha256"
expected=$(awk '{print $1}' base.img.xz.sha256)
echo "$expected  base.img.xz" | sha256sum -c - || die "checksum mismatch for base image"
base_name=$(basename "$real_url" .img.xz)          # e.g. 2026-10-06-raspios-bookworm-arm64-lite

log "Extracting"
rm -f base.img
xz -dk -T0 base.img.xz

# -- grow root partition -------------------------------------------------------------------------
log "Growing root partition by ${EXTRA_MB} MB"
truncate -s +${EXTRA_MB}M base.img
parted -s base.img resizepart 2 100%
LOOP=$(losetup -Pf --show base.img)
e2fsck -fy "${LOOP}p2" || [ $? -le 1 ]
resize2fs "${LOOP}p2"

# -- mount + prepare chroot ----------------------------------------------------------------------
log "Mounting image"
mount "${LOOP}p2" "$MNT"
mount "${LOOP}p1" "$MNT/boot/firmware"
mount -t proc proc "$MNT/proc"
mount -t sysfs sys "$MNT/sys"
mount --bind /dev "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"
mount -t tmpfs tmpfs "$MNT/run"

# keep apt from starting services inside the chroot
printf '#!/bin/sh\nexit 101\n' > "$MNT/usr/sbin/policy-rc.d"
chmod +x "$MNT/usr/sbin/policy-rc.d"

# DNS for the chroot
resolv_backup=""
if [ -e "$MNT/etc/resolv.conf" ] || [ -L "$MNT/etc/resolv.conf" ]; then
    resolv_backup="$MNT/etc/resolv.conf.consolepi-build"
    mv "$MNT/etc/resolv.conf" "$resolv_backup"
fi
cp -L /etc/resolv.conf "$MNT/etc/resolv.conf"

# -- stage installer + config --------------------------------------------------------------------
log "Staging installer and config"
mkdir -p "$MNT/tmp/consolepi-installer" "$MNT/root/consolepi-stage"
cp "$REPO_DIR/installer/install.sh" "$REPO_DIR/installer/common.sh" "$MNT/tmp/consolepi-installer/"

yq() { local v="$1"; printf "'%s'" "${v//\'/\'\'}"; }   # single quoted YAML scalar
cfg_ver=$(awk '/^CFG_FILE_VER:/ {print $2}' "$REPO_DIR/.static.yaml")
cat > "$MNT/root/consolepi-stage/ConsolePi.yaml" <<EOF
%YAML 1.2
---
CONFIG:
  cfg_file_ver: ${cfg_ver}
  push: false
  push_all: false
  push_api_key: ""
  push_iden: ""
  ovpn_enable: false
  vpn_check_ip: 10.0.150.1
  net_check_ip: 8.8.4.4
  local_domain: local
  hotspot: true
  wlan_ip: 10.110.0.1
  wlan_ssid: $(yq "$HOTSPOT_SSID")
  wlan_psk: $(yq "$HOTSPOT_PSK")
  wlan_country: ${WLAN_COUNTRY}
  wired_dhcp: false
  wired_ip: 10.30.110.1
  cloud: false
  cloud_svc: gdrive
  rem_user: consolepi
  power: false
  debug: false
EOF

# The consolepi user gets a random password and is locked afterwards.  Logins happen with the
# user configured in Raspberry Pi Imager (it renames the image's default user, uid 1000, which
# we add to the consolepi groups below).
consolepi_pass=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)

# -- run installer -------------------------------------------------------------------------------
log "Running ConsolePi installer (silent) from ${CONSOLEPI_REPO}@${CONSOLEPI_BRANCH}"
set +e
chroot "$MNT" /usr/bin/env -i \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    HOME=/root TERM=dumb LANG=C.UTF-8 SUDO_USER=root DEBIAN_FRONTEND=noninteractive \
    CONSOLEPI_REPO="$CONSOLEPI_REPO" CONSOLEPI_FORCE_NM=true \
    /bin/bash /tmp/consolepi-installer/install.sh --silent --no-users \
        -b "$CONSOLEPI_BRANCH" -p "$consolepi_pass" -H "$IMG_HOSTNAME" --tz "$TIMEZONE" -w "$WLAN_COUNTRY"
rc=$?
set -e
unset consolepi_pass
cp "$MNT/var/log/ConsolePi/install.log" "$OUT_DIR/install.log" 2>/dev/null || cp "$MNT/tmp/consolepi_install.log" "$OUT_DIR/install.log" 2>/dev/null || true
[ $rc -eq 0 ] || die "installer failed (rc=$rc), see install.log"
[ -x "$MNT/etc/ConsolePi/venv/bin/python3" ] || die "installer finished but ConsolePi venv is missing"

# -- image specific adjustments ------------------------------------------------------------------
log "Finalizing image"
chroot "$MNT" /bin/bash -euo pipefail <<EOF
# hostname (hostnamectl doesn't work in a chroot)
echo "$IMG_HOSTNAME" > /etc/hostname
grep -q "127.0.1.1" /etc/hosts && sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$IMG_HOSTNAME/" /etc/hosts || echo -e "127.0.1.1\t$IMG_HOSTNAME" >> /etc/hosts

# lock consolepi user (no password login), keep it for services/remote access via ssh keys
passwd -l consolepi

# default user (uid 1000, renamed by Raspberry Pi Imager on first boot) gets ConsolePi rights
first_user=\$(getent passwd 1000 | cut -d: -f1 || true)
if [ -n "\$first_user" ]; then
    for g in consolepi dialout adm sudo plugdev netdev gpio; do
        getent group \$g >/dev/null && usermod -aG \$g "\$first_user"
    done
fi

# SSH on, host keys are regenerated on first boot
systemctl enable ssh
rm -f /etc/ssh/ssh_host_*
systemctl enable regenerate_ssh_host_keys 2>/dev/null || true

# diagnostics for the build log
echo "--- first boot related units:"; systemctl list-unit-files | grep -Ei 'regenerate|userconf|ssh|NetworkManager|consolepi|ser2net|rfcomm' || true
echo "--- consolepi user groups for \$first_user:"; id "\$first_user" || true

# cleanup
apt-get clean
rm -rf /var/lib/apt/lists/* /root/.cache /tmp/* /var/tmp/*
rm -f /root/.bash_history
EOF

# build info
cat > "$MNT/etc/consolepi-image" <<EOF
base_image=${base_name}
repo=${CONSOLEPI_REPO}
branch=${CONSOLEPI_BRANCH}
commit=$(git -C "$MNT/etc/ConsolePi" rev-parse --short HEAD 2>/dev/null || echo unknown)
built=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
cp "$MNT/etc/consolepi-image" "$OUT_DIR/build-info.txt"
cat "$OUT_DIR/build-info.txt"

# -- undo chroot prep ----------------------------------------------------------------------------
rm -f "$MNT/usr/sbin/policy-rc.d" "$MNT/etc/resolv.conf"
[ -n "$resolv_backup" ] && mv "$resolv_backup" "$MNT/etc/resolv.conf"

log "Unmounting"
for m in dev/pts dev proc sys run boot/firmware ""; do
    umount "$MNT/$m"
done
e2fsck -fy "${LOOP}p2" || [ $? -le 1 ]
zerofree "${LOOP}p2"                  # zero unused blocks so the image compresses well
losetup -d "$LOOP"; LOOP=""

# -- compress ------------------------------------------------------------------------------------
out_name="consolepi-${base_name#*-raspios-}-$(date -u +%Y%m%d)"
log "Compressing to $OUT_DIR/${out_name}.img.xz"
mv base.img "${out_name}.img"
xz -T0 -6 -c "${out_name}.img" > "$OUT_DIR/${out_name}.img.xz"
rm -f "${out_name}.img"
(cd "$OUT_DIR" && sha256sum "${out_name}.img.xz" > "${out_name}.img.xz.sha256")
ls -lh "$OUT_DIR"
log "Done"
