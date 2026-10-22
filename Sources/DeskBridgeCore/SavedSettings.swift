// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 DeskBridge contributors
import Foundation
import Darwin

public struct SavedHost: Codable, Sendable {
    public var address: String
    public var uniqueID: String
    public var name: String
    public var certificatePEM: String
    public var httpPort: Int
    public var httpsPort: Int
    public init(address: String, uniqueID: String, name: String, certificatePEM: String, httpPort: Int, httpsPort: Int) {
        self.address = address; self.uniqueID = uniqueID; self.name = name
        self.certificatePEM = certificatePEM; self.httpPort = httpPort; self.httpsPort = httpsPort
    }
}
public struct SavedSettings: Codable, Sendable {
    public var schema = 1
    public var address = ""
    public var host: SavedHost?
    public var sshUsername = ""
    public var sshPort: UInt16 = 22
    public var sshHostPublicKey = ""
    public var sshIdentityPath = ""
    public init() {}
}
/// No standard preferences, legacy migration, keychain or unrelated application files.
public struct SettingsStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    /// Return a new publishable value only after persistence succeeds.
    public func updating(_ current: SavedSettings, _ change: (inout SavedSettings) throws -> Void) throws -> SavedSettings {
        var next = current
        try change(&next)
        try save(next)
        return next
    }
    public func load() throws -> SavedSettings {
        let url = directory.appendingPathComponent("settings.json")
        do {
            let data = try BoundedRegularFile.read(url, maximumBytes: 128 * 1024)
            let value = try JSONDecoder().decode(SavedSettings.self, from: data)
            guard value.schema == 1 else { throw CocoaError(.fileReadUnknown) }
            return value
        } catch BoundedRegularFile.Failure.missing { return SavedSettings() }
    }
    public func save(_ value: SavedSettings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(value)
        let temporary = directory.appendingPathComponent(".settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard Darwin.rename(temporary.path, directory.appendingPathComponent("settings.json").path) == 0
        else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

