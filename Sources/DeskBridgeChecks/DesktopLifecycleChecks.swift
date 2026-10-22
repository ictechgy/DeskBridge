// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(DeskBridgeCore)
import DeskBridgeCore
#endif

private final class SyntheticListenerCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]
    func increment(_ key: String) { lock.withLock { values[key, default: 0] += 1 } }
    func count(_ key: String) -> Int { lock.withLock { values[key, default: 0] } }
}

private final class SyntheticActivityToken: NSObject {}
private final class SyntheticActivityLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var held: Set<ObjectIdentifier> = []
    private var acquired: [Bool] = []
    private var released = 0
    private var invalidRelease = false

    func acquire(_ suppressed: Bool) -> NSObjectProtocol {
        let token = SyntheticActivityToken()
        lock.withLock { held.insert(ObjectIdentifier(token)); acquired.append(suppressed) }
        return token
    }
    func release(_ token: NSObjectProtocol) {
        lock.withLock {
            if held.remove(ObjectIdentifier(token)) == nil { invalidRelease = true }
            released += 1
        }
    }
    var snapshot: (acquired: [Bool], released: Int, held: Int, invalidRelease: Bool) {
        lock.withLock { (acquired, released, held.count, invalidRelease) }
    }
}

/// Fresh NotificationCenter and fake activity tokens only. Never touch audio, NSWorkspace or ProcessInfo activities.
@discardableResult
func runDesktopLifecycleChecks() throws -> Int {
    enum Failure: Error { case failed(String) }
    var count = 0
    func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw Failure.failed(label) }
        count += 1
    }
    let center = NotificationCenter()
    let name = Notification.Name("DeskBridge.synthetic.route-or-wake")
    let queue = DispatchQueue(label: "DeskBridge.synthetic.notification-delivery")
    let calls = SyntheticListenerCounts()
    let listener = DesktopNotificationListener()
    listener.install(center: center, name: name, queue: queue) { _ in calls.increment("old") }
    listener.install(center: center, name: name, queue: queue) { _ in calls.increment("new") }
    queue.suspend()
    center.post(name: name, object: nil)
    let deliveredInline = calls.count("new")
    queue.resume()
    queue.sync {}
    try check(deliveredInline == 0, "notification delivery must be asynchronous on the supplied queue")
    try check(calls.count("old") == 0 && calls.count("new") == 1, "reinstall must remove the prior observer")
    listener.remove(); listener.remove()
    center.post(name: name, object: nil); queue.sync {}
    try check(calls.count("new") == 1, "repeated removal must leave no observer")
    DispatchQueue.concurrentPerform(iterations: 200) { iteration in
        if iteration.isMultiple(of: 3) { listener.remove() }
        else { listener.install(center: center, name: name, queue: queue) { _ in calls.increment("raced") } }
    }
    listener.remove()
    center.post(name: name, object: nil); queue.sync {}
    try check(calls.count("raced") == 0, "concurrent install/remove must not orphan an observer")
    var temporary: DesktopNotificationListener? = DesktopNotificationListener()
    temporary?.install(center: center, name: name, queue: queue) { _ in calls.increment("disposed") }
    temporary = nil
    center.post(name: name, object: nil); queue.sync {}
    try check(calls.count("disposed") == 0, "listener destruction must remove its registration")

    let ledger = SyntheticActivityLedger()
    let activity = DesktopStreamActivity(acquire: { ledger.acquire($0) }, release: { ledger.release($0) })
    activity.begin(); activity.begin()
    activity.refresh(displaySuppressed: false)
    try check(ledger.snapshot.acquired == [false], "repeated begin/unchanged display must hold one activity")
    activity.refresh(displaySuppressed: true); activity.refresh(displaySuppressed: true)
    activity.refresh(displaySuppressed: false)
    try check(ledger.snapshot.acquired == [false, true, false] && ledger.snapshot.held == 1,
              "display suppression must replace the activity once per change")
    activity.end(); activity.end(); activity.refresh(displaySuppressed: true)
    try check(ledger.snapshot.held == 0 && ledger.snapshot.released == 3 && !ledger.snapshot.invalidRelease,
              "failure/repeated-stop edges must balance each token exactly once")
    do {
        let abandoned = DesktopStreamActivity(acquire: { ledger.acquire($0) }, release: { ledger.release($0) })
        abandoned.begin()
    }
    try check(ledger.snapshot.held == 0 && ledger.snapshot.released == 4, "activity destruction must release its token")
    DispatchQueue.concurrentPerform(iterations: 300) { iteration in
        switch iteration % 3 {
        case 0: activity.begin()
        case 1: activity.refresh(displaySuppressed: iteration.isMultiple(of: 2))
        default: activity.end()
        }
    }
    activity.end()
    try check(ledger.snapshot.held == 0 && ledger.snapshot.acquired.count == ledger.snapshot.released && !ledger.snapshot.invalidRelease,
              "concurrent activity lifecycle must leave no unbalanced token")
    return count
}
