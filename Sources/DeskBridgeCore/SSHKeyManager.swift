// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 DeskBridge contributors
import Foundation
import Darwin

public enum SSHKeyManager {
    public struct GeneratedKey: Sendable { public let privateKey: URL; public let publicKey: String }
    /// Called only by an explicit user action. No user ssh config/agent/keychain is read.
    public static func generate(in directory: URL) throws -> GeneratedKey {
        guard let base = try CorePrivateStorage.directory(directory, create: true) else { throw CorePrivateStorage.unsafe }
        defer { close(base) }
        guard let root = try CorePrivateStorage.child(base, name: "SSH", create: true) else { throw CorePrivateStorage.unsafe }
        defer { close(root) }
        let name = UUID().uuidString
        guard let generated = try CorePrivateStorage.child(root, name: name, create: true, exclusive: true)
        else { throw CorePrivateStorage.unsafe }
        var published = false
        defer {
            if !published {
                // Only our exclusive fresh directory and fixed key names are owned.
                // Unexpected contents are preserved; never recursively remove a path.
                _ = unlinkat(generated, "id_ed25519", 0)
                _ = unlinkat(generated, "id_ed25519.pub", 0)
                var held = stat(), named = stat()
                if fstat(generated, &held) == 0,
                   fstatat(root, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                   held.st_dev == named.st_dev && held.st_ino == named.st_ino {
                    _ = unlinkat(root, name, AT_REMOVEDIR)
                }
            }
            close(generated)
        }
        let file = directory.appendingPathComponent("SSH/\(name)/id_ed25519")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "DeskBridge", "-f", file.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        // ssh-keygen's public output may inherit a restrictive umask (for example
        // 0640). Only this fresh owner-readable non-executable ordinary file may
        // be tightened, after all owner/link/ACL/size checks.
        let publicFD = openat(generated, "id_ed25519.pub", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard publicFD >= 0 else { throw CorePrivateStorage.unsafe }
        defer { close(publicFD) }
        var publicStat = stat()
        guard fstat(publicFD, &publicStat) == 0,
              publicStat.st_mode & 0o400 != 0,
              (publicStat.st_mode & 0o7777) & ~mode_t(0o666) == 0 else { throw CorePrivateStorage.unsafe }
        try CorePrivateStorage.check(publicFD, directory: false, maximumBytes: 4096, mode: publicStat.st_mode & 0o7777)
        guard fchmod(publicFD, 0o600) == 0 else { throw CorePrivateStorage.unsafe }
        guard let privateBytes = try CorePrivateStorage.read(generated, name: "id_ed25519", maximumBytes: 64 * 1024),
              !privateBytes.isEmpty else { throw CorePrivateStorage.unsafe }
        guard let bytes = try CorePrivateStorage.read(generated, name: "id_ed25519.pub", maximumBytes: 4096),
              let pub = String(data: bytes, encoding: .utf8), !pub.isEmpty else { throw CorePrivateStorage.unsafe }
        published = true
        return GeneratedKey(privateKey: file, publicKey: pub.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

