// SPDX-License-Identifier: GPL-3.0-only
import DeskBridgeCore
import Foundation

/// Simulate modal re-entry using only the actual models' pure gate and snapshot validator.
@MainActor
func runSetupExchangeGateChecks(temporary: URL) throws -> Int {
    var count = 0
    func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ModelCheckFailure(message: message) }; count += 1
    }
    let directory = temporary.appendingPathComponent("setup-exchange-gates")
    let suite = "org.deskbridge.synthetic." + UUID().uuidString
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let desktop = DesktopModel(storageDirectory: directory, identitySuite: suite)
    let files = FilesModel(desktop: desktop)
    let identity = directory.appendingPathComponent("not-opened-private-key").path
    let addresses = "192.168.1.20, 100.80.10.20"
    let cases: [(fileBusy: Bool, connected: Bool, desktopBusy: Bool, streaming: Bool,
                 changedIdentity: Bool, changedAddresses: Bool, available: Bool, validSelection: Bool)] = [
        (false, false, false, false, false, false, true, true),
        (true, false, false, false, false, false, false, false),
        (false, true, false, false, false, false, false, false),
        (false, false, true, false, false, false, false, false),
        (false, false, false, true, false, false, false, false),
        (false, false, false, false, true, false, true, false),
        (false, false, false, false, false, true, true, false),
        (true, true, true, true, true, true, false, false),
    ]
    for state in cases {
        files.busy = state.fileBusy; files.connected = state.connected
        desktop.busy = state.desktopBusy; desktop.streaming = state.streaming
        files.identityPath = state.changedIdentity ? identity + "-replacement" : identity
        files.setupAddresses = state.changedAddresses ? "10.0.0.2" : addresses
        try expect(files.canExchangeSetup == state.available, "setup exchange gate missed a screen or file activity state")
        var accepted = false
        do { try files.requireSetupExchangeSelection(identityPath: identity, setupAddresses: addresses); accepted = true }
        catch is AppFailure {}
        try expect(accepted == state.validSelection, "post-panel exchange accepted stale identity, addresses or activity")
        try expect(desktop.settings.sshIdentityPath.isEmpty && desktop.settings.address.isEmpty,
                   "pure setup exchange validation persisted or published unapproved settings")
    }
    return count
}
