//
//  OverviewPictures.swift
//  Origami Text
//
//  Designed by Frode Hegland.
//  Copyright © 2026 Frode Alexander Hegland. All rights reserved.
//
//  Pictures for the Overview reading mode: a portrait for each person a
//  section mentions, a logo for each organisation, a photograph for each
//  place and concept — the same rules as Author's Overview, ported from
//  Author (Liquid Author/Table Of Contents/OverviewPictures.swift) so the
//  two agree on what is matched and what is refused. Keep them in step.
//
//  Names are found on this Mac (NaturalLanguage, plus the book's concepts);
//  pictures come from Wikipedia, whose search needs no key, and are cached
//  in Application Support for every book — each name is looked up once.
//  Matching is strict, since a wrong face is worse than none: every part
//  of a person's name must match, an ambiguous place only when its
//  qualifier is in the book, and a novel or film is never a place.
//

import AppKit
import NaturalLanguage
import CryptoKit

// MARK: - Entities

nonisolated enum OverviewEntityKind: String, Codable, CaseIterable, Identifiable {
    case person, place, organization, concept

    var id: String { rawValue }

    /// The category's name in the Pictures window.
    var title: String {
        switch self {
        case .person: return NSLocalizedString("People", comment: "Overview picture category")
        case .place: return NSLocalizedString("Places", comment: "Overview picture category")
        case .organization: return NSLocalizedString("Organisations & Companies", comment: "Overview picture category")
        case .concept: return NSLocalizedString("Concepts", comment: "Overview picture category")
        }
    }

    var symbol: String {
        switch self {
        case .person: return "person.fill"
        case .place: return "map"
        case .organization: return "building.2"
        case .concept: return "lightbulb"
        }
    }
}


/// A name found in a section, and the paragraph it first appears in.
nonisolated struct OverviewEntity: Hashable, Sendable {
    let name: String
    let kind: OverviewEntityKind
    /// The paragraph of the first mention ("P-…" or "H-…"), for Show in
    /// Text; empty for names listed from the store alone.
    let anchor: String

    /// The same name in any section, or any book, is the same picture.
    var key: String { kind.rawValue + ":" + name.lowercased() }
}

/// One section's text, as the name finder reads it.
nonisolated struct OverviewSectionText: Sendable {
    /// Each paragraph's id and its words with the reader's inline markup
    /// taken out.
    let paragraphs: [(id: String, text: String)]
    /// The book's concepts that occur in the section, with where.
    let concepts: [(name: String, kind: OverviewEntityKind, anchor: String)]
}

nonisolated enum OverviewEntities {

    /// Tagger mistakes seen in speech ("geez" as a person) and other words
    /// never worth a picture.
    private static let ignored: Set<String> = [
        "geez", "gee", "jeez", "gosh", "boy", "oh", "hey", "okay", "yeah", "god", "lord", "mom", "dad",
    ]

    /// The names in each section, in the order they first appear. Names
    /// that run through most of the book — an interview's speakers — are
    /// left out: a picture in every section points at nothing.
    static func find(sections: [OverviewSectionText]) -> [[OverviewEntity]] {
        var perSection: [[OverviewEntity]] = []
        var sectionsMentioning: [String: Int] = [:]

        for section in sections {
            var found: [OverviewEntity] = []
            var seen = Set<String>()
            for paragraph in section.paragraphs {
                let text = paragraph.text
                let tagger = NLTagger(tagSchemes: [.nameType])
                tagger.string = text
                tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                                     options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
                    let kind: OverviewEntityKind
                    switch tag {
                    case .personalName?: kind = .person
                    case .placeName?: kind = .place
                    case .organizationName?: kind = .organization
                    default: return true
                    }
                    let name = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard acceptable(name, kind: kind) else { return true }
                    let entity = OverviewEntity(name: name, kind: kind, anchor: paragraph.id)
                    if seen.insert(entity.key).inserted { found.append(entity) }
                    return true
                }
            }
            for concept in section.concepts where concept.name.count >= 3 {
                let entity = OverviewEntity(name: concept.name, kind: concept.kind, anchor: concept.anchor)
                if seen.insert(entity.key).inserted { found.append(entity) }
            }
            for key in seen { sectionsMentioning[key, default: 0] += 1 }
            perSection.append(found)
        }

        guard sections.count >= 4 else { return perSection }
        let limit = sections.count / 2
        return perSection.map { $0.filter { (sectionsMentioning[$0.key] ?? 0) <= limit } }
    }

    private static func acceptable(_ name: String, kind: OverviewEntityKind) -> Bool {
        guard name.count >= 3,
              let first = name.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first),
              !ignored.contains(name.lowercased()) else { return false }
        // A first name alone — "Dave" — could be anyone.
        if kind == .person, name.split(separator: " ").count < 2 { return false }
        return true
    }
}

// MARK: - Store

/// What Wikipedia gave for a name: the article and its picture, or — with
/// no title — that there was nothing safe to show.
nonisolated struct OverviewPictureRecord: Codable, Sendable {
    var title: String?
    var summary: String?
    var file: String?
    var fetched: Date
    // Added with the Pictures window; optional so older caches still read.
    /// The name as written, and its kind — so the window can list every
    /// cached picture, not only this document's.
    var name: String?
    var kind: OverviewEntityKind?
    /// "wikipedia", "commons" or "user".
    var source: String?
    /// Where the picture came from, to open from its menu.
    var pageURL: String?
    /// Deleted by the writer: not looked up again until they ask.
    var deleted: Bool?
}

/// A picture offered in the Pictures window's Find Alternatives.
struct OverviewPictureCandidate: Identifiable {
    let id = UUID()
    let title: String
    let summary: String?
    let source: String
    let pageURL: String?
    let image: NSImage
    let data: Data
    let fileExtension: String
}

extension OverviewEntity: Identifiable {
    var id: String { key }
}

final class OverviewPictureStore {

    static let shared = OverviewPictureStore()

    /// Posted on the main queue as pictures arrive.
    static let changed = Notification.Name("OverviewPicturesChanged")

    private static let enabledKey = "OverviewPicturesEnabled"
    private static let hiddenKey = "OverviewPicturesHidden"
    private static let disabledKindsKey = "OverviewPicturesDisabledKinds"

    /// On unless the writer turns it off — in Settings → Overview, or
    /// from a picture's menu.
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    /// Whole categories switched off in the Pictures window: not shown in
    /// any document, and not looked up. What is cached stays, ready for
    /// the category to come back on.
    var disabledKinds: Set<OverviewEntityKind> {
        get { Set((UserDefaults.standard.stringArray(forKey: Self.disabledKindsKey) ?? []).compactMap(OverviewEntityKind.init(rawValue:))) }
        set {
            UserDefaults.standard.set(newValue.map(\.rawValue), forKey: Self.disabledKindsKey)
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    func isShown(_ kind: OverviewEntityKind) -> Bool {
        !disabledKinds.contains(kind)
    }

    func setShown(_ kind: OverviewEntityKind, _ shown: Bool) {
        if shown { disabledKinds.remove(kind) } else { disabledKinds.insert(kind) }
    }

    /// Names whose picture the writer said was wrong.
    private(set) var hidden: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.hiddenKey) }
    }

    private var index: [String: OverviewPictureRecord] = [:]
    private let images = NSCache<NSString, NSImage>()
    private var queue: [(entity: OverviewEntity, evidence: Set<String>)] = []
    private var queued = Set<String>()
    private var isWorking = false

    /// Nothing is found again for a month; then it is asked once more, in
    /// case the article has gained a picture.
    private let retryNothingAfter: TimeInterval = 30 * 24 * 60 * 60

    /// The App Group Author and Origami Text both belong to (one team), so
    /// a picture found or chosen in one app is there in the other. Keep
    /// this, the folder and the index format the same in both apps.
    static let appGroupIdentifier = "9Q5N4A727S.com.liquid.author.shared"

    private let directory: URL = OverviewPictureStore.pictureDirectory()

    /// The shared group container's "Overview Pictures", else — an app not
    /// in the group — its own Application Support. A store this app kept
    /// before the two shared moves in once, so nothing is fetched twice.
    private static func pictureDirectory() -> URL {
        let fileManager = FileManager.default
        let local = (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory)
            .appendingPathComponent("Overview Pictures", isDirectory: true)
        guard let group = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            try? fileManager.createDirectory(at: local, withIntermediateDirectories: true)
            return local
        }
        let shared = group.appendingPathComponent("Library/Application Support/Overview Pictures",
                                                  isDirectory: true)
        try? fileManager.createDirectory(at: shared, withIntermediateDirectories: true)
        moveLegacyStore(from: local, into: shared)
        return shared
    }

    /// This app's own store, from before the two shared, merged into the
    /// shared one — record by record, the better answer kept — and removed.
    private static func moveLegacyStore(from local: URL, into shared: URL) {
        let fileManager = FileManager.default
        let legacyIndex = local.appendingPathComponent("index.json")
        guard fileManager.fileExists(atPath: legacyIndex.path) else { return }
        let old = readIndex(at: legacyIndex)
        let sharedIndex = shared.appendingPathComponent("index.json")
        var merged = readIndex(at: sharedIndex)
        for (key, record) in old {
            let kept = merged[key].map { preferred($0, record) } ?? record
            if kept.file == record.file, let file = record.file {
                let target = shared.appendingPathComponent(file)
                if !fileManager.fileExists(atPath: target.path) {
                    try? fileManager.moveItem(at: local.appendingPathComponent(file), to: target)
                }
            }
            merged[key] = kept
        }
        guard let data = try? JSONEncoder().encode(merged),
              (try? data.write(to: sharedIndex, options: .atomic)) != nil else { return }
        try? fileManager.removeItem(at: local)
    }

    static func readIndex(at url: URL) -> [String: OverviewPictureRecord] {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([String: OverviewPictureRecord].self, from: data)
        else { return [:] }
        return stored
    }

    /// Of two answers for one name — this app's and the other's — the one
    /// to keep: a deletion or a newer choice wins, and "nothing found"
    /// never wipes out a picture the other app found.
    static func preferred(_ a: OverviewPictureRecord, _ b: OverviewPictureRecord) -> OverviewPictureRecord {
        if a.deleted == true || b.deleted == true { return a.fetched >= b.fetched ? a : b }
        if (a.title != nil) != (b.title != nil) { return a.title != nil ? a : b }
        return a.fetched >= b.fetched ? a : b
    }

    /// When the index on disk was last read or written by this app.
    private var indexDate: Date?

    /// Takes in what the other app has written since this one last looked.
    func refreshFromDisk() {
        let date = (try? FileManager.default.attributesOfItem(atPath: indexURL.path))?[.modificationDate] as? Date
        guard let date, date != indexDate else { return }
        indexDate = date
        var changed = false
        for (key, record) in Self.readIndex(at: indexURL) {
            let kept = index[key].map { Self.preferred($0, record) } ?? record
            if index[key]?.file != kept.file || index[key]?.title != kept.title
                || index[key]?.deleted != kept.deleted {
                if let file = index[key]?.file { images.removeObject(forKey: file as NSString) }
                changed = true
            }
            index[key] = kept
        }
        if changed { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    /// A picture the app already keeps for this name — Origami Text's
    /// People directory — which comes first and is never looked up. Nil
    /// where the app keeps none (Author).
    var ownPicture: ((OverviewEntity) -> NSImage?)?

    /// Told when the writer chooses a picture themselves — Find
    /// Alternatives, Add Your Own — so the app can keep it too.
    var onChosen: ((OverviewEntity, NSImage) -> Void)?

    private func ownRecord(for entity: OverviewEntity) -> OverviewPictureRecord {
        OverviewPictureRecord(title: entity.name,
                              summary: NSLocalizedString("From People", comment: "Overview picture kept in the app's People directory"),
                              file: nil, fetched: Date(), name: entity.name, kind: entity.kind, source: "people")
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    private init() {
        index = Self.readIndex(at: indexURL)
        indexDate = (try? FileManager.default.attributesOfItem(atPath: indexURL.path))?[.modificationDate] as? Date
    }

    /// The picture for a name, if one is cached and not hidden.
    func picture(for entity: OverviewEntity) -> (image: NSImage, record: OverviewPictureRecord)? {
        guard isShown(entity.kind), !hidden.contains(entity.key) else { return nil }
        if let own = ownPicture?(entity) { return (own, ownRecord(for: entity)) }
        guard let record = index[entity.key], let image = storedImage(for: entity) else { return nil }
        return (image, record)
    }

    /// The kept picture whether or not it is in use — for the Pictures
    /// window, which shows what Don't Use would bring back.
    func storedImage(for entity: OverviewEntity) -> NSImage? {
        if let own = ownPicture?(entity) { return own }
        guard let record = index[entity.key], record.title != nil, let file = record.file else { return nil }
        if let image = images.object(forKey: file as NSString) { return image }
        guard let image = NSImage(contentsOf: directory.appendingPathComponent(file)) else { return nil }
        images.setObject(image, forKey: file as NSString)
        return image
    }

    /// Looks up the names not seen before. `documentText` is the evidence
    /// for qualifiers: "Portland, Oregon" only if Oregon is in it.
    func request(_ entities: [OverviewEntity], documentText: String) {
        guard isEnabled else { return }
        refreshFromDisk()
        // Older records lack the name as written and its kind; a document
        // that names them supplies both.
        var filledIn = false
        for entity in entities {
            guard var record = index[entity.key], record.name == nil || record.kind == nil else { continue }
            record.name = entity.name
            record.kind = entity.kind
            if record.source == nil, record.title != nil { record.source = "wikipedia" }
            if record.pageURL == nil, record.source == "wikipedia", let title = record.title {
                record.pageURL = Self.wikipediaURL(for: title)?.absoluteString
            }
            index[entity.key] = record
            filledIn = true
        }
        if filledIn { save() }

        var evidence: Set<String>?
        let disabled = disabledKinds
        for entity in entities where !queued.contains(entity.key) && !hidden.contains(entity.key)
            && !disabled.contains(entity.kind) && ownPicture?(entity) == nil {
            if let record = index[entity.key],
               record.title != nil || record.deleted == true
                || Date().timeIntervalSince(record.fetched) < retryNothingAfter { continue }
            if evidence == nil { evidence = Self.capitalisedWords(in: documentText) }
            queued.insert(entity.key)
            queue.append((entity, evidence ?? []))
        }
        work()
    }

    func hide(_ entity: OverviewEntity) {
        hidden.insert(entity.key)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func forgetHidden() {
        hidden = []
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Deletes every cached picture; they are fetched again when shown.
    func clearCache() {
        index = [:]
        images.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    // MARK: The Pictures window

    func record(for entity: OverviewEntity) -> OverviewPictureRecord? {
        if ownPicture?(entity) != nil { return ownRecord(for: entity) }
        return index[entity.key]
    }

    func isHidden(_ entity: OverviewEntity) -> Bool {
        hidden.contains(entity.key)
    }

    /// "Don't Use" and "Use": the picture is kept either way.
    func setHidden(_ entity: OverviewEntity, _ isHidden: Bool) {
        if isHidden { hidden.insert(entity.key) } else { hidden.remove(entity.key) }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Removes the picture, and marks the name so it is not looked up
    /// again by itself — Find Alternatives or Add Your Own bring one back.
    func delete(_ entity: OverviewEntity) {
        if let file = index[entity.key]?.file {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
            images.removeObject(forKey: file as NSString)
        }
        index[entity.key] = OverviewPictureRecord(title: nil, summary: nil, file: nil, fetched: Date(),
                                                  name: entity.name, kind: entity.kind, deleted: true)
        hidden.remove(entity.key)
        save()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Where the store lives, for the Pictures window to say so.
    var location: URL { directory }

    /// Every name with a cached answer, for the window opened from Settings.
    ///
    /// Records from before the window kept no name or kind; both are in the
    /// key ("person:vannevar bush"), so they are read from there — in
    /// lower case until a document naming it fills in the real spelling.
    var allEntities: [OverviewEntity] {
        index.compactMap { key, record in
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard let kind = record.kind ?? parts.first.flatMap(OverviewEntityKind.init(rawValue:)),
                  let name = record.name ?? (parts.count == 2 ? parts[1].capitalized : nil) else { return nil }
            return OverviewEntity(name: name, kind: kind, anchor: "")
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Pictures for a search, from Wikipedia articles and from Wikimedia
    /// Commons, with nothing filtered out: the writer chooses.
    func alternatives(for query: String) async -> [OverviewPictureCandidate] {
        var candidates: [OverviewPictureCandidate] = []

        var wikipedia = URLComponents(string: "https://en.wikipedia.org/w/api.php")
        wikipedia?.queryItems = [
            .init(name: "action", value: "query"), .init(name: "format", value: "json"),
            .init(name: "formatversion", value: "2"), .init(name: "redirects", value: "1"),
            .init(name: "generator", value: "search"), .init(name: "gsrsearch", value: query),
            .init(name: "gsrlimit", value: "10"), .init(name: "prop", value: "pageimages|description|pageprops"),
            .init(name: "piprop", value: "thumbnail"), .init(name: "pithumbsize", value: "160"),
            .init(name: "ppprop", value: "disambiguation"),
        ]
        if let url = wikipedia?.url, let data = await Self.get(url) {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let pages = ((json?["query"] as? [String: Any])?["pages"] as? [[String: Any]] ?? [])
                .sorted { ($0["index"] as? Int ?? 99) < ($1["index"] as? Int ?? 99) }
            for page in pages where page["pageprops"] == nil {
                guard let title = page["title"] as? String,
                      let source = (page["thumbnail"] as? [String: Any])?["source"] as? String,
                      let url = URL(string: source),
                      let candidate = await Self.candidate(from: url, title: title,
                                                           summary: page["description"] as? String,
                                                           source: "wikipedia",
                                                           pageURL: Self.wikipediaURL(for: title)?.absoluteString) else { continue }
                candidates.append(candidate)
            }
        }

        var commons = URLComponents(string: "https://commons.wikimedia.org/w/api.php")
        commons?.queryItems = [
            .init(name: "action", value: "query"), .init(name: "format", value: "json"),
            .init(name: "formatversion", value: "2"), .init(name: "generator", value: "search"),
            .init(name: "gsrsearch", value: query), .init(name: "gsrnamespace", value: "6"),
            .init(name: "gsrlimit", value: "12"), .init(name: "prop", value: "imageinfo"),
            .init(name: "iiprop", value: "url|mime"), .init(name: "iiurlwidth", value: "160"),
        ]
        if let url = commons?.url, let data = await Self.get(url) {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let pages = ((json?["query"] as? [String: Any])?["pages"] as? [[String: Any]] ?? [])
                .sorted { ($0["index"] as? Int ?? 99) < ($1["index"] as? Int ?? 99) }
            for page in pages {
                guard let info = (page["imageinfo"] as? [[String: Any]])?.first,
                      (info["mime"] as? String)?.hasPrefix("image/") == true,
                      let thumb = info["thumburl"] as? String, let url = URL(string: thumb),
                      let fileTitle = page["title"] as? String else { continue }
                let title = fileTitle
                    .replacingOccurrences(of: "File:", with: "")
                    .replacingOccurrences(of: "_", with: " ")
                    .components(separatedBy: ".").dropLast().joined(separator: ".")
                guard let candidate = await Self.candidate(from: url, title: title, summary: nil,
                                                           source: "commons",
                                                           pageURL: info["descriptionurl"] as? String) else { continue }
                candidates.append(candidate)
            }
        }
        return candidates
    }

    private static func candidate(from url: URL, title: String, summary: String?, source: String,
                                  pageURL: String?) async -> OverviewPictureCandidate? {
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard let data = await get(url), let image = NSImage(data: data) else { return nil }
        return OverviewPictureCandidate(title: title, summary: summary, source: source, pageURL: pageURL,
                                        image: image, data: data,
                                        fileExtension: url.pathExtension.isEmpty ? "jpg" : url.pathExtension.lowercased())
    }

    /// Uses a picture the writer chose from the alternatives.
    func use(_ candidate: OverviewPictureCandidate, for entity: OverviewEntity) {
        store(candidate.data, extension: candidate.fileExtension, for: entity,
              title: candidate.title, summary: candidate.summary, source: candidate.source, pageURL: candidate.pageURL)
        onChosen?(entity, candidate.image)
    }

    /// Uses the writer's own picture — a file chosen or dropped. Scaled down
    /// and kept as PNG, so a large photograph does not bloat the cache.
    @discardableResult
    func useOwn(_ image: NSImage, for entity: OverviewEntity) -> Bool {
        let side: CGFloat = 240
        let scale = min(1, side / max(image.size.width, image.size.height, 1))
        let size = NSSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        store(png, extension: "png", for: entity, title: entity.name,
              summary: NSLocalizedString("Your picture", comment: "Overview picture chosen by the writer"),
              source: "user", pageURL: nil)
        onChosen?(entity, image)
        return true
    }

    private func store(_ data: Data, extension fileExtension: String, for entity: OverviewEntity,
                       title: String, summary: String?, source: String, pageURL: String?) {
        if let old = index[entity.key]?.file {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(old))
            images.removeObject(forKey: old as NSString)
        }
        // A fresh name each time, so nothing cached under the old one shows.
        let file = UUID().uuidString + "." + fileExtension
        guard (try? data.write(to: directory.appendingPathComponent(file), options: .atomic)) != nil else { return }
        index[entity.key] = OverviewPictureRecord(title: title, summary: summary, file: file, fetched: Date(),
                                                  name: entity.name, kind: entity.kind, source: source, pageURL: pageURL)
        hidden.remove(entity.key)
        save()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    static func wikipediaURL(for title: String) -> URL? {
        guard let encoded = title.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://en.wikipedia.org/wiki/" + encoded)
    }

    // MARK: Fetching

    /// One lookup at a time, a little apart, until the queue is empty.
    private func work() {
        guard !isWorking, !queue.isEmpty else { return }
        isWorking = true
        Task { @MainActor in
            while !queue.isEmpty, isEnabled {
                let (entity, evidence) = queue.removeFirst()
                let record = await Self.lookUp(entity, evidence: evidence, into: directory)
                queued.remove(entity.key)
                // A failed request (offline, refused) records nothing, so it
                // is tried again next time rather than remembered as absent.
                guard let record else { continue }
                index[entity.key] = record
                save()
                if record.title != nil {
                    NotificationCenter.default.post(name: Self.changed, object: nil)
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            isWorking = false
        }
    }

    /// The other app writes the same index: what it wrote since is taken
    /// in first, the better answer for each name kept, then all written.
    private func save() {
        for (key, record) in Self.readIndex(at: indexURL) {
            index[key] = index[key].map { Self.preferred($0, record) } ?? record
        }
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
        indexDate = (try? FileManager.default.attributesOfItem(atPath: indexURL.path))?[.modificationDate] as? Date
    }

    private static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        return "OrigamiText/\(version) (macOS reader; Overview pictures)"
    }()

    /// Fetches with backoff: Wikipedia answers 429 when asked too fast.
    static func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        var delay: UInt64 = 2
        for _ in 0..<4 {
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 200 { return data }
            guard http.statusCode == 429 || http.statusCode >= 500 else { return nil }
            let retryAfter = UInt64(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? delay
            try? await Task.sleep(nanoseconds: min(retryAfter, 60) * 1_000_000_000)
            delay *= 2
        }
        return nil
    }

    /// Nil when the question could not be asked; a record with no title
    /// when it was asked and nothing safe came back.
    private static func lookUp(_ entity: OverviewEntity, evidence: Set<String>, into directory: URL) async -> OverviewPictureRecord? {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")
        components?.queryItems = [
            .init(name: "action", value: "query"), .init(name: "format", value: "json"),
            .init(name: "formatversion", value: "2"), .init(name: "redirects", value: "1"),
            .init(name: "generator", value: "search"), .init(name: "gsrsearch", value: entity.name),
            .init(name: "gsrlimit", value: "6"), .init(name: "prop", value: "pageimages|description|pageprops"),
            .init(name: "piprop", value: "thumbnail"), .init(name: "pithumbsize", value: "120"),
            .init(name: "ppprop", value: "disambiguation"),
        ]
        guard let url = components?.url, let data = await get(url) else { return nil }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let pages = ((json?["query"] as? [String: Any])?["pages"] as? [[String: Any]] ?? [])
            .sorted { ($0["index"] as? Int ?? 99) < ($1["index"] as? Int ?? 99) }

        let nothing = OverviewPictureRecord(title: nil, summary: nil, file: nil, fetched: Date(),
                                            name: entity.name, kind: entity.kind)
        guard let page = pages.first(where: { OverviewMatcher.accepts($0, for: entity, evidence: evidence) }),
              let title = page["title"] as? String,
              let source = (page["thumbnail"] as? [String: Any])?["source"] as? String,
              let imageURL = URL(string: source) else { return nothing }

        try? await Task.sleep(nanoseconds: 250_000_000)
        guard let imageData = await get(imageURL), NSImage(data: imageData) != nil else { return nil }
        let file = SHA256.hash(data: Data(entity.key.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
            + "." + (imageURL.pathExtension.isEmpty ? "jpg" : imageURL.pathExtension.lowercased())
        do {
            try imageData.write(to: directory.appendingPathComponent(file), options: .atomic)
        } catch {
            return nil
        }
        return OverviewPictureRecord(title: title, summary: page["description"] as? String, file: file, fetched: Date(),
                                     name: entity.name, kind: entity.kind, source: "wikipedia",
                                     pageURL: wikipediaURL(for: title)?.absoluteString)
    }

    static func capitalisedWords(in text: String) -> Set<String> {
        var words = Set<String>()
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, _, _, _ in
            if let word, let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) {
                words.insert(word)
            }
        }
        return words
    }
}

// MARK: - Matching

/// Whether a Wikipedia search result really is the thing named.
nonisolated enum OverviewMatcher {

    /// A result described as one of these is never a person or a place.
    private static let media = ["novel", "film", "song", "album", "book", "episode", "television series",
                                "tv series", "band", "video game", "play by", "musical", "opera", "poem"]

    private static let honorifics: Set<String> = ["dr", "mr", "mrs", "ms", "prof", "sir", "dame", "st"]
    private static let minorWords: Set<String> = ["of", "for", "the", "and", "in", "on", "at", "de", "&"]

    static func accepts(_ page: [String: Any], for entity: OverviewEntity, evidence: Set<String>) -> Bool {
        guard page["pageprops"] == nil,                        // a disambiguation page
              page["thumbnail"] != nil,
              let title = page["title"] as? String else { return false }

        let summary = (page["description"] as? String ?? "").lowercased()
        if entity.kind != .concept, media.contains(where: { summary.contains($0) }) { return false }

        // "Portland, Oregon" → core "Portland", qualifier "Oregon";
        // "Washington (state)" → core "Washington", qualifier "state".
        var core = title
        var qualifier: String?
        if let open = title.range(of: " ("), title.hasSuffix(")") {
            core = String(title[..<open.lowerBound])
            qualifier = String(title[open.upperBound..<title.index(before: title.endIndex)])
        } else if let comma = title.range(of: ", ") {
            core = String(title[..<comma.lowerBound])
            qualifier = String(title[comma.upperBound...])
        }

        // A qualifier must be named in the document, and be a name: "state"
        // or "computer system" is no evidence which one is meant.
        if let qualifier {
            let parts = qualifier.split(separator: " ").map(String.init)
            let names = parts.filter { $0.first?.isUppercase == true }
            guard !names.isEmpty,
                  names.allSatisfy({ evidence.contains($0.trimmingCharacters(in: .punctuationCharacters)) }) else { return false }
        }

        let query = words(entity.name).filter { !honorifics.contains($0) }
        let found = words(core)
        guard !query.isEmpty, !found.isEmpty else { return false }

        switch entity.kind {
        case .person:
            // Every part matches, allowing a short form (Doug → Douglas) and
            // one extra middle name; the family name must be exact.
            guard found.count >= query.count, found.count <= query.count + 1,
                  query.last == found.last else { return false }
            return query.dropLast().allSatisfy { part in
                found.contains { $0 == part || (part.count >= 3 && $0.hasPrefix(part)) || (($0.count >= 3) && part.hasPrefix($0)) }
            }
        case .place, .organization, .concept:
            if found == query { return true }
            // NACA → National Advisory Committee for Aeronautics.
            if entity.name.count >= 2, entity.name.count <= 6, entity.name == entity.name.uppercased() {
                let initials = String(found.filter { !minorWords.contains($0) }.compactMap(\.first))
                if initials == entity.name.lowercased() { return true }
            }
            // SRI → SRI International.
            if entity.kind == .organization, found.count == query.count + 1,
               Array(found.prefix(query.count)) == query { return true }
            return false
        }
    }

    private static func words(_ string: String) -> [String] {
        string.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "&'’")).inverted)
            .filter { !$0.isEmpty }
    }
}

