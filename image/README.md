# ConsolePi OS image

Raspberry Pi OS Lite (64 bit, Bookworm) with ConsolePi pre-installed. Flash it, boot it, done – no
installer run, no internet needed on the Pi.

## Supported hardware

Every Pi that runs 64 bit Raspberry Pi OS:

| Board | Notes |
|---|---|
| Pi Zero 2 W | 512 MB RAM is enough. No Ethernet; the single micro-USB data port needs an OTG adapter (or OTG hub) for the USB-serial adapter. |
| Pi 3B / 3B+ | |
| Pi 4 / 400 / 5, CM3 / CM4 | |

Not supported: Pi Zero / Zero W (v1), Pi 1 and Pi 2 – they can't run 64 bit.

## Download

* Releases: tags `image-v*` publish the image as a GitHub release.
* Any build: Actions → **Build ConsolePi OS image** → open a run → artifact `consolepi-image`.

## Flashing

Use **Raspberry Pi Imager**:

1. *Choose OS* → *Use custom* → select the `.img.xz`.
2. When asked, **edit the OS customisation settings**:
   * username / password – this is your login (the user gets all ConsolePi rights)
   * WiFi (optional) – a WiFi the Pi should join as client
   * *Services* → enable SSH
3. Write the card, boot the Pi.

Without the customisation the Pi asks for a user on the local console (keyboard + monitor) on first boot.

## First boot

* The file system grows to the full card and the SSH host keys are generated – give it a minute.
* If no configured WiFi is in range the Pi opens its **hotspot**:
  * SSID `ConsolePi`, password `ConsolePiR0cks!!`
  * the Pi is `10.110.0.1` → `ssh <user>@10.110.0.1`
* Run `consolepi-menu` to connect to a serial device.
* **Change the hotspot password**: `consolepi-config` opens the config, then apply it with
  `sudo consolepi-upgrade` (needs internet, it also updates ConsolePi).

Hostname `consolepi`, WiFi country `DE`, timezone `Europe/Berlin` (can be changed when running the workflow manually).

## Building yourself

The workflow runs on GitHub's arm64 runners. Locally (Linux, root, ~6 GB free):

```bash
sudo apt install parted zerofree xz-utils e2fsprogs curl   # + qemu-user-static on x86
sudo HOTSPOT_PSK='my-secret-psk' bash image/build-image.sh
```

All settings are listed at the top of `image/build-image.sh`. The build log of the ConsolePi
installer ends up in `out/install.log`.
