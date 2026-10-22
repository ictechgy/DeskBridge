// SPDX-License-Identifier: GPL-3.0-only
import DeskBridgeCore
import Foundation

@main
struct Checks {
    static func main() async throws {
        var count = 0
        func expect(_ condition: Bool, _ message: String) throws {
            guard condition else { throw CheckFailure(message: message) }; count += 1
        }
        for address in ["192.168.1.20", "10.0.0.8", "172.16.0.1", "172.31.255.1", "100.64.0.1", "100.127.255.1", "169.254.2.3"] {
            try expect(try EndpointPolicy.validatedAddress(address) == address, "private endpoint")
        }
        for invalid in ["8.8.8.8", "127.0.0.1", "0.0.0.0", "100.63.1.1", "100.128.0.1", "172.32.0.1", "192.168.01.1", "192.168.1.256",
                        "-oProxyCommand=whoami", "https://192.168.1.2", "localhost", "192.168.1.2:22", "192.168.1.2\n--arg", "::1"] {
            do { _ = try EndpointPolicy.validatedAddress(invalid); throw CheckFailure(message: "accepted endpoint " + invalid) }
            catch is EndpointPolicy.Failure { count += 1 }
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("deskbridge-settings-fixture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = SettingsStore(directory: temp)
        try expect(try store.load().host == nil, "new settings")
        var settings = SavedSettings(); settings.address = "100.80.10.20"
        settings.host = SavedHost(address: settings.address, uniqueID: "synthetic-host", name: "합성 PC",
                                  certificatePEM: "SYNTHETIC NOT A CERT", httpPort: 47989, httpsPort: 47984)
        try store.save(settings)
        let loaded = try store.load()
        try expect(loaded.host?.name == "합성 PC" && loaded.address == settings.address, "settings round trip")
        let mode = try FileManager.default.attributesOfItem(atPath: temp.appendingPathComponent("settings.json").path)[.posixPermissions] as? NSNumber
        try expect(mode?.intValue == 0o600, "settings owner permissions")
        let updated = try store.updating(loaded) { $0.address = "192.168.1.30" }
        try expect(updated.address == "192.168.1.30", "successful settings update returned")
        try expect(try store.load().address == updated.address, "successful settings update persisted")
        try expect(loaded.address == "100.80.10.20", "prior settings value retained")
        try store.save(loaded)
        // A real filesystem failure, independent of chmod/root behavior. Only fresh fixtures.
        let blocker = temp.appendingPathComponent("not-a-directory")
        let retainedBytes = Data("synthetic storage blocker".utf8)
        try retainedBytes.write(to: blocker)
        let failingStore = SettingsStore(directory: blocker)
        var published = loaded
        var saveFailed = false
        do {
            published = try failingStore.updating(published) {
                $0.address = "192.168.1.99"
                $0.host = SavedHost(address: $0.address, uniqueID: "unpersisted-host", name: "unpersisted",
                                    certificatePEM: "SYNTHETIC REPLACEMENT", httpPort: 47989, httpsPort: 47984)
            }
        } catch { saveFailed = true }
        try expect(saveFailed, "filesystem save failure surfaced")
        try expect(published.address == loaded.address, "failed address update not published")
        try expect(published.host?.certificatePEM == loaded.host?.certificatePEM &&
                   published.host?.uniqueID == loaded.host?.uniqueID, "failed host update not published")
        try expect(try store.load().host?.uniqueID == loaded.host?.uniqueID, "prior persisted host retained")
        try expect(try Data(contentsOf: blocker) == retainedBytes, "failed save leaves blocking file unchanged")
        try Data("not-json".utf8).write(to: temp.appendingPathComponent("settings.json"))
        do { _ = try store.load(); throw CheckFailure(message: "corrupt settings looked like fresh trust state") }
        catch is DecodingError { count += 1 }
        let sftp = try await runSFTPChecks()
        let engine = try runEnginePolicyChecks()
        let keyboard = try runDesktopKeyboardPolicyChecks()
        let target = try runTargetBindingChecks()
        let pipe = try await runSFTPPipeChecks()
        let setup = try runSetupExchangeChecks()
        let lifecycle = try runDesktopLifecycleChecks()
        let progress = try runTransferProgressChecks()
        let connectionDiscovery = try runConnectionInvitationChecks()
        let boundedFiles = try runBoundedRegularFileChecks()
        let result: [String: Any] = ["status": "passed", "endpointAndSettings": count, "sftp": sftp, "enginePolicy": engine, "keyboardAndComposition": keyboard, "targetBinding": target, "sftpPipes": pipe,
                                    "setupExchange": setup, "desktopLifecycle": lifecycle, "transferProgress": progress, "discoveryAndQR": connectionDiscovery, "boundedRegularFiles": boundedFiles,
                                    "scope": "synthetic offline checks only; no UI, socket, preferences, Keychain or live Windows"]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
        print(String(decoding: data, as: UTF8.self))
    }
}
struct CheckFailure: Error { let message: String }

