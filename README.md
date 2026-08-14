# scansnap-pi

Turn a Fujitsu ScanSnap iX500 into a small headless scan-to-WebDAV appliance.
Insert paper, press the scanner button, and a duplex PDF is uploaded to
ownCloud, Nextcloud, or another WebDAV server. No ScanSnap Cloud account or
desktop application is required.

The pipeline runs on Raspberry Pi OS or another Debian-based Linux system:

```text
ScanSnap iX500 --USB--> scanbd --button--> scanimage --> PDF --> WebDAV
```

It removes blank duplex pages, deskews and crops scans, improves receipt
contrast, compresses the result, and retains failed uploads for recovery.

## Requirements

- Fujitsu ScanSnap iX500 connected by USB
- Raspberry Pi OS or Debian
- A WebDAV account and target folder

Install the runtime packages:

```bash
sudo apt update
sudo apt install scanbd sane-utils imagemagick libjpeg-turbo-progs img2pdf curl
```

## Setup

Create the dedicated account used by the supplied scanbd and sudoers files:

```bash
sudo adduser --disabled-password --gecos "" scansnap
sudo usermod -aG scanner,lp scansnap
```

Stop scanbd temporarily and obtain the exact SANE device identifier:

```bash
sudo systemctl stop scanbd
sudo -u scansnap scanimage -L
sudo systemctl start scanbd
```

Deploy from this repository. The SSH account must be allowed to use `sudo` on
the Pi:

```bash
scripts/deploy-to-pi.sh admin@pi-host
```

The deploy script installs scripts below `/home/scansnap`, installs the files
under `pi/etc`, and creates the configuration from the example only when it
does not already exist. It never overwrites an existing configuration.

On the Pi, edit `/home/scansnap/.config/scansnap/scansnap.env` and set:

```dotenv
SCANNER_DEVICE="fujitsu:ScanSnap iX500:replace-with-your-device-id"
WEBDAV_URL=https://cloud.example.com/remote.php/dav/files/username/Scans/
WEBDAV_USER=username
WEBDAV_PASSWORD=replace-with-an-app-password
```

Use a dedicated WebDAV app password when the server supports it. Keep this
file at mode `600`; it is excluded from Git.

## Use and troubleshooting

Load paper into the ADF and press the Scan or Email button. Both buttons run
the same pipeline.

```bash
systemctl status scanbd
tail -f /home/scansnap/scansnap.log
ls /home/scansnap/scansnap-pending /home/scansnap/scansnap-failed
```

`scanbd` owns the scanner while running. Stop it before using `scanimage`
manually. Failed uploads are moved to `scansnap-failed` instead of being
deleted.

The default profile is A4, duplex, color, 200 dpi. Optional values such as
`RESOLUTION`, `BLANK_THRESHOLD`, and `JPEG_QUALITY` are documented in
[`pi/config/scansnap.env.example`](pi/config/scansnap.env.example).

## Tests

Run the configuration test on any system with Bash:

```bash
tests/test-upload-config.sh
```

Run the image integration test on a system with ImageMagick 6:

```bash
tests/test-normalize-image.sh
```

## License

GPL-2.0-or-later. The bundled `scanbd` Fujitsu configuration retains its
original copyright and license notice.
