// The main window: status and deck picker, the buttons, the drop zone and the log.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var m: Model
    @State private var dropping = false
    @State private var showDecks = false
    @State private var showDrives = false

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
        .sheet(isPresented: $showDecks) { DecksView().environmentObject(m) }
        .sheet(isPresented: $showDrives) { DrivesView().environmentObject(m) }
        .onReceive(NotificationCenter.default.publisher(for: .manageDrives)) { _ in showDrives = true }
        .onReceive(NotificationCenter.default.publisher(for: .manageDecks)) { _ in showDecks = true }
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
                Button { showDecks = true } label: { Image(systemName: "slider.horizontal.3") }
                    .help("Manage decks: add, rename, delete, choose the model")
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
            Button { showDrives = true } label: { Label(m.drives.isEmpty ? "Drives" : "Drives (\(m.drives.count))", systemImage: "externaldrive") }
                .help("The folders plugged into the deck as USB drives or an SD card")
            Spacer()
            Menu {
                Button("Choose firmware...") { m.choose("Choose the deck's firmware file") }
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
