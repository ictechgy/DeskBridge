// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Darwin
import DeskBridgeCore
import Foundation

@MainActor protocol MacHostOwnedProcess: AnyObject {
    var running: Bool { get }
    var onExit: (@MainActor () -> Void)? { get set }
    func stop()
    func forceStop()
}

/// Only children of this newly created process group are signalled. Keep the
/// original child unreaped until group cleanup, so its numeric ID cannot be
/// reused. Sunshine's web Restart forks; that child must not escape ownership.
@MainActor final class MacHostChild: MacHostOwnedProcess {
    private let pid: pid_t
    private(set) var running = true
    var onExit: (@MainActor () -> Void)?

    init(executable: URL, arguments: [String]) throws {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw MacHostPolicy.Failure.exited }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw MacHostPolicy.Failure.exited }
        defer { posix_spawnattr_destroy(&attributes) }
        var mask = sigset_t(); sigemptyset(&mask)
        guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0
        else { throw MacHostPolicy.Failure.exited }
        // No shell, inherited descriptors or DYLD/Python/Qt injection variables.
        // Preserve the actual user home: upstream always ensures its empty default
        // appdata directory; every file it reads/writes is separately overridden.
        let inherited = ProcessInfo.processInfo.environment
        let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=en_US.UTF-8"] +
            ["HOME", "TMPDIR", "USER", "LOGNAME"].compactMap { key in inherited[key].map { "\(key)=\($0)" } }
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var child: pid_t = 0
        try Task.checkCancellation()
        let result = argv.withUnsafeBufferPointer { av in envp.withUnsafeBufferPointer { ev in
            posix_spawn(&child, executable.path, &actions, &attributes,
                        UnsafeMutablePointer(mutating: av.baseAddress!), UnsafeMutablePointer(mutating: ev.baseAddress!))
        } }
        guard result == 0, child > 0 else { throw MacHostPolicy.Failure.exited }
        pid = child
        let spawnedPID = child
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var info = siginfo_t()
            var result: Int32
            repeat { result = waitid(P_PID, id_t(spawnedPID), &info, WEXITED | WNOWAIT) } while result < 0 && errno == EINTR
            // Original child remains unreaped during group cleanup.
            _ = kill(-spawnedPID, SIGKILL)
            Task { @MainActor [weak self] in
                // Mark unowned before reaping: no queued stop can signal a
                // reused process-group ID after waitpid releases this PID.
                self?.finish()
                DispatchQueue.global(qos: .utility).async {
                    var status: Int32 = 0
                    while waitpid(spawnedPID, &status, 0) < 0 && errno == EINTR {}
                }
            }
        }
    }
    func stop() { if running { _ = kill(-pid, SIGTERM) } }
    func forceStop() { if running { _ = kill(-pid, SIGKILL) } }
    private func finish() {
        guard running else { return }
        running = false
        onExit?()
    }
}

@MainActor enum MacHostRuntime {
    static let installedApp = URL(fileURLWithPath: "/Applications/Sunshine.app", isDirectory: true)
    static func installed() -> Bool { FileManager.default.fileExists(atPath: installedApp.appendingPathComponent("Contents/MacOS/Sunshine").path) }
    static func start(name: String, username: String, password: String) async throws -> any MacHostOwnedProcess {
        guard installed() else { throw MacHostPolicy.Failure.installationRequired }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: MacHostPolicy.bundleIdentifier).isEmpty else {
            throw MacHostPolicy.Failure.existingHost
        }
        // Verify the complete signed code/resource envelope and nested libraries,
        // then pin both upstream identity and exact version. No trust bypass.
        let app = installedApp
        let directory = try await MacHostFileWork.perform { try MacHostFileWork.prepareApplication(app, username: username, password: password) }
        try Task.checkCancellation()
        // Validation yields MainActor; an independently launched Sunshine must
        // still be rejected immediately before creating our owned child.
        guard NSRunningApplication.runningApplications(withBundleIdentifier: MacHostPolicy.bundleIdentifier).isEmpty else {
            throw MacHostPolicy.Failure.existingHost
        }
        try Task.checkCancellation()
        return try MacHostChild(executable: installedApp.appendingPathComponent("Contents/MacOS/Sunshine"),
                                arguments: MacHostPolicy.arguments(directory: directory, name: name))
    }
    static func addresses() -> [MacHostAddress] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var output: [MacHostAddress] = []; var current = list
        while let pointer = current {
            let value = pointer.pointee; current = value.ifa_next
            guard let socket = value.ifa_addr, socket.pointee.sa_family == UInt8(AF_INET),
                  value.ifa_flags & UInt32(IFF_UP) != 0, value.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let interfaceName = value.ifa_name else { continue }
            let interface = String(cString: interfaceName)
            guard interface.hasPrefix("en") || interface.hasPrefix("utun") else { continue }
            var address = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(socket, socklen_t(socket.pointee.sa_len), &address, socklen_t(address.count), nil, 0, NI_NUMERICHOST) == 0,
               let hint = try? MacHostAddress(interface: interface, address: String(decoding: address.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) { output.append(hint) }
        }
        return MacHostAddress.selected(output)
    }
    static func download(to destination: URL) async throws {
        let asset = MacHostPolicy.currentDownload
        try await MacHostFileWork.download(to: destination, expectedBytes: asset.bytes, sha256: asset.sha256) {
            try await MacHostDownload.fetch(from: asset.url, expectedBytes: asset.bytes)
        }
    }
}
