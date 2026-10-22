// SPDX-License-Identifier: GPL-3.0-only
import GlimmerEngine

/// Presentation belongs to the desktop shell, independently of transport recovery.
struct DesktopRecoveryPresentation {
    enum Phase { case connecting, live, waiting, reconnecting, ended }
    private(set) var phase: Phase = .connecting
    private var receivedFreshFrame = false

    var message: String? {
        switch phase {
        case .connecting: "PC 화면에 연결하는 중…"
        case .waiting: "PC 영상을 기다리는 중…"
        case .reconnecting: "화면을 다시 연결하는 중… 마지막 화면이 표시됩니다."
        case .live, .ended: nil
        }
    }

    mutating func receive(_ event: StreamEvent) {
        guard phase != .ended else { return }
        switch event {
        case .firstFrame: receivedFreshFrame = true; phase = .live
        case .reconnecting: receivedFreshFrame = false; phase = .reconnecting
        // A recovered transport is not proof that a fresh picture has arrived.
        case .reconnected: if !receivedFreshFrame { phase = .waiting }
        case .waitingForVideo(true):
            if phase != .reconnecting { phase = .waiting }
        case .waitingForVideo(false):
            if phase == .waiting { phase = .live }
        // Stage failures can belong to a retryable reconnect attempt.
        case .connectionTerminated, .stopped: phase = .ended
        default: break
        }
    }
}
