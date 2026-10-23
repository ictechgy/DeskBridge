// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Darwin
import DeskBridgeCore
import Foundation
import Security

/// Blocking signature and file operations run outside MainActor. Cancellation
/// reaches the worker and is checked between bounded reads and before commit.
enum MacHostFileWork {
    static func perform<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try operation()
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func prepareApplication(_ app: URL, username: String, password: String) throws -> URL {
        try validateApplication(app)
        let parent = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        let directory = parent.appendingPathComponent("DeskBridgeMacHost", isDirectory: true)
        try Task.checkCancellation()
        try MacHostStorage.prepare(directory: directory)
        try MacHostStorage.prepareWebCredentials(directory: directory, username: username, password: password)
        try Task.checkCancellation()
        return directory
    }

    static func validateApplication(_ url: URL) throws {
        try Task.checkCancellation()
        let requirement = try applicationRequirement()
        let metadata = try signingMetadata(at: url, requirement: requirement)
        guard metadata.matchesPinnedApplication else {
            try Task.checkCancellation(); throw MacHostPolicy.Failure.untrustedApplication
        }
        try Task.checkCancellation()
    }

    static func applicationRequirement() throws -> SecRequirement {
        var requirement: SecRequirement?
        // Apple's Developer ID issuer and Application leaf extensions (TN3127):
        // https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements
        let expression = "anchor apple generic and identifier \"\(MacHostPolicy.bundleIdentifier)\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(MacHostPolicy.signingTeam)\""
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw MacHostPolicy.Failure.untrustedApplication }
        return requirement
    }

    struct SigningMetadata: Equatable, Sendable {
        let identifier: String
        let bundleIdentifier: String
        let version: String
        let executable: String

        var matchesPinnedApplication: Bool {
            identifier == MacHostPolicy.bundleIdentifier && bundleIdentifier == MacHostPolicy.bundleIdentifier &&
                version == MacHostPolicy.sunshineVersion && executable == "Sunshine"
        }
    }

    /// Always creates a new code object. Foundation caches Bundle metadata by URL,
    /// so it cannot attest a replacement installed at a previously checked path.
    static func signingMetadata(at url: URL, requirement: SecRequirement?) throws -> SigningMetadata {
        try Task.checkCancellation()
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement) == errSecSuccess,
              SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
              let information = information as? [String: Any],
              let identifier = information[kSecCodeInfoIdentifier as String] as? String,
              let propertyList = information[kSecCodeInfoPList as String] as? [String: Any],
              let bundleIdentifier = propertyList["CFBundleIdentifier"] as? String,
              let version = propertyList["CFBundleShortVersionString"] as? String,
              let executable = propertyList["CFBundleExecutable"] as? String
        else { try Task.checkCancellation(); throw MacHostPolicy.Failure.untrustedApplication }
        try Task.checkCancellation()
        return SigningMetadata(identifier: identifier, bundleIdentifier: bundleIdentifier, version: version, executable: executable)
    }

    static func requireAbsent(_ destination: URL) throws {
        guard destination.isFileURL else { throw MacHostPolicy.Failure.download }
        var value = stat()
        if lstat(destination.path, &value) == 0 { throw MacHostPolicy.Failure.collision }
        guard errno == ENOENT else { throw MacHostPolicy.Failure.download }
    }

    static func download(to destination: URL, expectedBytes: Int64, sha256: String,
                         fetch: @escaping @Sendable () async throws -> URL) async throws {
        // Refuse existing files, directories and dangling symlinks before any
        // network request. A Save panel's Replace choice never permits overwrite.
        try await perform { try requireAbsent(destination) }
        try Task.checkCancellation()
        let temporary = try await fetch()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await perform {
            try verifyAndCopy(temporary, to: destination, expectedBytes: expectedBytes, sha256: sha256)
        }
    }

    static func verifyAndCopy(_ temporary: URL, to destination: URL, expectedBytes: Int64, sha256: String) throws {
        try Task.checkCancellation()
        let file = open(temporary.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw MacHostPolicy.Failure.download }
        defer { close(file) }
        var info = stat()
        guard expectedBytes > 0, fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size == expectedBytes else { throw MacHostPolicy.Failure.download }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        var received: Int64 = 0
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { read(file, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, Int64(count) <= expectedBytes - received else { throw MacHostPolicy.Failure.download }
            if count == 0 { break }
            hasher.update(data: Data(buffer.prefix(count)))
            received += Int64(count)
        }
        try Task.checkCancellation()
        guard received == expectedBytes,
              hasher.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw MacHostPolicy.Failure.download
        }
        let quarantine = Data("0081;\(String(Int(Date().timeIntervalSince1970), radix: 16));Knot;".utf8)
        guard quarantine.withUnsafeBytes({ fsetxattr(file, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }) == 0 else {
            throw MacHostPolicy.Failure.download
        }
        try requireAbsent(destination)
        try Task.checkCancellation()
        // This remains exclusive if another file appears after requireAbsent.
        // A successful final system copy is a committed saved file.
        try FileManager.default.copyItem(at: temporary, to: destination)
    }
}
