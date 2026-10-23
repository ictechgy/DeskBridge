// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import GlimmerEngine
import DeskBridgeCore

/// Exercise the actual operation catch path with typed synthetic failures.
@MainActor
func runDesktopFailureGuidanceChecks(temporary: URL) async throws -> Int {
    var count = 0
    func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ModelCheckFailure(message: message) }; count += 1
    }
    let suite = "org.deskbridge.synthetic." + UUID().uuidString
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let model = DesktopModel(storageDirectory: temporary.appendingPathComponent("desktop-guidance"), identitySuite: suite)
    let raw = "synthetic-untrusted-detail-192.0.2.1-private-path"
    let cases: [(any Error, String)] = [
        (ConnectionInvitation.Failure.invalid, "새 연결 QR"),
        (CorePrivateStorageFailure.unsafeStorage, "저장 폴더"),
        (IdentityStorageError.unsafeStorage, "저장 폴더"),
        (IdentityStorageError.incompleteIdentity, "백업에서 복원"),
        (StreamSecurityPolicy.Failure.plaintextSignalling, "필수 화면 암호화"),
        (StreamSecurityPolicy.Failure.missingEncryption(7), "필수 화면 암호화"),
        (PairingFailure.invalidAddress, "IPv4 주소"),
        (PairingFailure.unreachable, "네트워크 연결"),
        (PairingFailure.gameStream, "Sunshine 호스트"),
        (PairingFailure.timedOut, "PIN 입력 시간"),
        (PairingFailure.busy, "다른 PIN 연결"),
        (PairingFailure.rejected, "승인하지 않았습니다"),
        (StreamError.hostCertChanged(raw), "인증서와 다릅니다"),
        (StreamError.sunshineNeedsRestart(raw), "Sunshine을 다시 시작"),
        (StreamError.pairingFailed(raw), "연결 권한과 PIN"),
        (StreamError.pairingRejected, "연결 권한과 PIN"),
        (StreamError.hostUnreachable(raw), "방화벽"),
        (StreamError.hostTimedOut, "방화벽"),
        (StreamError.truncatedRead(raw), "방화벽"),
        (StreamError.gameStreamHost, "Sunshine 호스트"),
        (StreamError.hostRefused(message: raw, code: 403), "Desktop을 열지 못했습니다"),
        (StreamError.launchFailed(raw), "Desktop을 열지 못했습니다"),
        (StreamError.streamPortsBlocked(proto: raw, port: 47998), "통신이 차단"),
        (StreamError.sessionFailed(-9876), "화면 연결을 시작하지 못했습니다"),
        (StreamError.binaryNotFound, "화면 연결을 시작하지 못했습니다"),
        (StreamError.decoderFailed(raw), "해상도를 낮춰"),
        (StreamError.audioFailed(raw), "오디오 장치·네트워크"),
        (StreamError.crypto(raw), "보안 연결"),
    ]
    for (error, guidance) in cases {
        model.pairingPIN = "1234"
        model.perform { throw error }
        for _ in 0..<1000 {
            if !model.busy { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try expect(!model.busy && model.errorMessage?.contains(guidance) == true,
                   "typed desktop failure did not display the corresponding Korean recovery guidance")
        try expect(model.errorMessage?.contains(raw) == false,
                   "untrusted low-level host detail escaped into desktop error guidance")
        try expect(model.pairingPIN == nil && model.status == "작업을 완료하지 못했습니다.",
                   "failed desktop operation retained its PIN or busy status")
    }
    let localMessage = "합성 설정 오류를 확인하세요."
    try expect(DesktopModel.failureMessage(AppFailure(localMessage)) == localMessage,
               "local actionable app errors must retain their specific guidance")
    let unknown = DesktopModel.failureMessage(NSError(domain: raw, code: -1, userInfo: [NSLocalizedDescriptionKey: raw]))
    try expect(unknown.contains("작업을 완료하지 못했습니다") && !unknown.contains(raw),
               "unknown framework errors must use fixed Korean guidance")
    let files = FilesModel(desktop: model)
    files.perform { throw NSError(domain: raw, code: -1, userInfo: [NSLocalizedDescriptionKey: raw]) }
    for _ in 0..<1000 {
        if !files.busy { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    try expect(!files.busy && files.errorMessage?.contains("개인 키의 접근 권한") == true && files.errorMessage?.contains(raw) == false,
               "file operations exposed raw framework storage details")
    try expect(FilesModel.failureMessage(AppFailure(localMessage)) == localMessage,
               "file operations lost actionable local guidance")
    try expect(FilesModel.failureMessage(CorePrivateStorageFailure.unsafeStorage).contains("저장 폴더"),
               "file credential storage refusal lost actionable local guidance")
    let denied = temporary.appendingPathComponent("startup-storage-guidance")
    try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var saved = SavedSettings(); saved.address = "192.168.1.21"; saved.sshHostPublicKey = "SYNTHETIC PRESERVED PIN"
    let deniedStore = SettingsStore(directory: denied); try deniedStore.save(saved)
    let savedFile = denied.appendingPathComponent("settings.json")
    let before = try Data(contentsOf: savedFile)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: denied.path)
    let deniedModel = DesktopModel(storageDirectory: denied, identitySuite: suite)
    try expect(deniedModel.errorMessage?.contains("접근 권한") == true && deniedModel.errorMessage?.contains("설정 파일을 복구") == false,
               "startup permission refusal lost typed storage guidance")
    let startupMessage = deniedModel.errorMessage
    do { try deniedModel.assertStorageReady(); throw ModelCheckFailure(message: "unsafe startup allowed operations") }
    catch let error as AppFailure { try expect(error.message == startupMessage, "later operations changed the startup recovery guidance") }
    let deniedFiles = FilesModel(desktop: deniedModel)
    deniedFiles.perform { try deniedModel.assertStorageReady() }
    for _ in 0..<1000 { if !deniedFiles.busy { break }; try await Task.sleep(for: .milliseconds(1)) }
    try expect(deniedFiles.errorMessage == startupMessage, "file operation lost the same storage refusal")
    try expect(try Data(contentsOf: savedFile) == before, "storage guidance modified saved credentials")
    return count
}
