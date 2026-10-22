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
    public static let maximumBytes = 128 * 1024
    public enum Failure: LocalizedError {
        case tooLarge
        public var errorDescription: String? {
            "설정 정보가 너무 커서 저장하지 않았습니다. 기존 연결 정보는 유지됩니다. PC 이름과 입력한 설정을 확인하세요."
        }
    }
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
            let data = try BoundedRegularFile.read(url, maximumBytes: Self.maximumBytes)
            let value = try JSONDecoder().decode(SavedSettings.self, from: data)
            guard value.schema == 1 else { throw CocoaError(.fileReadUnknown) }
            return value
        } catch BoundedRegularFile.Failure.missing { return SavedSettings() }
    }
    public func save(_ value: SavedSettings) throws {
        // Every successful write must remain readable on the next launch.
        // Validate before touching the directory or replacing trusted settings.
        let data = try JSONEncoder().encode(value)
        guard data.count <= Self.maximumBytes else { throw Failure.tooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
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

