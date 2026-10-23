#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Exercise production private storage using only fresh synthetic /private/tmp files.

The vendor package-private implementation and loader are source-extracted, with
in-memory defaults/crypto stand-ins. No UserDefaults, Keychain, GUI, network, or
existing credentials are accessed. A keygen wrapper records invocation, and only
runs the real tool after all unsafe-path tests have proved the gate stays closed.
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
if sys.platform != "darwin":
    raise SystemExit("private-storage checks require Darwin extended ACLs")

HARNESS = r'''
import Foundation
import Darwin

final class FixtureDefaults {
    var values: [String: Any] = [:]
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func string(forKey key: String) -> String? { values[key] as? String }
    func set(_ value: Any, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func synchronize() {}
}
struct FixtureLog { func info(_ message: String) {}; func error(_ message: String) {} }
enum PEM {
    static func identity(certPEM: String, keyPEM: String) throws {
        guard certPEM == "CERT", keyPEM == "KEY" else { throw IdentityStorageError.unsafeStorage }
    }
}
final class IdentityManager {
    static let accountCert = "client-cert-pem", accountKey = "client-key-pem", accountUID = "client-unique-id"
    static let fileStorageFlag = "version", fileStorageVersion = 1, legacyKeychainOnlyFlag = "legacy"
    struct Identity { let uniqueID: String; let certPEM: String; let keyPEM: String }
    let defaults: FixtureDefaults? = FixtureDefaults()
    let protectedDataAvailable = { true }
    let storageRoot: () throws -> URL
    let migrateIdentity: (String?) throws -> AdoptedQtIdentity? = { _ in nil }
    var cached: Identity?
    let log = FixtureLog()
    var generations = 0
    init(_ root: URL) { storageRoot = { root } }
    func generateUniqueID() throws -> String { "0123456789abcdef0123456789abcdef" }
    func generateKeyPairAndCert() throws -> (String, String) { generations += 1; return ("CERT", "KEY") }
}
enum IdentityStorageError: Error { case unavailable, defaultsUnavailable, unsafeStorage }

let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let marker = fixture.appendingPathComponent("keygen-invoked")
var checks = 0
func expect(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
    guard try value() else { fatalError("private storage check failed: \(label)") }; checks += 1
}
func refused(_ label: String, _ body: () throws -> Void) throws {
    do { try body() } catch CorePrivateStorageFailure.unsafeStorage { checks += 1; return }
    catch IdentityStorageError.unsafeStorage { checks += 1; return }
    catch { fatalError("unexpected failure for \(label): \(type(of: error))") }
    fatalError("unsafe storage accepted: \(label)")
}
func fresh(_ name: String) throws -> URL {
    let url = fixture.appendingPathComponent(name, isDirectory: true)
    guard mkdir(url.path, 0o700) == 0 else { fatalError("cannot create fixture") }; return url
}
func writeFixture(_ data: Data, _ url: URL, mode: mode_t = 0o600) throws {
    try data.write(to: url); guard chmod(url.path, mode) == 0 else { fatalError("fixture chmod") }
}
func acl(_ url: URL, _ grant: String) throws {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/chmod")
    p.arguments = ["+a", "everyone allow " + grant, url.path]
    try p.run(); p.waitUntilExit(); guard p.terminationStatus == 0 else { fatalError("fixture ACL") }
}
func identityRoot(_ base: URL) throws -> URL {
    let glimmer = base.appendingPathComponent("Glimmer", isDirectory: true)
    let identity = glimmer.appendingPathComponent("Identity", isDirectory: true)
    guard mkdir(glimmer.path, 0o700) == 0, mkdir(identity.path, 0o700) == 0 else { fatalError("fixture dirs") }
    return identity
}
func unchanged(_ url: URL, _ bytes: Data, _ label: String) throws {
    try expect(Data(contentsOf: url) == bytes, label)
}
func noKeygen(_ label: String) throws {
    try expect(!FileManager.default.fileExists(atPath: marker.path), label)
}

// Lock in Darwin's empty-ACL contract; Linux's zero result has different semantics.
guard let emptyACL = acl_init(0) else { fatalError("empty ACL fixture") }
try expect(acl_valid(emptyACL) == 0, "empty Darwin ACL valid")
var emptyEntry: acl_entry_t?
errno = 0
let emptyResult = acl_get_entry(emptyACL, Int32(ACL_FIRST_ENTRY.rawValue), &emptyEntry)
try expect(emptyResult == -1 && errno == EINVAL, "empty Darwin ACL entry semantics")
acl_free(UnsafeMutableRawPointer(emptyACL))

// Genuine absence is the only new-storage path.
let absent = fixture.appendingPathComponent("absent")
try expect(try FileIdentityStore.read(account: IdentityManager.accountKey, base: absent) == nil, "absent identity")
try expect(try SettingsStore(directory: absent).load().address == "", "absent settings")
try expect(!FileManager.default.fileExists(atPath: absent.path), "missing reads do not create storage")
let good = try fresh("ordinary")
try FileIdentityStore.write(Data("CERT".utf8), account: IdentityManager.accountCert, base: good)
try FileIdentityStore.write(Data("KEY".utf8), account: IdentityManager.accountKey, base: good)
try FileIdentityStore.write(Data("UID".utf8), account: IdentityManager.accountUID, base: good)
try expect(try FileIdentityStore.read(account: IdentityManager.accountKey, base: good) == Data("KEY".utf8), "identity round trip")
var settings = SavedSettings(); settings.address = "fixture.invalid"
try SettingsStore(directory: good).save(settings)
try expect(try SettingsStore(directory: good).load().address == settings.address, "settings round trip")
let loaded = IdentityManager(good); try expect(try loaded.load().uniqueID == "UID", "existing identity used without flag")
try expect(loaded.generations == 0, "existing identity not regenerated")
let interrupted = IdentityManager(good)
interrupted.defaults!.set("LEGACY-CERT", forKey: IdentityKey.certificate)
interrupted.defaults!.set("LEGACY-KEY", forKey: IdentityKey.privateKey)
interrupted.defaults!.set("LEGACY-UID", forKey: IdentityKey.uniqueID)
try expect(try interrupted.load().uniqueID == "UID", "interrupted migration replaced complete file identity")
try expect(interrupted.generations == 0, "interrupted migration regenerated keys")
try expect(interrupted.defaults!.string(forKey: IdentityKey.certificate) == nil &&
           interrupted.defaults!.string(forKey: IdentityKey.privateKey) == nil &&
           interrupted.defaults!.string(forKey: IdentityKey.uniqueID) == nil,
           "complete file identity retained legacy plaintext defaults")
try expect(interrupted.defaults!.integer(forKey: IdentityManager.fileStorageFlag) == IdentityManager.fileStorageVersion,
           "interrupted migration did not finish storage flag")

// Parent inheritance and every app-owned directory ACL fail before secret bytes/keygen.
for (index, grant) in ["read", "search", "read,file_inherit", "read,search,directory_inherit", "read,search,file_inherit,directory_inherit"].enumerated() {
    let base = try fresh("base-acl-\(index)")
    let original = Data("synthetic-original".utf8)
    let settingsFile = base.appendingPathComponent("settings.json")
    try writeFixture(original, settingsFile)
    try acl(base, grant)
    try refused("base ACL identity read") { _ = try FileIdentityStore.read(account: IdentityManager.accountKey, base: base) }
    try refused("base ACL identity write") { try FileIdentityStore.write(Data("secret".utf8), account: IdentityManager.accountKey, base: base) }
    try refused("base ACL settings read") { _ = try SettingsStore(directory: base).load() }
    try refused("base ACL settings write") { try SettingsStore(directory: base).save(settings) }
    try refused("base ACL SSH gate") { _ = try SSHKeyManager.generate(in: base) }
    try unchanged(settingsFile, original, "base ACL preserves bytes")
    try expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("Glimmer").path), "no identity secret tree on ACL base")
    try expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("SSH").path), "no SSH tree on ACL base")
    try noKeygen("no keygen on base ACL")
}
let inherited = try fresh("inheriting-parent")
try acl(inherited, "read,search,file_inherit,directory_inherit")
let inheritedBase = inherited.appendingPathComponent("app")
try refused("new app inherits ACL before settings bytes") { try SettingsStore(directory: inheritedBase).save(settings) }
try expect(!FileManager.default.fileExists(atPath: inheritedBase.appendingPathComponent("settings.json").path), "no inherited-ACL settings bytes")
let inheritedSSH = inherited.appendingPathComponent("ssh-app")
try refused("new app inherits ACL before keygen") { _ = try SSHKeyManager.generate(in: inheritedSSH) }
try noKeygen("no keygen on inherited ACL")
for name in ["Glimmer", "Identity", "SSH"] {
    let base = try fresh("child-acl-" + name)
    let child: URL
    if name == "Identity" { child = try identityRoot(base) }
    else { child = base.appendingPathComponent(name); guard mkdir(child.path, 0o700) == 0 else { fatalError("child") } }
    try acl(child, "read,search,file_inherit,directory_inherit")
    if name == "SSH" {
        try refused("SSH child ACL gate") { _ = try SSHKeyManager.generate(in: base) }
        try expect(try FileManager.default.contentsOfDirectory(atPath: child.path).isEmpty, "no SSH secret child on ACL")
    } else {
        try refused("identity child ACL read") { _ = try FileIdentityStore.read(account: IdentityManager.accountKey, base: base) }
        try refused("identity child ACL write") { try FileIdentityStore.write(Data("secret".utf8), account: IdentityManager.accountKey, base: base) }
    }
    try noKeygen("no keygen on child ACL")
}

// Validate the temporary descriptor before writing, even if inheritance appears
// after the parent descriptor was opened. The rejected fresh temp is removed.
let lateACL = try fresh("late-inheritance")
let lateFD = try CorePrivateStorage.directory(lateACL, create: false)!
try acl(lateACL, "read,file_inherit,only_inherit")
try refused("inherited temporary ACL") { try CorePrivateStorage.replace(lateFD, name: "secret", data: Data("secret".utf8), maximumBytes: 4096) }
close(lateFD)
try expect(try FileManager.default.contentsOfDirectory(atPath: lateACL.path).isEmpty, "no secret or temp survives inherited ACL")

let vendorLateACL = try fresh("vendor-late-inheritance")
let vendorLateFD = try IdentityPrivateStorage.directory(vendorLateACL, create: false)!
try acl(vendorLateACL, "read,file_inherit,only_inherit")
try refused("vendor inherited temporary ACL") { try IdentityPrivateStorage.replace(vendorLateFD, name: "secret", data: Data("secret".utf8), maximumBytes: 4096) }
close(vendorLateFD)
try expect(try FileManager.default.contentsOfDirectory(atPath: vendorLateACL.path).isEmpty, "no vendor secret or temp survives inherited ACL")

// Existing unsafe files are never chmodded, unlinked, overwritten, or treated as missing.
for kind in ["symlink", "fifo", "oversize", "mode", "hardlink", "acl"] {
    let base = try fresh("file-" + kind), identity = try identityRoot(base)
    let key = identity.appendingPathComponent("client-key.pem"), target = base.appendingPathComponent("target")
    let original = Data(repeating: 75, count: kind == "oversize" ? 64 * 1024 + 1 : 16)
    if kind == "symlink" { try writeFixture(original, target); guard symlink(target.path, key.path) == 0 else { fatalError("symlink") } }
    else if kind == "fifo" { guard mkfifo(key.path, 0o600) == 0 else { fatalError("fifo") } }
    else { try writeFixture(original, key, mode: kind == "mode" ? 0o644 : 0o600) }
    if kind == "hardlink" { guard link(key.path, target.path) == 0 else { fatalError("hardlink") } }
    if kind == "acl" { try acl(key, "read") }
    try refused("unsafe identity read \(kind)") { _ = try FileIdentityStore.read(account: IdentityManager.accountKey, base: base) }
    try refused("unsafe identity replacement \(kind)") { try FileIdentityStore.write(Data("replacement".utf8), account: IdentityManager.accountKey, base: base) }
    for version in [0, 1] {
        let manager = IdentityManager(base); manager.defaults!.set(version, forKey: IdentityManager.fileStorageFlag)
        try refused("unsafe identity loader \(kind), flag \(version)") { _ = try manager.load() }
        try expect(manager.generations == 0, "unsafe never regenerates")
    }
    if kind != "fifo" { try unchanged(key, original, "unsafe identity preserved \(kind)") }
    var info = stat(); guard lstat(key.path, &info) == 0 else { fatalError("unsafe file removed") }
    if kind == "mode" { try expect(info.st_mode & 0o777 == 0o644, "unsafe mode not tightened") }
    if kind == "hardlink" { try expect(info.st_nlink == 2, "unsafe links preserved") }

    let store = SettingsStore(directory: base), file = base.appendingPathComponent("settings.json")
    if kind == "symlink" { guard symlink(target.path, file.path) == 0 else { fatalError("settings symlink") } }
    else if kind == "fifo" { guard mkfifo(file.path, 0o600) == 0 else { fatalError("settings fifo") } }
    else { try writeFixture(Data(repeating: 83, count: kind == "oversize" ? SettingsStore.maximumBytes + 1 : 16), file, mode: kind == "mode" ? 0o644 : 0o600) }
    if kind == "hardlink" { guard link(file.path, base.appendingPathComponent("settings-alias").path) == 0 else { fatalError("settings hardlink") } }
    if kind == "acl" { try acl(file, "read") }
    let prior = kind == "fifo" ? Data() : try Data(contentsOf: file)
    try refused("unsafe settings read \(kind)") { _ = try store.load() }
    try refused("unsafe settings replacement \(kind)") { try store.save(settings) }
    if kind != "fifo" { try unchanged(file, prior, "unsafe settings preserved \(kind)") }
}
// Directory symlinks and permissive app roots cannot be adopted/tightened.
let linkTarget = try fresh("base-link-target"), linkBase = fixture.appendingPathComponent("base-link")
guard symlink(linkTarget.path, linkBase.path) == 0 else { fatalError("base symlink") }
for base in [linkBase, try fresh("base-mode")] {
    if base != linkBase { guard chmod(base.path, 0o755) == 0 else { fatalError("base mode") } }
    try refused("unsafe app base settings") { try SettingsStore(directory: base).save(settings) }
    try refused("unsafe app base identity") { try FileIdentityStore.write(Data("secret".utf8), account: IdentityManager.accountKey, base: base) }
    try refused("unsafe app base SSH") { _ = try SSHKeyManager.generate(in: base) }
    try noKeygen("no keygen on unsafe base")
}
let uidBase = try fresh("uid-limit")
try FileIdentityStore.write(Data("CERT".utf8), account: IdentityManager.accountCert, base: uidBase)
try FileIdentityStore.write(Data("KEY".utf8), account: IdentityManager.accountKey, base: uidBase)
let uid = uidBase.appendingPathComponent("Glimmer/Identity/client-uniqueid.txt")
try writeFixture(Data(repeating: 85, count: 4097), uid)
let uidManager = IdentityManager(uidBase)
try refused("UID bound") { _ = try uidManager.load() }
try expect(uidManager.generations == 0, "oversized UID never regenerates")
for (name, cert, key, unique) in [("partial", "CERT", nil, "UID"), ("empty-cert", "", "KEY", "UID"), ("empty-uid", "CERT", "KEY", "")] as [(String, String, String?, String)] {
    let base = try fresh(name)
    try FileIdentityStore.write(Data(cert.utf8), account: IdentityManager.accountCert, base: base)
    if let key { try FileIdentityStore.write(Data(key.utf8), account: IdentityManager.accountKey, base: base) }
    try FileIdentityStore.write(Data(unique.utf8), account: IdentityManager.accountUID, base: base)
    let manager = IdentityManager(base)
    try refused("malformed identity \(name)") { _ = try manager.load() }
    try expect(manager.generations == 0, "malformed identity not regenerated")
}
let onlyUID = try fresh("uid-only")
try FileIdentityStore.write(Data("UID".utf8), account: IdentityManager.accountUID, base: onlyUID)
let onlyUIDManager = IdentityManager(onlyUID)
try refused("UID-only partial identity") { _ = try onlyUIDManager.load() }
try expect(onlyUIDManager.generations == 0, "UID-only partial identity not regenerated")
let freshIdentity = IdentityManager(fixture.appendingPathComponent("fresh-generation"))
_ = try freshIdentity.load(); try expect(freshIdentity.generations == 1, "genuine absence permits generation")
try noKeygen("all refusal tests precede real keygen")
let sshBase = try fresh("ssh-success"), generated = try SSHKeyManager.generate(in: sshBase)
try expect(generated.publicKey.hasPrefix("ssh-ed25519 "), "fresh SSH key success")
try expect(FileManager.default.fileExists(atPath: marker.path), "wrapper proves successful keygen invocation")
var keyStat = stat(); guard lstat(generated.privateKey.path, &keyStat) == 0 else { fatalError("generated key") }
try expect(keyStat.st_mode & 0o777 == 0o600 && keyStat.st_nlink == 1, "generated private key mode/link")
print("private storage checks passed: \(checks) synthetic assertions")
'''

with tempfile.TemporaryDirectory(prefix="deskbridge-private-storage-", dir="/private/tmp") as temporary:
    temp = Path(temporary)
    os.chmod(temp, 0o700)
    fixture = temp / "fixtures"
    fixture.mkdir(mode=0o700)
    wrapper = temp / "keygen-fixture"
    # Paths are generated locally and passed as argv; no user data is interpolated.
    wrapper.write_text('#!/bin/sh\nprintf invoked > "$DESKBRIDGE_FIXTURE_MARKER"\nexec /usr/bin/ssh-keygen "$@"\n')
    wrapper.chmod(0o700)
    identity = (ROOT / "Vendor/Glimmer/GlimmerEngine/Network/Identity.swift").read_text()
    extracted = identity.split("// MARK: - IdentityManager", 1)[0]
    extracted = extracted.replace("private enum IdentityPrivateStorage", "enum IdentityPrivateStorage")
    loading = (ROOT / "Vendor/Glimmer/GlimmerEngine/Network/Identity+Loading.swift").read_text()
    loading = loading.replace("UserDefaults", "FixtureDefaults")
    ssh = (ROOT / "Sources/DeskBridgeCore/SSHKeyManager.swift").read_text()
    ssh = ssh.replace('URL(fileURLWithPath: "/usr/bin/ssh-keygen")', 'URL(fileURLWithPath: CommandLine.arguments[2])')
    for name, source in [("IdentityStore.swift", extracted), ("IdentityLoading.swift", loading), ("SSHKeyManager.swift", ssh), ("main.swift", HARNESS)]:
        (temp / name).write_text(source)
    binary = temp / "check"
    subprocess.run(["/usr/bin/swiftc", "-package-name", "PrivateStorageSyntheticChecks", "-o", str(binary),
                    str(ROOT / "Sources/DeskBridgeCore/CorePrivateStorage.swift"),
                    str(ROOT / "Sources/DeskBridgeCore/SavedSettings.swift"),
                    str(temp / "IdentityStore.swift"), str(temp / "IdentityLoading.swift"),
                    str(temp / "SSHKeyManager.swift"), str(temp / "main.swift")], check=True, timeout=60)
    environment = os.environ.copy()
    environment["DESKBRIDGE_FIXTURE_MARKER"] = str(fixture / "keygen-invoked")
    subprocess.run([str(binary), str(fixture), str(wrapper)], check=True, timeout=30, env=environment)
