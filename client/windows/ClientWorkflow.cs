// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Threading;
using System.Threading.Tasks;

namespace DeskBridge.Reverse
{
    internal enum ClientMessage
    {
        Title, Initial, Sidebar, Heading, Setup, AddressHeading, LinkName, CandidateName,
        ManualName, NoTarget, EngineNetwork, PairButton, PinInstructions, StreamHeading,
        CommandOption, StreamButton, Keyboard, Shortcuts, Availability, LinkPreview,
        QrTitle, ManualTarget, AddressSelected, DiscoveryEmpty, DiscoveryFound,
        EngineReady, PairStarted, PairFinished, StreamFinished, EngineFailed
    }

    // Explicit role messages keep Linux behavior independent of edits to Mac copy.
    internal static class ReverseClientText
    {
        internal static string Get(ClientMessage message, HostPlatform platform)
        {
            bool mac = platform == HostPlatform.Mac;
            switch (message)
            {
                case ClientMessage.Title: return mac ? "Knot · Mac 열기" : "Knot · Linux 열기";
                case ClientMessage.Initial: return mac ? "Mac에서 ‘이 Mac 공유’를 시작한 뒤 QR/링크 또는 같은 Wi-Fi 검색으로 주소를 선택하세요. 아직 연결을 확인하지 않았습니다." : "Linux에서 Knot 공유를 시작한 뒤 QR/링크 또는 같은 Wi-Fi 검색으로 주소를 선택하세요. 아직 연결을 확인하지 않았습니다.";
                case ClientMessage.Sidebar: return mac ? "Knot\r\n\r\nMac 열기\r\n\r\n① 주소 선택\r\n② PIN 연결\r\n③ 화면 열기" : "Knot\r\n\r\nLinux 열기\r\n\r\n① 주소 선택\r\n② PIN 연결\r\n③ 화면 열기";
                case ClientMessage.Heading: return mac ? "Windows에서 Mac 열기" : "Windows에서 Linux 열기";
                case ClientMessage.Setup: return mac ? "같은 Wi-Fi 또는 이미 연결된 Tailscale을 사용합니다. Mac에서 Knot의 ‘이 Mac 공유’를 켜고 화면 녹화·손쉬운 사용 권한을 허용하세요. 로그인한 Mac의 Desktop을 엽니다." : "같은 Wi-Fi 또는 이미 연결된 Tailscale을 사용합니다. Ubuntu 24.04 LTS amd64의 X11 데스크톱에서 Knot의 ‘이 Linux 공유’를 시작하세요. Linux 파일 전송·Wayland·로그인 화면은 아직 지원하지 않습니다. PIN으로 PC를 확인하세요.";
                case ClientMessage.AddressHeading: return mac ? "1. Mac 주소 선택" : "1. Linux 주소 선택";
                case ClientMessage.LinkName: return mac ? "Mac 연결 링크" : "Linux 연결 링크";
                case ClientMessage.CandidateName: return mac ? "미확인 Mac 주소 후보" : "미확인 Linux 주소 후보";
                case ClientMessage.ManualName: return mac ? "Mac의 LAN 또는 Tailscale IPv4 주소" : "Linux의 LAN 또는 Tailscale IPv4 주소";
                case ClientMessage.NoTarget: return mac ? "선택한 Mac 없음 · 연결 미확인" : "선택한 Linux 없음 · 연결 미확인";
                case ClientMessage.EngineNetwork: return mac ? "화면은 선택한 Mac에 직접 연결합니다. Moonlight는 별도로 호환성·게임패드 목록·업데이트 유무를 온라인에서 조회할 수 있습니다. 이 프리뷰는 보안 서명이 없으며, 파일 전송 기능은 역방향에서 아직 지원하지 않습니다." : "화면은 선택한 Linux에 직접 연결합니다. Moonlight는 별도로 호환성·게임패드 목록·업데이트 유무를 온라인에서 조회할 수 있습니다. 이 프리뷰는 보안 서명이 없으며, 파일 전송 기능은 역방향에서 아직 지원하지 않습니다.";
                case ClientMessage.PairButton: return mac ? "PIN으로 Mac 연결" : "PIN으로 Linux 연결";
                case ClientMessage.PinInstructions: return mac ? "PIN은 Moonlight 창에서 표시됩니다. 선택한 Mac의 Sunshine 설정 화면에 직접 입력하고 기기를 승인하세요. QR·링크나 프로그램 종료 코드만으로 Mac의 신원을 확인했다고 표시하지 않습니다." : "PIN은 Moonlight 창에서 표시됩니다. 선택한 Linux의 Sunshine 설정 화면에 직접 입력하고 기기를 승인하세요. QR·링크나 프로그램 종료 코드만으로 Linux의 신원을 확인했다고 표시하지 않습니다.";
                case ClientMessage.StreamHeading: return mac ? "3. Mac 화면 열기" : "3. Linux 화면 열기";
                case ClientMessage.CommandOption: return mac ? "Windows 키를 Mac Command로 보내기 (전체 화면)" : "시스템 키 전달 사용 안 함";
                case ClientMessage.StreamButton: return mac ? "Mac 화면 열기" : "Linux 화면 열기";
                case ClientMessage.Keyboard: return mac ? "기본은 Win+Ctrl+←/→ 등 Windows 단축키를 유지합니다. 위 옵션을 켜면 Windows 키가 Mac Command로 전달되고 Alt+Tab 같은 조합도 Mac으로 갈 수 있습니다. Ctrl은 Mac Control, Alt는 Option이며 Ctrl↔Command 자동 교환은 하지 않습니다." : "Linux 연결은 시스템 키 전달을 끈 상태로 시작합니다. Windows 키·Alt+Tab 등은 로컬 Windows에서 처리될 수 있습니다. Ctrl은 Control, Alt는 Alt로 사용하며 입력 결과는 실제 연결에서 확인하세요.";
                case ClientMessage.Shortcuts: return mac ? "화면에서 Ctrl+Alt+Shift+K로 시스템 키 전달을 켜고 끌 수 있고, Ctrl+Alt+Shift+Q로 화면 연결을 닫습니다. 먼저 전달을 끄면 Windows 데스크톱을 전환할 수 있습니다. 한/영 전환은 Mac 입력기 설정을 확인하세요. 다른 앱을 종료하겠다는 Moonlight 안내는 취소하세요." : "화면 연결을 마치려면 Moonlight 창을 닫거나 Knot의 ‘작업 취소’를 누르세요. 이 앱이 실행한 로컬 화면 엔진만 종료합니다. 한/영 전환은 Linux 입력기 설정을 확인하세요. 다른 앱을 종료하겠다는 Moonlight 안내는 취소하세요.";
                case ClientMessage.Availability: return mac ? "로그인 전 화면·FileVault·잠금 해제·절전 복귀·모니터 없는 사용은 보장하지 않습니다. 실제 연결 상태와 페어링 오류는 Moonlight 창에서 확인하세요." : "로그인 전 화면·잠금 해제·절전 복귀·모니터 없는 사용은 보장하지 않습니다. 실제 연결 상태와 페어링 오류는 Moonlight 창에서 확인하세요.";
                case ClientMessage.LinkPreview: return mac ? "링크를 읽었습니다. 미확인 Mac 주소를 확인하고 ‘선택한 주소 사용’을 누르세요. 아직 접속하지 않았습니다." : "링크를 읽었습니다. 미확인 Linux 주소를 확인하고 ‘선택한 주소 사용’을 누르세요. 아직 접속하지 않았습니다.";
                case ClientMessage.QrTitle: return mac ? "Mac 연결 QR 이미지 선택" : "Linux 연결 QR 이미지 선택";
                case ClientMessage.ManualTarget: return mac ? "직접 입력한 Mac" : "직접 입력한 Linux";
                case ClientMessage.AddressSelected: return mac ? "주소를 선택했습니다. Mac에서 ‘이 Mac 공유’를 시작한 뒤 PIN으로 연결하세요. 주소만으로 기기 신원을 신뢰하지 않습니다." : "주소를 선택했습니다. Linux에서 ‘이 Linux 공유’를 시작한 뒤 PIN으로 연결하세요. 주소만으로 기기 신원을 신뢰하지 않습니다.";
                case ClientMessage.DiscoveryEmpty: return mac ? "주변 주소 안내를 찾지 못했습니다. Mac의 QR/링크를 사용하세요. Tailscale 기기는 Wi-Fi 검색에 나타나지 않을 수 있습니다." : "주변 주소 안내를 찾지 못했습니다. Linux의 QR/링크를 사용하세요. Tailscale 기기는 Wi-Fi 검색에 나타나지 않을 수 있습니다.";
                case ClientMessage.DiscoveryFound: return mac ? "검색 결과는 미확인 Sunshine 기기입니다. 사용하려는 Mac과 주소를 확인하고 선택하세요." : "검색 결과는 미확인 Sunshine 기기입니다. 사용하려는 Linux와 주소를 확인하고 선택하세요.";
                case ClientMessage.EngineReady: return mac ? "화면 엔진 파일 검증을 완료했습니다. 다음으로 Mac의 PIN 승인을 진행하세요. 아직 Mac 연결은 확인하지 않았습니다." : "화면 엔진 파일 검증을 완료했습니다. 다음으로 Linux의 PIN 승인을 진행하세요. 아직 Linux 연결은 확인하지 않았습니다.";
                case ClientMessage.PairStarted: return mac ? "Moonlight의 PIN 연결 창을 실행했습니다. PIN을 선택한 Mac의 Sunshine에 직접 입력하세요. 실제 결과는 Moonlight 창에서 확인합니다." : "Moonlight의 PIN 연결 창을 실행했습니다. PIN을 선택한 Linux의 Sunshine에 직접 입력하세요. 실제 결과는 Moonlight 창에서 확인합니다.";
                case ClientMessage.PairFinished: return mac ? "PIN 연결 창이 종료되었습니다. Moonlight에서 성공을 확인했다면 ‘Mac 화면 열기’를 누르세요." : "PIN 연결 창이 종료되었습니다. Moonlight에서 성공을 확인했다면 ‘Linux 화면 열기’를 누르세요.";
                case ClientMessage.StreamFinished: return mac ? "화면 엔진이 종료되었습니다. Mac의 앱은 종료 요청하지 않았습니다." : "화면 엔진이 종료되었습니다. Linux의 앱은 종료 요청하지 않았습니다.";
                case ClientMessage.EngineFailed: return mac ? "화면 엔진이 정상 완료되지 않았습니다. Moonlight의 오류 안내와 Mac의 공유 상태·권한을 확인한 뒤 다시 시도하세요." : "화면 엔진이 정상 완료되지 않았습니다. Moonlight의 오류 안내와 Linux의 공유 상태를 확인한 뒤 다시 시도하세요.";
                default: throw new ArgumentOutOfRangeException("message");
            }
        }
    }

    internal sealed class QrImportResult
    {
        internal readonly string Link;
        internal readonly ReverseInvitation Invitation;
        internal QrImportResult(string link, ReverseInvitation invitation) { Link = link; Invitation = invitation; }
    }

    internal sealed class QrImportRequest
    {
        private readonly HostPlatform platform;
        private readonly string address, link;
        private readonly long generation;
        internal QrImportRequest(HostPlatform platform, string address, string link, long generation)
        { this.platform = platform; this.address = address; this.link = link; this.generation = generation; }
        internal bool Matches(HostPlatform currentPlatform, string currentAddress, string currentLink, long currentGeneration)
        { return platform == currentPlatform && address == currentAddress && link == currentLink && generation == currentGeneration; }
        internal Task<QrImportResult> ReadAsync(string path, CancellationToken cancel)
        { return ReadAsync(path, ReverseQrReader.Read, cancel); }
        // GDI+ and the bounded decoder do not offer an interruptible operation. A
        // cancellation discards their eventual result; the caller waits for cleanup.
        internal Task<QrImportResult> ReadAsync(string path, Func<string, string> read, CancellationToken cancel)
        {
            return Task.Run(() =>
            {
                cancel.ThrowIfCancellationRequested();
                string text = read(path);
                cancel.ThrowIfCancellationRequested();
                ReverseInvitation invitation = ConnectionPolicy.Parse(text);
                ConnectionPolicy.RequireRole(invitation, platform);
                return new QrImportResult(text, invitation);
            }, cancel);
        }
    }
}
