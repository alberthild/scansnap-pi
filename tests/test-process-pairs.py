#!/usr/bin/env python3
"""A removed blank back must not pair two different sheets."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
class PairTest(unittest.TestCase):
    def test_removed_back_keeps_original_sheet_pairs(self):
        with tempfile.TemporaryDirectory() as tmp:
            home=Path(tmp); bindir=home/'bin'; bindir.mkdir()
            job=home/'job'; work=job/'work'; work.mkdir(parents=True)
            for i in (1,2,3): (work/f'page-{i:03d}.jpg').write_text('jpeg')
            scripts={
                'identify': '''case "$*" in
*fx:mean*) case "$*" in *page-002*) echo 0.99;; *) echo 0.5;; esac;;
*) case "$*" in *page-001*) echo '100 400';; *) echo '300 400';; esac;;
esac''',
                'scansnap-normalize-image.sh': 'printf "%s\\n" "$*" >> "$HOME/normalizations"',
                'djpeg': 'echo image', 'cjpeg': 'cat', 'du': 'printf "1000\\tsize\\n"',
                'img2pdf': 'while [ "$1" != -o ]; do shift; done; printf pdf > "$2"',
            }
            for name,body in scripts.items():
                p=bindir/name; p.write_text('#!/bin/bash\n'+body+'\n'); p.chmod(0o755)
            env=dict(os.environ,HOME=tmp,PATH=str(bindir)+':'+os.environ['PATH'])
            result=subprocess.run(['bash',str(ROOT/'pi/bin/scansnap-process.sh'),str(job)],env=env,capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertNotIn('--receipt',(home/'normalizations').read_text())
            self.assertTrue((job/'result.part.pdf').exists())
            self.assertFalse((work/'page-002.jpg').exists())
if __name__=='__main__': unittest.main()
