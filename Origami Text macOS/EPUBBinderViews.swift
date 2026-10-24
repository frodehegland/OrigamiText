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
                BinderDialog.showChooser(BinderChooserRequest(record: record, info: info, purpose: .exportSelection),
                                         model: model)
            }
        }
        if binder.isActive {
            if binder.contains(record) {
                Button("Remove from Binder") { binder.remove(record) }
            } else if let info, info.hasWorks {
                Button("Add Articles to Binder…") {
                    BinderDialog.showChooser(BinderChooserRequest(record: record, info: info, purpose: .addToBinder),
                                             model: model)
                }
                Button("Add Whole Book to Binder") { binder.add(BinderPart(record: record, workIDs: nil)) }
            } else {
                Button("Add to Binder") { binder.add(BinderPart(record: record, workIDs: nil)) }
            }
        } else {
            Button("New Binder") {
                binder.start()
                // The Binder window first, so the chooser lands over it.
                BinderDialog.showBinder(model: model)
                if let info, info.hasWorks {
                    BinderDialog.showChooser(BinderChooserRequest(record: record, info: info, purpose: .addToBinder),
                                             model: model)
                } else {
                    binder.add(BinderPart(record: record, workIDs: nil))
                }
            }
        }
    }
}

// MARK: - The Binder window

/// The binder being made, in a window of its own: what is in it so far,
/// a minus on each item, and Cancel, Export As Binder, Export As Binder
/// with Cover…. It floats beside the library while the reader
/// control-clicks more books to add them; closing it cancels the binder,
/// and it goes on its own once the binder is exported or cancelled.
struct BinderWindowView: View {
    @Environment(AppModel.self) private var model
    /// Closes the window this view stands in.
    let close: () -> Void
    @State private var isDropTargeted = false
    private var binder: BinderModel { BinderModel.shared }

    var body: some View {
        let parts = binder.parts ?? []
        VStack(alignment: .leading, spacing: 12) {
            Text(parts.isEmpty
                 ? "Control-click books in the library to add them to this binder, or drag them here — from the library or from the Finder. A book of several articles asks which."
                 : "\(parts.count) \(parts.count == 1 ? "item" : "items"). Control-click or drag more books here to add them.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(parts) { part in
                    let title = part.title(model.epubWorks(for: part.record))
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title)
                            // A selection of articles: the book they came from.
                            if part.workIDs != nil, title != part.record.title {
                                Text(part.record.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            binder.remove(part.record)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove from Binder")
                    }
                }
            }
            .frame(height: 240)
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            HStack {
                Button("Cancel") { binder.cancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Export As Binder") { model.exportBinder(parts, coverText: nil, title: nil) }
                    .disabled(parts.isEmpty)
                Button("Export As Binder with Cover…") { BinderDialog.showCover(model: model) }
                    .disabled(parts.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
        // Books dragged in: a library row (its stored .epub) or any file
        // the importer reads. Each is parsed for its articles.
        .dropDestination(for: URL.self) { urls, _ in
            model.addToBinder(dropped: urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        // Exported or cancelled — from here, the menu, or the save
        // panel's success — the window goes with the binder.
        .onChange(of: binder.isActive) { _, active in
            if !active { close() }
        }
    }
}

// MARK: - The dialogs

/// The binder's dialogs are windows of their own, not a bar in the
/// library column or SwiftUI sheets hung off it, which came out
/// compressed and cropped. The Binder window floats beside the library
/// while books are added; the works chooser and the cover dialog are
/// titled, closable panels centred over it. Escape cancels, Return
/// confirms.
@MainActor
enum BinderDialog {
    private static var open: [NSPanel] = []
    private static var closeWatchers: [ObjectIdentifier: NSObjectProtocol] = [:]
    /// The one Binder window, while a binder is being made.
    private static weak var binderPanel: NSPanel?

    /// The Binder window: shown on New Binder, brought forward thereafter.
    static func showBinder(model: AppModel) {
        if let panel = binderPanel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        binderPanel = present(title: "Binder", model: model, floating: true, placement: .besideLibrary,
                              onClose: {
                                  // The red button cancels; an export or Cancel
                                  // has already emptied the binder by now.
                                  if BinderModel.shared.isActive { BinderModel.shared.cancel() }
                              }) { close in
            BinderWindowView(close: close)
        }
    }

    /// Export Selection… or Add Articles to Binder…: which of the book's
    /// articles.
    static func showChooser(_ request: BinderChooserRequest, model: AppModel) {
        _ = present(title: request.purpose == .exportSelection ? "Export Selection" : "Add Articles to Binder",
                    model: model) { close in
            BinderWorksChooser(request: request, close: close)
        }
    }

    /// Export As Binder with Cover…: the binder's title and cover text.
    static func showCover(model: AppModel) {
        _ = present(title: "Export As Binder with Cover", model: model) { close in
            BinderCoverSheet(close: close)
        }
    }

    private enum Placement {
        /// Centred over the library window — a dialog about one thing.
        case overLibrary
        /// To the right of the library window, top-aligned, so the
        /// library stays clear for control-clicking; inside its right
        /// edge when the screen has no room.
        case besideLibrary
    }

    @discardableResult
    private static func present<Content: View>(title: String, model: AppModel,
                                               floating: Bool = false,
                                               placement: Placement = .overLibrary,
                                               onClose: (() -> Void)? = nil,
                                               @ViewBuilder content: (@escaping () -> Void) -> Content) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable],
                            backing: .buffered, defer: false)
        let close: () -> Void = { [weak panel] in panel?.close() }
        let hosting = NSHostingController(rootView: content(close).environment(model))
        // The window takes the view's own size — the fixed width and the
        // list's height — rather than squeezing it.
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        // A floating panel stays over the library while books are
        // clicked, and steps aside with the app.
        panel.isFloatingPanel = floating
        panel.level = floating ? .floating : .normal
        panel.hidesOnDeactivate = floating

        let size = panel.frame.size
        if let main = model.mainNSWindow, main.isVisible {
            switch placement {
            case .overLibrary:
                panel.setFrameOrigin(NSPoint(x: main.frame.midX - size.width / 2,
                                             y: main.frame.midY - size.height / 2))
            case .besideLibrary:
                let screen = (main.screen ?? NSScreen.main)?.visibleFrame
                var x = main.frame.maxX + 12
                if let screen, x + size.width > screen.maxX {
                    x = main.frame.maxX - size.width - 24
                }
                var y = main.frame.maxY - size.height - 48
                if let screen { y = max(screen.minY, min(y, screen.maxY - size.height)) }
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            }
        } else {
            panel.center()
        }

        // Kept alive until it closes, then let go.
        open.append(panel)
        let key = ObjectIdentifier(panel)
        closeWatchers[key] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                onClose?()
                open.removeAll { $0 === panel }
                if let token = closeWatchers.removeValue(forKey: key) {
                    NotificationCenter.default.removeObserver(token)
                }
            }
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        return panel
    }
}

/// Which of a book's articles: for Export Selection…, or to add to the
/// binder. Title and cover text ride along for the export.
struct BinderWorksChooser: View {
    @Environment(AppModel.self) private var model
    let request: BinderChooserRequest
    /// Closes the dialog window this view stands in.
    let close: () -> Void
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
            if request.info.worksInferred {
                Text("The book declares no articles of its own; these are what its level 1 headings mark out. Each is cut from the book at its heading.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            .frame(height: 280)
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
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                Button(request.purpose == .exportSelection ? "Export…" : "Add") {
                    let ids = request.info.works.map(\.id).filter { selected.contains($0) }
                    // The dialog goes first, so the save panel stands alone.
                    close()
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
    /// Closes the dialog window this view stands in.
    let close: () -> Void
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
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") {
                    let parts = BinderModel.shared.parts ?? []
                    let cover = coverText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    close()
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

    /// Files dropped on the Binder window. A shelved book's own .epub
    /// (a library row dragged over) is that book; any other file joins
    /// the library first, as a drop on the Inbox does, since a binder is
    /// made from shelved books. Then, as with the menu: a book of several
    /// articles — declared, or found by its level 1 headings — opens the
    /// chooser; a single work goes in whole.
    func addToBinder(dropped urls: [URL]) {
        if !BinderModel.shared.isActive { BinderModel.shared.start() }
        var pending: [URL] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if ext == "epub" {
                if let record = shelvedRecord(forStoredEPUB: url) {
                    offerToBinder(record)
                } else {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if let record = importEPUB(at: url) { offerToBinder(record) }
                }
            } else if Self.importableExtensions.contains(ext) || ext == "json" {
                pending.append(url)
            } else {
                showNote("“\(url.lastPathComponent)” is not a kind Origami Text can bind.")
            }
        }
        guard !pending.isEmpty else { return }
        // Converted kinds (Word, Markdown, PDF, LaTeX…) report no record
        // of their own and some convert off the main actor, so the shelf
        // is watched for what they add.
        let before = Set(epubRecords.map(\.id))
        openFiles(pending, importing: true)
        Task { @MainActor in
            var offered: Set<String> = []
            for _ in 0..<20 {
                for record in epubRecords where !before.contains(record.id) && !offered.contains(record.id) {
                    offered.insert(record.id)
                    offerToBinder(record)
                }
                if offered.count >= pending.count { break }
                try? await Task.sleep(for: .milliseconds(300))
            }
            if offered.isEmpty {
                showNote("Nothing new reached the library from the drop, so nothing was added to the binder.")
            }
        }
    }

    /// The shelved book whose stored .epub this is, if any.
    private func shelvedRecord(forStoredEPUB url: URL) -> EPUBRecord? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return epubRecords.first {
            Self.storedEPUBURL(inFolder: $0.folder).standardizedFileURL.resolvingSymlinksInPath().path == path
        }
    }

    /// Into the binder, as the menu would put it: the chooser for a
    /// book of articles, else the whole book.
    private func offerToBinder(_ record: EPUBRecord) {
        guard !BinderModel.shared.contains(record) else { return }
        if let info = epubWorks(for: record), info.hasWorks {
            BinderDialog.showChooser(BinderChooserRequest(record: record, info: info, purpose: .addToBinder), model: self)
        } else {
            BinderModel.shared.add(BinderPart(record: record, workIDs: nil))
        }
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
