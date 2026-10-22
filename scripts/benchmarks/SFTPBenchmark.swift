// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import Darwin

private struct BenchmarkFailure: Error { let message: String }
private func require(_ value: Bool, _ message: String) throws {
    if !value { throw BenchmarkFailure(message: message) }
}

/// In-memory SFTP v3 peer. Delays each reply until send time + injected RTT.
/// No SSH process, socket, credentials, real host or existing remote file is used.
private final class DelayedPeer: SFTPTransport, @unchecked Sendable {
    private let condition = NSCondition()
    private let delay: UInt64
    private var stopped = false
    private var replies: [(data: Data, sent: UInt64, due: UInt64, held: Bool)] = []
    private let holdFirstRead: Bool
    private var heldReadReceiveWaiting = false
    private var files: [String: Data]
    private var directories: Set<String> = ["/", "/files"]
    private var handles: [Data: String] = [:]
    private var sequence = 0
    private var counts: [UInt8: Int] = [:]
    private var maximumOutstanding = 0
    private var replyNanoseconds: UInt64 = 0
    init(rttMs: Int, seed: Data, holdFirstRead: Bool = false) {
        delay = UInt64(rttMs) * 1_000_000
        self.holdFirstRead = holdFirstRead
        files = ["/files/seed.bin": seed]
    }
    func contents(_ path: String) -> Data? { condition.withLock { files[path] } }
    func snapshot() -> (requests: Int, dataRequests: Int, maxOutstanding: Int, replyNanoseconds: UInt64) {
        condition.withLock { (counts.values.reduce(0, +), (counts[5] ?? 0) + (counts[6] ?? 0), maximumOutstanding, replyNanoseconds) }
    }
    func send(_ payload: Data) throws {
        condition.lock(); defer { condition.unlock() }
        guard !stopped else { throw SFTPError.cancelled }
        var request = SFTPBinaryReader(payload)
        let type = try request.byte()
        counts[type, default: 0] += 1
        var reply = SFTPBinaryWriter()
        if type == 1 {
            try require(request.uint32() == 3, "unsupported init")
            reply.byte(2); reply.uint32(3)
        } else {
            let id = try request.uint32()
            func status(_ code: UInt32) -> SFTPBinaryWriter {
                var result = SFTPBinaryWriter()
                result.byte(101); result.uint32(id); result.uint32(code)
                result.string("synthetic"); result.string(""); return result
            }
            func attributes(_ path: String) -> SFTPBinaryWriter {
                guard files[path] != nil || directories.contains(path) else { return status(2) }
                var result = SFTPBinaryWriter(); result.byte(105); result.uint32(id)
                result.uint32(1 | 4 | 8); result.uint64(UInt64(files[path]?.count ?? 0))
                result.uint32(directories.contains(path) ? 0o040755 : 0o100644)
                result.uint32(100); result.uint32(100); return result
            }
            switch type {
            case 7: reply = attributes(try request.string())
            case 8: reply = handles[try request.bytes()].map(attributes) ?? status(9)
            case 3:
                let path = try request.string(), flags = try request.uint32()
                _ = try request.uint32()
                if flags & 0x20 != 0 && files[path] != nil { reply = status(4) }
                else {
                    if flags & 8 != 0 { files[path] = Data() }
                    if files[path] == nil { reply = status(2) }
                    else {
                        sequence += 1; let handle = Data("h-\(sequence)".utf8); handles[handle] = path
                        reply.byte(102); reply.uint32(id); reply.bytes(handle)
                    }
                }
            case 4: handles.removeValue(forKey: try request.bytes()); reply = status(0)
            case 5:
                let handle = try request.bytes(), offset = try request.uint64(), length = try request.uint32()
                if let path = handles[handle], let data = files[path], offset < data.count {
                    let end = min(data.count, Int(offset) + Int(length))
                    reply.byte(103); reply.uint32(id); reply.bytes(data.subdata(in: Int(offset)..<end))
                } else { reply = status(1) }
            case 6:
                let handle = try request.bytes(), offset = try request.uint64(), data = try request.bytes()
                if let path = handles[handle], let count = files[path]?.count, UInt64(count) == offset {
                    files[path, default: Data()].append(data); reply = status(0)
                } else { reply = status(9) }
            case 14:
                let path = try request.string(); _ = try request.uint32()
                reply = status(directories.insert(path).inserted ? 0 : 4)
            case 13: files.removeValue(forKey: try request.string()); reply = status(0)
            case 15: directories.remove(try request.string()); reply = status(0)
            case 18:
                let source = try request.string(), target = try request.string()
                if files[target] == nil, let data = files.removeValue(forKey: source) {
                    files[target] = data; reply = status(0)
                } else { reply = status(4) }
            default: throw BenchmarkFailure(message: "unimplemented request \(type)")
            }
        }
        try request.requireEnd()
        let sent = DispatchTime.now().uptimeNanoseconds
        replies.append((reply.data, sent, sent + delay, holdFirstRead && type == 5 && counts[5] == 1))
        maximumOutstanding = max(maximumOutstanding, replies.count)
        condition.broadcast()
    }
    func receive() throws -> Data {
        condition.lock(); defer { condition.unlock() }
        while true {
            guard !stopped else { throw SFTPError.cancelled }
            guard let first = replies.first else { throw BenchmarkFailure(message: "no synthetic reply") }
            if first.held {
                heldReadReceiveWaiting = true; condition.broadcast()
                condition.wait() // Only cancel() can release this reply; natural delay completion cannot pass the gate.
                continue
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= first.due {
                replyNanoseconds += now - first.sent
                return replies.removeFirst().data
            }
            _ = condition.wait(until: Date(timeIntervalSinceNow: Double(first.due - now) / 1e9))
        }
    }
    func cancel() { condition.withLock { stopped = true; condition.broadcast() } }
    func close() { cancel() }
    func waitForHeldRead(timeout: TimeInterval) -> Bool {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !heldReadReceiveWaiting && !stopped {
            if !condition.wait(until: deadline) { return false }
        }
        return heldReadReceiveWaiting && !stopped
    }
}

private final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: UInt64 = 0
    private var total: UInt64?
    private var invalid = false
    func record(_ progress: TransferProgress) {
        lock.withLock {
            if progress.bytesTransferred < previous || progress.bytesTransferred > progress.totalBytes ||
                (total != nil && total != progress.totalBytes) { invalid = true }
            total = progress.totalBytes
            previous = progress.bytesTransferred
        }
    }
    func complete(_ bytes: Int) -> Bool { lock.withLock { !invalid && previous == bytes && total == UInt64(bytes) } }
}

@main
private struct SFTPBenchmark {
    static func main() async throws {
        // The runner owns this newly created fixture directory, never a user-selected folder.
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let repetitions = Int(CommandLine.arguments[3])!
        var key = SFTPBinaryWriter(); key.string("ssh-ed25519"); key.bytes(Data(repeating: 7, count: 32))
        let config = try SFTPConnectionConfiguration(host: "synthetic.invalid", username: "benchmark",
            identityFile: root.appendingPathComponent("never-read-identity"),
            pinnedHostPublicKey: "ssh-ed25519 " + key.data.base64EncodedString())
        // Hash-counter bytes are deterministic, noncompressible test data, generated outside timing.
        var payload = Data(); payload.reserveCapacity(8 * 1024 * 1024)
        for index in 0..<(8 * 1024 * 1024 / 32) {
            payload.append(contentsOf: SHA256.hash(data: Data("deskbridge-benchmark-v1:\(index)".utf8)))
        }
        var rows: [[String: Any]] = []
        func run(bytes: Int, rtt: Int, repetition: Int, direction: String, warmup: Bool = false) async throws {
            let data = Data(payload.prefix(bytes))
            let expectedHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let peer = DelayedPeer(rttMs: rtt, seed: data)
            let client = SFTPClient(configuration: config, transportFactory: { peer })
            try await client.connect() // Connection/init excluded. No process launched by injected factory.
            let before = peer.snapshot(), progress = Progress()
            let source = root.appendingPathComponent("source.bin")
            let target = root.appendingPathComponent(UUID().uuidString + ".bin")
            if direction == "upload" { try data.write(to: source, options: .atomic) }
            let start = DispatchTime.now().uptimeNanoseconds
            let resultPath: String
            if direction == "upload" {
                resultPath = try await client.upload(localURL: source, progress: { progress.record($0) })
            } else {
                resultPath = "/files/seed.bin"
                try await client.download(remotePath: resultPath, destinationURL: target, progress: { progress.record($0) })
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            let after = peer.snapshot()
            let actual = direction == "upload" ? peer.contents(resultPath) : try Data(contentsOf: target)
            try require(actual == data && progress.complete(bytes), "transfer integrity/progress failed")
            let actualHash = SHA256.hash(data: actual!).map { String(format: "%02x", $0) }.joined()
            try require(actualHash == expectedHash, "digest mismatch")
            await client.disconnect()
            if direction == "download" { try FileManager.default.removeItem(at: target) }
            if !warmup {
                rows.append(["direction": direction, "bytes": bytes, "injectedReplyDelayMs": rtt,
                    "repetition": repetition, "wallSeconds": elapsed, "goodputMiBps": Double(bytes) / 1048576 / elapsed,
                    "requests": after.requests - before.requests, "dataRequests": after.dataRequests - before.dataRequests,
                    "meanObservedReplyDelayMs": Double(after.replyNanoseconds - before.replyNanoseconds) / 1e6 / Double(after.requests - before.requests),
                    "maxOutstanding": after.maxOutstanding, "sha256": actualHash, "integrity": "PASS", "progress": "PASS"])
            }
        }
        try await run(bytes: 262144, rtt: 0, repetition: 0, direction: "upload", warmup: true)
        try await run(bytes: 262144, rtt: 0, repetition: 0, direction: "download", warmup: true)
        // Rotate cells and alternate direction by round to avoid one fixed thermal/cache order.
        let cells = [(1048576, 0), (8388608, 5), (1048576, 30), (8388608, 0), (1048576, 5), (8388608, 30)]
        for repetition in 1...repetitions {
            for offset in cells.indices {
                let (bytes, rtt) = cells[(offset + repetition - 1) % cells.count]
                for direction in repetition.isMultiple(of: 2) ? ["download", "upload"] : ["upload", "download"] {
                    try await run(bytes: bytes, rtt: rtt, repetition: repetition, direction: direction)
                }
            }
        }
        // Safety checks execute production finalization and cancellation; not simulated outcomes.
        let peer = DelayedPeer(rttMs: 0, seed: Data(payload.prefix(1048576)))
        let client = SFTPClient(configuration: config, transportFactory: { peer })
        try await client.connect()
        let collision = root.appendingPathComponent("existing.bin"), sentinel = Data("SYNTHETIC-PRESERVE".utf8)
        try sentinel.write(to: collision)
        do {
            try await client.download(remotePath: "/files/seed.bin", destinationURL: collision)
            throw BenchmarkFailure(message: "overwrite unexpectedly accepted")
        } catch SFTPError.destinationExists { }
        try require(try Data(contentsOf: collision) == sentinel, "existing destination changed")
        await client.disconnect()
        let cancelPeer = DelayedPeer(rttMs: 0, seed: payload, holdFirstRead: true)
        let cancelClient = SFTPClient(configuration: config, transportFactory: { cancelPeer })
        defer { cancelClient.cancel() }
        try await cancelClient.connect()
        let cancelledTarget = root.appendingPathComponent("cancelled.bin")
        let task = Task.detached { try await cancelClient.download(remotePath: "/files/seed.bin", destinationURL: cancelledTarget) }
        try require(cancelPeer.waitForHeldRead(timeout: 10), "download never entered held READ receive")
        let beforeCancel = try FileManager.default.contentsOfDirectory(atPath: root.path)
        try require(beforeCancel.contains(where: { $0.hasSuffix(".part") }), "no partial file before cancellation")
        let watchdog = DispatchWorkItem { exit(3) }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2), execute: watchdog)
        defer { watchdog.cancel() }
        let cancelStart = DispatchTime.now().uptimeNanoseconds
        cancelClient.cancel()
        do { try await task.value; throw BenchmarkFailure(message: "cancel unexpectedly succeeded") }
        catch SFTPError.cancelled { }
        let cancelMs = Double(DispatchTime.now().uptimeNanoseconds - cancelStart) / 1e6
        try require(cancelMs < 2000, "cancel completion exceeded budget")
        watchdog.cancel()
        await cancelClient.disconnect()
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        try require(!names.contains("cancelled.bin") && !names.contains(where: { $0.hasSuffix(".part") }), "partial download retained")
        let report: [String: Any] = ["schemaVersion": 1, "scope": "SYNTHETIC_IN_MEMORY_NO_SSH_NO_NETWORK",
            "warmupRunsExcluded": 2, "rows": rows,
            "safety": ["localDownloadNoOverwrite": "PASS", "remoteUploadCollisionCases": "NOT_EXERCISED", "cancel": "PASS", "cancelToCompletionMs": cancelMs, "partialCleanup": "PASS",
                "cancelWitness": "HELD_READ_RECEIVE_WITH_EXISTING_PARTIAL", "cancelCompletionBudgetMs": 2000],
            "limitations": ["Artificial reply delay, not measured network RTT", "No SSH encryption, pipes, real server, disk write on peer, bandwidth contention or video",
                "Includes local file IO and production path validation/finalization; excludes connect, fixture generation and verification hashing",
                "No comparison with Cyberduck or any other client; small repeated warm-cache trials"]]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .withoutOverwriting)
    }
}
