import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - The menu

/// The binding verbs on a shelved book's menu (Origami Binding Profile
/// §5, 24 Oct 2026): Export Full Document, Export Selection… for a book
/// of articles, and the binder — New Binder, then Add to Binder on every
/// book until it is exported or cancelled.
struct BinderMenuItems: View {
    @Environment(AppModel.self) private var model
    let record: EPUBRecord
    private var binder: BinderModel { BinderModel.shared }

    var body: some View {
        let info = model.epubWorks(for: record)
        Divider()
        Button("Export Full Document…") { model.exportFullDocument(record) }
        if let info, info.hasWorks {
            Button("Export Selection…") {
                binder.chooser = BinderChooserRequest(record: record, info: info, purpose: .exportSelection)
            }
        }
        if binder.isActive {
            if binder.contains(record) {
                Button("Remove from Binder") { binder.remove(record) }
            } else if let info, info.hasWorks {
                Button("Add Articles to Binder…") {
                    binder.chooser = BinderChooserRequest(record: record, info: info, purpose: .addToBinder)
                }
                Button("Add Whole Book to Binder") { binder.add(BinderPart(record: record, workIDs: nil)) }
            } else {
                Button("Add to Binder") { binder.add(BinderPart(record: record, workIDs: nil)) }
            }
        } else {
            Button("New Binder") {
                binder.start()
                if let info, info.hasWorks {
                    binder.chooser = BinderChooserRequest(record: record, info: info, purpose: .addToBinder)
                } else {
                    binder.add(BinderPart(record: record, workIDs: nil))
                }
            }
        }
    }
}

// MARK: - The binder bar and its sheets

/// Shown under the library list while a binder is being made: what is
/// in it, and Export As Binder, Export As Binder with Cover…, Cancel.
/// Also presents the works chooser and the cover sheet for every surface.
struct BinderBar: View {
    @Environment(AppModel.self) private var model
    private var binder: BinderModel { BinderModel.shared }

    var body: some View {
        @Bindable var binder = BinderModel.shared
        Group {
            if let parts = binder.parts {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(parts.isEmpty ? "New Binder — control-click books to add them"
                             : "Binder: \(parts.count) \(parts.count == 1 ? "item" : "items")")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button("Cancel") { binder.cancel() }
                        Button("Export As Binder") { model.exportBinder(parts, coverText: nil, title: nil) }
                            .disabled(parts.isEmpty)
                        Button("Export As Binder with Cover…") { binder.coverRequest = true }
                            .disabled(parts.isEmpty)
                            .keyboardShortcut(.defaultAction)
                    }
                    if !parts.isEmpty {
                        Text(parts.map { $0.title(model.epubWorks(for: $0.record)) }.joined(separator: " · "))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(10)
                .background(.regularMaterial)
                .overlay(alignment: .top) { Divider() }
            }
        }
        .sheet(item: $binder.chooser) { request in
            BinderWorksChooser(request: request)
        }
        .sheet(isPresented: $binder.coverRequest) {
            BinderCoverSheet()
        }
    }
}

/// Which of a book's articles: for Export Selection…, or to add to the
/// binder. Title and cover text ride along for the export.
struct BinderWorksChooser: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: BinderChooserRequest
    @State private var selected: Set<String> = []
    @State private var title = ""
    @State private var coverText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.purpose == .exportSelection ? "Export Selection" : "Add Articles to Binder")
                .font(.headline)
            Text(request.record.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Button("All") { selected = Set(request.info.works.map(\.id)) }
                Button("None") { selected = [] }
                Spacer()
                Text("\(selected.count) of \(request.info.works.count) chosen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            List {
                ForEach(request.info.works) { work in
                    Toggle(isOn: Binding(
                        get: { selected.contains(work.id) },
                        set: { on in if on { selected.insert(work.id) } else { selected.remove(work.id) } })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(work.title)
                            if !work.authors.isEmpty {
                                Text(work.authors.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 220)
            if request.purpose == .exportSelection {
                TextField("Title", text: $title)
                Text("Cover text (optional):")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $coverText)
                    .font(.system(size: 13))
                    .frame(height: 70)
                    .border(Color.secondary.opacity(0.3))
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.purpose == .exportSelection ? "Export…" : "Add") {
                    let ids = request.info.works.map(\.id).filter { selected.contains($0) }
                    switch request.purpose {
                    case .addToBinder:
                        BinderModel.shared.add(BinderPart(record: request.record, workIDs: ids))
                    case .exportSelection:
                        let part = BinderPart(record: request.record, workIDs: ids)
                        let cover = coverText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        model.exportBinder([part], coverText: cover.isEmpty ? nil : cover,
                                           title: name.isEmpty ? nil : name)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            selected = Set(request.info.works.map(\.id))
            title = request.record.title
        }
    }
}

/// Export As Binder with Cover…: the binder's title and a paragraph for
/// its cover page.
struct BinderCoverSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var coverText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export As Binder with Cover")
                .font(.headline)
            TextField("Title", text: $title)
            Text("A paragraph for the cover, before the list of works. A blank line starts a new paragraph.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $coverText)
                .font(.system(size: 13))
                .frame(height: 140)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") {
                    let parts = BinderModel.shared.parts ?? []
                    let cover = coverText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    dismiss()
                    model.exportBinder(parts, coverText: cover.isEmpty ? nil : cover, title: name.isEmpty ? nil : name)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { title = AppModel.defaultBinderTitle }
    }
}

// MARK: - The model's part

extension AppModel {

    /// The works a shelved book declares, read from its unpacked folder;
    /// nil when the book cannot be read at all.
    func epubWorks(for record: EPUBRecord) -> EPUBWorks? {
        EPUBWorks.read(unpackedFolder: Self.unpackedEPUBURL(inFolder: record.folder))
    }

    static var defaultBinderTitle: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return "Binder, \(formatter.string(from: Date()))"
    }

    /// Export Full Document…: the book's own .epub, as it is on the shelf.
    func exportFullDocument(_ record: EPUBRecord) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.epub]
        panel.nameFieldStringValue = record.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".epub"
        panel.canCreateDirectories = true
        panel.message = "Export this book as it is — the whole publication, every article."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try writeEPUBCopy(of: record, to: destination)
            showNote("Exported “\(destination.lastPathComponent)”")
        } catch {
            NSSound.beep()
            showNote("Could not export the EPUB: \(error.localizedDescription)")
        }
    }

    /// Writes a binder — a selection from one book, or a reading list
    /// from several — and puts it on the shelf too. The title is the
    /// one given, else the file name chosen in the save panel.
    func exportBinder(_ parts: [BinderPart], coverText: String?, title: String?) {
        var entries: [(part: BinderPart, folder: URL, info: EPUBWorks)] = []
        for part in parts {
            let folder = Self.unpackedEPUBURL(inFolder: part.record.folder)
            guard let info = EPUBWorks.read(unpackedFolder: folder) else {
                showNote("“\(part.record.title)” could not be read, so it was left out.")
                continue
            }
            entries.append((part, folder, info))
        }
        guard !entries.isEmpty else { NSSound.beep(); return }

        let suggested = title ?? (entries.count == 1 && entries[0].part.workIDs != nil
                                  ? entries[0].part.title(entries[0].info) : Self.defaultBinderTitle)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.epub]
        panel.nameFieldStringValue = suggested.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".epub"
        panel.canCreateDirectories = true
        panel.message = entries.count > 1
            ? "Export these works as one binder — a reading list, each work naming the book it came from."
            : "Export the chosen articles as one binder."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let bindingTitle = title ?? destination.deletingPathExtension().lastPathComponent
        do {
            try EPUBBinderWriter.write(.init(title: bindingTitle, coverText: coverText,
                                             compiler: authorIdentity.name, parts: entries),
                                       to: destination)
            BinderModel.shared.cancel()
            // On the shelf as well, so it reads here at once.
            if let record = importEPUB(at: destination) {
                libraryRevealID = record.id
            }
            showNote("Exported “\(destination.lastPathComponent)”")
        } catch {
            NSSound.beep()
            showNote("Could not write the binder: \(error.localizedDescription)")
        }
    }
}
