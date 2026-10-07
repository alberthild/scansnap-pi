#!/usr/bin/env python3
"""Verify scan/upload outcomes reach the optional LED integration."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PipelineLEDTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.bin = self.home / 'bin'
        self.bin.mkdir()
        self.events = self.home / 'events'
        self.script('scansnap-led.sh', 'printf "%s %s\\n" "$1" "$2" >> "$HOME/events"')
        self.config = self.home / 'config.env'
        self.config.write_text('SCANNER_DEVICE=test\nWEBDAV_URL=https://example.com/scans/\n'
                               'WEBDAV_USER=test\nWEBDAV_PASSWORD=test\n'
                               f'SCANSNAP_TMPDIR={self.home}\n')
        self.env = dict(os.environ, HOME=str(self.home), SCANSNAP_CONFIG=str(self.config),
                        SCANSNAP_LED_JOB_ID='scan-test', PATH=f'{self.bin}:{os.environ["PATH"]}')

    def script(self, name, body):
        path = self.bin / name
        path.write_text('#!/usr/bin/env bash\n' + body + '\n')
        path.chmod(0o755)

    def run_pipeline(self, script, *args):
        return subprocess.run(['bash', str(ROOT / 'pi/bin' / script), *map(str, args)],
                              env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def test_configuration_error_sets_error_indicator(self):
        self.config.unlink()
        result = self.run_pipeline('scansnap-upload.sh')
        self.assertEqual(result.returncode, 2)
        self.assertTrue(self.events.exists(), 'scan did not report LED status')
        self.assertEqual(self.events.read_text().splitlines(), ['begin scan-test', 'fail scan-test'])

    def test_empty_feeder_returns_to_ready(self):
        for name in ['identify', 'convert', 'djpeg', 'cjpeg', 'img2pdf', 'curl',
                     'scansnap-upload-bg.sh', 'scansnap-normalize-image.sh', 'logger']:
            self.script(name, 'exit 0')
        self.script('scanimage', 'echo "Document feeder out of documents" >&2; exit 7')
        result = self.run_pipeline('scansnap-upload.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.events.exists(), 'empty scan did not restore LED status')
        events = [line for line in self.events.read_text().splitlines() if not line.startswith('clear')]
        self.assertTrue(events[0].startswith('begin scan-'))
        self.assertEqual(events[-1], events[0].replace('begin ', 'end ', 1))

    def test_upload_success_finishes_job_and_removes_pdf(self):
        pdf = self.home / 'scan.pdf'
        pdf.write_bytes(b'%PDF-test')
        self.script('curl', 'printf 201')
        result = self.run_pipeline('scansnap-upload-bg.sh', pdf)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(pdf.exists())
        self.assertTrue(self.events.exists(), 'upload did not finish LED job')
        self.assertEqual(self.events.read_text().splitlines(), ['end scan-test'])

    def test_failed_upload_sets_error_and_retains_pdf(self):
        pdf = self.home / 'scan.pdf'
        pdf.write_bytes(b'%PDF-test')
        self.script('curl', 'printf 500')
        self.script('sleep', 'exit 0')
        result = self.run_pipeline('scansnap-upload-bg.sh', pdf)
        self.assertEqual(result.returncode, 6, result.stderr)
        self.assertTrue((self.home / 'scansnap-failed/scan.pdf').exists())
        self.assertTrue(self.events.exists(), 'failed upload did not set LED error')
        self.assertEqual(self.events.read_text().splitlines(), ['fail scan-test'])


if __name__ == '__main__':
    unittest.main()
