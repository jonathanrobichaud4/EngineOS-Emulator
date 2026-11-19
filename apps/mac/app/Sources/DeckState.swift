// What the emulator reports: its decks, drives and models, and reading `engineos-emu state`.

import Foundation

/// A deck in the VM (an emu.sh profile): the default one, or others side by side, such as a
/// stock Engine OS deck next to the EngineX one. One runs at a time.
struct DeckInfo: Hashable {
    var name: String
    var setUp: Bool
    var enginex: String
    var running: Bool
    var model: String = "JP21"
    var what: String { !setUp ? "not set up" : (enginex.isEmpty ? "stock Engine OS" : "EngineX \(enginex)") }
    var label: String { "\(name) (\(DeckModel.name(model)), \(what))" + (running ? ", running" : "") }
}

/// A folder plugged into the emulated decks (drives.txt; every deck shares them).
struct DriveInfo: Hashable {
    var label: String
    var kind: String   // "usb" or "sd"
    var folder: String
    var kindName: String { kind == "sd" ? "SD card" : "USB drive" }
}

/// The deck models the emulator knows, by inMusic product code. The list itself
/// (DeckModel.all, DeckModel.firmwareNote) is generated from models/ when the app is built.
struct DeckModel: Hashable {
    let code: String, name: String, ready: Bool
    static func name(_ code: String) -> String { all.first { $0.code == code }?.name ?? code }
}

/// `engineos-emu state`: lima= and vm= lines, then (with the VM running) json= with
/// `emu.sh info --json` (docs/cli.md). An emulator from before 1.2 in the VM answers with
/// key=value lines plus deck= and drive= lines instead, which still work.
struct EmuState {
    var values: [String: String] = [:]
    var decks: [DeckInfo] = []
    var drives: [DriveInfo] = []
    /// The deck on the network: "lan" (seen there), "local" (internet only) or "off", its name
    /// there and this computer's addresses on it (emu.sh info --json "network").
    var network: (mode: String, name: String, addresses: [String])?
    /// True once the emulator answered (the VM is up), so the deck and drive lists are real.
    var fromEmulator = false

    init(parsing text: String) {
        for line in text.split(separator: "\n") {
            if line.hasPrefix("json=") {
                readJSON(String(line.dropFirst(5)))
            } else if line.hasPrefix("drive=") {
                let f = line.dropFirst(6).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                if f.count >= 3 { drives.append(DriveInfo(label: f[0], kind: f[1], folder: f[2])) }
            } else if line.hasPrefix("deck=") {
                let f = line.dropFirst(5).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                if f.count >= 4 {
                    decks.append(DeckInfo(name: f[0], setUp: f[1] == "yes", enginex: f[2], running: f[3] == "yes",
                                          model: f.count >= 5 && !f[4].isEmpty ? f[4] : "JP21"))
                }
            } else if let eq = line.firstIndex(of: "=") {
                values[String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
        }
        if values["profile"] != nil { fromEmulator = true }
    }

    private mutating func readJSON(_ text: String) {
        guard let data = text.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        for (k, v) in o {
            if let s = v as? String { values[k] = s }
            else if let b = v as? Bool { values[k] = b ? "yes" : "no" }
        }
        for d in o["decks"] as? [[String: Any]] ?? [] {
            decks.append(DeckInfo(name: d["name"] as? String ?? "default", setUp: d["setup"] as? Bool ?? false,
                                  enginex: d["enginex"] as? String ?? "", running: d["running"] as? Bool ?? false,
                                  model: d["model"] as? String ?? "JP21"))
        }
        if let n = o["network"] as? [String: Any] {
            network = (n["mode"] as? String ?? "local", n["name"] as? String ?? "", n["addresses"] as? [String] ?? [])
        }
        for d in o["drives"] as? [[String: Any]] ?? [] {
            drives.append(DriveInfo(label: d["label"] as? String ?? "", kind: d["kind"] as? String ?? "usb",
                                    folder: d["folder"] as? String ?? ""))
        }
    }
}
