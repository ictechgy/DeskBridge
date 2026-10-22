// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 DeskBridge contributors
import Foundation

/// Binds an asynchronous host check and subsequent desktop authority to one displayed endpoint.
/// Certificate/PIN authentication stays in GlimmerEngine; this prevents stale UI authority.
public struct TargetBinding: Sendable {
    public struct Attempt: Sendable, Equatable {
        public let address: String
        private let token: UUID
        fileprivate init(address: String) { self.address = address; token = UUID() }
    }
    public enum Failure: Error, LocalizedError {
        case changed
        public var errorDescription: String? { "대상 PC 주소가 바뀌었습니다. PC 확인과 페어링 상태를 다시 확인하세요." }
    }
    private var pending: Attempt?
    private var boundAddress: String?
    public init() {}
    public mutating func invalidate() { pending = nil; boundAddress = nil }
    public mutating func begin(input: String) throws -> Attempt {
        invalidate()
        let attempt = Attempt(address: try EndpointPolicy.validatedAddress(input))
        pending = attempt
        return attempt
    }
    public mutating func accept(_ attempt: Attempt, currentInput: String) throws {
        // An obsolete completion must not destroy a newer check either.
        guard pending == attempt else { throw Failure.changed }
        guard (try? EndpointPolicy.validatedAddress(currentInput)) == attempt.address else {
            invalidate(); throw Failure.changed
        }
        boundAddress = attempt.address; pending = nil
    }
    public mutating func failed(_ attempt: Attempt) {
        // Pending-only cleanup, safe in defer after accept; use invalidate to revoke accepted authority.
        if pending == attempt { invalidate() }
    }
    public func require(input: String, expectedAddress: String) throws {
        let current = try EndpointPolicy.validatedAddress(input)
        guard let boundAddress, current == boundAddress, current == expectedAddress else { throw Failure.changed }
    }
}

