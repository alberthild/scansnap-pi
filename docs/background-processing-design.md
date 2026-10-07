# Scan capture and background processing

## Intended outcome

The user can scan another stack after the current stack has been captured
and saved on the Pi, while earlier stacks are still being processed and
uploaded. Keep the existing image corrections and WebDAV destination.
Older Raspberry Pis have limited CPU and memory, so run only one image
processing job at a time.

Observed capture time was about 5–7 seconds for two sides. Processing took
about four minutes. Moving processing out of the button action removes that
wait for the next scan; it does not make the CPU work itself faster.

## Chosen approach

Split capture from processing with a persistent queue on the Pi's SD card.
The button action remains synchronous only until scanimage finishes and the
captured job is committed to the queue. A separate systemd worker processes
complete jobs serially, with lower CPU and I/O priority than capture.

The scanner exposes `buffermode`, which can read ADF pages into internal
memory. Do not change that setting in this first implementation: transfers
are already fast relative to processing, and the hardware buffer is not the
persistent queue. No scanner hardware buffering capacity is assumed.

## Job lifecycle

1. Each button press creates a unique capture directory on the SD card.
   scanimage writes numbered JPEG pages there. No raw pages rely solely on
   `/dev/shm`. Check available disk space before capture; keep a configurable
   reserve, initially 512 MiB.
2. Store the job ID, capture timestamp, and the processing settings needed
   for this stack. Do not copy cloud passwords into job metadata. Upload uses
   the user's existing protected cloud configuration.
3. Empty feeder: finish normally without queuing a job. Unexpected scan
   errors or incomplete scans: retain acquired pages for recovery, record the
   error, and do not silently upload a partial document as a complete scan.
4. Publish a completed job by an atomic rename within the spool filesystem.
   The worker cannot process a directory while capture is writing it. The
   button action then returns, allowing scanbd to resume button polling.
5. The worker processes published jobs in capture order, one at a time:
   blank filtering, image correction, JPEG compression, PDF creation, upload.
   Work on copies so a failed processing attempt retains the original scans.
6. Use a stable filename derived from capture time and job ID, preventing
   collisions and allowing upload retries to address the same remote file.
7. Remove raw scans only after a successful upload. Failed jobs are retained
   separately and do not block later queued jobs. Preserve failed PDFs too.

## Worker and recovery

Use a systemd service running as the scan account, with `Nice=10`, low I/O
priority, and a lock preventing concurrent worker instances. It starts at
boot and watches the persistent spool for completed jobs.

On restart, resume committed jobs. Interrupted processing must be recoverable
from raw pages; incomplete capture directories remain in a recovery area,
not automatically promoted to complete documents. Keep success/failure and
the stable job identity durable so reboot recovery does not silently lose
documents or create a second filename for the same job.

## Status and user behavior

Preserve the Pi ACT LED patterns: solid means the queue is empty and no job
is active; slow blinking means capture, queued work, processing, or upload;
fast blinking means a recorded error. Restore status from persistent jobs
after reboot, rather than assuming the queue is empty.

With background processing, slow blinking no longer means that another scan
is blocked. After paper finishes passing and the capture is safely queued,
the next stack can be scanned while the LED continues blinking. Log an
explicit message when capture completes and the scanner becomes available.

## Existing installation and deployment

Update the repository's dedicated `scansnap` account deployment and the live
existing installations with a custom scan account. Back up installed scripts first; preserve
the live ownCloud configuration and account. Install only when no scan or
upload is running. Keep the current normalizer and processing settings.

This changes the relationship between capture, processing, upload, and LED
status. It requires a queue and worker, rather than merely adding `&` to the
current script, whose cleanup trap deletes the temporary scan directory.

## Acceptance checks

- Capture returns with a durable queued job while processing is deliberately
  held. A second capture succeeds before the first job is processed.
- Jobs stay separate and retain capture order, settings, and filenames.
- Only one processor runs, including when two workers are started.
- Empty feeder, scan errors, disk exhaustion, processing failures, and upload
  failures retain appropriate data and report the correct status.
- Service restart and reboot recovery do not lose completed captures.
- Busy status persists across overlapping capture/processing/upload jobs.
- Run the existing suite and new queue tests, then confirm two successive
  button scans on the Pi and verify both PDFs through ownCloud WebDAV.

## Scope

Keep image quality and existing corrections. No new website, notifications,
scanner LED controls, extra hardware, or hardware buffer tuning in this
change. Background processing remains limited by the Pi's throughput; a
growing queue consumes SD-card space and is protected by the free-space check.

## Review decisions accepted before implementation

The independent review required stable original duplex numbering, strict scan
exit handling, a separate capture lock during recovery, fsync before queue
publication and upload acknowledgement, ongoing free-space checks, and
account-aware deployment. All are implemented and covered by targeted tests.

A second code review additionally required a PDF checksum commit marker,
isolation of corrupt manifests, orphan detection while the worker remains
running, a shared state/LED lock, fully captured effective settings, and
preservation of legacy scan settings and normalizer. These were incorporated.
Failed queue jobs keep the LED error latched until explicit recovery; merely
starting another scan no longer clears it. Installation uses a temporary
button guard before checking for active work.
