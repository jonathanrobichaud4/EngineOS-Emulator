// Managing decks: emu.sh profile new / rename / delete / model.

import AppKit

extension Model {
    static let deckNamePattern = "^[A-Za-z0-9_-]+$"

    private func validName(_ name: String, except old: String? = nil) -> Bool {
        guard name.range(of: Model.deckNamePattern, options: .regularExpression) != nil else {
            alert("Deck names are letters, digits, - and _ only."); return false
        }
        if name != old, deckChoices.contains(where: { $0.name == name }) { alert("There's already a deck called \(name)."); return false }
        return true
    }

    /// A popup of the models; the ones that don't boot yet are shown but can't be picked.
    static func modelPopup(selected: String) -> NSPopUpButton {
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        pop.autoenablesItems = false
        for d in DeckModel.all {
            pop.addItem(withTitle: d.ready ? d.name : "\(d.name) (coming later)")
            pop.lastItem?.representedObject = d.code
            pop.lastItem?.isEnabled = d.ready
        }
        pop.selectItem(at: DeckModel.all.firstIndex { $0.code == selected } ?? 0)
        return pop
    }

    func newDeck() {
        let a = NSAlert()
        a.messageText = "New deck"
        a.informativeText = "A name (letters, digits, - and _) and which deck it is. Then drop a firmware file on the window to set it up, with or without EngineX.\n\n" + DeckModel.firmwareNote
        let field = NSTextField(frame: NSRect(x: 0, y: 32, width: 260, height: 24))
        field.stringValue = deckChoices.contains { $0.name == "stock" } ? "" : "stock"
        field.placeholderString = "name"
        let pop = Model.modelPopup(selected: "JP21")
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 58))
        box.addSubview(field); box.addSubview(pop)
        a.accessoryView = box
        a.addButton(withTitle: "Create")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard validName(name) else { return }
        let code = pop.selectedItem?.representedObject as? String ?? "JP21"
        run(["profile", "new", name, code], title: "Making the \(name) deck") { code in
            if code == 0 { self.deck = name }
            self.refresh()
        }
    }

    func renameDeck(_ d: DeckInfo) {
        guard !d.running else { alert("Stop the \(d.name) deck before renaming it."); return }
        let a = NSAlert()
        a.messageText = "Rename \"\(d.name)\""
        a.informativeText = "Letters, digits, - and _."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = d.name
        a.accessoryView = field
        a.addButton(withTitle: "Rename")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard name != d.name, validName(name, except: d.name) else { return }
        run(["profile", "rename", d.name, name], title: "Renaming \(d.name) to \(name)") { code in
            if code == 0 && self.deck == d.name { self.deck = name }
            self.refresh()
        }
    }

    func deleteDeck(_ d: DeckInfo) {
        guard !d.running else { alert("Stop the \(d.name) deck before deleting it."); return }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Delete the \(d.name) deck?"
        a.informativeText = "This deletes its firmware copy, Engine settings, library and installed mods. Your music and drive folders aren't touched."
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        run(["profile", "delete", d.name], title: "Deleting the \(d.name) deck") { code in
            if code == 0 && self.deck == d.name {
                self.deck = self.decks.first { $0.name != d.name }?.name ?? "default"
            }
            self.refresh()
        }
    }

    func setModel(_ d: DeckInfo, _ code: String) {
        guard code != d.model else { return }
        guard DeckModel.all.first(where: { $0.code == code })?.ready ?? false else {
            alert("\(DeckModel.name(code)) support isn't ready yet. For now every deck is an SC LIVE 4."); return
        }
        run(["profile", "model", d.name, code], title: "Setting \(d.name) to \(DeckModel.name(code))") { _ in self.refresh() }
    }
}
