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
#   BASE_IMAGE_URL   Raspberry Pi OS Lite arm64 image (.img.xz)   default: latest trixie
#   CONSOLEPI_REPO   GitHub repo owner/name to install from       default: StofflHD/ConsolePi
#   CONSOLEPI_BRANCH branch to install                            default: master
#   IMG_HOSTNAME     hostname                                     default: consolepi
#   WLAN_COUNTRY     WiFi regulatory domain                       default: DE
#   TIMEZONE         timezone                                     default: Europe/Berlin
#   HOTSPOT_SSID     SSID of the fallback hotspot                 default: ConsolePi
#   HOTSPOT_PSK      PSK of the fallback hotspot (8-63 chars)     default: ConsolePiR0cks!!
#   IMG_VERSION      version in file name + /etc/consolepi-image  default: dev-YYYYMMDD
#   OUT_DIR          output directory                             default: ./out
#   WORK_DIR         work directory (needs ~6 GB)                 default: ./work
# -----------------------------------------------------------------------------------------------
set -euo pipefail

BASE_IMAGE_URL="${BASE_IMAGE_URL:-https://downloads.raspberrypi.com/raspios_lite_arm64_latest}"
CONSOLEPI_REPO="${CONSOLEPI_REPO:-StofflHD/ConsolePi}"
CONSOLEPI_BRANCH="${CONSOLEPI_BRANCH:-master}"
IMG_HOSTNAME="${IMG_HOSTNAME:-consolepi}"
WLAN_COUNTRY="${WLAN_COUNTRY:-DE}"
TIMEZONE="${TIMEZONE:-Europe/Berlin}"
HOTSPOT_SSID="${HOTSPOT_SSID:-ConsolePi}"
HOTSPOT_PSK="${HOTSPOT_PSK:-ConsolePiR0cks!!}"
IMG_VERSION="${IMG_VERSION:-dev-$(date -u +%Y%m%d)}"
OUT_DIR="$(realpath -m "${OUT_DIR:-./out}")"
WORK_DIR="$(realpath -m "${WORK_DIR:-./work}")"
TTYD_VERSION=1.7.7
TTYD_SHA256=b38acadd89d1d396a0f5649aa52c539edbad07f4bc7348b27b4f4b7219dd4165   # ttyd.aarch64 from the release's SHA256SUMS
EXTRA_MB=2048  # space added to the root fs for ConsolePi (venv, deps).  RPi OS grows the fs to the card on first boot.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
MNT="$WORK_DIR/mnt"
LOOP=""

log() { echo -e "\n\e[96m==> $*\e[0m"; }
die() { echo -e "\n\e[31mERROR: $*\e[0m" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ ${#HOTSPOT_PSK} -ge 8 ] && [ ${#HOTSPOT_PSK} -le 63 ] || die "HOTSPOT_PSK must be 8-63 characters"
[[ "$IMG_VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid IMG_VERSION (letters, digits, . _ -)"
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
        -b "$CONSOLEPI_BRANCH" -p "$consolepi_pass" -H "$IMG_HOSTNAME" --tz "$TIMEZONE" -w "$WLAN_COUNTRY" \
    2>&1 | tee "$WORK_DIR/installer-output.log"
set -e
unset consolepi_pass
cp "$MNT/var/log/ConsolePi/install.log" "$OUT_DIR/install.log" 2>/dev/null || cp "$MNT/tmp/consolepi_install.log" "$OUT_DIR/install.log" 2>/dev/null || true
# the installer's exit code isn't meaningful (its last statement is `$silent && $do_reboot && ...`), check its result instead
grep -q "Silent Install Complete" "$WORK_DIR/installer-output.log" || die "installer did not complete, see install.log"
[ -x "$MNT/etc/ConsolePi/venv/bin/python3" ] || die "installer finished but ConsolePi venv is missing"

# -- first boot setup (consolepi-setup.txt on the boot partition) --------------------------------
log "Installing first boot setup"
install -m 0755 "$SCRIPT_DIR/rootfs/usr/local/sbin/consolepi-setup" "$MNT/usr/local/sbin/consolepi-setup"
install -m 0644 "$SCRIPT_DIR/rootfs/etc/systemd/system/consolepi-setup.service" "$MNT/etc/systemd/system/consolepi-setup.service"
# CRLF so it opens fine in Windows notepad right after flashing
sed 's/\r$//; s/$/\r/' "$SCRIPT_DIR/rootfs/boot/firmware/consolepi-setup.txt" > "$MNT/boot/firmware/consolepi-setup.txt"
chroot "$MNT" systemctl enable consolepi-setup.service

# -- web terminal (ttyd -> login -> consolepi-menu, https://<pi>/) --------------------------------
# ttyd isn't packaged for bookworm/trixie: official static build, pinned + checksum verified
log "Installing web terminal (ttyd ${TTYD_VERSION})"
curl -sSLf -o "$WORK_DIR/ttyd" "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.aarch64"
echo "${TTYD_SHA256}  $WORK_DIR/ttyd" | sha256sum -c - || die "checksum mismatch for ttyd"
install -m 0755 "$WORK_DIR/ttyd" "$MNT/usr/local/bin/ttyd"
install -m 0755 "$SCRIPT_DIR/rootfs/usr/local/sbin/consolepi-web-cert" "$SCRIPT_DIR/rootfs/usr/local/sbin/consolepi-web-login" \
    "$SCRIPT_DIR/rootfs/usr/local/sbin/consolepi-web-start" "$MNT/usr/local/sbin/"
install -m 0644 "$SCRIPT_DIR/rootfs/etc/systemd/system/consolepi-web.service" "$MNT/etc/systemd/system/"
install -m 0644 "$SCRIPT_DIR/rootfs/etc/profile.d/zz-consolepi-web.sh" "$MNT/etc/profile.d/"
chroot "$MNT" systemctl enable consolepi-web.service
chroot "$MNT" /bin/bash -euo pipefail <<'EOF'
/usr/local/bin/ttyd --version
T=$(mktemp -d)
CONSOLEPI_WEB_DIR=$T/web /usr/local/sbin/consolepi-web-cert
openssl x509 -in $T/web/cert.pem -noout -subject -ext subjectAltName
test "$(stat -c %a $T/web/key.pem)" = 600
rm -rf $T
test ! -e /etc/consolepi-web    # must be created on the Pi, never shipped in the image
bash -n /etc/profile.d/zz-consolepi-web.sh
# login loop (prompt comes back after exit) needs setsid with -c/-w and a login binary
sh -n /usr/local/sbin/consolepi-web-login
setsid --help | grep -q -- '--ctty' && setsid --help | grep -q -- '--wait'
test -x /bin/login
# ttyd options: theme must be valid JSON, font size 16 by default
sed '/^exec /,$d' /usr/local/sbin/consolepi-web-start > $T.sh
echo 'printf "%s" "$THEME" | python3 -c "import json,sys; json.load(sys.stdin)"; test "$FONT_SIZE" = 16' >> $T.sh
sh $T.sh && rm -f $T.sh
echo "web terminal OK"
EOF

# -- hotspot portal (port 80): phones joining the hotspot get a page linking to the web terminal --------
log "Installing hotspot portal"
install -m 0755 "$SCRIPT_DIR/rootfs/usr/local/sbin/consolepi-portal" "$MNT/usr/local/sbin/"
install -m 0644 "$SCRIPT_DIR/rootfs/etc/systemd/system/consolepi-portal.service" "$MNT/etc/systemd/system/"
chroot "$MNT" systemctl enable consolepi-portal.service
chroot "$MNT" /usr/local/sbin/consolepi-portal --write-dns-config
chroot "$MNT" /bin/bash -euo pipefail <<'EOF'
grep -q '^address=/captive.apple.com/10.110.0.1$' /etc/NetworkManager/dnsmasq-shared.d/consolepi-portal.conf
CONSOLEPI_PORTAL_PORT=8099 /usr/local/sbin/consolepi-portal & pid=$!
sleep 2
python3 - <<'PY'
import http.client
def get(host):
    c = http.client.HTTPConnection("127.0.0.1", 8099, timeout=5)
    c.request("GET", "/hotspot-detect.html", headers={"Host": host})
    r = c.getresponse()
    return r.status, r.getheader("Location"), r.read()
s, _, body = get("captive.apple.com")
assert s == 200 and b"Open web terminal" in body and b"https://127.0.0.1/" in body, (s, body[:200])
s, loc, _ = get("127.0.0.1")
assert s == 302 and loc == "https://127.0.0.1/", (s, loc)
PY
test "$(ps -o user= -p $pid)" = nobody
kill $pid
echo "portal OK"
EOF

# -- Bluetooth pairing agent (BlueZ rejects pairing without one; rfcomm.service comes from the installer)
log "Installing Bluetooth pairing agent"
chroot "$MNT" /bin/bash -euo pipefail <<'EOF'
export DEBIAN_FRONTEND=noninteractive
pkgs="python3-dbus python3-gi"
apt-get install -y -qq --no-install-recommends $pkgs || { apt-get update -qq && apt-get install -y -qq --no-install-recommends $pkgs; }
EOF
install -m 0755 "$SCRIPT_DIR/rootfs/usr/local/sbin/consolepi-bt-agent" "$MNT/usr/local/sbin/"
install -m 0644 "$SCRIPT_DIR/rootfs/etc/systemd/system/consolepi-bt-agent.service" "$MNT/etc/systemd/system/"
# Bluetooth user (auto-login, limited menu) may power the Pi off from the menu - nothing else
echo 'blue ALL=(root) NOPASSWD: /usr/bin/systemctl poweroff' > "$MNT/etc/sudoers.d/consolepi-blue-poweroff"
chmod 0440 "$MNT/etc/sudoers.d/consolepi-blue-poweroff"
chroot "$MNT" usermod -aG video blue    # vcgencmd fallback of consolepi-powercheck (under-voltage warning)
chroot "$MNT" systemctl enable consolepi-bt-agent.service
chroot "$MNT" /bin/bash -euo pipefail <<'EOF'
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' /usr/local/sbin/consolepi-bt-agent
python3 -c 'import dbus, dbus.service, dbus.mainloop.glib; from gi.repository import GLib'
test -L /etc/systemd/system/bluetooth.target.wants/consolepi-bt-agent.service
systemctl is-enabled rfcomm.service bluetooth.service
id blue
command -v btmgmt                    # PIN pairing switches Secure Simple Pairing off with it
command -v rfcomm sdptool hciconfig  # used by rfcomm.service / bluetooth.service (deprecated BlueZ tools)
visudo -cf /etc/sudoers.d/consolepi-blue-poweroff
sudo -l -U blue | grep -q '/usr/bin/systemctl poweroff'
bash -n /etc/ConsolePi/src/consolepi-menu.sh
grep -q 'shutdown_pi' /etc/ConsolePi/src/consolepi-menu.sh
echo "bluetooth agent OK"
EOF

# smoke test with the image's real nmcli/openssl against a scratch root (no wifi_country/hostname: they act on the live system)
log "Smoke test consolepi-setup"
chroot "$MNT" /bin/bash -euo pipefail <<'EOF'
T=/tmp/setup-smoke
mkdir -p $T/boot/firmware $T/etc/NetworkManager/system-connections $T/etc/ConsolePi $T/home/pi
mkdir -p $T/etc/systemd/system/multi-user.target.wants
touch $T/etc/systemd/system/multi-user.target.wants/userconfig.service   # = first boot
cp /etc/passwd $T/etc/passwd
# password with '!' and umlauts in a Windows-1252 file (what some Windows editors save)
printf 'user=smoke\r\npassword=!Sm\xf6ke-p\xe4ss\r\n' > $T/boot/firmware/consolepi-setup.txt
CONSOLEPI_SETUP_ROOT=$T /usr/local/sbin/consolepi-setup
h=$(cut -d: -f2 $T/boot/firmware/userconf.txt)
[ "$(printf '%s\n' '!Smöke-päss' | openssl passwd -6 -salt "$(echo "$h" | cut -d'$' -f3)" -stdin)" = "$h" ] || { echo "password hash mismatch"; exit 1; }
grep -q 'Windows-1252' $T/boot/firmware/consolepi-setup.done.txt
rm $T/boot/firmware/userconf.txt $T/boot/firmware/consolepi-setup.done.txt
cp /etc/NetworkManager/system-connections/hotspot.nmconnection $T/etc/NetworkManager/system-connections/
cp /etc/ConsolePi/ConsolePi.yaml $T/etc/ConsolePi/
printf 'user=smoke\r\npassword=smoke-pass\r\nwifi_ssid=Smoke Net;1\r\nwifi_password=smoke-psk-123\r\nssh_key=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIsmoke test\r\nhotspot_password=NewHotspotPW\r\nbluetooth_pin=24681357\r\n' > $T/boot/firmware/consolepi-setup.txt
CONSOLEPI_SETUP_ROOT=$T /usr/local/sbin/consolepi-setup
test ! -e $T/boot/firmware/consolepi-setup.txt
grep -q '^smoke:\$6\$' $T/boot/firmware/userconf.txt
f=$(ls $T/etc/NetworkManager/system-connections/wifi-*.nmconnection)
cat "$f"
grep -q '^psk=smoke-psk-123' "$f"
grep -q '^psk=NewHotspotPW' $T/etc/NetworkManager/system-connections/hotspot.nmconnection
grep -q "wlan_psk: 'NewHotspotPW'" $T/etc/ConsolePi/ConsolePi.yaml
grep -qx 'pin=24681357' $T/etc/consolepi-bt.conf
test "$(stat -c %a $T/etc/consolepi-bt.conf)" = 600
grep -q 'Problems' $T/boot/firmware/consolepi-setup.done.txt && { cat $T/boot/firmware/consolepi-setup.done.txt; exit 1; }
rm -rf $T
# the menu's import block must load with the installed venv (regression: spinner import before sys.path)
out=$(cd /tmp && /etc/ConsolePi/venv/bin/python -c "exec(open('/etc/ConsolePi/src/consolepi-menu.py').read().split('MIN_WIDTH = ')[0])" 2>&1 || true)
echo "$out" | tail -5
echo "$out" | grep -qE 'ModuleNotFoundError|ImportError' && { echo "consolepi-menu imports broken"; exit 1; }
test -x /etc/ConsolePi/src/consolepi-commands/consolepi-powercheck
/etc/ConsolePi/src/consolepi-commands/consolepi-powercheck || true   # no firmware in the chroot: must not fail
echo "smoke test OK"
EOF

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
    for g in consolepi dialout adm sudo plugdev netdev gpio video; do
        getent group \$g >/dev/null && usermod -aG \$g "\$first_user"
    done
fi

# git: /etc/ConsolePi belongs to another user than whoever logs in (the installer only allows it
# per user, but the image's users are made later by consolepi-setup) -> allow it for everyone
git config --system --get-all safe.directory | grep -qx /etc/ConsolePi || git config --system --add safe.directory /etc/ConsolePi
runuser -u nobody -- git -C /etc/ConsolePi log -1 --format='git safe.directory OK (%cd)'

# SSH on, host keys are regenerated on first boot
systemctl enable ssh
rm -f /etc/ssh/ssh_host_*
systemctl enable regenerate_ssh_host_keys 2>/dev/null || true

# diagnostics for the build log
echo "--- first boot related units:"; systemctl list-unit-files | grep -Ei 'regenerate|userconf|ssh|NetworkManager|consolepi|ser2net|rfcomm|bt-agent' || true
echo "--- consolepi-setup ordering:"; systemctl show -p Before,After,WantedBy consolepi-setup.service 2>/dev/null || true
echo "--- wifi country / rfkill:"; grep -o 'cfg80211.ieee80211_regdom=[A-Z]*' /boot/firmware/cmdline.txt || echo "regdom not set in cmdline"
echo "--- consolepi user groups for \$first_user:"; id "\$first_user" || true

# cleanup
apt-get clean
rm -rf /var/lib/apt/lists/* /root/.cache /tmp/* /var/tmp/*
rm -f /root/.bash_history
EOF

# build info
cat > "$MNT/etc/consolepi-image" <<EOF
version=${IMG_VERSION}
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
out_name="consolepi-${IMG_VERSION}-${base_name#*-raspios-}"    # e.g. consolepi-v0.1.4-trixie-arm64-lite
log "Compressing to $OUT_DIR/${out_name}.img.xz"
mv base.img "${out_name}.img"
xz -T0 -6 -c "${out_name}.img" > "$OUT_DIR/${out_name}.img.xz"
rm -f "${out_name}.img"
(cd "$OUT_DIR" && sha256sum "${out_name}.img.xz" > "${out_name}.img.xz.sha256")
ls -lh "$OUT_DIR"
log "Done"
