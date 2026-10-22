// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 DeskBridge contributors
import Foundation
import Darwin

public enum SSHKeyManager {
    public struct GeneratedKey: Sendable { public let privateKey: URL; public let publicKey: String }
    /// Called only by an explicit user action. No user ssh config/agent/keychain is read.
    public static func generate(in directory: URL) throws -> GeneratedKey {
        let root = directory.appendingPathComponent("SSH", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let file = root.appendingPathComponent("id_ed25519-\(UUID().uuidString)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "DeskBridge", "-f", file.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let pub = try String(contentsOf: file.appendingPathExtension("pub"), encoding: .utf8)
        return GeneratedKey(privateKey: file, publicKey: pub.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

