//
//  OverviewReadingScreen.swift
//  Origami Text
//
//  Designed by Frode Hegland.
//  Copyright © 2026 Frode Alexander Hegland. All rights reserved.
//
//  Overview: the book seen as Author's Overview sees a document. Section by
//  section, the heading, then what the section holds that a skimming reader
//  looks for — a picture for each person, place, organisation and concept
//  it mentions, the names and concepts themselves, its Marked lines, its
//  bold, the reader's own highlights and comments, and the works it cites.
//  Every heading, line and picture is a click back into the reading at
//  that place.
//
//  The same rules and the same settings as Author's Overview (Settings →
//  Views → Outline there; Settings →
//  Overview here), so a book reads the same way in both. Pictures come
//  from OverviewPictures.swift, ported from Author.
//
//  A whole-page mode like the AI readings: `AppModel.readingOverviewOn`
//  puts it up, any mode word at the foot takes it down.
//

import SwiftUI
import AppKit

// MARK: - Settings

/// What Overview shows. Each mirrors a setting in Author's Overview.
enum OverviewSettings {
    /// People, places and organisations found in each section (Author:
    /// Outline → Names).
    static let namesKey = "overviewShowNames"
    /// The book's defined concepts that occur in each section (Author:
    /// Outline → Defined Concepts).
    static let conceptsKey = "overviewShowConcepts"
    /// Text the author Marked (Author: Overview → Marked Text).
    static let markedKey = "overviewShowMarked"
    /// Bold text (Author: Overview → Bold Text).
    static let boldKey = "overviewShowBold"
    /// The reader's own highlights, in the place of Author's highlights.
    static let highlightsKey = "overviewShowHighlights"
    /// The reader's own comments, in the place of Author's comment text.
    static let commentsKey = "overviewShowComments"
    /// The works each section cites.
    static let citationsKey = "overviewShowCitations"
    /// Headings drawn lighter, so the content under them leads (Author:
    /// Overview → Lighter Headings).
    static let lighterHeadingsKey = "overviewLighterHeadings"
}

// MARK: - Reading the inline markup

/// The importer's inline conventions (OrigamiEPUBImport.inlineText):
/// `**bold**`, `*italic*`, `==marked==`, `[cite:KEY]`, `[note:id]`,
/// `[inote:id]`, `[text](url)`.
nonisolated enum OverviewInline {

    private static let marked = try? NSRegularExpression(pattern: #"==(.+?)=="#)
    private static let bold = try? NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#)
    private static let cite = try? NSRegularExpression(pattern: #"\[cite:([^\]]+)\]"#)
    private static let notes = try? NSRegularExpression(pattern: #"\[(?:note|inote):[^\]]*\]"#)
    private static let link = try? NSRegularExpression(pattern: #"\[([^\]]*)\]\([^)]*\)"#)

    static func spans(_ expression: NSRegularExpression?, in text: String) -> [String] {
        guard let expression else { return [] }
        let ns = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { plain(ns.substring(with: $0.range(at: 1))) }
            .filter { !$0.isEmpty }
    }

    static func markedSpans(in text: String) -> [String] { spans(marked, in: text) }
    static func boldSpans(in text: String) -> [String] { spans(bold, in: text) }
    static func citationKeys(in text: String) -> [String] { spans(cite, in: text) }

    /// The words alone, as a person reads them — what the name finder sees.
    static func plain(_ text: String) -> String {
        var result = text
        for expression in [cite, notes] {
            guard let expression else { continue }
            result = expression.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: (result as NSString).length),
                                                         withTemplate: "")
        }
        if let link {
            result = link.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: (result as NSString).length),
                                                   withTemplate: "$1")
        }
        for mark in ["**", "==", "`"] {
            result = result.replacingOccurrences(of: mark, with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - The screen

struct OverviewReadingScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppSettings.readerThemeKey) private var themeRaw = ReaderTheme.highContrast.rawValue
    @AppStorage(ThemeColorOverrides.tickKey) private var themeEditTick = 0

    @AppStorage(OverviewSettings.namesKey) private var showNames = true
    @AppStorage(OverviewSettings.conceptsKey) private var showConcepts = true
    @AppStorage(OverviewSettings.markedKey) private var showMarked = true
    @AppStorage(OverviewSettings.boldKey) private var showBold = true
    @AppStorage(OverviewSettings.highlightsKey) private var showHighlights = true
    @AppStorage(OverviewSettings.commentsKey) private var showComments = true
    @AppStorage(OverviewSettings.citationsKey) private var showCitations = false
    @AppStorage(OverviewSettings.lighterHeadingsKey) private var lighterHeadings = false
    /// The reader's body face and size (Settings ▸ Reading ▸ Fonts,
    /// ⌘⇧+/⌘⇧−), which the names line is set in.
    @AppStorage(AppSettings.readerBodyFontKey) private var bodyFontName = ReaderStyle.defaultBodyFont
    @AppStorage("readingFontDelta") private var fontDelta = 3.0

    let doc: LiquidDoc

    /// The names in each section, by section id; empty until found.
    @State private var entities: [String: [OverviewEntity]] = [:]
    /// Bumped as pictures arrive or change, so the strips redraw.
    @State private var pictureTick = 0

    private var readerTheme: ReaderTheme {
        _ = themeEditTick
        return ReaderTheme(rawValue: themeRaw) ?? .highContrast
    }

    private var sections: [OrigamiSection] { OrigamiSection.build(from: doc) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                header
                ForEach(sections) { section in
                    sectionView(section)
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .background(readerTheme.background(for: colorScheme) ?? Color(nsColor: .textBackgroundColor))
        .foregroundStyle(readerTheme.textColor(for: colorScheme) ?? Color(nsColor: .labelColor))
        .task(id: doc.id) { await findNames() }
        .task {
            for await _ in NotificationCenter.default.notifications(named: OverviewPictureStore.changed) {
                pictureTick += 1
            }
        }
    }

    private var header: some View {
        Text("Overview")
            .font(.title2.weight(.semibold))
    }

    // MARK: A section

    @ViewBuilder
    private func sectionView(_ section: OrigamiSection) -> some View {
        let indent = CGFloat(max(0, section.level - 1)) * 22
        let body = section.paragraphs.filter { $0.effectiveHeading == nil }

        VStack(alignment: .leading, spacing: 6) {
            if let heading = section.heading {
                Button { open(heading.id) } label: {
                    Text(OverviewInline.plain(heading.text))
                        .font(headingFont(section.level))
                        .opacity(lighterHeadings ? 0.5 : 1)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .help("Go to this section")
            }

            pictureStrip(for: section)

            let names = nameLine(for: section, body: body)
            if !names.characters.isEmpty {
                Text(names)
                    .font(bodyFont)
                    .multilineTextAlignment(.leading)
            }

            if showMarked {
                lines(body.flatMap { paragraph in
                    OverviewInline.markedSpans(in: paragraph.text).map { (paragraph.id, $0) }
                }, font: .body)
            }
            if showBold {
                lines(body.flatMap { paragraph in
                    OverviewInline.boldSpans(in: paragraph.text).map { (paragraph.id, $0) }
                }, font: .body.weight(.semibold))
            }
            if showHighlights || showComments {
                annotationLines(for: body)
            }
            if showCitations {
                let keys = body.flatMap { OverviewInline.citationKeys(in: $0.text) }
                let unique = keys.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                ForEach(unique, id: \.self) { key in
                    Text(citationLine(forKey: key))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, indent)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.semibold)
        case 2: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }

    private func lines(_ items: [(String, String)], font: Font) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            Button { open(item.0) } label: {
                Text(item.1)
                    .font(font)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }

    /// The reading's body font, as the reading view sets body text.
    private var bodyFont: Font {
        Font.custom(bodyFontName, size: max(NSFont.preferredFont(forTextStyle: .body).pointSize + fontDelta, 8))
    }

    /// People, places and organisations, then the book's concepts — as
    /// Author's Overview lists names and defined concepts on one line —
    /// each kind in its own style: people italic, places bold,
    /// organisations bold italic, concepts plain.
    private func nameLine(for section: OrigamiSection, body: [LiquidDoc.Paragraph]) -> AttributedString {
        var names: [(name: String, kind: OverviewEntityKind)] = []
        if showNames {
            names += (entities[section.id] ?? []).filter { $0.kind != .concept }.map { ($0.name, $0.kind) }
        }
        if showConcepts {
            for paragraph in body {
                for concept in OrigamiReading.concepts(in: paragraph, of: doc)
                where !names.contains(where: { $0.name == concept.name }) {
                    names.append((concept.name, concept.tag == "person" ? .person : .concept))
                }
            }
        }
        var line = AttributedString()
        for (position, item) in names.enumerated() {
            if position > 0 { line += AttributedString(", ") }
            var name = AttributedString(item.name)
            switch item.kind {
            case .person: name.font = bodyFont.italic()
            case .place: name.font = bodyFont.bold()
            case .organization: name.font = bodyFont.bold().italic()
            case .concept: name.font = bodyFont
            }
            line += name
        }
        return line
    }

    @ViewBuilder
    private func annotationLines(for body: [LiquidDoc.Paragraph]) -> some View {
        let ids = Set(body.map { fragment($0.id) })
        let resolved = model.resolvedAnnotations(for: doc).filter { item in
            guard let paragraphID = item.resolution?.paragraphID else { return false }
            return ids.contains(fragment(paragraphID))
        }
        ForEach(resolved) { item in
            let motivation = item.annotation.motivation
            if motivation == WebAnnotation.Motivation.highlighting, showHighlights,
               let exact = item.resolution?.exact, !exact.isEmpty {
                Button { open(item.resolution?.paragraphID ?? "") } label: {
                    Text(exact)
                        .padding(.horizontal, 3)
                        .background(Color.yellow.opacity(0.35), in: RoundedRectangle(cornerRadius: 3))
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
            } else if motivation == WebAnnotation.Motivation.commenting, showComments,
                      let comment = item.annotation.body?.value, !comment.isEmpty {
                Button { open(item.resolution?.paragraphID ?? "") } label: {
                    Text(comment)
                        .italic()
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func fragment(_ id: String) -> String {
        String(id.split(separator: "#", omittingEmptySubsequences: false).last ?? Substring(id))
    }

    private func citationLine(forKey key: String) -> String {
        guard let reference = doc.references.first(where: { $0.id == key }) else { return key }
        let record = BibTeXRecord.records(in: reference.bibtex).first
        var parts: [String] = []
        if let title = record?.title, !title.isEmpty { parts.append(title) }
        let credit = [record?.displayAuthors ?? "", record?.year ?? ""]
            .filter { !$0.isEmpty }.joined(separator: ", ")
        if !credit.isEmpty { parts.append(credit) }
        return parts.isEmpty ? (reference.citedAs ?? key) : parts.joined(separator: " \u{2014} ")
    }

    // MARK: Pictures

    @ViewBuilder
    private func pictureStrip(for section: OrigamiSection) -> some View {
        let store = OverviewPictureStore.shared
        let pictures: [(entity: OverviewEntity, image: NSImage, record: OverviewPictureRecord)] = {
            _ = pictureTick
            guard store.isEnabled else { return [] }
            return (entities[section.id] ?? []).compactMap { entity in
                store.picture(for: entity).map { (entity, $0.image, $0.record) }
            }
        }()
        if !pictures.isEmpty {
            HStack(spacing: 6) {
                ForEach(pictures.prefix(10), id: \.entity.key) { picture in
                    let side: CGFloat = 30
                    let title = picture.record.title ?? picture.entity.name
                    Button { open(picture.entity.anchor) } label: {
                        Image(nsImage: picture.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: side, height: side)
                            .clipShape(RoundedRectangle(cornerRadius: picture.entity.kind == .person ? side / 2 : 5))
                    }
                    .buttonStyle(.plain)
                    .help([title, picture.record.summary].compactMap { $0 }.joined(separator: " — ")
                          + "\nPicture from Wikipedia. Click to go to the text.")
                    .accessibilityLabel(title)
                    .contextMenu {
                        Button("Manage Pictures…") { showPicturesWindow() }
                        if let page = picture.record.pageURL, let url = URL(string: page) {
                            Button("Open “\(title)” Source") { NSWorkspace.shared.open(url) }
                        }
                        Button("Wrong Picture — Don’t Show It") { store.hide(picture.entity) }
                        Divider()
                        Button("Turn Off Pictures in Overview") { store.isEnabled = false }
                    }
                }
            }
        }
    }

    // MARK: Finding and going

    /// Finds the names in every section off the main thread, then asks for
    /// their pictures.
    private func findNames() async {
        let sections = self.sections
        let documentText = (doc.body ?? []).map { OverviewInline.plain($0.text) }.joined(separator: "\n")
        let texts: [OverviewSectionText] = sections.map { section in
            let body = section.paragraphs.filter { $0.effectiveHeading == nil }
            var concepts: [(name: String, kind: OverviewEntityKind, anchor: String)] = []
            for paragraph in body {
                for concept in OrigamiReading.concepts(in: paragraph, of: doc)
                where !concepts.contains(where: { $0.name == concept.name }) {
                    concepts.append((concept.name, concept.tag == "person" ? .person : .concept, paragraph.id))
                }
            }
            return OverviewSectionText(paragraphs: body.map { ($0.id, OverviewInline.plain($0.text)) },
                                       concepts: concepts)
        }
        let found = await Task.detached(priority: .utility) {
            OverviewEntities.find(sections: texts)
        }.value
        var bySection: [String: [OverviewEntity]] = [:]
        for (section, names) in zip(sections, found) { bySection[section.id] = names }
        entities = bySection
        OverviewPictureStore.shared.request(found.flatMap { $0 }, documentText: documentText)
    }

    /// Back into the reading at a paragraph or heading.
    private func open(_ id: String) {
        guard !id.isEmpty else { return }
        model.readingOverviewOn = false
        model.pendingReaderFragment = id
    }

    private func showPicturesWindow() {
        var firstMention: [String: OverviewEntity] = [:]
        var order: [String] = []
        var sectionCounts: [String: Int] = [:]
        for section in sections {
            for entity in entities[section.id] ?? [] {
                sectionCounts[entity.key, default: 0] += 1
                if firstMention[entity.key] == nil {
                    firstMention[entity.key] = entity
                    order.append(entity.key)
                }
            }
        }
        OverviewPicturesWindowController.shared.show(entities: order.compactMap { firstMention[$0] },
                                                     sections: sectionCounts,
                                                     documentName: doc.title,
                                                     jump: { id in open(id) })
    }
}

// MARK: - Settings tab

/// Settings → Overview: what the Overview shows, and its pictures — the
/// same choices as Author's Overview.
struct OverviewSettingsView: View {
    @AppStorage(OverviewSettings.namesKey) private var showNames = true
    @AppStorage(OverviewSettings.conceptsKey) private var showConcepts = true
    @AppStorage(OverviewSettings.markedKey) private var showMarked = true
    @AppStorage(OverviewSettings.boldKey) private var showBold = true
    @AppStorage(OverviewSettings.highlightsKey) private var showHighlights = true
    @AppStorage(OverviewSettings.commentsKey) private var showComments = true
    @AppStorage(OverviewSettings.citationsKey) private var showCitations = false
    @AppStorage(OverviewSettings.lighterHeadingsKey) private var lighterHeadings = false

    /// Mirrors the store's own switch, so the toggle redraws.
    @State private var picturesOn = OverviewPictureStore.shared.isEnabled
    @State private var shownKinds = Set(OverviewEntityKind.allCases.filter { OverviewPictureStore.shared.isShown($0) })

    var body: some View {
        Form {
            Section {
                Toggle("Names — people, places, organisations", isOn: $showNames)
                Toggle("Defined concepts", isOn: $showConcepts)
                Toggle("Marked text", isOn: $showMarked)
                Toggle("Bold text", isOn: $showBold)
                Toggle("Your highlights", isOn: $showHighlights)
                Toggle("Your comments", isOn: $showComments)
                Toggle("Citations", isOn: $showCitations)
                Toggle("Lighter headings", isOn: $lighterHeadings)
            } header: {
                Text("Under each heading, show")
            } footer: {
                Text("Overview is at the foot of a book, in the Outline group, and on ⌘−. The same choices as Author's Overview, so a book reads alike in both.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Pictures of people, organisations, places and concepts", isOn: $picturesOn)
                    .onChange(of: picturesOn) { _, on in OverviewPictureStore.shared.isEnabled = on }
                ForEach(OverviewEntityKind.allCases) { kind in
                    Toggle(isOn: Binding(
                        get: { shownKinds.contains(kind) },
                        set: { on in
                            if on { shownKinds.insert(kind) } else { shownKinds.remove(kind) }
                            OverviewPictureStore.shared.setShown(kind, on)
                        })) {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                    .disabled(!picturesOn)
                    .padding(.leading, 16)
                }
                HStack {
                    Button("Manage Pictures…") { OverviewPicturesWindowController.shared.showAll() }
                    Button("Show Hidden Pictures Again") { OverviewPictureStore.shared.forgetHidden() }
                    Button("Clear Picture Cache") { OverviewPictureStore.shared.clearCache() }
                }
            } header: {
                Text("Pictures")
            } footer: {
                Text("Names found in each section are looked up on Wikipedia, and the pictures kept on this Mac for every book — shared with Author, so each is fetched once for both, and clearing the cache clears it for both. People in your People directory show their own photo, and a picture you choose for one of them becomes their People photo. Only the names are sent, never the text. Click a picture to go to its mention; right-click one that is wrong to hide it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
