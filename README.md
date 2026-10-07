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
sudo apt install scanbd sane-utils imagemagick libjpeg-turbo-progs img2pdf curl python3
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

Each button press captures one stack into `~/scansnap-spool`. After capture
and durable storage, the scanner is free for the next stack. A single
`scansnap-worker@USER.service` processes the queue with lower CPU and I/O
priority and uploads PDFs in capture order. Image processing can still take
several minutes on older Pis; new scans can be queued during that time.

On Raspberry Pis with an ACT LED, solid green means no queued work, slow
blinking means capture/queued work/processing/upload, and fast blinking means
an error. **Slow blinking does not prevent another scan after the preceding
stack has finished being captured.** Failed queue jobs keep the error visible
until recovered. The worker reconstructs status after a reboot. A ready LED
describes pipeline activity, not scanner connectivity.

Raw JPEGs are kept until successful upload. Interrupted captures and failed
jobs remain in `~/scansnap-spool/failed/JOB`; metadata and logs explain why.
Do not automatically retry a partial capture: inspect the retained pages or
rescan the complete stack. To retry a processing/upload failure, stop the
worker, run `~/bin/scansnap-worker.sh retry JOB` as the scan user, then start
the service again. Existing PDFs in `scansnap-pending` and `scansnap-failed`
from the old pipeline are retained and are not automatically resubmitted.

```bash
sudo systemctl status scansnap-worker@scansnap.service
sudo systemctl stop scansnap-worker@scansnap.service
sudo -u scansnap -H /home/scansnap/bin/scansnap-worker.sh retry JOB
sudo systemctl start scansnap-worker@scansnap.service
```

Use the actual account name in these commands. For example, deploy with
`scripts/deploy-to-pi.sh admin@pi-host scansnap`.
The installer preserves `owncloud.env` and creates a protected compatibility
configuration when needed. It backs up existing scripts/configuration under
`/var/backups/scansnap` and refuses deployment during active scans or with a
nonempty queue.

The spool reserves 512 MiB by default (`SCANSNAP_MIN_FREE_MB`). Free space is
checked before and during capture/processing. On disk exhaustion, originals
are retained; the job is not silently uploaded as a complete document.

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

Run the status indicator and pipeline tests with Python 3:

```bash
python3 tests/test-status-led.py
python3 tests/test-led-pipeline.py
python3 tests/test-queue.py
python3 tests/test-process-pairs.py
```

## License

GPL-2.0-or-later. The bundled `scanbd` Fujitsu configuration retains its
original copyright and license notice.
