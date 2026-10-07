#!/usr/bin/env python3
"""Durable capture spool and single background processor, without extra packages."""
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid
from urllib.parse import quote

SETTINGS = {'SOURCE':'ADF Duplex', 'MODE':'Color', 'RESOLUTION':'200',
            'PAGE_WIDTH':'210', 'PAGE_HEIGHT':'297', 'BLANK_THRESHOLD':'0.96',
            'JPEG_QUALITY':'60'}


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_json(path, value):
    tmp = path.with_suffix('.tmp')
    with tmp.open('w') as out:
        json.dump(value, out)
        out.flush()
        os.fsync(out.fileno())
    os.replace(tmp, path)
    sync_dir(path.parent)


class Queue:
    def __init__(self, env=None):
        self.env = dict(os.environ if env is None else env)
        self.home = Path(self.env['HOME'])
        self.root = Path(self.env.get('SCANSNAP_SPOOL', str(self.home/'scansnap-spool')))
        self.bin = Path(self.env.get('SCANSNAP_BIN', str(self.home/'bin')))
        self.min_free = int(self.env.get('SCANSNAP_MIN_FREE_MB', '512')) * 1024 * 1024
        if self.min_free < 0:
            raise ValueError('SCANSNAP_MIN_FREE_MB must not be negative')
        self.lock_fds = []
        for state in ('capturing', 'queued', 'processing', 'failed', 'done'):
            (self.root/state).mkdir(parents=True, exist_ok=True, mode=0o700)

    def log(self, message):
        line = datetime.now().astimezone().isoformat(timespec='seconds')+' '+message
        print(line, flush=True)
        with (self.home/'scansnap.log').open('a') as out:
            out.write(line+'\n')

    def led(self, action, job=None):
        helper = self.bin/'scansnap-led.sh'
        if helper.exists():
            try:
                subprocess.run([str(helper), action] + ([job] if job else []),
                               env=self.env, timeout=15, check=False, pass_fds=tuple(self.lock_fds))
            except (OSError, subprocess.TimeoutExpired):
                self.log('WARN: LED status unavailable')

    def reconcile_led(self):
        # All spool state changes share this lock, so a stale snapshot cannot
        # recreate a completed capture marker or clear a simultaneous failure.
        with self.lock('status', blocking=True):
            active = {job.name for state in ('capturing', 'queued', 'processing')
                      for job in (self.root/state).iterdir() if job.is_dir()}
            ledger = self.root/'led-jobs.json'
            try:
                previous = set(json.loads(ledger.read_text()))
            except (OSError, ValueError):
                previous = set()
            for job_id in active:
                self.led('begin', job_id)
            for job_id in previous-active:
                self.led('end', job_id)
            failed = list((self.root/'failed').iterdir())
            if failed:
                for job in failed:
                    self.led('fail', job.name)
            else:
                self.led('clear')
            atomic_json(ledger, sorted(active))

    @contextmanager
    def lock(self, name, blocking=False):
        with (self.root/(name+'.lock')).open('a') as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
            except BlockingIOError:
                yield False
                return
            self.lock_fds.append(handle.fileno())
            try:
                yield True
            finally:
                self.lock_fds.remove(handle.fileno())
                # Closing (rather than explicit LOCK_UN) keeps the lock held by
                # any inherited child descriptor if this process is interrupted.

    def move(self, job, state):
        with self.lock('status', blocking=True):
            target = self.root/state/job.name
            parent = job.parent
            os.rename(job, target)
            sync_dir(parent)
            sync_dir(target.parent)
            return target

    def remove(self, job):
        with self.lock('status', blocking=True):
            shutil.rmtree(job)
            sync_dir(job.parent)

    def run(self, command, *, env=None, stdout=None, stderr=None, monitor_space=True, input_text=None):
        process = subprocess.Popen(command, env=env or self.env, stdout=stdout, stderr=stderr,
                                   stdin=subprocess.PIPE if input_text is not None else subprocess.DEVNULL,
                                   start_new_session=True, pass_fds=tuple(self.lock_fds))
        try:
            if input_text is not None:
                process.stdin.write(input_text.encode())
                process.stdin.close()
            while process.poll() is None:
                if monitor_space and shutil.disk_usage(self.root).free < self.min_free:
                    raise RuntimeError('free disk space fell below reserve')
                time.sleep(0.2)
            return process.returncode
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()

    def fail(self, job, reason, stage):
        try:
            data = json.loads((job/'job.json').read_text())
            if not isinstance(data, dict):
                raise ValueError('invalid metadata object')
        except (OSError, ValueError):
            data = {'id': job.name}
        data.update(error=str(reason), failure_stage=stage)
        # If storage is completely full, retain raw files even if metadata
        # cannot be updated. Directory state remains the source of truth.
        try:
            atomic_json(job/'job.json', data)
        except OSError:
            pass
        self.move(job, 'failed')
        self.reconcile_led()
        self.log(f'ERROR: {job.name}: {reason}; originals retained in scansnap-spool/failed')

    def capture(self):
        with self.lock('capture') as acquired:
            if not acquired:
                self.log('Scanner capture already active')
                return 4
            job_id = 'scan-'+datetime.now().strftime('%Y%m%d-%H%M%S')+'-'+uuid.uuid4().hex[:12]
            job = self.root/'capturing'/job_id
            with self.lock('status', blocking=True):
                job.mkdir(mode=0o700)
                (job/'raw').mkdir()
            self.reconcile_led()
            try:
                if shutil.disk_usage(self.root).free < self.min_free:
                    raise RuntimeError('not enough free disk space to start capture')
                device = self.env.get('SCANNER_DEVICE')
                if not device:
                    raise ValueError('SCANNER_DEVICE is not set')
                data = {'id': job_id, 'created_ns': time.time_ns(), 'filename': job_id+'.pdf',
                        'settings': {key:self.env.get(key, default) for key,default in SETTINGS.items()}}
                atomic_json(job/'job.json', data)
                cmd = ['scanimage', '--device-name', device,
                       '--source', self.env.get('SOURCE', 'ADF Duplex'),
                       '--mode', self.env.get('MODE', 'Color'),
                       '--resolution', self.env.get('RESOLUTION', '200'),
                       '--page-width', self.env.get('PAGE_WIDTH', '210'),
                       '--page-height', self.env.get('PAGE_HEIGHT', '297'),
                       '--format=jpeg', '--batch='+str(job/'raw/page-%03d.jpg')]
                self.log(f'Capture started: {job_id}')
                with (job/'scan-stderr.log').open('wb') as error:
                    rc = self.run(cmd, stderr=error, stdout=subprocess.DEVNULL)
                detail = (job/'scan-stderr.log').read_text(errors='replace')
                self.log(detail.rstrip())
                if rc != 0 and not (rc == 7 and 'out of documents' in detail.lower()):
                    raise RuntimeError(f'scanimage failed (rc={rc}); incomplete stack')
                pages = list((job/'raw').glob('page-*.jpg'))
                if not pages:
                    if 'out of documents' not in detail.lower():
                        raise RuntimeError('scanimage produced no pages')
                    self.remove(job)
                    self.reconcile_led()
                    self.log('ADF leer. Kein Auftrag.')
                    return 0
                for page in pages:
                    if page.stat().st_size == 0:
                        raise RuntimeError('empty page file; incomplete stack')
                    with page.open('rb') as stream:
                        os.fsync(stream.fileno())
                sync_dir(job/'raw')
                sync_dir(job)
                self.move(job, 'queued')
                self.log(f'{len(pages)} Seiten gespeichert: {job_id}. Scanner frei; Verarbeitung im Hintergrund.')
                return 0
            except (OSError, ValueError, RuntimeError, KeyboardInterrupt) as exc:
                if job.exists():
                    self.fail(job, exc, 'capture')
                return 3

    def recover_captures(self):
        with self.lock('capture') as acquired:
            if acquired:
                for job in (self.root/'capturing').iterdir():
                    self.fail(job, 'interrupted capture; manual recovery required', 'capture')

    def recover(self):
        self.recover_captures()
        for job in (self.root/'processing').iterdir():
            self.move(job, 'queued')
        for job in (self.root/'queued').iterdir():
            if (self.root/'done'/(job.name+'.json')).exists():
                self.remove(job)
        self.reconcile_led()

    def upload(self, job, data):
        url = self.env['WEBDAV_URL'].rstrip('/')+'/'+quote(data['filename'])
        if not url.startswith(('http://', 'https://')):
            raise ValueError('WEBDAV_URL must use HTTP(S)')
        def config_quote(value):
            if '\n' in value or '\r' in value:
                raise ValueError('newline in WebDAV configuration')
            return '"'+value.replace('\\', '\\\\').replace('"', '\\"')+'"'
        config = 'url = '+config_quote(url)+'\nuser = '+config_quote(
            self.env['WEBDAV_USER']+':'+self.env['WEBDAV_PASSWORD'])+'\n'
        for attempt in range(1, 4):
            with (job/'http-code').open('wb') as output, (job/'upload-error.log').open('wb') as error:
                rc = self.run(['curl', '--config', '-', '-sS', '--max-time', '600',
                               '--output', str(job/'upload-response'), '--write-out', '%{http_code}',
                               '--header', 'Content-Type: application/pdf', '--upload-file', str(job/'result.pdf')],
                              stdout=output, stderr=error, input_text=config, monitor_space=False)
            code = (job/'http-code').read_text().strip()
            if rc == 0 and re.fullmatch(r'2\d\d', code):
                self.log(f'Upload OK: {data["filename"]}, HTTP={code}')
                return
            self.log(f'Upload attempt {attempt} failed: {data["filename"]}, HTTP={code}, curl={rc}')
            if attempt < 3:
                time.sleep(float(self.env.get('SCANSNAP_UPLOAD_RETRY_WAIT', '10')))
        raise RuntimeError('WebDAV upload failed after three attempts')

    def pdf_ready(self, job):
        try:
            expected = json.loads((job/'pdf-ready.json').read_text())
            pdf = job/'result.pdf'
            if pdf.stat().st_size <= 0:
                return False
            with pdf.open('rb') as stream:
                digest = hashlib.file_digest(stream, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else hashlib.sha256(stream.read()).hexdigest()
            return expected == {'size':pdf.stat().st_size, 'sha256':digest}
        except (OSError, ValueError):
            return False

    def commit_pdf(self, job):
        part = job/'result.part.pdf'
        if not part.is_file() or part.stat().st_size == 0:
            raise RuntimeError('processor did not produce a PDF')
        with part.open('rb') as stream:
            if stream.read(5) != b'%PDF-':
                raise RuntimeError('invalid PDF header')
            stream.seek(0)
            digest = hashlib.sha256()
            for block in iter(lambda: stream.read(1024*1024), b''):
                digest.update(block)
            os.fsync(stream.fileno())
        os.replace(part, job/'result.pdf')
        sync_dir(job)
        atomic_json(job/'pdf-ready.json', {'size':(job/'result.pdf').stat().st_size,
                                         'sha256':digest.hexdigest()})

    def process_first(self):
        jobs = []
        for candidate in (self.root/'queued').iterdir():
            try:
                data = json.loads((candidate/'job.json').read_text())
                if not isinstance(data['created_ns'], int) or not isinstance(data['settings'], dict):
                    raise ValueError('invalid job metadata')
                jobs.append((data['created_ns'], candidate))
            except (OSError, ValueError, KeyError, TypeError) as exc:
                self.fail(candidate, 'invalid job manifest: '+str(exc), 'capture')
        jobs = [job for _,job in sorted(jobs)]
        if not jobs:
            return False
        job = self.move(jobs[0], 'processing')
        stage = 'processing'
        try:
            data = json.loads((job/'job.json').read_text())
            self.log('Processing: '+job.name)
            if not self.pdf_ready(job):
                size = sum(p.stat().st_size for p in (job/'raw').glob('page-*.jpg'))
                if shutil.disk_usage(self.root).free < self.min_free + size * 3:
                    raise RuntimeError('not enough space for processing copies')
                work = job/'work'
                if work.exists():
                    shutil.rmtree(work)
                shutil.copytree(job/'raw', work)
                env = dict(self.env)
                env.update(data['settings'])
                with (job/'process.log').open('ab') as output:
                    rc = self.run([str(self.bin/'scansnap-process.sh'), str(job)], env=env,
                                  stdout=output, stderr=subprocess.STDOUT)
                if rc != 0:
                    raise RuntimeError(f'image processing failed (rc={rc})')
                if (job/'empty').exists():
                    data['status']='empty'
                else:
                    self.commit_pdf(job)
            if data.get('status') != 'empty':
                with (job/'result.pdf').open('rb') as pdf:
                    os.fsync(pdf.fileno())
                sync_dir(job)
                stage = 'upload'
                self.upload(job, data)
                data['status']='uploaded'
            atomic_json(self.root/'done'/(job.name+'.json'), data)
            self.remove(job)
            self.log('Job complete: '+job.name)
        except (OSError, ValueError, KeyError, RuntimeError) as exc:
            if job.exists():
                self.fail(job, exc, stage)
        self.reconcile_led()
        return True

    def run_once(self):
        with self.lock('worker') as acquired:
            if not acquired:
                return False
            self.recover()
            return self.process_first()

    def worker(self):
        with self.lock('worker') as acquired:
            if not acquired:
                raise RuntimeError('another worker is already running')
            self.recover()
            while True:
                if not self.process_first():
                    self.recover_captures()
                    time.sleep(2)

    def retry(self, job_id):
        if not re.fullmatch(r'[a-zA-Z0-9_-]{1,64}', job_id):
            raise ValueError('invalid job ID')
        with self.lock('worker') as acquired:
            if not acquired:
                raise RuntimeError('stop the worker before retrying a failed job')
            job = self.root/'failed'/job_id
            data = json.loads((job/'job.json').read_text())
            if data.get('failure_stage') == 'capture':
                raise ValueError('partial capture requires manual recovery or a new scan')
            self.move(job, 'queued')
            self.reconcile_led()


def main():
    os.umask(0o077)
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    queue = Queue()
    command = sys.argv[1] if len(sys.argv) > 1 else ''
    if command == 'capture':
        return queue.capture()
    if command == 'worker':
        queue.worker()
    elif command == 'once':
        queue.run_once()
    elif command == 'retry' and len(sys.argv) == 3:
        queue.retry(sys.argv[2])
    else:
        raise ValueError('usage: scansnap-queue.py capture|worker|once|retry JOB')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except (OSError, ValueError, RuntimeError, KeyError) as exc:
        print('Queue error: '+str(exc), file=sys.stderr)
        sys.exit(1)
