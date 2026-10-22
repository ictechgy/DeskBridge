// SPDX-License-Identifier: GPL-3.0-only
// Standalone checks of the production batcher/backend input slice. The regular
// checks executable excludes these fixtures; compile with the flag below plus:
// Network/{InputBatcher,InputSendThread}.swift, Session/NativeBackend+Input.swift,
// Protocol/{InputEncoder,EnetWire,StreamingBackend+Values}.swift, and
// Input/DesktopInputWire.swift from Vendor/Glimmer/GlimmerEngine.
// swiftc -swift-version 6 -package-name Glimmer -parse-as-library
//   -D DESKBRIDGE_INPUT_BATCHER_SYNTHETIC_CHECKS <sources> -o <fresh temp>/checks
#if DESKBRIDGE_INPUT_BATCHER_SYNTHETIC_CHECKS
import Foundation
import Darwin

private struct MotionCheckFailure: Error { let message: String }

@main
private struct InputBatcherSyntheticChecks {
    static func main() {
        do { print("Input batching checks: \(try run())") }
        catch { print("FAILED: \(error)"); exit(1) }
    }

    static func run() throws -> Int {
        var checks = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw MotionCheckFailure(message: message) }
            checks += 1
        }
        let peer = EnetControlChannel(), clock = SyntheticInputClock()
        let batcher = InputBatcher(enet: peer, now: { clock.now }, tracker: { nil },
                                   scheduleFlush: { clock.schedule(thread: $0, deadline: $1, action: $2) })
        defer { batcher.stop() }
        let backend = NativeBackend(batcher: batcher, peer: peer)
        backend.enableDesktopInputOrdering()
        peer.setBacklog(send: true, reliable: true)
        // Repeated due timer firings under real batcher backpressure must keep
        // exactly one latest position, rather than accepting 10,000 reliables.
        for x: Int16 in 1...10_000 {
            try require(backend.sendMousePosition(x: x, y: 8, refW: 30_000, refH: 20_000) == 0, "motion was not merged")
            if x.isMultiple(of: 10) { clock.fire() }
        }
        try require(peer.packets.isEmpty, "absolute motion bypassed backpressure")
        try require(clock.pendingCount == 1 && clock.maximumPendingCount == 1, "motion scheduled an unbounded timer queue")

        // Barriers intentionally drain one latest motion even while congested.
        try require(backend.sendKeyboard(keyCode: 65, action: 3, modifiers: 0, flags: 0) == 0, "key barrier failed")
        let latest = InputEncoder.mousePosition(x: 10_000, y: 8, refW: 30_000, refH: 20_000)
        let key = InputEncoder.keyboard(keyCode: 65, action: 3, modifiers: 0, flags: 0)
        try require(peer.packets.map(\.payload) == [latest, key], "key overtook latest absolute position")
        try require(peer.packets.allSatisfy { $0.channel == 2 }, "desktop motion left the shared reliable channel")

        for x: Int16 in 10_001...11_000 {
            _ = backend.sendMousePosition(x: x, y: 9, refW: 30_000, refH: 20_000)
        }
        try require(peer.packets.count == 2, "a second motion burst bypassed merging")
        try require(backend.sendUtf8Text("한") == 0, "text barrier failed")
        let beforeText = InputEncoder.mousePosition(x: 11_000, y: 9, refW: 30_000, refH: 20_000)
        try require(Array(peer.packets.suffix(2)).map(\.payload) == [beforeText, InputEncoder.utf8TextPackets("한")[0]], "text overtook pending absolute position")
        _ = backend.sendMousePosition(x: 11_111, y: 10, refW: 30_000, refH: 20_000)
        try require(peer.packets.count == 4, "later motion crossed the text barrier")
        try require(backend.sendMouseButton(action: 7, button: 1) == 0, "button barrier failed")
        let beforeClick = InputEncoder.mousePosition(x: 11_111, y: 10, refW: 30_000, refH: 20_000)
        try require(Array(peer.packets.suffix(2)).map(\.payload) == [beforeClick, InputEncoder.mouseButton(action: 7, button: 1)], "button overtook pending absolute position")

        // Switching absolute → relative → absolute drains the earlier mode;
        // desktop relative deltas use that same reliable channel as the edges.
        _ = backend.sendMousePosition(x: 123, y: 4, refW: 1000, refH: 1000)
        _ = backend.sendMouseMove(dx: 2, dy: 3)
        _ = backend.sendMousePosition(x: 456, y: 7, refW: 1000, refH: 1000)
        try require(peer.packets.count == 8, "relative/absolute mode barriers did not drain exactly once")
        peer.setBacklog(send: false, reliable: false)
        clock.fire()
        let modes = [InputEncoder.mousePosition(x: 123, y: 4, refW: 1000, refH: 1000),
                     InputEncoder.mouseMove(dx: 2, dy: 3),
                     InputEncoder.mousePosition(x: 456, y: 7, refW: 1000, refH: 1000)]
        try require(Array(peer.packets.suffix(3)).map(\.payload) == modes, "relative/absolute order changed")
        try require(peer.packets.allSatisfy { $0.channel == 2 }, "a desktop barrier changed reliable channels")
        let drainedCount = peer.packets.count
        clock.fire()
        try require(peer.packets.count == drainedCount, "a drained absolute position replayed")

        // Ordinary game pointer input keeps its original mouse channel.
        let gamePeer = EnetControlChannel(), gameClock = SyntheticInputClock()
        let gameBatcher = InputBatcher(enet: gamePeer, now: { gameClock.now }, tracker: { nil },
                                       scheduleFlush: { gameClock.schedule(thread: $0, deadline: $1, action: $2) })
        let gameBackend = NativeBackend(batcher: gameBatcher, peer: gamePeer)
        _ = gameBackend.sendMousePosition(x: 1, y: 2, refW: 100, refH: 100)
        try require(gamePeer.packets.isEmpty, "ordinary absolute motion stopped merging")
        _ = gameBackend.sendMouseButton(action: 7, button: 1)
        try require(gamePeer.packets.count == 2 && gamePeer.packets.allSatisfy { $0.channel == 3 }, "ordinary mouse channel changed")
        gameBatcher.stop()
        try require(gameBackend.sendMousePosition(x: 2, y: 3, refW: 100, refH: 100) == -2, "stopped batcher accepted motion")

        func fixture() -> (EnetControlChannel, SyntheticInputClock, InputBatcher) {
            let peer = EnetControlChannel(), clock = SyntheticInputClock()
            let batcher = InputBatcher(enet: peer, now: { clock.now }, tracker: { nil },
                scheduleFlush: { clock.schedule(thread: $0, deadline: $1, action: $2) })
            return (peer, clock, batcher)
        }

        // Reports and arrival pairs must report actual reliable acceptance. A
        // rejected arrival must never emit its dependent fallback packet.
        do {
            let (peer, _, batcher) = fixture(); defer { batcher.stop() }
            peer.scriptAcceptance([false])
            try require(batcher.passThroughReport([0xA1], channel: 16) == -1, "rejected report reported success")
            try require(peer.packets.isEmpty && peer.attempts.map(\.payload) == [[0xA1]], "report rejection changed wire state")
            try require(batcher.passThroughReport([0xA1], channel: 16) == 0, "report retry did not report acceptance")
            peer.scriptAcceptance([false])
            try require(batcher.passThroughPair([0xB1], [0xB2], channel: 16) == -1, "rejected first pair packet reported success")
            try require(peer.attempts.map(\.payload) == [[0xB1]], "pair sent fallback after rejected arrival")
            peer.scriptAcceptance([true, false])
            try require(batcher.passThroughPair([0xC1], [0xC2], channel: 16) == -1, "rejected second pair packet reported success")
            try require(peer.attempts.map(\.payload) == [[0xC1], [0xC2]] && peer.packets.last?.payload == [0xC1], "pair lost accepted first packet or accepted rejected second")
            try require(batcher.passThroughPair([0xD1], [0xD2], channel: 16) == 0, "accepted pair reported failure")
        }

        let barriers: [(String, (InputBatcher) -> Int32, [[UInt8]])] = [
            ("key", { $0.passThrough(key, channel: 2) }, [key]),
            ("button", { $0.passThrough(InputEncoder.mouseButton(action: 7, button: 1), channel: 2) }, [InputEncoder.mouseButton(action: 7, button: 1)]),
            ("text", { $0.passThroughText("한", channel: 2) }, InputEncoder.utf8TextPackets("한")),
            ("report", { $0.passThroughReport([0xE1], channel: 16) }, [[0xE1]]),
            ("pair", { $0.passThroughPair([0xF1], [0xF2], channel: 16) }, [[0xF1], [0xF2]])
        ]
        for (name, send, expected) in barriers {
            let (peer, clock, batcher) = fixture(); defer { batcher.stop() }
            _ = batcher.setAbsMouse(x: 12, y: 13, refW: 100, refH: 100, channel: 2)
            let motion = InputEncoder.mousePosition(x: 12, y: 13, refW: 100, refH: 100)
            peer.scriptAcceptance([false])
            try require(send(batcher) == -1, "\(name) ignored failed motion barrier")
            try require(peer.packets.isEmpty && peer.attempts.map(\.payload) == [motion], "\(name) overtook rejected motion")
            clock.fire()
            try require(peer.packets.map(\.payload) == [motion] && clock.pendingCount == 0, "\(name) barrier lost absolute retry")
            try require(send(batcher) == 0 && peer.packets.map(\.payload) == [motion] + expected, "\(name) retry did not follow accepted motion")
        }

        // A partial relative drain commits accepted chunks once and retains only
        // the unsent remainder, including both signs at the Int16 limits.
        do {
            let (peer, clock, batcher) = fixture(); defer { batcher.stop() }
            _ = batcher.accumulateMouseMove(dx: .max, dy: .min, channel: 2)
            _ = batcher.accumulateMouseMove(dx: .max, dy: .min, channel: 2)
            let chunk = InputEncoder.mouseMove(dx: .max, dy: .min)
            peer.scriptAcceptance([true, false])
            try require(batcher.passThrough(key, channel: 2) == -1, "partial relative drain did not reject later edge")
            try require(peer.packets.map(\.payload) == [chunk] && peer.attempts.map(\.payload) == [chunk, chunk], "partial relative drain committed wrong chunks")
            try require(clock.pendingCount == 1 && clock.maximumPendingCount == 1, "partial relative failure did not retain one timer")
            clock.fire()
            try require(peer.packets.map(\.payload) == [chunk, chunk] && clock.pendingCount == 0, "relative retry lost remainder or duplicated accepted chunk")
            clock.fire()
            try require(peer.packets.count == 2, "drained relative remainder replayed")
            try require(batcher.passThrough(key, channel: 2) == 0 && peer.packets.last?.payload == key, "edge remained blocked after relative recovery")
        }

        // A rejected mode/channel drain must keep the old slot intact and reject
        // the new input, rather than relabeling or overwriting retained motion.
        for relative in [false, true] {
            for switchMode in [false, true] {
                let (peer, clock, batcher) = fixture(); defer { batcher.stop() }
                let old = relative ? InputEncoder.mouseMove(dx: 5, dy: 6)
                    : InputEncoder.mousePosition(x: 5, y: 6, refW: 100, refH: 100)
                if relative { _ = batcher.accumulateMouseMove(dx: 5, dy: 6, channel: 3) }
                else { _ = batcher.setAbsMouse(x: 5, y: 6, refW: 100, refH: 100, channel: 3) }
                peer.scriptAcceptance([false])
                let nextRelative = switchMode ? !relative : relative
                let result = nextRelative
                    ? batcher.accumulateMouseMove(dx: 9, dy: 10, channel: 2)
                    : batcher.setAbsMouse(x: 9, y: 10, refW: 100, refH: 100, channel: 2)
                try require(result == -1 && peer.packets.isEmpty, "failed mouse mode/channel drain accepted replacement")
                clock.fire()
                try require(peer.packets.map(\.payload) == [old] && peer.packets[0].channel == 3, "mouse mode/channel failure overwrote retained slot")
                try require(clock.pendingCount == 0, "rejected mouse replacement remained queued")
            }
        }

        // Rejected reliable gyro-null state survives timer retries and blocks a
        // later edge. Supersedable nonzero sensor samples still drop on failure.
        do {
            let (peer, clock, batcher) = fixture(); defer { batcher.stop() }
            let accel = InputEncoder.controllerMotion(num: 0, motionType: 1, x: 1, y: 2, z: 3)
            let gyroNull = InputEncoder.controllerMotion(num: 0, motionType: 2, x: 0, y: 0, z: 0)
            _ = batcher.updateMotion(num: 0, motionType: 1, x: 1, y: 2, z: 3)
            _ = batcher.updateMotion(num: 0, motionType: 2, x: 0, y: 0, z: 0)
            peer.scriptAcceptance([true, false])
            clock.fire()
            try require(peer.packets.map(\.payload) == [accel] && clock.pendingCount == 1, "partial motion drain discarded rejected gyro-null state")
            peer.scriptAcceptance([false])
            try require(batcher.passThrough(key, channel: 2) == -1 && peer.attempts.map(\.payload) == [gyroNull], "edge overtook pending gyro-null retry")
            clock.fire()
            try require(peer.packets.map(\.payload) == [accel, gyroNull] && clock.pendingCount == 0, "gyro-null retry lost dirty count or duplicated state")
            _ = batcher.updateMotion(num: 0, motionType: 2, x: 1, y: 2, z: 3)
            peer.scriptAcceptance([false])
            clock.fire()
            try require(peer.packets.count == 2 && clock.pendingCount == 0, "superseded unreliable sensor sample became a reliable retry")
        }

        // Retained controller axes also form a barrier; the existing controller
        // edge policy remains responsible for retrying its own rejected edges.
        do {
            let (peer, clock, batcher) = fixture(); defer { batcher.stop() }
            let analog = GamepadAnalog(leftTrigger: 0, rightTrigger: 0,
                leftStickX: 20, leftStickY: 0, rightStickX: 0, rightStickY: 0)
            _ = batcher.updateController(num: 0, mask: 1, buttons: 0, analog: analog)
            peer.scriptAcceptance([false])
            try require(batcher.passThrough(key, channel: 2) == -1 && peer.packets.isEmpty, "edge overtook rejected controller state")
            clock.fire()
            try require(peer.packets.map(\.payload) == [InputEncoder.multiController(num: 0, mask: 1, buttons: 0, analog: analog)], "controller barrier lost retained axes")
        }

        do {
            let (peer, clock, batcher) = fixture()
            _ = batcher.accumulateMouseMove(dx: 5, dy: 6)
            peer.scriptAcceptance([false])
            clock.fire()
            batcher.stop()
            clock.fire() // Simulate an already-delivered timer racing with stop.
            try require(peer.packets.isEmpty && clock.pendingCount == 0, "stopped batcher replayed or rearmed retained state")
            try require(batcher.passThroughReport([1], channel: 16) == -2 && batcher.passThroughPair([1], [2], channel: 16) == -2, "stopped report/pair accepted input")
        }
        return checks
    }
}

/// Fresh in-memory acceptance records, not an ENet peer or network connection.
final class EnetControlChannel: @unchecked Sendable {
    struct Packet: Sendable { let payload: [UInt8]; let channel: UInt8 }
    private let lock = NSLock()
    private var records: [Packet] = []
    private var attempted: [Packet] = []
    private var acceptance: [Bool] = []
    private var sendBlocked = false
    private var reliableBlocked = false
    var packets: [Packet] { lock.withLock { records } }
    var attempts: [Packet] { lock.withLock { attempted } }
    var sendBacklogged: Bool { lock.withLock { sendBlocked } }
    var reliableBacklogged: Bool { lock.withLock { reliableBlocked } }
    var inputBacklogged: Bool { sendBacklogged || reliableBacklogged }
    func setBacklog(send: Bool, reliable: Bool) { lock.withLock { sendBlocked = send; reliableBlocked = reliable } }
    func scriptAcceptance(_ results: [Bool]) { lock.withLock { acceptance = results; attempted.removeAll() } }
    func sendInputPacket(_ payload: [UInt8], channel: UInt8, timing: InputTimingBatch? = nil) -> Bool {
        lock.withLock {
            let packet = Packet(payload: payload, channel: channel)
            attempted.append(packet)
            let accepted = acceptance.isEmpty ? true : acceptance.removeFirst()
            if accepted { records.append(packet) }
            return accepted
        }
    }
    func sendInputPacketUnreliable(_ payload: [UInt8], channel: UInt8) -> Bool { sendInputPacket(payload, channel: channel) }
    func estimatedRtt() -> (rttMs: Double, varianceMs: Double)? { nil }
    func health() -> (sentReliable: Int, oldestUnackedMs: UInt32, sinceLastAckMs: UInt32) { (0, 0, 0) }
    func requestIdrFrame() {}
    func reanchorAckAndPing() {}
    func hdrMetadata() -> HdrMetadata? { nil }
}

private final class SyntheticInputClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = DispatchTime(uptimeNanoseconds: 1_000_000_000)
    private var pending: (InputSendThread, @Sendable () -> Void)?
    private var maximumPending = 0
    var now: DispatchTime { lock.withLock { instant } }
    var pendingCount: Int { lock.withLock { pending == nil ? 0 : 1 } }
    var maximumPendingCount: Int { lock.withLock { maximumPending } }
    func schedule(thread: InputSendThread, deadline: DispatchTime, action: @escaping @Sendable () -> Void) {
        lock.withLock {
            precondition(pending == nil, "batcher replaced an armed flush")
            pending = (thread, action); maximumPending = max(maximumPending, 1)
        }
    }
    func fire() {
        let callback = lock.withLock {
            instant = instant + .milliseconds(1)
            let callback = pending; pending = nil; return callback
        }
        if let (thread, action) = callback { thread.sync { action(); return 0 } }
    }
}

// Inert dependencies for this isolated production-source slice. No singleton,
// preferences, diagnostics, stream/session, media or user input is initialized.
package final class NativeBackend {
    private let lock = NSLock()
    var inputReady = true
    var desktopInputOrdering = false
    var featureFlags: UInt32 = 0
    static let ffControllerTouchEvents: UInt32 = 2
    var inputBatcher: InputBatcher?
    var enetChannel: EnetControlChannel?
    init(batcher: InputBatcher, peer: EnetControlChannel) { inputBatcher = batcher; enetChannel = peer }
    func withState<T>(_ body: () -> T) -> T { lock.withLock(body) }
}
package struct HdrMetadata {}
enum StreamStageNames { static func name(for stage: Int32) -> String { "synthetic" } }
enum StreamProtocol {
    static let LI_ERR_UNSUPPORTED: Int32 = -5501
    static let LI_MOTION_TYPE_GYRO = 2
    static let STREAM_CFG_REMOTE: Int32 = 1
}
enum Diag { static func notice(_ message: String, _ category: String) {} }
struct InputEventTiming: Sendable {}
enum InputTimingContext {
    struct Capture { func samples() -> [InputEventTiming] { [] } }
    static func take() -> Capture? { nil }
}
struct InputTimingBatch {
    init?(_ samples: [InputEventTiming], tracker: FrameTimingTracker?) { nil }
}
final class SyntheticInputCounter: Sendable { func increment() {} }
final class SyntheticInputHistogram: Sendable { func observe(_ value: Double) {} }
final class SyntheticInputTrace: Sendable { func append(_ value: String) {} }
final class FrameTimingTracker: Sendable {
    static var shared: FrameTimingTracker? { nil }
    let inputTimingDropped = SyntheticInputCounter()
    let inputLocalLatency = SyntheticInputHistogram()
    let inputDeliverLatency = SyntheticInputHistogram()
    let traceWriter = SyntheticInputTrace()
    let sessionId = "synthetic"
    func noteInputLegs(_ value: Double) {}
}
final class TelemetryCounters: Sendable {
    static let shared = TelemetryCounters()
    let inputEventsTotal = SyntheticInputCounter()
    let inputMotionTotal = SyntheticInputCounter()
    let inputBatchFlushTotal = SyntheticInputCounter()
    let inputFlushSendBackloggedSkipTotal = SyntheticInputCounter()
    let inputFlushReliableBackloggedSkipTotal = SyntheticInputCounter()
    func noteInputEvent() {}
}
final class InputDeliverStamp: Sendable {
    static let shared = InputDeliverStamp()
    func take(slot: Int) -> UInt64 { 0 }
}
enum TelemetryRenderer { static func jsonNumber(_ value: Double) -> String { String(value) } }
#endif
