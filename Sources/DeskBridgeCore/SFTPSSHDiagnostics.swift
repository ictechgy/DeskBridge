import Foundation
import Darwin

/// Fixed connection guidance only. SSH stderr, hostnames, usernames and paths
/// must never become an associated value, log entry or user-facing message.
public enum SFTPSSHFailure: Sendable, Equatable {
    case hostKeyVerificationFailed
    case authenticationRejected
    case connectionRefused
    case networkUnavailable
}

/// Classifies only a bounded prefix of OpenSSH's English diagnostics. The
/// rolling window is at most one known signature long; no complete line or raw
/// stderr is retained. Additional input is deliberately ignored by the parser
/// while the pipe reader continues draining it.
public struct SFTPSSHFailureClassifier: Sendable {
    public static let maximumInspectedBytes = 4096
    private static let signatures: [(bytes: [UInt8], failure: SFTPSSHFailure)] = [
        (Array("remote host identification has changed!".utf8), .hostKeyVerificationFailed),
        (Array("host key verification failed.".utf8), .hostKeyVerificationFailed),
        (Array("permission denied (".utf8), .authenticationRejected),
        (Array("connection refused".utf8), .connectionRefused),
        (Array("no route to host".utf8), .networkUnavailable),
        (Array("network is unreachable".utf8), .networkUnavailable),
        (Array("operation timed out".utf8), .networkUnavailable),
        (Array("connection timed out".utf8), .networkUnavailable),
    ]
    private static let windowSize = signatures.map(\.bytes.count).max() ?? 1
    private var window: [UInt8] = []
    public private(set) var inspectedByteCount = 0
    public private(set) var failure: SFTPSSHFailure?
    /// Count-only diagnostic for synthetic resource-bound checks.
    public var retainedByteCount: Int { window.count }

    public init() {}

    public mutating func consume(_ bytes: Data) {
        let remaining = Self.maximumInspectedBytes - inspectedByteCount
        guard remaining > 0 else { return }
        for byte in bytes.prefix(remaining) {
            inspectedByteCount += 1
            // OpenSSH is launched with LC_ALL=C. Only ASCII case folding is
            // needed, and arbitrary invalid UTF-8 never reaches a String.
            window.append(byte >= 65 && byte <= 90 ? byte + 32 : byte)
            if window.count > Self.windowSize { window.removeFirst() }
            for signature in Self.signatures where window.suffix(signature.bytes.count).elementsEqual(signature.bytes) {
                if failure.map({ Self.priority(signature.failure) < Self.priority($0) }) ?? true {
                    failure = signature.failure
                }
            }
        }
        if inspectedByteCount == Self.maximumInspectedBytes { window.removeAll(keepingCapacity: false) }
    }

    /// Only EOF/closed-pipe startup errors may use stderr guidance. A cancelled,
    /// timed-out or invalid protocol operation retains its original meaning.
    public func replacingStartupDisconnect(_ error: SFTPError) -> SFTPError {
        guard error == .disconnected, let failure else { return error }
        return .sshConnectionFailure(failure)
    }

    private static func priority(_ failure: SFTPSSHFailure) -> Int {
        switch failure {
        case .hostKeyVerificationFailed: return 0
        case .authenticationRejected: return 1
        case .connectionRefused: return 2
        case .networkUnavailable: return 3
        }
    }
}

/// Owns and continuously drains an anonymous SSH stderr pipe on a separate
/// queue. Both parsing and reads are bounded; reaching the parsing budget never
/// stops reading and therefore cannot fill the child's stderr pipe.
public final class SFTPSSHStderrDrain: @unchecked Sendable {
    private let worker: Worker

    public init(input: FileHandle) throws {
        worker = try Worker(input: input)
        let worker = worker
        worker.completion.enter()
        DispatchQueue(label: "DeskBridge.SSH.stderr", qos: .utility).async {
            defer { worker.completion.leave() }
            worker.drain()
        }
    }

    public var failure: SFTPSSHFailure? { worker.lock.withLock { worker.classifier.failure } }
    public var inspectedByteCount: Int { worker.lock.withLock { worker.classifier.inspectedByteCount } }

    /// A small, bounded startup-EOF grace period lets stderr catch up with the
    /// independently drained SFTP stdout. A child retaining stderr cannot hold
    /// up the existing packet deadline or wait indefinitely for process exit.
    @discardableResult
    public func waitForEOF(timeout: TimeInterval) -> Bool {
        guard timeout.isFinite, timeout >= 0, timeout <= 1 else { return false }
        return worker.completion.wait(timeout: .now() + timeout) == .success
    }

    public func close() {
        worker.cancel()
        worker.completion.wait()
    }
    deinit { close() }

    private final class Worker: @unchecked Sendable {
        let input: FileHandle
        let wakeRead: FileHandle
        let wakeWrite: FileHandle
        let lock = NSLock()
        let completion = DispatchGroup()
        var classifier = SFTPSSHFailureClassifier()
        private var cancelled = false
        private var closed = false

        init(input: FileHandle) throws {
            self.input = input
            let wake = Pipe(); wakeRead = wake.fileHandleForReading; wakeWrite = wake.fileHandleForWriting
            do {
                for handle in [input, wakeRead, wakeWrite] {
                    let flags = fcntl(handle.fileDescriptor, F_GETFL)
                    let descriptorFlags = fcntl(handle.fileDescriptor, F_GETFD)
                    guard flags >= 0, descriptorFlags >= 0,
                          fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0,
                          fcntl(handle.fileDescriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
                        throw SFTPError.localIO("cannot configure bounded SSH diagnostics")
                    }
                }
                guard fcntl(wakeWrite.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                    throw SFTPError.localIO("cannot configure SSH diagnostic cancellation")
                }
            } catch {
                for handle in [input, wakeRead, wakeWrite] { try? handle.close() }
                throw error
            }
        }

        func cancel() {
            lock.withLock {
                guard !cancelled, !closed else { return }
                cancelled = true
                var byte: UInt8 = 1
                var wrote: Int
                repeat { wrote = Darwin.write(wakeWrite.fileDescriptor, &byte, 1) } while wrote < 0 && errno == EINTR
            }
        }

        func drain() {
            defer {
                lock.withLock {
                    closed = true
                    for handle in [input, wakeRead, wakeWrite] { try? handle.close() }
                }
            }
            var bytes = [UInt8](repeating: 0, count: 1024)
            while !lock.withLock({ cancelled }) {
                var items = [pollfd(fd: input.fileDescriptor, events: Int16(POLLIN), revents: 0),
                             pollfd(fd: wakeRead.fileDescriptor, events: Int16(POLLIN), revents: 0)]
                // A lost wake write must not leave close() joining an infinite poll.
                let ready = items.withUnsafeMutableBufferPointer { Darwin.poll($0.baseAddress, 2, 250) }
                if ready < 0 {
                    if errno == EINTR { continue }
                    return
                }
                guard !lock.withLock({ cancelled }) else { return }
                if items[0].revents == 0 { continue }
                if items[0].revents & Int16(POLLNVAL) != 0 { return }
                let count = bytes.withUnsafeMutableBytes { Darwin.read(input.fileDescriptor, $0.baseAddress!, $0.count) }
                if count > 0 {
                    lock.withLock {
                        if classifier.inspectedByteCount < SFTPSSHFailureClassifier.maximumInspectedBytes {
                            classifier.consume(Data(bytes.prefix(count)))
                        }
                    }
                } else if count == 0 { return }
                else if errno != EAGAIN && errno != EINTR { return }
            }
        }
    }
}
