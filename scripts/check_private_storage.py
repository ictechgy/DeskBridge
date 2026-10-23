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
enum StreamError: Error { case crypto(String), hostTimedOut }
enum FixtureCryptoFailure: Error { case unexpected }
// Synthetic PEM validation preserves the production crypto-error taxonomy;
// this harness does not exercise Security.framework PEM parsing or real RSA keys.
enum PEM {
    static func identity(certPEM: String, keyPEM: String) throws {
        if certPEM == "UNEXPECTED-ERROR" { throw FixtureCryptoFailure.unexpected }
        if certPEM == "NONCRYPTO-ERROR" { throw StreamError.hostTimedOut }
        guard certPEM != "WEAK-CERT", keyPEM != "WEAK-KEY" else {
            throw StreamError.crypto("client identity requires RSA keys of at least 2048 bits")
        }
        guard certPEM == "CERT", keyPEM == "KEY" || keyPEM == "MISMATCHED-KEY" else {
            throw StreamError.crypto("could not parse client certificate or private key")
        }
        guard keyPEM == "KEY" else { throw StreamError.crypto("client cert/key mismatch") }
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
    var uidGenerations = 0
    init(_ root: URL) { storageRoot = { root } }
    func generateUniqueID() throws -> String { uidGenerations += 1; return "0123456789abcdef0123456789abcdef" }
    func generateKeyPairAndCert() throws -> (String, String) { generations += 1; return ("CERT", "KEY") }
}
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
func incomplete(_ label: String, _ body: () throws -> Void) throws {
    do { try body() } catch IdentityStorageError.incompleteIdentity { checks += 1; return }
    catch { fatalError("wrong incomplete-identity failure for \(label): \(type(of: error))") }
    fatalError("incomplete identity accepted: \(label)")
}
enum FixtureValidationFailure { case unsafeStorage, unexpected, nonCrypto }
func validationFailure(_ expected: FixtureValidationFailure, _ label: String, _ body: () throws -> Void) throws {
    do { try body() }
    catch IdentityStorageError.unsafeStorage where expected == .unsafeStorage { checks += 1; return }
    catch FixtureCryptoFailure.unexpected where expected == .unexpected { checks += 1; return }
    catch StreamError.hostTimedOut where expected == .nonCrypto { checks += 1; return }
    catch { fatalError("wrong local identity validation failure for \(label): \(type(of: error))") }
    fatalError("invalid local identity accepted: \(label)")
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

// Hooks are injected into the extracted source only; production has no fixture switches.
enum FixturePublicationFailure: Error { case injected }
enum FixturePublication {
    static var mode = ""
    static func checkpoint(_ point: String) throws {
        if mode == "crash-" + point { kill(getpid(), SIGKILL); _exit(86) }
        if mode == "throw-" + point { throw FixturePublicationFailure.injected }
        if mode == "race-" + point {
            let canonical = fixture.appendingPathComponent("Glimmer/Identity")
            if mkdir(canonical.path, 0o700) != 0 && errno != EEXIST { fatalError("race directory") }
            try writeFixture(Data("RACING-MATERIAL".utf8), canonical.appendingPathComponent("racing-material"))
        }
        if mode == "swap-before-publish" && point == "before-publish" {
            let canonical = fixture.appendingPathComponent("Glimmer/Identity")
            guard rename(canonical.path, fixture.appendingPathComponent("Glimmer/held-empty").path) == 0,
                  mkdir(canonical.path, 0o700) == 0 else { fatalError("swap directory") }
        }
        if mode == "extra-stage-after-stage-1" && point == "after-stage-1" {
            let glimmer = fixture.appendingPathComponent("Glimmer")
            let stage = try FileManager.default.contentsOfDirectory(atPath: glimmer.path).first { $0.hasPrefix(".identity-") }!
            try writeFixture(Data("UNEXPECTED-STAGE-CONTENT".utf8), glimmer.appendingPathComponent(stage + "/unexpected"))
        }
    }
    static func parentSync(_ fd: Int32) -> Int32 {
        if mode == "parent-sync-failure" { errno = EIO; return -1 }
        return fsync(fd)
    }
}
if CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "publication-worker" {
    FixturePublication.mode = CommandLine.arguments[4]
    let manager = IdentityManager(fixture)
    manager.defaults!.set("unchanged", forKey: "other-setting")
    let beforeDefaults = NSDictionary(dictionary: manager.defaults!.values)
    do {
        _ = try manager.load()
        fatalError("publication injection was not reached")
    } catch FixturePublicationFailure.injected {
        try expect(FixturePublication.mode.hasPrefix("throw-"), "unexpected injected publication failure")
    } catch IdentityStorageError.unsafeStorage {
        try expect(!FixturePublication.mode.hasPrefix("throw-") && !FixturePublication.mode.hasPrefix("crash-"),
                   "publication failed before checkpoint")
    }
    try expect(beforeDefaults.isEqual(NSDictionary(dictionary: manager.defaults!.values)), "failed publication changed defaults/flag")
    try expect(manager.cached == nil && manager.generations == 1 && manager.uidGenerations == 1,
               "failed fresh publication changed cached state or generation count")
    exit(0)
}
func publicationChild(_ base: URL, _ mode: String, killed: Bool = false) throws {
    let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = [base.path, CommandLine.arguments[2], "publication-worker", mode]
    try child.run(); child.waitUntilExit()
    try expect(killed ? child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL :
               child.terminationReason == .exit && child.terminationStatus == 0,
               "publication child did not reach expected failure: \(mode)")
}
func canonicalBytes(_ base: URL) throws -> [Data?] {
    try [IdentityManager.accountCert, IdentityManager.accountKey, IdentityManager.accountUID].map {
        try FileIdentityStore.read(account: $0, base: base)
    }
}
let generatedComponents: [Data?] = [Data("CERT".utf8), Data("KEY".utf8), Data("0123456789abcdef0123456789abcdef".utf8)]

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
    if name == "partial" { try incomplete("partial identity") { _ = try manager.load() } }
    else { try refused("malformed identity \(name)") { _ = try manager.load() } }
    try expect(manager.generations == 0, "malformed identity not regenerated")
}
let onlyUID = try fresh("uid-only")
try FileIdentityStore.write(Data("UID".utf8), account: IdentityManager.accountUID, base: onlyUID)
let onlyUIDManager = IdentityManager(onlyUID)
try incomplete("UID-only partial identity") { _ = try onlyUIDManager.load() }
try expect(onlyUIDManager.generations == 0, "UID-only partial identity not regenerated")
let freshIdentity = IdentityManager(fixture.appendingPathComponent("fresh-generation"))
_ = try freshIdentity.load(); try expect(freshIdentity.generations == 1, "genuine absence permits generation")
// A published identity must never become a fresh install, even if every file is gone.
for hasPEMs in [false, true] {
    let base = try fresh("published-missing-\(hasPEMs)")
    if hasPEMs {
        try FileIdentityStore.write(Data("CERT".utf8), account: IdentityManager.accountCert, base: base)
        try FileIdentityStore.write(Data("KEY".utf8), account: IdentityManager.accountKey, base: base)
    }
    let manager = IdentityManager(base)
    manager.defaults!.set(IdentityManager.fileStorageVersion, forKey: IdentityManager.fileStorageFlag)
    manager.defaults!.set("LEGACY-CERT", forKey: IdentityKey.certificate)
    manager.defaults!.set("LEGACY-KEY", forKey: IdentityKey.privateKey)
    try incomplete("published identity missing components") { _ = try manager.load() }
    try expect(manager.generations == 0 && manager.uidGenerations == 0 && manager.cached == nil,
               "published identity regenerated or cached replacement material")
    try expect(manager.defaults!.string(forKey: IdentityKey.privateKey) == "LEGACY-KEY" &&
               manager.defaults!.integer(forKey: IdentityManager.fileStorageFlag) == IdentityManager.fileStorageVersion,
               "refusal changed recovery defaults or initialized flag")
    try expect(try FileIdentityStore.read(account: IdentityManager.accountUID, base: base) == nil,
               "refusal wrote a replacement UID")
    try expect(try FileIdentityStore.read(account: IdentityManager.accountKey, base: base) == (hasPEMs ? Data("KEY".utf8) : nil),
               "refusal changed existing or absent key bytes")
}
let legacyPEMs = try fresh("unpublished-pems")
try FileIdentityStore.write(Data("CERT".utf8), account: IdentityManager.accountCert, base: legacyPEMs)
try FileIdentityStore.write(Data("KEY".utf8), account: IdentityManager.accountKey, base: legacyPEMs)
let legacyManager = IdentityManager(legacyPEMs)
try expect(try legacyManager.load().certPEM == "CERT" && legacyManager.generations == 0 && legacyManager.uidGenerations == 1,
           "unpublished migration no longer preserves its valid PEM pair")
// Missing material has a distinct recovery error. Exercise every refused subset
// of the three components, preserving both file bytes and in-memory defaults.
// Mask 0 without a flag is a fresh install; mask 3 without a flag remains the
// explicit valid-PEM legacy migration above. Neither contract changes here.
let components = [(IdentityManager.accountCert, Data("CERT".utf8)),
                  (IdentityManager.accountKey, Data("KEY".utf8)),
                  (IdentityManager.accountUID, Data("UID".utf8))]
for established in [false, true] {
    for mask in 0..<7 where established || (mask != 0 && mask != 3) {
        let base = try fresh("incomplete-matrix-\(established)-\(mask)")
        for (index, component) in components.enumerated() where mask & (1 << index) != 0 {
            try FileIdentityStore.write(component.1, account: component.0, base: base)
        }
        let manager = IdentityManager(base)
        if established { manager.defaults!.set(IdentityManager.fileStorageVersion, forKey: IdentityManager.fileStorageFlag) }
        manager.defaults!.set("RECOVERY-CERT", forKey: IdentityKey.certificate)
        manager.defaults!.set("RECOVERY-KEY", forKey: IdentityKey.privateKey)
        manager.defaults!.set("RECOVERY-UID", forKey: IdentityKey.uniqueID)
        manager.defaults!.set("unrelated", forKey: "other-setting")
        let beforeDefaults = NSDictionary(dictionary: manager.defaults!.values)
        let beforeEntries = try FileManager.default.contentsOfDirectory(atPath: base.path)
        try incomplete("component mask \(mask), established \(established)") { _ = try manager.load() }
        try expect(manager.generations == 0 && manager.uidGenerations == 0 && manager.cached == nil,
                   "incomplete identity generated or cached replacement material")
        try expect(beforeDefaults.isEqual(NSDictionary(dictionary: manager.defaults!.values)),
                   "incomplete identity changed defaults or initialized flag")
        try expect(try FileManager.default.contentsOfDirectory(atPath: base.path) == beforeEntries,
                   "incomplete identity created or removed a storage directory")
        for (index, component) in components.enumerated() {
            let expected: Data? = mask & (1 << index) != 0 ? component.1 : nil
            try expect(try FileIdentityStore.read(account: component.0, base: base) == expected,
                       "incomplete identity changed existing or absent component bytes")
        }
    }
}
// Invalid bytes remain unsafeStorage even when a different component is missing.
for (index, component) in [(IdentityManager.accountCert, Data()),
                            (IdentityManager.accountKey, Data([0xff])),
                            (IdentityManager.accountUID, Data(" \n".utf8))].enumerated() {
    let base = try fresh("malformed-partial-\(index)")
    try FileIdentityStore.write(component.1, account: component.0, base: base)
    let manager = IdentityManager(base)
    try refused("malformed partial bytes") { _ = try manager.load() }
    try expect(manager.generations == 0 && manager.uidGenerations == 0,
               "malformed partial identity regenerated material")
    try expect(try FileIdentityStore.read(account: component.0, base: base) == component.1,
               "malformed partial bytes changed")
}
// Valid UTF-8 can still fail PEM parsing, RSA strength, or cert/key matching.
// Both local validation boundaries must preserve all material and defaults.
let validationCases: [(String, String, String, FixtureValidationFailure)] = [
    ("bad-cert", "NOT-A-CERTIFICATE", "KEY", .unsafeStorage),
    ("bad-key", "CERT", "NOT-A-PRIVATE-KEY", .unsafeStorage),
    ("weak-cert", "WEAK-CERT", "KEY", .unsafeStorage),
    ("weak-key", "CERT", "WEAK-KEY", .unsafeStorage),
    ("mismatch", "CERT", "MISMATCHED-KEY", .unsafeStorage),
    ("unexpected", "UNEXPECTED-ERROR", "KEY", .unexpected),
    ("noncrypto", "NONCRYPTO-ERROR", "KEY", .nonCrypto),
]
for (name, cert, key, expectedFailure) in validationCases {
    for version in [0, 1] {
        for prewrite in [false, true] {
            let label = "\(name), flag \(version), prewrite \(prewrite)"
            let base = try fresh("pem-validation-\(name)-\(version)-\(prewrite)")
            let stored = [(IdentityManager.accountCert, Data((prewrite ? "CERT" : cert).utf8)),
                          (IdentityManager.accountKey, Data((prewrite ? "KEY" : key).utf8)),
                          (IdentityManager.accountUID, Data("UID".utf8))]
            for (account, bytes) in stored { try FileIdentityStore.write(bytes, account: account, base: base) }
            let manager = IdentityManager(base)
            manager.defaults!.set(version, forKey: IdentityManager.fileStorageFlag)
            manager.defaults!.set("RECOVERY-CERT", forKey: IdentityKey.certificate)
            manager.defaults!.set("RECOVERY-KEY", forKey: IdentityKey.privateKey)
            manager.defaults!.set("RECOVERY-UID", forKey: IdentityKey.uniqueID)
            manager.defaults!.set("unrelated", forKey: "other-setting")
            let beforeDefaults = NSDictionary(dictionary: manager.defaults!.values)
            let directory = base.appendingPathComponent("Glimmer/Identity")
            let beforeEntries = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            try validationFailure(expectedFailure, label) {
                if prewrite {
                    try manager.writeIdentityToFileStore(.init(uniqueID: "REPLACEMENT-UID", certPEM: cert, keyPEM: key))
                } else {
                    _ = try manager.load()
                }
            }
            try expect(manager.generations == 0 && manager.uidGenerations == 0 && manager.cached == nil,
                       "local PEM refusal generated or cached replacement material: \(label)")
            try expect(beforeDefaults.isEqual(NSDictionary(dictionary: manager.defaults!.values)),
                       "local PEM refusal changed defaults or initialized flag: \(label)")
            try expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == beforeEntries,
                       "local PEM refusal changed storage entries: \(label)")
            for (account, bytes) in stored {
                try expect(try FileIdentityStore.read(account: account, base: base) == bytes,
                           "local PEM refusal changed component bytes: \(label)")
            }
        }
    }
}
// Abruptly kill real child processes after every staged file, before publication,
// and after publication. No stack unwinding/cleanup runs in these children.
for emptyDestination in [false, true] {
    for point in ["after-stage-1", "after-stage-2", "after-stage-3", "before-publish", "after-publish"] {
        for killed in [false, true] {
            let label = "\(emptyDestination)-\(point)-\(killed)"
            let base = try fresh("fresh-publication-" + label)
            if emptyDestination { _ = try identityRoot(base) }
            try publicationChild(base, (killed ? "crash-" : "throw-") + point, killed: killed)
            let published = point == "after-publish"
            try expect(try canonicalBytes(base) == (published ? generatedComponents : [nil, nil, nil]),
                       "crash/failure exposed partial canonical identity: \(label)")
            let glimmer = base.appendingPathComponent("Glimmer")
            let stages = try FileManager.default.contentsOfDirectory(atPath: glimmer.path).filter { $0.hasPrefix(".identity-") }
            try expect(stages.count == (killed && !published ? 1 : 0), "wrong retained stage count: \(label)")
            var orphanBytes: [String: Data] = [:]
            if let stageName = stages.first {
                let stageURL = glimmer.appendingPathComponent(stageName)
                let stageFD = try IdentityPrivateStorage.directory(stageURL, create: false)!
                defer { close(stageFD) }
                let entries = try IdentityPrivateStorage.entries(stageFD)
                try expect(entries.isSubset(of: [FileIdentityStore.certFileName, FileIdentityStore.keyFileName, FileIdentityStore.uidFileName]),
                           "crash orphan contains unexpected files")
                for name in entries {
                    let bytes = try IdentityPrivateStorage.read(stageFD, name: name, maximumBytes: name == FileIdentityStore.uidFileName ? 4096 : 64 * 1024)!
                    orphanBytes[stageName + "/" + name] = bytes
                }
                try expect(entries.count == (point == "after-stage-1" ? 1 : point == "after-stage-2" ? 2 : 3),
                           "crash did not occur at the requested stage boundary")
            }
            if emptyDestination && !published {
                let empty = try IdentityPrivateStorage.directory(base.appendingPathComponent("Glimmer/Identity"), create: false)!
                defer { close(empty) }
                try expect(try IdentityPrivateStorage.entries(empty).isEmpty, "failed publication replaced/filled empty destination")
            }
            let retry = IdentityManager(base)
            _ = try retry.load()
            try expect(retry.generations == (published ? 0 : 1) && retry.uidGenerations == (published ? 0 : 1),
                       "retry adopted an orphan or regenerated a published identity: \(label)")
            try expect(try canonicalBytes(base) == generatedComponents, "retry did not publish/adopt complete identity: \(label)")
            try expect(retry.defaults!.integer(forKey: IdentityManager.fileStorageFlag) == IdentityManager.fileStorageVersion,
                       "successful retry did not advance flag")
            for (name, bytes) in orphanBytes { try unchanged(glimmer.appendingPathComponent(name), bytes, "retry changed unadopted orphan") }
        }
    }
    let syncBase = try fresh("fresh-parent-sync-failure-\(emptyDestination)")
    if emptyDestination { _ = try identityRoot(syncBase) }
    try publicationChild(syncBase, "parent-sync-failure")
    try expect(try canonicalBytes(syncBase) == generatedComponents, "parent fsync failure rolled back complete canonical identity")
    let syncRetry = IdentityManager(syncBase); _ = try syncRetry.load()
    try expect(syncRetry.generations == 0 && syncRetry.uidGenerations == 0, "parent fsync failure caused identity replacement")
    for point in ["before-publish", "at-rename"] {
        let base = try fresh("fresh-race-\(emptyDestination)-\(point)")
        if emptyDestination { _ = try identityRoot(base) }
        try publicationChild(base, "race-" + point)
        try unchanged(base.appendingPathComponent("Glimmer/Identity/racing-material"), Data("RACING-MATERIAL".utf8),
                      "publication replaced racing canonical bytes")
        try expect(try canonicalBytes(base) == [nil, nil, nil], "racing destination received partial identity")
        let retry = IdentityManager(base)
        try refused("racing unknown canonical content") { _ = try retry.load() }
        try expect(retry.generations == 0 && retry.uidGenerations == 0, "racing content was treated as a new install")
    }
}
let swappedEmpty = try fresh("fresh-swapped-empty")
_ = try identityRoot(swappedEmpty)
try publicationChild(swappedEmpty, "swap-before-publish")
try expect(try FileManager.default.contentsOfDirectory(atPath: swappedEmpty.appendingPathComponent("Glimmer").path).sorted() == ["Identity", "held-empty"],
           "empty destination inode swap was published or removed")
let unknownStage = try fresh("fresh-unknown-stage")
try publicationChild(unknownStage, "extra-stage-after-stage-1")
let retainedStage = try FileManager.default.contentsOfDirectory(atPath: unknownStage.appendingPathComponent("Glimmer").path)
try expect(retainedStage.count == 1 && retainedStage[0].hasPrefix(".identity-"), "cleanup removed/replaced stage with unknown entry")
let retainedURL = unknownStage.appendingPathComponent("Glimmer/" + retainedStage[0])
try expect(try FileManager.default.contentsOfDirectory(atPath: retainedURL.path) == ["unexpected"], "cleanup retained known staged secrets or removed unknown bytes")
try unchanged(retainedURL.appendingPathComponent("unexpected"), Data("UNEXPECTED-STAGE-CONTENT".utf8), "cleanup removed unknown stage bytes")
for version in [0, 1] {
    let base = try fresh("fresh-unknown-entry-\(version)")
    let directory = try identityRoot(base), unknown = directory.appendingPathComponent("unknown")
    try writeFixture(Data("DO-NOT-ADOPT".utf8), unknown)
    let manager = IdentityManager(base); manager.defaults!.set(version, forKey: IdentityManager.fileStorageFlag)
    let beforeDefaults = NSDictionary(dictionary: manager.defaults!.values)
    if version == 0 { try refused("unknown identity entries") { _ = try manager.load() } }
    else { try incomplete("established identity remains incomplete") { _ = try manager.load() } }
    try expect(manager.generations == 0 && manager.uidGenerations == 0 && manager.cached == nil,
               "unknown identity entries permitted generation")
    try expect(beforeDefaults.isEqual(NSDictionary(dictionary: manager.defaults!.values)), "unknown entries changed defaults/flag")
    try unchanged(unknown, Data("DO-NOT-ADOPT".utf8), "unknown identity entry changed")
}
for index in 0..<3 {
    for empty in [false, true] {
        let base = try fresh("fresh-size-validation-\(index)-\(empty)")
        var bytes = [Data("CERT".utf8), Data("KEY".utf8), Data("UID".utf8)]
        bytes[index] = empty ? Data() : Data(repeating: 65, count: index == 2 ? 4097 : 64 * 1024 + 1)
        try refused("fresh identity component size") {
            try FileIdentityStore.publishFresh(certificate: bytes[0], privateKey: bytes[1], uniqueID: bytes[2], base: base)
        }
        try expect(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty, "size refusal created storage/stage")
    }
}
try noKeygen("all refusal tests precede real keygen")
let sshBase = try fresh("ssh-success"), generated = try SSHKeyManager.generate(in: sshBase)
try expect(generated.publicKey.hasPrefix("ssh-ed25519 "), "fresh SSH key success")
try expect(FileManager.default.fileExists(atPath: marker.path), "wrapper proves successful keygen invocation")
var keyStat = stat(); guard lstat(generated.privateKey.path, &keyStat) == 0 else { fatalError("generated key") }
try expect(keyStat.st_mode & 0o777 == 0o600 && keyStat.st_nlink == 1, "generated private key mode/link")
for mask in ["027", "002", "077"] {
    setenv("DESKBRIDGE_FIXTURE_UMASK", mask, 1)
    let base = try fresh("ssh-umask-" + mask)
    let key = try SSHKeyManager.generate(in: base)
    var pub = stat(), priv = stat()
    guard lstat(key.privateKey.path + ".pub", &pub) == 0, lstat(key.privateKey.path, &priv) == 0 else { fatalError("umask key fixture") }
    try expect(pub.st_mode & 0o7777 == 0o600 && priv.st_mode & 0o7777 == 0o600,
               "child umask must preserve successful private key publication")
}
unsetenv("DESKBRIDGE_FIXTURE_UMASK")
for keepExtra in [false, true] {
    setenv("DESKBRIDGE_FIXTURE_FAIL", "1", 1)
    if keepExtra { setenv("DESKBRIDGE_FIXTURE_EXTRA", "1", 1) }
    let base = try fresh("ssh-partial-failure-\(keepExtra)")
    var failed = false
    do { _ = try SSHKeyManager.generate(in: base) } catch { failed = true }
    unsetenv("DESKBRIDGE_FIXTURE_FAIL"); unsetenv("DESKBRIDGE_FIXTURE_EXTRA")
    try expect(failed, "nonzero keygen status was published")
    let children = try FileManager.default.contentsOfDirectory(at: base.appendingPathComponent("SSH"), includingPropertiesForKeys: nil)
    if keepExtra {
        try expect(children.count == 1, "unexpected content was recursively deleted")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: children[0].path)
        try expect(remaining == ["unexpected"], "partial private/public keys survived failure cleanup")
    } else {
        try expect(children.isEmpty, "failed keygen left an orphan private generation")
    }
}
print("private storage checks passed: \(checks) synthetic assertions")
'''

with tempfile.TemporaryDirectory(prefix="deskbridge-private-storage-", dir="/private/tmp") as temporary:
    temp = Path(temporary)
    os.chmod(temp, 0o700)
    fixture = temp / "fixtures"
    fixture.mkdir(mode=0o700)
    wrapper = temp / "keygen-fixture"
    # Paths are generated locally and passed as argv; no user data is interpolated.
    wrapper.write_text('''#!/bin/sh
printf invoked > "$DESKBRIDGE_FIXTURE_MARKER"
umask "${DESKBRIDGE_FIXTURE_UMASK:-022}"
/usr/bin/ssh-keygen "$@" || exit $?
if [ "${DESKBRIDGE_FIXTURE_EXTRA:-0}" = 1 ]; then
  while [ "$#" -gt 0 ]; do
    if [ "$1" = -f ]; then printf synthetic > "${2%/*}/unexpected"; break; fi
    shift
  done
fi
if [ "${DESKBRIDGE_FIXTURE_FAIL:-0}" = 1 ]; then exit 1; fi
''')
    wrapper.chmod(0o700)
    identity = (ROOT / "Vendor/Glimmer/GlimmerEngine/Network/Identity.swift").read_text()
    extracted = identity.split("// MARK: - IdentityManager", 1)[0]
    extracted = extracted.replace("private enum IdentityPrivateStorage", "enum IdentityPrivateStorage")
    checkpoints = {
        '            files.append((name, try IdentityPrivateStorage.exclusiveFile(stage, name: name, data: data, maximumBytes: maximumBytes)))':
        '            files.append((name, try IdentityPrivateStorage.exclusiveFile(stage, name: name, data: data, maximumBytes: maximumBytes)))\n            try FixturePublication.checkpoint("after-stage-\\(files.count)")',
        '        guard fsync(stage) == 0 else { throw IdentityStorageError.unsafeStorage }':
        '        guard fsync(stage) == 0 else { throw IdentityStorageError.unsafeStorage }\n        try FixturePublication.checkpoint("before-publish")',
        '        guard renameat(glimmer, stageName, glimmer, "Identity") == 0 else { throw IdentityStorageError.unsafeStorage }':
        '        try FixturePublication.checkpoint("at-rename")\n        guard renameat(glimmer, stageName, glimmer, "Identity") == 0 else { throw IdentityStorageError.unsafeStorage }',
        '        published = true': '        published = true\n        try FixturePublication.checkpoint("after-publish")',
        '        guard fsync(glimmer) == 0 else { throw IdentityStorageError.unsafeStorage }':
        '        guard FixturePublication.parentSync(glimmer) == 0 else { throw IdentityStorageError.unsafeStorage }',
    }
    for original, replacement in checkpoints.items():
        assert extracted.count(original) == 1, f"publication checkpoint drift: {original}"
        extracted = extracted.replace(original, replacement)
    # Compile the actual public error cases too; do not mirror their taxonomy.
    extracted += "\npublic enum IdentityStorageError" + identity.split("public enum IdentityStorageError", 1)[1]
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
