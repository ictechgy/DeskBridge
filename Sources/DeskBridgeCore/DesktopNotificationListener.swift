// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// One replaceable observer. Hooks and teardown may arrive on different lifecycle threads.
public final class DesktopNotificationListener: @unchecked Sendable {
    private let lock = NSLock()
    // The center/token pair is accessed only under lock; notifications never take that lock.
    private var registration: (center: NotificationCenter, token: NSObjectProtocol)?

    public init() {}

    public func install(center: NotificationCenter, name: Notification.Name, queue: DispatchQueue,
                        changed: @escaping @Sendable (UInt64) -> Void) {
        lock.withLock {
            removeLocked()
            let token = center.addObserver(forName: name, object: nil, queue: nil) { _ in
                let now = DispatchTime.now().uptimeNanoseconds
                queue.async { changed(now) }
            }
            registration = (center, token)
        }
    }

    public func remove() { lock.withLock { removeLocked() } }

    private func removeLocked() {
        if let registration { registration.center.removeObserver(registration.token) }
        registration = nil
    }

    deinit { remove() }
}
