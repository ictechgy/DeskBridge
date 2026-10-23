# Windows에서 Mac 화면 연결

Mac 앱의 **이 Mac 공유**에서 준비합니다. 같은 Wi-Fi/LAN 또는 이미 설정한 Tailscale의 IPv4 주소를 사용합니다. Sunshine의 macOS 호스트 지원은 실험 단계입니다. 이 기능은 화면 연결이며 Windows → Mac 파일 전송을 추가하지 않습니다.

1. **Sunshine DMG 받기**를 누르고 저장 위치를 고릅니다. 앱은 공식 고정 버전의 해당 아키텍처 파일을 받은 뒤 정확한 크기와 SHA256을 확인하고 macOS quarantine을 붙입니다. 기존 파일은 덮어쓰지 않습니다.
2. **검증된 DMG 열기**를 눌러 Sunshine을 `/Applications/Sunshine.app`으로 옮깁니다. 앱을 DMG에서 직접 실행하지 않습니다. 설치 상태를 새로 고칩니다. 앱이 있다는 표시만으로 서명이나 연결이 검증된 것은 아닙니다.
3. 최초 실행 시 앱에 웹 관리자 이름과 16~128바이트 비밀번호를 입력합니다. 공유 포트를 열기 전에 무작위 salt와 비밀번호 해시를 0600 파일로 준비하며 평문은 저장하지 않습니다. 기존 계정은 덮어쓰지 않고 손상된 계정은 시작을 거부합니다. 원격 제어 허용 체크 후 **이 Mac 공유 시작**을 누릅니다. 실행 직전에 고정 버전과 Apple 신뢰 체인의 공식 LizardByte 서명·중첩 코드를 확인합니다. 기존 Sunshine이 실행 중이면 직접 종료해야 합니다. Gatekeeper·조직 정책·서명을 해제하는 우회는 하지 않습니다.
4. macOS의 화면 및 시스템 오디오 기록·손쉬운 사용 권한은 요청에 실제 표시된 앱에 직접 승인합니다. Knot가 자식 프로세스를 시작하므로 책임 앱인 Knot가 권한 대상이 될 수 있습니다. Sunshine만 승인하면 충분하다고 가정하지 말고, 시스템 설정에서 요청에 표시된 Knot 또는 Sunshine 항목을 확인한 뒤 공유를 껐다가 다시 켭니다. 자동 권한 승인, 원격 로그인/SSH 활성화, 전체 디스크 접근, 클립보드 동기화, 로그인 자동 실행은 하지 않습니다.
5. **Sunshine 초기 설정 / PIN**으로 `https://localhost:47990`을 열어 앱에서 준비한 Sunshine 웹 관리자 계정으로 로그인합니다. 로컬 자체 서명 인증서 경고가 나타날 수 있습니다. 이 Mac의 고정 localhost 주소인지 확인합니다. Windows의 Knot에서 Mac 연결 QR PNG나 링크 파일을 가져오고 페어링합니다. Windows가 표시하는 PIN을 이 Mac의 Sunshine PIN 페이지에 입력한 뒤 Desktop을 엽니다.

연결 QR·링크는 `deskbridge://connect?v=2`와 `platform=macos`를 사용합니다. Windows의 Mac 역할에서 열고, Windows·Linux 호스트용 Mac 탭에서는 거부합니다. 선택한 LAN/Tailscale 주소 하나와 `Knot Mac` 이름·OS 안내만 포함하며, 비밀번호·인증서·파일 권한을 포함하지 않습니다. 페어링은 별도입니다. 인터페이스 주소는 OS 메타데이터에서만 얻으며 서브넷 스캔·호스트 프로브는 하지 않습니다.

## 프로세스·설정 경계

- 사용자별 `~/Library/Application Support/DeskBridgeMacHost`에 별도 설정·Desktop 앱 목록·웹 자격 증명·인증서·페어링 상태를 보관합니다. 디렉터리는 0700, 앱이 쓰는 설정은 0600이며 심볼릭 링크/하드 링크·다른 사용자 쓰기 접근·확장 ACL을 거부합니다. Sunshine이 내부 상태 파일을 0644로 만들더라도 0700 상위 폴더가 다른 사용자 접근을 막으며, 다음 명시적 시작 때 확인한 파일 디스크립터로 0600으로 강화합니다. 앱 전체의 umask는 바꾸지 않습니다. 기존 `~/.config/sunshine`의 설정·키는 읽거나 가져오지 않습니다. upstream은 시작 중 기본 appdata 디렉터리 자체가 없으면 빈 디렉터리를 만들 수 있으나 실제 설정·키·상태·로그 경로는 별도로 지정합니다.
- 매번 명시적 CLI 값으로 LAN/WAN 암호화 필수(2), UPnP off, 웹 UI `pc`(loopback origin만), IPv4, 트레이·컨트롤러·Steam 오디오 드라이버 설치 off를 강제합니다. 스트림은 IPv4 인터페이스에서 대기하므로 이 기능이 네트워크 방화벽을 만드는 것은 아닙니다. 인터넷 포트 포워딩을 설정하지 마세요.
- 읽을 수 있는 raw Sunshine 로그를 앱에 표시하거나 보관하지 않습니다. 고정된 상태/오류 안내를 제공합니다. 로그 파일·표준 출력/오류는 `/dev/null`입니다.
- 앱이 새로 만든 POSIX 프로세스 그룹만 시작·종료합니다. 저장 PID, 프로세스 이름에 의한 kill, 기존 Sunshine 인수인계는 없습니다. 종료 요청 후 3초가 지나면 같은 소유 그룹만 강제 종료합니다. 원래 자식 PID는 그룹 정리가 끝나기 전까지 회수하지 않아 재사용 PID를 신호하는 것을 방지합니다.
- Sunshine 웹의 **Restart**는 fork를 하므로 해당 자식도 정리하고 공유 꺼짐으로 돌아갑니다. Knot에서 **공유 끄기 → 공유 시작**을 사용하세요. 앱 종료 시 공유도 종료합니다. 앱을 강제 종료하거나 전원이 끊긴 상황의 완전한 종료 보장은 하지 않습니다.

## 무료 입력과 키 대응

이 고정 Sunshine의 `third-party/libvirtualhid`는 commit `53e1a949fc0784af716b782ddfa6c647cafd1f05`입니다. [고정 macOS backend](https://github.com/LizardByte/libvirtualhid/blob/53e1a949fc0784af716b782ddfa6c647cafd1f05/src/platform/macos/macos_backend.cpp)의 `MacosBackend`는 `macos-coregraphics`, `supports_keyboard=true`, `supports_mouse=true`를 제공하고 CoreGraphics `CGEventPost`로 키·마우스를 보냅니다. macOS 키·마우스 생성에는 드라이버 설치나 유료 라이선스 검사가 없습니다. [고정 license map](https://github.com/LizardByte/libvirtualhid/blob/53e1a949fc0784af716b782ddfa6c647cafd1f05/LICENSES/license-map.md)은 non-driver backend를 MIT로 분류하며, 별도 source-available/상용 드라이버 범위는 Windows UMDF 드라이버·브로커입니다. 이 Mac 공유 기능은 해당 Windows 드라이버를 설치하지 않습니다.

해당 소스의 키 테이블에서 전달된 Windows LWIN/RWIN(0x5B/0x5C)은 Mac Command/Right Command, 좌우 Ctrl은 Control, 좌우 Alt는 Option입니다. Ctrl↔Command를 자동 교환하지 않습니다. Windows 자체가 가로채는 시스템 단축키, 한국어 IME/조합 입력, Windows AltGr와 Mac Option 조합, Mission Control은 이 표만으로 동작이 검증되지 않으므로 실제 기기에서 확인해야 합니다.

Windows 클라이언트의 기본값은 시스템 키를 전달하지 않으므로 Windows 키도 로컬에 남습니다. 전체 화면의 **Windows 키를 Mac Command로 보내기**를 켜면 전달되며 Alt+Tab 같은 조합도 Mac으로 갈 수 있습니다. **Ctrl+Alt+Shift+K**로 전달을 전환하고 **Ctrl+Alt+Shift+Q**로 로컬 연결을 닫습니다. 전달을 끈 뒤 Windows 작업 공간을 전환하세요.

## 공급망 근거와 검증 범위

[공식 고정 릴리스](https://github.com/LizardByte/Sunshine/releases/tag/v2026.914.233613)의 GitHub API asset digest·크기를 `SunshineDependency.json`과 Core 정책에 고정합니다. arm64 DMG를 새 임시 폴더에 받아 크기/SHA256 검증 후 읽기 전용으로 마운트하고 실행 없이 `codesign --verify --deep --strict`를 확인했습니다. 서명은 LizardByte LLC의 Team `F8XQ7XCN2R`, bundle ID `dev.lizardbyte.app.Sunshine`입니다. x86_64 파일은 공식 API hash/크기만 확인했으며 대상 기기 검증이 필요합니다.

정책의 CLI 키/우선순위·앱 실행 경로·fork 재시작 처리는 [고정 upstream 소스](https://github.com/LizardByte/Sunshine/tree/63d35f702ee9e362e43263742981836ec0710384)의 `src/config.cpp`, `src/main.cpp`, `src/platform/macos/misc.mm`, `src/confighttp.cpp`, `src/network.cpp`, `cmake/packaging/macos.cmake`로 확인했습니다. Sunshine 소스를 수정하거나 다시 배포하지 않습니다.

합성 검증은 새 임시 파일, 가짜 프로세스 seam, 새로 컴파일한 무해한 fork/종료 fixture, 주소 QR 인코딩/디코딩만 사용합니다. 실제 Sunshine 실행·화면 캡처·사용자 설정/키 읽기·권한 요청은 하지 않았습니다. 실제 Windows↔Mac 페어링, 한/영·Command 키, 소리, DPI/해상도, 잠금/로그인 화면, 모니터 입력 전환, 절전 복귀, 네트워크 손실/재연결·성능은 별도 대상 기기 테스트가 필요합니다.

이전 preview.12 이하에서 공유를 사용했다면 업그레이드 후 Sunshine 웹에 본인이 정한 관리자 계정으로 로그인되는지 확인하고 페어링된 기기 목록을 검토하세요. 기존 계정·페어링은 자동으로 교체하거나 초기화하지 않습니다. 모르는 계정이거나 로그인할 수 없다면 공유를 중지하고 전체 설정을 백업한 뒤 신원과 복구 방법을 확인하세요.
