# Working on scansnap-pi

## Architecture and lessons

- Read README.md and docs/background-processing-design.md before changing the pipeline.
- Keep the scanbd button action limited to capture and durable queue publication.
  Image processing and upload belong in the serial background worker. On the
  deployed Pi, duplex capture took about 5–7 seconds while processing took minutes;
  a synchronous button action made the scanner appear unresponsive.
- Queue storage is on the Pi filesystem, not an assumed scanner cache or RAM disk.
  Preserve originals until a durable upload-success receipt exists. Never automatically
  retry interrupted captures as complete documents.
- Preserve separate capture/worker locks, atomic state transitions, fsync, the PDF
  checksum marker, stable upload filenames, and serialized LED reconciliation.
- Pair duplex pages by original page numbers, before blank-page removal can shift
  their positions. Work on copies of raw images.
- The status light is the green ACT LED on the Pi, not the blue ScanSnap button.
  Slow blinking permits another stack once capture finishes; fast blinking remains
  latched while failed jobs exist. Solid means idle, not verified USB connectivity.

## Deployment and diagnosis

- Use the actual deployment account in service names and paths. Repository
  examples use `scansnap` and the placeholder host `pi-host`.
- Example deployment: `scripts/deploy-to-pi.sh admin@pi-host scansnap`.
  Deploy only when capture and processing are idle and the queue is empty. Preserve
  the installed normalizer, settings, credentials, and `/var/backups/scansnap`.
- Start diagnosis with `systemctl status scanbd scansnap-worker@scansnap.service`,
  `journalctl -u scansnap-worker@scansnap.service -n 60 --no-pager`,
  `/home/scansnap/scansnap.log`, free disk space, and spool state counts.
  Do not dump document contents or protected configuration into tool output.
- scanbd owns the USB scanner. Stop it before direct scanimage diagnostics and
  restart afterward; do not interrupt a live scan to probe the device.
- Existing credentials live in protected `~/.config/scansnap/owncloud.env`, loaded
  through `scansnap.env`. Never commit either file or print credentials. Queue
  metadata must not contain passwords. Confirm an upload at the configured WebDAV
  destination when diagnosing missing files, not just by scanner motion.
- Preserve `scansnap-spool`, legacy pending/failed PDFs, and deployment backups
  during cleanup. Temporary source/test staging directories are disposable after
  confirming no process uses them. Do not delete queued or failed documents.

## Validation and Git

- Python checks: `python3 tests/test-queue.py`, `python3 tests/test-status-led.py`,
  `python3 tests/test-led-pipeline.py`, `python3 tests/test-process-pairs.py`.
- Shell checks: `bash tests/test-upload-config.sh`, `bash tests/test-deploy-failure.sh`,
  `bash -n scripts/*.sh pi/bin/*.sh`, and `git diff --check`.
- Run `bash tests/test-normalize-image.sh` on an ImageMagick 6 system (the Pi is
  suitable). It can take minutes on this hardware. Use isolated fixtures, not
  actual scanner operations, for automated tests.
- After capture/worker changes, request two successive physical stacks and check
  their eventual uploads. Physical operation was confirmed by the user.
- Before publishing, inspect commit author/email as well as changes. The initial
  generic `noreply@users.noreply.github.com` author caused incorrect GitHub attribution
  and was corrected to the configured contributor identity. Do not reintroduce it.
- Do not rewrite published history or force-push without explicit authorization.

## Public repository privacy

- Never publish actual hostnames, IP addresses, SSH aliases, account names, cloud
  endpoints, device identifiers, hardware inventory, or deployment timestamps.
  Use neutral examples such as `pi-host`, `scansnap`, and `cloud.example.com`.
- Keep installation-specific notes outside version control. Inspect documentation,
  tests, commit messages, and historical content before publishing. Git ignore
  rules do not remove information that was previously committed.
