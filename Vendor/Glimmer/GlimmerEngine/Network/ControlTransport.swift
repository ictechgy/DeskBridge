// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// In-memory mutual TLS and exact DER pinning keep CA trust and the keychain out of control requests.

import Foundation
import Network
import Security
import os

package enum ControlTransport {

    final class RequestLifetime: Sendable {
        let deadline: Date
        private struct State {
            var cancelled = false
            var connection: NWConnection?
        }
        private let state = OSAllocatedUnfairLock(initialState: State())

        init(timeout: TimeInterval) { deadline = Date().addingTimeInterval(timeout) }

        /// Cancel the attached connection so a pending handshake or read ends now.
        func cancel() {
            let connection = state.withLock { state -> NWConnection? in
                state.cancelled = true
                return state.connection
            }
            connection?.cancel()
        }

        /// False when the request was cancelled before its connection existed; it never starts.
        func attach(_ connection: NWConnection) -> Bool {
            state.withLock { state in
                guard !state.cancelled else { return false }
                state.connection = connection
                return true
            }
        }

        func detach() -> NWConnection? {
            state.withLock { state in
                let connection = state.connection
                state.connection = nil
                return connection
            }
        }

        var isCancelled: Bool { state.withLock { $0.cancelled } }
    }

    /// One control response.
    package struct Response: Sendable {
        package let status: Int
        package let body: Data

        package init(status: Int, body: Data) {
            self.status = status
            self.body = body
        }
    }

    /// The PEM material one control call carries: the client credential we
    /// present on the mutual-TLS handshake plus the host leaf we pin against.
    /// All-nil is the plain-HTTP unpaired probe (no cert, no pin).
    package struct TLSCredential: Sendable {
        package let clientCertPEM: String?
        package let clientKeyPEM: String?
        /// The host leaf must match it byte-for-byte (DER) or the handshake is
        /// refused (MITM gate). NetworkClient never opens TLS without one, and
        /// only a finished PIN handshake supplies it.
        package let pinnedCertPEM: String?

        package init(clientCertPEM: String?, clientKeyPEM: String?, pinnedCertPEM: String?) {
            self.clientCertPEM = clientCertPEM
            self.clientKeyPEM = clientKeyPEM
            self.pinnedCertPEM = pinnedCertPEM
        }
    }

    private static let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Network.TLS")

    /// Requests wrapped in `StreamAttempt.run` report its deadline as `hostTimedOut`; this
    /// backstop only ends an unwrapped `/launch`, so it lands just after the same deadline.
    package static let backstopGrace: TimeInterval = 0.25

    /// One control GET in `get`'s shape: NetworkClient's seam, so tests can answer as a fake Sunshine.
    package typealias Get = @Sendable (_ host: String, _ port: Int, _ target: String, _ userAgent: String,
                               _ tls: Bool, _ credential: TLSCredential,
                               _ timeout: TimeInterval) async throws -> Response

    /// Perform one HTTP/1.1 GET. `tls == false` is plain HTTP (the unpaired probe
    /// path - no cert, no pin); `tls == true` presents the client cert and pins.
    package static func get(host: String, port: Int, target: String,
                            userAgent: String,
                            tls: Bool,
                            credential: TLSCredential,
                            timeout: TimeInterval) async throws -> Response {
        let lifetime = RequestLifetime(timeout: timeout)
        var request = "GET \(target) HTTP/1.1\r\n"
        request += "Host: \(host):\(port)\r\n"
        request += "User-Agent: \(userAgent)\r\n"
        request += "Accept: */*\r\n"
        request += "Connection: close\r\n\r\n"
        let exchange = Exchange(host: host, port: port, request: Data(request.utf8), lifetime: lifetime)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard let rawPort = UInt16(exactly: port), rawPort > 0,
                  let endpointPort = NWEndpoint.Port(rawValue: rawPort) else {
                throw StreamError.hostUnreachable("invalid control port \(port)")
            }
            let parameters = try exchange.parameters(tls: tls, credential: credential)
            return try await exchange.run(NWConnection(host: NWEndpoint.Host(host), port: endpointPort,
                                                       using: parameters))
        } onCancel: {
            lifetime.cancel()
        }
    }

    // MARK: - One request

    /// One request's connection and reply. Invariant: `reply` and `continuation` are only
    /// touched on `queue`, which runs every connection callback, the backstop, and the start.
    private final class Exchange: @unchecked Sendable {
        let queue = DispatchQueue(label: "io.ugfugl.Glimmer.control", qos: .userInitiated)
        let host: String
        let port: Int
        let request: Data
        let lifetime: RequestLifetime
        /// Why the verify block refused the PC; written there, read when the handshake fails.
        private let pinRejection = OSAllocatedUnfairLock<String?>(initialState: nil)
        private var reply = ResponseBuffer()
        private var continuation: CheckedContinuation<Response, Error>?
        private var backstop: DispatchWorkItem?

        init(host: String, port: Int, request: Data, lifetime: RequestLifetime) {
            self.host = host
            self.port = port
            self.request = request
            self.lifetime = lifetime
        }

        func parameters(tls: Bool, credential: TLSCredential) throws -> NWParameters {
            guard tls else { return .tcp }
            guard let pinnedCertPEM = credential.pinnedCertPEM else { throw StreamError.crypto("TLS control requests require a pinned host certificate") }
            let options = NWProtocolTLS.Options()
            let security = options.securityProtocolOptions
            // The pin is the guarantee; the floor just keeps the handshake off legacy versions.
            sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
            // A resumed session skips the verify block, so every connection does a full handshake.
            sec_protocol_options_set_tls_resumption_enabled(security, false)
            if let certPEM = credential.clientCertPEM, let keyPEM = credential.clientKeyPEM {
                sec_protocol_options_set_local_identity(security, try clientIdentity(certPEM: certPEM, keyPEM: keyPEM))
            }
            _ = try PEM.certificateKey(pinnedCertPEM, context: "paired PC certificate")
            guard let pinned = PEM.der(pinnedCertPEM) else { throw StreamError.crypto("could not parse pinned host cert") }
            let rejection = pinRejection
            // Self-signed, so pinned instead of CA-validated: the leaf must byte-equal the pin.
            sec_protocol_options_set_verify_block(security, { _, trust, complete in
                let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue())
                guard let leaf = (chain as? [SecCertificate])?.first else {
                    rejection.withLock { $0 = "host presented no certificate" }
                    return complete(false)
                }
                let matches: Bool
                do {
                    matches = try acceptsHostCertificate(leaf, pinnedDER: pinned)
                } catch {
                    rejection.withLock { $0 = "PC certificate requires an RSA key of at least 2048 bits" }
                    return complete(false)
                }
                if !matches { rejection.withLock { $0 = "pinned host cert mismatch" } }
                complete(matches)
            }, queue)
            return NWParameters(tls: options)
        }

        func run(_ connection: NWConnection) async throws -> Response {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self, connection] in
                    self.continuation = continuation
                    guard lifetime.attach(connection) else {
                        return finish(.failure(CancellationError()), closing: nil)
                    }
                    connection.stateUpdateHandler = { [weak self, weak connection] state in
                        guard let self, let connection else { return }
                        handle(state, on: connection)
                    }
                    connection.start(queue: queue)
                    let delay = max(0, lifetime.deadline.timeIntervalSinceNow) + backstopGrace
                    let work = DispatchWorkItem { [weak self, weak connection] in
                        self?.finish(.failure(StreamError.hostUnreachable("Control request timed out.")), closing: connection)
                    }
                    backstop = work
                    queue.asyncAfter(deadline: .now() + delay, execute: work)
                }
            }
        }

        private func handle(_ state: NWConnection.State, on connection: NWConnection) {
            switch state {
            case .ready:
                connection.send(content: request, completion: .contentProcessed { [self] error in
                    if let error { return finish(.failure(failure(error)), closing: connection) }
                    receive(on: connection)
                })
            case .waiting(let error), .failed(let error):
                // Network.framework retries a waiting connection; a control request fails now instead.
                finish(.failure(failure(error)), closing: connection)
            case .cancelled:
                finish(.failure(StreamError.hostUnreachable("control connection closed")), closing: nil)
            default:
                break
            }
        }

        private func receive(on connection: NWConnection) {
            let maxLength = 16 * 1024
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { [self] data, _, done, error in
                do {
                    if let raw = try reply.receive(data, done: done, error: error.map { failure($0) }) {
                        return finish(.success(try parse(raw)), closing: connection)
                    }
                    receive(on: connection)
                } catch {
                    finish(.failure(error), closing: connection)
                }
            }
        }

        /// The error a connection failure reports, in the wording `classifyPairedPathFailure` reads.
        private func failure(_ error: NWError) -> Error {
            if let rejection = pinRejection.withLock({ $0 }) {
                log.error("\(rejection, privacy: .public) - refusing (possible MITM or host re-imaged)")
                return StreamError.hostUnreachable(rejection)
            }
            if case .tls = error {
                return StreamError.hostUnreachable("TLS handshake to \(host):\(port) failed (\(error))")
            }
            return StreamError.hostUnreachable("connect to \(host):\(port) failed or timed out")
        }

        /// Resumes the caller once; a cancelled request always reports cancellation.
        private func finish(_ result: Result<Response, Error>, closing connection: NWConnection?) {
            backstop?.cancel()
            backstop = nil
            let owned = lifetime.detach()
            owned?.stateUpdateHandler = nil
            connection?.stateUpdateHandler = nil
            owned?.cancel()
            connection?.cancel()
            guard let continuation else { return }
            self.continuation = nil
            if case .failure = result, lifetime.isCancelled {
                return continuation.resume(throwing: CancellationError())
            }
            continuation.resume(with: result)
        }
    }

    // MARK: - Client identity (PEM to an in-memory identity, no keychain)

    package static func acceptsHostCertificate(_ certificate: SecCertificate, pinnedDER: Data?) throws -> Bool {
        guard let pinnedDER, SecCertificateCopyData(certificate) as Data == pinnedDER else { return false }
        _ = try PEM.certificateKey(certificate, context: "PC certificate")
        return true
    }

    /// The client identity from its PEM files, held in memory only.
    package static func clientIdentity(certPEM: String, keyPEM: String) throws -> sec_identity_t {
        let identity = try PEM.identity(certPEM: certPEM, keyPEM: keyPEM)
        guard let secIdentity = sec_identity_create(identity) else {
            throw StreamError.crypto("could not create TLS client identity")
        }
        return secIdentity
    }

    // MARK: - Reply

    /// Ceiling for one control response. Real replies are tens of KiB of XML at
    /// most, so anything past this is a broken or hostile responder.
    package static let maxResponseBytes = 4 * 1024 * 1024
    /// Bound incomplete headers separately from the (potentially larger) XML body.
    package static let maxHeaderBytes = 64 * 1024

    /// One reply as it arrives: whole at `Content-Length` when the PC sends one, else at close.
    struct ResponseBuffer {
        private(set) var bytes = Data()
        private var headerEnd: Int?
        private var contentLength: Int?
        private var headerSearchOffset = 0

        init() {}

        /// A transport error is never a clean close, even without Content-Length.
        mutating func receive(_ chunk: Data?, done: Bool, error: Error?) throws -> Data? {
            if let error { throw error }
            if let chunk, try append(chunk) { return bytes }
            return done ? try finish() : nil
        }

        /// Adds a chunk; true once the body has reached `Content-Length`.
        mutating func append(_ chunk: Data) throws -> Bool {
            guard chunk.count <= maxResponseBytes - bytes.count else {
                throw StreamError.hostUnreachable("control response too large")
            }
            bytes.append(chunk)
            if headerEnd == nil {
                // Revisit only the three-byte overlap: a peer delivering one byte per
                // callback must not force a rescan of the entire accumulated header.
                if let separator = bytes.range(of: Data("\r\n\r\n".utf8),
                                                in: headerSearchOffset..<bytes.endIndex) {
                    guard separator.upperBound <= maxHeaderBytes else {
                        throw StreamError.hostUnreachable("control response headers too large")
                    }
                    headerEnd = separator.upperBound
                    contentLength = try contentLengthHeader(in: bytes[bytes.startIndex..<separator.lowerBound])
                } else {
                    guard bytes.count < maxHeaderBytes else {
                        throw StreamError.hostUnreachable("control response headers too large")
                    }
                    headerSearchOffset = max(0, bytes.count - 3)
                }
            }
            if bytes.count > maxResponseBytes || (contentLength ?? 0) > maxResponseBytes {
                throw StreamError.hostUnreachable("control response too large")
            }
            guard let headerEnd, let contentLength else { return false }
            return bytes.count - headerEnd >= contentLength
        }

        /// The reply once the PC closes; a body short of its `Content-Length` is a truncated read.
        func finish() throws -> Data {
            if let headerEnd, let contentLength, bytes.count - headerEnd < contentLength {
                throw StreamError.truncatedRead(
                    "connection closed before Content-Length satisfied (have \(bytes.count) bytes)")
            }
            return bytes
        }
    }

    /// `Content-Length` from a completed header block, so a reply ends at its body instead of
    /// the PC's close. Invalid or conflicting lengths are rejected rather than treated as absent.
    /// Fails closed on non-UTF-8 headers: this is host-supplied input, and a lossy decode would half-parse it.
    package static func contentLengthHeader(in headerBytes: Data) throws -> Int? {
        guard let head = String(bytes: headerBytes, encoding: .utf8) else {
            throw StreamError.hostUnreachable("malformed HTTP response (headers are not UTF-8)")
        }
        var length: Int?
        for line in head.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { continue }
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { throw StreamError.hostUnreachable("malformed Content-Length header") }
            let text = parts[1].trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(text),
                  length == nil || length == value else { throw StreamError.hostUnreachable("invalid or conflicting Content-Length") }
            length = value
        }
        return length
    }

    // MARK: - HTTP/1.1 response parse

    package static func parse(_ raw: Data) throws -> Response {
        guard let sep = raw.range(of: Data("\r\n\r\n".utf8)) else {
            throw StreamError.hostUnreachable("malformed HTTP response (no header terminator)")
        }
        // Header bytes that are not UTF-8 are malformed protocol text, handled by the
        // malformed-response path rather than lossily decoded into a status line.
        guard let head = String(bytes: raw[raw.startIndex..<sep.lowerBound], encoding: .utf8) else {
            throw StreamError.hostUnreachable("malformed HTTP response (headers are not UTF-8)")
        }
        guard let statusLine = head.split(separator: "\r\n").first else {
            throw StreamError.hostUnreachable("empty HTTP response")
        }
        // "HTTP/1.1 200 OK" -> 200
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw StreamError.hostUnreachable("unparseable HTTP status line: \(statusLine)")
        }
        let length = try contentLengthHeader(in: Data(raw[raw.startIndex..<sep.lowerBound]))
        let available = raw.count - sep.upperBound
        if let length, available < length { throw StreamError.truncatedRead("connection closed before Content-Length satisfied") }
        let body = Data(raw[sep.upperBound..<(sep.upperBound + (length ?? available))])
        return Response(status: status, body: body)
    }
}
