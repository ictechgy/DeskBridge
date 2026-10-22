# SPDX-License-Identifier: GPL-3.0-only
"""Reject release inventories the installed Windows runtime cannot consume."""
from pathlib import Path
import json
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from reverse_client import engine_inputs

ROOT = Path(__file__).resolve().parents[2]


class ReverseInventoryChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="deskbridge-inventory-check-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.directory = self.root / "client/windows"
        self.directory.mkdir(parents=True)
        self.pin = json.loads((ROOT / "client/windows/MoonlightDependency.json").read_text())
        self.entry = {"sha256": "a" * 64, "bytes": 1}
        self.files = {"Moonlight.exe": self.entry, "portable.dat": self.entry}

    def validate(self, files):
        (self.directory / "MoonlightDependency.json").write_text(json.dumps(self.pin))
        (self.directory / "MoonlightFiles.json").write_text(json.dumps(files))
        return engine_inputs(self.root)

    def test_reviewed_manifest(self):
        files = json.loads((ROOT / "client/windows/MoonlightFiles.json").read_text())
        self.assertEqual(len(self.validate(files)[1]), 284)

    def test_inventory_bounds(self):
        for files in [
            {**self.files, **{"file-%d" % i: self.entry for i in range(511)}},
            {**self.files, "huge.dll": {**self.entry, "bytes": 64 * 1024 * 1024 + 1}},
            {**self.files, **{"big-%d" % i: {**self.entry, "bytes": 64 * 1024 * 1024} for i in range(3)}},
        ]:
            with self.subTest(files=len(files)), self.assertRaises(ValueError):
                self.validate(files)

    def test_runtime_filename_contract(self):
        for name in ["a" * 241, "folder/COM0.dll", "LPT9", "NUL.txt", "trailing.",
                     "folder /file", "a+b.dll", "한글.dll", "a//b", "a/./b", "a/../b"]:
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.validate({**self.files, name: self.entry})

    def test_file_directory_collision(self):
        with self.assertRaises(ValueError):
            self.validate({**self.files, "folder": self.entry, "folder/child": self.entry})


if __name__ == "__main__":
    unittest.main()
