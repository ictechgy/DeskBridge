// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 DeskBridge contributors
import Darwin
import Foundation

public enum CorePrivateStorageFailure: LocalizedError, Sendable {
    case unsafeStorage
    public var errorDescription: String? {
        "앱의 저장 폴더나 파일을 안전하게 사용할 수 없습니다. 소유자, 접근 권한과 공유 설정을 확인한 뒤 다시 시도하세요."
    }
}

/// Only the app-owned base and its descendants must be private. Its existing
/// Application Support parent is never tightened or adopted as private storage.
enum CorePrivateStorage {
    static let unsafe = CorePrivateStorageFailure.unsafeStorage
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
