# SPDX-License-Identifier: GPL-3.0-only
"""Package race/tamper regressions using only newly generated source fixtures."""
import contextlib
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_linux_host as builder
from linux_check_record import LINUX_PAYLOAD_SOURCES, validate_payload_sources
from test_linux_host import archive_inventory


class LinuxBuildProvenance(unittest.TestCase):
    def fixture(self, root):
        for source, mode in LINUX_PAYLOAD_SOURCES.values():
            path = root / source; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(('synthetic ' + source).encode())
        (root / 'VERSION').write_text('0.2.0-preview.12\n')
    def snapshot(self, root):
        files = {'VERSION'} | {source for source, mode in LINUX_PAYLOAD_SOURCES.values()}
        result = {}
        for name in files:
            with (root / name).open('rb') as stream: result[name] = hashlib.sha256(stream.read()).hexdigest()
        return result
    def run_builder(self, root):
        with patch.object(builder, 'ROOT', root), patch.object(builder, 'source_snapshot', self.snapshot), \
             patch.object(builder.subprocess, 'check_output', return_value='f' * 40), \
             patch.object(sys, 'argv', ['build_linux_host.py', '--output', str(root / 'out/Linux.deb')]), contextlib.redirect_stdout(io.StringIO()):
            builder.main()
    def test_package_entries_bound_to_source_manifest(self):
        with tempfile.TemporaryDirectory(prefix='deskbridge-linux-package-fixture-') as temporary:
            root = Path(temporary); self.fixture(root); self.run_builder(root)
            record = json.loads((root / 'out/Linux.build.json').read_text())
            inventory = archive_inventory((root / 'out/Linux.deb').read_bytes())
            validate_payload_sources(record, inventory)
            target = 'usr/lib/deskbridge-linux/policy.py'
            record['sourceManifest']['host/linux/policy.py'] = '0' * 64
            with self.assertRaises(ValueError): validate_payload_sources(record, inventory)
    def test_file_only_archive_and_missing_directory_record_are_rejected(self):
        with tempfile.TemporaryDirectory(prefix='deskbridge-no-directories-fixture-') as temporary:
            root = Path(temporary); self.fixture(root)
            original = builder.tar
            with patch.object(builder, 'tar', side_effect=lambda entries, directories=(): original(entries)):
                self.run_builder(root)
            data = (root / 'out/Linux.deb').read_bytes()
            with self.assertRaises(ValueError): archive_inventory(data)

    def test_source_mutation_after_consumption_cannot_complete_build(self):
        with tempfile.TemporaryDirectory(prefix='deskbridge-linux-package-race-') as temporary:
            root = Path(temporary); self.fixture(root)
            original = Path.read_bytes
            mutated = False
            def read(path):
                nonlocal mutated
                data = original(path)
                if path == root / 'host/linux/policy.py' and not mutated:
                    mutated = True; path.write_bytes(data + b'\nchanged after read')
                return data
            with patch.object(Path, 'read_bytes', read), self.assertRaises(SystemExit): self.run_builder(root)
            self.assertTrue(mutated)
            self.assertFalse((root / 'out/Linux.build.json').exists())
