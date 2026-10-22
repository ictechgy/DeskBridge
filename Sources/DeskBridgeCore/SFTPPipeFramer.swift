import Foundation
import Darwin

/// The production SFTP four-byte packet framer, also usable with anonymous pipe peers.
/// Owns the supplied SSH stdin/stdout handles. Send/receive are serialized; cancel is concurrent-safe.
public final class SFTPPipeFramer: SFTPTransport, @unchecked Sendable {
    public static let maximumPacketBytes = 1_048_576
    private let input: FileHandle
    private let output: FileHandle
    private let wakeRead: FileHandle
    private let wakeWrite: FileHandle
    private let timeoutNanoseconds: UInt64
    private let stateLock = NSLock()
    private let operationLock = NSLock()
    private var cancelled = false
    private var closed = false
    private var waitingForIO = false
    /// State-only diagnostic for deterministic liveness checks; exposes no packet contents.
    public var hasPendingIO: Bool { stateLock.withLock { waitingForIO } }

    public init(input: FileHandle, output: FileHandle, packetTimeout: TimeInterval = 30) throws {
        guard packetTimeout.isFinite, packetTimeout >= 0.001, packetTimeout <= 300 else {
            throw SFTPError.invalidConfiguration("invalid packet timeout")
        }
        self.input = input; self.output = output
        let wake = Pipe(); wakeRead = wake.fileHandleForReading; wakeWrite = wake.fileHandleForWriting
        timeoutNanoseconds = UInt64(packetTimeout * 1_000_000_000)
        do {
            for handle in [input, output, wakeRead, wakeWrite] {
                let flags = fcntl(handle.fileDescriptor, F_GETFL)
                let descriptorFlags = fcntl(handle.fileDescriptor, F_GETFD)
                guard flags >= 0, descriptorFlags >= 0,
                      fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0,
                      fcntl(handle.fileDescriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
                    throw SFTPError.localIO("cannot configure bounded SSH pipes")
                }
            }
            for handle in [input, wakeWrite] {
                guard fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                    throw SFTPError.localIO("cannot suppress closed-pipe signals")
                }
            }
        } catch {
            stateLock.withLock { cancelled = true; closed = true }
            for handle in [input, output, wakeRead, wakeWrite] { try? handle.close() }
            throw error
        }
    }

    public func send(_ payload: Data) throws {
        try perform {
            guard !payload.isEmpty, payload.count <= Self.maximumPacketBytes else {
                throw SFTPError.protocolViolation("outgoing packet exceeds limit")
            }
            var prefix = SFTPBinaryWriter(); prefix.uint32(UInt32(payload.count))
            let bytes = prefix.data + payload, deadline = self.deadline()
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < bytes.count {
                    try waitForPipe(input.fileDescriptor, event: Int16(POLLOUT), deadline: deadline)
                    let count = Darwin.write(input.fileDescriptor, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count > 0 { offset += count }
                    else if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                    else { try ensureOpen(); throw SFTPError.disconnected }
                }
            }
        }
    }

    public func receive() throws -> Data {
        try perform {
            let deadline = self.deadline()
            var header = SFTPBinaryReader(try readExactly(4, deadline: deadline))
            let size = Int(try header.uint32())
            guard size > 0, size <= Self.maximumPacketBytes else {
                throw SFTPError.protocolViolation("packet exceeds limit")
            }
            return try readExactly(size, deadline: deadline)
        }
    }

    private func perform<T>(_ body: () throws -> T) throws -> T {
        operationLock.lock(); defer { operationLock.unlock() }
        do { try ensureOpen(); return try body() }
        catch { cancel(); throw error }
    }
    private func deadline() -> UInt64 { DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds }
    private func readExactly(_ count: Int, deadline: UInt64) throws -> Data {
        var result = Data()
        while result.count < count {
            try waitForPipe(output.fileDescriptor, event: Int16(POLLIN), deadline: deadline)
            var chunk = Data(count: min(65_536, count - result.count))
            let readCount = chunk.withUnsafeMutableBytes { Darwin.read(output.fileDescriptor, $0.baseAddress!, $0.count) }
            if readCount > 0 { result.append(chunk.prefix(readCount)) }
            else if readCount < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            else { try ensureOpen(); throw SFTPError.disconnected }
        }
        return result
    }
    private func waitForPipe(_ descriptor: Int32, event: Int16, deadline: UInt64) throws {
        while true {
            try ensureOpen()
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw SFTPError.timedOut }
            let milliseconds = Int32(min(250, max(1, (deadline - now) / 1_000_000)))
            var items = [pollfd(fd: descriptor, events: event, revents: 0),
                         pollfd(fd: wakeRead.fileDescriptor, events: Int16(POLLIN), revents: 0)]
            stateLock.withLock { waitingForIO = true }
            let result = items.withUnsafeMutableBufferPointer { Darwin.poll($0.baseAddress, 2, milliseconds) }
            let pollError = errno
            stateLock.withLock { waitingForIO = false }
            if result > 0 {
                try ensureOpen()
                if items[0].revents == 0 { continue }
                guard items[0].revents & Int16(POLLNVAL) == 0 else { throw SFTPError.disconnected }
                return // read/write reports buffered data, EOF or EPIPE on HUP/ERR.
            }
            if result == 0 { continue } // A cancellation slice is not the packet deadline.
            if pollError != EINTR { throw SFTPError.disconnected }
        }
    }
    private func ensureOpen() throws {
        let stopped = stateLock.withLock { cancelled || closed }
        if stopped { throw SFTPError.cancelled }
    }
    public func cancel() {
        stateLock.lock()
        let shouldWake = !cancelled && !closed
        cancelled = true
        if shouldWake {
            var byte: UInt8 = 1
            var result: Int
            repeat { result = Darwin.write(wakeWrite.fileDescriptor, &byte, 1) }
            while result < 0 && errno == EINTR
        }
        stateLock.unlock()
    }
    public func close() {
        cancel()
        operationLock.lock(); defer { operationLock.unlock() }
        let shouldClose = stateLock.withLock {
            if closed { return false }; closed = true; return true
        }
        if shouldClose { for handle in [input, output, wakeRead, wakeWrite] { try? handle.close() } }
    }
    deinit { close() }
}
