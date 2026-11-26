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
* File names carry the version: `consolepi-v0.1.3-bookworm-arm64-lite.img.xz` for releases,
  `consolepi-dev-<date>-<commit>-…` for manual builds. `/etc/consolepi-image` on the Pi shows it too.

## Flashing and setup

1. Write the `.img.xz` with any tool: Raspberry Pi Imager (*Use custom*), balenaEtcher, …
   Imager doesn't offer its OS customisation (user, WiFi) for custom images – that's what step 2 is for.
2. Re-plug the card. The small FAT partition **bootfs** shows up on your PC (Windows: as a drive).
   Open **`consolepi-setup.txt`** with a text editor, fill in at least `user` and `password`
   (and your WiFi), remove the `#` in front of those lines and save:

   ```ini
   user=stefan
   password=MySecret123
   wifi_ssid=My WiFi
   wifi_password=my-wifi-password
   wifi_country=DE
   hotspot_password=my-hotspot-password
   ```
3. Boot the Pi. The settings are applied on first boot, then `consolepi-setup.txt` is deleted
   (it holds passwords). What was applied – and any problems – is in `consolepi-setup.done.txt`
   on the same partition.

The user gets all ConsolePi rights (groups `consolepi`, `dialout`, `sudo`). SSH is enabled.
Without `user`/`password` the Pi asks for a user on the local console (keyboard + monitor).

Notes:

* Special characters and umlauts in passwords are fine. The file may be saved as UTF-8, UTF-16 or
  Windows-1252 (ANSI). `consolepi-setup.done.txt` shows the password length so typos stand out.
* The Pi's local console uses an English keyboard layout – on a German keyboard `y`/`z` and most
  symbols are on different keys. SSH from your PC is not affected.
* **Forgot the password / locked out?** Put a new `consolepi-setup.txt` with `user` + `password`
  (or just `ssh_key`) on **bootfs** and boot: it is applied on every boot where the file exists, and
  after the first boot the password of that user is changed directly.

## First boot

* The file system grows to the full card and the SSH host keys are generated – give it a minute.
* If no configured WiFi is in range the Pi opens its **hotspot**:
  * SSID `ConsolePi`, password `ConsolePiR0cks!!` unless set via `hotspot_ssid` / `hotspot_password`
  * the Pi is `10.110.0.1` → `ssh <user>@10.110.0.1`
* Otherwise: `ssh <user>@consolepi.local` (or the IP from your router).
* Run `consolepi-menu` to connect to a serial device. `sd` in the menu shuts the Pi down when you're done.

## Web terminal (browser access, like AirConsole)

Open **`https://consolepi.local`** (or `https://10.110.0.1` on the hotspot, or the Pi's IP) in any
browser – phone, tablet or laptop, no app needed. Log in with your user and password, and
`consolepi-menu` opens right away. Leaving the menu gives you a normal shell; `exit` ends the session.

* The certificate is self-signed (created on the Pi's first boot, unique per Pi), so the browser
  warns once – accept it (*Advanced → Proceed*).
* Same users and passwords as SSH; at most 5 sessions at the same time.
* Font size 16 px, "Rust" colour scheme (warm dark background, orange cursor). Other font size:
  `sudo systemctl edit consolepi-web`, add `[Service]` and `Environment=CONSOLEPI_WEB_FONT_SIZE=18`,
  then `sudo systemctl restart consolepi-web`. Colours: `/usr/local/sbin/consolepi-web-start`.
* Turn it off: `sudo systemctl disable --now consolepi-web`
* Built on [ttyd](https://github.com/tsl0922/ttyd) (`/usr/local/bin/ttyd`, service `consolepi-web`).

## Bluetooth console

The Pi is discoverable as `consolepi` and offers a Bluetooth serial port (SPP). Pair it – no PIN –
and connect at 115200 baud: you are logged in automatically as user `blue` and a limited menu
(locally attached adapters only) opens. Use SSH or the web terminal for everything else.

* **Windows:** pair, then *More Bluetooth settings → COM Ports* shows the *Outgoing* port – open it in
  PuTTY (Serial, 115200).
* **Linux:** `bluetoothctl` → `pair <MAC>`, `trust <MAC>`; then `sudo rfcomm connect /dev/rfcomm0 <MAC> 1`
  and `picocom -b 115200 /dev/rfcomm0` (Arch/CachyOS: `rfcomm` is in `bluez-deprecated-tools`).
* **Android:** e.g. the app *Serial Bluetooth Terminal*.
* **iPhone / iPad: not possible** – iOS has no classic Bluetooth serial support. Use the web terminal.

Anyone in range can pair and gets the menu without a password. Stop advertising: `consolepi-btoff`
(paired devices still connect). Turn Bluetooth access off completely:
`sudo systemctl disable --now consolepi-bt-agent rfcomm`. Pairing log: `journalctl -u consolepi-bt-agent`.

Hostname `consolepi`, WiFi country `DE`, timezone `Europe/Berlin` (can be changed when running the workflow manually).

## Building yourself

The workflow runs on GitHub's arm64 runners. Locally (Linux, root, ~6 GB free):

```bash
sudo apt install parted zerofree xz-utils e2fsprogs curl   # + qemu-user-static on x86
sudo HOTSPOT_PSK='my-secret-psk' bash image/build-image.sh
```

All settings are listed at the top of `image/build-image.sh`. The build log of the ConsolePi
installer ends up in `out/install.log`.
