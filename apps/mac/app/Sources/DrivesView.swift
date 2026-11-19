import AppKit
import SwiftUI

/// The folders plugged into the decks: add, unplug, rename, USB or SD card, show in Finder.
struct DrivesView: View {
    @EnvironmentObject var m: Model
    @Environment(\.dismiss) var dismiss
    @State private var picked: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Drives").font(.title3.bold())
            Text("Folders on your Mac plugged into the deck as USB drives (or one SD card). Every deck sees the same ones. Engine keeps its library on a drive, so drives inside \(m.share.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) work best; others are read-only.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(selection: $picked) {
                ForEach(m.drives, id: \.label) { d in
                    HStack(spacing: 10) {
                        Image(systemName: d.kind == "sd" ? "sdcard" : "externaldrive").frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.label).bold()
                            Text(d.folder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Picker("", selection: Binding(get: { d.kind }, set: { m.setDriveType(d, $0) })) {
                            Text("USB drive").tag("usb")
                            Text("SD card").tag("sd")
                        }
                        .labelsHidden().frame(width: 120).disabled(m.busy)
                    }
                    .tag(d.label)
                    .contextMenu {
                        Button("Show in Finder") { m.revealDrive(d) }
                        Button("Rename...") { m.renameDrive(d) }
                        Button("Unplug") { m.removeDrive(d) }
                    }
                }
            }
            .frame(minHeight: 160)
            .overlay {
                if m.drives.isEmpty {
                    Text("No drives plugged in. Add a music folder, or drop one on the main window.").foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Add Folder...") { m.choose("Choose a music folder", folders: true) }
                Button("Rename...") { if let d = sel { m.renameDrive(d) } }.disabled(sel == nil)
                Button("Unplug") { if let d = sel { m.removeDrive(d) } }.disabled(sel == nil)
                Button("Show in Finder") { if let d = sel { m.revealDrive(d) } }.disabled(sel == nil)
                Spacer()
                if m.busy { ProgressView().controlSize(.small); Text(m.task).foregroundStyle(.secondary).lineLimit(1) }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .disabled(m.busy)
        }
        .padding(16)
        .frame(width: 600, height: 380)
        .onAppear { m.refresh() }
    }

    private var sel: DriveInfo? { m.drives.first { $0.label == picked } }
}
