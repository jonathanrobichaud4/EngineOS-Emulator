// Drives (emu.sh drive add / remove / rename / type) and dropped or chosen files.

import AppKit

extension Model {
    func removeDrive(_ d: DriveInfo) {
        let a = NSAlert()
        a.messageText = "Unplug \(d.label)?"
        a.informativeText = "The deck stops seeing it. The folder and its music stay where they are: \(d.folder)"
        a.addButton(withTitle: "Unplug")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        run(["drive", "remove", d.label], title: "Unplugging \(d.label)") { _ in self.refresh() }
    }

    func renameDrive(_ d: DriveInfo) {
        let a = NSAlert()
        a.messageText = "Rename \(d.label)"
        a.informativeText = "The name the deck shows: up to 11 letters, digits, - and _, like a real USB stick."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = d.label
        a.accessoryView = field
        a.addButton(withTitle: "Rename")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard name != d.label else { return }
        guard name.count <= 11, name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            alert("Drive names are up to 11 letters, digits, - and _."); return
        }
        guard !drives.contains(where: { $0.label == name }) else { alert("There's already a drive called \(name)."); return }
        run(["drive", "rename", d.label, name], title: "Renaming \(d.label) to \(name)") { _ in self.refresh() }
    }

    func setDriveType(_ d: DriveInfo, _ kind: String) {
        guard kind != d.kind else { return }
        if kind == "sd", let other = drives.first(where: { $0.kind == "sd" && $0.label != d.label }) {
            alert("The deck has one SD card slot, and \(other.label) is in it. Make that one a USB drive first."); return
        }
        run(["drive", "type", d.label, kind], title: kind == "sd" ? "Putting \(d.label) in the SD slot" : "Making \(d.label) a USB drive") { _ in self.refresh() }
    }

    func revealDrive(_ d: DriveInfo) {
        let url = URL(fileURLWithPath: d.folder)
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else { alert("\(d.folder) isn't there any more (moved or deleted?). Unplug the drive and plug the folder in again.") }
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
