# Background processing implementation plan

> Execute inline using executing-plans; the user authorized reviewer feedback followed by immediate implementation.

Goal: return the button action after durable capture while a serial background service processes and uploads queued stacks.
Spec: docs/background-processing-design.md

Architecture: Python standard-library queue owns persistence, capture and worker locks, retries and recovery. Bash retains image processing and shell configuration loading. A parameterized systemd service runs the worker as the scan account with reduced CPU/I/O priority.

## Tasks
- [x] 1. Add queue tests, observe failure: capture without processing, second capture, partial scan retention, recovery during capture, serial worker, stable upload retry, disk pressure, sticky failed-job LED state.
- [x] 2. Implement pi/bin/scansnap-queue.py and config-loading capture/worker wrappers. Capturing/queued/processing/failed/done directories, fsync+rename handoff, original pages retained until durable success. Capture has its own flock, worker has another. Stop process groups before releasing locks. Recovery acquires capture lock nonblocking.
- [x] 3. Extract existing image corrections into scansnap-process.sh. Copy raw pages to work; name duplex partners by original numbered filename; produce result.pdf atomically. Add a duplex regression test. Worker uploads synchronously to a stable remote name, retries same file and retains failed data.
- [x] 4. Parameterize deploy target account/Home, button action, sudoers and worker service; support existing owncloud.env aliases without exposing credentials. Preserve legacy pending/failed PDFs. Refuse active legacy processes, install complete files before restart. Update LED error latch to survive new begins until explicitly cleared after recovery.
- [x] 5. Run repository tests locally and on Pi, independent code review, fix material findings, install during idle period. Verify real LED and worker state; request two user button presses for hardware validation if needed.

## Review focus and decisions
- Accepted review: explicit scan RC/end-of-batch checks, original duplex numbering, two distinct locks, fsync before publish and success before cleanup.
- Disk reserve default 512 MiB; monitor while capture runs and check working-copy requirements; low-space jobs retained, never delete originals to make space.
- Completed receipt prevents re-upload after cleanup interruption; ambiguous remote success repeats the identical PUT filename.
- Persistent failed jobs keep error visible across new successful jobs and service restart; retry is explicit and never promotes partial captures.
- Preserve the existing scan account and protected owncloud.env. The repository default is scansnap.
- Continue in the current checkout to preserve the already installed LED work. After successful hardware testing, the user requested a GitHub push.

## Progress
Plan review by review_background_design completed; all seven substantive findings accepted.

Local queue suite: 19 passing; all six code-review findings corrected. LED snapshot synchronization and live orphan recovery have additional regression tests. Pi staged suite passed Queue17, LED8, duplex1, config/deploy and the normalizer integration test; final Queue19 suite also passed before deployment.

Deployment verified: worker and scanbd active, queue empty, LED ready.
Existing scripts and configuration were backed up before installation. Full Pi suite passed (Queue19, LED8, duplex1, config, deployment
failure propagation, ImageMagick integration). The user confirmed successful
hardware operation and requested publication to GitHub.
