import SwiftUI

/// Add, rename and delete decks, and pick each one's model.
struct DecksView: View {
    @EnvironmentObject var m: Model
    @Environment(\.dismiss) var dismiss
    @State private var picked: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Decks").font(.title3.bold())
            Text("Each deck is its own emulated unit with its own firmware, settings, library and mods. One runs at a time. " + DeckModel.firmwareNote)
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(selection: $picked) {
                ForEach(m.deckChoices, id: \.name) { d in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.name).bold()
                            Text(d.what + (d.running ? ", running" : "")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(get: { d.model }, set: { m.setModel(d, $0) })) {
                            ForEach(DeckModel.all, id: \.code) { x in
                                Text(x.ready ? x.name : "\(x.name) (coming later)").tag(x.code)
                            }
                        }
                        .labelsHidden().frame(width: 190)
                        .disabled(m.busy || d.running)
                    }
                    .tag(d.name)
                }
            }
            .frame(minHeight: 180)
            HStack {
                Button("Add...") { m.newDeck() }
                Button("Rename...") { if let d = sel { m.renameDeck(d) } }.disabled(sel == nil)
                Button("Delete...") { if let d = sel { m.deleteDeck(d) } }.disabled(sel == nil)
                Spacer()
                if m.busy { ProgressView().controlSize(.small); Text(m.task).foregroundStyle(.secondary).lineLimit(1) }
                Button("Use This Deck") { if let d = sel { m.deck = d.name }; dismiss() }.disabled(sel == nil)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .disabled(m.busy)
        }
        .padding(16)
        .frame(width: 560, height: 380)
        .onAppear { picked = m.deck; m.refresh() }
    }

    private var sel: DeckInfo? { m.deckChoices.first { $0.name == picked } }
}
