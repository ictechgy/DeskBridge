// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io
// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

// File-backed identities avoid keychain prompts; see docs/SECURITY.md for the same-user threat model.

import Foundation
import Darwin
import os.log
import Security

// MARK: - Storage keys

// Keep the Moonlight QSettings keys unchanged so existing identities survive migration.
package enum IdentityKey {
    package static let uniqueID    = "uniqueid"
    package static let certificate = "certificate"
    package static let privateKey  = "key"
}

private enum IdentityPrivateStorage {
    static let unsafe = IdentityStorageError.unsafeStorage
    static func directory(_ url: URL, create: Bool) throws -> Int32? {
        guard url.isFileURL, !url.lastPathComponent.isEmpty else { throw unsafe }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard parent >= 0 else {
            if !create && errno == ENOENT { return nil }
            throw unsafe
        }
        defer { close(parent) }
        return try child(parent, name: url.lastPathComponent, create: create)
    }
    static func child(_ parent: Int32, name: String, create: Bool, exclusive: Bool = false) throws -> Int32? {
        guard valid(name) else { throw unsafe }
        if create && mkdirat(parent, name, 0o700) != 0 && (errno != EEXIST || exclusive) { throw unsafe }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            if !create && errno == ENOENT { return nil }
            throw unsafe
        }
        do { try check(fd, directory: true); return fd }
        catch { close(fd); throw error }
    }
    static func check(_ fd: Int32, directory: Bool, maximumBytes: Int = 0, mode: mode_t? = nil) throws {
        var value = stat()
        let expected = mode ?? (directory ? 0o700 : 0o600)
        guard fstat(fd, &value) == 0, value.st_uid == getuid(),
              value.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              value.st_mode & 0o7777 == expected,
              directory || (value.st_nlink == 1 && value.st_size >= 0 && value.st_size <= maximumBytes)
        else { throw unsafe }
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT else { throw unsafe }; return
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { throw unsafe }
        var entry: acl_entry_t?
        errno = 0
        // Darwin uses EINVAL when a valid ACL has no first entry.
        guard acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1, errno == EINVAL else { throw unsafe }
    }
    static func read(_ parent: Int32, name: String, maximumBytes: Int, mode: mode_t = 0o600) throws -> Data? {
        guard valid(name), maximumBytes >= 0 else { throw unsafe }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw unsafe
        }
        defer { close(fd) }
        try check(fd, directory: false, maximumBytes: maximumBytes, mode: mode)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(maximumBytes + 1, 16 * 1024))
        while true {
            let count = Darwin.read(fd, &buffer, min(buffer.count, maximumBytes + 1 - data.count))
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw unsafe }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else { throw unsafe }
        }
        try check(fd, directory: false, maximumBytes: maximumBytes, mode: mode)
        return data
    }
    static func replace(_ parent: Int32, name: String, data: Data, maximumBytes: Int) throws {
        guard valid(name), data.count <= maximumBytes else { throw unsafe }
        _ = try read(parent, name: name, maximumBytes: maximumBytes)
        let temporary = ".private-" + UUID().uuidString
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw unsafe }
        defer { close(fd); _ = unlinkat(parent, temporary, 0) }
        // Inherited ACLs must be refused before the first secret byte is written.
        try check(fd, directory: false, maximumBytes: maximumBytes)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw unsafe }; offset += count
            }
        }
        guard fsync(fd) == 0 else { throw unsafe }
        try check(fd, directory: false, maximumBytes: maximumBytes)
        guard renameat(parent, temporary, parent, name) == 0, fsync(parent) == 0 else { throw unsafe }
    }
    private static func valid(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.utf8.contains(0)
    }
}

// MARK: - FileIdentityStore

// Atomic owner-only files; verify permissions because FUSE/NFS may silently ignore chmod.

package enum FileIdentityStore {

    /// Filename for the X.509 certificate (PEM, full --BEGIN CERTIFICATE-- block).
    package static let certFileName = "client-cert.pem"

    /// Filename for the RSA private key (PEM, PKCS#8 unencrypted).
    package static let keyFileName = "client-key.pem"

    /// Filename for the 32-hex-char client unique ID (raw ASCII, no newline).
    package static let uidFileName = "client-uniqueid.txt"

    /// Account-name → filename mapping. Keeping the `account:` API on the
    /// store mirrors how the old keychain backend was addressed, so the
    /// call sites at the top of `load()` stay readable.
    package static func filename(forAccount account: String) -> String? {
        switch account {
        case IdentityManager.accountCert: return certFileName
        case IdentityManager.accountKey:  return keyFileName
        case IdentityManager.accountUID:  return uidFileName
        default: return nil
        }
    }

    /// The shell supplies the base; identities live under `Glimmer/Identity` within it.
    /// Created on first write with mode 0700.
    package static func directoryURL(base: URL) throws -> URL {
        base.appendingPathComponent("Glimmer/Identity", isDirectory: true)
    }

    package static func fileURL(account: String, base: URL) throws -> URL? {
        guard let name = filename(forAccount: account) else { return nil }
        return try directoryURL(base: base).appendingPathComponent(name, isDirectory: false)
    }

    /// Missing storage is distinct from unsafe storage, which must never regenerate.
    package static func read(account: String, base: URL) throws -> Data? {
        guard let name = filename(forAccount: account) else { throw IdentityStorageError.unsafeStorage }
        guard let root = try openDirectory(base: base, create: false) else { return nil }
        defer { close(root) }
        return try IdentityPrivateStorage.read(root, name: name, maximumBytes: limit(account))
    }

    /// Validate every existing component, even when another component is missing.
    /// This also runs before migration/generation when no version flag is present.
    package static func validateStorage(base: URL) throws {
        for account in [IdentityManager.accountCert, IdentityManager.accountKey, IdentityManager.accountUID] {
            _ = try read(account: account, base: base)
        }
    }

    package static func write(_ data: Data, account: String, base: URL) throws {
        guard let name = filename(forAccount: account), data.count <= limit(account),
              let root = try openDirectory(base: base, create: true) else { throw IdentityStorageError.unsafeStorage }
        defer { close(root) }
        try IdentityPrivateStorage.replace(root, name: name, data: data, maximumBytes: limit(account))
    }

    private static func limit(_ account: String) -> Int {
        account == IdentityManager.accountUID ? 4096 : 64 * 1024
    }

    private static func openDirectory(base: URL, create: Bool) throws -> Int32? {
        guard let root = try IdentityPrivateStorage.directory(base, create: create) else { return nil }
        defer { close(root) }
        guard let glimmer = try IdentityPrivateStorage.child(root, name: "Glimmer", create: create) else { return nil }
        defer { close(glimmer) }
        return try IdentityPrivateStorage.child(glimmer, name: "Identity", create: create)
    }

    /// Only known, validated ordinary identity files are eligible for cleanup.
    package static func delete(account: String, base: URL) {
        guard let name = filename(forAccount: account),
              let root = try? openDirectory(base: base, create: false) else { return }
        defer { close(root) }
        guard (try? IdentityPrivateStorage.read(root, name: name, maximumBytes: limit(account))) != nil else { return }
        _ = unlinkat(root, name, 0)
    }

}

// MARK: - IdentityManager

public actor IdentityManager {

    /// A failed named suite stays unavailable; never borrow another domain's identity.
    let defaults: UserDefaults?
    let storageRoot: @Sendable () throws -> URL
    let protectedDataAvailable: @Sendable () -> Bool
    let migrateIdentity: @Sendable (String?) throws -> AdoptedQtIdentity?

    /// Cached, fully-materialized identity. Built lazily on first access; once
    /// in memory we never touch disk again for the life of the actor.
    package struct Identity {
        let uniqueID: String   // 32-hex-char GUID
        let certPEM: String    // PEM-encoded X.509 certificate
        let keyPEM: String    // PEM-encoded RSA private key (PKCS#8)
    }

    var cached: Identity?

    let log = Logger(subsystem: "io.ugfugl.Glimmer",
                             category: "Stream.Identity")

    public init(defaultsSuite: String?, supportBase: URL,
                protectedDataAvailable: @escaping @Sendable () -> Bool) {
        self.init(defaultsSuite: defaultsSuite, storageRoot: { supportBase },
                  protectedDataAvailable: protectedDataAvailable, migrateIdentity: { _ in nil })
    }

    package init(defaultsSuite: String?, storageRoot: @escaping @Sendable () throws -> URL,
                 protectedDataAvailable: @escaping @Sendable () -> Bool = { true },
                 migrateIdentity: @escaping @Sendable (String?) throws -> AdoptedQtIdentity?,
                 makeDefaults: @Sendable (String) -> UserDefaults? = { UserDefaults(suiteName: $0) }) {
        if let defaultsSuite {
            self.defaults = makeDefaults(defaultsSuite)
        } else {
            self.defaults = .standard
        }
        self.storageRoot = storageRoot
        self.protectedDataAvailable = protectedDataAvailable
        self.migrateIdentity = migrateIdentity
    }

    // MARK: Public surface

    package func clientCertPEM() throws -> String {
        try load().certPEM
    }

    package func clientKeyPEM() throws -> String {
        try load().keyPEM
    }

    public func uniqueID() throws -> String {
        try load().uniqueID
    }

    /// Both peers use SHA-256(salt || PIN)[0..<16] for the raw AES-128-ECB challenge.
    package nonisolated static func aesKey(forPIN pin: String, salt: Data) -> Data {
        let pinBytes = Data(pin.utf8)
        var input = Data(capacity: salt.count + pinBytes.count)
        input.append(salt)
        input.append(pinBytes)

        // AES-128 - first 16 bytes only. The remaining bytes of the digest are
        // discarded (this matches GFE/Sunshine behaviour, not a quirk on our end).
        return PairingClient.digest(input).prefix(16)
    }

    // MARK: Loading

    // Prefer files, then legacy defaults, then shell-supplied migration, then fresh generation.
    // Never read or delete keychain items. Only successful file writes advance the migration flag.

    /// Versioned flag - once set to `fileStorageVersion`, future launches
    /// load identity directly from the file store and skip all migration
    /// branches. Bump if the on-disk shape ever changes incompatibly.
    package static let fileStorageFlag = "glimmer.identityFileStorageVersion"
    package static let fileStorageVersion = 1

    /// The keychain-era build already wiped its plaintext defaults. Keep its flag unchanged;
    /// no keychain access occurs, and a successful file write supersedes this marker.
    package static let legacyKeychainOnlyFlag = "glimmer.identityKeychainOnly"

    package static let accountCert = "client-cert-pem"
    package static let accountKey  = "client-key-pem"
    package static let accountUID  = "client-unique-id"
}

public enum IdentityStorageError: Error, Sendable {
    case unavailable
    case defaultsUnavailable
    case unsafeStorage
}
