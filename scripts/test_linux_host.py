#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Linux-only checks for an exact-source package, using new synthetic fixtures."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import tarfile
import unittest
sys.dont_write_bytecode = True
from linux_check_record import validate_payload_sources, payload_directories
ROOT = Path(__file__).resolve().parent.parent


def archive_inventory(data):
    if not data.startswith(b'!<arch>\n'): raise ValueError('Not a Debian ar archive')
    offset, members = 8, {}
    while offset < len(data):
        header = data[offset:offset + 60]
        if len(header) != 60 or header[-2:] != b'`\n': raise ValueError('Invalid ar header')
        size, name = int(header[48:58]), header[:16].decode().strip().rstrip('/')
        if name in members or size < 0 or offset + 60 + size > len(data): raise ValueError('Invalid ar entry')
        members[name] = data[offset + 60:offset + 60 + size]; offset += 60 + size + size % 2
    if set(members) != {'debian-binary', 'control.tar.gz', 'data.tar.gz'} or members['debian-binary'] != b'2.0\n': raise ValueError('Unexpected Debian members')
    result, directories, seen = {}, set(), set()
    with tarfile.open(fileobj=io.BytesIO(members['data.tar.gz'])) as archive:
        for entry in archive:
            name = entry.name.rstrip('/')
            canonical = '.' if name == '.' else name[2:] if name.startswith('./') else None
            expected_name = '.' if canonical == '.' else './' + str(Path(canonical)) if canonical is not None else ''
            if canonical is None or name != expected_name or entry.name not in (name, name + '/' if entry.isdir() else name) or '..' in Path(canonical).parts or entry.uid != 0 or entry.gid != 0 or canonical in seen:
                raise ValueError('Unexpected package payload')
            seen.add(canonical)
            if entry.isdir():
                if entry.mode != 0o755 or canonical not in payload_directories(): raise ValueError('Unexpected directory')
                directories.add(canonical)
            elif entry.isfile() and canonical.startswith('usr/'):
                if str(Path(canonical).parent) not in directories: raise ValueError('Directory must precede its files')
                result[canonical] = {'sha256': hashlib.sha256(archive.extractfile(entry).read()).hexdigest(), 'mode': entry.mode}
            else: raise ValueError('Unexpected package payload type')
    if directories != set(payload_directories()): raise ValueError('Missing package directories')
    with tarfile.open(fileobj=io.BytesIO(members['control.tar.gz'])) as archive:
        entries = archive.getmembers()
        if len(entries) != 1 or entries[0].name != './control' or not entries[0].isfile(): raise ValueError('Unexpected installer hooks')
    return result


def installation_check(package, inventory):
    # Only this script's validated package (no maintainer scripts) in a NEW inert root.
    with tempfile.TemporaryDirectory(prefix='deskbridge-install-fixture-') as temporary:
        root = Path(temporary) / 'root'; root.mkdir()
        common = ['/usr/bin/dpkg', '--root=' + str(root), '--log=' + str(Path(temporary) / 'dpkg.log'),
                  '--force-not-root', '--force-script-chrootless', '--force-depends', '--no-triggers',
                  # Container dpkg defaults can exclude documentation; verify ours too.
                  '--path-include=/usr/share/doc/deskbridge-linux-host', '--path-include=/usr/share/doc/deskbridge-linux-host/*']
        subprocess.run(common + ['--install', str(package.resolve())], check=True, capture_output=True, timeout=30)
        for name, expected in inventory.items():
            path = root / name
            if path.is_symlink() or not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected['sha256'] or path.stat().st_mode & 0o777 != expected['mode']:
                raise ValueError('Installed payload differs from archive: ' + name)
        subprocess.run(common + ['--remove', 'deskbridge-linux-host'], check=True, capture_output=True, timeout=30)
        if any((root / name).exists() for name in inventory): raise ValueError('Package removal retained an installed file')
        if (root / 'usr/lib/deskbridge-linux').exists() or (root / 'usr/share/doc/deskbridge-linux-host').exists():
            raise ValueError('Package removal retained owned directories')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--record', type=Path)
    args = parser.parse_args()
    if sys.platform != 'linux' or platform.freedesktop_os_release().get('VERSION_ID') != '24.04' or platform.freedesktop_os_release().get('ID') != 'ubuntu':
        raise SystemExit('Run checks in a fresh Ubuntu 24.04 environment; no actual desktop or Sunshine is launched')
    package = args.package
    build = json.loads(package.with_suffix('.build.json').read_text())
    data = package.read_bytes()
    if hashlib.sha256(data).hexdigest() != build['sha256'] or archive_inventory(data) != build['inventory']:
        raise SystemExit('Package changed after build')
    validate_payload_sources(build, archive_inventory(data))
    # Explicit source copies must match the immutable manifest from the builder.
    sources = [ROOT / 'scripts/test_linux_host.py', ROOT / 'scripts/linux_check_record.py'] + sorted((ROOT / 'host/linux').rglob('*'))
    for path in sources:
        if path.is_file():
            if path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != build['sourceManifest'].get(path.relative_to(ROOT).as_posix()):
                raise SystemExit('Fixture source differs from package build')
    metadata = subprocess.run(['/usr/bin/dpkg-deb', '--info', str(package)], capture_output=True, check=True, timeout=10).stdout.decode()
    if 'deskbridge-linux-host' not in metadata: raise SystemExit('Debian metadata invalid')
    installation_check(package, build['inventory'])
    # Import bindings without initializing GTK, opening a screen or launching the application.
    import gi
    gi.require_version('Gtk', '3.0')
    from gi.repository import Gtk
    import qrcode
    from PIL import Image
    suite = unittest.defaultTestLoader.discover(str(ROOT / 'host/linux/tests'), pattern='test_*.py')
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful() or result.skipped: raise SystemExit('Linux fixture checks failed or skipped')
    record = {'schema': 1, 'status': 'passed', 'platform': 'ubuntu-24.04', 'machine': platform.machine(),
              'sha256': build['sha256'], 'sourceManifest': build['sourceManifest'], 'testsRun': result.testsRun,
              'gtkBindingsImported': True, 'dpkgMetadataValidated': True, 'inventoryValidated': True,
              'installationTested': True, 'removalTested': True,
              'scope': 'fresh inert files, download response fixtures and owned inert child processes; no Sunshine, UI, capture, input, audio or network session'}
    target = args.record or package.with_suffix('.checks.json')
    target.write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps({k: v for k, v in record.items() if k != 'sourceManifest'}))

if __name__ == '__main__': main()
