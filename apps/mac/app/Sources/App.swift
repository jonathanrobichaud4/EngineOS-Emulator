// EngineOS Emulator for macOS: a window for the emulator, which runs in a Lima Linux VM.
// The app shows the deck's state, starts and stops it, takes dropped files (firmware, EngineX
// bundle, mod, music folder), and shows what it's doing. Build: apps/mac/app/build.sh (needs
// Xcode or the Command Line Tools; macOS 13 or later). The files: docs/layout.md.

import AppKit
import SwiftUI

extension Notification.Name {
    static let manageDecks = Notification.Name("manageDecks")
    static let manageDrives = Notification.Name("manageDrives")
}

struct SettingsView: View {
    @EnvironmentObject var m: Model
    var body: some View {
        Form {
            Toggle("Start the deck when the app opens", isOn: $m.autoStart)
            Toggle("Open the deck page after starting", isOn: $m.openDeck)
            Toggle("Update the emulator when the app opens", isOn: $m.autoUpdate)
            Toggle("Update this app automatically", isOn: $m.autoUpdateApp)
            Toggle("Stop the deck and the VM when the app quits", isOn: $m.stopOnQuit)
            HStack {
                Button("Check for app updates now") { m.checkAppUpdate(manual: true) }
                Text(BuildInfo.version == "dev" ? "Test build \(BuildInfo.commit.prefix(7))" : "Version \(BuildInfo.version) (\(BuildInfo.commit.prefix(7)))")
                    .foregroundStyle(.secondary).font(.caption)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: Model?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { model?.quit() }

    /// Quitting stops the deck and the VM (unless that's turned off in Settings), so nothing keeps
    /// running in the background. The app waits for it up to three minutes; if it takes longer the
    /// app quits anyway and leaves the stop running on its own (never cut short, which would leave
    /// Lima thinking a dead VM is running).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let m = model, m.stopOnQuit, !m.updating, m.vm == "Running", !m.script.isEmpty else { return .terminateNow }
        m.append("\n> Stopping the deck and the VM before quitting\n")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: m.script)
        p.arguments = ["vm-stop"]
        p.environment = m.env
        var done = false
        let finish = { DispatchQueue.main.async { if !done { done = true; sender.reply(toApplicationShouldTerminate: true) } } }
        p.terminationHandler = { _ in finish() }
        do { try p.run() } catch { return .terminateNow }
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { finish() }
        return .terminateLater
    }
}

@main
struct EngineOSEmulatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = Model()

    var body: some Scene {
        WindowGroup(AppInfo.name) {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 480)
                .onAppear { delegate.model = model }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Firmware or Mod...") { model.choose("Choose a firmware file, EngineX bundle or mod") }
                    .keyboardShortcut("o")
            }
            CommandMenu("Deck") {
                Button("Manage Decks...") { NotificationCenter.default.post(name: .manageDecks, object: nil) }
                    .keyboardShortcut("k").disabled(model.busy)
                Button("Manage Drives...") { NotificationCenter.default.post(name: .manageDrives, object: nil) }
                    .keyboardShortcut("d", modifiers: [.command, .shift]).disabled(model.busy)
                Divider()
                Button("Start") { model.start() }.keyboardShortcut("r").disabled(model.busy || !model.isSetUp || model.running)
                Button("Stop") { model.stop() }.keyboardShortcut(".").disabled(model.busy || !model.running)
                Button("Reboot") { model.reboot() }.disabled(model.busy || !model.running)
                Divider()
                Button("Open Deck Page") { NSWorkspace.shared.open(model.deckURL) }.keyboardShortcut("d")
                Button("Open EngineX Console") { NSWorkspace.shared.open(model.consoleURL) }
            }
        }
        Settings {
            SettingsView().environmentObject(model)
        }
    }
}
