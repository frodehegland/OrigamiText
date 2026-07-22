import SwiftUI
import CoreLocation
import UniformTypeIdentifiers
import os

private let log = Logger(subsystem: "com.origami.letters", category: "letters")

/// Origami Text for iOS: the letters end of the format. The inbox is
/// the front page — letters from the community, unread first in bold —
/// and New Letter sits at the bottom, opening a composer with the same
/// conventions as writing a letter on the Mac: one paragraph per line,
/// #/##/### headings styled as you type, pasted BibTeX becoming a
/// citation, attention naming who it is for, and the discourse verbs
/// (Respond, Extend, Support, Question, Disagree, Summarize) starting a
/// linked reply from any letter. Publishing writes an ordinary
/// `.origamitext` document — Visual-Meta appendix and all — straight
/// into the community folder, so it is on the Mac the moment the folder
/// syncs. Notes have moved to the Knowledge Space app; the phone now
/// reads and writes letters.
@main
struct OrigamiLettersApp: App {
    @State private var model = LettersModel()

    var body: some Scene {
        WindowGroup {
            LettersHomeView()
                .environment(model)
        }
    }
}

// MARK: - The model

/// The community's letters as the folder holds them, plus the identity
/// a new letter needs. Rescans on demand and when the app returns to
/// the foreground.
@MainActor @Observable
final class LettersModel {
    private(set) var letters: [LiquidDoc] = []
    private(set) var folderURL: URL?

    /// The most recent failure, in words the alert can show. Every path
    /// that could fail silently reports here instead.
    var lastError: String?

    /// A letter the reading view wants opened — set by tapping an
    /// address link in a body; the home view pushes it.
    var requestedLetterID: String?

    private static let bookmarkKey = "communityFolderBookmark"
    private static let authorKey = "authorName"
    private static let readKey = "readLetterIDs"
    private let locationFinder = LocationFinder()

    /// The place the device last resolved — stamped on a letter at
    /// publish, exactly as the Mac stamps letters, honoring the same
    /// "shareGeneralLocation" preference (on unless turned off).
    private(set) var currentPlace: String?

    /// Names from the community folder's People.json — the contact
    /// directory the Mac writes there — offered for attention and for
    /// saying who you are.
    private(set) var knownNames: [String] = []

    /// Which letters this reader has opened — local and private, like
    /// read-state everywhere in Origami Text; never in the shared record.
    private(set) var readIDs: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: LettersModel.readKey) ?? [])

    var authorName: String {
        get { UserDefaults.standard.string(forKey: Self.authorKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.authorKey)
            // Inbox and Sent split on this name — refilter for it.
            rescan()
        }
    }

    init() {
        restoreFolder()
        locationFinder.onPlace = { [weak self] place in
            self?.currentPlace = place
        }
        locationFinder.begin()
    }

    /// Called when a letter is about to be published, so the place is fresh.
    func refreshPlace() {
        locationFinder.begin()
    }

    // MARK: The folder

    func openFolder(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            lastError = "iOS did not grant access to that folder. Please choose it again."
            log.error("openFolder: security scope refused for \(url.path)")
            return
        }
        do {
            let bookmark = try url.bookmarkData()
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        } catch {
            log.error("openFolder: bookmark failed: \(error.localizedDescription)")
        }
        folderURL = url
        rescan()
    }

    private func restoreFolder() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else {
            log.error("restoreFolder: could not resolve or access the saved folder bookmark")
            return
        }
        folderURL = url
        rescan()
    }

    /// Every letter in the community folder, newest first. The phone is
    /// the correspondence end: letters only — bots, trails, glossaries,
    /// transcripts, and the library's other kinds stay on the larger
    /// screens.
    func rescan() {
        guard let folderURL else { return }
        // Documents made elsewhere may exist here only as hidden
        // ".<name>.icloud" placeholders, and asking iCloud for the
        // folder alone does not reliably fetch its contents — ask for
        // each by its real name, so the next rescan (foregrounding,
        // pull-to-refresh) finds what has landed.
        try? FileManager.default.startDownloadingUbiquitousItem(at: folderURL)
        if let placeholders = FileManager.default.enumerator(
            at: folderURL, includingPropertiesForKeys: nil,
            options: [.skipsPackageDescendants]) {
            for case let url as URL in placeholders
            where url.pathExtension.lowercased() == "icloud" {
                var name = url.lastPathComponent
                if name.hasPrefix(".") { name.removeFirst() }
                name = String(name.dropLast(".icloud".count))
                guard !name.isEmpty else { continue }
                let real = url.deletingLastPathComponent().appendingPathComponent(name)
                try? FileManager.default.startDownloadingUbiquitousItem(at: real)
            }
        }
        loadKnownNames(from: folderURL)
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let enumerator = FileManager.default.enumerator(
            at: folderURL, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var found: [LiquidDoc] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == LiquidDoc.fileExtension,
                  let data = try? Data(contentsOf: url),
                  let doc = try? LiquidDoc.decode(data: data, fileURL: url),
                  Self.isLetter(doc)
            else { continue }
            found.append(doc)
        }
        letters = found.sorted { $0.listedDate > $1.listedDate }
    }

    /// The Mac's letter test, mirrored: letters and extracts are
    /// letters; an untyped document is a letter unless it wraps a file
    /// or reads as a transcript.
    nonisolated static func isLetter(_ doc: LiquidDoc) -> Bool {
        if doc.documentType == LiquidDoc.DocumentType.letter.rawValue
            || doc.documentType == LiquidDoc.DocumentType.extract.rawValue { return true }
        guard doc.documentType == nil, doc.wraps == nil else { return false }
        let speaks = (doc.body ?? []).contains { $0.speaker != nil }
        return !speaks
    }

    /// The community's contact directory, as the Mac wrote it. A record
    /// here is decoded leniently — only the name parts matter to the
    /// phone.
    private struct CommunityPerson: Decodable {
        var givenName: String?
        var middleName: String?
        var familyName: String?
        var displayName: String {
            [givenName, middleName, familyName]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
    }

    private func loadKnownNames(from folder: URL) {
        let url = folder.appendingPathComponent("People.json")
        // The folder lives in iCloud; ask for the file in case only its
        // placeholder has synced so far.
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        guard let data = try? Data(contentsOf: url),
              let people = try? JSONDecoder().decode([CommunityPerson].self, from: data)
        else { return }
        knownNames = people.map(\.displayName).filter { !$0.isEmpty }
    }

    // MARK: Letters

    func isOwn(_ doc: LiquidDoc) -> Bool {
        doc.author.trimmingCharacters(in: .whitespaces)
            .caseInsensitiveCompare(authorName.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    /// Letters from the community: everyone else's, newest first.
    var inbox: [LiquidDoc] { letters.filter { !isOwn($0) } }

    /// The user's own letters in the folder.
    var sent: [LiquidDoc] { letters.filter { isOwn($0) } }

    /// Whether a letter asks for this reader's attention by name.
    func isForMe(_ doc: LiquidDoc) -> Bool {
        let mine = authorName.trimmingCharacters(in: .whitespaces)
        guard !mine.isEmpty else { return false }
        return doc.attention.contains { $0.caseInsensitiveCompare(mine) == .orderedSame }
    }

    func isRead(_ doc: LiquidDoc) -> Bool {
        readIDs.contains(doc.id)
    }

    func markRead(_ doc: LiquidDoc) {
        guard readIDs.insert(doc.id).inserted else { return }
        UserDefaults.standard.set(readIDs.sorted(), forKey: Self.readKey)
    }

    var hasUnreadInbox: Bool {
        inbox.contains { !isRead($0) }
    }

    func letter(id: String) -> LiquidDoc? {
        letters.first { $0.id == id }
    }

    /// Publishes a letter into the community folder: file first, on the
    /// record at once, Visual-Meta appendix and all — the same act as
    /// the Mac's publish. Returns nil on failure, with the reason in
    /// `lastError`.
    @discardableResult
    func publishLetter(title: String, bodyText: String,
                       attention: [String], onBehalfOf: String?,
                       date: LiquidDate?,
                       extraLinks: [LiquidDoc.Link],
                       references: [(id: String, bibtex: String)]) -> LiquidDoc? {
        guard let folderURL else {
            lastError = "No community folder is open. Choose the folder first."
            return nil
        }
        guard !authorName.isEmpty else {
            lastError = "Set your name first — a letter carries its author."
            return nil
        }
        let created = Date.now
        let id = LiquidAddress.makeID(author: authorName, created: created) { candidate in
            self.letters.contains { $0.id == candidate }
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let body = LiquidDoc.parseBody(from: bodyText)
        var links = LiquidDoc.detectedLinks(in: body)
        for link in extraLinks where !links.contains(where: { $0.to == link.to && $0.rel == link.rel }) {
            links.append(link)
        }
        // The same preference the Mac honors: letters carry the place
        // they were written unless sharing is turned off.
        let sharePlace = UserDefaults.standard.object(forKey: "shareGeneralLocation") as? Bool ?? true
        var doc = LiquidDoc(format: LiquidDoc.knownFormat,
                            id: id,
                            title: trimmedTitle.isEmpty ? "Untitled" : trimmedTitle,
                            author: authorName,
                            created: created,
                            body: body,
                            links: links,
                            wraps: nil,
                            date: date,
                            documentType: LiquidDoc.DocumentType.letter.rawValue,
                            location: sharePlace ? currentPlace : nil,
                            fileURL: folderURL.appendingPathComponent(id))
        doc.attention = attention
        doc.onBehalfOf = onBehalfOf
        doc.references = references.map { LiquidDoc.Reference(id: $0.id, bibtex: $0.bibtex) }
        let finished = VisualMeta.appendingAppendix(to: doc)
        let named = LiquidDoc(format: finished.format,
                              id: finished.id,
                              title: finished.title,
                              author: finished.author,
                              created: finished.created,
                              body: finished.body,
                              links: finished.links,
                              wraps: nil,
                              date: finished.date,
                              documentType: finished.documentType,
                              location: finished.location,
                              fileURL: folderURL.appendingPathComponent(finished.suggestedExportFileName))
        var complete = named
        complete.attention = finished.attention
        complete.onBehalfOf = finished.onBehalfOf
        complete.references = finished.references
        do {
            try complete.jsonData().write(to: complete.fileURL, options: .atomic)
            letters.insert(complete, at: 0)
            markRead(complete)
            return complete
        } catch {
            lastError = "Could not publish the letter: \(error.localizedDescription)"
            log.error("publishLetter: write failed at \(complete.fileURL.path): \(error.localizedDescription)")
            return nil
        }
    }

    func delete(_ doc: LiquidDoc) {
        guard isOwn(doc) else { return }
        try? FileManager.default.removeItem(at: doc.fileURL)
        letters.removeAll { $0.id == doc.id }
    }
}

/// One-shot place finding: current location, reverse-geocoded to the
/// most natural short name — sublocality, locality, and country where
/// the placemark has them ("Wimbledon, London, United Kingdom"), per
/// the format's location convention.
private final class LocationFinder: NSObject, CLLocationManagerDelegate {
    var onPlace: (@MainActor (String) -> Void)?
    private let manager = CLLocationManager()

    func begin() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.requestWhenInUseAuthorization()
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task {
            guard let placemark = try? await CLGeocoder()
                .reverseGeocodeLocation(location).first else { return }
            let parts = [placemark.subLocality, placemark.locality, placemark.country]
                .compactMap { $0 }
            let place = parts.isEmpty
                ? (placemark.name ?? placemark.administrativeArea ?? "")
                : parts.joined(separator: ", ")
            guard !place.isEmpty else { return }
            await MainActor.run { [onPlace] in onPlace?(place) }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // No place, no field — the letter simply travels without one.
    }
}

// MARK: - The home view

/// The inbox, front and center: the community's letters, unread in
/// bold, letters asking for your attention marked. Sent shows your own.
/// New Letter sits at the bottom; the gear covers the folder and the
/// name.
struct LettersHomeView: View {
    @Environment(LettersModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var box: Box = .inbox
    @State private var path: [String] = []
    @State private var choosingFolder = false
    @State private var namingSelf = false
    @State private var typedName = ""
    @State private var composing: LetterSeed?
    @State private var settingUp = false

    private enum Box: String, CaseIterable {
        case inbox = "Inbox"
        case sent = "Sent"
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.folderURL == nil {
                    ContentUnavailableView {
                        Label("No Community Folder", systemImage: "folder")
                    } description: {
                        Text("Choose the folder your community shares. Letters arrive here as it syncs, and letters you write are published into it.")
                    } actions: {
                        Button("Choose Folder…") { choosingFolder = true }
                    }
                } else {
                    lettersList
                }
            }
            .navigationTitle(box.rawValue)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Box", selection: $box) {
                        ForEach(Box.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }
            }
            .navigationDestination(for: String.self) { id in
                LetterReadingView(docID: id, compose: { composing = $0 })
            }
            // The two doors at the bottom: set up, and write. New Letter
            // waits for a folder and a name; the gear is always open.
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button {
                        settingUp = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.title2)
                    }
                    .accessibilityLabel("Set Up")

                    Spacer()

                    Button {
                        model.refreshPlace()
                        composing = LetterSeed()
                    } label: {
                        Label("New Letter", systemImage: "square.and.pencil")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.folderURL == nil || model.authorName.isEmpty)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
        .confirmationDialog("Set Up", isPresented: $settingUp) {
            Button("Choose Shared Folder…") { choosingFolder = true }
            Button("Pick Your Name…") {
                typedName = model.authorName
                namingSelf = true
            }
        } message: {
            Text("Pick the folder your community shares, or say who you are — letters carry your name as their author.")
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.openFolder(url) }
        }
        .sheet(item: $composing) { seed in
            LetterComposerView(seed: seed)
        }
        .alert("Your Name", isPresented: $namingSelf) {
            TextField("Name, as usually written", text: $typedName)
            ForEach(model.knownNames, id: \.self) { name in
                Button(name) { model.authorName = name }
            }
            Button("Done") {
                model.authorName = typedName.trimmingCharacters(in: .whitespaces)
            }
        } message: {
            Text("Letters carry your name as their author — it is how the community knows they are yours, and how the inbox knows what is for you.")
        }
        .alert("Something Went Wrong", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                model.rescan()
                model.refreshPlace()
            }
        }
        // A tapped address link inside a letter asks for another letter.
        .onChange(of: model.requestedLetterID) {
            guard let id = model.requestedLetterID else { return }
            model.requestedLetterID = nil
            if model.letter(id: id) != nil { path.append(id) }
        }
        .onAppear {
            if model.authorName.isEmpty { namingSelf = true }
        }
    }

    private var shownLetters: [LiquidDoc] {
        box == .inbox ? model.inbox : model.sent
    }

    private var lettersList: some View {
        List {
            ForEach(shownLetters) { doc in
                NavigationLink(value: doc.id) {
                    row(for: doc)
                }
                .swipeActions {
                    if model.isOwn(doc) {
                        Button("Delete", role: .destructive) { model.delete(doc) }
                    }
                }
            }
        }
        .overlay {
            if shownLetters.isEmpty {
                ContentUnavailableView(
                    box == .inbox ? "No Letters Yet" : "Nothing Sent Yet",
                    systemImage: box == .inbox ? "tray" : "paperplane",
                    description: Text(box == .inbox
                        ? "Letters from the community appear here as the folder syncs."
                        : "Write a letter — publishing puts it in the folder for everyone."))
            }
        }
        .refreshable { model.rescan() }
    }

    private func row(for doc: LiquidDoc) -> some View {
        let unread = box == .inbox && !model.isRead(doc)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(doc.title)
                    .fontWeight(unread ? .bold : .medium)
                    .lineLimit(1)
                if model.isForMe(doc) {
                    Text("for you")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.tint.opacity(0.15), in: Capsule())
                        .foregroundStyle(.tint)
                }
            }
            Text(byline(for: doc))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func byline(for doc: LiquidDoc) -> String {
        let when = doc.date?.displayText
            ?? doc.created.formatted(date: .abbreviated, time: .shortened)
        let who = box == .inbox ? "\(doc.displayAuthor) · " : ""
        guard let location = doc.location else { return who + when }
        return "\(who)\(when) · \(location)"
    }
}

// MARK: - Reading a letter

/// The letter itself: title, byline with provenance, and the body with
/// headings styled and address links live. The reply family — the same
/// discourse verbs as the Mac — starts a linked letter from here.
struct LetterReadingView: View {
    @Environment(LettersModel.self) private var model
    let docID: String
    /// Hands a prepared composer seed up to the home view's sheet.
    let compose: (LetterSeed) -> Void

    private var doc: LiquidDoc? { model.letter(id: docID) }

    var body: some View {
        Group {
            if let doc {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(doc.title)
                            .font(.system(size: 26, design: .serif))
                        byline(for: doc)
                        provenance(for: doc)
                        Divider()
                        ForEach(bodyParagraphs(of: doc)) { paragraph in
                            Text(paragraph.renderedText)
                                .font(font(for: paragraph))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding()
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            ForEach(DocumentRelation.discourseActions, id: \.self) { relation in
                                if let title = relation.actionTitle {
                                    Button(title) { reply(relation, to: doc) }
                                }
                            }
                        } label: {
                            Image(systemName: "arrowshape.turn.up.left")
                        }
                        .accessibilityLabel("Reply")
                    }
                }
            } else {
                ContentUnavailableView("Letter Not Available", systemImage: "tray",
                                       description: Text("This letter is no longer in the folder."))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        // An address link in the body opens that letter, exactly as on
        // the Mac.
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme?.lowercased() == "origamitext" else { return .systemAction }
            let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !id.isEmpty { model.requestedLetterID = id }
            return .handled
        })
        .onAppear {
            if let doc { model.markRead(doc) }
        }
    }

    /// Starts the linked reply: the same act as the Mac's discourse
    /// menu — a titled draft carrying the relation to this letter.
    private func reply(_ relation: DocumentRelation, to doc: LiquidDoc) {
        guard let prefix = relation.titlePrefix else { return }
        model.refreshPlace()
        compose(LetterSeed(
            title: "\(prefix)\(doc.title)",
            link: LiquidDoc.Link(to: doc.id, fragment: nil, rel: relation.rawValue),
            linkedTitle: doc.title,
            attention: [doc.author]))
    }

    private func bodyParagraphs(of doc: LiquidDoc) -> [LiquidDoc.Paragraph] {
        let appendixIDs = doc.visualMetaParagraphIDs
        return (doc.body ?? []).filter { !appendixIDs.contains($0.id) }
    }

    private func font(for paragraph: LiquidDoc.Paragraph) -> Font {
        switch paragraph.effectiveHeading {
        case 1: .system(size: 24, weight: .bold, design: .serif)
        case 2: .system(size: 21, weight: .bold, design: .serif)
        case 3: .system(size: 18, weight: .semibold, design: .serif)
        default: .system(size: 17, design: .serif)
        }
    }

    private func byline(for doc: LiquidDoc) -> some View {
        var parts: [String] = []
        if let onBehalfOf = doc.onBehalfOf {
            parts.append("\(doc.displayAuthor) on behalf of \(onBehalfOf)")
        } else {
            parts.append(doc.displayAuthor)
        }
        parts.append(doc.date?.displayText
                     ?? doc.created.formatted(date: .abbreviated, time: .shortened))
        if let location = doc.location { parts.append(location) }
        if !doc.attention.isEmpty {
            parts.append("attn " + doc.attention.joined(separator: ", "))
        }
        return Text(parts.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// The discourse this letter declares — "Responding to <title>",
    /// tappable when the original is here.
    @ViewBuilder
    private func provenance(for doc: LiquidDoc) -> some View {
        let relations = doc.links.compactMap { link -> (label: String, id: String)? in
            guard let relation = DocumentRelation.from(rel: link.rel),
                  let label = relation.bylineLabel else { return nil }
            let target = model.letter(id: LiquidAddress.canonical(link.to))
            return (label: "\(label) “\(target?.title ?? link.to)”", id: LiquidAddress.canonical(link.to))
        }
        if !relations.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(relations, id: \.id) { relation in
                    Button {
                        model.requestedLetterID = relation.id
                    } label: {
                        Text(relation.label)
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
