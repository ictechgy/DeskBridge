// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Balances one session activity, including failure, replacement and repeated stop paths.
public final class DesktopStreamActivity: @unchecked Sendable {
    private let lock = NSLock()
    private let acquire: @Sendable (Bool) -> NSObjectProtocol
    private let release: @Sendable (NSObjectProtocol) -> Void
    // Token and display state belong to the same lock. No OS activity occurs in tests.
    private var token: NSObjectProtocol?
    private var displaySuppressed = false

    public init(acquire: @escaping @Sendable (Bool) -> NSObjectProtocol,
                release: @escaping @Sendable (NSObjectProtocol) -> Void) {
        self.acquire = acquire
        self.release = release
    }

    public func begin() {
        lock.withLock {
            guard token == nil else { return }
            displaySuppressed = false
            token = acquire(false)
        }
    }

    public func refresh(displaySuppressed: Bool) {
        lock.withLock {
            guard let previous = token, self.displaySuppressed != displaySuppressed else { return }
            // Take the replacement first so refreshing does not open an idle-sleep gap.
            token = acquire(displaySuppressed)
            self.displaySuppressed = displaySuppressed
            release(previous)
        }
    }

    public func end() {
        lock.withLock {
            guard let previous = token else { return }
            token = nil
            release(previous)
        }
    }

    deinit { end() }
}
