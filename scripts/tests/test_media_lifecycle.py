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


# A fatal current replacement used to vanish while isReconnecting was true.
# Exercise the actual actor consumer, complete bounded episode, success suffix,
# ordered callback adapter and native cleanup with controlled inert await seams.
reconnect = (ENGINE / "Session/StreamSession+Reconnect.swift").read_text()
session_source = (ENGINE / "Session/StreamSession.swift").read_text()
events_source = (ENGINE / "Session/NativeConnectionEvents.swift").read_text()
terminate = block(reconnect, "package func handleHostTerminate(")
terminate_prefix = terminate[:terminate.index("        // The uplink is dead")]
selection_start = reconnect.index("        let fresh = makeBackend()")
selection_end = reconnect.index("        await MainActor.run {", selection_start)
selection = reconnect[selection_start:selection_end]
tail_start = reconnect.index("        await net.setRequestDeadline(nil)", selection_end)
tail_end = reconnect.index("    /// Actor-owned attempt state", tail_start)
attempt_tail = reconnect[tail_start:tail_end].rstrip()
# The closing brace belongs to reconnectInPlace; the fixture supplies its header.
assert attempt_tail.endswith("}")
attempt_tail = attempt_tail[:-1]
# Full production consumer wiring is checked in addition to executing slices.
assert "package var reconnectAttemptID: UUID?" in session_source
assert "package var reconnectAttemptFailure: Int32?" in session_source
assert reconnect.index("reconnectAttemptID = nil", reconnect.index("private func reconnectInPlace")) < selection_start
assert selection.index("attemptID = UUID()") < selection.index("reconnectAttemptID = freshAttempt")
assert "try checkReconnectAttempt(freshAttempt, deadline: deadline)" in block(reconnect, "private func reconnectInPlace(")
assert "enqueueSessionEvent { await session.handleHostTerminate(code: code, from: backend) }" in events_source
success = block(reconnect, "if resumed {")
assert success.index("await MainActor.run") < success.index("guard reconnectAttemptIsHealthy(resumedAttempt)")
commit = success[success.index("guard reconnectAttemptIsHealthy(resumedAttempt)"):success.index("bridge?.emit(.reconnected)")]
assert "await " not in commit
assert "reconnectAttemptID = nil" in commit
teardown = block(reconnect, "private func teardownConnectionForReconnect()")
teardown = teardown[:teardown.index("        if let state = connectFlowState")] + "    }"
reconnect_fixture = r'''
import Foundation
import os

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func use<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
func wait(_ semaphore: DispatchSemaphore) { precondition(semaphore.wait(timeout: .now() + 5) == .success, "controlled schedule timed out") }
final class Resource: @unchecked Sendable {
    let cleanups = Locked(0)
    func stop() {}; func interrupt() {}; func close() {}; func requestIdrFrame() {}
    func setNegotiatedBitrateKbps(_ value: Int) {}
    func cleanup() { cleanups.use { $0 += 1 } }
}
final class Receiver: @unchecked Sendable {
    var onReceiveFailed: (@Sendable () -> Void)?
    func stop() {}
}
let stopHook = Locked<(@Sendable () -> Void)?>(nil)
let rearmHook = Locked<(@Sendable () -> Void)?>(nil)
final class NativeBackend: @unchecked Sendable {
    static let logCategory = "inert"
    let stateLock = NSLock(), teardownLock = NSRecursiveLock()
    var interrupted = false, inputReady = true
    var videoReceiver: Receiver?, videoSink: Resource?, audioSink: Resource?
    var enetChannel: Resource? = Resource(), rtspClient: Resource? = Resource()
    var audioReceiver: Resource?, inputBatcher: Resource?
    func withState<T>(_ body: () -> T) -> T { stateLock.lock(); defer { stateLock.unlock() }; return body() }
    func wire(receiver: Receiver, events: NativeConnectionEvents) { __VIDEO_FAILURE_CLOSURE__ }
    __BACKEND_METHODS__
    func requestIdrFrame() { withState { enetChannel }?.requestIdrFrame() }
}
typealias StreamingBackend = NativeBackend
enum StreamError: Error { case sessionFailed(Int32), hostTimedOut, hostUnreachable(String) }
struct TakeoverRequired: Error { let appID: Int }
enum StreamEvent { case connectionTerminated(errorCode: Int32, error: StreamError? = nil), reconnecting, reconnected }
enum DisconnectReason { case hostClosedClean, hostError }
enum Privacy { case `private`, `public` }
struct Message: ExpressibleByStringInterpolation {
    init(stringLiteral: String) {}; init(stringInterpolation: StringInterpolation) {}
    static func + (_ lhs: Message, _ rhs: Message) -> Message { Message(stringLiteral: "") }
    struct StringInterpolation: StringInterpolationProtocol {
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ value: String) {}
        mutating func appendInterpolation<T>(_ value: T, privacy: Privacy = .public) {}
    }
}
enum Diag {
    static func info(_ message: Message, _ category: String) { stopHook.use { $0 }?() }
    static func error(_ message: Message, _ category: String) {}
    static func notice(_ message: Message, _ category: String) {}
}
final class Counter: @unchecked Sendable {
    let value = Locked(0)
    func increment() { value.use { $0 += 1 } }
}
final class P2: @unchecked Sendable { func setDisconnectReason(_ reason: DisconnectReason) {} }
final class TelemetryCounters: Sendable {
    static let shared = TelemetryCounters()
    let p2 = P2(), reconnectTotal = Counter()
}
final class Bridge: @unchecked Sendable {
    weak var session: StreamSession?
    let values = Locked<[String]>([])
    func beginAttempt(_ id: UUID) {}
    func emit(_ event: StreamEvent) {
        values.use { value in
            switch event {
            case .reconnected: value.append("reconnected")
            case .reconnecting: value.append("reconnecting")
            case .connectionTerminated: value.append("terminated")
            }
        }
    }
}
final class NativeConnectionEvents: @unchecked Sendable {
    static let logCategory = "inert"
    weak var bridge: Bridge?, backend: NativeBackend?
    private let sessionEvents = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    private var isCurrent: Bool { true } // Session actor still checks actual backend identity.
    init(bridge: Bridge, backend: NativeBackend) { self.bridge = bridge; self.backend = backend }
    private func emit(_ event: StreamEvent) { bridge?.emit(event) }
    __EVENT_METHODS__
    func drain() async { let tail = sessionEvents.withLock { $0 }; await tail?.value }
}
@MainActor final class Presentation {
    var values = [String?]()
    func showRecovery(_ value: String?) { values.append(value) }
}
final class Input: Sendable {
    func prepareForReplacement(attempt: UUID) {}; func rebind(to: NativeBackend, attempt: UUID) {}
    @MainActor func quiesce() {}; @MainActor func setReady(_ ready: Bool) {}
}
struct SyntheticClock: Sendable {
    let schedule: Schedule
    func sleep(_ duration: Duration) async throws { try Task.checkCancellation(); await schedule.sleep() }
}
actor NetworkClient {
    let schedule: Schedule
    let backend: NativeBackend
    let events: NativeConnectionEvents
    var shutdowns = 0
    init(schedule: Schedule, backend: NativeBackend, events: NativeConnectionEvents) {
        self.schedule = schedule; self.backend = backend; self.events = events
    }
    func setRequestDeadline(_ deadline: Date?) async { await schedule.deadlineCleared(backend: backend, events: events) }
    func shutdown() { shutdowns += 1 }
}
struct BackendStreamConfig { let bitrate: Int32 = 20_000 }
actor Schedule {
    enum Mode: Sendable { case healthy, deadlineFatal, rearmFatal, notifyBeforeStop, stale, wake, cancel, taskCancel, allFatal }
    let mode: Mode
    weak var session: StreamSession?
    var backends = [NativeBackend](), resources = [Resource](), events = [NativeConnectionEvents]()
    var sleepCalls = 0, setupCount = 0, interruptedBeforeRelease: Bool?
    let callbackDone = DispatchSemaphore(value: 0), releaseStop = DispatchSemaphore(value: 0)
    var retainedReceiver: Receiver?
    init(_ mode: Mode) { self.mode = mode }
    func setSession(_ session: StreamSession) { self.session = session }
    func sleep() {
        sleepCalls += 1
        if mode == .notifyBeforeStop && sleepCalls == 2 {
            stopHook.use { $0 = nil }; releaseStop.signal(); wait(callbackDone)
        }
    }
    func register(_ backend: NativeBackend, _ resource: Resource, _ event: NativeConnectionEvents) {
        // Production teardown must finish before another setup touches the sink.
        precondition(resources.allSatisfy { $0.cleanups.use { $0 } == 1 }, "replacement overlapped previous cleanup")
        backends.append(backend); resources.append(resource); events.append(event); setupCount += 1
    }
    func deadlineCleared(backend: NativeBackend, events: NativeConnectionEvents) async {
        let index = setupCount
        if mode == .allFatal || (mode == .deadlineFatal && index == 1) {
            backend.videoReceiver?.onReceiveFailed?(); await events.drain()
        } else if mode == .cancel && index == 1 {
            await session?.cancelCurrent()
        } else if mode == .taskCancel && index == 1 {
            withUnsafeCurrentTask { $0?.cancel() }
        } else if mode == .stale && index == 1 {
            // Even an already-queued adapter that passed its bridge gate is fenced.
            await session?.handleHostTerminate(code: -1, from: NativeBackend())
        } else if mode == .wake && index == 1 {
            await session?.handleHostTerminate(code: -1)
        } else if (mode == .rearmFatal || mode == .notifyBeforeStop) && index == 1 {
            let beforeStop = mode == .notifyBeforeStop
            let stopped = DispatchSemaphore(value: 0), receiver = backend.videoReceiver!
            let callbackDone = self.callbackDone, releaseStop = self.releaseStop
            let drained = DispatchSemaphore(value: 0)
            retainedReceiver = receiver
            rearmHook.use { hook in hook = {
                rearmHook.use { $0 = nil }
                if beforeStop { stopHook.use { hook in hook = { stopped.signal(); wait(releaseStop) } } }
                DispatchQueue.global().async { receiver.onReceiveFailed?(); callbackDone.signal() }
                if beforeStop { wait(stopped) } else { wait(callbackDone) }
                Task { await events.drain(); drained.signal() }
                wait(drained)
                if beforeStop { precondition(!backend.withState { backend.interrupted }, "failure must be retained before stop latch") }
            } }
        }
    }
    func stats() -> (Int, [Int], Int) { (setupCount, resources.map { $0.cleanups.use { $0 } }, sleepCalls) }
}
actor StreamSession {
    static let deadPeerTerminationCode: Int32 = -1, reconnectAttemptCap = 3
    static let reconnectWindowSeconds: TimeInterval = 30
    let schedule: Schedule, clock: SyntheticClock, bridge: Bridge?
    var backend = NativeBackend(), attemptID = UUID()
    var reconnectAttemptID: UUID?, reconnectAttemptFailure: Int32?
    var isStreaming = true, stopInProgress = false, isReconnecting = false, reconnectAttempts = 0
    var lastReconnectError: StreamError?, normalTerminations = 0, publicInput: Input? = Input(), input: Input? = Input()
    var network: NetworkClient?
    var presentation: Presentation?
    nonisolated(unsafe) var frameWatchdogArmedAt: Double = 0
    nonisolated var uptimeSeconds: Double { rearmHook.use { $0 }?(); return 1 }
    init(schedule: Schedule, bridge: Bridge, presentation: Presentation) {
        self.schedule = schedule; self.clock = SyntheticClock(schedule: schedule); self.bridge = bridge; self.presentation = presentation
    }
    func setWaitingForVideo(_ waiting: Bool) {}; func resetStallLatches() {}
    func makeBackend() -> NativeBackend { NativeBackend() }
    func checkAttempt(deadline: Date? = nil) throws {
        guard !Task.isCancelled, isStreaming, !stopInProgress else { throw CancellationError() }
    }
    __TERMINATE_PREFIX__
        normalTerminations += 1 // Ordinary-live handling is outside this regression's slice.
    }
    __ATTEMPT_METHODS__
    __EPISODE__
    __TEARDOWN__
    func reconnectInPlace(deadline: Date) async throws(TakeoverRequired) -> Bool {
        reconnectAttemptID = nil
        await teardownConnectionForReconnect()
        guard !Task.isCancelled, isStreaming, !stopInProgress else { return false }
        __SELECTION__
        let dec = Resource(), backendConfig = BackendStreamConfig()
        let receiver = Receiver(), events = NativeConnectionEvents(bridge: bridge!, backend: fresh)
        fresh.videoReceiver = receiver; fresh.videoSink = dec; fresh.wire(receiver: receiver, events: events)
        await schedule.register(fresh, dec, events)
        let net = NetworkClient(schedule: schedule, backend: fresh, events: events)
        network = net
        __ATTEMPT_TAIL__
    }
    func cancelCurrent() { isStreaming = false; stopInProgress = true; backend.stopConnection() }
    func stop(cause: DisconnectReason) async { cancelCurrent() }
    func endStreamClosedByPC() async { cancelCurrent() }
    func run() async { await runReconnectEpisode(code: -1, cause: "synthetic") }
    func state() -> (Bool, Int, Int32?) { (isReconnecting, normalTerminations, reconnectAttemptFailure) }
    func finalCleanup() { backend.stopConnection() }
}
__BUDGET__
@main struct Checks {
    static func main() async throws {
        var checks = 0
        func expect(_ value: Bool, _ name: String) { precondition(value, name); checks += 1 }
        for mode: Schedule.Mode in [.healthy, .deadlineFatal, .rearmFatal, .notifyBeforeStop, .stale, .wake, .cancel, .taskCancel, .allFatal] {
            let schedule = Schedule(mode), bridge = Bridge(), presentation = await MainActor.run { Presentation() }
            let session = StreamSession(schedule: schedule, bridge: bridge, presentation: presentation)
            bridge.session = session; await schedule.setSession(session)
            let before = TelemetryCounters.shared.reconnectTotal.value.use { $0 }
            await Task { await session.run() }.value
            let stats = await schedule.stats(), state = await session.state()
            let values = bridge.values.use { $0 }
            let banners = await MainActor.run { presentation.values }
            let succeeds = mode != .cancel && mode != .taskCancel && mode != .allFatal
            expect(values.filter { $0 == "reconnected" }.count == (succeeds ? 1 : 0), "only a healthy attempt emits one reconnected")
            expect(TelemetryCounters.shared.reconnectTotal.value.use { $0 } - before == (succeeds ? 1 : 0), "telemetry agrees with accepted attempts")
            expect(!state.0, "episode finishes its ownership")
            let retried = mode == .deadlineFatal || mode == .rearmFatal || mode == .notifyBeforeStop
            expect(stats.0 == (retried ? 2 : (mode == .allFatal ? 3 : 1)), "failure consumes remaining attempts instead of false success")
            expect(stats.1.dropLast().allSatisfy { $0 == 1 }, "old failed sinks clean exactly once before replacement")
            expect(banners.count == 2 && banners.first! == "Reconnecting…" && banners.last! == nil, "failed attempts do not hide/recreate recovery banner")
            if mode == .allFatal { expect(values == Array(repeating: "reconnecting", count: 4) + ["terminated"], "each failed attempt reasserts recovery without a false success") }
            if mode == .cancel || mode == .taskCancel { expect(stats.1 == [1], "cancel cleanup remains singular") }
            if succeeds {
                await session.handleHostTerminate(code: -1, from: await session.backend)
                expect(await session.state().1 == 1, "post-commit current failure follows ordinary live handling")
            }
            await session.finalCleanup()
            expect(await schedule.stats().1.allSatisfy { $0 == 1 }, "every synthetic sink cleaned exactly once")
            stopHook.use { $0 = nil }; rearmHook.use { $0 = nil }
        }
        print("{\"status\":\"passed\",\"reconnectFatalRaceChecks\":\(checks),\"scope\":\"production actor termination/success/bounded episode, event adapter, callback and native cleanup slices; inert network/deadline/watchdog schedules, no device\"}")
    }
}
'''
reconnect_fixture = reconnect_fixture.replace("__VIDEO_FAILURE_CLOSURE__", block(pipeline, "receiver.onReceiveFailed ="))
reconnect_fixture = reconnect_fixture.replace("__BACKEND_METHODS__", "\n".join(
    block(backend, signature).replace("package func", "func", 1)
    for signature in ("package func stopConnection()", "package func interruptConnection()")))
reconnect_fixture = reconnect_fixture.replace("__EVENT_METHODS__", "\n".join(
    block(events_source, signature).replace("package func", "func", 1)
    for signature in ("private func enqueueSessionEvent(", "package func connectionTerminated(")))
reconnect_fixture = reconnect_fixture.replace("__TERMINATE_PREFIX__", terminate_prefix.replace("package func", "func", 1))
reconnect_fixture = reconnect_fixture.replace("__ATTEMPT_METHODS__", "\n".join(
    block(reconnect, signature) for signature in ("private func reconnectAttemptIsHealthy(",
                                                "private func checkReconnectAttempt(", "private func tearDownSlippedInReconnect(")))
reconnect_fixture = reconnect_fixture.replace("__EPISODE__", block(reconnect, "private func runReconnectEpisode("))
reconnect_fixture = reconnect_fixture.replace("__TEARDOWN__", teardown)
reconnect_fixture = reconnect_fixture.replace("__SELECTION__", selection)
reconnect_fixture = reconnect_fixture.replace("__ATTEMPT_TAIL__", attempt_tail)
reconnect_fixture = reconnect_fixture.replace("__BUDGET__", block(reconnect, "package struct ReconnectBudget").replace("package ", ""))
with tempfile.TemporaryDirectory(prefix="knot-reconnect-fatal-", dir="/tmp") as directory:
    temporary = Path(directory)
    source = temporary / "Checks.swift"
    source.write_text(reconnect_fixture)
    executable = temporary / "checks"
    argv = ["/usr/bin/swiftc", "-swift-version", "6", "-parse-as-library", "-O",
            "-module-cache-path", str(temporary / "module-cache"), str(source), "-o", str(executable)]
    print(json.dumps({"compileArgv": argv, "checksArgv": [str(executable)]}), flush=True)
    subprocess.run(argv, check=True, timeout=90)
    subprocess.run([str(executable)], check=True, timeout=30)
    print(json.dumps({"reconnectFatalFixtureSHA256": hashlib.sha256(reconnect_fixture.encode()).hexdigest(),
                      "productionSourceSHA256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                                 for path in (ENGINE / "Session/StreamSession.swift", ENGINE / "Session/StreamSession+Reconnect.swift",
                                                              ENGINE / "Session/NativeConnectionEvents.swift", ENGINE / "Session/NativeBackend.swift",
                                                              ENGINE / "Session/NativeBackend+Pipeline.swift")}}))



# Public recovery must become honest again if a replacement dies after its first
# decoded frame. Execute current production callback wiring, bridge fencing,
# ordered public event source, termination prefix and complete shell reducer.
# Only backend/video/presentation resources are inert; no sockets or media open.
import re

recovery_paths = {
    "reconnect": ENGINE / "Session/StreamSession+Reconnect.swift",
    "start": ENGINE / "Session/StreamSession+Start.swift",
    "bridge": ENGINE / "Session/StreamBridgeContext.swift",
    "events": ENGINE / "Session/SessionEventSource.swift",
    "public": ENGINE / "Session/StreamSession+Public.swift",
    "presentation": ROOT / "Sources/DeskBridgeApp/Streaming/DesktopRecoveryPresentation.swift",
}
recovery_sources = {key: path.read_text() for key, path in recovery_paths.items()}
recovery_terminate = block(recovery_sources["reconnect"], "package func handleHostTerminate(")
recovery_prefix = recovery_terminate[:recovery_terminate.index("        // The uplink is dead")] + "    }"
recovery_types = (ENGINE / "Models/Types.swift").read_text()
recovery_constants = "\n".join(re.findall(
    r"^    package static let (?:deadPeer|protectedContent|frameConversion|noVideoTraffic|noVideoFrame)TerminationCode[^\n]*",
    (ENGINE / "Session/StreamSession.swift").read_text() + "\n" +
    (ENGINE / "Session/StreamSession+FrameWatchdog.swift").read_text(), re.M))
assert len(recovery_constants.splitlines()) == 5
recovery_contract = "\n".join([
    block(recovery_types, "public enum StreamEvent:"),
    block(recovery_types, "public enum ConnectionQuality:"),
    block(recovery_types, "public enum StreamError:"),
    (ENGINE / "Models/StreamFailure.swift").read_text(),
    (ENGINE / "Models/StreamFailureCopy.swift").read_text(),
    "public enum StreamConnection {\n" + block((ENGINE / "Session/StreamConnection.swift").read_text(), "public enum Failure:") + "\n}",
    block((ENGINE / "Session/StreamSession+Attempt.swift").read_text(), "package struct TakeoverRequired:"),
    "public enum StreamInput { public enum Event: Sendable {} }",
])
recovery_fixture = r'''
import Foundation
__CONTRACT__
__PRESENTATION__
__EVENT_SOURCE__
final class NativeBackend: @unchecked Sendable {}
final class StreamBridgeContext: @unchecked Sendable {
    private let sourceLock = NSLock()
    private var attemptID = UUID()
    private var eventSource: ObjectIdentifier?
    private var audioEventsQuiesced = false
    let publicEvents: SessionEventSource?
    var eventContinuation: AsyncStream<StreamEvent>.Continuation?
    init(_ events: SessionEventSource) { publicEvents = events }
    __BRIDGE_METHODS__
}
@MainActor final class Video {
    var onHDRActiveChanged: ((Bool) -> Void)?
    var onFirstDecodedFrame: (() -> Void)?
}
@MainActor final class SessionPresentation { var firstFrame: () -> Void = {} }
struct SessionMedia { let video: Video; let presentation: SessionPresentation }
public final class StreamSession: @unchecked Sendable {
    __UPDATE__
    __CONSTANTS__
    let backend = NativeBackend()
    var bridge: StreamBridgeContext?
    var isStreaming = true, stopInProgress = false, isReconnecting = true
    var attemptID: UUID, reconnectAttemptID: UUID?, reconnectAttemptFailure: Int32?
    var lastReconnectError: StreamError?
    init(bridge: StreamBridgeContext, attempt: UUID) {
        self.bridge = bridge; attemptID = attempt; reconnectAttemptID = attempt
    }
    @MainActor __TERMINATION_PREFIX__
    @MainActor __WIRE__
}
@main struct PublicRecoveryChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ name: String) throws {
            guard condition() else { throw NSError(domain: name, code: checks) }; checks += 1
        }
        func label(_ event: StreamEvent) -> String {
            switch event {
            case .firstFrame: "frame"
            case .reconnecting: "reconnecting"
            default: "unexpected"
            }
        }
        func collect(_ source: SessionEventSource) async -> [StreamSession.Update] {
            source.finish()
            var values: [StreamSession.Update] = []
            for await update in source.stream { values.append(update) }
            return values
        }
        let source = SessionEventSource(); _ = source.stream
        let bridge = StreamBridgeContext(source), attempt = UUID()
        let session = StreamSession(bridge: bridge, attempt: attempt)
        bridge.setEventSource(session.backend, attempt: attempt)
        let video = Video(), presentation = SessionPresentation()
        var deliveredFrames = 0
        presentation.firstFrame = { deliveredFrames += 1 }
        let media = SessionMedia(video: video, presentation: presentation)
        session.wireMediaCallbacks(setup: media, bridge: bridge, attempt: attempt)
        let failedFrame = video.onFirstDecodedFrame!
        bridge.emit(.reconnecting); failedFrame()
        await session.handleHostTerminate(code: -1, from: session.backend)
        let retiredEpoch = bridge.currentAttempt
        try expect(retiredEpoch != attempt, "first current failure retires callback epoch")
        try expect(session.attemptID == attempt && session.reconnectAttemptID == attempt,
                   "callback fence preserves session and sticky-latch attempt IDs")
        try expect(session.reconnectAttemptFailure == -1, "current failure stays latched")
        try expect(!bridge.acceptsEvent(from: session.backend, attempt: attempt), "failed native callback attempt rejected")
        failedFrame()
        bridge.emit(.firstFrame, source: session.backend, attempt: attempt)
        try expect(deliveredFrames == 1, "late failed decoder frame never reaches presentation callback")
        await session.handleHostTerminate(code: -2, from: session.backend)
        try expect(bridge.currentAttempt == retiredEpoch && session.reconnectAttemptFailure == -1,
                   "duplicate failure neither resets epoch nor replaces first failure")
        let next = UUID()
        session.attemptID = next; session.reconnectAttemptID = next; session.reconnectAttemptFailure = nil
        bridge.setEventSource(session.backend, attempt: next)
        session.wireMediaCallbacks(setup: media, bridge: bridge, attempt: next)
        video.onFirstDecodedFrame?()
        try expect(deliveredFrames == 2 && bridge.acceptsEvent(from: session.backend, attempt: next),
                   "next fresh attempt decoder and native callbacks accepted")
        let updates = await collect(source)
        try expect(updates.map { label($0.event) } == ["reconnecting", "frame", "reconnecting", "frame"],
                   "one failure reassertion and no late/duplicate public frame")
        try expect(updates[1].attemptID == attempt && updates[2].attemptID == retiredEpoch && updates[3].attemptID == next,
                   "ordered public updates retain actual epochs")
        var recovery = DesktopRecoveryPresentation()
        recovery.receive(updates[0].event); recovery.receive(updates[1].event)
        try expect(recovery.phase == .live && recovery.message == nil, "actual reducer is live after original frame")
        recovery.receive(updates[2].event)
        try expect(recovery.phase == .reconnecting && recovery.message != nil, "actual reducer restores recovery card after current failure")
        recovery.receive(updates[3].event)
        try expect(recovery.phase == .live && recovery.message == nil, "only next fresh frame clears recovery card")
        for mode in ["stale", "wake", "stopping", "stopped", "old-drain"] {
            let events = SessionEventSource(); _ = events.stream
            let bridge = StreamBridgeContext(events), id = UUID()
            let session = StreamSession(bridge: bridge, attempt: id)
            bridge.setEventSource(session.backend, attempt: id)
            let video = Video(), media = SessionMedia(video: video, presentation: SessionPresentation())
            session.wireMediaCallbacks(setup: media, bridge: bridge, attempt: id)
            bridge.emit(.reconnecting); video.onFirstDecodedFrame?()
            if mode == "stopping" { session.stopInProgress = true }
            if mode == "stopped" { session.isStreaming = false }
            if mode == "old-drain" { session.reconnectAttemptID = nil }
            let producer: NativeBackend? = mode == "wake" ? nil : (mode == "stale" ? NativeBackend() : session.backend)
            await session.handleHostTerminate(code: -1, from: producer)
            try expect(bridge.currentAttempt == id && session.reconnectAttemptFailure == nil,
                       "\(mode) does not retire epoch or latch failure")
            let values = await collect(events)
            try expect(values.map { label($0.event) } == ["reconnecting", "frame"],
                       "\(mode) does not add a recovery reset")
        }
        print("{\"status\":\"passed\",\"publicRecoveryChecks\":\(checks),\"scope\":\"current production termination prefix, decoder callback wiring, bridge methods, public FIFO and complete shell reducer; inert backend/video only\"}")
    }
}
'''
recovery_fixture = recovery_fixture.replace("__CONTRACT__", recovery_contract)
recovery_fixture = recovery_fixture.replace("__PRESENTATION__", recovery_sources["presentation"])
recovery_fixture = recovery_fixture.replace("__EVENT_SOURCE__", recovery_sources["events"])
recovery_fixture = recovery_fixture.replace("__UPDATE__", block(recovery_sources["public"], "public struct Update:"))
recovery_fixture = recovery_fixture.replace("__CONSTANTS__", recovery_constants)
recovery_fixture = recovery_fixture.replace("__TERMINATION_PREFIX__", recovery_prefix)
recovery_fixture = recovery_fixture.replace("__WIRE__", block(recovery_sources["start"], "package func wireMediaCallbacks("))
recovery_fixture = recovery_fixture.replace("__BRIDGE_METHODS__", "\n".join(
    block(recovery_sources["bridge"], signature) for signature in (
        "package var currentAttempt:", "package func beginAttempt(", "package func setEventSource(",
        "package func acceptsEvent(", "package func emit(")))
recovery_fixture = recovery_fixture.replace("package ", "").replace("import GlimmerEngine\n", "")
with tempfile.TemporaryDirectory(prefix="knot-public-recovery-", dir="/tmp") as directory:
    temporary = Path(directory)
    source = temporary / "Checks.swift"
    source.write_text(recovery_fixture)
    executable = temporary / "checks"
    argv = ["/usr/bin/swiftc", "-swift-version", "6", "-parse-as-library", "-O",
            "-module-cache-path", str(temporary / "module-cache"), str(source), "-o", str(executable)]
    print(json.dumps({"compileArgv": argv, "checksArgv": [str(executable)]}), flush=True)
    subprocess.run(argv, check=True, timeout=90)
    subprocess.run([str(executable)], check=True, timeout=30)
    print(json.dumps({"publicRecoveryFixtureSHA256": hashlib.sha256(recovery_fixture.encode()).hexdigest(),
                      "productionSourceSHA256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                                 for path in recovery_paths.values()}}))
