// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Reverse desktop setup policy. These hints never authorize pairing or file access.
public enum MacHostPolicy {
    public static let sunshineVersion = "2026.914.233613"
    public static let sunshineCommit = "63d35f702ee9e362e43263742981836ec0710384"
    public static let bundleIdentifier = "dev.lizardbyte.app.Sunshine"
    public static let signingTeam = "F8XQ7XCN2R"
    public static let webURL = URL(string: "https://localhost:47990")!
    public struct Download: Sendable, Equatable {
        public let architecture: String
        public let bytes: Int64
        public let sha256: String
        public var url: URL {
            URL(string: "https://github.com/LizardByte/Sunshine/releases/download/v\(MacHostPolicy.sunshineVersion)/Sunshine-macOS-\(architecture).dmg")!
        }
    }
    public static let arm64 = Download(architecture: "arm64", bytes: 40_375_035,
        sha256: "795f03a389c5726f9a7b15f501dc1ddf204b442cae565859ac83aae027a9e07c")
    public static let x86_64 = Download(architecture: "x86_64", bytes: 43_417_393,
        sha256: "764b11674babac0cd838c2883359207a481c462f355ccbfd1ec91f6d44672101")
    public static var currentDownload: Download {
        #if arch(arm64)
        arm64
        #else
        x86_64
        #endif
    }
    /// CLI values override even a configuration edited in Sunshine's web UI.
    /// The private web UI uses loopback origin enforcement; the stream listeners
    /// use IPv4 interfaces. This does not create a firewall or block port forwards.
    public static func arguments(directory: URL, name: String) throws -> [String] {
        guard directory.isFileURL, ConnectionInvitation.validName(name),
              !directory.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !directory.path.contains("="), !directory.path.contains("#"),
              !name.contains("#"), !name.contains("["), !name.contains("]") else { throw Failure.invalidConfiguration }
        let paths = ["file_apps": "apps.json", "file_state": "state.json", "credentials_file": "web-credentials.json",
                     "pkey": "credentials/cakey.pem", "cert": "credentials/cacert.pem"]
        return [directory.appendingPathComponent("sunshine.conf").path] + paths.sorted { $0.key < $1.key }.map {
            "\($0.key)=\(directory.appendingPathComponent($0.value).path)"
        } + ["sunshine_name=\(name)", "lan_encryption_mode=2", "wan_encryption_mode=2", "upnp=disabled",
             "origin_web_ui_allowed=pc", "address_family=ipv4", "system_tray=disabled", "controller=disabled",
             "install_steam_audio_drivers=disabled", "log_path=/dev/null", "port=47989"]
    }
    public static let desktopApplications = Data("{\"env\":{},\"apps\":[{\"name\":\"Desktop\",\"cmd\":\"\"}]}\n".utf8)
    public enum Failure: Error, LocalizedError {
        case invalidConfiguration, installationRequired, untrustedApplication, existingHost, privateStorage, helperUnavailable, exited, download, collision
        public var errorDescription: String? {
            switch self {
            case .invalidConfiguration: "이 Mac의 공유 설정을 만들 수 없습니다. Mac 이름과 앱 저장 위치를 확인하세요."
            case .installationRequired: "고정된 버전의 Sunshine을 Applications 폴더에 설치한 뒤 다시 시작하세요."
            case .untrustedApplication: "Sunshine의 버전 또는 공식 서명을 확인하지 못했습니다. 안내된 공식 DMG로 다시 설치하세요. 보안 설정을 해제하지 마세요."
            case .existingHost: "Sunshine이 이미 실행 중입니다. 기존 Sunshine을 직접 종료한 뒤 다시 시작하세요. 기존 설정과 프로세스는 변경하지 않습니다."
            case .privateStorage: "공유 설정 폴더의 소유권 또는 접근 권한을 확인하지 못했습니다. 공유를 시작하지 않았습니다."
            case .helperUnavailable: "Knot 공유 도우미를 안전하게 시작하지 못했습니다. 공식 Knot 패키지와 macOS·조직의 실행 정책을 확인한 뒤 다시 설치하거나 실행하세요. 공유를 시작하지 않았습니다."
            case .exited: "공유 프로세스가 종료되었습니다. Knot 도우미와 macOS·조직의 실행 정책, Sunshine 설치 버전·화면 기록·손쉬운 사용 권한 및 포트 충돌을 확인한 뒤 다시 시작하세요."
            case .download: "공식 Sunshine 다운로드를 확인하지 못했습니다. 네트워크를 확인하고 다시 받으세요."
            case .collision: "같은 이름의 파일이 이미 있습니다. 다른 위치나 이름을 선택하세요."
            }
        }
    }
}

public struct MacHostAddress: Identifiable, Equatable, Sendable {
    public let interface: String
    public let address: String
    public var id: String { address }
    public var label: String { address.hasPrefix("100.") ? "Tailscale · \(address)" : "\(interface) · \(address)" }
    public init(interface: String, address: String) throws {
        let checked = try EndpointPolicy.validatedAddress(address)
        guard checked == address, !address.hasPrefix("169.254."), !interface.isEmpty, interface.utf8.count <= 32,
              interface.utf8.allSatisfy({ ($0 == 45 || $0 == 46 || (48...57).contains($0)) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 })
        else { throw MacHostPolicy.Failure.invalidConfiguration }
        self.interface = interface; self.address = address
    }
    public static func selected(_ candidates: [MacHostAddress]) -> [MacHostAddress] {
        var seen = Set<String>()
        return Array(candidates.sorted {
            ($0.address.hasPrefix("100.") ? 0 : 1, $0.address) < ($1.address.hasPrefix("100.") ? 0 : 1, $1.address)
        }.filter { seen.insert($0.address).inserted }.prefix(8))
    }
}
