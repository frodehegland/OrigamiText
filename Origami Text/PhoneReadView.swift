import SwiftUI
import WebKit
import UniformTypeIdentifiers

// The phone's reading end, based on the visionOS reader: the shelf as
// Articles and Journals, books arriving from Files or the community
// folder, and a reader with the same views — Default (the EPUB's own
// pages), Scroll, Focus, and Outline — sized for a hand instead of a
// room. Keep in step with VisionOpeningView / VisionReaderView.

// MARK: - The shelf

struct ReadHomeView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var shelf: Shelf = .articles
    @State private var choosingEPUB = false
    @State private var choosingFolder = false
    @State private var showsSettings = false

    private enum Shelf: Hashable { case articles, journals }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Group {
                if model.epubRecords.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing to Read Yet", systemImage: "books.vertical")
                    } description: {
                        Text("Open an EPUB from Files, or choose the iCloud folder your community shares — everything published from a Mac appears here.")
                    } actions: {
                        Button("Open EPUB…") { choosingEPUB = true }
                        Button("Choose Folder…") { choosingFolder = true }
                    }
                } else {
                    List {
                        switch shelf {
                        case .articles:
                            ForEach(model.alphabetical) { record in
                                row(record)
                            }
                        case .journals:
                            ForEach(model.venues, id: \.self) { venue in
                                NavigationLink {
                                    PhoneJournalView(venue: venue)
                                } label: {
                                    HStack {
                                        Label(venue, systemImage: "newspaper")
                                            .lineLimit(2)
                                        Spacer()
                                        Text("\(model.records(inVenue: venue).count)")
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Read")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Showing", selection: $shelf) {
                        Text("Articles").tag(Shelf.articles)
                        Text("Journals").tag(Shelf.journals)
                    }
                    .pickerStyle(.segmented)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Open EPUB…") { choosingEPUB = true }
                        Button(model.folderURL == nil
                               ? "Choose Community Folder…"
                               : "Change Community Folder…") { choosingFolder = true }
                        Divider()
                        Button("Settings…") { showsSettings = true }
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .navigationDestination(item: $model.readerRecordID) { recordID in
                PhoneReaderView(docID: recordID)
            }
        }
        .fileImporter(isPresented: $choosingEPUB,
                      allowedContentTypes: [.epub],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                var last: EPUBRecord?
                for url in urls {
                    if let record = await model.openEPUBFile(at: url) { last = record }
                }
                if let last { model.readerRecordID = last.id }
            }
        }
        .fileImporter(isPresented: $choosingFolder,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.openFolder(url) }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active { model.scanFolderForEPUBs() }
        }
        .sheet(isPresented: $showsSettings) {
            PhoneSettingsView()
                .presentationDetents([.medium, .large])
        }
    }

    private func row(_ record: EPUBRecord) -> some View {
        Button {
            model.readerRecordID = record.id
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).lineLimit(2)
                Text(record.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - One journal

/// One venue's papers, the whole list — tap a paper and it opens in
/// the reader, as on the headset.
struct PhoneJournalView: View {
    @Environment(PhoneModel.self) private var model
    let venue: String

    var body: some View {
        List(model.records(inVenue: venue)) { record in
            Button {
                model.readerRecordID = record.id
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title).lineLimit(2)
                    Text(record.author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
        .navigationTitle(venue)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - The reading theme

/// The reading's dress — ReadingDeskTheme's phone twin (that type
/// lives in a visionOS-only file): the same two themes, the same
/// "readingDeskTheme" key, so the choice travels. Keep in step.
enum PhoneReadingTheme: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }
    var displayName: String { self == .light ? "Light" : "Dark" }
    var scheme: ColorScheme { self == .light ? .light : .dark }

    /// The page behind the words — warm paper, or a quiet near-black.
    var page: Color {
        self == .light
            ? Color(red: 0.98, green: 0.97, blue: 0.94)
            : Color(red: 0.11, green: 0.11, blue: 0.12)
    }
}

// MARK: - Settings

/// The phone's reading settings — the Mac's pane, sized down. How
/// citations read applies live to whatever is open; the citation's
/// tap, and the source it reveals, are the same in every style. One
/// key across platforms: "origamiCitationStyle".
struct PhoneSettingsView: View {
    @AppStorage("origamiCitationStyle")
    private var citationStyleRaw = OrigamiCitationStyle.authorDate.rawValue
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Citations", selection: $citationStyleRaw) {
                        ForEach(OrigamiCitationStyle.allCases) { style in
                            Text(style.displayName).tag(style.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Citations")
                } footer: {
                    Text(OrigamiCitationStyle(rawValue: citationStyleRaw)?.blurb ?? "")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - The reader

struct PhoneReaderView: View {
    @Environment(PhoneModel.self) private var model
    let docID: String

    /// The Mac's reading views, sized for the hand: Default (the EPUB's
    /// own pages), Scroll, Focus, Outline.
    private enum Mode: String, CaseIterable {
        case faithful, scroll, focus, outline
        var word: String {
            switch self {
            case .faithful: "Default"
            case .scroll: "Scroll"
            case .focus: "Focus"
            case .outline: "Outline"
            }
        }
    }

    @AppStorage("phoneReaderMode") private var modeRaw = Mode.faithful.rawValue
    @AppStorage("phoneReaderFontDelta") private var fontDelta = 0.0
    /// The reading's appearance — the headset's Reading Desk choice, same key.
    @AppStorage("readingDeskTheme") private var themeRaw = PhoneReadingTheme.light.rawValue
    /// The colour theme — the Mac's full set, same "readerTheme" key:
    /// sepia to Solarized, the dyslexia and Irlen palettes among them.
    @AppStorage("readerTheme") private var readerThemeRaw = ReaderTheme.highContrast.rawValue
    /// Bionic Reading — the first half of every word bold, same key as
    /// the Mac's toggle.
    @AppStorage("bionicReading") private var bionicReading = false
    /// The Word assist's pace.
    @AppStorage("rsvpWPM") private var rsvpWPM = 250.0
    /// How citations read — the cross-platform choice (Settings ▸
    /// Citations), the same key the Mac and the headset honour.
    @AppStorage("origamiCitationStyle")
    private var citationStyleRaw = OrigamiCitationStyle.authorDate.rawValue
    @State private var focusIndex = 0
    @State private var expanded: Set<String> = []
    /// The tapped citation's reference key, card-presented; the tapped
    /// dagger's endnote id likewise — the Mac's interactions, here.
    @State private var citationKey: String?
    @State private var noteID: String?
    /// Focus's assists — the Mac's: one sentence, one paragraph, or one
    /// word (RSVP) at a time.
    private enum Assist: String { case none, sentence, paragraph }
    @State private var assistRaw = Assist.none.rawValue
    @State private var sentenceIndex = 0
    @State private var paragraphIndex = 0
    @State private var showsRSVP = false
    @State private var rsvpWords: [String] = []
    @State private var rsvpWordIndex = 0
    @State private var rsvpPlaying = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private var mode: Mode { Mode(rawValue: modeRaw) ?? .faithful }
    private var theme: PhoneReadingTheme {
        PhoneReadingTheme(rawValue: themeRaw) ?? .light
    }
    private var readerTheme: ReaderTheme {
        ReaderTheme(rawValue: readerThemeRaw) ?? .highContrast
    }
    private var assist: Assist { Assist(rawValue: assistRaw) ?? .none }
    /// The page behind the words: the colour theme's, else plain by
    /// appearance; and the ink the theme asks for, else the scheme's.
    private var pageColor: Color {
        readerTheme.background(for: readingScheme)
            ?? (readingScheme == .dark ? .black : .white)
    }
    private var inkStyle: AnyShapeStyle {
        readerTheme.textColor(for: readingScheme).map(AnyShapeStyle.init)
            ?? AnyShapeStyle(.primary)
    }
    /// Everything that colours ink — the environment AND the attributed
    /// text, whose colours are baked at build time — reads this, never
    /// the raw colorScheme (the visionOS lesson).
    private var readingScheme: ColorScheme { theme.scheme }
    private var citationStyle: OrigamiCitationStyle {
        OrigamiCitationStyle(rawValue: citationStyleRaw) ?? .authorDate
    }
    private var bodySize: CGFloat { 17 + fontDelta }

    var body: some View {
        Group {
            if let doc = model.index.byID[docID]?.doc {
                reading(doc)
            } else if let record = model.epubRecords.first(where: { $0.id == docID }) {
                // The index is still parsing — the faithful page needs
                // only files, so it reads meanwhile.
                faithful(record)
            } else {
                ProgressView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        // Reading takes the whole screen: the top stays clean — no back
        // button, no bar, and no clock — the way a page should. The way
        // back is the chevron in the foot bar.
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(true)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if mode == .focus, !showsRSVP { assistBar }
                footBar
            }
        }
        // A citation's tap opens the source's card, a dagger's its
        // endnote — never the browser. Anything else opens normally.
        .environment(\.openURL, OpenURLAction { url in
            if let key = OrigamiReading.citationKey(from: url) {
                citationKey = key
                return .handled
            }
            if let id = OrigamiReading.noteID(from: url) {
                noteID = id
                return .handled
            }
            return .systemAction
        })
        .sheet(item: Binding(
            get: { citationKey.map { TappedCitation(key: $0) } },
            set: { citationKey = $0?.key })) { tapped in
            if let doc = model.index.byID[docID]?.doc {
                PhoneCitationCard(doc: doc, key: tapped.key)
                    .presentationDetents([.medium, .large])
            }
        }
        .sheet(item: Binding(
            get: { noteID.map { TappedNote(id: $0) } },
            set: { noteID = $0?.id })) { tapped in
            if let doc = model.index.byID[docID]?.doc {
                PhoneEndnoteCard(doc: doc, noteID: tapped.id,
                                 style: citationStyle)
                    .presentationDetents([.medium])
            }
        }
    }

    private struct TappedCitation: Identifiable {
        let key: String
        var id: String { key }
    }

    private struct TappedNote: Identifiable {
        let id: String
    }

    @ViewBuilder private func reading(_ doc: LiquidDoc) -> some View {
        let sections = OrigamiSection.build(from: doc)
        Group {
            switch mode {
            case .faithful:
                if let record = model.epubRecords.first(where: { $0.id == docID }) {
                    faithful(record)
                } else {
                    scrollBody(sections, doc: doc)
                }
            case .scroll:
                scrollBody(sections, doc: doc)
            case .focus:
                focusBody(sections, doc: doc)
            case .outline:
                outlineBody(sections, doc: doc)
            }
        }
        // The native readings stand on the theme's page, its scheme
        // riding along; Default wears the theme through injected CSS.
        .background {
            if mode != .faithful { pageColor.ignoresSafeArea() }
        }
        .overlay {
            if showsRSVP { rsvpOverlay }
        }
        .environment(\.colorScheme, mode == .faithful ? colorScheme : readingScheme)
        .scrollContentBackground(mode == .faithful ? .automatic : .hidden)
    }

    private func faithful(_ record: EPUBRecord) -> some View {
        let folder = PhoneModel.epubsRoot
            .appendingPathComponent(record.folder, isDirectory: true)
        return PhoneFaithfulWebView(
            page: folder.appendingPathComponent(record.contentSubpath),
            base: folder,
            themeCSS: readerTheme.css,
            pageColor: pageColor)
            .id(readerTheme.rawValue)   // a theme change reloads the page dressed anew
            .background(pageColor.ignoresSafeArea())
            .ignoresSafeArea(edges: .bottom)
    }

    // MARK: Scroll

    private func scrollBody(_ sections: [OrigamiSection], doc: LiquidDoc) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(sections) { section in
                    sectionView(section, doc: doc)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    @ViewBuilder private func sectionView(_ section: OrigamiSection,
                                          doc: LiquidDoc) -> some View {
        if let heading = section.heading {
            Text(OrigamiReading.inlineAttributed(heading.text, in: doc,
                                                 citations: citationStyle,
                                                 appearance: readingScheme))
                .font(.system(size: bodySize + CGFloat(max(0, 4 - section.level) * 2),
                              weight: .semibold, design: .serif))
                .foregroundStyle(inkStyle)
                .id(heading.id)
                .padding(.top, 8)
        }
        ForEach(section.paragraphs) { paragraph in
            paragraphView(paragraph, doc: doc)
        }
    }

    @ViewBuilder private func paragraphView(_ paragraph: LiquidDoc.Paragraph,
                                            doc: LiquidDoc) -> some View {
        if paragraph.text == "---" {
            Divider()
        } else {
            Text(rendered(paragraph.text, doc: doc))
                .font(.system(size: bodySize, design: .serif))
                .foregroundStyle(inkStyle)
                .lineSpacing(4)
                .id(paragraph.id)
        }
    }

    // MARK: Focus

    private func focusBody(_ sections: [OrigamiSection], doc: LiquidDoc) -> some View {
        let index = min(max(focusIndex, 0), max(sections.count - 1, 0))
        return VStack(spacing: 0) {
            if sections.isEmpty {
                ContentUnavailableView("Nothing to Read", systemImage: "doc.text")
            } else {
                switch assist {
                case .none:
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            sectionView(sections[index], doc: doc)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                    }
                case .sentence:
                    let sentences = sentences(of: sections[index])
                    let at = min(max(sentenceIndex, 0), max(sentences.count - 1, 0))
                    unitDisplay(sentences.isEmpty ? "" : sentences[at],
                                doc: doc, place: "\(at + 1) of \(sentences.count)")
                case .paragraph:
                    let paragraphs = sections[index].paragraphs
                    let at = min(max(paragraphIndex, 0), max(paragraphs.count - 1, 0))
                    unitDisplay(paragraphs.isEmpty ? "" : paragraphs[at].text,
                                doc: doc, place: "\(at + 1) of \(paragraphs.count)")
                }
                stepBar(sections, doc: doc, index: index)
            }
        }
    }

    /// One sentence or paragraph alone on the page, big enough to settle
    /// into — the Mac's assists, sized for the hand.
    private func unitDisplay(_ text: String, doc: LiquidDoc, place: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Text(rendered(text, doc: doc))
                .font(.system(size: bodySize + 4, design: .serif))
                .foregroundStyle(inkStyle)
                .lineSpacing(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
            Text(place)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Previous/Next step whatever Focus is showing: the section, its
    /// sentences, or its paragraphs — crossing into the next section at
    /// the edges.
    private func stepBar(_ sections: [OrigamiSection], doc: LiquidDoc, index: Int) -> some View {
        HStack {
            Button { step(-1, sections: sections, index: index) } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            Spacer()
            Text("\(index + 1) of \(sections.count)")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button { step(1, sections: sections, index: index) } label: {
                Label("Next", systemImage: "chevron.right")
            }
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func step(_ delta: Int, sections: [OrigamiSection], index: Int) {
        withAnimation {
            switch assist {
            case .none:
                focusIndex = min(max(index + delta, 0), sections.count - 1)
            case .sentence:
                let count = sentences(of: sections[index]).count
                let next = sentenceIndex + delta
                if next < 0 || next >= count {
                    focusIndex = min(max(index + delta, 0), sections.count - 1)
                    sentenceIndex = 0
                } else {
                    sentenceIndex = next
                }
            case .paragraph:
                let count = sections[index].paragraphs.count
                let next = paragraphIndex + delta
                if next < 0 || next >= count {
                    focusIndex = min(max(index + delta, 0), sections.count - 1)
                    paragraphIndex = 0
                } else {
                    paragraphIndex = next
                }
            }
        }
    }

    private func sentences(of section: OrigamiSection) -> [String] {
        section.paragraphs.flatMap { OrigamiReading.sentences(of: $0.text) }
    }

    // MARK: Outline

    private func outlineBody(_ sections: [OrigamiSection], doc: LiquidDoc) -> some View {
        List {
            ForEach(sections) { section in
                DisclosureGroup(isExpanded: Binding(
                    get: { expanded.contains(section.id) },
                    set: { open in
                        if open { expanded.insert(section.id) }
                        else { expanded.remove(section.id) }
                    })) {
                    ForEach(section.paragraphs) { paragraph in
                        paragraphView(paragraph, doc: doc)
                            .listRowSeparator(.hidden)
                    }
                } label: {
                    Text(section.title)
                        .font(.system(size: bodySize, weight: .semibold, design: .serif))
                }
            }
        }
        .listStyle(.plain)
    }

    /// The paragraph's attributed text: tokens resolved, the theme's
    /// appearance, and — when asked — the bionic bolding.
    private func rendered(_ text: String, doc: LiquidDoc) -> AttributedString {
        var out = OrigamiReading.inlineAttributed(text, in: doc,
                                                  citations: citationStyle,
                                                  appearance: readingScheme)
        if bionicReading { out = Self.bionic(out) }
        return out
    }

    /// Bold the first half of every word — the Mac's bionic pass, on
    /// AttributedString. Ranges gather first; attributes apply after,
    /// so run coalescing never shifts the walk.
    private static func bionic(_ text: AttributedString) -> AttributedString {
        var out = text
        let wordChars = CharacterSet.alphanumerics
        var ranges: [Range<AttributedString.Index>] = []
        let chars = out.characters
        var i = chars.startIndex
        while i < chars.endIndex {
            while i < chars.endIndex,
                  !(chars[i].unicodeScalars.allSatisfy { wordChars.contains($0) }) {
                i = chars.index(after: i)
            }
            guard i < chars.endIndex else { break }
            let start = i
            while i < chars.endIndex,
                  chars[i].unicodeScalars.allSatisfy({ wordChars.contains($0) }) {
                i = chars.index(after: i)
            }
            let length = chars.distance(from: start, to: i)
            guard length >= 2 else { continue }
            let boldEnd = chars.index(start, offsetBy: max(1, Int((Double(length) / 2).rounded(.up))))
            ranges.append(start..<boldEnd)
        }
        for range in ranges {
            let existing = out[range].inlinePresentationIntent ?? []
            out[range].inlinePresentationIntent = existing.union(.stronglyEmphasized)
        }
        return out
    }

    // MARK: The Word assist (RSVP)

    /// One word at a time, centre screen — the Mac's Word assist:
    /// play/pause, five back or forward, the pace in words a minute.
    private var rsvpOverlay: some View {
        ZStack {
            pageColor.ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer()
                Text(rsvpWords.isEmpty ? "" : rsvpWords[min(rsvpWordIndex, rsvpWords.count - 1)])
                    .font(.system(size: 34 + fontDelta, design: .serif))
                    .foregroundStyle(inkStyle)
                    .frame(maxWidth: .infinity)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.05), value: rsvpWordIndex)
                Text("\(rsvpWordIndex + 1) / \(rsvpWords.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 28) {
                    Button { rsvpWordIndex = max(rsvpWordIndex - 5, 0) } label: {
                        Image(systemName: "backward.fill")
                    }
                    Button {
                        rsvpPlaying.toggle()
                        if rsvpPlaying { stepRSVP() }
                    } label: {
                        Image(systemName: rsvpPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                    }
                    Button { rsvpWordIndex = min(rsvpWordIndex + 5, max(rsvpWords.count - 1, 0)) } label: {
                        Image(systemName: "forward.fill")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(inkStyle)
                HStack(spacing: 10) {
                    Button { rsvpWPM = max(rsvpWPM - 25, 60) } label: {
                        Image(systemName: "minus.circle")
                    }
                    Text("\(Int(rsvpWPM)) wpm")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 80)
                    Button { rsvpWPM = min(rsvpWPM + 25, 800) } label: {
                        Image(systemName: "plus.circle")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Button("Close") {
                    rsvpPlaying = false
                    showsRSVP = false
                }
                .foregroundStyle(.secondary)
                .padding(.bottom, 20)
            }
        }
    }

    private func beginRSVP(_ sections: [OrigamiSection]) {
        let index = min(max(focusIndex, 0), max(sections.count - 1, 0))
        guard index < sections.count else { return }
        let whole = sections[index].paragraphs.map(\.text).joined(separator: " ")
            .replacingOccurrences(of: #"\[(cite|note|inote):[^\]]*\]"#,
                                  with: "", options: .regularExpression)
        rsvpWords = whole.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        rsvpWordIndex = 0
        showsRSVP = true
        rsvpPlaying = true
        stepRSVP()
    }

    private func stepRSVP() {
        guard rsvpPlaying else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60.0 / max(rsvpWPM, 60)))
            guard rsvpPlaying, showsRSVP else { return }
            if rsvpWordIndex < rsvpWords.count - 1 {
                rsvpWordIndex += 1
                stepRSVP()
            } else {
                rsvpPlaying = false
            }
        }
    }

    // MARK: Furniture

    /// The reading's foot bar — the headset's, sized for a hand: the
    /// view words, then Contents, the theme, and the type size.
    private var footBar: some View {
        HStack(spacing: 6) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.backward")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            separator
            ForEach(Array(Mode.allCases.enumerated()), id: \.offset) { index, word in
                if index > 0 { separator }
                modeWord(word.word, chosen: mode == word) {
                    modeRaw = word.rawValue
                    if word == .outline { expanded = [] }
                    if word == .focus { focusIndex = 0 }
                }
            }
            Spacer(minLength: 8)
            Menu {
                Picker("Appearance", selection: $themeRaw) {
                    ForEach(PhoneReadingTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme.rawValue)
                    }
                }
                Picker("Theme", selection: $readerThemeRaw) {
                    ForEach(ReaderTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme.rawValue)
                    }
                }
                Toggle("Bionic Reading", isOn: $bionicReading)
            } label: {
                Image(systemName: "circle.lefthalf.filled")
                    .foregroundStyle(.secondary)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            Menu {
                Button("Bigger") { fontDelta = min(fontDelta + 1, 12) }
                Button("Smaller") { fontDelta = max(fontDelta - 1, -4) }
                Divider()
                Button("Reset Size") { fontDelta = 0 }
            } label: {
                Text("Aa")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        // The foot bar is always black, whatever the page or the system
        // wear — dark scheme so its words and icons read light.
        .background(Color.black.ignoresSafeArea(edges: .bottom))
        .environment(\.colorScheme, .dark)
    }

    /// Focus's second row: [ Focus | Sentence | Paragraph | Word ] —
    /// the Mac's assists, in the same black dress as the foot bar.
    private var assistBar: some View {
        HStack(spacing: 6) {
            Text("[").foregroundStyle(.tertiary)
            modeWord("Focus", chosen: assist == .none) {
                assistRaw = Assist.none.rawValue
            }
            separator
            modeWord("Sentence", chosen: assist == .sentence) {
                sentenceIndex = 0
                assistRaw = Assist.sentence.rawValue
            }
            separator
            modeWord("Paragraph", chosen: assist == .paragraph) {
                paragraphIndex = 0
                assistRaw = Assist.paragraph.rawValue
            }
            separator
            modeWord("Word", chosen: showsRSVP) {
                if let doc = model.index.byID[docID]?.doc {
                    beginRSVP(OrigamiSection.build(from: doc))
                }
            }
            Text("]").foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }

    private var separator: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1, height: 14)
    }

    private func modeWord(_ word: String, chosen: Bool, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(word)
                .font(.subheadline.weight(chosen ? .semibold : .regular))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(chosen ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - The citation card

/// The tapped citation's source, card-presented: the visionOS
/// citation sheet's sibling — title, authors, year, the DOI or URL as
/// a live link, and the BibTeX a long press away.
private struct PhoneCitationCard: View {
    let doc: LiquidDoc
    let key: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let reference = doc.references.first { $0.id == key }
        let fields = reference.flatMap { BibTeXParser.first($0.bibtex)?.fields } ?? [:]
        let title = fields["title"] ?? reference?.citedAs ?? key
        let author = fields["author"] ?? ""
        let year = fields["year"] ?? ""
        let venue = fields["journal"] ?? fields["booktitle"] ?? fields["publisher"] ?? ""
        let doi = fields["doi"]
        let urlField = fields["url"]
        NavigationStack {
            List {
                Section {
                    Text(title).font(.headline)
                    if !author.isEmpty || !year.isEmpty {
                        Text([author, year].filter { !$0.isEmpty }
                            .joined(separator: " \u{00B7} "))
                            .foregroundStyle(.secondary)
                    }
                    if !venue.isEmpty {
                        Text(venue).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Section {
                    if let doi, !doi.isEmpty,
                       let url = URL(string: doi.hasPrefix("http")
                                     ? doi : "https://doi.org/" + doi) {
                        Link(destination: url) {
                            Label("DOI", systemImage: "link")
                        }
                    }
                    if let urlField, !urlField.isEmpty, let url = URL(string: urlField) {
                        Link(destination: url) {
                            Label("Web", systemImage: "safari")
                        }
                    }
                    if let bibtex = reference?.bibtex, !bibtex.isEmpty {
                        Button {
                            UIPasteboard.general.string = bibtex
                        } label: {
                            Label("Copy BibTeX", systemImage: "doc.on.doc")
                        }
                    }
                }
            }
            .navigationTitle("Citation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// The tapped dagger's endnote, card-presented, its own links live.
private struct PhoneEndnoteCard: View {
    let doc: LiquidDoc
    let noteID: String
    let style: OrigamiCitationStyle
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(OrigamiReading.endnote(withID: noteID, in: doc)
                    .map { OrigamiReading.inlineAttributed($0.text, in: doc,
                                                           citations: style,
                                                           appearance: colorScheme) }
                    ?? AttributedString("The document carries no note \(noteID)."))
                    .font(.system(size: 16, design: .serif))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .navigationTitle("Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - The faithful page

/// The EPUB's own page, as published — WebKit reading the unpacked
/// files directly, the visionOS FaithfulWebView's sibling.
private struct PhoneFaithfulWebView: UIViewRepresentable {
    let page: URL
    let base: URL
    /// The colour theme's CSS, injected over the book's own — the
    /// Mac's faithful reader does the same — and its page colour for
    /// the web view's own backing, so the safe areas match the page.
    var themeCSS: String = ""
    var pageColor: Color = .white

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if !themeCSS.isEmpty {
            let escaped = themeCSS
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
            let script = WKUserScript(
                source: "const s = document.createElement('style'); s.textContent = `\(escaped)`; document.documentElement.appendChild(s);",
                injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            configuration.userContentController.addUserScript(script)
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = UIColor(pageColor)
        view.scrollView.backgroundColor = UIColor(pageColor)
        view.loadFileURL(page, allowingReadAccessTo: base)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}
