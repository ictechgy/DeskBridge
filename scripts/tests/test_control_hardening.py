#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Compile the production control/PEM/client slice with fresh offline dependency fixtures."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / "Vendor/Glimmer/GlimmerEngine"


with tempfile.TemporaryDirectory(prefix="deskbridge-control-synthetic-") as fixture:
    temporary = Path(fixture)
    executable = temporary / "checks"
    subprocess.run(["/usr/bin/swiftc", "-swift-version", "6", "-package-name", "Glimmer", "-parse-as-library",
                    "-D", "DESKBRIDGE_CONTROL_SYNTHETIC_CHECKS", "-module-cache-path", str(temporary / "module-cache"),
                    str(ENGINE / "Network/Network.swift"), str(ENGINE / "Network/ControlTransport.swift"),
                    str(ENGINE / "Network/PEM.swift"), str(ENGINE / "Network/NetworkClient+Endpoints.swift"),
                    str(ENGINE / "Network/NetworkClient+Request.swift"), str(ENGINE / "Network/Network+Support.swift"),
                    str(ENGINE / "Network/StreamAttempt.swift"), str(ENGINE / "Network/Pairing.swift"),
                    str(ENGINE / "Network/Pairing+Crypto.swift"), str(ENGINE / "Network/PairingFailure.swift"),
                    str(ROOT / "Sources/DeskBridgeChecks/ControlHardeningSyntheticChecks.swift"), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
    replay = temporary / "replay-checks"
    replay_sources = ["Protocol/StreamCrypto.swift", "Protocol/EnetWire.swift", "Diagnostics/AtomicCounter.swift",
                      "Network/EnetControlChannel.swift", "Network/EnetControlChannel+Inbound.swift",
                      "Network/EnetControlChannel+Send.swift", "Network/EnetControlChannel+ControlMessages.swift"]
    subprocess.run(["/usr/bin/swiftc", "-swift-version", "6", "-package-name", "Glimmer", "-parse-as-library",
                    "-target", "arm64-apple-macosx26.0", "-D", "DESKBRIDGE_CONTROL_REPLAY_SYNTHETIC_CHECKS",
                    "-module-cache-path", str(temporary / "module-cache"),
                    *[str(ENGINE / name) for name in replay_sources],
                    str(ROOT / "Sources/DeskBridgeChecks/ControlReplaySyntheticChecks.swift"), "-o", str(replay)], check=True)
    subprocess.run([str(replay)], check=True)
