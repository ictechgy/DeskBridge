// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// Acceptance timestamps replace the encrypted ENet transport. Never injects OS input.
final class EnetControlChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var expected: [[UInt8]: UInt64] = [:]
    private var pendingMotion: [UInt64] = []
    private var motionPayloads = Set<[UInt8]>()
    private var newest: [Double] = []
    private var oldest: [Double] = []
    private var accepted = Set<[UInt8]>()
    private var acceptanceOrder: [[UInt8]] = []
    private var duplicates = 0
    private var invalid = 0
    var inputBacklogged: Bool { false }
    var sendBacklogged: Bool { false }
    var reliableBacklogged: Bool { false }
    func expect(_ payload: [UInt8], motion: Bool) {
        lock.withLock {
            let now = DispatchTime.now().uptimeNanoseconds
            expected[payload] = now
            if motion { motionPayloads.insert(payload); pendingMotion.append(now) }
        }
    }
    func sendInputPacket(_ payload: [UInt8], channel: UInt8, timing: InputTimingBatch? = nil) -> Bool {
        lock.withLock {
            let now = DispatchTime.now().uptimeNanoseconds
            guard channel == 2, let stamp = expected[payload] else { invalid += 1; return false }
            if !accepted.insert(payload).inserted { duplicates += 1 }
            acceptanceOrder.append(payload)
            newest.append(Double(now - stamp) / 1e6)
            if motionPayloads.contains(payload) {
                oldest.append(Double(now - (pendingMotion.first ?? stamp)) / 1e6)
                pendingMotion.removeAll(where: { $0 <= stamp })
            } else { oldest.append(Double(now - stamp) / 1e6) }
            return true
        }
    }
    func sendInputPacketUnreliable(_ payload: [UInt8], channel: UInt8) -> Bool { sendInputPacket(payload, channel: channel) }
    func estimatedRtt() -> (rttMs: Double, varianceMs: Double)? { nil }
    func health() -> (sentReliable: Int, oldestUnackedMs: UInt32, sinceLastAckMs: UInt32) { (0, 0, 0) }
    func requestIdrFrame() {}
    func reanchorAckAndPing() {}
    func hdrMetadata() -> HdrMetadata? { nil }
    func hasAccepted(_ payload: [UInt8]) -> Bool { lock.withLock { accepted.contains(payload) } }
    func barrierOrdered(_ barrier: [UInt8], after finalMotion: [UInt8]?) -> Bool {
        lock.withLock {
            guard acceptanceOrder.last == barrier, acceptanceOrder.filter({ $0 == barrier }).count == 1 else { return false }
            guard let finalMotion else { return true }
            guard let motion = acceptanceOrder.firstIndex(of: finalMotion), let edge = acceptanceOrder.firstIndex(of: barrier) else { return false }
            return motion < edge
        }
    }
    func snapshot() -> (newest: [Double], oldest: [Double], duplicates: Int, invalid: Int) {
        lock.withLock { (newest, oldest, duplicates, invalid) }
    }
}

@main
private struct InputBenchmark {
    static func main() throws {
        let repetitions = Int(CommandLine.arguments[2])!
        var rows: [[String: Any]] = []
        // Raw per-packet samples are retained; no end-to-end/input-to-screen interpretation.
        func run(profile: String, count: Int, intervalNs: UInt64, round: Int, warmup: Bool = false) throws {
            let peer = EnetControlChannel(), batcher = InputBatcher(enet: peer, tracker: { nil })
            let backend = NativeBackend(batcher: batcher, peer: peer)
            backend.enableDesktopInputOrdering()
            defer { batcher.stop() }
            let phaseOffsetNs = UInt64(round * 137_113 % 1_000_000)
            let jitterNs: Int64 = profile == "motion-1000Hz" ? 150_000 : 0
            let start = DispatchTime.now().uptimeNanoseconds + phaseOffsetNs
            var failures = 0, producerLate: [Double] = [], arrivalIntervals: [Double] = []
            var previousArrival: UInt64?
            for index in 1...count {
                let mixed = UInt64(index) &* 6364136223846793005 &+ UInt64(round) &* 1442695040888963407
                let jitter = jitterNs == 0 ? 0 : Int64((mixed >> 24) % UInt64(jitterNs * 2 + 1)) - jitterNs
                let deadline = UInt64(max(Int64(start), Int64(start + UInt64(index - 1) * intervalNs) + jitter))
                var now = DispatchTime.now().uptimeNanoseconds
                while now < deadline {
                    Thread.sleep(forTimeInterval: Double(deadline - now) / 1e9)
                    now = DispatchTime.now().uptimeNanoseconds
                }
                let arrival = DispatchTime.now().uptimeNanoseconds
                if let previousArrival { arrivalIntervals.append(Double(arrival - previousArrival) / 1e6) }
                previousArrival = arrival
                if intervalNs > 0 { producerLate.append(Double(arrival - deadline) / 1e6) }
                let result: Int32
                if profile == "keyboard-100Hz" {
                    let payload = InputEncoder.keyboard(keyCode: Int16(index), action: 3, modifiers: 0, flags: 0)
                    peer.expect(payload, motion: false)
                    result = backend.sendKeyboard(keyCode: Int16(index), action: 3, modifiers: 0, flags: 0)
                } else {
                    let payload = InputEncoder.mousePosition(x: Int16(index), y: 8, refW: 30000, refH: 20000)
                    peer.expect(payload, motion: true)
                    result = backend.sendMousePosition(x: Int16(index), y: 8, refW: 30000, refH: 20000)
                }
                if result != 0 { failures += 1 }
            }
            // A real production ordering barrier drains the final pending motion synchronously.
            let barrier = InputEncoder.keyboard(keyCode: 32000, action: 3, modifiers: 0, flags: 0)
            peer.expect(barrier, motion: false)
            if backend.sendKeyboard(keyCode: 32000, action: 3, modifiers: 0, flags: 0) != 0 { failures += 1 }
            batcher.stop()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            let samples = peer.snapshot()
            let finalMotion = InputEncoder.mousePosition(x: Int16(count), y: 8, refW: 30000, refH: 20000)
            guard failures == 0, samples.duplicates == 0, samples.invalid == 0,
                  !samples.newest.isEmpty, profile != "keyboard-100Hz" || samples.newest.count == count + 1 else {
                throw NSError(domain: "SyntheticInputBenchmark", code: 1)
            }
            guard profile == "keyboard-100Hz" || peer.hasAccepted(finalMotion) else {
                throw NSError(domain: "SyntheticInputBenchmarkFinalPosition", code: 1)
            }
            guard peer.barrierOrdered(barrier, after: profile == "keyboard-100Hz" ? nil : finalMotion) else {
                throw NSError(domain: "SyntheticInputBenchmarkBarrierOrder", code: 1)
            }
            if !warmup {
                rows.append(["profile": profile, "repetition": round, "submitted": count, "acceptedIncludingBarrier": samples.newest.count,
                    "intervalNs": intervalNs, "barrierOrdering": "PASS",
                    "phaseOffsetNs": phaseOffsetNs, "producerJitterNs": jitterNs,
                    "mergedMotionEvents": count + 1 - samples.newest.count, "failures": failures,
                    "duplicates": samples.duplicates, "wallSeconds": elapsed,
                    "latestEventToSyntheticAcceptanceMs": samples.newest,
                    "oldestPendingToSyntheticAcceptanceMs": samples.oldest,
                    "producerInterArrivalMs": arrivalIntervals,
                    "producerLatenessMs": producerLate])
            }
        }
        try run(profile: "keyboard-100Hz", count: 50, intervalNs: 0, round: 0, warmup: true)
        try run(profile: "motion-1000Hz", count: 50, intervalNs: 1_000_000, round: 0, warmup: true)
        for round in 1...repetitions {
            try run(profile: "keyboard-100Hz", count: 300, intervalNs: 10_000_000, round: round)
            try run(profile: "motion-1000Hz", count: 2000, intervalNs: 1_000_000, round: round)
            try run(profile: "motion-burst", count: 10000, intervalNs: 0, round: round)
        }
        let result: [String: Any] = ["schemaVersion": 1, "scope": "PRODUCTION_INPUT_SLICE_SYNTHETIC_ACCEPTANCE_NO_NETWORK",
            "backpressureExercised": false,
            "backendInstance": "INERT_TEST_STORAGE_WITH_PRODUCTION_INPUT_EXTENSION",
            "rows": rows, "warmupRunsExcluded": 2,
            "limitations": ["No OS event capture, AppKit, IME, encryption, ENet, host processing, decoding or display",
                "Includes benchmark timestamp/dictionary/lock overhead and default userInteractive sender; no real-time policy hook",
                "Motion is latest-only; samples represent accepted packets, not every submitted motion event",
                "Barrier packet included; no per-event delivery/latency inference for merged motion",
                "Local scheduling can bunch arrivals; inspect raw producer lateness; timing tracker/diagnostics are inert",
                "Motion1000Hz uses deterministic per-event jitter plus per-round phase offset; not a fixed-period latency guarantee"]]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .withoutOverwriting)
    }
}
