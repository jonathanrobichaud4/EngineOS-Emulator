// EngineOS Emulator for macOS: a window for the emulator, which runs in a Lima Linux VM.
// Everything goes through the bundled `engineos-emu` launcher (Contents/Resources), the same
// commands you'd type in Terminal. The app shows the deck's state, starts and stops it, takes
// dropped files (firmware, EngineX bundle, mod, music folder), and shows what it's doing.
//
// Build: mac/app/build.sh (needs Xcode or the Command Line Tools; macOS 13 or later).

import AppKit
import SwiftUI

/// The app's name, in one place, and what carries over from before the rename (SC LIVE 4
/// Emulator): its settings, and its drive folder until the launcher moves it.
enum AppInfo {
    static let name = "EngineOS Emulator"
    static let zip = "EngineOSEmulator-mac.zip"
    static let script = "engineos-emu"

    /// ~/EngineOSEmulator, or ~/SCLive4Emulator on an older install whose VM hasn't restarted
    /// since (engineos-emu moves it then).
    static var share: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let new = home.appendingPathComponent("EngineOSEmulator"), old = home.appendingPathComponent("SCLive4Emulator")
        let fm = FileManager.default
        return !fm.fileExists(atPath: new.path) && fm.fileExists(atPath: old.path) ? old : new
    }

    /// Settings saved under the old bundle id, copied over once.
    private static let migrated: Void = {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromSCLive4"),
              let old = UserDefaults(suiteName: "io.github.jonathanrobichaud4.engineos-emulator") else { return }
        for k in ["autoStart", "openDeck", "autoUpdate", "softwareRender", "autoUpdateApp", "deck"]
            where d.object(forKey: k) == nil {
            if let v = old.object(forKey: k) { d.set(v, forKey: k) }
        }
        d.set(true, forKey: "migratedFromSCLive4")
    }()

    static func savedDeck() -> String {
        _ = migrated
        return UserDefaults.standard.string(forKey: "deck") ?? "default"
    }
}
import UniformTypeIdentifiers

// MARK: - Decks

/// A deck in the VM (an emu.sh profile): the default one, or others side by side, such as a
/// stock Engine OS deck next to the EngineX one. One runs at a time.
struct DeckInfo: Hashable {
    var name: String
    var setUp: Bool
    var enginex: String
    var running: Bool
    var label: String {
        let what = !setUp ? "not set up" : (enginex.isEmpty ? "stock Engine OS" : "EngineX \(enginex)")
        return "\(name) (\(what))" + (running ? " · running" : "")
    }
}

// MARK: - Running the launcher

final class Model: ObservableObject {
    @Published var log = ""
    @Published var busy = false
    @Published var task = ""              // what the busy command is, for the status line
    @Published var state: [String: String] = [:]
    @Published var following = false     // the Engine log is streaming into the log view

    @AppStorage("autoStart") var autoStart = false
    @AppStorage("openDeck") var openDeck = true
    @AppStorage("autoUpdate") var autoUpdate = true
    @AppStorage("softwareRender") var softwareRender = false
    @AppStorage("autoUpdateApp") var autoUpdateApp = true

    /// The selected deck ("default" is emu.sh's unnamed profile).
    @Published var deck: String = AppInfo.savedDeck() {
        didSet { UserDefaults.standard.set(deck, forKey: "deck"); state = [:]; refresh() }
    }
    @Published var decks: [DeckInfo] = []
    @Published var newDecks: [String] = []   // made here, not set up yet

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
        return e
    }

    func launch() {
        guard !started else { return }
        started = true
        if script.isEmpty { append("The app is missing its engineos-emu script; rebuild it with mac/app/build.sh.\n") }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in self?.refresh() }
        if autoUpdateApp { checkAppUpdate(manual: false) }
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
        if !isSetUp { return ("No deck yet: drop an SC LIVE 4 firmware file here", .orange) }
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
            var s: [String: String] = [:]
            var ds: [DeckInfo] = []
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                if line.hasPrefix("deck=") {
                    let f = line.dropFirst(5).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                    if f.count >= 4 { ds.append(DeckInfo(name: f[0], setUp: f[1] == "yes", enginex: f[2], running: f[3] == "yes")) }
                } else if let eq = line.firstIndex(of: "=") {
                    s[String(line[..<eq])] = String(line[line.index(after: eq)...])
                }
            }
            DispatchQueue.main.async {
                if !s.isEmpty { self.state = s }
                if !ds.isEmpty { self.decks = ds; self.newDecks.removeAll { n in ds.contains { $0.name == n } } }
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

    /// "--profile DECK" for the selected deck (nothing for the default one).
    var profileArgs: [String] { deck == "default" ? [] : ["--profile", deck] }

    /// Every deck to offer: the VM's, ones made here, and the selected one.
    var deckChoices: [DeckInfo] {
        var all = decks
        if !all.contains(where: { $0.name == "default" }) { all.insert(DeckInfo(name: "default", setUp: false, enginex: "", running: false), at: 0) }
        for n in newDecks + [deck] where !all.contains(where: { $0.name == n }) {
            all.append(DeckInfo(name: n, setUp: false, enginex: "", running: false))
        }
        return all
    }

    /// Runs `engineos-emu [--profile DECK] args...`, streaming its output into the log. One at a time.
    /// Commands about the VM or the app itself don't take a deck.
    func run(_ args: [String], title: String, profile: String? = nil, done: ((Int32) -> Void)? = nil) {
        let vmWide: Set<String> = ["install", "update", "vm-stop", "uninstall"]
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

    func newDeck() {
        let a = NSAlert()
        a.messageText = "New deck"
        a.informativeText = "A name for it (letters, digits, - and _), for example \"stock\". Then drop a firmware file on the window to set it up, with or without EngineX."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = "stock"
        a.accessoryView = field
        a.addButton(withTitle: "Create")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            append("Deck names are letters, digits, - and _ only.\n"); return
        }
        if !deckChoices.contains(where: { $0.name == name }) { newDecks.append(name) }
        deck = name
        append("New deck \"\(name)\": drop a firmware file on the window to set it up (add an EngineX bundle after, or leave it stock).\n")
    }

    private func startSelected() {
        let graphics = softwareRender ? "software" : "auto"
        run(["graphics", graphics], title: "Setting graphics to \(graphics)") { _ in
            self.run(["start"], title: "Starting the \(self.deck) deck") { code in
                if code == 0 && self.openDeck { NSWorkspace.shared.open(self.deckURL) }
            }
        }
    }
    func stop() { run(["stop"], title: "Stopping the deck") }
    func reboot() { run(["reboot"], title: "Rebooting the deck") }
    func update() { run(["update"], title: "Updating the emulator") }
    func stopVM() { run(["vm-stop"], title: "Stopping the VM") }

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

    // MARK: updating the app itself

    /// The app is published as the "mac-app" release, with version.txt holding the commit it
    /// was built from. A different commit there means a newer build: download it, swap this
    /// app's bundle for it once the app has quit, and open it again.
    static let release = "https://github.com/jonathanrobichaud4/engineos-emulator/releases/download/mac-app/"

    func checkAppUpdate(manual: Bool) {
        guard BuildInfo.commit != "dev" else {
            if manual { append("This is a local build (not from the release), so it doesn't update itself.\n") }
            return
        }
        var req = URLRequest(url: URL(string: Model.release + "version.txt")!)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let latest = data.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            DispatchQueue.main.async {
                guard code == 200, latest.count >= 7 else {
                    if manual { self.append("Couldn't check for app updates\(err.map { ": \($0.localizedDescription)" } ?? " (HTTP \(code))").\n") }
                    return
                }
                if latest == BuildInfo.commit {
                    if manual { self.append("The app is up to date (build \(latest.prefix(7))).\n") }
                    return
                }
                self.installAppUpdate(latest)
            }
        }.resume()
    }

    private func installAppUpdate(_ latest: String) {
        append("\n> Downloading the new app (build \(latest.prefix(7)))\n")
        URLSession.shared.downloadTask(with: URL(string: Model.release + AppInfo.zip)!) { tmp, resp, err in
            let fail = { (why: String) in DispatchQueue.main.async { self.append("App update failed: \(why)\n") } }
            guard let tmp = tmp, (resp as? HTTPURLResponse)?.statusCode == 200 else { fail(err?.localizedDescription ?? "download failed"); return }
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("engineos-update-\(UUID().uuidString)")
            do {
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                let zip = work.appendingPathComponent("app.zip")
                try fm.moveItem(at: tmp, to: zip)
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", zip.path, work.path]
                try unzip.run(); unzip.waitUntilExit()
                guard unzip.terminationStatus == 0,
                      let newApp = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" })
                else { fail("the download didn't contain the app"); return }
                let old = Bundle.main.bundleURL
                guard fm.isWritableFile(atPath: old.deletingLastPathComponent().path) else {
                    fail("can't write to \(old.deletingLastPathComponent().path); download it from the release page instead"); return
                }
                // Swap the bundles after this app quits, then open the new one. It goes in under
                // its own name, so an install from before the rename picks up the new name.
                let dest = old.deletingLastPathComponent().appendingPathComponent(newApp.lastPathComponent)
                let script = work.appendingPathComponent("swap.sh")
                let sh = """
                #!/bin/bash
                while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
                rm -rf "\(old.path).old" && mv "\(old.path)" "\(old.path).old" && mv "\(newApp.path)" "\(dest.path)" &&
                  xattr -dr com.apple.quarantine "\(dest.path)" 2>/dev/null
                rm -rf "\(old.path).old"
                open "\(dest.path)"
                """
                try sh.write(to: script, atomically: true, encoding: .utf8)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = [script.path]
                try p.run()
                DispatchQueue.main.async {
                    self.append("Restarting with the new app...\n")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { NSApp.terminate(nil) }
                }
            } catch {
                fail(error.localizedDescription)
            }
        }.resume()
    }

    // MARK: dropped or chosen files

    enum Kind { case firmware, enginex, mod, folder, unknown }

    func kind(of url: URL) -> Kind {
        var dir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &dir), dir.boolValue { return .folder }
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".img") || name.hasSuffix(".exe") || name.hasSuffix(".zip") { return .firmware }
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
            // A mod has a mod.json at its top (or one folder down); an EngineX bundle doesn't.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            p.arguments = ["-tzf", url.path]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return .unknown }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let names = String(decoding: data, as: UTF8.self).split(separator: "\n")
            let isMod = names.contains { n in
                let parts = n.split(separator: "/").filter { $0 != "." }
                return parts.last == "mod.json" && parts.count <= 2
            }
            return isMod ? .mod : .enginex
        }
        return .unknown
    }

    func open(_ url: URL) {
        switch kind(of: url) {
        case .firmware:
            run(["setup", url.path], title: "Setting up the deck from \(url.lastPathComponent)")
        case .enginex:
            run(["enginex", url.path], title: "Installing EngineX from \(url.lastPathComponent)")
        case .mod:
            run(["mod-install", url.path], title: "Installing the mod \(url.lastPathComponent)")
        case .folder:
            addDrive(url)
        case .unknown:
            append("Not sure what \(url.lastPathComponent) is. Drop a firmware file (.img, .exe or .zip), an EngineX bundle or mod (.tar.gz), or a music folder.\n")
        }
    }

    /// Engine writes its library onto a drive, and only ~/EngineOSEmulator is writable from the VM,
    /// so a folder elsewhere is copied there first (or used read-only).
    func addDrive(_ url: URL) {
        let inside = url.standardizedFileURL.path.hasPrefix(share.standardizedFileURL.path + "/")
        if inside { run(["drive", "add", url.path], title: "Plugging in \(url.lastPathComponent) as a USB drive"); return }
        let a = NSAlert()
        a.messageText = "Copy \"\(url.lastPathComponent)\" into \(share.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))?"
        a.informativeText = "Engine writes its library onto the drive, and the emulator can only write inside \(share.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")). You can also plug it in as is, read-only (Engine then can't keep a library on it)."
        a.addButton(withTitle: "Copy and plug in")
        a.addButton(withTitle: "Use read-only")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            let dest = share.appendingPathComponent(url.lastPathComponent)
            busy = true
            task = "Copying \(url.lastPathComponent)"
            append("\n> Copying \(url.lastPathComponent) into \(share.path)\n")
            DispatchQueue.global().async {
                var err: Error?
                do {
                    try FileManager.default.createDirectory(at: self.share, withIntermediateDirectories: true)
                    if !FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.copyItem(at: url, to: dest) }
                } catch { err = error }
                DispatchQueue.main.async {
                    self.busy = false
                    self.task = ""
                    if let err = err { self.append("Copy failed: \(err.localizedDescription)\n"); return }
                    self.run(["drive", "add", dest.path], title: "Plugging in \(dest.lastPathComponent) as a USB drive")
                }
            }
        case .alertSecondButtonReturn:
            run(["drive", "add", url.path], title: "Plugging in \(url.lastPathComponent) as a USB drive (read-only)")
        default:
            break
        }
    }

    func choose(_ title: String, folders: Bool = false) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = folders
        panel.canChooseFiles = !folders
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let u = panel.url { open(u) }
    }
}

// MARK: - Window

struct ContentView: View {
    @EnvironmentObject var m: Model
    @State private var dropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if m.state.isEmpty == false && (!m.lima || m.vm == "none") {
                installBox
            } else {
                buttons
            }
            dropZone
            logView
        }
        .padding(16)
        .onAppear { m.launch() }
    }

    var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppInfo.name).font(.title2.bold())
                HStack(spacing: 6) {
                    Circle().fill(m.summary.color).frame(width: 9, height: 9)
                    Text((m.state["product_name"].map { "\($0): " } ?? "") + (m.busy ? m.task : m.summary.text)).foregroundStyle(.secondary).lineLimit(1)
                    if m.busy { ProgressView().controlSize(.small) }
                }
            }
            Spacer()
            if m.lima && m.vm != "none" {
                Picker("Deck", selection: $m.deck) {
                    ForEach(m.deckChoices, id: \.name) { d in Text(d.label).tag(d.name) }
                }
                .frame(maxWidth: 300)
                .disabled(m.busy)
                Button { m.newDeck() } label: { Image(systemName: "plus") }
                    .help("New deck")
                    .disabled(m.busy)
            }
        }
    }

    var installBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("The emulator runs in a small Linux VM made with Lima. Install sets it up (a few minutes the first time).")
                    .fixedSize(horizontal: false, vertical: true)
                if !m.brew && !m.lima {
                    Text("Lima installs with Homebrew, which isn't installed yet. Install Homebrew first, then come back.")
                        .foregroundStyle(.orange)
                    Button("Open brew.sh") { NSWorkspace.shared.open(URL(string: "https://brew.sh")!) }
                }
                Button("Install") { m.install() }.keyboardShortcut(.defaultAction).disabled(m.busy || (!m.brew && !m.lima))
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }

    var buttons: some View {
        HStack(spacing: 8) {
            Button { m.start() } label: { Label("Start", systemImage: "play.fill") }
                .disabled(m.busy || !m.isSetUp || m.running)
            Button { m.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                .disabled(m.busy || !m.running)
            Button { m.reboot() } label: { Label("Reboot", systemImage: "arrow.clockwise") }
                .disabled(m.busy || !m.running)
            Divider().frame(height: 18)
            Button { NSWorkspace.shared.open(m.deckURL) } label: { Label("Open deck", systemImage: "rectangle.on.rectangle") }
                .disabled(!m.running)
            Button { NSWorkspace.shared.open(m.consoleURL) } label: { Label("EngineX console", systemImage: "slider.horizontal.3") }
                .disabled(!m.running || (m.state["enginex"] ?? "").isEmpty)
            Spacer()
            Menu {
                Button("Choose firmware...") { m.choose("Choose an SC LIVE 4 firmware file") }
                Button("Install EngineX bundle or mod...") { m.choose("Choose an EngineX bundle or a mod (.tar.gz)") }
                Button("Plug in a folder as a USB drive...") { m.choose("Choose a music folder", folders: true) }
                Divider()
                Button(m.following ? "Stop following the Engine log" : "Follow the Engine log") { m.followEngineLog() }
                Button("Update the emulator") { m.update() }
                Button("Check for app updates") { m.checkAppUpdate(manual: true) }
                Button("Reset the deck's data...") { m.resetData() }
                Divider()
                Button("Open Drives Folder") {
                    try? FileManager.default.createDirectory(at: m.share, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(m.share)
                }
                Button("Stop the VM (frees its memory)") { m.stopVM() }
                Button("Delete the VM...") { m.uninstall() }
            } label: { Label("More", systemImage: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .controlSize(.large)
    }

    var dropZone: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .foregroundStyle(dropping ? Color.accentColor : Color.secondary.opacity(0.5))
            .background(RoundedRectangle(cornerRadius: 10).fill(dropping ? Color.accentColor.opacity(0.08) : Color.clear))
            .frame(height: 64)
            .overlay(
                VStack(spacing: 2) {
                    Text("Drop files here").font(.headline)
                    Text("Firmware (.img, .exe, .zip) sets up the deck · EngineX bundle or mod (.tar.gz) installs it · a folder plugs in as a USB drive")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(.horizontal, 12)
            )
            .onDrop(of: [UTType.fileURL], isTargeted: $dropping) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url = url { DispatchQueue.main.async { m.open(url) } }
                    }
                }
                return true
            }
    }

    var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(m.log.isEmpty ? " " : m.log)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                Color.clear.frame(height: 1).id("end")
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
            .onChange(of: m.log) { _ in proxy.scrollTo("end", anchor: .bottom) }
        }
        .frame(minHeight: 180)
    }
}

struct SettingsView: View {
    @EnvironmentObject var m: Model
    var body: some View {
        Form {
            Toggle("Start the deck when the app opens", isOn: $m.autoStart)
            Toggle("Open the deck page after starting", isOn: $m.openDeck)
            Toggle("Update the emulator when the app opens", isOn: $m.autoUpdate)
            Toggle("Software rendering (if the screen looks wrong)", isOn: $m.softwareRender)
            Toggle("Update this app automatically", isOn: $m.autoUpdateApp)
            HStack {
                Button("Check for app updates now") { m.checkAppUpdate(manual: true) }
                Text("Build \(BuildInfo.commit.prefix(7))").foregroundStyle(.secondary).font(.caption)
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
