#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Deterministic unprivileged Debian builder, usable on macOS. No install or execution."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile
from build_snapshot import source_snapshot
from linux_check_record import LINUX_PAYLOAD_SOURCES, payload_directories, validate_payload_sources

ROOT = Path(__file__).resolve().parent.parent


def tar(entries, directories=()):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode='w', format=tarfile.USTAR_FORMAT) as archive:
        for name in directories:
            item = tarfile.TarInfo('./' if name == '.' else './' + name + '/')
            item.type, item.mode, item.uid, item.gid, item.mtime = tarfile.DIRTYPE, 0o755, 0, 0, 0
            item.uname = item.gname = 'root'
            archive.addfile(item)
        for name, data, mode in sorted(entries):
            item = tarfile.TarInfo('./' + name)
            item.size, item.mode, item.uid, item.gid, item.mtime = len(data), mode, 0, 0, 0
            item.uname = item.gname = 'root'
            archive.addfile(item, io.BytesIO(data))
    return gzip.compress(output.getvalue(), mtime=0)


def deb(entries, control):
    result = bytearray(b'!<arch>\n')
    for name, data in [('debian-binary', b'2.0\n'), ('control.tar.gz', tar([('control', control, 0o644)])), ('data.tar.gz', tar(entries, payload_directories()))]:
        header = f'{name + "/":<16}{0:<12}{0:<6}{0:<6}{"100644":<8}{len(data):<10}`\n'.encode('ascii')
        assert len(header) == 60
        result.extend(header); result.extend(data)
        if len(data) % 2: result.extend(b'\n')
    return bytes(result)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    before = source_snapshot(ROOT)  # Before VERSION or any package input is consumed.
    version = (ROOT / 'VERSION').read_text().strip()
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[a-zA-Z0-9.]+)?', version): raise SystemExit('Invalid VERSION')
    deb_version = version.replace('-', '~', 1)
    entries = []
    for target, (relative, mode) in LINUX_PAYLOAD_SOURCES.items():
        data = (ROOT / relative).read_bytes()
        if hashlib.sha256(data).hexdigest() != before.get(relative):
            raise SystemExit('Source changed while reading package input')
        entries.append((target, data, mode))
    control = f'''Package: deskbridge-linux-host
Version: {deb_version}
Architecture: amd64
Maintainer: Knot contributors
Section: net
Priority: optional
Depends: python3 (>= 3.12), python3-gi, gir1.2-gtk-3.0, python3-qrcode, python3-pil, iproute2, util-linux, libglib2.0-bin, xdg-utils
Description: Knot native setup for an Ubuntu X11 desktop shared with Mac or Windows
 Logged-in Ubuntu 24.04 amd64 X11 host only. Downloads pinned Sunshine on
 explicit action. No automatic root broker, group grants or autostart.
'''.encode()
    payload = deb(entries, control)
    path = args.output or ROOT / 'build/linux' / ('Knot-' + version + '-linux-amd64.deb')
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)
    if source_snapshot(ROOT) != before: raise SystemExit('Source changed during build')
    record = {'schema': 1, 'version': version, 'sourceManifest': before,
              'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
              'sha256': hashlib.sha256(payload).hexdigest(), 'bytes': len(payload),
              'directories': payload_directories(),
              'sourceEntries': {target: source for target, (source, mode) in LINUX_PAYLOAD_SOURCES.items()},
              'inventory': {name: {'sha256': hashlib.sha256(data).hexdigest(), 'mode': mode} for name, data, mode in entries},
              'scope': 'Debian archive construction only; not an Ubuntu desktop acceptance result'}
    validate_payload_sources(record, record['inventory'])
    path.with_suffix('.build.json').write_text(json.dumps(record, indent=2) + '\n')
    print(path)

if __name__ == '__main__': main()
