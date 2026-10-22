#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Convert the approved master PNG into native app icon containers with macOS tools."""
from pathlib import Path
import struct, subprocess, tempfile

ROOT = Path(__file__).resolve().parent.parent
BRAND = ROOT / 'Assets/Brand'

if __name__ == '__main__':
    master = BRAND / 'nearby-panes.png'
    with tempfile.TemporaryDirectory(prefix='deskbridge-icons-') as directory:
        iconset = Path(directory) / 'AppIcon.iconset'
        iconset.mkdir()
        for points in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                pixels = points * scale
                suffix = '@2x' if scale == 2 else ''
                subprocess.run(['/usr/bin/sips', '-z', str(pixels), str(pixels), str(master), '--out',
                                str(iconset / ('icon_' + str(points) + 'x' + str(points) + suffix + '.png'))],
                               check=True, stdout=subprocess.PIPE)
        subprocess.run(['/usr/bin/iconutil', '-c', 'icns', str(iconset), '-o', str(BRAND / 'AppIcon.icns')], check=True)
        images = [(size, (iconset / ('icon_' + str(size) + 'x' + str(size) + '.png')).read_bytes()) for size in (16, 32, 128, 256)]
        # ICO's PNG entries preserve the original alpha; no pixel data is rewritten here.
        header = struct.pack('<HHH', 0, 1, len(images))
        offset = 6 + 16 * len(images)
        entries = bytearray()
        for size, data in images:
            dimension = 0 if size == 256 else size
            entries.extend(struct.pack('<BBBBHHII', dimension, dimension, 0, 0, 1, 32, len(data), offset))
            offset += len(data)
        (BRAND / 'AppIcon.ico').write_bytes(header + entries + b''.join(data for _, data in images))
