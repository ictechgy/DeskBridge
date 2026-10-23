// SPDX-License-Identifier: GPL-3.0-only
import DeskBridgeCore
import Foundation

private final class VisibilityActivityToken: NSObject {}
private final class VisibilityActivityLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var held: Set<ObjectIdentifier> = []
    private var acquired: [Bool] = []
    private var releases = 0
    private var invalidRelease = false
    func acquire(_ suppressed: Bool) -> NSObjectProtocol {
        let token = VisibilityActivityToken()
        lock.withLock { held.insert(ObjectIdentifier(token)); acquired.append(suppressed) }
        return token
    }
    func release(_ token: NSObjectProtocol) {
        lock.withLock {
            if held.remove(ObjectIdentifier(token)) == nil { invalidRelease = true }
            releases += 1
        }
    }
    var snapshot: (states: [Bool], held: Int, releases: Int, invalidRelease: Bool) {
        lock.withLock { (acquired, held.count, releases, invalidRelease) }
    }
}

/// Actual visibility policy plus fake power tokens only; no AppKit window, Space or OS activity.
func runDesktopVisibilityChecks() throws -> Int {
    var count = 0
    func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ModelCheckFailure(message: message) }; count += 1
    }
    for visible in [false, true] {
        for minimized in [false, true] {
            for occlusionVisible in [false, true] {
                var state = DesktopPresentationVisibility()
                let edge = state.update(isVisible: visible, isMiniaturized: minimized, isOcclusionVisible: occlusionVisible)
                let shouldPresent = visible && !minimized && occlusionVisible
                try expect(edge == !shouldPresent, "visibility matrix admitted hidden presentation")
                try expect(state.update(isVisible: visible, isMiniaturized: minimized, isOcclusionVisible: occlusionVisible) == nil,
                           "duplicate visibility notification repeated a presentation transition")
            }
        }
    }
    let ledger = VisibilityActivityLedger()
    let activity = DesktopStreamActivity(acquire: { ledger.acquire($0) }, release: { ledger.release($0) })
    var state = DesktopPresentationVisibility()
    func update(_ visible: Bool, _ minimized: Bool, _ occlusion: Bool) {
        if let suppressed = state.update(isVisible: visible, isMiniaturized: minimized, isOcclusionVisible: occlusion) {
            activity.refresh(displaySuppressed: suppressed)
        }
    }
    activity.begin()
    update(true, false, true)
    update(true, false, false) // Covered window or another Space, without minimization.
    update(true, false, false)
    update(true, true, false)
    update(true, false, false) // Deminiaturized but still occluded: remain suppressed.
    try expect(ledger.snapshot.states == [false, true] && ledger.snapshot.held == 1,
               "hidden or deminiaturized-occluded state kept a display-sleep assertion")
    update(true, false, true)
    update(true, false, true)
    try expect(ledger.snapshot.states == [false, true, false] && ledger.snapshot.held == 1,
               "visible restoration failed to replace exactly one activity")
    activity.end(); activity.end()
    update(false, false, false)
    update(true, false, true)
    try expect(ledger.snapshot.held == 0 && ledger.snapshot.releases == 3 && !ledger.snapshot.invalidRelease,
               "late visibility refresh or duplicate stop leaked/reacquired an activity")
    return count
}
