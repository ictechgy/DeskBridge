// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import DeskBridgeCore
import Foundation
import Security

/// No existing Sunshine preference/key paths are read or adopted. This separate
/// per-user directory is checked by descriptor; symlinks/hard links and access by
/// another user fail closed. Tests use newly created synthetic directories only.
enum MacHostStorage {
    static func prepareWebCredentials(directory: URL, username: String, password: String) throws {
        let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw MacHostPolicy.Failure.privateStorage }
        defer { close(root) }
        try checkDirectory(root)
        var existing = stat()
        if fstatat(root, "web-credentials.json", &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            try checkFile(root, "web-credentials.json")
            let fd = openat(root, "web-credentials.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { throw MacHostPolicy.Failure.privateStorage }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? file.close() }
            var value = stat()
            guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_uid == geteuid(), value.st_nlink == 1,
                  value.st_mode & 0o077 == 0, value.st_size <= 8192 else { throw MacHostPolicy.Failure.privateStorage }
            try SunshineWebCredentials.validate(try file.read(upToCount: 8193) ?? Data())
            return
        }
        guard errno == ENOENT else { throw MacHostPolicy.Failure.privateStorage }
        var random = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw MacHostPolicy.Failure.privateStorage }
        let salt = random.map { String(format: "%02X", $0) }.joined()
        let bytes = try SunshineWebCredentials.encode(username: username, password: password, salt: salt)
        let temporary = ".web-credentials-" + UUID().uuidString
        let fd = openat(root, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MacHostPolicy.Failure.privateStorage }
        defer { close(fd); _ = unlinkat(root, temporary, 0) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try file.write(contentsOf: bytes); try file.synchronize()
        guard renameatx_np(root, temporary, root, "web-credentials.json", UInt32(RENAME_EXCL)) == 0 else { throw MacHostPolicy.Failure.privateStorage }
    }
    static func prepare(directory: URL) throws {
        guard directory.isFileURL else { throw MacHostPolicy.Failure.privateStorage }
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw MacHostPolicy.Failure.privateStorage }
        let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw MacHostPolicy.Failure.privateStorage }
        defer { close(root) }
        try checkDirectory(root)
        if mkdirat(root, "credentials", 0o700) != 0 && errno != EEXIST { throw MacHostPolicy.Failure.privateStorage }
        let credentials = openat(root, "credentials", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard credentials >= 0 else { throw MacHostPolicy.Failure.privateStorage }
        defer { close(credentials) }
        try checkDirectory(credentials)
        for name in ["sunshine.conf", "apps.json", "state.json", "web-credentials.json"] { try checkFile(root, name) }
        for name in ["cakey.pem", "cacert.pem"] { try checkFile(credentials, name) }
        try replace(root, name: "sunshine.conf", bytes: Data("# DeskBridge owns this configuration. Security policy is enforced by command-line overrides.\n".utf8))
        try replace(root, name: "apps.json", bytes: MacHostPolicy.desktopApplications)
    }
    private static func checkDirectory(_ descriptor: Int32) throws {
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_uid == geteuid(),
              value.st_mode & S_IFMT == S_IFDIR, value.st_mode & 0o077 == 0 else { throw MacHostPolicy.Failure.privateStorage }
        try checkACL(descriptor)
    }
    private static func checkFile(_ directory: Int32, _ name: String) throws {
        var value = stat()
        if fstatat(directory, name, &value, AT_SYMLINK_NOFOLLOW) < 0 {
            guard errno == ENOENT else { throw MacHostPolicy.Failure.privateStorage }; return
        }
        guard value.st_uid == geteuid(), value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1,
              value.st_mode & 0o022 == 0 else { throw MacHostPolicy.Failure.privateStorage }
        // Upstream may create a 0644 file under our 0700 directory. It remains
        // inaccessible to other users; tighten it by verified descriptor on the
        // next explicit start, without changing the app-wide process umask.
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw MacHostPolicy.Failure.privateStorage }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_dev == value.st_dev, opened.st_ino == value.st_ino,
              opened.st_uid == geteuid(), opened.st_nlink == 1, opened.st_mode & S_IFMT == S_IFREG,
              fchmod(descriptor, 0o600) == 0 else { throw MacHostPolicy.Failure.privateStorage }
        try checkACL(descriptor)
    }
    private static func checkACL(_ descriptor: Int32) throws {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            // Darwin reports ENOENT when an existing descriptor has no ACL.
            guard errno == ENOENT else { throw MacHostPolicy.Failure.privateStorage }; return
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        // POSIX mode alone does not constrain inherited macOS ACL grants.
        guard acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) != 0 else { throw MacHostPolicy.Failure.privateStorage }
    }
    private static func replace(_ directory: Int32, name: String, bytes: Data) throws {
        let temporary = ".deskbridge-" + UUID().uuidString
        let descriptor = openat(directory, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw MacHostPolicy.Failure.privateStorage }
        defer { close(descriptor); _ = unlinkat(directory, temporary, 0) }
        let wrote = bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let result = write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { return false }; offset += result
            }
            return fsync(descriptor) == 0
        }
        guard wrote, renameat(directory, temporary, directory, name) == 0 else { throw MacHostPolicy.Failure.privateStorage }
    }
}
