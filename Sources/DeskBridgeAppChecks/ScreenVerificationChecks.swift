// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import GlimmerEngine

@MainActor
func runScreenVerificationChecks(temporary: URL) async throws -> Int {
    var count = 0
    func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ModelCheckFailure(message: message) }; count += 1
    }
    try expect(DesktopModel.displayName(" 개발 PC ", fallback: "192.168.1.20") == "개발 PC", "ordinary host label changed")
    try expect(DesktopModel.displayName("\n\u{202e}\u{0000}", fallback: "192.168.1.20") == "192.168.1.20",
               "empty or control-only host label did not use the selected address")
    let excessiveName = String(repeating: "합성🖥️", count: 40_000)
    let boundedName = DesktopModel.displayName(excessiveName, fallback: "192.168.1.20")
    try expect(!boundedName.isEmpty && boundedName.utf8.count <= 256, "UTF-8 host label limit failed")
    for (connected, bound, candidate, expected): (Bool, String?, String, Bool) in [
        (true, "192.168.1.20", "192.168.1.20", true),
        (true, "192.168.1.20", "192.168.1.21", false),
        (true, "100.80.10.20", "100.80.10.20", true),
        (false, "192.168.1.20", "192.168.1.20", false),
        (true, nil, "192.168.1.20", false),
        (true, "192.168.1.20", " 192.168.1.20", false),
        (true, "8.8.8.8", "8.8.8.8", false),
    ] {
        try expect(FilesModel.connectionMatches(connected: connected, connectedAddress: bound, validatedAddress: candidate) == expected,
                   "screen verification did not preserve the exact canonical file target")
    }
    let suite = "org.deskbridge.synthetic." + UUID().uuidString
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let metadataModel = DesktopModel(storageDirectory: temporary.appendingPathComponent("bounded-host-metadata"), identitySuite: suite,
        operations: DesktopOperations(fetchServerInfo: { _, _ in
            ServerInfo(address: "192.168.1.20", uniqueId: "synthetic-unchanged-identity", serverName: excessiveName)
        }, appList: { _ in throw ModelCheckFailure(message: "unpaired metadata fixture requested applications") },
        openStream: { _, _, _, _, _ in throw ModelCheckFailure(message: "metadata fixture opened a stream") }))
    metadataModel.address = "192.168.1.20"
    metadataModel.connect()
    for _ in 0..<1000 {
        if !metadataModel.busy { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    try expect(!metadataModel.busy && metadataModel.errorMessage == nil && metadataModel.serverName == boundedName,
               "actual verification path published unbounded host metadata")
    let desktop = DesktopModel(storageDirectory: temporary.appendingPathComponent("screen-verification"), identitySuite: suite)
    let files = FilesModel(desktop: desktop)
    try expect(desktop.canVerifyCurrentPC, "idle file model blocked screen verification")
    files.busy = true
    try expect(!desktop.canVerifyCurrentPC, "active file operation allowed screen verification")
    files.busy = false; files.connected = true
    try expect(!desktop.canVerifyCurrentPC, "unbound synthetic file connection allowed a screen target")
    files.connected = false; desktop.streaming = true
    try expect(!desktop.canVerifyCurrentPC, "live stream allowed another verification")
    desktop.streaming = false
    files.connect()
    for _ in 0..<1000 {
        if !files.busy { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    try expect(!files.busy && !files.connected && files.errorMessage?.contains("개인 키를 먼저") == true,
               "empty identity did not fail before creating an SSH connection")
    // Use an invalid port to stop the actual connect path before any key-file read or SSH construction.
    desktop.address = "192.168.1.20"
    files.identityPath = "/synthetic-unused-key"; files.port = "0"
    for state in 0..<4 {
        desktop.streaming = state == 0; desktop.busy = state == 1
        files.busy = state == 2; files.connected = state == 3
        desktop.paired = true; desktop.fingerprint = "synthetic-verified-target"
        files.connect(address: "192.168.1.21")
        try expect(desktop.address == "192.168.1.20" && desktop.paired && desktop.fingerprint == "synthetic-verified-target",
                   "file draft changed the shared PC during screen/file activity")
    }
    desktop.busy = false; files.busy = false; files.connected = false; desktop.streaming = true
    files.connect(address: " 192.168.1.20\n")
    for _ in 0..<1000 {
        if !files.busy { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    try expect(!files.busy && files.errorMessage?.contains("SSH 포트") == true && desktop.streaming && desktop.paired &&
               desktop.address == "192.168.1.20" && desktop.fingerprint == "synthetic-verified-target",
               "same canonical file target was rejected or invalidated while its screen streamed")
    desktop.streaming = false
    files.connect(address: "192.168.")
    try expect(!files.busy && desktop.address == "192.168.1.20" && desktop.paired,
               "an incomplete submitted file address mutated the verified screen target")
    files.connect(address: "192.168.1.21")
    try expect(files.busy && desktop.address == "192.168.1.21" && !desktop.paired,
               "explicit file address did not use the idle target-selection guard before becoming busy")
    for _ in 0..<1000 {
        if !files.busy { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    try expect(!files.busy && !files.connected && files.errorMessage?.contains("SSH 포트") == true,
               "offline invalid-port file connect did not settle before SSH creation")
    let corruptDirectory = temporary.appendingPathComponent("synthetic-untrusted-storage-detail")
    try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let corruptFile = corruptDirectory.appendingPathComponent("settings.json")
    try Data("synthetic corrupt settings".utf8).write(to: corruptFile)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: corruptFile.path)
    let corrupt = DesktopModel(storageDirectory: corruptDirectory, identitySuite: suite)
    try expect(corrupt.errorMessage?.contains("설정을 읽지 못했습니다") == true &&
               corrupt.errorMessage?.contains(corruptDirectory.path) == false && !corrupt.canVerifyCurrentPC,
               "corrupt settings did not fail closed with fixed Korean guidance")
    return count
}
