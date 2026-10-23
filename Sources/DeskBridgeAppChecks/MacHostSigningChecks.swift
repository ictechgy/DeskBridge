// SPDX-License-Identifier: GPL-3.0-only
import DeskBridgeCore
import Foundation

/// Uses only a newly compiled, never executed fixture and ad-hoc signatures.
/// No installed application, signing identity, Keychain or user state is read.
func runMacHostSigningChecks(temporary: URL) throws -> Int {
    var count = 0
    func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw ModelCheckFailure(message: message) }; count += 1
    }
    func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ModelCheckFailure(message: "synthetic signing fixture tool failed: \(executable)")
        }
    }
    let fixture = temporary.appendingPathComponent("signing-" + UUID().uuidString, isDirectory: true)
    let app = fixture.appendingPathComponent("Synthetic.app", isDirectory: true)
    let contents = app.appendingPathComponent("Contents", isDirectory: true)
    let binaries = contents.appendingPathComponent("MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
    let source = fixture.appendingPathComponent("inert.c")
    try Data("int main(void) { return 0; }\n".utf8).write(to: source)
    let executable = binaries.appendingPathComponent("Sunshine")
    try run("/usr/bin/clang", [source.path, "-o", executable.path])
    func sign(version: String, bundleIdentifier: String = MacHostPolicy.bundleIdentifier,
              identifier: String = MacHostPolicy.bundleIdentifier, executable: String = "Sunshine") throws {
        let propertyList = ["CFBundleIdentifier": bundleIdentifier, "CFBundleExecutable": executable,
                            "CFBundlePackageType": "APPL", "CFBundleVersion": version,
                            "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: propertyList, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
        try run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", identifier, app.path])
    }
    try sign(version: "1.0")
    // Seed the same-process Foundation cache that caused the original defect.
    let cachedBundle = Bundle(url: app)
    try expect(cachedBundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "1.0",
               "synthetic bundle cache was not primed")
    let first = try MacHostFileWork.signingMetadata(at: app, requirement: nil)
    try expect(first.version == "1.0", "initial secured signing metadata differs")
    try sign(version: "2.0")
    let replacement = try MacHostFileWork.signingMetadata(at: app, requirement: nil)
    try expect(replacement.version == "2.0" && first.version == "1.0",
               "fresh signing metadata retained a previous same-path version")
    try expect(!replacement.matchesPinnedApplication, "non-pinned signed version accepted")

    try sign(version: MacHostPolicy.sunshineVersion)
    let pinned = try MacHostFileWork.signingMetadata(at: app, requirement: nil)
    try expect(pinned.matchesPinnedApplication, "exact pinned metadata was not recognized")
    // This calls the actual production requirement parser and trust check. Exact
    // metadata alone must never authorize this ad-hoc signed synthetic bundle.
    // A parser failure must fail the check, rather than count as a trust rejection.
    _ = try MacHostFileWork.applicationRequirement()
    var refused = false
    do { try MacHostFileWork.validateApplication(app) }
    catch MacHostPolicy.Failure.untrustedApplication { refused = true }
    try expect(refused, "production requirement accepted an ad-hoc signed fixture")

    try sign(version: MacHostPolicy.sunshineVersion, identifier: "synthetic.wrong.signing-identifier")
    let wrongIdentifier = try MacHostFileWork.signingMetadata(at: app, requirement: nil)
    try expect(wrongIdentifier.bundleIdentifier == MacHostPolicy.bundleIdentifier &&
               !wrongIdentifier.matchesPinnedApplication, "signing identifier was not pinned")
    try sign(version: MacHostPolicy.sunshineVersion, bundleIdentifier: "synthetic.wrong.bundle-identifier")
    let wrongBundle = try MacHostFileWork.signingMetadata(at: app, requirement: nil)
    try expect(wrongBundle.identifier == MacHostPolicy.bundleIdentifier && !wrongBundle.matchesPinnedApplication,
               "secured bundle identifier was not pinned")
    let otherExecutable = binaries.appendingPathComponent("OtherSynthetic")
    try FileManager.default.moveItem(at: executable, to: otherExecutable)
    try sign(version: MacHostPolicy.sunshineVersion, executable: otherExecutable.lastPathComponent)
    let wrongExecutable = try MacHostFileWork.signingMetadata(at: app, requirement: nil)
    try expect(!wrongExecutable.matchesPinnedApplication, "secured executable name was not pinned")

    // Metadata may be copied out only after the same code object validates its seal.
    try Data("unsigned replacement".utf8).write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
    refused = false
    do { _ = try MacHostFileWork.signingMetadata(at: app, requirement: nil) }
    catch MacHostPolicy.Failure.untrustedApplication { refused = true }
    try expect(refused, "unvalidated replacement Info.plist returned trusted metadata")
    return count
}
