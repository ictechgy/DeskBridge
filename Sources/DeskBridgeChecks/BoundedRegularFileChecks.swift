// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import DeskBridgeCore
import Foundation

/// A delayed writer rescues a regressed blocking FIFO open so a failed check cannot hang the suite.
func armSyntheticFIFORescue(_ url: URL) -> DispatchGroup {
    let rescue = DispatchGroup(); rescue.enter()
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(400)) {
        let descriptor = Darwin.open(url.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        if descriptor >= 0 { Darwin.close(descriptor) }
        rescue.leave()
    }
    return rescue
}

func runBoundedRegularFileChecks() throws -> Int {
    var count = 0
    func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CheckFailure(message: message) }; count += 1
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("deskbridge-bounded-file-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let regular = directory.appendingPathComponent("regular"), empty = directory.appendingPathComponent("empty")
    let bytes = Data("12345678".utf8); try bytes.write(to: regular); try Data().write(to: empty)
    try expect(try BoundedRegularFile.read(regular, maximumBytes: 8) == bytes, "bounded reader lost exact-limit regular data")
    try expect(try BoundedRegularFile.read(empty, maximumBytes: 8).isEmpty, "bounded reader changed empty-file semantics")
    var tooLarge = false
    do { _ = try BoundedRegularFile.read(regular, maximumBytes: 7) } catch BoundedRegularFile.Failure.tooLarge { tooLarge = true }
    try expect(tooLarge, "bounded reader accepted an oversized regular file")
    let link = directory.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
    for url in [directory, link, URL(string: "https://synthetic.invalid/file")!] {
        var refused = false
        do { _ = try BoundedRegularFile.read(url, maximumBytes: 8) } catch is BoundedRegularFile.Failure { refused = true }
        try expect(refused, "bounded reader accepted directory, symlink or non-file URL")
    }
    let fifo = directory.appendingPathComponent("fifo")
    guard mkfifo(fifo.path, 0o600) == 0 else { throw CheckFailure(message: "cannot create synthetic FIFO") }
    let rescue = armSyntheticFIFORescue(fifo), start = ProcessInfo.processInfo.systemUptime
    defer { rescue.wait() }
    var refused = false
    do { _ = try BoundedRegularFile.read(fifo, maximumBytes: 8) } catch BoundedRegularFile.Failure.invalidFile { refused = true }
    try expect(refused && ProcessInfo.processInfo.systemUptime - start < 0.25, "FIFO selection blocked before regular-file validation")
    let missing = directory.appendingPathComponent("missing-settings")
    try expect(try SettingsStore(directory: missing).load().host == nil, "only missing settings should initialize fresh state")
    for kind in ["oversized", "symlink", "fifo", "not-directory"] {
        let settingsDirectory = directory.appendingPathComponent("settings-" + kind)
        if kind == "not-directory" { try Data([1]).write(to: settingsDirectory) }
        else { try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true,
                                                      attributes: [.posixPermissions: 0o700]) }
        let settingsURL = settingsDirectory.appendingPathComponent("settings.json")
        var settingsRescue: DispatchGroup?
        if kind == "oversized" {
            try Data(repeating: 32, count: 128 * 1024 + 1).write(to: settingsURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
        }
        if kind == "symlink" { try FileManager.default.createSymbolicLink(at: settingsURL, withDestinationURL: regular) }
        if kind == "fifo" {
            guard mkfifo(settingsURL.path, 0o600) == 0 else { throw CheckFailure(message: "cannot create synthetic settings FIFO") }
            settingsRescue = armSyntheticFIFORescue(settingsURL)
        }
        let settingsStart = ProcessInfo.processInfo.systemUptime
        var settingsRefused = false
        do { _ = try SettingsStore(directory: settingsDirectory).load() }
        catch BoundedRegularFile.Failure.tooLarge { settingsRefused = kind == "oversized" }
        catch BoundedRegularFile.Failure.unreadable { settingsRefused = ["symlink", "not-directory"].contains(kind) }
        catch BoundedRegularFile.Failure.invalidFile { settingsRefused = kind == "fifo" }
        catch is CorePrivateStorageFailure { settingsRefused = true }
        let elapsed = ProcessInfo.processInfo.systemUptime - settingsStart
        settingsRescue?.wait()
        try expect(settingsRefused, "invalid existing settings were treated as fresh trust state")
        if kind == "fifo" { try expect(elapsed < 0.25, "settings FIFO blocked before validation") }
    }
    return count
}
