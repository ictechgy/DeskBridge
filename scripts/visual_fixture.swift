// SPDX-License-Identifier: GPL-3.0-only
// Synthetic rendering executable only. Not included in the shipped app target.
import AppKit
import CoreGraphics
import DeskBridgeCore
import GlimmerEngine
import SwiftUI

@MainActor
private final class FixtureLifecycle: NSObject, NSApplicationDelegate {
    var terminateOnClose = false
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { terminateOnClose }
}

@main
enum VisualFixture {
    @MainActor static func main() {
        let app = NSApplication.shared
        let lifecycle = FixtureLifecycle()
        app.delegate = lifecycle
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                guard [3, 5].contains(CommandLine.arguments.count) else { throw AppFailure("Expected temporary fixture and output directories.") }
                let interactive = CommandLine.arguments.count == 5 && CommandLine.arguments[3] == "--interactive"
                lifecycle.terminateOnClose = interactive
                guard interactive || CGPreflightScreenCaptureAccess() else {
                    throw AppFailure("Screen Recording is unavailable. No screenshot was taken. Run --interactive for manual inspection; this tool does not request OS permissions.")
                }
                let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
                let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
                guard fixture.path.hasPrefix(NSTemporaryDirectory()), fixture.lastPathComponent.hasPrefix("deskbridge-ui-") else {
                    throw AppFailure("Fixture storage must be a freshly created temporary directory.")
                }
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let ready = SavedHost(address: "192.168.1.20", uniqueID: "SYNTHETIC-PC", name: "개발 PC",
                                      certificatePEM: "SYNTHETIC-NOT-A-CERTIFICATE", httpPort: 47989, httpsPort: 47984)
                for (name, page, mode, width, height) in [
                    ("desktop", Page.desktop, "ready", 1200.0, 710.0),
                    ("files", Page.files, "ready", 1200.0, 710.0),
                    ("setup", Page.setup, "ready", 1200.0, 710.0),
                    ("first-run", Page.desktop, "empty", 1200.0, 710.0),
                    ("certificate-error", Page.desktop, "mismatch", 1200.0, 710.0),
                    ("compact", Page.desktop, "ready", 880.0, 620.0),
                    ("files-compact", Page.files, "ready", 880.0, 620.0),
                    ("dark", Page.desktop, "dark", 1200.0, 710.0)
                ] {
                    if interactive && name != CommandLine.arguments[4] { continue }
                    let directory = fixture.appendingPathComponent(name, isDirectory: true)
                    var settings = SavedSettings()
                    if mode != "empty" { settings.address = ready.address; settings.host = ready }
                    let store = SettingsStore(directory: directory)
                    try store.save(settings)
                    let model = DesktopModel(storageDirectory: directory, identitySuite: "org.deskbridge.visual.\(UUID().uuidString)")
                    guard model.store.directory == directory else { throw AppFailure("Fixture storage injection failed.") }
                    if mode == "ready" || mode == "dark" {
                        model.serverName = ready.name; model.paired = true
                        model.apps = [HostApp(id: 1, name: "Desktop", hdrCapable: false, hidden: false)]
                        model.resolution = 1440; model.status = ""
                    } else if mode == "mismatch" {
                        model.status = "화면 연결을 중단했습니다."
                        model.errorMessage = "저장된 화면 인증서와 다릅니다. 변경 이유를 확인한 뒤 다시 페어링하세요."
                    }
                    let files = FilesModel(desktop: model)
                    if mode != "empty" {
                        files.connected = true; files.currentPath = "/files/Projects"
                        files.entries = [
                            .visualFixture(name: "sprint-plan.md", size: 4096),
                            .visualFixture(name: "client.ts", size: 12288),
                            .visualFixture(name: "schema.sql", size: 8192),
                            .visualFixture(name: "notes.txt", size: 2048)
                        ]; files.selection = "/files/Projects/client.ts"; files.status = ""
                    }
                    let view = MainView(initialPage: page).environmentObject(model).environmentObject(files)
                    let controller = NSHostingController(rootView: view)
                    let rect = NSRect(x: 0, y: 0, width: width, height: height)
                    let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.title = "DeskBridge · 합성 화면 검증"
                    window.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
                    window.contentViewController = controller
                    window.setContentSize(rect.size)
                    window.makeKeyAndOrderFront(nil)
                    app.activate(ignoringOtherApps: true)
                    try await Task.sleep(for: .milliseconds(500))
                    controller.view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    if interactive {
                        print("SYNTHETIC_WINDOW_READY \(name) windowID=\(window.windowNumber)")
                        fflush(stdout)
                        return
                    }
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), "-t", "png", output.appendingPathComponent(name + ".png").path]
                    try capture.run(); capture.waitUntilExit()
                    guard capture.terminationStatus == 0 else { throw AppFailure("Cannot capture the synthetic window. No visual pass is implied.") }
                    print("Rendered \(name) \(Int(width))x\(Int(height)) using synthetic data only")
                    window.orderOut(nil); window.close()
                }
                app.terminate(nil)
            } catch {
                fputs("Synthetic visual fixture failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        withExtendedLifetime(lifecycle) { app.run() }
    }
}
