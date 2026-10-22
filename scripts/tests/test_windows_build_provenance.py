#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Pure synthetic notice provenance tests; no compiler or Windows process runs."""
from pathlib import Path
import hashlib
import json
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from build_windows_launcher import verify_runtime_notices


class RuntimeNotices(unittest.TestCase):
    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory(prefix='deskbridge-runtime-notices-')
        self.root = Path(self.fixture.name)
        self.vendor = self.root / 'Vendor/WindowsRuntime'
        self.vendor.mkdir(parents=True)
        self.texts = {'Zig-LICENSE': b'Synthetic Zig notice\n', 'Mingw-COPYING': b'Synthetic CRT notice\n'}
        self.pins = {name: hashlib.sha256(data).hexdigest() for name, data in self.texts.items()}
        for name, data in self.texts.items():
            (self.vendor / name).write_bytes(data)
        (self.vendor / 'NOTICE').write_bytes(b'Fixture notice\n' + b'\n'.join(self.texts.values()))
        self.write_pins()

    def tearDown(self):
        self.fixture.cleanup()

    def write_pins(self):
        (self.vendor / 'UPSTREAM.json').write_text(json.dumps({'files': self.pins}))

    def test_actual_verifier_accepts_matching_notice_sources(self):
        hashes = verify_runtime_notices(self.root)
        self.assertEqual(set(hashes), {'Zig-LICENSE', 'Mingw-COPYING', 'NOTICE'})
        self.assertEqual(hashes['Zig-LICENSE'], self.pins['Zig-LICENSE'])

    def test_modified_upstream_text_is_rejected(self):
        (self.vendor / 'Zig-LICENSE').write_bytes(b'changed')
        with self.assertRaises(ValueError):
            verify_runtime_notices(self.root)

    def test_missing_notice_block_is_rejected(self):
        (self.vendor / 'NOTICE').write_bytes(self.texts['Zig-LICENSE'])
        with self.assertRaises(ValueError):
            verify_runtime_notices(self.root)

    def test_unknown_inventory_is_rejected(self):
        self.pins['outside'] = '0' * 64
        self.write_pins()
        with self.assertRaises(ValueError):
            verify_runtime_notices(self.root)

    def test_bad_recorded_digest_is_rejected(self):
        self.pins['Mingw-COPYING'] = '0' * 64
        self.write_pins()
        with self.assertRaises(ValueError):
            verify_runtime_notices(self.root)


if __name__ == '__main__':
    unittest.main()
