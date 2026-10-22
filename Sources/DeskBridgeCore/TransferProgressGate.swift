// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Bounds cross-thread UI delivery to 10 Hz while always admitting the first and final update.
public final class TransferProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> UInt64
    private var last: UInt64?
    private var finished = false
    public init(now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) { self.now = now }
    public func accept(bytes: UInt64, total: UInt64) -> Bool {
        lock.withLock {
            guard !finished else { return false }
            let timestamp = now()
            let complete = bytes >= total
            guard complete || last == nil || timestamp >= last! && timestamp - last! >= 100_000_000 else { return false }
            last = timestamp; finished = complete
            return true
        }
    }
}
