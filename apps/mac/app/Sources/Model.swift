// The app's state and the commands it runs. Everything goes through the bundled `engineos-emu`
// launcher (Contents/Resources), the same commands you'd type in Terminal.
// Decks: Model+Decks.swift. Drives and dropped files: Model+Files.swift. Updates: Updater.swift.

import AppKit
import SwiftUI

final class Model: ObservableObject {
    @Published var log = ""
    @Published var busy = false
    @Published var task = ""              // what the busy command is, for the status line
    @Published var state: [String: String] = [:]
    @Published var following = false     // the Engine log is streaming into the log view

    @AppStorage("autoStart") var autoStart = false
    @AppStorage("openDeck") var openDeck = true
    @AppStorage("autoUpdate") var autoUpdate = true
    @AppStorage("autoUpdateApp") var autoUpdateApp = true
    @AppStorage("stopOnQuit") var stopOnQuit = true
    var updating = false   // quitting to install an app update: leave the deck alone

    /// The selected deck ("default" is emu.sh's unnamed profile).
    @Published var deck: String = AppInfo.savedDeck() {
        didSet { UserDefaults.standard.set(deck, forKey: "deck"); state = [:]; refresh() }
    }
    @Published var decks: [DeckInfo] = []
    @Published var drives: [DriveInfo] = []
    @Published var network: (mode: String, name: String, addresses: [String])?

    private var current: Process?
    private var follower: Process?
    private var timer: Timer?
    private var started = false

    let script: String = Bundle.main.path(forResource: AppInfo.script, ofType: nil) ?? ""
    var share: URL { AppInfo.share }

    var env: [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        e["NO_COLOR"] = "1"
        e["ENGINEOS_NO_OPEN"] = "1"   // the app opens the deck page itself, once
        // "update" moves the emulator to the release matching this app.
        if BuildInfo.version != "dev" { e["ENGINEOS_VERSION"] = BuildInfo.version }
        return e
    }

    func launch() {
        guard !started else { return }
        started = true
        if script.isEmpty { append("The app is missing its engineos-emu script; rebuild it with apps/mac/app/build.sh.\n") }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in self?.refresh() }
        if autoUpdateApp { checkAppUpdate(manual: false) }
        else { append("Automatic app updates are off (Settings > Update this app automatically).\n") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, self.vm == "Running" || self.vm == "Stopped" else { return }
            if self.autoUpdate {
                self.run(["update"], title: "Updating the emulator") { _ in
                    if self.autoStart && self.isSetUp { self.start() }
                }
            } else if self.autoStart && self.isSetUp {
                self.start()
            }
        }
    }

    // State, from `engineos-emu state` (never starts the VM).
    var lima: Bool { state["lima"] == "yes" }
    var brew: Bool { state["brew"] != "no" }
    var vm: String { state["vm"] ?? "" }
    var isSetUp: Bool { state["setup"] == "yes" }
    var running: Bool { state["running"] == "yes" }
    var engineUp: Bool { state["engine"] == "up" }
    var deckURL: URL { URL(string: state["deck_url"] ?? "http://localhost:8090/")! }
    var consoleURL: URL { URL(string: state["console_url"] ?? "http://localhost:8080/")! }

    var summary: (text: String, color: Color) {
        if state.isEmpty { return ("Checking...", .secondary) }
        if !lima { return ("Not installed yet", .orange) }
        switch vm {
        case "none": return ("Not installed yet", .orange)
        case "Running": break
        default: return (isSetUp ? "Stopped" : "VM stopped", .secondary)
        }
        if !isSetUp { return ("No deck yet: drop its firmware file here", .orange) }
        if let e = state["engine_error"], !e.isEmpty { return ("Engine stopped: " + e, .red) }
        if running && engineUp { return ("Running", .green) }
        if running { return ("Starting Engine...", .yellow) }
        return ("Stopped", .secondary)
    }

    func refresh() {
        guard !script.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script] + profileArgs + ["state"]
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let s = EmuState(parsing: String(decoding: data, as: UTF8.self))
            DispatchQueue.main.async {
                if !s.values.isEmpty { self.state = s.values }
                // The VM's own list (empty once every deck is deleted). If the selected deck is
                // gone (renamed or deleted elsewhere), select the first one there is.
                if s.values["vm"] == "Running" && s.fromEmulator {
                    self.decks = s.decks
                    self.drives = s.drives
                    self.network = s.network
                    if !s.decks.isEmpty && !s.decks.contains(where: { $0.name == self.deck }) { self.deck = s.decks[0].name }
                }
            }
        }
        try? p.run()
    }

    func append(_ s: String) {
        // Drop terminal colour codes, keep the view to the last ~200 KB.
        let clean = s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        log += clean
        if log.count > 200_000 { log = String(log.suffix(150_000)) }
    }

    func alert(_ text: String) {
        let a = NSAlert(); a.messageText = text; a.runModal()
    }

    /// "--profile DECK" for the selected deck (nothing for the default one).
    var profileArgs: [String] { deck == "default" ? [] : ["--profile", deck] }

    /// Every deck to offer: the VM's, or just the selected one before there are any.
    var deckChoices: [DeckInfo] {
        decks.isEmpty ? [DeckInfo(name: deck, setUp: false, enginex: "", running: false)] : decks
    }

    /// Runs `engineos-emu [--profile DECK] args...`, streaming its output into the log. One at a time.
    /// Commands about the VM or the app itself don't take a deck.
    func run(_ args: [String], title: String, profile: String? = nil, done: ((Int32) -> Void)? = nil) {
        let vmWide: Set<String> = ["install", "update", "vm-stop", "uninstall", "profile", "network"]
        var pre = profileArgs
        if let p = profile { pre = p == "default" ? [] : ["--profile", p] }
        let full = (args.first.map { vmWide.contains($0) } ?? false) ? args : pre + args
        guard !busy else { append("Busy with: \(task). Try again when it's finished.\n"); return }
        guard !script.isEmpty else { return }
        busy = true
        task = title
        append("\n> \(title)\n")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script] + full
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let s = String(decoding: d, as: UTF8.self)
            DispatchQueue.main.async { self?.append(s) }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async {
                guard let self = self else { return }
                if !rest.isEmpty { self.append(String(decoding: rest, as: UTF8.self)) }
                if proc.terminationStatus != 0 { self.append("(\(self.task) failed, exit \(proc.terminationStatus))\n") }
                self.busy = false
                self.task = ""
                self.current = nil
                self.refresh()
                done?(proc.terminationStatus)
            }
        }
        do {
            try p.run()
            current = p
        } catch {
            busy = false
            task = ""
            append("Couldn't run engineos-emu: \(error.localizedDescription)\n")
        }
    }

    // MARK: actions

    func install() { run(["install"], title: "Installing (Lima and the Linux VM; the first time takes a few minutes)") }

    func start() {
        if let other = decks.first(where: { $0.running && $0.name != deck }) {
            let a = NSAlert()
            a.messageText = "Stop the \"\(other.name)\" deck first?"
            a.informativeText = "Only one deck runs at a time. \"\(other.name)\" is running; it'll be stopped and \"\(deck)\" started."
            a.addButton(withTitle: "Stop and start")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
            run(["stop"], title: "Stopping the \(other.name) deck", profile: other.name) { _ in self.startSelected() }
            return
        }
        startSelected()
    }

    private func startSelected() {
        run(["start"], title: "Starting the \(deck) deck") { code in
            if code == 0 && self.openDeck { NSWorkspace.shared.open(self.deckURL) }
        }
    }
    func stop() { run(["stop"], title: "Stopping the deck") }
    func reboot() { run(["reboot"], title: "Rebooting the deck") }
    func update() { run(["update"], title: "Updating the emulator") }
    func stopVM() { run(["vm-stop"], title: "Stopping the VM") }

    // MARK: your network (docs/networking.md)

    /// The VM is bridged onto the Mac's network (engineos-emu network on).
    var onNetwork: Bool { state["bridged"] == "yes" }

    var networkNote: String {
        if !onNetwork {
            return "Lets Denon gear, Engine DJ, SoundSwitch and lighting apps on your network see the deck. The first time, it installs a small helper and asks for your password; the VM restarts."
        }
        guard let n = network, running else { return "On your network. Start the deck and it shows up there." }
        if n.mode != "lan" { return "The VM is on your network, but this deck is set to stay on this computer." }
        return "Seen as \(n.name)" + (n.addresses.isEmpty ? "" : " at " + n.addresses.joined(separator: ", "))
    }

    func setOnNetwork(_ on: Bool) {
        run(["network", on ? "on" : "off"], title: on ? "Putting the deck on your network" : "Taking the deck off your network")
    }

    func uninstall() {
        let a = NSAlert()
        a.messageText = "Delete the emulator's Linux VM?"
        a.informativeText = "This deletes the VM and the deck inside it (its settings, library and installed mods). Your files in \(share.path) stay."
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        a.alertStyle = .warning
        if a.runModal() == .alertFirstButtonReturn { run(["uninstall", "--yes"], title: "Deleting the VM") }
    }

    func resetData() {
        let a = NSAlert()
        a.messageText = "Reset the deck's data?"
        a.informativeText = "Engine's settings and library on the emulated deck go back to a fresh start. The firmware and EngineX stay."
        a.addButton(withTitle: "Reset")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if running {
            run(["stop"], title: "Stopping the deck") { _ in self.run(["reset-data"], title: "Resetting the deck's data") }
        } else {
            run(["reset-data"], title: "Resetting the deck's data")
        }
    }

    func followEngineLog() {
        if following { follower?.terminate(); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script] + profileArgs + ["log"]
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let s = String(decoding: d, as: UTF8.self)
            DispatchQueue.main.async { self?.append(s) }
        }
        p.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { self?.following = false; self?.append("(stopped following the Engine log)\n") }
        }
        do {
            try p.run()
            follower = p
            following = true
            append("\n> Following the Engine log\n")
        } catch {
            append("Couldn't follow the log: \(error.localizedDescription)\n")
        }
    }

    func quit() {
        follower?.terminate()
    }
}
