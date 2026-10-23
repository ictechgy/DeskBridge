#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Complete production ENet termination producers against fresh inert dependencies.

Compiles real AES-GCM, replay, reliable admission, ACK, control-loop and callback
priority. No socket, runtime history, app preferences or device is opened.
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
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def make_fixture():
    support = (ROOT / "Sources/DeskBridgeChecks/ControlReplaySyntheticChecks.swift").read_text()
    deps = support[support.index("// Inert dependencies replace"):]
    for signature in ("    static let controlTickMs:", "    static func msSince(", "    func declarePeerDead("):
        if "func " in signature:
            deps = deps.replace(block(deps, signature), "", 1)
        else:
            deps = "\n".join(line for line in deps.splitlines() if not line.startswith(signature))
    deps = deps.replace("    static func notice(_ message: DiagMessage, _ category: String) {}",
                        "    static let noticeHook = Hook()\n    static func notice(_ message: DiagMessage, _ category: String) { noticeHook.fire() }")
    deps = deps.replace("    static func error(_ message: DiagMessage, _ category: String) {}",
                        "    static let errorHook = Hook()\n    static func error(_ message: DiagMessage, _ category: String) { errorHook.fire() }")
    deps = deps.replace("final class TelemetryCounters:", "final class InertCounter: Sendable { func increment(by amount: UInt64 = 1) {} }\nfinal class TelemetryCounters:", 1)
    deps = deps.replace("    let p2 = SyntheticControlP2()", "    let ackSilenceNearMissTotal = InertCounter(), enetRetransmitTotal = InertCounter()\n    let p2 = SyntheticControlP2()", 1)
    bridge = (ENGINE / "Session/StreamBridgeContext.swift").read_text()
    methods = "\n".join(block(bridge, s).replace("package ", "") for s in (
        "package func setEventSource(", "package func admitTermination(", "package func terminationIntent("))
    inbound = (ENGINE / "Network/EnetControlChannel+Inbound.swift").read_text()
    assert inbound.count("handleInboundControl(inner)") == 1
    assert "for inner in result.due { handleInboundControl(inner) }" in inbound
    assert "guard let inner = openInboundControl(bytes) else { return nil }" in inbound
    assert "authenticatedTermination: true" in block(inbound, "func handleInboundControl(")
    fixture = r'''
#if DESKBRIDGE_CONTROL_REPLAY_SYNTHETIC_CHECKS
import Foundation
import CryptoKit
import Network
final class Hook: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: (@Sendable () -> Void)?
    func set(_ value: @escaping @Sendable () -> Void) { lock.withLock { operation = value } }
    func fire() { let value = lock.withLock { let value = operation; operation = nil; return value }; value?() }
}
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var codes: [Int32] = [], admissions: [Bool] = []
    func append(_ code: Int32, admitted: Bool) { lock.withLock { codes.append(code); admissions.append(admitted) } }
    var values: [Int32] { lock.withLock { codes } }
    var accepted: [Bool] { lock.withLock { admissions } }
}
final class Epoch: Sendable { func beginAttempt(_ id: UUID) {} }
final class NativeBackend: @unchecked Sendable {}
final class IntentBridge: @unchecked Sendable {
    private let sourceLock = NSLock()
    private var eventSource: ObjectIdentifier?, terminationSource: ObjectIdentifier?
    private var attemptID = UUID(), terminationAttempt: UUID?
    private var terminationEventsRetired = true, audioEventsQuiesced = false
    private var admittedTerminationCode: Int32?
    let publicEvents: Epoch? = nil
    __BRIDGE__
}
@main struct EnetTerminationChecks {
    static let key = [UInt8](0..<16)
    static let pc = Int32(bitPattern: 0x80030023)
    __MAKE_PEER__
    __DATAGRAM__
    static func terminationFrame(sequence: UInt32, code: Int32 = pc) throws -> [UInt8] {
        var iv = [UInt8](repeating: 0, count: 12)
        for index in 0..<4 { iv[index] = UInt8(truncatingIfNeeded: sequence >> (index * 8)) }
        iv[10] = 0x48; iv[11] = 0x43
        let type = CtrlV2.termination, raw = UInt32(bitPattern: code)
        let plain: [UInt8] = [UInt8(type & 0xff), UInt8(type >> 8), 4, 0,
                             UInt8(truncatingIfNeeded: raw >> 24), UInt8(truncatingIfNeeded: raw >> 16),
                             UInt8(truncatingIfNeeded: raw >> 8), UInt8(truncatingIfNeeded: raw)]
        let sealed = try AES.GCM.seal(Data(plain), using: SymmetricKey(data: Data(key)), nonce: AES.GCM.Nonce(data: Data(iv)))
        let length = UInt16(20 + plain.count)
        return [1, 0, UInt8(length & 0xff), UInt8(length >> 8)] + Array(iv[0..<4]) + Array(sealed.tag) + Array(sealed.ciphertext)
    }
    static func age(_ peer: EnetControlChannel) {
        peer.withState {
            let old = peer.serviceTimeMs &- EnetControlChannel.ackSilenceDeadMs
            peer.lastAckRecvMs = old
            peer.sentReliable.append(SentReliable(channelID: 0, reliableSequenceNumber: 1,
                commandBytes: [], sentAtMs: old, firstSentAtMs: old, attempts: 1))
        }
    }
    static func tick(_ peer: EnetControlChannel) {
        let done = DispatchSemaphore(value: 0)
        Thread {
            var loop = EnetControlChannel.ControlLoopState()
            precondition(!peer.controlLoopTick(&loop), "actual ACK-silence tick must stop")
            done.signal()
        }.start()
        precondition(done.wait(timeout: .now() + 5) == .success, "dedicated tick must not deadlock in callback close")
    }
    static func bind(_ peer: EnetControlChannel, bridge: IntentBridge, owner: NativeBackend, attempt: UUID) -> Recorder {
        let recorder = Recorder()
        bridge.setEventSource(owner, attempt: attempt)
        peer.onTerminated = { code in
            recorder.append(code, admitted: bridge.admitTermination(code: code, from: owner, attempt: attempt))
            peer.close() // Actual close re-enters stateLock; callback must be outside it.
        }
        return recorder
    }
    static func main() throws {
        var checks = 0
        func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        for admittedFirst in [false, true] {
            let peer = try makePeer(), bridge = IntentBridge(), owner = NativeBackend(), attempt = UUID()
            let codes = bind(peer, bridge: bridge, owner: owner, attempt: attempt)
            let packet = datagram(try terminationFrame(sequence: 1), channel: 0, reliable: 1, sentTime: !admittedFirst)
            let incoming = DispatchQueue(label: "synthetic.enet.inbound")
            if admittedFirst {
                let admitted = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
                Diag.noticeHook.set { admitted.signal(); precondition(resume.wait(timeout: .now() + 5) == .success) }
                incoming.async { peer.onDatagram(packet); finished.signal() }
                expect(admitted.wait(timeout: .now() + 5) == .success, "authenticated packet admitted before concurrent local death")
                expect(peer.inboundReliableHistory.count == 1 && peer.inboundOrder[0]?.next == 2 && !peer.disconnected && !peer.interrupted.isSet,
                       "real GCM/replay/order/ACK seam precedes local death")
                age(peer); tick(peer)
                expect(codes.values == [-1] && peer.interrupted.isSet, "local callback closes before authenticated host dispatch")
                resume.signal()
                expect(finished.wait(timeout: .now() + 5) == .success, "admitted host dispatch completes after close")
                expect(codes.values == [-1, pc], "already-authenticated PC intent upgrades the closed local failure exactly once")
            } else {
                Diag.errorHook.set {
                    let done = DispatchSemaphore(value: 0)
                    incoming.async { peer.onDatagram(packet); done.signal() }
                    precondition(done.wait(timeout: .now() + 5) == .success)
                }
                age(peer); tick(peer)
                expect(Set(codes.values) == Set([-1, pc]) && codes.values.count == 2, "post-latch/pre-callback PC upgrade survives either callback ordering")
                expect(peer.inboundReliableHistory.count == 1 && peer.inboundOrder[0]?.next == 2, "PC reason passes real crypto and reliable admission")
            }
            expect(bridge.terminationIntent(from: owner, attempt: attempt) == pc, "actual bridge retains PC priority over out-of-order local callback")
            expect(peer.notifiedTerminationCode == pc && peer.disconnected && peer.interrupted.isSet, "upgrade never resurrects channel state")
            peer.onDatagram(packet) // Exact duplicate may ACK; must not redispatch.
            peer.onDatagram(datagram(try terminationFrame(sequence: 2, code: Int32(bitPattern: 0x80030013)), channel: 0, reliable: 2, sentTime: true))
            peer.declarePeerDead(code: -1, reason: "duplicate local failure")
            expect(codes.values.count == 2 && peer.notifiedTerminationCode == pc, "first explicit PC code bounds all later callback attempts")
        }
        let peer = try makePeer(), bridge = IntentBridge(), owner = NativeBackend(), attempt = UUID()
        let codes = bind(peer, bridge: bridge, owner: owner, attempt: attempt)
        age(peer); tick(peer)
        let good = try terminationFrame(sequence: 11)
        var forged = good; forged[8] ^= 0x80
        let ackBefore = SyntheticControlIO.shared.ackCount
        peer.onDatagram(datagram(forged, channel: 0, reliable: 1, sentTime: true))
        peer.onDatagram(datagram([0x09, 0x01, 4, 0, 0x80, 0x03, 0, 0x23], channel: 0, reliable: 1, sentTime: true))
        peer.declarePeerDead(code: pc, reason: "untrusted caller does not establish authenticated intent")
        expect(codes.values == [-1] && peer.notifiedTerminationCode == -1, "forged/plaintext/non-authenticated reports cannot upgrade")
        expect(peer.inboundReliableHistory.count == 0 && peer.inboundOrder.isEmpty && SyntheticControlIO.shared.ackCount == ackBefore,
               "rejected ciphertext/plaintext neither ACKs nor moves authenticated state")
        peer.onDatagram(datagram(good, channel: 0, reliable: 1, sentTime: true))
        expect(codes.values == [-1, pc] && bridge.terminationIntent(from: owner, attempt: attempt) == pc, "rejection does not poison subsequent legitimate PC upgrade")
        peer.onDatagram(datagram(good, channel: 0, reliable: 2, sentTime: true))
        expect(codes.values.count == 2 && peer.inboundOrder[0]?.next == 2, "relabeled replay cannot trigger another callback or advance order")
        let retired = try makePeer(), retiredBridge = IntentBridge(), retiredOwner = NativeBackend(), oldAttempt = UUID()
        let retiredCodes = bind(retired, bridge: retiredBridge, owner: retiredOwner, attempt: oldAttempt)
        age(retired); tick(retired)
        expect(retiredBridge.terminationIntent(from: retiredOwner, attempt: oldAttempt, retiring: true) == -1, "explicit retirement captures local reason")
        retired.onDatagram(datagram(try terminationFrame(sequence: 21), channel: 0, reliable: 1, sentTime: true))
        expect(retiredCodes.values == [-1, pc] && retiredCodes.accepted == [true, false], "upstream PC upgrade cannot resurrect explicitly retired bridge")
        expect(retiredBridge.terminationIntent(from: retiredOwner, attempt: oldAttempt) == -1, "retired source retains its frozen snapshot")
        print("{\"status\":\"passed\",\"enetTerminationProducerChecks\":\(checks),\"scope\":\"complete production ENet channel/control-loop/receive/GCM/replay/order/ACK/send and actual bridge admission; inert connection/logging/telemetry; no sockets/devices\"}")
    }
}
'''
    fixture = fixture.replace("__BRIDGE__", methods).replace("__MAKE_PEER__", block(support, "    static func makePeer(")).replace("__DATAGRAM__", block(support, "    static func datagram("))
    return fixture + deps


if __name__ == "__main__":
    fixture = make_fixture()
    sources = ["Protocol/StreamCrypto.swift", "Protocol/EnetWire.swift", "Diagnostics/AtomicCounter.swift",
               "Network/EnetControlChannel.swift", "Network/EnetControlChannel+Inbound.swift", "Network/EnetControlChannel+Send.swift",
               "Network/EnetControlChannel+ControlMessages.swift", "Network/EnetControlChannel+ControlLoop.swift"]
    with tempfile.TemporaryDirectory(prefix="knot-enet-termination-", dir="/tmp") as directory:
        temporary = Path(directory); source = temporary / "Checks.swift"; source.write_text(fixture); executable = temporary / "checks"
        argv = ["/usr/bin/swiftc", "-swift-version", "6", "-package-name", "Glimmer", "-parse-as-library", "-O",
                "-target", "arm64-apple-macosx26.0", "-D", "DESKBRIDGE_CONTROL_REPLAY_SYNTHETIC_CHECKS",
                "-module-cache-path", str(temporary / "module-cache"), *[str(ENGINE / path) for path in sources], str(source), "-o", str(executable)]
        print(json.dumps({"compileArgv": argv, "checksArgv": [str(executable)]}), flush=True)
        subprocess.run(argv, check=True, timeout=90)
        subprocess.run([str(executable)], check=True, timeout=30)
        print(json.dumps({"enetTerminationFixtureSHA256": hashlib.sha256(fixture.encode()).hexdigest(),
                          "productionSourceSHA256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in [*[ENGINE / name for name in sources], ENGINE / "Session/StreamBridgeContext.swift", ROOT / "Sources/DeskBridgeChecks/ControlReplaySyntheticChecks.swift"]}}))
