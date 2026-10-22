#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Exercise the production input batcher against a new in-memory peer; no sockets or app state."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / "Vendor/Glimmer/GlimmerEngine"
with tempfile.TemporaryDirectory(prefix="deskbridge-input-synthetic-") as fixture:
    temporary = Path(fixture)
    executable = temporary / "checks"
    sources = ["Network/InputBatcher.swift", "Network/InputSendThread.swift", "Session/NativeBackend+Input.swift",
               "Protocol/InputEncoder.swift", "Protocol/EnetWire.swift", "Protocol/StreamingBackend+Values.swift",
               "Input/DesktopInputWire.swift"]
    subprocess.run(["/usr/bin/swiftc", "-swift-version", "6", "-package-name", "Glimmer", "-parse-as-library",
                    "-D", "DESKBRIDGE_INPUT_BATCHER_SYNTHETIC_CHECKS", "-module-cache-path", str(temporary / "module-cache"),
                    *[str(ENGINE / name) for name in sources],
                    str(ROOT / "Sources/DeskBridgeChecks/InputBatcherSyntheticChecks.swift"), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
