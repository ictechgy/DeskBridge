// SPDX-License-Identifier: GPL-3.0-only
import GlimmerEngine

/// Presentation belongs to the desktop shell, independently of transport recovery.
struct DesktopRecoveryPresentation {
    enum Phase { case connecting, live, waiting, reconnecting, ended }
    private(set) var phase: Phase = .connecting
    private var receivedFreshFrame = false
    private var hasReceivedVideo = false
    private var audioUnavailable = false
    private var terminalStatus: String?

    private var audioWarning: String? {
        audioUnavailable ? "오디오를 사용할 수 없습니다. Mac과 PC의 오디오 출력 장치를 확인하세요." : nil
    }

    var status: String {
        switch phase {
        case .connecting: "화면에 연결하는 중…"
        case .waiting: "PC 영상을 기다리는 중…"
        case .reconnecting: "화면을 다시 연결하는 중…"
        case .live: audioUnavailable ? "화면 연결됨 · 오디오를 사용할 수 없습니다." : "화면 연결됨"
        case .ended: terminalStatus ?? "화면 연결을 끊었습니다."
        }
    }

    var message: String? {
        switch phase {
        case .connecting: "PC 화면에 연결하는 중…"
        case .waiting: "PC 영상을 기다리는 중…"
        case .reconnecting: "화면을 다시 연결하는 중… 마지막 화면이 표시됩니다."
        case .live: audioWarning
        case .ended: nil
        }
    }

    mutating func receive(_ event: StreamEvent) {
        guard phase != .ended else { return }
        switch event {
        case .firstFrame: receivedFreshFrame = true; hasReceivedVideo = true; phase = .live
        case .reconnecting:
            receivedFreshFrame = false; audioUnavailable = false; phase = .reconnecting
        // A recovered transport is not proof that a fresh picture has arrived.
        case .reconnected: if !receivedFreshFrame { phase = .waiting }
        case .waitingForVideo(true):
            if phase != .reconnecting { phase = .waiting }
        case .waitingForVideo(false):
            if phase == .waiting && receivedFreshFrame { phase = .live }
        // Stage failures can belong to a retryable reconnect attempt.
        case .audioFailed: audioUnavailable = true
        case .connectionTerminated(let code, let error):
            terminalStatus = Self.terminationMessage(code: code, hasReceivedVideo: hasReceivedVideo, error: error)
            phase = .ended
        case .stopped: phase = .ended
        default: break
        }
    }

    /// Remote diagnostic strings never become shell copy. Keep the engine's typed failure reason.
    private static func terminationMessage(code: Int32, hasReceivedVideo: Bool, error: StreamError?) -> String {
        if let error {
            switch StreamFailure.connection(error) {
            case .unreachable, .hostTimedOut:
                return "PC에 다시 연결하지 못했습니다. Sunshine의 실행 상태와 Wi-Fi·Tailscale 연결을 확인한 뒤 다시 연결하세요."
            case .pairing, .pairingRejected, .pairingRequired:
                return "PC의 연결 권한이나 인증서를 확인하지 못했습니다. 저장된 PC를 직접 확인한 뒤 다시 연결하세요. 인증서는 자동으로 교체하지 않습니다."
            case .security:
                return "화면 보안 연결을 확인하지 못해 중단했습니다. Sunshine의 암호화 설정을 확인하고 다시 연결하세요."
            default: break
            }
        }
        switch StreamFailure.termination(code: code, hasReceivedVideo: hasReceivedVideo) {
        case .videoDidNotResume:
            return "PC의 영상이 다시 시작되지 않았습니다. Sunshine의 화면 캡처 상태를 확인한 뒤 다시 연결하세요."
        case .noVideoTraffic:
            return "PC에서 영상을 받지 못했습니다. Sunshine의 실행 상태와 방화벽을 확인한 뒤 다시 연결하세요."
        case .noDecodedVideo:
            return "PC의 영상을 표시하지 못했습니다. 화면 캡처 설정을 확인하고 해상도를 낮춰 다시 연결하세요."
        case .connectionLost:
            return "PC와의 연결이 끊겼습니다. Wi-Fi·Tailscale 연결과 Sunshine의 실행 상태를 확인한 뒤 다시 연결하세요."
        case .protectedContent:
            return "보호된 콘텐츠로 인해 화면 연결이 종료되었습니다. PC에서 다른 화면을 연 뒤 다시 연결하세요."
        case .frameConversion:
            return "PC의 영상 형식을 처리하지 못했습니다. PC의 HDR·해상도 설정을 확인한 뒤 다시 연결하세요."
        case .unexpected:
            return "화면 연결이 종료되었습니다. PC의 Sunshine 상태를 확인한 뒤 다시 연결하세요."
        }
    }
}
