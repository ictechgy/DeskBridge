// SPDX-License-Identifier: GPL-3.0-only
// Production crypto, channel state, inbound dispatch and send files, with inert dependencies.
// No socket, preferences, diagnostics store, identity, media or UI is initialized.
#if DESKBRIDGE_CONTROL_REPLAY_SYNTHETIC_CHECKS
import Foundation
import CryptoKit
import Network

private struct ControlReplayFailure: Error { let message: String }

@main
private struct ControlReplaySyntheticChecks {
    static let key = [UInt8](0..<16)

    static func main() throws {
        var checks = 0
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw ControlReplayFailure(message: message) }
            checks += 1
        }
        func inject(_ peer: EnetControlChannel, _ envelope: [UInt8], channel: UInt8 = 0,
                    reliable: UInt16, sentTime: Bool = true, acknowledged: Bool = true) throws {
            let before = SyntheticControlIO.shared.ackCount
            peer.onDatagram(datagram(envelope, channel: channel, reliable: reliable, sentTime: sentTime))
            try require(SyntheticControlIO.shared.ackCount == before + (acknowledged ? 1 : 0),
                        "only admitted reliable payloads and exact authenticated duplicates may be ACKed")
            guard acknowledged else { return }
            let high = UInt8(reliable >> 8), low = UInt8(reliable & 0xff)
            try require(SyntheticControlIO.shared.lastAck == [Enet.cmdAcknowledge, channel, high, low,
                                                             high, low, 0, sentTime ? 123 : 0],
                        "ACK must echo the incoming transport labels and timestamp, including retransmissions")
        }
        let peer = try makePeer()
        var delivered: [UInt16] = []
        peer.onRumble = { _, value, _ in delivered.append(value) }
        let original = try frame(sequence: 7)
        try inject(peer, original, reliable: 1)
        try inject(peer, original, reliable: 1, sentTime: false)
        var alteredDuplicate = original
        alteredDuplicate[8] ^= 0x80
        try inject(peer, alteredDuplicate, reliable: 1, acknowledged: false)
        try inject(peer, original, reliable: 2, acknowledged: false)
        try inject(peer, original, channel: 1, reliable: 1, acknowledged: false)
        try require(delivered == [7], "same envelope was dispatched more than once after relabeling")
        try require(peer.inboundOrder[0]?.next == 2 && peer.inboundOrder[0]?.held.isEmpty == true,
                    "relabeled replay advanced or occupied the original channel cursor")
        try require(peer.inboundOrder[1] == nil, "cross-channel replay created ordering state")
        try inject(peer, try frame(sequence: 8), reliable: 2)
        try require(delivered == [7, 8] && peer.inboundOrder[0]?.next == 3,
                    "relabeled replay displaced the legitimate next reliable")

        let reordered = try makePeer()
        var reorderedDelivery: [UInt16] = []
        reordered.onRumble = { _, value, _ in reorderedDelivery.append(value) }
        let held = try frame(sequence: 12)
        try inject(reordered, held, reliable: 2)
        try inject(reordered, held, reliable: 2, sentTime: false)
        try inject(reordered, alteredDuplicate, reliable: 2, acknowledged: false)
        try inject(reordered, held, reliable: 3, acknowledged: false)
        try inject(reordered, try frame(sequence: 10), channel: 1, reliable: 1)
        try require(reorderedDelivery == [10] && reordered.inboundOrder[0]?.next == 1
                    && reordered.inboundOrder[0]?.held.count == 1,
                    "held replay occupied a second slot or valid cross-channel reordering failed")
        try inject(reordered, try frame(sequence: 11), reliable: 1)
        try require(reorderedDelivery == [10, 11, 12] && reordered.inboundOrder[0]?.next == 3,
                    "valid reordered host counters must drain in reliable order")
        try inject(reordered, held, reliable: 2)
        try inject(reordered, held, reliable: 1, acknowledged: false)
        try inject(reordered, held, channel: 2, reliable: 1, acknowledged: false)
        try require(reordered.inboundOrder[2] == nil, "replay of a drained held packet created a new cursor")

        var forged = try frame(sequence: .max)
        forged[8] ^= 0x80
        try inject(peer, forged, reliable: 3, acknowledged: false)
        var forgedCounter = try frame(sequence: 9)
        forgedCounter[7] ^= 0x80
        try inject(peer, forgedCounter, reliable: 3, acknowledged: false)
        let nextFrame = try frame(sequence: 9)
        try inject(peer, nextFrame, reliable: 1, acknowledged: false)
        try require(peer.inboundOrder[0]?.next == 3, "forged high counters moved ENet state")
        try inject(peer, nextFrame, reliable: 3)
        try require(delivered == [7, 8, 9], "failed authentication poisoned the replay high watermark")

        // A rejected current label cannot ACK away the host's genuine retransmit.
        // Later authentic traffic waits, then drains when the missing valid frame arrives.
        let poisoned = try makePeer()
        var poisonDelivery: [UInt16] = []
        poisoned.onRumble = { _, value, _ in poisonDelivery.append(value) }
        for invalid in [[UInt8](arrayLiteral: 0, 0, 0, 0), [1, 0], Array(original.dropLast())] {
            try inject(poisoned, invalid, reliable: 1, acknowledged: false)
        }
        try require(poisoned.inboundOrder.isEmpty && poisoned.inboundReliableHistory.count == 0,
                    "invalid envelopes created ordering or authenticated duplicate state")
        try inject(poisoned, try frame(sequence: 33), reliable: 2)
        try require(poisonDelivery.isEmpty && poisoned.inboundOrder[0]?.next == 1
                    && poisoned.inboundOrder[0]?.held.count == 1,
                    "valid future reliable did not wait behind the rejected current label")
        let missing = try frame(sequence: 32)
        try inject(poisoned, missing, reliable: 1)
        try require(poisonDelivery == [32, 33] && poisoned.inboundOrder[0]?.next == 3
                    && poisoned.inboundOrder[0]?.held.isEmpty == true,
                    "genuine current retransmit failed to drain future authenticated payloads in order")
        try inject(poisoned, missing, reliable: 1, sentTime: false)

        let coalesced = try makePeer()
        var coalescedDelivery: [UInt16] = []
        coalesced.onRumble = { _, value, _ in coalescedDelivery.append(value) }
        let beforeCoalesced = SyntheticControlIO.shared.ackCount
        let rejectedCommand = datagram([0, 0], channel: 0, reliable: 1, sentTime: true)
        let acceptedCommand = datagram(try frame(sequence: 40), channel: 0, reliable: 1, sentTime: true)
        coalesced.onDatagram(rejectedCommand + acceptedCommand.dropFirst(4))
        try require(SyntheticControlIO.shared.ackCount == beforeCoalesced + 1
                    && coalescedDelivery == [40] && coalesced.inboundOrder[0]?.next == 2,
                    "a rejected complete command stopped or ACKed a later coalesced valid command")

        // Unencrypted ENet peer control uses channel 0xFF. A forged peer command
        // on a data channel must not ACK away an encrypted reliable with those
        // labels. Every complete command must still preserve coalesced parsing.
        let peerCommands: [UInt8] = [Enet.cmdVerifyConnect, Enet.cmdPing,
                                     Enet.cmdBandwidthLimit, Enet.cmdThrottleConfigure]
        let ignoredDataCommands: [UInt8] = [Enet.cmdSendUnreliable, Enet.cmdSendUnsequenced,
                                            Enet.cmdSendFragment, Enet.cmdSendUnreliableFragment]
        for command in peerCommands + ignoredDataCommands {
            for channel: UInt8 in [0, 1, Enet.peerChannelID] {
                let routed = try makePeer()
                var values: [UInt16] = []
                routed.onRumble = { _, value, _ in values.append(value) }
                let dataChannel: UInt8 = channel == Enet.peerChannelID ? 0 : channel
                let expectedValue = UInt16(100 + command)
                let data = datagram(try frame(sequence: UInt32(expectedValue)),
                                    channel: dataChannel, reliable: 1, sentTime: true)
                let beforeAck = SyntheticControlIO.shared.ackCount
                let beforeVerify = SyntheticControlIO.shared.verifyCount
                routed.onDatagram(commandDatagram(command, body: commandBody(command),
                                                  channel: channel, reliable: 1) + data.dropFirst(4))
                let peerControl = peerCommands.contains(command) && channel == Enet.peerChannelID
                try require(SyntheticControlIO.shared.ackCount == beforeAck + (peerControl ? 2 : 1),
                            "unencrypted commands may only ACK allowlisted peer-control labels")
                try require(values == [expectedValue] && routed.inboundOrder[dataChannel]?.next == 2,
                            "ignored/wrong-channel commands swallowed a coalesced authenticated reliable")
                try require(routed.inboundReliableHistory.count == 1,
                            "unencrypted command occupied authenticated duplicate history")
                let verifyRouted = command == Enet.cmdVerifyConnect && channel == Enet.peerChannelID
                try require(SyntheticControlIO.shared.verifyCount == beforeVerify + (verifyRouted ? 1 : 0)
                            && routed.connected == verifyRouted,
                            "wrong-channel VERIFY_CONNECT reached the handshake handler")
            }
        }
        for command in peerCommands {
            let flagged = try makePeer()
            let beforeFlagged = SyntheticControlIO.shared.ackCount
            flagged.onDatagram(commandDatagram(command, body: commandBody(command),
                                               channel: Enet.peerChannelID, reliable: 0x1234))
            try require(SyntheticControlIO.shared.ackCount == beforeFlagged + 1
                        && SyntheticControlIO.shared.lastAck == [Enet.cmdAcknowledge, Enet.peerChannelID,
                                                                0x12, 0x34, 0x12, 0x34, 0, 123],
                        "peer-control ACK changed its peer channel, sequence or received time")
            let unflagged = try makePeer()
            let beforeAck = SyntheticControlIO.shared.ackCount
            unflagged.onDatagram(commandDatagram(command, body: commandBody(command),
                                                 channel: Enet.peerChannelID, reliable: 1,
                                                 acknowledge: false))
            try require(SyntheticControlIO.shared.ackCount == beforeAck,
                        "peer-control commands without ACKNOWLEDGE were ACKed")
        }
        // A truncated fixed/declared body ends this datagram without an ACK or
        // state mutation; it must not poison the next complete datagram either.
        for command in (peerCommands + ignoredDataCommands).filter({ $0 != Enet.cmdPing }) {
            for channel: UInt8 in [0, 1, Enet.peerChannelID] {
                let truncated = try makePeer()
                let beforeAck = SyntheticControlIO.shared.ackCount
                let beforeVerify = SyntheticControlIO.shared.verifyCount
                truncated.onDatagram(commandDatagram(command, body: Array(commandBody(command).dropLast()),
                                                      channel: channel, reliable: 1))
                try require(SyntheticControlIO.shared.ackCount == beforeAck
                            && SyntheticControlIO.shared.verifyCount == beforeVerify
                            && !truncated.connected && truncated.inboundOrder.isEmpty
                            && truncated.inboundReliableHistory.count == 0,
                            "a truncated peer/data command ACKed or mutated admission state")
                try inject(truncated, try frame(sequence: 200 + UInt32(command)), reliable: 1)
                try require(truncated.inboundOrder[0]?.next == 2,
                            "a malformed preceding datagram poisoned the next reliable")

                let trailing = try makePeer()
                let validPrefix = datagram(try frame(sequence: 220 + UInt32(command)),
                                           channel: 0, reliable: 1, sentTime: true)
                let badSuffix = commandDatagram(command, body: Array(commandBody(command).dropLast()),
                                                 channel: channel, reliable: 2)
                let beforeTrailing = SyntheticControlIO.shared.ackCount
                trailing.onDatagram(validPrefix + badSuffix.dropFirst(4))
                try require(SyntheticControlIO.shared.ackCount == beforeTrailing + 1
                            && trailing.inboundOrder[0]?.next == 2
                            && trailing.inboundReliableHistory.count == 1 && !trailing.connected,
                            "a truncated coalesced suffix ACKed or discarded the admitted prefix")
            }
        }
        let unknown = try makePeer()
        let beforeUnknown = SyntheticControlIO.shared.ackCount
        let validAfterUnknown = datagram(try frame(sequence: 250), channel: 0, reliable: 1, sentTime: true)
        unknown.onDatagram(commandDatagram(15, body: [], channel: Enet.peerChannelID, reliable: 1)
                           + validAfterUnknown.dropFirst(4))
        try require(SyntheticControlIO.shared.ackCount == beforeUnknown && unknown.inboundOrder.isEmpty,
                    "an unknown command was ACKed or parsed through an unknowable body boundary")
        try inject(unknown, try frame(sequence: 250), reliable: 1)

        // A callback may tear down the transport; its admitted reliable must be ACKed first.
        let closing = try makePeer()
        let beforeClose = SyntheticControlIO.shared.ackCount
        var ackAtClose: Int?
        closing.onRumble = { _, _, _ in
            ackAtClose = SyntheticControlIO.shared.ackCount
            closing.close()
        }
        try inject(closing, try frame(sequence: 41), reliable: 1, sentTime: false)
        try require(ackAtClose == beforeClose + 1 && closing.interrupted.isSet,
                    "payload callback ran before its ACK or failed to exercise teardown")

        // Rotate the production duplicate history through its entire fixed ring. A
        // cached ciphertext from a previous UInt16 reliable cycle cannot ACK the
        // current label, even though its original binding is still retained.
        let rotating = try makePeer()
        let width = UInt32(ControlReplayWindow.capacity)
        let oldest = try frame(sequence: 0)
        try inject(rotating, oldest, channel: 1, reliable: 1)
        let beforeRotation = SyntheticControlIO.shared.ackCount
        for sequence in 1..<width {
            rotating.onDatagram(datagram(try frame(sequence: sequence), channel: 0,
                                         reliable: UInt16(sequence), sentTime: true))
        }
        try require(SyntheticControlIO.shared.ackCount - beforeRotation == Int(width - 1)
                    && rotating.inboundOrder[0]?.next == 0,
                    "valid reliable traffic did not advance to the UInt16 wrap boundary")
        try require(rotating.inboundReliableHistory.count == EnetAuthenticatedReliableHistory.capacity
                    && rotating.inboundReliableHistory.retainedSlotCount == EnetAuthenticatedReliableHistory.capacity,
                    "authenticated duplicate history did not reach its fixed capacity")
        try inject(rotating, oldest, channel: 1, reliable: 1)
        try inject(rotating, try frame(sequence: width), reliable: 0)
        try inject(rotating, oldest, channel: 1, reliable: 1, acknowledged: false)
        try inject(rotating, try frame(sequence: 1), reliable: 1, acknowledged: false)
        try require(rotating.inboundOrder[0]?.next == 1 && rotating.inboundOrder[0]?.held.isEmpty == true,
                    "historical ciphertext ACKed or advanced a new reliable cycle")
        let wrapped = try frame(sequence: width + 1)
        try inject(rotating, wrapped, reliable: 1)
        try inject(rotating, wrapped, reliable: 1, sentTime: false)
        try inject(rotating, wrapped, channel: 2, reliable: 1, acknowledged: false)
        try require(rotating.inboundReliableHistory.count <= EnetAuthenticatedReliableHistory.capacity
                    && rotating.inboundReliableHistory.retainedSlotCount == EnetAuthenticatedReliableHistory.capacity,
                    "duplicate history grew after ring eviction or reliable-label reuse")

        // Fill and rotate the fixed-size window using real AES-GCM envelopes. A missing
        // counter on the oldest live edge remains admissible; crossing that edge expires it.
        let crypto = try ControlCrypto(rikey: key)
        var window = ControlReplayWindow()
        _ = try crypto.open(try frame(sequence: 0), replayWindow: &window)
        for sequence in 2...width {
            _ = try crypto.open(try frame(sequence: sequence), replayWindow: &window)
        }
        try require(try crypto.open(try frame(sequence: 1), replayWindow: &window).count == 14,
                    "oldest unseen counter inside the bounded window was lost")
        for sequence in [UInt32(0), 1, width] {
            try require(rejects(crypto, try frame(sequence: sequence), window: &window),
                        "repeated or expired counter was accepted after ring rotation")
        }
        _ = try crypto.open(try frame(sequence: width * 3), replayWindow: &window)
        try require(rejects(crypto, try frame(sequence: width + 1), window: &window),
                    "a large authenticated jump failed to expire an unseen old counter")
        _ = try crypto.open(try frame(sequence: width * 3 - 1), replayWindow: &window)
        try require(rejects(crypto, try frame(sequence: width * 3 - 1), window: &window),
                    "large jump did not establish duplicate protection for reordered counters")

        var wrapWindow = ControlReplayWindow()
        _ = try crypto.open(try frame(sequence: .max), replayWindow: &wrapWindow)
        _ = try crypto.open(try frame(sequence: .max - 1), replayWindow: &wrapWindow)
        try require(rejects(crypto, try frame(sequence: 0), window: &wrapWindow),
                    "counter wrap must not reset replay protection")
        try require(rejects(crypto, try frame(sequence: .max), window: &wrapWindow),
                    "maximum counter replay must remain rejected")
        var freshWindow = ControlReplayWindow()
        try require(try crypto.open(original, replayWindow: &freshWindow).count == 14,
                    "fresh sessions must own independent receive state")

        // Exercise both production send paths at exhaustion, without creating a connection.
        for lastReliable in [true, false] {
            let sender = try makePeer()
            sender.enetSeq = .max - 1
            if lastReliable {
                _ = try sender.sendEncryptedControl(type: 1, payload: [], channel: 0, label: "synthetic")
            } else {
                try sender.sendEncryptedControlUnreliable(type: 1, payload: [], channel: 0, label: "synthetic")
            }
            let reliableCount = sender.sentReliable.count
            let unreliableCounter = sender.channelOutgoingUnreliableSeq[0]
            var failures = 0
            do { _ = try sender.sendEncryptedControl(type: 1, payload: [], channel: 0, label: "synthetic") }
            catch StreamCryptoError.counterExhausted { failures += 1 }
            do { try sender.sendEncryptedControlUnreliable(type: 1, payload: [], channel: 0, label: "synthetic") }
            catch StreamCryptoError.counterExhausted { failures += 1 }
            try require(failures == 2 && sender.enetSeq == .max && sender.sentReliable.count == reliableCount
                        && sender.channelOutgoingUnreliableSeq[0] == unreliableCounter,
                        "counter exhaustion must fail both send modes without nonce reuse or transport mutation")
        }
        print("Control authenticated replay and ACK admission: \(checks) synthetic checks passed; bounded replay/history; no sockets or app state")
    }

    static func rejects(_ crypto: ControlCrypto, _ envelope: [UInt8], window: inout ControlReplayWindow) -> Bool {
        do { _ = try crypto.open(envelope, replayWindow: &window); return false }
        catch StreamCryptoError.replayedCounter { return true }
        catch { return false }
    }

    static func makePeer() throws -> EnetControlChannel {
        EnetControlChannel(host: "192.0.2.1", port: 47999, controlConnectData: 0,
                           crypto: try ControlCrypto(rikey: key))
    }

    static func frame(sequence: UInt32) throws -> [UInt8] {
        var iv = [UInt8](repeating: 0, count: 12)
        for index in 0..<4 { iv[index] = UInt8(truncatingIfNeeded: sequence >> (index * 8)) }
        iv[10] = 0x48; iv[11] = 0x43
        // SS_RUMBLE_DATA: four reserved bytes, controller number, low and high motors.
        let plaintext: [UInt8] = [0x0b, 0x01, 0x0a, 0x00, 0, 0, 0, 0, 0, 0,
                                 UInt8(truncatingIfNeeded: sequence), UInt8(truncatingIfNeeded: sequence >> 8), 0, 0]
        let sealed = try AES.GCM.seal(Data(plaintext), using: SymmetricKey(data: Data(key)),
                                      nonce: AES.GCM.Nonce(data: Data(iv)))
        let length = UInt16(20 + plaintext.count)
        return [1, 0, UInt8(length & 0xff), UInt8(length >> 8)] + Array(iv[0..<4])
            + Array(sealed.tag) + Array(sealed.ciphertext)
    }

    static func datagram(_ envelope: [UInt8], channel: UInt8, reliable: UInt16, sentTime: Bool) -> [UInt8] {
        var bytes = ByteWriter()
        bytes.u16BE(sentTime ? Enet.headerFlagSentTime : 0)
        if sentTime { bytes.u16BE(123) }
        bytes.u8(Enet.cmdSendReliable | Enet.flagAcknowledge)
        bytes.u8(channel); bytes.u16BE(reliable); bytes.u16BE(UInt16(envelope.count)); bytes.append(envelope)
        return bytes.bytes
    }

    static func commandDatagram(_ command: UInt8, body: [UInt8], channel: UInt8,
                                reliable: UInt16, acknowledge: Bool = true) -> [UInt8] {
        var bytes = ByteWriter()
        bytes.u16BE(Enet.headerFlagSentTime); bytes.u16BE(123)
        bytes.u8(command | (acknowledge ? Enet.flagAcknowledge : 0))
        bytes.u8(channel); bytes.u16BE(reliable); bytes.append(body)
        return bytes.bytes
    }

    static func commandBody(_ command: UInt8) -> [UInt8] {
        switch command {
        case Enet.cmdVerifyConnect: return [UInt8](repeating: 0, count: 40)
        case Enet.cmdPing: return []
        case Enet.cmdBandwidthLimit: return [UInt8](repeating: 0, count: 8)
        case Enet.cmdThrottleConfigure: return [UInt8](repeating: 0, count: 12)
        case Enet.cmdSendUnreliable, Enet.cmdSendUnsequenced:
            return [0, 1, 0, 3, 0xaa, 0xbb, 0xcc]
        case Enet.cmdSendFragment, Enet.cmdSendUnreliableFragment:
            return [0, 1, 0, 3] + [UInt8](repeating: 0, count: 16) + [0xaa, 0xbb, 0xcc]
        default: preconditionFailure("unsupported synthetic command")
        }
    }
}

// Inert dependencies replace unrelated logging, telemetry and handshake, never the
// production replay, ENet admission, payload dispatch, ACK construction or send code.
private final class SyntheticControlIO: @unchecked Sendable {
    static let shared = SyntheticControlIO()
    private let lock = NSLock()
    private var acknowledgements = 0
    private var verifications = 0
    private var lastAcknowledgement: [UInt8]?
    var ackCount: Int { lock.withLock { acknowledgements } }
    var verifyCount: Int { lock.withLock { verifications } }
    var lastAck: [UInt8]? { lock.withLock { lastAcknowledgement } }
    func record(_ commands: [[UInt8]]) {
        lock.withLock {
            let acks = commands.filter { $0.first == Enet.cmdAcknowledge }
            acknowledgements += acks.count
            if let last = acks.last { lastAcknowledgement = last }
        }
    }
    func recordVerify() { lock.withLock { verifications += 1 } }
}
extension EnetControlChannel {
    static let controlTickMs: UInt32 = 20
    static func msSince(_ before: UInt32, now: UInt32) -> UInt32 { now &- before }
    func declarePeerDead(code: Int32, reason: DiagMessage, authenticatedTermination: Bool = false) { fatalError("synthetic peer must remain alive") }
    // This inert consumer tests parser routing/body isolation only. It does not
    // substitute for the production handshake's connectID/throttle validation.
    func handleVerifyConnect(_ reader: inout ByteReader) {
        precondition(reader.take(40) != nil && reader.remaining == 0)
        SyntheticControlIO.shared.recordVerify()
        connected = true
    }
    func wrapDatagram(commands: [[UInt8]], sentTime: Bool, recordRtt: Bool = true) -> [UInt8] {
        SyntheticControlIO.shared.record(commands)
        return commands.flatMap { $0 }
    }
}
struct HdrMetadata: Equatable {
    let displayPrimariesRX: UInt16, displayPrimariesRY: UInt16, displayPrimariesGX: UInt16, displayPrimariesGY: UInt16
    let displayPrimariesBX: UInt16, displayPrimariesBY: UInt16, whitePointX: UInt16, whitePointY: UInt16
    let maxDisplayLuminance: UInt16, minDisplayLuminance: UInt16, maxContentLightLevel: UInt16
    let maxFrameAverageLightLevel: UInt16, maxFullFrameLuminance: UInt16
}
final class InputCallbackProbe { func allowsGate(on queue: DispatchQueue) -> Bool { false } }
final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
struct InputTimingBatch: Sendable {
    func completed(sent: UInt64, at: UInt64) {}
    func submitted(at: UInt64) {}
}
struct DiagMessage: ExpressibleByStringInterpolation {
    init(stringLiteral: String) {}
    init(stringInterpolation: StringInterpolation) {}
    static func + (lhs: Self, rhs: Self) -> Self { lhs }
    struct StringInterpolation: StringInterpolationProtocol {
        enum Privacy { case `private` }
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ value: String) {}
        mutating func appendInterpolation<T>(_ value: T) {}
        mutating func appendInterpolation<T>(_ value: T, privacy: Privacy) {}
    }
}
enum Diag {
    static func info(_ message: DiagMessage, _ category: String) {}
    static func notice(_ message: DiagMessage, _ category: String) {}
    static func error(_ message: DiagMessage, _ category: String) {}
    static func debug(_ message: DiagMessage, _ category: String) {}
}
final class FrameTimingTracker: Sendable { static var shared: FrameTimingTracker? { nil } }
final class SyntheticControlP2: Sendable { func stampIdrRequest(_ value: UInt64) {} }
final class SyntheticRumbleActivity: Sendable { func stamp() {} }
final class TelemetryCounters: Sendable {
    static let shared = TelemetryCounters()
    static func monotonicNowNanos() -> UInt64 { 0 }
    let p2 = SyntheticControlP2()
    let rumbleActivity = SyntheticRumbleActivity()
    let rumbleEventTotal = AtomicCounter(), rumbleDroppedInvalidTotal = AtomicCounter()
    let idrRequestedTotal = AtomicCounter(), rfiTotal = AtomicCounter(), idrRoundTripRequestTotal = AtomicCounter()
    let enetGapOver20msTotal = AtomicCounter(), enetGapOver50msTotal = AtomicCounter(), enetGapOver100msTotal = AtomicCounter()
    func noteCtrlIgnored(type: UInt16) {}
}
#endif
