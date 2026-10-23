// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io
// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

import Foundation
import os.log
import Security

extension IdentityManager {

    func load() throws -> Identity {
        guard protectedDataAvailable() else { throw IdentityStorageError.unavailable }
        guard let defaults else { throw IdentityStorageError.defaultsUnavailable }
        if let cached { return cached }
        try FileIdentityStore.validateStorage(base: storageRoot())

        // -----------------------------------------------------------------
        // Step 1 - file-store fast path.
        // -----------------------------------------------------------------
        let established = defaults.integer(forKey: Self.fileStorageFlag) >= Self.fileStorageVersion
        if let identity = try loadFromFileStore(requireComplete: established) {
            // Complete an interrupted migration without replacing the valid file identity.
            wipeUserDefaultsPlaintext(defaults: defaults)
            defaults.set(Self.fileStorageVersion, forKey: Self.fileStorageFlag)
            cached = identity
            log.info("Loaded identity from file store")
            return identity
        }
        // An established identity disappearing is a recovery error, not a new install.
        guard !established else { throw IdentityStorageError.incompleteIdentity }

        // The keychain-era flag means the earliest plaintext defaults were already wiped.
        let legacyKeychainOnly = defaults.integer(forKey: Self.legacyKeychainOnlyFlag) >= 1

        var storedCert: String?
        var storedKey: String?
        var storedID: String?

        if !legacyKeychainOnly {
            storedCert = defaults.string(forKey: IdentityKey.certificate)
            storedKey  = defaults.string(forKey: IdentityKey.privateKey)
            storedID   = defaults.string(forKey: IdentityKey.uniqueID)
        } else {
            // Even with the flag set, an opaque uniqueID might still live
            // in UserDefaults from an even earlier build. Preserve it.
            storedID = defaults.string(forKey: IdentityKey.uniqueID)
        }

        // The shell may copy a legacy identity. It validates PEMs and never modifies the source suite.
        let needsMigration = (storedCert?.isEmpty ?? true) || (storedKey?.isEmpty ?? true)
        if needsMigration, let adopted = try migrateIdentity(storedID) {
            storedCert = adopted.certPEM
            storedKey  = adopted.keyPEM
            storedID   = adopted.uniqueID
        }

        // -----------------------------------------------------------------
        // Either we have a usable PEM pair from steps 3/4, or we go to step 5.
        // -----------------------------------------------------------------
        if let certPEM = storedCert, !certPEM.isEmpty,
           let keyPEM  = storedKey, !keyPEM.isEmpty {
            let uid: String
            if let stored = storedID, !stored.isEmpty {
                uid = stored
            } else {
                uid = try generateUniqueID()
            }
            let identity = Identity(uniqueID: uid, certPEM: certPEM, keyPEM: keyPEM)
            try writeIdentityToFileStore(identity)
            wipeUserDefaultsPlaintext(defaults: defaults)
            defaults.set(Self.fileStorageVersion, forKey: Self.fileStorageFlag)
            cached = identity
            log.info("Migrated identity from UserDefaults plaintext to file store")
            return identity
        }

        // -----------------------------------------------------------------
        // Step 5 - fresh install. Generate, file-store, done.
        // -----------------------------------------------------------------
        log.info("No existing client identity - generating a new one (file store)")
        let (certPEM, keyPEM) = try generateKeyPairAndCert()
        let uid: String
        if let stored = storedID, !stored.isEmpty {
            uid = stored
        } else {
            uid = try generateUniqueID()
        }
        let identity = Identity(uniqueID: uid, certPEM: certPEM, keyPEM: keyPEM)
        try writeIdentityToFileStore(identity)
        wipeUserDefaultsPlaintext(defaults: defaults)
        defaults.set(Self.fileStorageVersion, forKey: Self.fileStorageFlag)
        cached = identity
        log.info("Wrote freshly-generated identity to file store")
        return identity
    }

    package struct AdoptedQtIdentity: Sendable {
        package let certPEM: String
        package let keyPEM: String
        package let uniqueID: String?
        package init(certPEM: String, keyPEM: String, uniqueID: String?) {
            self.certPEM = certPEM
            self.keyPEM = keyPEM
            self.uniqueID = uniqueID
        }
    }

    // MARK: File store (current backend)

    /// Only an unflagged first install/migration may fall through or synthesize a missing ID.
    /// Once published, all three identity components must remain present.
    func loadFromFileStore(requireComplete: Bool) throws -> Identity? {
        let certificate = try FileIdentityStore.read(account: Self.accountCert, base: storageRoot())
        let privateKey = try FileIdentityStore.read(account: Self.accountKey, base: storageRoot())
        let uniqueID = try FileIdentityStore.read(account: Self.accountUID, base: storageRoot())
        if certificate == nil && privateKey == nil && uniqueID == nil { return nil }
        // Existing malformed bytes remain a storage validation failure even if
        // another component is absent. Missing ordinary material instead needs
        // recovery guidance; changing permissions cannot restore those bytes.
        func text(_ data: Data?) throws -> String? {
            guard let data else { return nil }
            guard let value = String(data: data, encoding: .utf8), !value.isEmpty
            else { throw IdentityStorageError.unsafeStorage }
            return value
        }
        let certificatePEM = try text(certificate)
        let privateKeyPEM = try text(privateKey)
        let storedUID = try text(uniqueID)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let storedUID, storedUID.isEmpty { throw IdentityStorageError.unsafeStorage }
        guard let certPEM = certificatePEM, let keyPEM = privateKeyPEM
        else { throw IdentityStorageError.incompleteIdentity }
        try validateLocalIdentity(certPEM: certPEM, keyPEM: keyPEM)
        let uid: String
        if let stored = storedUID {
            uid = stored
        } else {
            guard !requireComplete else { throw IdentityStorageError.incompleteIdentity }
            // Complete an unpublished legacy migration without replacing its valid PEM pair.
            uid = try generateUniqueID()
            let uidBytes = Data(uid.utf8)
            try FileIdentityStore.write(uidBytes, account: Self.accountUID, base: storageRoot())
            log.info("File store missing uniqueID - synthesised and wrote a fresh one")
        }
        return Identity(uniqueID: uid, certPEM: certPEM, keyPEM: keyPEM)
    }

    /// Persist an Identity to the file store. Each component goes through
    /// `FileIdentityStore.write` which enforces mode 0600 and verifies it
    /// stuck via stat(2).
    func writeIdentityToFileStore(_ identity: Identity) throws {
        try FileIdentityStore.validateStorage(base: storageRoot())
        try validateLocalIdentity(certPEM: identity.certPEM, keyPEM: identity.keyPEM)
        try FileIdentityStore.write(Data(identity.certPEM.utf8),
                                    account: Self.accountCert, base: storageRoot())
        try FileIdentityStore.write(Data(identity.keyPEM.utf8),
                                    account: Self.accountKey, base: storageRoot())
        try FileIdentityStore.write(Data(identity.uniqueID.utf8),
                                    account: Self.accountUID, base: storageRoot())
    }

    /// Invalid local PEM material needs local storage guidance, not host crypto settings.
    private func validateLocalIdentity(certPEM: String, keyPEM: String) throws {
        do {
            _ = try PEM.identity(certPEM: certPEM, keyPEM: keyPEM)
        } catch StreamError.crypto {
            throw IdentityStorageError.unsafeStorage
        }
    }

    // MARK: UserDefaults plaintext cleanup

    /// Remove any plaintext PEMs left in UserDefaults. The uniqueID is
    /// wiped too - once we're in file-store mode the only authoritative copy
    /// lives on disk. Idempotent: removing missing keys is a no-op.
    func wipeUserDefaultsPlaintext(defaults: UserDefaults) {
        defaults.removeObject(forKey: IdentityKey.certificate)
        defaults.removeObject(forKey: IdentityKey.privateKey)
        defaults.removeObject(forKey: IdentityKey.uniqueID)
        // Force a synchronous flush to disk so a process crash between
        // here and natural CFPreferences flush doesn't leave the plaintext
        // PEM on the platter.
        defaults.synchronize()
    }
}
