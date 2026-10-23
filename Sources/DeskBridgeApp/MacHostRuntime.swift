// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Darwin
import DeskBridgeCore
import Foundation
import Security

@MainActor protocol MacHostOwnedProcess: AnyObject {
    var running: Bool { get }
    var onExit: (@MainActor () -> Void)? { get set }
    func stop()
    func forceStop()
}

/// The native supervisor is this process group's leader. Its exclusive lifetime
/// pipe survives worker threads, but not app death or an exec. The supervisor
/// kills the whole group on EOF or host exit; this app also keeps the supervisor
/// unreaped until final group cleanup, so a crash cannot expose a reused PGID.
/// The helper permits only an exec into the pinned host under a fixed no-fork
/// restriction; upstream web restart and commands that spawn apps are unavailable.
@MainActor final class MacHostChild: MacHostOwnedProcess {
    private let pid: pid_t
    private var lifetimeWriter: Int32
    private(set) var running = true
    var onExit: (@MainActor () -> Void)?

    init(executable: URL, arguments: [String], supervisor: URL = MacHostRuntime.supervisorExecutable) throws {
        let strings = [executable.path] + arguments
        guard executable.isFileURL, executable.path.hasPrefix("/"), supervisor.isFileURL,
              supervisor.path.hasPrefix("/"), arguments.count <= 256,
              strings.allSatisfy({ !$0.utf8.contains(0) && $0.utf8.count <= 16_384 }),
              strings.reduce(0, { $0 + $1.utf8.count + 1 }) <= 131_072 else {
            throw MacHostPolicy.Failure.helperUnavailable
        }
        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else { throw MacHostPolicy.Failure.helperUnavailable }
        let writer = pipeFDs[1]
        guard fcntl(writer, F_SETFD, FD_CLOEXEC) == 0 else {
            _ = close(pipeFDs[0]); _ = close(writer)
            throw MacHostPolicy.Failure.helperUnavailable
        }
        // Use a distinct source for dup2 onto the helper's fixed fd 3. Neither
        // original pipe end can leak through an unrelated concurrent exec.
        let reader = fcntl(pipeFDs[0], F_DUPFD_CLOEXEC, 10)
        _ = close(pipeFDs[0])
        var transferred = false
        defer { if reader >= 0 { _ = close(reader) }; if !transferred { _ = close(writer) } }
        guard reader >= 0 else { throw MacHostPolicy.Failure.helperUnavailable }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw MacHostPolicy.Failure.helperUnavailable }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw MacHostPolicy.Failure.helperUnavailable }
        defer { posix_spawnattr_destroy(&attributes) }
        var mask = sigset_t(); sigemptyset(&mask)
        guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, reader, 3) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0
        else { throw MacHostPolicy.Failure.helperUnavailable }
        // No shell, inherited descriptors or DYLD/Python/Qt injection variables.
        // Preserve the actual user home: upstream always ensures its empty default
        // appdata directory; every file it reads/writes is separately overridden.
        let inherited = ProcessInfo.processInfo.environment
        let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=en_US.UTF-8"] +
            ["HOME", "TMPDIR", "USER", "LOGNAME"].compactMap { key in inherited[key].map { "\(key)=\($0)" } }
        let argv = ([supervisor.path, "--", executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var child: pid_t = 0
        try Task.checkCancellation()
        let result = argv.withUnsafeBufferPointer { av in envp.withUnsafeBufferPointer { ev in
            posix_spawn(&child, supervisor.path, &actions, &attributes,
                        UnsafeMutablePointer(mutating: av.baseAddress!), UnsafeMutablePointer(mutating: ev.baseAddress!))
        } }
        guard result == 0, child > 0 else { throw MacHostPolicy.Failure.helperUnavailable }
        pid = child
        lifetimeWriter = writer
        transferred = true
        let spawnedPID = child
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var info = siginfo_t()
            var result: Int32
            repeat { result = waitid(P_PID, id_t(spawnedPID), &info, WEXITED | WNOWAIT) } while result < 0 && errno == EINTR
            // Only signal after waitid proves this exact child is still held
            // unreaped. Even an early supervisor crash cannot reuse its PGID.
            let owned = result == 0 && info.si_pid == spawnedPID
            if owned { _ = kill(-spawnedPID, SIGKILL) }
            Task { @MainActor [weak self] in
                // Mark unowned before reaping: no queued stop can signal a
                // reused process-group ID after waitpid releases this PID.
                self?.finish()
                if owned { DispatchQueue.global(qos: .utility).async {
                    var status: Int32 = 0
                    while waitpid(spawnedPID, &status, 0) < 0 && errno == EINTR {}
                } }
            }
        }
    }
    deinit { if lifetimeWriter >= 0 { _ = close(lifetimeWriter) } }
    func stop() { if running { _ = kill(-pid, SIGTERM) } }
    func forceStop() { if running { closeLifetime(); _ = kill(-pid, SIGKILL) } }
    private func closeLifetime() {
        if lifetimeWriter >= 0 { _ = close(lifetimeWriter); lifetimeWriter = -1 }
    }
    private func finish() {
        guard running else { return }
        running = false
        closeLifetime()
        onExit?()
    }
}

@MainActor enum MacHostRuntime {
    static var supervisorExecutable: URL {
        // Derive from the running executable, never PATH, cwd, or user settings.
        Bundle.main.executableURL!.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Helpers/KnotHostSupervisor", isDirectory: false)
    }
    private nonisolated static func validateSupervisor(app: URL, helper: URL) throws {
        try Task.checkCancellation()
        // The fixed system wrapper is part of the containment boundary. Do not
        // search PATH, select an alternative launcher, or run without it.
        let wrapper = "/usr/bin/sandbox-exec"
        var wrapperAttributes = stat()
        guard lstat(wrapper, &wrapperAttributes) == 0,
              wrapperAttributes.st_mode & S_IFMT == S_IFREG,
              wrapperAttributes.st_uid == 0, wrapperAttributes.st_mode & 0o022 == 0,
              FileManager.default.isExecutableFile(atPath: wrapper) else {
            throw MacHostPolicy.Failure.helperUnavailable
        }
        for path in [helper.deletingLastPathComponent(), helper] {
            var attributes = stat()
            guard lstat(path.path, &attributes) == 0,
                  attributes.st_mode & S_IFMT == (path == helper ? S_IFREG : S_IFDIR) else {
                throw MacHostPolicy.Failure.helperUnavailable
            }
        }
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw MacHostPolicy.Failure.helperUnavailable }
        // The outer signature pins the nested helper's exact code identity;
        // checking only a separately valid ad-hoc signature would permit swaps.
        for url in [app, helper] {
            try Task.checkCancellation()
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
                  let code, SecStaticCodeCheckValidity(code,
                    SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures), nil) == errSecSuccess else {
                throw MacHostPolicy.Failure.helperUnavailable
            }
        }
    }
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
        let helper = supervisorExecutable
        let ownBundle = Bundle.main.bundleURL
        let directory = try await MacHostFileWork.perform {
            try validateSupervisor(app: ownBundle, helper: helper)
            return try MacHostFileWork.prepareApplication(app, username: username, password: password)
        }
        try Task.checkCancellation()
        // Validation yields MainActor; an independently launched Sunshine must
        // still be rejected immediately before creating our owned child.
        guard NSRunningApplication.runningApplications(withBundleIdentifier: MacHostPolicy.bundleIdentifier).isEmpty else {
            throw MacHostPolicy.Failure.existingHost
        }
        try Task.checkCancellation()
        return try MacHostChild(executable: installedApp.appendingPathComponent("Contents/MacOS/Sunshine"),
                                arguments: MacHostPolicy.arguments(directory: directory, name: name), supervisor: helper)
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
