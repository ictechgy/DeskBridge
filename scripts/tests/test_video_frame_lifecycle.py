#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Exercise exact decoder lifecycle/latch and shell state with inert codec dependencies."""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / "Vendor/Glimmer/GlimmerEngine"


def block(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    return source[start:end]


lifecycle = (ENGINE / "Video/VideoDecoder+Decode.swift").read_text()
output = (ENGINE / "Video/VideoDecoder+Session.swift").read_text()
presentation = (ROOT / "Sources/DeskBridgeApp/Streaming/DesktopRecoveryPresentation.swift").read_text()
types = (ENGINE / "Models/Types.swift").read_text()
failure = (ENGINE / "Models/StreamFailure.swift").read_text()
failure_copy = (ENGINE / "Models/StreamFailureCopy.swift").read_text()
connection = (ENGINE / "Session/StreamConnection.swift").read_text()
takeover = (ENGINE / "Session/StreamSession+Attempt.swift").read_text()
constants = "\n".join(re.findall(r"^    package static let (?:deadPeer|protectedContent|frameConversion|noVideoTraffic|noVideoFrame)TerminationCode[^\n]*",
    (ENGINE / "Session/StreamSession.swift").read_text() + "\n" +
    (ENGINE / "Session/StreamSession+FrameWatchdog.swift").read_text(), re.M))
assert len(constants.splitlines()) == 5
model_contract = "\n".join([
    block(types, "public enum StreamEvent:"), block(types, "public enum ConnectionQuality:"),
    block(types, "public enum StreamError:"), failure, failure_copy,
    "enum StreamSession {\n" + constants + "\n}",
    "public enum StreamConnection {\n" + block(connection, "public enum Failure:") + "\n}",
    block(takeover, "package struct TakeoverRequired:"),
    "public enum StreamInput { public enum Event: Sendable {} }",
])
methods = "\n".join(block(lifecycle, "nonisolated func " + name + "()")
                    for name in ("handleStart", "handleStop", "handleCleanup"))
gate = block(output, "if !decoder.didFireFirstDecodedFrame")
fixture = r'''
import Foundation
import Synchronization

// No VT session, native backend, display, socket, preferences or media exists.
struct SilentLog: Sendable { func info(_ value: String) {} }
let log = SilentLog()
func VTDecompressionSessionInvalidate(_ session: Int) {}
final class Stats: @unchecked Sendable { func resetForConnection() {} }
__ACTUAL_MODEL_CONTRACT__
final class VideoDecoder: @unchecked Sendable {
    var isStreaming = false
    var didFireFirstDecodedFrame = false
    let firstFrameLifecycleGeneration = Atomic<UInt64>(0)
    let decodeQueue = DispatchQueue(label: "synthetic.decoder.lifecycle")
    let statsCollector = Stats()
    var decompressionSession: Int? = 1
    var formatDescription: Int?, cachedHDRFormatDescription: Int?
    var spsData: Data?, ppsData: Data?, vpsData: Data?
    let inFlightDecodeLock = NSLock()
    var inFlightDecodes = 3
    var lastVtDecodeFailed = true
    var schedules = 0
    var onFirstDecodedFrame: (() -> Void)?
    @MainActor func configureLayerColorspace() {}
    func reapplySuppressionAtConnect() {}
    func clearDecodeGateForConnectionStop() {}
    func releaseOutputCallbackRefcon() {}
    static func noteFirstDecodedFrameTelemetry() {}
    func scheduleFirstDecodedFrame() { schedules += 1; onFirstDecodedFrame?() }
    func syntheticDecodedFrame() {
        guard isStreaming else { return }
        let decoder = self
        __ACTUAL_FIRST_FRAME_GATE__
    }
    __ACTUAL_LIFECYCLE_METHODS__
}
__ACTUAL_PRESENTATION__
@main struct Checks {
    @MainActor static func main() throws {
        var checks = 0
        func expect(_ value: Bool) throws {
            guard value else { throw NSError(domain: "synthetic first-frame lifecycle", code: checks) }
            checks += 1
        }
        let decoder = VideoDecoder()
        var state = DesktopRecoveryPresentation()
        decoder.onFirstDecodedFrame = { state.receive(.firstFrame) }
        for attempt in 1...3 {
            decoder.handleStart()
            try expect(decoder.isStreaming && !decoder.didFireFirstDecodedFrame)
            if attempt > 1 {
                state.receive(.reconnected)
                try expect(state.phase == .waiting)
            }
            decoder.syntheticDecodedFrame(); decoder.syntheticDecodedFrame()
            try expect(decoder.schedules == attempt)
            try expect(state.phase == .live && state.message == nil)
            decoder.handleStop(); decoder.handleCleanup()
            try expect(!decoder.isStreaming && decoder.inFlightDecodes == 0 && !decoder.lastVtDecodeFailed)
            try expect(decoder.firstFrameLifecycleGeneration.load(ordering: .acquiring) == UInt64(attempt))
            if attempt < 3 { state.receive(.reconnecting) }
        }
        print("{\"status\":\"passed\",\"videoFrameLifecycleChecks\":\(checks),\"firstFrameSchedules\":\(decoder.schedules),\"scope\":\"exact production lifecycle methods, first-frame latch and shell state; inert codec/platform; no VT/native/UI/network\"}")
    }
}
'''
fixture = fixture.replace("__ACTUAL_FIRST_FRAME_GATE__", gate).replace("__ACTUAL_LIFECYCLE_METHODS__", methods)
fixture = fixture.replace("__ACTUAL_MODEL_CONTRACT__", model_contract)
fixture = fixture.replace("__ACTUAL_PRESENTATION__", presentation.replace("import GlimmerEngine\n", ""))
with tempfile.TemporaryDirectory(prefix="deskbridge-decoder-lifecycle-", dir="/tmp") as directory:
    temporary = Path(directory)
    source = temporary / "Checks.swift"
    source.write_text(fixture)
    executable = temporary / "checks"
    subprocess.run(["/usr/bin/swiftc", "-swift-version", "6", "-package-name", "Glimmer", "-parse-as-library", "-O",
                    "-module-cache-path", str(temporary / "module-cache"), str(source), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
    print(json.dumps({"fixtureSHA256": hashlib.sha256(fixture.encode()).hexdigest(),
                      "scope": "source-extracted regression, not device or video acceptance"}))
