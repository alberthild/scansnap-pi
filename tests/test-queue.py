#!/usr/bin/env python3
import fcntl
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / 'pi/bin/scansnap-queue.py'

class QueueTest(unittest.TestCase):
    def setUp(self):
        self.assertTrue(MODULE.exists(), 'persistent queue implementation is missing')
        spec = importlib.util.spec_from_file_location('queue_impl', MODULE)
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.bin = self.home / 'bin'
        self.bin.mkdir()
        self.exe('scanimage', '''for arg; do case "$arg" in --batch=*) batch=${arg#--batch=};; esac; done
printf 'jpeg' > "$(printf "$batch" 1)"
if [ "${SCAN_FAIL:-0}" = 1 ]; then echo 'Paper jam' >&2; exit 9; fi
printf 'jpeg' > "$(printf "$batch" 2)"
echo 'Document feeder out of documents' >&2
exit 7''')
        self.exe('scansnap-process.sh', "printf processed >> \"$HOME/processed\"; printf '%%PDF-1.4\\n%%%%EOF\\n' > \"$1/result.part.pdf\"")
        self.exe('curl', 'printf uploaded >> "$HOME/uploads"; printf "%s" "${CURL_STATUS:-201}"')
        self.exe('scansnap-led.sh', 'printf "%s %s\\n" "$1" "${2:-}" >> "$HOME/led-events"')
        self.env = dict(os.environ, HOME=str(self.home), PATH=f'{self.bin}:{os.environ["PATH"]}',
                        SCANNER_DEVICE='fujitsu:test', WEBDAV_URL='https://example.test/Scans/',
                        WEBDAV_USER='user', WEBDAV_PASSWORD='secret', SCANSNAP_MIN_FREE_MB='0',
                        SCANSNAP_UPLOAD_RETRY_WAIT='0')
        self.q = self.mod.Queue(self.env)

    def exe(self, name, body):
        p = self.bin / name
        p.write_text('#!/bin/bash\nset -eu\n'+body+'\n')
        p.chmod(0o755)

    def jobs(self, state):
        return list((self.q.root / state).iterdir())

    def test_capture_queues_two_stacks_without_processing(self):
        self.assertEqual(self.q.capture(), 0)
        self.assertEqual(self.q.capture(), 0)
        jobs = self.jobs('queued')
        self.assertEqual(len(jobs), 2)
        self.assertFalse((self.home / 'processed').exists())
        self.assertTrue(all(len(list((p/'raw').glob('page-*.jpg'))) == 2 for p in jobs))
        self.assertNotIn('secret', (jobs[0]/'job.json').read_text())

    def test_partial_scan_is_retained_and_not_uploaded(self):
        self.q.env['SCAN_FAIL'] = '1'
        self.assertNotEqual(self.q.capture(), 0)
        self.assertEqual(self.jobs('queued'), [])
        self.assertEqual(len(self.jobs('failed')), 1)
        self.assertTrue((self.jobs('failed')[0]/'raw/page-001.jpg').exists())
        self.assertFalse(self.q.run_once())
        self.assertFalse((self.home/'uploads').exists())

    def test_success_records_receipt_before_removing_raw_job(self):
        self.q.capture()
        job_id = self.jobs('queued')[0].name
        self.assertTrue(self.q.run_once())
        self.assertEqual(self.jobs('processing'), [])
        self.assertEqual(self.jobs('queued'), [])
        self.assertTrue((self.q.root/'done'/f'{job_id}.json').exists())
        self.assertEqual((self.home/'uploads').read_text(), 'uploaded')

    def test_failed_upload_retains_raw_pdf_and_retry_reuses_pdf(self):
        self.q.capture()
        self.q.env['CURL_STATUS']='500'
        self.q.run_once()
        job=self.jobs('failed')[0]
        self.assertTrue((job/'raw/page-001.jpg').exists())
        self.assertTrue((job/'result.pdf').exists())
        self.q.env['CURL_STATUS']='201'
        self.q.retry(job.name)
        self.q.run_once()
        self.assertEqual((self.home/'processed').read_text(), 'processed')
        self.assertEqual(len(self.jobs('done')), 1)

    def test_worker_restart_does_not_steal_live_capture(self):
        with self.q.lock('capture', blocking=True) as acquired:
            orphan=self.q.root/'capturing/live'
            orphan.mkdir()
            self.q.run_once()
            self.assertTrue(orphan.exists())
        self.q.run_once()
        self.assertFalse(orphan.exists())
        self.assertTrue((self.q.root/'failed/live').exists())

    def test_second_worker_does_not_process_while_first_owns_lock(self):
        self.q.capture()
        with self.q.lock('worker', blocking=True):
            self.assertFalse(self.q.run_once())
        self.assertFalse((self.home/'processed').exists())
        self.assertEqual(len(self.jobs('queued')), 1)

    def test_done_receipt_suppresses_upload_after_cleanup_crash(self):
        self.q.capture()
        queued=self.jobs('queued')[0]
        self.mod.atomic_json(self.q.root/'done'/f'{queued.name}.json', {'status':'uploaded'})
        self.q.run_once()
        self.assertFalse((self.home/'uploads').exists())
        self.assertFalse(queued.exists())

    def test_low_space_rejects_capture_without_starting_scanner(self):
        self.q.min_free=1
        with patch.object(self.mod.shutil, 'disk_usage', return_value=type('Usage', (), {'free':0})()):
            self.assertNotEqual(self.q.capture(), 0)
        self.assertEqual(self.jobs('queued'), [])

    def test_low_space_processing_retains_originals(self):
        self.q.capture()
        with patch.object(self.mod.shutil, 'disk_usage', return_value=type('Usage', (), {'free':0})()):
            self.q.run_once()
        self.assertTrue((self.jobs('failed')[0]/'raw/page-001.jpg').exists())
        self.assertFalse((self.home/'uploads').exists())

    def test_failed_job_remains_visible_after_successful_job(self):
        self.q.env['SCAN_FAIL']='1'
        self.q.capture()
        self.q.env['SCAN_FAIL']='0'
        self.q.capture()
        self.q.run_once()
        self.assertTrue((self.home/'led-events').read_text().splitlines()[-1].startswith('fail '))

    def test_processing_restart_reuses_completed_pdf(self):
        self.q.capture()
        job=self.jobs('queued')[0]
        job=self.q.move(job, 'processing')
        (job/'result.part.pdf').write_bytes(b'%PDF-1.4\n%%EOF\n')
        self.q.commit_pdf(job)
        self.q.run_once()
        self.assertFalse((self.home/'processed').exists())
        self.assertEqual(len(self.jobs('done')), 1)

    def test_capture_order_uses_manifest_not_random_filename_suffix(self):
        self.q.capture()
        self.q.capture()
        jobs=self.jobs('queued')
        import json
        first,second=sorted(jobs, key=lambda p: json.loads((p/'job.json').read_text())['created_ns'])
        data=json.loads((first/'job.json').read_text())
        data['created_ns']=1
        self.mod.atomic_json(first/'job.json',data)
        self.q.run_once()
        self.assertTrue((self.q.root/'done'/(first.name+'.json')).exists())
        self.assertTrue(second.exists())

    def test_disk_reserve_during_capture_stops_and_retains_partial_pages(self):
        self.exe('scanimage', 'for arg; do case "$arg" in --batch=*) batch=${arg#--batch=};; esac; done\nprintf jpeg > "$(printf "$batch" 1)"\nsleep 10')
        self.q.min_free=1
        high=type('Usage', (), {'free':100})()
        low=type('Usage', (), {'free':0})()
        with patch.object(self.mod.shutil, 'disk_usage', side_effect=[high,high,high,low]):
            self.assertNotEqual(self.q.capture(),0)
        self.assertTrue((self.jobs('failed')[0]/'raw/page-001.jpg').exists())
        self.assertEqual(self.jobs('queued'),[])

    def test_uncommitted_pdf_is_reprocessed_after_restart(self):
        self.q.capture()
        job=self.jobs('queued')[0]
        (job/'result.pdf').write_bytes(b'')
        self.q.run_once()
        self.assertTrue((self.home/'processed').exists())
        self.assertEqual(len(self.jobs('done')),1)

    def test_corrupt_manifest_does_not_block_other_jobs(self):
        self.q.capture()
        bad=self.jobs('queued')[0]
        (bad/'job.json').write_text('broken')
        self.q.capture()
        self.q.run_once()
        self.assertTrue((self.q.root/'failed'/bad.name).exists())
        self.assertEqual(len(self.jobs('done')),1)

    def test_defaults_are_frozen_when_captured(self):
        self.q.capture()
        import json
        data=json.loads((self.jobs('queued')[0]/'job.json').read_text())
        self.assertEqual(data['settings']['BLANK_THRESHOLD'],'0.96')
        self.assertEqual(data['settings']['SOURCE'],'ADF Duplex')

    def test_running_worker_recovers_new_orphan_capture(self):
        import time, sys
        worker=subprocess.Popen([sys.executable,str(MODULE),'worker'],env=self.env,
                                stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        try:
            deadline=time.monotonic()+5
            while time.monotonic()<deadline:
                with self.q.lock('worker') as acquired:
                    if not acquired:
                        break
                time.sleep(0.05)
            else:
                self.fail('worker did not start')
            orphan=self.q.root/'capturing/interrupted'
            orphan.mkdir()
            deadline=time.monotonic()+5
            while time.monotonic()<deadline and not (self.q.root/'failed/interrupted').exists():
                time.sleep(0.05)
            self.assertTrue((self.q.root/'failed/interrupted').exists())
        finally:
            worker.terminate()
            worker.wait(timeout=10)

    def test_led_snapshot_cannot_recreate_a_completed_capture(self):
        import threading
        self.q.capture()
        job=self.jobs('queued')[0]
        paused=threading.Event(); release=threading.Event(); removed=threading.Event()
        original=self.q.led
        def pause_led(action, job_id=None):
            original(action,job_id)
            if action=='begin' and not paused.is_set():
                paused.set(); release.wait(3)
        self.q.led=pause_led
        reader=threading.Thread(target=self.q.reconcile_led)
        def remove_job():
            self.q.remove(job); removed.set(); self.q.reconcile_led()
        writer=threading.Thread(target=remove_job)
        reader.start()
        self.assertTrue(paused.wait(3))
        writer.start()
        try:
            self.assertFalse(removed.wait(0.1))
        finally:
            release.set()
            reader.join(5); writer.join(5)
        self.assertFalse(reader.is_alive()); self.assertFalse(writer.is_alive())
        events=[line for line in (self.home/'led-events').read_text().splitlines()
                if job.name in line]
        self.assertEqual(events[-1],'end '+job.name)

    def test_partial_capture_cannot_be_retried_as_complete_document(self):
        self.q.env['SCAN_FAIL']='1'
        self.q.capture()
        with self.assertRaises(ValueError):
            self.q.retry(self.jobs('failed')[0].name)

if __name__ == '__main__':
    unittest.main()
