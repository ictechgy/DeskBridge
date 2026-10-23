// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.IO;

namespace DeskBridge.Reverse
{
    internal enum ReverseFailure
    {
        EngineIntegrity, EngineArchive, EngineDownload, DownloadIdle, DownloadDeadline,
        EnginePolicy, StoragePolicy, LinkedStorage, ProfilePolicy, EngineStart,
        EngineBusy, BootstrapRequired, AdministratorNotAllowed, WindowsRequired, Discovery, OperationFailed
    }

    // Only an enum selects authored messages. No OS exception text, target, file path,
    // inner exception or remotely supplied string enters this presentation boundary.
    internal sealed class ReverseUserException : IOException
    {
        internal ReverseUserException(ReverseFailure failure) : base(ReverseErrors.Fixed(failure)) { }
    }

    internal static class ReverseErrors
    {
        internal const string Fallback = "작업을 완료하지 못했습니다. 주소·인터넷 연결·앱 폴더 접근 권한과 Moonlight 안내를 확인한 뒤 다시 시도하세요. 시스템 경로·로그·비밀 정보는 이 창에 표시하지 않습니다.";
        internal const string QrGuidance = "QR 이미지를 읽지 못했습니다. 공유할 PC의 Knot에서 새 PNG QR 이미지를 만드세요. OneDrive·공유·링크 폴더 밖의 로컬 폴더를 직접 만든 뒤 이미지를 복사하세요. 예: 파일 탐색기에서 %LOCALAPPDATA%를 열고 Knot-QR 폴더를 만든 뒤 그 안의 PNG를 선택하세요. 한 장에 PC 연결 QR 하나만 포함하고 8 MiB 이하로 저장하세요.";
        internal static string Fixed(ReverseFailure failure)
        {
            switch (failure)
            {
                case ReverseFailure.EngineIntegrity:
                    return "화면 엔진 파일이 바뀌었거나 손상되어 실행하지 않았습니다. 자동으로 삭제하거나 덮어쓰지 않습니다. Knot을 닫고 파일 탐색기에서 %LOCALAPPDATA%\\DeskBridge-Reverse-v1을 여세요. 이름이 engine-으로 시작하는 해당 엔진 폴더를 별도 로컬 폴더에 보관한 뒤 Knot의 ‘화면 엔진 받기’를 다시 누르세요. profiles 폴더는 옮기거나 지우지 마세요.";
                case ReverseFailure.EngineArchive:
                    return "다운로드한 화면 엔진의 고정 크기·해시·파일 구성을 확인하지 못했습니다. 설치하지 않았습니다. 인터넷 연결을 확인하고 ‘화면 엔진 받기’를 다시 누르세요.";
                case ReverseFailure.EngineDownload:
                    return "공식 화면 엔진 다운로드를 완료하지 못했습니다. 인터넷 연결을 확인하고 ‘화면 엔진 받기’를 다시 누르세요.";
                case ReverseFailure.DownloadIdle:
                    return "60초 동안 화면 엔진 다운로드가 진행되지 않아 중단했습니다. 인터넷 연결을 확인하고 다시 시도하세요.";
                case ReverseFailure.DownloadDeadline:
                    return "화면 엔진 다운로드가 10분 안에 완료되지 않아 중단했습니다. 인터넷 연결을 확인하고 다시 시도하세요.";
                case ReverseFailure.EnginePolicy:
                    return "이 Knot 빌드의 고정 화면 엔진 목록을 확인할 수 없습니다. 공식 배포 파일을 다시 받으세요. 임의 엔진은 실행하지 않습니다.";
                case ReverseFailure.LinkedStorage:
                    return "앱 저장 경로에 링크·클라우드 재분석 지점이 있어 사용하지 않았습니다. OneDrive·공유·링크 밖의 로컬 Windows 사용자 계정에서 실행하세요. QR 이미지는 %LOCALAPPDATA%를 연 뒤 직접 만든 Knot-QR 폴더에 복사해서 선택하세요.";
                case ReverseFailure.StoragePolicy:
                    return "앱 전용 폴더의 소유자·접근 권한·생성 상태를 확인할 수 없습니다. 기존 폴더를 자동으로 가져오거나 삭제하지 않습니다. Knot을 닫고 로컬 사용자 계정과 앱 데이터 폴더 권한을 확인하세요.";
                case ReverseFailure.ProfilePolicy:
                    return "앱 전용 연결 프로필의 구성·사용 잠금을 확인할 수 없습니다. 다른 Knot와 Moonlight 연결 창을 닫은 뒤 다시 시도하세요. 기존 Moonlight 설정을 가져오거나 인증서를 자동 초기화하지 않습니다.";
                case ReverseFailure.EngineBusy:
                    return "이미 화면 엔진 작업이 진행 중입니다. 현재 작업을 마치거나 취소한 뒤 다시 시도하세요.";
                case ReverseFailure.EngineStart:
                    return "화면 엔진을 안전한 로컬 실행 경계에서 시작하지 못했습니다. 다른 연결 창을 닫고 다시 시도하세요. 관리자 권한으로 다시 실행하지 마세요.";
                case ReverseFailure.BootstrapRequired:
                    return "원본 Knot 실행 파일을 확인할 수 없습니다. 배포용 Knot EXE를 로컬 폴더에 저장한 뒤 평소처럼 두 번 클릭하세요.";
                case ReverseFailure.AdministratorNotAllowed:
                    return "관리자 창을 닫고 Knot EXE를 평소처럼 실행하세요. 화면 연결은 관리자 권한이 필요하지 않습니다.";
                case ReverseFailure.WindowsRequired:
                    return "Windows 11 x64에서 실행하세요.";
                case ReverseFailure.Discovery:
                    return "근처 PC 검색을 완료하지 못했습니다. 공유할 PC의 Knot에서 연결 QR 또는 링크를 가져오세요. Tailscale 기기는 Wi-Fi 검색에 나타나지 않을 수 있습니다.";
                default: return Fallback;
            }
        }

        internal static string ForOperation(Exception error, HostPlatform platform = HostPlatform.Mac)
        {
            if (error is ReverseUserException) return error.Message;
            if (error is OperationCanceledException)
                return platform == HostPlatform.Mac ? "작업을 취소했습니다. Mac의 앱·공유 설정에는 종료 요청하지 않았습니다." :
                    platform == HostPlatform.Linux ? "작업을 취소했습니다. Linux의 앱·공유 설정에는 종료 요청하지 않았습니다." :
                    "작업을 취소했습니다. Windows의 앱·공유 설정에는 종료 요청하지 않았습니다.";
            if (error is InvalidDataException) return QrGuidance;
            if (error is FormatException || error is ArgumentException)
            {
                // Keep only exact authored validation messages. Unexpected .NET parse/path
                // errors can contain caller data and must fall through to fixed guidance.
                foreach (string allowed in new[] {
                    "LAN 또는 Tailscale IPv4 주소를 입력하세요.",
                    "LAN 또는 Tailscale의 IPv4 주소만 지원합니다. 예: 192.168.1.20",
                    "지원되는 PC 연결 링크가 아닙니다. 공유할 PC의 Knot에서 새 QR/링크를 만드세요.",
                    "연결 QR의 대상 OS가 다릅니다. 해당 PC의 역할을 선택하고 새 QR/링크를 가져오세요.",
                    "지원되지 않는 해상도입니다.", "지원되지 않는 화면 설정입니다.",
                    "Mac Command 키 전달은 전체 화면에서만 선택하세요.", "잘못된 실행 인수입니다." })
                    if (error.Message == allowed) return allowed;
            }
            return Fallback;
        }
    }
}
