#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Exercise production receive/drain/CBC methods with inert, newly created fixtures.

No sockets, codec, preferences, devices or existing media are opened. Queue/FEC
bookkeeping is real; the unexercised RS decoder and display are inert stand-ins.
"""
from pathlib import Path
import hashlib
import json
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


audio_receive = (ENGINE / "Network/RtpAudioReceiver+Receive.swift").read_text()
audio_decrypt = (ENGINE / "Network/RtpAudioReceiver+Decrypt.swift").read_text()
video = (ENGINE / "Network/VideoRtpReceiver.swift").read_text()
pipeline = (ENGINE / "Session/NativeBackend+Pipeline.swift").read_text()
backend = (ENGINE / "Session/NativeBackend.swift").read_text()

# Bind the extracted methods to their real production consumers as well as
# executing them. These checks prevent an unused fixed helper from passing.
assert audio_receive.index("!acceptsAudioPayload") < audio_receive.index("queue.addPacket")
assert "self?.publishReceiveFailure(receiveFailure, callback: onReceiveFailed)" in audio_receive
assert "if receiveFailed { self?.publishReceiveFailure(callback: onReceiveFailed) }" in video
assert "if receiveFailed { onReceiveFailed?() }" not in video
assert "events.audioFailed(\"audio receive failed (errno " in pipeline

fixture = r'''
import Foundation
import Darwin
import Synchronization
import CommonCrypto

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func use<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body(&value)
    }
}
final class Flag: @unchecked Sendable {
    let state = Locked(false)
    var isSet: Bool { state.use { $0 } }
    func set() { state.use { $0 = true } }
}
let sleeps = Locked<[useconds_t]>([])
@discardableResult func usleep(_ delay: useconds_t) -> Int32 {
    sleeps.use { $0.append(delay) }; return 0
}
final class Script: @unchecked Sendable {
    let errors: Locked<[Int32]>
    let entered = DispatchSemaphore(value: 0)
    let release: DispatchSemaphore?
    init(_ errors: [Int32], parked: Bool = false) {
        self.errors = Locked(errors)
        release = parked ? DispatchSemaphore(value: 0) : nil
    }
    func next() -> Int32 {
        entered.signal(); release?.wait()
        return errors.use { $0.isEmpty ? EIO : $0.removeFirst() }
    }
}
let script = Locked(Script([EIO]))
final class DatagramBatch {
    let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: 1500)
    let activeScript: Script
    init(capacity: Int, stride: Int) { activeScript = script.use { $0 } }
    deinit { storage.deallocate() }
    func receiveOne(from: Int32) -> Int { errno = activeScript.next(); return -1 }
    func datagram(_ index: Int) -> (bytes: UnsafeMutablePointer<UInt8>, length: Int) { (storage, 0) }
    func isExpectedPeer(at: Int, expected: Int, expectedLength: Int) -> Bool { true }
}
struct ReceiveTiming {
    enum Kind { case audio }
    init(telemetry: Kind) {}
    mutating func note(_ batch: DatagramBatch, index: Int, count: Int, socket: Int32, stream: String) {}
}
enum UdpPinger { static func noteForeignPeer(_ noted: inout Bool, stream: String, category: String) {} }
final class Worker: @unchecked Sendable {
    let idle = Locked(0)
    func enqueue(_ bytes: [UInt8], count: Int, arrival: UInt64) { idle.use { $0 += 1 } }
    func enqueue(_ bytes: UnsafeRawBufferPointer, count: Int, arrival: UInt64) {}
}
final class Counter: @unchecked Sendable { func increment() {} }
final class TelemetryCounters: Sendable {
    static let shared = TelemetryCounters()
    let audioFecMismatchTotal = Counter()
}
enum AudioDiagnostics {
    static func warn(_ message: String, _ category: String) {}
    static func notice(_ message: String, _ category: String) {}
}
struct AudioFecDecoder { func recover(_ block: RtpAudioQueue.FecBlock) -> Bool { false } }
struct TransportRoute: Sendable { static let shared = TransportRoute(); let streamLink = "wired" }
final class RtpAudioReceiver: @unchecked Sendable {
    static let maxPacketSize = 1400
    static let cat = "synthetic.audio"
    let fd: Int32 = -1
    let destAddr = 0, destAddrLen = 0
    let recvQueue = DispatchQueue(label: "synthetic.audio.receive")
    let interrupted = Flag()
    let decodeWorker = Worker()
    var onReceiveFailed: (@Sendable (Int32) -> Void)?
    var audioEncryption = true
    let aesKey = [UInt8](repeating: 0x42, count: 16)
    let avRiKeyId: UInt32 = 0x01020304
    var decryptScratch = [UInt8](repeating: 0, count: 1416)
    let queue = RtpAudioQueue(audioPacketDuration: 5)
    func noteAudioArrivalGap(now: UInt64) {}
    __AUDIO_METHODS__
}
enum StreamProtocol { static let FRAME_TYPE_IDR = 1; static let DR_NEED_IDR: Int32 = -1 }
struct DecodeUnit: Sendable {
    let frameType = 0, rtpTimestamp = 0, frameNumber = 0
    let receiveTimeUs: UInt64 = 0, enqueueTimeUs: UInt64 = 0
    let fullLength = 0, frameHostProcessingLatency = 0
}
final class Sink: @unchecked Sendable {
    let submissions = Locked(0)
    func submitDecodeUnit(_ unit: DecodeUnit) -> Int32 { submissions.use { $0 += 1 }; return 0 }
}
struct Episode { var isOpen = false }
struct Depacketizer { func requestDecoderRefresh() {} }
final class FrameTimingTracker: Sendable {
    static let shared: FrameTimingTracker? = nil
    func recordAssembled(rtpTimestamp: Int, frameIndex: Int, receiveNanos: UInt64,
        assembleNanos: UInt64, frameBytes: Int, isIDR: Bool, hostEncodeTenthsMs: Int) {}
}
enum Diag {
    static func info(_ message: String, _ category: String) {}
    static func warn(_ message: String, _ category: String) {}
}
final class VideoRtpReceiver: @unchecked Sendable {
    static let cat = "synthetic.video"
    let interrupted = Atomic<Bool>(false)
    let recvQueue = DispatchQueue(label: "synthetic.video.receive")
    let sink: Sink?
    var lossEpisode = Episode()
    let depacketizer = Depacketizer()
    init(sink: Sink) { self.sink = sink }
    func noteKeyFrame(_ unit: DecodeUnit, tracker: FrameTimingTracker) {}
    func closeLossEpisode(at unit: DecodeUnit, isIDR: Bool) {}
    func isExpectedPostGateResync(isIDR: Bool) -> Bool { false }
    __VIDEO_METHODS__
}
final class LeafResource: @unchecked Sendable {
    func stop() {}
    func interrupt() {}
    func close() {}
}
final class LifecycleSink: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let cleanups = Locked(0)
    var onCleanup: (@Sendable () -> Void)?
    func stop() {}
    func cleanup() {
        cleanups.use { $0 += 1 }; onCleanup?(); entered.signal(); release.wait()
    }
}
final class NativeBackend: @unchecked Sendable {
    static let logCategory = "synthetic.backend"
    let stateLock = NSLock()
    let teardownLock = NSRecursiveLock()
    var interrupted = false, inputReady = true
    var enetChannel: LeafResource?, rtspClient: LeafResource?, audioReceiver: LeafResource?
    var audioSink: LeafResource?, inputBatcher: LeafResource?
    var videoReceiver: VideoRtpReceiver?
    var videoSink: LifecycleSink?
    __BACKEND_METHODS__
}
func encrypt(_ bytes: [UInt8], receiver: RtpAudioReceiver, sequence: UInt16, padding: Bool) -> [UInt8] {
    var iv = ((receiver.avRiKeyId &+ UInt32(sequence)).bigEndian, UInt32(0), UInt32(0), UInt32(0))
    var output = [UInt8](repeating: 0, count: bytes.count + 16)
    var moved = 0
    let status = bytes.withUnsafeBytes { input in
        receiver.aesKey.withUnsafeBytes { key in
            withUnsafeBytes(of: &iv) { ivBytes in
                output.withUnsafeMutableBytes { destination in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                        padding ? CCOptions(kCCOptionPKCS7Padding) : 0, key.baseAddress,
                        key.count, ivBytes.baseAddress, input.baseAddress, input.count,
                        destination.baseAddress, destination.count, &moved)
                }
            }
        }
    }
    precondition(status == kCCSuccess)
    return Array(output[..<moved])
}
func packet(_ payload: [UInt8], sequence: UInt16) -> [UInt8] {
    [0x80, 97, UInt8(sequence >> 8), UInt8(truncatingIfNeeded: sequence),
     0, 0, 0, UInt8(truncatingIfNeeded: sequence * 5), 0, 0, 0, 1] + payload
}
@main struct Checks {
    static func main() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else { throw NSError(domain: label, code: checks) }; checks += 1
        }
        func wait(_ signal: DispatchSemaphore, _ label: String) throws {
            try expect(signal.wait(timeout: .now() + 3) == .success, label)
        }

        // Real CBC and real queue bookkeeping: bad in-order padding cannot
        // consume the sequence, so its valid retransmission still plays.
        let audio = RtpAudioReceiver()
        let seedCipher = encrypt([0x11, 0x22, 0x33], receiver: audio, sequence: 0, padding: true)
        let seed = packet(seedCipher, sequence: 0)
        try expect(audio.acceptsAudioPayload(seed, count: seed.count), "valid baseline payload")
        _ = audio.queue.addPacket(seed, rtp: RtpAudioQueue.RtpHeader(header: 0x80,
            packetType: 97, sequenceNumber: 0, timestamp: 0, ssrc: 1))
        try expect(audio.queue.nextRtpSequenceNumber == 4, "start on first whole block")
        for sequence in UInt16(4)...UInt16(6) {
            let bad = packet(encrypt([UInt8](repeating: 0, count: 16), receiver: audio,
                                     sequence: sequence, padding: false), sequence: sequence)
            let before = audio.queue.nextRtpSequenceNumber
            try expect(!audio.acceptsAudioPayload(bad, count: bad.count), "bad padding at every cursor")
            try expect(audio.queue.nextRtpSequenceNumber == before, "invalid payload leaves cursor")
            let cipher = encrypt([0x11, 0x22, 0x33], receiver: audio, sequence: sequence, padding: true)
            let valid = packet(cipher, sequence: sequence)
            try expect(audio.acceptsAudioPayload(valid, count: valid.count), "valid ciphertext admitted")
            let header = RtpAudioQueue.RtpHeader(header: 0x80, packetType: 97,
                sequenceNumber: sequence, timestamp: UInt32(sequence) * 5, ssrc: 1)
            try expect(audio.queue.addPacket(valid, rtp: header) == .handleNow, "valid packet follows rejected packet")
            try expect(audio.queue.nextRtpSequenceNumber == sequence + 1, "valid queue advances once")
            try expect(Array(audio.queue.blocks[0].dataShards[Int(sequence % 4)].prefix(cipher.count)) == cipher,
                       "FEC retains original ciphertext")
        }
        let runt = packet([1, 2, 3], sequence: 3)
        try expect(!audio.acceptsAudioPayload(runt, count: runt.count), "misaligned encrypted packet rejected")
        audio.audioEncryption = false
        try expect(audio.acceptsAudioPayload(runt, count: runt.count), "legacy plaintext format unchanged")

        // Run the exact production receive loop against scripted syscall
        // results; no real descriptor/socket exists.
        let runtimeAudio = RtpAudioReceiver()
        let terminal = DispatchSemaphore(value: 0)
        let failureCodes = Locked<[Int32]>([])
        runtimeAudio.onReceiveFailed = { error in
            failureCodes.use { $0.append(error) }; terminal.signal()
        }
        sleeps.use { $0.removeAll() }
        script.use { $0 = Script([ENOBUFS, ENOMEM, ENOBUFS, ENOMEM, ENOBUFS, ENOMEM, EAGAIN, ENOBUFS, EIO]) }
        runtimeAudio.startReceiveLoop()
        try wait(terminal, "runtime audio failure delivered")
        runtimeAudio.recvQueue.sync {}
        try expect(failureCodes.use { $0 } == [EIO], "one nonfatal terminal event")
        try expect(sleeps.use { $0 } == [1_000, 2_000, 4_000, 8_000, 16_000, 16_000, 1_000], "capped resettable backoff")
        try expect(runtimeAudio.decodeWorker.idle.use { $0 } == 1, "idle timeout remains startup evidence")

        let cancelledAudio = RtpAudioReceiver()
        let cancelledScript = Script([EBADF], parked: true)
        script.use { $0 = cancelledScript }
        let cancelledFailures = Locked(0)
        cancelledAudio.onReceiveFailed = { _ in cancelledFailures.use { $0 += 1 } }
        cancelledAudio.startReceiveLoop()
        try wait(cancelledScript.entered, "cancelled receive entered")
        cancelledAudio.interrupted.set()
        cancelledScript.release?.signal()
        cancelledAudio.recvQueue.sync {}
        try expect(cancelledFailures.use { $0 } == 0, "stop excludes terminal event")

        // Park an old receive before submit. Stop cannot finish until it
        // drains; releasing it after cancellation cannot reach the shared sink.
        let sink = Sink()
        let oldVideo = VideoRtpReceiver(sink: sink)
        let parked = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        oldVideo.recvQueue.async { parked.signal(); release.wait(); oldVideo.depacketizerDidAssembleFrame(DecodeUnit()) }
        try wait(parked, "old video parked")
        DispatchQueue.global().async { oldVideo.stop(); stopped.signal() }
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while !oldVideo.interrupted.load(ordering: .relaxed), DispatchTime.now().uptimeNanoseconds < deadline { sched_yield() }
        try expect(oldVideo.interrupted.load(ordering: .relaxed), "video cancellation published")
        try expect(stopped.wait(timeout: .now() + 0.02) == .timedOut, "stop waits for old receive")
        release.signal()
        try wait(stopped, "old receiver drained")
        let replacement = VideoRtpReceiver(sink: sink)
        replacement.recvQueue.sync { replacement.depacketizerDidAssembleFrame(DecodeUnit()) }
        oldVideo.recvQueue.sync { oldVideo.depacketizerDidAssembleFrame(DecodeUnit()) }
        try expect(sink.submissions.use { $0 } == 1, "only replacement submits after reopen")

        // Real failure publication moves callbacks off recvQueue. Its consumer
        // can synchronously stop/join while the exiting receive is still parked.
        let failedVideo = VideoRtpReceiver(sink: Sink())
        let published = DispatchSemaphore(value: 0), exitReceive = DispatchSemaphore(value: 0)
        let fatalFinished = DispatchSemaphore(value: 0), callbackStarted = DispatchSemaphore(value: 0)
        failedVideo.recvQueue.async {
            failedVideo.publishReceiveFailure {
                callbackStarted.signal(); failedVideo.stop(); fatalFinished.signal()
            }
            published.signal(); exitReceive.wait()
        }
        try wait(published, "fatal published")
        try wait(callbackStarted, "fatal callback starts off receive queue")
        try expect(fatalFinished.wait(timeout: .now() + 0.02) == .timedOut, "fatal consumer joins exiting receive")
        exitReceive.signal()
        try wait(fatalFinished, "fatal callback drains without deadlock")

        // Concurrent stop cannot return after references are taken but before
        // cleanup completes. A same-thread leaf notification may reenter stop.
        let backend = NativeBackend(), lifecycleSink = LifecycleSink()
        backend.videoSink = lifecycleSink
        lifecycleSink.onCleanup = { [weak backend] in backend?.stopConnection() }
        let firstStop = DispatchSemaphore(value: 0), secondStop = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { backend.stopConnection(); firstStop.signal() }
        try wait(lifecycleSink.entered, "backend entered cleanup after reentrant stop")
        DispatchQueue.global().async { backend.stopConnection(); secondStop.signal() }
        try expect(secondStop.wait(timeout: .now() + 0.02) == .timedOut, "concurrent stop waits for cleanup")
        lifecycleSink.release.signal()
        try wait(firstStop, "first backend stop completed")
        try wait(secondStop, "second backend stop completed")
        try expect(lifecycleSink.cleanups.use { $0 } == 1, "backend cleans sink exactly once")
        print("{\"status\":\"passed\",\"mediaLifecycleChecks\":\(checks),\"scope\":\"exact production receive/drain/CBC methods and audio queue; scripted syscalls, inert display/FEC recovery, no network or device\"}")
    }
}
'''

audio_methods = [block(audio_receive, "func " + name) for name in (
    "startReceiveLoop()", "shouldContinueReceiving(after", "publishReceiveFailure(")]
audio_methods += [block(audio_decrypt, "func " + name) for name in ("acceptsAudioPayload(", "decryptCbc(")]
video_methods = [block(video, signature).replace("private func", "func", 1) for signature in (
    "func stop()", "private func publishReceiveFailure(", "func depacketizerDidAssembleFrame(")]
fixture = fixture.replace("__AUDIO_METHODS__", "\n".join(audio_methods))
fixture = fixture.replace("__VIDEO_METHODS__", "\n".join(video_methods))
fixture = fixture.replace("__BACKEND_METHODS__", "\n".join(
    block(backend, signature).replace("package func", "func", 1)
    for signature in ("package func stopConnection()", "package func interruptConnection()")))
queue_sources = [ENGINE / "Network" / name for name in ("RtpAudioQueue.swift", "RtpAudioQueue+Fec.swift")]
with tempfile.TemporaryDirectory(prefix="knot-media-lifecycle-", dir="/tmp") as directory:
    temporary = Path(directory)
    source = temporary / "Checks.swift"
    source.write_text(fixture)
    executable = temporary / "checks"
    compile_argv = ["/usr/bin/swiftc", "-swift-version", "6", "-parse-as-library", "-O",
                    "-module-cache-path", str(temporary / "module-cache"), str(source),
                    *map(str, queue_sources), "-o", str(executable)]
    print(json.dumps({"compileArgv": compile_argv, "checksArgv": [str(executable)]}), flush=True)
    subprocess.run(compile_argv, check=True)
    subprocess.run([str(executable)], check=True, timeout=30)
    source_paths = [ENGINE / "Network/RtpAudioReceiver+Receive.swift",
                    ENGINE / "Network/RtpAudioReceiver+Decrypt.swift",
                    ENGINE / "Network/VideoRtpReceiver.swift", ENGINE / "Session/NativeBackend.swift",
                    ENGINE / "Session/NativeBackend+Pipeline.swift", *queue_sources]
    print(json.dumps({"fixtureSHA256": hashlib.sha256(fixture.encode()).hexdigest(),
                      "productionSourceSHA256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                                 for path in source_paths},
                      "scope": "offline source-extracted synthetic regression, not device acceptance"}))
