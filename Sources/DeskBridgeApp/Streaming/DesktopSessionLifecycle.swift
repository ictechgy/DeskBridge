// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import DeskBridgeCore
import GlimmerEngine

/// Native operations follow the engine's existing start/stop/recovery ownership edges.
final class DesktopSessionLifecycle: Sendable {
    private let activity: DesktopStreamActivity
    private let wake = DesktopNotificationListener()
    private let wakeCenter: NotificationCenter
    private let wakeName: Notification.Name

    @MainActor init() {
        wakeCenter = NSWorkspace.shared.notificationCenter
        wakeName = NSWorkspace.didWakeNotification
        activity = DesktopStreamActivity(acquire: { displaySuppressed in
            var options: ProcessInfo.ActivityOptions = [.userInitiated]
            if !displaySuppressed { options.insert(.idleDisplaySleepDisabled) }
            return ProcessInfo.processInfo.beginActivity(options: options, reason: "Knot remote desktop session")
        }, release: { ProcessInfo.processInfo.endActivity($0) })
    }

    func hooks() -> StreamSession.Lifecycle {
        StreamSession.Lifecycle(beginActivity: { [self] in activity.begin() },
            endActivity: { [self] in activity.end() },
            refreshActivity: { [self] in activity.refresh(displaySuppressed: $0) },
            armWake: { [self] changed in
                wake.install(center: wakeCenter, name: wakeName, queue: .main) { _ in changed() }
            }, stopWake: { [self] in wake.remove() })
    }
}
