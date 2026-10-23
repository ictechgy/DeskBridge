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
bridge = (ENGINE / "Session/StreamBridgeContext.swift").read_text()

# Bind the extracted methods to their real production consumers as well as
# executing them. These checks prevent an unused fixed helper from passing.
assert audio_receive.index("!acceptsAudioPayload") < audio_receive.index("queue.addPacket")
assert "self?.publishReceiveFailure(receiveFailure, callback: onReceiveFailed)" in audio_receive
assert "if receiveFailed { self?.publishReceiveFailure(callback: onReceiveFailed) }" in video
assert "if receiveFailed { onReceiveFailed?() }" not in video
assert "events.audioFailed(\"audio receive failed (errno " in pipeline
assert video.index("try Self.configureReceiveTimeout(sock)") < video.index("fd = sock")

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
enum EnetError: Error { case socketFailure(String) }
let timeoutFailure = Locked(false)
let closedSockets = Locked<[Int32]>([])
let timeoutSockets = Locked<[Int32]>([])
func setsockopt(_ socket: Int32, _ level: Int32, _ option: Int32, _ bytes: UnsafeRawPointer?, _ length: socklen_t) -> Int32 {
    precondition(level == SOL_SOCKET && option == SO_RCVTIMEO && length == MemoryLayout<timeval>.size)
    precondition(bytes!.load(as: timeval.self).tv_usec == 100_000)
    timeoutSockets.use { $0.append(socket) }
    if timeoutFailure.use({ $0 }) { errno = EIO; return -1 }
    return 0
}
func close(_ socket: Int32) -> Int32 { closedSockets.use { $0.append(socket) }; return 0 }
final class Flag: @unchecked Sendable {
    let state = Locked(false)
    var isSet: Bool { state.use { $0 } }
    func set() { state.use { $0 = true } }
}
let sleeps = Locked<[useconds_t]>([])
let sleepHook = Locked<(@Sendable (useconds_t) -> Void)?>(nil)
@discardableResult func usleep(_ delay: useconds_t) -> Int32 {
    sleeps.use { $0.append(delay) }; sleepHook.use { $0 }?(delay); return 0
}
final class Script: @unchecked Sendable {
    let errors: Locked<[Int32]>
    let calls = Locked(0)
    let entered = DispatchSemaphore(value: 0)
    let release: DispatchSemaphore?
    init(_ errors: [Int32], parked: Bool = false) {
        self.errors = Locked(errors)
        release = parked ? DispatchSemaphore(value: 0) : nil
    }
    func next() -> Int32 {
        calls.use { $0 += 1 }
        entered.signal(); release?.wait()
        return errors.use { $0.isEmpty ? EIO : $0.removeFirst() }
    }
}
let script = Locked(Script([EIO]))
let receiveModes = Locked<[String]>([])
final class DatagramBatch {
    let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: 1500)
    let activeScript: Script
    init(capacity: Int, stride: Int, receiveBatch: TransportPlatform.ReceiveBatch? = nil) { activeScript = script.use { $0 } }
    deinit { storage.deallocate() }
    private func result() -> Int { errno = activeScript.next(); return errno == 0 ? 1 : -1 }
    func receiveOne(from: Int32) -> Int { receiveModes.use { $0.append("one") }; return result() }
    func receive(from: Int32) -> Int { receiveModes.use { $0.append("batch") }; return result() }
    func datagram(_ index: Int) -> (bytes: UnsafeMutablePointer<UInt8>, length: Int) { (storage, 1) }
    func isExpectedPeer(at: Int, expected: Int, expectedLength: Int) -> Bool { true }
}
struct ReceiveTiming {
    enum Kind { case audio, video }
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
    static func notice(_ message: String, _ category: String) {}
    static func error(_ message: String, _ category: String) {}
}
enum TransportPlatform { typealias ReceiveBatch = @Sendable () -> Void }
struct VideoDecryptor: Sendable { init?(key: [UInt8]) {} }
struct SyntheticVideoQueue {
    let flushes = Locked(0)
    func flushDeferredIfWindowElapsed(nowUs: UInt64) { flushes.use { $0 += 1 } }
}
final class VideoRtpReceiver: @unchecked Sendable {
    static let cat = "synthetic.video"
    let interrupted = Atomic<Bool>(false)
    let recvQueue = DispatchQueue(label: "synthetic.video.receive")
    let fd: Int32 = -1, packetSize = 1400
    let encrypted = false, aesKey = [UInt8]()
    let receiveBatch: TransportPlatform.ReceiveBatch? = nil
    let destAddr = 0, destAddrLen = 0
    var onReceiveFailed: (@Sendable () -> Void)?
    var loggedReceivePressure = false
    let rtpQueue = SyntheticVideoQueue()
    let received = Locked(0)
    let sink: Sink?
    var lossEpisode = Episode()
    let depacketizer = Depacketizer()
    init(sink: Sink) { self.sink = sink }
    func noteKeyFrame(_ unit: DecodeUnit, tracker: FrameTimingTracker) {}
    func closeLossEpisode(at unit: DecodeUnit, isIDR: Bool) {}
    func isExpectedPostGateResync(isIDR: Bool) -> Bool { false }
    func receive(_ bytes: UnsafeMutablePointer<UInt8>, count: Int, decryptor: VideoDecryptor?) { received.use { $0 += 1 } }
    __VIDEO_METHODS__
}
final class LeafResource: @unchecked Sendable {
    var onTerminated: (@Sendable (Int32) -> Void)?
    var onHdrMode: (@Sendable (Bool) -> Void)?
    func stop() {}
    func interrupt() {}
    func close() {}
}
typealias EnetControlChannel = LeafResource
protocol ConnectionEvents: Sendable {
    func connectionTerminated(code: Int32)
    func setHdrMode(_ enabled: Bool)
}
final class RecordedEvents: ConnectionEvents, @unchecked Sendable {
    let codes = Locked<[Int32]>([])
    let notified = DispatchSemaphore(value: 0)
    func connectionTerminated(code: Int32) { codes.use { $0.append(code) }; notified.signal() }
    func setHdrMode(_ enabled: Bool) {}
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
    func withState<T>(_ body: () -> T) -> T { stateLock.lock(); defer { stateLock.unlock() }; return body() }
    func checkInterrupted() -> Bool { withState { interrupted } }
    func wireVideoFailure(receiver: VideoRtpReceiver, events: any ConnectionEvents) {
        __VIDEO_FAILURE_CLOSURE__
    }
    __BACKEND_METHODS__
}
enum StreamEvent: Equatable, Sendable { case reconnecting, audioFailed(String), firstFrame }
final class SessionEventSource: @unchecked Sendable {
    let events = Locked<[StreamEvent]>([])
    let didBegin = Locked<[UUID]>([])
    var onYield: (@Sendable (StreamEvent) -> Void)?
    func beginAttempt(_ id: UUID) { didBegin.use { $0.append(id) } }
    func yield(_ event: StreamEvent, attempt: UUID) { events.use { $0.append(event) }; onYield?(event) }
}
final class StreamBridgeContext: @unchecked Sendable {
    private var attemptID = UUID()
    private let sourceLock = NSLock()
    private var eventSource: ObjectIdentifier?
    private var audioEventsQuiesced = false
    let publicEvents: SessionEventSource?
    var eventContinuation: AsyncStream<StreamEvent>.Continuation?
    init(events: SessionEventSource? = nil) { publicEvents = events }
    __BRIDGE_METHODS__
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
        try VideoRtpReceiver.configureReceiveTimeout(701)
        try expect(timeoutSockets.use { $0 } == [701] && closedSockets.use { $0.isEmpty }, "successful timeout retains local socket")
        timeoutFailure.use { $0 = true }
        var failedTimeout = false
        do { try VideoRtpReceiver.configureReceiveTimeout(702) }
        catch EnetError.socketFailure { failedTimeout = true }
        try expect(failedTimeout && closedSockets.use { $0 } == [702], "failed timeout must close unpublished socket and refuse startup")

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

        // Execute the full video loop with scripted buffer pressure, an idle
        // poll and a successful datagram. No descriptor is used by the stub.
        let pressuredVideo = VideoRtpReceiver(sink: Sink())
        let videoFailure = DispatchSemaphore(value: 0)
        pressuredVideo.onReceiveFailed = { videoFailure.signal() }
        sleeps.use { $0.removeAll() }
        script.use { $0 = Script([ENOBUFS, ENOMEM, ENOBUFS, ENOMEM, ENOBUFS, ENOMEM,
                                  EAGAIN, ENOBUFS, 0, ENOBUFS, EIO]) }
        pressuredVideo.startReceiveLoop()
        try wait(videoFailure, "video terminal error delivered off receive queue")
        pressuredVideo.recvQueue.sync {}
        try expect(sleeps.use { $0 } == [1_000, 2_000, 4_000, 8_000, 16_000, 16_000, 1_000, 1_000],
                   "video pressure is capped and resets after idle and successful batch")
        try expect(pressuredVideo.received.use { $0 } == 1, "successful datagram reaches production loop consumer")
        try expect(pressuredVideo.rtpQueue.flushes.use { $0 } == 1, "idle poll still flushes reorder hold")

        let interruptedVideo = VideoRtpReceiver(sink: Sink())
        let interruptScript = Script([ENOBUFS, EIO])
        let interruptFailures = Locked(0)
        interruptedVideo.onReceiveFailed = { interruptFailures.use { $0 += 1 } }
        script.use { $0 = interruptScript }
        sleeps.use { $0.removeAll() }
        sleepHook.use { $0 = { _ in interruptedVideo.interrupted.store(true, ordering: .relaxed) } }
        interruptedVideo.startReceiveLoop()
        interruptedVideo.recvQueue.sync {}
        sleepHook.use { $0 = nil }
        try expect(interruptScript.calls.use { $0 } == 1, "interrupt after pressure sleep excludes another syscall")
        try expect(sleeps.use { $0 } == [1_000] && interruptFailures.use { $0 } == 0,
                   "pressure cancellation is quiet and bounded")

        let fallbackVideo = VideoRtpReceiver(sink: Sink())
        let fallbackFailure = DispatchSemaphore(value: 0)
        fallbackVideo.onReceiveFailed = { fallbackFailure.signal() }
        script.use { $0 = Script([ENOSYS, ENOBUFS, EIO]) }
        receiveModes.use { $0.removeAll() }
        fallbackVideo.startReceiveLoop()
        try wait(fallbackFailure, "batch syscall fallback remains operational")
        fallbackVideo.recvQueue.sync {}
        try expect(receiveModes.use { $0 } == ["batch", "one", "one"], "unsupported batch syscall switches subsequent receives to recvmsg")

        // A callback may have passed NativeConnectionEvents.isCurrent before
        // recovery starts. The real bridge must fence it at actual delivery.
        let bridgeEvents = SessionEventSource()
        let bridge = StreamBridgeContext(events: bridgeEvents)
        let oldBackend = NativeBackend(), oldAttempt = UUID()
        bridge.setEventSource(oldBackend, attempt: oldAttempt)
        try expect(bridge.acceptsEvent(from: oldBackend, attempt: oldAttempt), "old callback passes precheck")
        bridge.emit(.reconnecting)
        bridge.emit(.audioFailed("old failure during backoff"), source: oldBackend, attempt: oldAttempt)
        try expect(bridgeEvents.events.use { $0 } == [.reconnecting], "backoff fences old audio event after precheck")
        let newAttempt = UUID(), newBackend = NativeBackend()
        bridge.beginAttempt(newAttempt)
        bridge.emit(.audioFailed("old generation"), source: oldBackend, attempt: oldAttempt)
        bridge.setEventSource(newBackend, attempt: newAttempt)
        bridge.emit(.audioFailed("new receiver before first picture"), source: newBackend, attempt: newAttempt)
        bridge.emit(.firstFrame, source: newBackend, attempt: newAttempt)
        try expect(bridgeEvents.events.use { $0 } == [.reconnecting, .audioFailed("new receiver before first picture"), .firstFrame],
                   "new receiver failure survives first frame while old generation stays rejected")

        // Park the actual reconnect yield while sourceLock is held. A competing
        // audio delivery cannot pass between quiescing and publishing that edge.
        let raceEvents = SessionEventSource()
        let orderedBridge = StreamBridgeContext(events: raceEvents)
        orderedBridge.setEventSource(oldBackend, attempt: oldAttempt)
        let reconnectEntered = DispatchSemaphore(value: 0), reconnectRelease = DispatchSemaphore(value: 0)
        let reconnectDone = DispatchSemaphore(value: 0), racedAudioDone = DispatchSemaphore(value: 0)
        raceEvents.onYield = { event in
            if event == .reconnecting { reconnectEntered.signal(); reconnectRelease.wait() }
        }
        DispatchQueue.global().async { orderedBridge.emit(.reconnecting); reconnectDone.signal() }
        try wait(reconnectEntered, "reconnect delivery entered under bridge source lock")
        DispatchQueue.global().async {
            orderedBridge.emit(.audioFailed("raced old event"), source: oldBackend, attempt: oldAttempt)
            racedAudioDone.signal()
        }
        try expect(racedAudioDone.wait(timeout: .now() + 0.02) == .timedOut, "audio emission waits for reconnect boundary")
        reconnectRelease.signal()
        try wait(reconnectDone, "reconnect event released")
        try wait(racedAudioDone, "racing audio delivery completed")
        try expect(raceEvents.events.use { $0 } == [.reconnecting], "raced audio is rejected after ordered reconnect yield")
        // Both attempt entry points reset the same latch; beginAttempt also
        // serves the legacy continuation path before a backend is installed.
        let resetEvents = SessionEventSource(), resetBridge = StreamBridgeContext(events: resetEvents)
        resetBridge.emit(.reconnecting)
        resetBridge.beginAttempt(newAttempt)
        resetBridge.emit(.audioFailed("fresh attempt"), attempt: newAttempt)
        try expect(resetEvents.events.use { $0 } == [.reconnecting, .audioFailed("fresh attempt")], "beginAttempt independently resets audio fence")
        resetBridge.emit(.reconnecting)
        resetBridge.setEventSource(newBackend, attempt: newAttempt)
        resetBridge.emit(.audioFailed("fresh source"), source: newBackend, attempt: newAttempt)
        try expect(resetEvents.events.use { $0.last } == .audioFailed("fresh source"), "setEventSource independently resets audio fence")

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

        // Run each production termination closure. Notification is queued
        // before teardown can block, while stop still drains the shared sink.
        for hostTermination in [false, true] {
            let terminatingBackend = NativeBackend(), parkedSink = LifecycleSink()
            let receiver = VideoRtpReceiver(sink: Sink()), events = RecordedEvents()
            terminatingBackend.videoSink = parkedSink
            terminatingBackend.videoReceiver = receiver
            let callbackDone = DispatchSemaphore(value: 0)
            if hostTermination {
                let control = EnetControlChannel()
                terminatingBackend.wireVideoControl(enet: control, events: events)
                DispatchQueue.global().async { control.onTerminated?(42); callbackDone.signal() }
            } else {
                terminatingBackend.wireVideoFailure(receiver: receiver, events: events)
                DispatchQueue.global().async { receiver.onReceiveFailed?(); callbackDone.signal() }
            }
            try wait(events.notified, "termination notification precedes parked cleanup")
            try wait(parkedSink.entered, "termination teardown entered cleanup")
            try expect(callbackDone.wait(timeout: .now() + 0.02) == .timedOut, "termination callback still waits for decoder cleanup")
            try expect(events.codes.use { $0 } == [hostTermination ? 42 : -1], "termination code preserved")
            parkedSink.release.signal()
            try wait(callbackDone, "termination teardown completes after cleanup release")
            try expect(parkedSink.cleanups.use { $0 } == 1, "termination cleanup remains singular")
        }
        print("{\"status\":\"passed\",\"mediaLifecycleChecks\":\(checks),\"scope\":\"exact production receive/drain/CBC methods and audio queue; scripted syscalls, inert display/FEC recovery, no network or device\"}")
    }
}
'''

audio_methods = [block(audio_receive, "func " + name) for name in (
    "startReceiveLoop()", "shouldContinueReceiving(after", "publishReceiveFailure(")]
audio_methods += [block(audio_decrypt, "func " + name) for name in ("acceptsAudioPayload(", "decryptCbc(")]
video_methods = [block(video, signature).replace("private func", "func", 1) for signature in (
    "func stop()", "private func publishReceiveFailure(", "func depacketizerDidAssembleFrame(",
    "private func startReceiveLoop()", "private func shouldContinueReceiving(")]
video_methods.append(block(video, "private static func configureReceiveTimeout(").replace("private static func", "static func", 1))
fixture = fixture.replace("__AUDIO_METHODS__", "\n".join(audio_methods))
fixture = fixture.replace("__VIDEO_METHODS__", "\n".join(video_methods))
fixture = fixture.replace("__BACKEND_METHODS__", "\n".join(
    block(backend, signature).replace("package func", "func", 1)
    for signature in ("package func stopConnection()", "package func interruptConnection()")))
fixture = fixture.replace("__VIDEO_FAILURE_CLOSURE__", block(pipeline, "receiver.onReceiveFailed ="))
fixture = fixture.replace("__BRIDGE_METHODS__", "\n".join(
    block(bridge, signature).replace("package func", "func", 1)
    for signature in ("package func beginAttempt(", "package func setEventSource(",
                      "package func acceptsEvent(", "package func emit(")))
fixture = fixture.replace("    func wireVideoFailure", block(pipeline, "func wireVideoControl(") + "\n    func wireVideoFailure", 1)
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
                    ENGINE / "Session/NativeBackend+Pipeline.swift", ENGINE / "Session/StreamBridgeContext.swift", *queue_sources]
    print(json.dumps({"fixtureSHA256": hashlib.sha256(fixture.encode()).hexdigest(),
                      "productionSourceSHA256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                                 for path in source_paths},
                      "scope": "offline source-extracted synthetic regression, not device acceptance"}))


# Separate source-extracted audio startup fixture keeps all 74 receive/drain
# checks above unchanged. Only syscalls, ping scheduling, codec work and logging
# are inert; openSocket, timeout setup and both backend audio consumers are real.
audio_socket = (ENGINE / "Network/RtpAudioReceiver+Socket.swift").read_text()
assert audio_socket.index("try Self.configureReceiveTimeout(sock)") < audio_socket.index("fd = sock")
assert "config: config, host: host, events: events" in block(pipeline, "rtsp.onAudioPortNegotiated =")
socket_fixture = r'''
import Foundation
import Darwin

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func use<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
struct Ledger {
    var nextSocket: Int32 = 703
    var timeoutFails = false
    var binds = [Int32](), closes = [Int32](), timeouts = [Int32](), timestamps = [Int32]()
    var family = AF_INET
    var onTimeout: (@Sendable () -> Void)?
}
let ledger = Locked(Ledger())
func socket(_ family: Int32, _ kind: Int32, _ proto: Int32) -> Int32 {
    precondition(kind == SOCK_DGRAM && proto == 0)
    return ledger.use { value in defer { value.nextSocket += 1 }; return value.nextSocket }
}
@discardableResult func setsockopt(_ socket: Int32, _ level: Int32, _ option: Int32, _ bytes: UnsafeRawPointer?, _ length: socklen_t) -> Int32 {
    precondition(level == SOL_SOCKET)
    guard option == SO_RCVTIMEO else {
        precondition(option == SO_RCVBUF || option == SO_NET_SERVICE_TYPE); return 0
    }
    precondition(length == MemoryLayout<timeval>.size && bytes!.load(as: timeval.self).tv_sec == 0
                 && bytes!.load(as: timeval.self).tv_usec == 100_000)
    let state = ledger.use { value -> (Bool, (@Sendable () -> Void)?) in
        value.timeouts.append(socket); return (value.timeoutFails, value.onTimeout)
    }
    state.1?()
    if state.0 { errno = EIO; return -1 }
    return 0
}
@discardableResult func close(_ socket: Int32) -> Int32 { ledger.use { $0.closes.append(socket) }; return 0 }
func bind(_ socket: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t) -> Int32 {
    ledger.use { $0.binds.append(socket) }; return 0
}
enum SocketTimestamp { static func enable(on socket: Int32) -> Bool { ledger.use { $0.timestamps.append(socket) }; return true } }
enum NWEndpoint { typealias Host = String }
enum EnetError: Error { case socketFailure(String) }
enum UdpPinger {
    static func makeSockaddr(for host: String, port: UInt16) -> (sockaddr_storage, socklen_t, Int32)? {
        (sockaddr_storage(), socklen_t(MemoryLayout<sockaddr_storage>.size), ledger.use { $0.family })
    }
}
enum Privacy { case `private`, `public` }
struct Message: ExpressibleByStringInterpolation {
    init(stringLiteral: String) {}
    init(stringInterpolation: StringInterpolation) {}
    static func + (_ lhs: Message, _ rhs: Message) -> Message { Message(stringLiteral: "") }
    struct StringInterpolation: StringInterpolationProtocol {
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ value: String) {}
        mutating func appendInterpolation<T>(_ value: T, privacy: Privacy = .public) {}
    }
}
enum Diag {
    static func info(_ message: Message, _ category: String) {}
    static func warn(_ message: Message, _ category: String) {}
    static func notice(_ message: Message, _ category: String) {}
    static func error(_ message: Message, _ category: String) {}
}
struct OpusConfig {}
struct RtspHandshakeResult {}
struct BackendServerInfo {}
struct BackendStreamConfig {
    let audioConfiguration: Int32 = 0
    let remoteInputAesKey = [UInt8](), remoteInputAesIv = [UInt8]()
}
struct TransportPlatform { let configureAudioThread: @Sendable () -> Void = {} }
final class Sink: @unchecked Sendable {}
final class Counter: @unchecked Sendable {
    let count = Locked(0)
    func increment() { count.use { $0 += 1 } }
}
final class TelemetryCounters: Sendable {
    static let shared = TelemetryCounters()
    let audioReceiveFailedTotal = Counter()
}
final class RtpAudioReceiver: @unchecked Sendable {
    static let cat = "inert.audio", maxPacketSize = 1400
    let host: String, audioPort: UInt16
    var destAddr = sockaddr_storage(), destAddrLen: socklen_t = 0
    var fd: Int32 = -1
    var onReceiveFailed: (@Sendable (Int32) -> Void)?
    var receiveStarts = 0
    init(host: String = "inert", audioPort: UInt16 = 1, pingPayload: [UInt8] = [], audioPacketDuration: Int = 5,
         opusConfig: OpusConfig = OpusConfig(), audioConfig: Int32 = 0, audioEncryption: Bool = false,
         aesKey: [UInt8] = [], aesIvId: [UInt8] = [], sink: Sink? = nil, platform: TransportPlatform = TransportPlatform(),
         configureThread: @escaping @Sendable () -> Void = {}) { self.host = host; self.audioPort = audioPort }
    func startPing() throws { try openSocket() } // Ping scheduling deliberately inert.
    func startReceive() throws { receiveStarts += 1 } // Codec and receive loop covered separately.
    __SOCKET_METHODS__
}
protocol ConnectionEvents: Sendable { func audioFailed(_ detail: String) }
final class Events: ConnectionEvents, @unchecked Sendable {
    let failures = Locked<[String]>([])
    func audioFailed(_ detail: String) { failures.use { $0.append(detail) } }
}
final class NativeBackend: @unchecked Sendable {
    static let logCategory = "inert.backend"
    let stateLock = NSLock(), platform = TransportPlatform()
    var interrupted = false
    var audioReceiver: RtpAudioReceiver?, audioSink: Sink?
    func withState<T>(_ body: () -> T) -> T { stateLock.lock(); defer { stateLock.unlock() }; return body() }
    func adoptWhileConnecting(_ body: () -> Void) -> Bool { withState { guard !interrupted else { return false }; body(); return true } }
    __PIPELINE_METHODS__
}
@main struct Checks {
    static func main() throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ name: String) throws {
            guard value() else { throw NSError(domain: name, code: checks) }; checks += 1
        }
        ledger.use { $0.timeoutFails = true }
        let failed = RtpAudioReceiver()
        var refused = false
        do { try failed.openSocket() } catch EnetError.socketFailure { refused = true }
        try expect(refused && failed.fd == -1, "timeout failure refuses fd publication")
        try expect(ledger.use { $0.closes } == [703], "only unpublished audio socket closes")
        try expect(ledger.use { $0.binds.isEmpty && $0.timestamps.isEmpty && $0.timeouts == [703] }, "timeout failure precedes bind and timestamp enable")

        ledger.use { $0.timeoutFails = false }
        let valid = RtpAudioReceiver()
        try valid.openSocket()
        try expect(valid.fd == 704 && ledger.use { $0.binds } == [704], "successful audio timeout allows normal fd publication")
        try expect(ledger.use { $0.closes } == [703], "successful audio socket remains receiver owned")
        ledger.use { $0.family = AF_INET6 }
        let valid6 = RtpAudioReceiver()
        try valid6.openSocket()
        try expect(valid6.fd == 705 && ledger.use { $0.binds.last } == 705, "IPv6 bind also follows mandatory timeout")

        func start(_ backend: NativeBackend, _ events: Events) {
            backend.startAudioPing(audioPort: 1, pingPayload: [], audioEncryption: false,
                                   opusConfig: OpusConfig(), config: BackendStreamConfig(), host: "inert", events: events)
            backend.startAudioReceive(handshake: RtspHandshakeResult(), config: BackendStreamConfig(),
                                      server: BackendServerInfo(), host: "inert", events: events)
        }
        ledger.use { $0.timeoutFails = true }
        let backend = NativeBackend(), events = Events()
        backend.audioSink = Sink()
        start(backend, events)
        try expect(backend.audioReceiver == nil, "failed early ping receiver is released")
        try expect(events.failures.use { $0 } == ["audio transport initialization failed"], "one fixed nonfatal audio failure reaches event sink")
        try expect(TelemetryCounters.shared.audioReceiveFailedTotal.count.use { $0 } == 1, "failed early transport increments audio failure counter once")

        let disabled = NativeBackend(), disabledEvents = Events()
        start(disabled, disabledEvents)
        try expect(disabled.audioReceiver == nil && disabledEvents.failures.use { $0.isEmpty }, "deliberate no-sink configuration remains silent")

        ledger.use { $0.timeoutFails = false }
        let live = NativeBackend(), liveEvents = Events()
        live.audioSink = Sink()
        start(live, liveEvents)
        try expect(live.audioReceiver?.receiveStarts == 1 && liveEvents.failures.use { $0.isEmpty }, "successful ping reuses its receiver without a failure event")

        let stopped = NativeBackend(), stoppedEvents = Events()
        stopped.audioSink = Sink()
        ledger.use { $0.timeoutFails = true; $0.onTimeout = { stopped.withState { stopped.interrupted = true } } }
        start(stopped, stoppedEvents)
        ledger.use { $0.onTimeout = nil }
        try expect(stopped.audioReceiver == nil && stoppedEvents.failures.use { $0.isEmpty }, "concurrent stop suppresses stale startup failure event")
        try expect(TelemetryCounters.shared.audioReceiveFailedTotal.count.use { $0 } == 1, "no-sink success and cancellation do not count failures")
        let replaced = NativeBackend(), replacedEvents = Events(), replacement = RtpAudioReceiver()
        replaced.audioSink = Sink()
        ledger.use { $0.onTimeout = { replaced.withState { replaced.audioReceiver = replacement } } }
        start(replaced, replacedEvents)
        ledger.use { $0.onTimeout = nil }
        try expect(replaced.audioReceiver === replacement && replacedEvents.failures.use { $0.isEmpty }, "obsolete startup failure cannot clear a replacement receiver or emit its error")
        print("{\"status\":\"passed\",\"audioSocketStartupChecks\":\(checks),\"scope\":\"exact production audio socket and backend startup methods; inert syscalls/ping/codec/logging, no network or device\"}")
    }
}
'''
socket_fixture = socket_fixture.replace("__SOCKET_METHODS__", "\n".join(
    block(audio_socket, signature).replace("private static func", "static func", 1)
    for signature in ("func openSocket()", "private static func configureReceiveTimeout(")))
socket_fixture = socket_fixture.replace("__PIPELINE_METHODS__", "\n".join(
    block(pipeline, signature) for signature in ("func startAudioPing(", "func startAudioReceive(")))
with tempfile.TemporaryDirectory(prefix="knot-audio-socket-", dir="/tmp") as directory:
    temporary = Path(directory)
    source = temporary / "Checks.swift"
    source.write_text(socket_fixture)
    executable = temporary / "checks"
    argv = ["/usr/bin/swiftc", "-swift-version", "6", "-parse-as-library", "-O",
            "-module-cache-path", str(temporary / "module-cache"), str(source), "-o", str(executable)]
    print(json.dumps({"compileArgv": argv, "checksArgv": [str(executable)]}), flush=True)
    subprocess.run(argv, check=True)
    subprocess.run([str(executable)], check=True, timeout=30)
    print(json.dumps({"audioSocketFixtureSHA256": hashlib.sha256(socket_fixture.encode()).hexdigest(),
                      "productionSourceSHA256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                                 for path in (ENGINE / "Network/RtpAudioReceiver+Socket.swift",
                                                              ENGINE / "Session/NativeBackend+Pipeline.swift")}}))
