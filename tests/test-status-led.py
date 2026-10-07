#!/usr/bin/env python3
"""Verify visible status, including overlapping scan/upload jobs."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

HELPER = Path(__file__).resolve().parents[1] / 'pi/libexec/scansnap-status-led.py'


class StatusLEDTest(unittest.TestCase):
    def setUp(self):
        self.assertTrue(HELPER.exists(), 'LED status helper is missing')
        spec = importlib.util.spec_from_file_location('status_led', HELPER)
        self.helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.helper)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.helper.STATE_DIR = root / 'state'
        self.helper.LED_DIR = root / 'led'
        self.helper.LED_DIR.mkdir()
        for name, value in [('trigger', 'mmc0'), ('brightness', '0'),
                            ('max_brightness', '1'), ('delay_on', '0'), ('delay_off', '0')]:
            (self.helper.LED_DIR / name).write_text(value)

    def read(self, name):
        return (self.helper.LED_DIR / name).read_text().strip()

    def test_idle_is_solid_and_active_job_blinks(self):
        self.helper.update('init')
        self.assertEqual(self.read('trigger'), 'none')
        self.assertEqual(self.read('brightness'), '1')
        self.helper.update('begin', 'scan-10')
        self.assertEqual(self.read('trigger'), 'timer')
        self.assertEqual(self.read('delay_on'), '700')
        self.helper.update('end', 'scan-10')
        self.assertEqual(self.read('trigger'), 'none')
        self.assertEqual(self.read('brightness'), '1')

    def test_one_finished_upload_does_not_hide_another_active_scan(self):
        self.helper.update('begin', 'scan-10')
        self.helper.update('begin', 'scan-11')
        self.helper.update('end', 'scan-10')
        self.assertEqual(self.read('trigger'), 'timer')
        self.helper.update('end', 'scan-11')
        self.assertEqual(self.read('trigger'), 'none')

    def test_failure_stays_visible_until_explicit_clear(self):
        self.helper.update('begin', 'scan-10')
        self.helper.update('begin', 'scan-11')
        self.helper.update('fail', 'scan-10')
        self.assertEqual(self.read('delay_on'), '100')
        self.helper.update('end', 'scan-11')
        self.assertEqual(self.read('trigger'), 'timer')
        self.assertEqual(self.read('delay_on'), '100')
        self.helper.update('begin', 'scan-12')
        self.assertEqual(self.read('delay_on'), '100')
        self.helper.update('clear')
        self.assertEqual(self.read('delay_on'), '700')

    def test_invalid_job_cannot_write_outside_state_directory(self):
        with self.assertRaises(ValueError):
            self.helper.update('begin', '../escape')
        self.assertFalse((Path(self.tmp.name) / 'escape').exists())


if __name__ == '__main__':
    unittest.main()
