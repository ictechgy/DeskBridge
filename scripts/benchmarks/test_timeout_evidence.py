#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Regression: a real child timeout must retain partial binary output and a terminal record."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from run import recorded_command


class FailureEvidence(unittest.TestCase):
    def test_timeout_preserves_partial_bytes(self):
        with tempfile.TemporaryDirectory(prefix="deskbridge-timeout-check-", dir="/tmp") as folder:
            root = Path(folder); record = {}
            child = "import os,time; os.write(1,b'partial\\xff\\n'); os.write(2,b'synthetic-stderr\\n'); time.sleep(10)"
            with self.assertRaises(subprocess.TimeoutExpired):
                recorded_command([sys.executable, "-c", child], cwd=root, output=root, label="timeout", record=record, timeout=0.5)
            self.assertEqual((root / "timeout.stdout").read_bytes(), b"partial\xff\n")
            self.assertEqual((root / "timeout.stderr").read_bytes(), b"synthetic-stderr\n")
            self.assertEqual(record["exitCode"], 124)
            self.assertTrue(record["timedOut"])
            self.assertGreaterEqual(record["elapsedSeconds"], 0.5)

    def test_nonzero_exit_stays_distinct(self):
        with tempfile.TemporaryDirectory(prefix="deskbridge-exit-check-", dir="/tmp") as folder:
            root = Path(folder); record = {}
            with self.assertRaises(subprocess.CalledProcessError):
                recorded_command([sys.executable, "-c", "import sys; print('synthetic-failure'); sys.exit(7)"],
                    cwd=root, output=root, label="exit", record=record)
            self.assertEqual(record["exitCode"], 7)
            self.assertNotIn("timedOut", record)
            self.assertEqual((root / "exit.stdout").read_text(), "synthetic-failure\n")


if __name__ == "__main__":
    unittest.main()
