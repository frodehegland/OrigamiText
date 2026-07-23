import SwiftUI
import AppKit
import FoundationModels

/// The emotion judgement as the on-device model returns it; ids are
/// verified against the document's real paragraphs before display.
@Generable
nonisolated struct GeneratedEmotionJudgement {
    @Guide(description: "Ids of paragraphs clearly expressing positive emotion (joy, enthusiasm, gratitude, hope), copied exactly")
    var positive: [String]
    @Guide(description: "Ids of paragraphs clearly expressing negative emotion (anger, frustration, worry, dismay), copied exactly")
    var negative: [String]
}

struct DocumentDetailView: View {
    @Environment(AppModel.self) private var model
    let destination: AppModel.Destination
    @State private var highlightedParagraphID: String?
    @State private var highlightedSpan: String?
    /// Open stretchtext marks: "paragraphID|address#fragment".
    @State private var expandedTransclusions: Set<String> = []
    /// Emotional-tone tinting: positive paragraphs green, negative red.
    @State private var showingEmotions = false
    @State private var isJudgingEmotions = false
    @State private var emotionsError: String?
    @State private var positiveParagraphs: Set<String>?
    @State private var negativeParagraphs: Set<String> = []
    /// Flow: dense text broken open for reading — display only.
    @State private var flowText = false
    @AppStorage(AppSettings.fullScreenContentWidthKey) private var fullScreenContentWidth = 760.0
    @AppStorage(AppSettings.hideVisualMetaKey) private var hideVisualMeta = false
    @AppStorage(AppSettings.readerHeaderColumnWidthKey) private var headerColumnWidth = 250.0
    @State private var headerColumnDragBase: Double?
    /// Bot Check: the bot asked to comment on this document, its answer,
    /// and the panel's presentation state.
    @State private var botCheckBot: Bot?
    @State private var botCheckStance: BotStance?
    @State private var isBotChecking = false
    @State private var showsBotCheck = false
    /// Summary & Notes: the transcript's grounded summary, read from
    /// its linked summary document — an ordinary Origami letter that
    /// `summarizes` this transcript — or produced on demand by the
    /// on-device model and saved as one.
    @State private var transcriptSummary: TranscriptSummary?
    @State private var transcriptSummaryDoc: LiquidDoc?
    @State private var isSummarizing = false
    @State private var summaryProgress = ""
    @State private var summaryError: String?
    @State private var summaryTask: Task<Void, Never>?

    private var doc: LiquidDoc { destination.doc }

    private var layoutStyle: ReaderLayoutStyle {
        // The window reads with the options column on the right, as in
        // Knowledge Space. Full screen alone reads Top of Letters: the
        // connection columns already flank the text there, and the
        // header belongs with the words.
        model.isFullScreen ? .topOfLetters : .rightColumn
    }

    var body: some View {
        Group {
            if doc.isSidecar {
                SidecarView(doc: doc)
            } else {
                textBody
            }
        }
    }

    /// Full screen flanks the reading column with the document's
    /// neighborhood: what it links to on the left, what links to it on
    /// the right.
    private var textBody: some View {
        GeometryReader { geo in
            // The header column yields to the text: whatever width it was
            // dragged to, the letter itself keeps at least ~400pt.
            let headerMax = max(180, geo.size.width - 420)
            HStack(alignment: .top, spacing: 0) {
                if model.isFullScreen {
                    ReadingConnectionsColumn(doc: doc, direction: .outbound)
                }
                readerColumn
                if layoutStyle == .rightColumn {
                    headerColumnResizer(maxWidth: headerMax)
                    headerColumn(width: min(CGFloat(headerColumnWidth), headerMax))
                }
                if model.isFullScreen {
                    ReadingConnectionsColumn(doc: doc, direction: .inbound)
                }
            }
        }
    }

    /// Title, byline, and its context menu — shared by both layouts.
    private func headerBlock(compact: Bool) -> some View {
        DocumentHeader(doc: doc, showsAuthoringActions: true, compact: compact)
            .contextMenu {
                Button("Copy to Cite") {
                    model.copyCitation(doc: doc)
                }
                Button("Export as EPUB…") {
                    model.exportEPUB(doc)
                }
                if !model.authorIdentity.matches(author: doc.author) {
                    Divider()
                    ForEach(DocumentRelation.discourseActions, id: \.self) { relation in
                        Button(relation.actionTitle ?? relation.rawValue) {
                            model.startDiscourse(relation, about: doc)
                        }
                    }
                }
            }
    }

    /// The reading controls, shared by both layouts: mail verbs (Unread,
    /// File) on the first line, reading aids (Emotions, Flow) on the
    /// second.
    private func readerControls(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 8) {
            if !model.authorIdentity.matches(author: doc.author) {
                HStack(spacing: 8) {
                    Button {
                        model.markUnread(doc)
                    } label: {
                        Label("Unread", systemImage: "envelope.badge")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isUnread(doc))
                    .help("Mark this letter unread — its title goes bold again in the lists")
                    Menu {
                        FileUnderMenuItems(doc: doc)
                    } label: {
                        Label(model.folder(for: doc).map { "Filed: \($0)" } ?? "File",
                              systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .help("File this document under a folder — Archived alone hides it from the library's other views")
                }
            }
            HStack(spacing: 8) {
                // Bot Check: a chosen bot comments on this document, in
                // the same panel language as the Bot view. Others'
                // letters only — one's own words need no bot's verdict.
                if !model.bots.bots.isEmpty, !model.authorIdentity.matches(author: doc.author) {
                    Menu {
                        ForEach(model.bots.bots) { bot in
                            Button(bot.displayName) { runBotCheck(bot) }
                        }
                    } label: {
                        Label("Bot Check", systemImage: "brain.head.profile")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(isBotChecking)
                    .help("Ask a bot whether the person it stands for would agree with this document")
                    .popover(isPresented: $showsBotCheck, arrowEdge: .bottom) {
                        botCheckPopover
                    }
                }
                if isJudgingEmotions {
                    ProgressView()
                        .controlSize(.small)
                }
                if let emotionsError {
                    Text(emotionsError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button {
                    if positiveParagraphs != nil {
                        withAnimation(.snappy) { showingEmotions.toggle() }
                    } else {
                        judgeEmotions()
                    }
                } label: {
                    Label(showingEmotions ? "Hide Emotions" : "Emotions",
                          systemImage: "theatermasks")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isJudgingEmotions || !emotionsAvailable)
                .help(emotionsAvailable
                      ? "Tint paragraphs by emotional tone: positive green, negative red — judged on this Mac, nothing leaves it"
                      : "Requires Apple Intelligence")
                Button {
                    withAnimation(.snappy) { flowText.toggle() }
                } label: {
                    Label(flowText ? "Unflow" : "Flow", systemImage: "text.alignleft")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Break dense text open while reading: sentences get their own lines, clauses break after commas, parentheses stand apart — the document itself is untouched")
            }
        }
    }

    /// One bot's comment on the open document: cached instantly when the
    /// bot has already read it, else judged now — and cached, so the Bot
    /// view knows it too.
    private func runBotCheck(_ bot: Bot) {
        botCheckBot = bot
        botCheckStance = nil
        isBotChecking = true
        showsBotCheck = true
        let doc = doc
        Task {
            botCheckStance = await model.bots.check(doc, with: bot)
            isBotChecking = false
        }
    }

    /// The same panel language as the Bot view's hover card: the verdict
    /// line in the verdict's color, the title, the reason in their voice.
    @ViewBuilder
    private var botCheckPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let bot = botCheckBot {
                if let stance = botCheckStance {
                    Text(stance.verdictLine(for: bot))
                        .font(.headline)
                        .foregroundStyle(stance.color)
                    Text(doc.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(stance.reason)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if isBotChecking {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("\(bot.displayName) is reading…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("\(bot.displayName) could not judge this — Apple Intelligence may be unavailable.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 400, alignment: .leading)
    }

    /// The column beside the reader, in Knowledge Space's language: the
    /// letter's identity on top, then Action (Unread), File (the filing
    /// folders with Archive and a new folder under a rule), and Reading
    /// (Bot Check, Emotions, Flow) — leaving the reading view to the
    /// words alone.
    private func headerColumn(width: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerBlock(compact: true)
                if !model.authorIdentity.matches(author: doc.author) {
                    columnSection("Action") {
                        Button {
                            model.markUnread(doc)
                        } label: {
                            Text("Unread")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(model.isUnread(doc))
                        .help("Mark this letter unread — its title goes bold again in the lists")
                    }
                    fileSection
                }
                readingSection
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The filing folders as checkable buttons, with Archive and a new
    /// folder quietly under a rule — Knowledge Space's File section.
    private var fileSection: some View {
        columnSection("File") {
            ForEach(fileFolders, id: \.self) { folder in
                filingButton(folder)
            }
            Divider()
            HStack {
                Button("Archive") {
                    model.fileDocument(doc, under: AppModel.archivedFolderName)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help("File the letter away: it leaves the library's lists")
                Spacer()
                Button {
                    model.fileInNewFolder(doc)
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("A new folder, with this letter filed in it")
            }
        }
    }

    /// The user's own folders: everything but Archived, which has its
    /// own place under the rule.
    private var fileFolders: [String] {
        model.filingFolders.filter {
            $0.caseInsensitiveCompare(AppModel.archivedFolderName) != .orderedSame
        }
    }

    private func filingButton(_ folder: String) -> some View {
        Button {
            if model.folder(for: doc) == folder {
                model.unfile(doc)
            } else {
                model.fileDocument(doc, under: folder)
            }
        } label: {
            HStack {
                Text(folder)
                if model.folder(for: doc) == folder {
                    Spacer(minLength: 4)
                    Image(systemName: "checkmark")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The reading aids: a bot's verdict, emotional tinting, and flowed
    /// text — display only, the letter itself untouched.
    private var readingSection: some View {
        columnSection("Reading") {
            if TranscriptSummarizer.canSummarize(doc) {
                Button {
                    runTranscriptSummary()
                } label: {
                    HStack {
                        Text(transcriptSummary == nil ? "Summary & Notes" : "Redo Summary & Notes")
                        if isSummarizing {
                            Spacer(minLength: 4)
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(isSummarizing || !TranscriptSummarizer.isAvailable)
                .help(TranscriptSummarizer.isAvailable
                      ? "Summarize this transcript on this Mac — every note links back to the statements that produced it; nothing leaves this Mac"
                      : "Requires Apple Intelligence")
                if isSummarizing, !summaryProgress.isEmpty {
                    Text(summaryProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let summaryError {
                    Text(summaryError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if transcriptSummary != nil, !isSummarizing {
                    Button("Remove Summary") {
                        if let transcriptSummaryDoc {
                            model.removeTranscriptSummary(transcriptSummaryDoc)
                        }
                        transcriptSummaryDoc = nil
                        transcriptSummary = nil
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("Trash the summary letter — the transcript itself is untouched")
                }
            }
            if !model.bots.bots.isEmpty, !model.authorIdentity.matches(author: doc.author) {
                Menu {
                    ForEach(model.bots.bots) { bot in
                        Button(bot.displayName) { runBotCheck(bot) }
                    }
                } label: {
                    Text("Bot Check")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(isBotChecking)
                .help("Ask a bot whether the person it stands for would agree with this document")
                .popover(isPresented: $showsBotCheck, arrowEdge: .leading) {
                    botCheckPopover
                }
            }
            Button {
                if positiveParagraphs != nil {
                    withAnimation(.snappy) { showingEmotions.toggle() }
                } else {
                    judgeEmotions()
                }
            } label: {
                HStack {
                    Text(showingEmotions ? "Hide Emotions" : "Emotions")
                    if isJudgingEmotions {
                        Spacer(minLength: 4)
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(isJudgingEmotions || !emotionsAvailable)
            .help(emotionsAvailable
                  ? "Tint paragraphs by emotional tone: positive green, negative red — judged on this Mac, nothing leaves it"
                  : "Requires Apple Intelligence")
            Button {
                withAnimation(.snappy) { flowText.toggle() }
            } label: {
                Text(flowText ? "Unflow" : "Flow")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .help("Break dense text open while reading: sentences get their own lines, clauses break after commas, parentheses stand apart — the document itself is untouched")
            if let emotionsError {
                Text(emotionsError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// A titled run of the column, Knowledge Space's section style.
    private func columnSection(_ title: String,
                               @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    /// The seam between text and header column: drag it to resize the
    /// column; the width is remembered across letters and launches.
    private func headerColumnResizer(maxWidth: CGFloat) -> some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                let base = headerColumnDragBase ?? headerColumnWidth
                                headerColumnDragBase = base
                                headerColumnWidth = min(max(base - value.translation.width, 180),
                                                        min(maxWidth, 450))
                            }
                            .onEnded { _ in headerColumnDragBase = nil }
                    )
            }
    }

    private var readerColumn: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if layoutStyle == .topOfLetters {
                        headerBlock(compact: false)
                            .padding(.bottom, 8)
                        HStack(spacing: 8) {
                            Spacer()
                            readerControls(alignment: .trailing)
                        }
                        .padding(.bottom, 16)
                    }
                    // The transcript's Summary & Notes, at the top of the
                    // words it summarizes; every note links back down.
                    if let summary = transcriptSummary {
                        summaryBlock(summary)
                            .padding(.bottom, 16)
                    }
                    if model.index.retractedIDs.contains(doc.id) {
                        Label("This document has been retracted by its author.",
                              systemImage: "exclamationmark.octagon.fill")
                            .foregroundStyle(.red)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                            .padding(.bottom, 16)
                    }
                    let appendixIDs = doc.visualMetaParagraphIDs
                    ForEach((doc.body ?? []).filter { !appendixIDs.contains($0.id) }) { paragraph in
                        paragraphRow(paragraph, isAppendix: false)
                    }
                    if !appendixIDs.isEmpty {
                        metadataToggle
                        if !hideVisualMeta {
                            ForEach((doc.body ?? []).filter { appendixIDs.contains($0.id) }) { paragraph in
                                paragraphRow(paragraph, isAppendix: true)
                            }
                        }
                    }
                    DocumentFooter(doc: doc)
                }
                .frame(maxWidth: model.isFullScreen ? CGFloat(fullScreenContentWidth)
                                : layoutStyle == .rightColumn ? 960 : 620,
                       alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(24)
            }
            .onAppear { consumeFragmentRequest(with: proxy) }
            .onChange(of: model.fragmentRequest) { consumeFragmentRequest(with: proxy) }
            .onChange(of: doc.id) {
                showingEmotions = false
                positiveParagraphs = nil
                negativeParagraphs = []
                emotionsError = nil
                flowText = false
                // A new document: any read in flight is abandoned, and
                // the new transcript's linked summary (if any) shows.
                summaryTask?.cancel()
                isSummarizing = false
                summaryProgress = ""
                summaryError = nil
                loadTranscriptSummary()
            }
            .onAppear {
                loadTranscriptSummary()
            }
            .environment(\.openURL, OpenURLAction { url in
                handleReaderURL(url)
            })
        }
    }

    @ViewBuilder
    private func paragraphRow(_ paragraph: LiquidDoc.Paragraph, isAppendix: Bool) -> some View {
        let inboundRefs = model.index.backlinks[doc.id] ?? []
        let citationCount = inboundRefs.filter { $0.fragment == paragraph.id }.count
        let transclusions = isAppendix ? [] : transclusionMatches(in: paragraph)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 6) {
                ParagraphView(
                    paragraph: paragraph,
                    isHighlighted: highlightedParagraphID == paragraph.id,
                    highlightedSpan: highlightedParagraphID == paragraph.id ? highlightedSpan : nil,
                    sizeScale: isAppendix ? 0.5 : 1,
                    transcludeDocumentID: isAppendix ? nil : doc.id,
                    expandedTransclusionKeys: expandedTransclusions,
                    liftSource: isAppendix ? nil : doc,
                    flowed: isAppendix ? false : flowText
                )
                .contextMenu {
                    ContextActionItems(target: .paragraph(paragraph, in: doc))
                }
                if citationCount > 0 {
                    Label("\(citationCount)", systemImage: "quote.opening")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 10)
                        .help(citationCount == 1
                              ? "Cited by 1 document"
                              : "Cited by \(citationCount) documents")
                }
            }
            let expandedHere = transclusions.filter {
                expandedTransclusions.contains(transclusionKey(paragraph, $0))
            }
            if !expandedHere.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(expandedHere.enumerated()), id: \.offset) { _, match in
                        TransclusionQuoteView(match: match)
                    }
                }
                .padding(.leading, 6)
                .padding(.bottom, 8)
            }
        }
        .background(isAppendix ? Color.clear : sentimentTint(for: paragraph.id),
                    in: RoundedRectangle(cornerRadius: 6))
        .id(paragraph.id)
        .contextMenu {
            Button("Copy to Cite") {
                model.copyCitation(doc: doc, paragraphID: paragraph.id)
            }
            Button("Copy Link to Paragraph") {
                model.copyParagraphLink(doc: doc, paragraphID: paragraph.id)
            }
            if !model.authorIdentity.matches(author: doc.author) {
                Divider()
                ForEach(DocumentRelation.discourseActions, id: \.self) { relation in
                    Button(relation.actionTitle ?? relation.rawValue) {
                        model.startDiscourse(relation, about: doc)
                    }
                }
            }
        }
    }

    /// Readers who prefer not to see the Visual-Meta appendix can hide it;
    /// the centered button sits between the body text and the appendix, or
    /// after a line break when the appendix is hidden.
    @ViewBuilder
    private var metadataToggle: some View {
        if hideVisualMeta {
            Text(" ")
                .padding(6)
            Button("Metadata") {
                withAnimation(.snappy) { hideVisualMeta = false }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
        } else {
            Button("Hide Metadata") {
                withAnimation(.snappy) { hideVisualMeta = true }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
    }

    /// Stretchtext marks toggle in place; origami links follow; the web
    /// goes to the browser.
    private func handleReaderURL(_ url: URL) -> OpenURLAction.Result {
        if url.scheme?.lowercased() == "origamitext-transclude", let host = url.host() {
            let address = LiquidAddress.canonical(host)
            let paragraphID = String(url.path().trimmingPrefix("/"))
            let key = "\(paragraphID)|\(address)#\(url.fragment ?? "")"
            withAnimation(.snappy) {
                if expandedTransclusions.contains(key) {
                    expandedTransclusions.remove(key)
                } else {
                    expandedTransclusions.insert(key)
                }
            }
            return .handled
        }
        if url.scheme?.lowercased() == "origamitext" {
            model.handleURL(url)
            return .handled
        }
        return .systemAction
    }

    private func transclusionKey(_ paragraph: LiquidDoc.Paragraph, _ match: AddressMatch) -> String {
        "\(paragraph.id)|\(match.id)#\(match.fragment ?? "")"
    }

    /// Citations found in a paragraph's text, deduplicated, excluding
    /// self-references — each becomes a transclusion chip.
    private func transclusionMatches(in paragraph: LiquidDoc.Paragraph) -> [AddressMatch] {
        var seen: Set<String> = []
        return LiquidAddress.matches(in: paragraph.text).filter { match in
            guard match.id != doc.id, !LiquidAddress.isPersonAddress(match.id) else { return false }
            let key = "\(match.id)#\(match.fragment ?? "")"
            return seen.insert(key).inserted
        }
    }

    private var emotionsAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Asks the on-device model which content paragraphs clearly express
    /// emotion (the appendix is metadata and never judged). Ids that don't
    /// exist in the document are dropped; a paragraph claimed on both
    /// sides counts as neither.
    private func judgeEmotions() {
        isJudgingEmotions = true
        emotionsError = nil
        let appendixIDs = doc.visualMetaParagraphIDs
        let paragraphs = (doc.body ?? []).filter {
            !appendixIDs.contains($0.id) && !$0.displayText.isEmpty
        }
        var prompt = """
        You judge the emotional tone of the paragraphs of one document. Name only paragraphs whose text clearly expresses emotion — positive (joy, enthusiasm, gratitude, hope) or negative (anger, frustration, worry, dismay). Factual, procedural, or descriptive paragraphs express no emotion and belong in neither list. Copy paragraph ids exactly. Empty lists are an honest answer.

        THE PARAGRAPHS:

        """
        for paragraph in paragraphs {
            prompt += "\(paragraph.id): \(paragraph.displayText)\n"
        }
        let request = prompt
        let validIDs = Set(paragraphs.map(\.id))
        Task {
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(to: request, generating: GeneratedEmotionJudgement.self)
                let positive = Set(response.content.positive).intersection(validIDs)
                let negative = Set(response.content.negative).intersection(validIDs)
                positiveParagraphs = positive.subtracting(negative)
                negativeParagraphs = negative.subtracting(positive)
                withAnimation(.snappy) { showingEmotions = true }
            } catch {
                emotionsError = "The model could not respond."
            }
            isJudgingEmotions = false
        }
    }

    /// Green for clearly positive paragraphs, red for clearly negative;
    /// everything else stays untinted.
    private func sentimentTint(for paragraphID: String) -> Color {
        guard showingEmotions else { return .clear }
        if positiveParagraphs?.contains(paragraphID) == true { return .green.opacity(0.16) }
        if negativeParagraphs.contains(paragraphID) { return .red.opacity(0.16) }
        return .clear
    }

    // MARK: - Summary & Notes

    /// The transcript's linked summary document, read back for display.
    private func loadTranscriptSummary() {
        if TranscriptSummarizer.canSummarize(doc),
           let summaryDoc = model.transcriptSummaryDocument(for: doc) {
            transcriptSummaryDoc = summaryDoc
            transcriptSummary = TranscriptSummary.display(from: summaryDoc, transcriptID: doc.id)
        } else {
            transcriptSummaryDoc = nil
            transcriptSummary = nil
        }
    }

    /// One read of the transcript, narrated in the column while it
    /// runs. The result is saved beside the transcript as an ordinary
    /// linked document — shareable like anything else; the transcript
    /// itself is never touched.
    private func runTranscriptSummary() {
        guard !isSummarizing else { return }
        isSummarizing = true
        summaryError = nil
        summaryProgress = ""
        let doc = doc
        summaryTask = Task {
            do {
                let summary = try await TranscriptSummarizer.summarize(doc) { note in
                    summaryProgress = note
                }
                let saved = model.saveTranscriptSummary(summary, for: doc)
                if self.doc.id == doc.id {
                    withAnimation(.snappy) {
                        transcriptSummary = summary
                        transcriptSummaryDoc = saved
                    }
                }
            } catch is CancellationError {
                // Navigated away mid-read; nothing to report.
            } catch {
                if self.doc.id == doc.id {
                    summaryError = error.localizedDescription
                }
            }
            if self.doc.id == doc.id {
                isSummarizing = false
                summaryProgress = ""
            }
        }
    }

    /// The summary as it reads at the top of the transcript: the
    /// overview, then the notes, each with chips linking back to the
    /// statements that produced it.
    private func summaryBlock(_ summary: TranscriptSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Summary & Notes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("AI, on this Mac · \(summary.generated.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let overview = summary.overview {
                Text(overview)
                    .font(.system(size: 15, design: .serif))
                    .textSelection(.enabled)
            }
            ForEach(summary.notes) { note in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("•")
                        .foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(note.text)
                            .font(.system(size: 14, design: .serif))
                            .textSelection(.enabled)
                        WrappingHStack(horizontalSpacing: 5, verticalSpacing: 4) {
                            ForEach(note.sources, id: \.self) { source in
                                summarySourceChip(source)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    /// One doorway back into the conversation: the speaker's name,
    /// jumping to (and flashing) the statement the note came from.
    private func summarySourceChip(_ paragraphID: String) -> some View {
        let speaker = (doc.body ?? []).first { $0.id == paragraphID }?.speaker
        return Button {
            model.fragmentRequest = AppModel.FragmentRequest(
                docID: doc.id, paragraphID: paragraphID, token: UUID())
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 7))
                Text(speaker ?? "statement")
            }
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Jump to the statement this note came from")
    }

    private func consumeFragmentRequest(with proxy: ScrollViewProxy) {
        guard let request = model.fragmentRequest, request.docID == doc.id else { return }
        model.fragmentRequest = nil
        Task {
            // Let the new document finish layout before scrolling to the anchor.
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(request.paragraphID, anchor: .top)
            }
            highlightedParagraphID = request.paragraphID
            highlightedSpan = request.span
            try? await Task.sleep(for: .milliseconds(300))
            withAnimation(.easeOut(duration: 1.5)) {
                highlightedParagraphID = nil
                highlightedSpan = nil
            }
        }
    }
}

/// A left-aligned flow: subviews run across like an HStack and wrap to
/// the next line when the width runs out — so pill-button rows in the
/// narrow reading column never crush their labels.
struct WrappingHStack: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, in: proposal.width ?? .infinity)
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height }
            + verticalSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, in: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: .unspecified)
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty
                ? size.width
                : row.width + horizontalSpacing + size.width
            if !row.indices.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + horizontalSpacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

struct DocumentHeader: View {
    @Environment(AppModel.self) private var model
    let doc: LiquidDoc
    /// True only in the main reader: own published documents offer
    /// Supersede and Follow Up where the byline would be.
    var showsAuthoringActions = false
    /// The narrow Right Column layout: a smaller title, and byline items
    /// stacked vertically — the header reads down, not across.
    var compact = false
    @State private var showingRevisionDelta = false
    @State private var confirmingNotTranscript = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(doc.title)
                    .font(.system(size: compact ? 20 : 32, design: .serif))
                    .textSelection(.enabled)
                if doc.hasUnfamiliarFormatVersion {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .help("Written in a different Origami Document format (\(doc.format)); some content may not be shown.")
                }
            }
            bylineRow
            if model.authorIdentity.matches(author: doc.author), showsAuthoringActions {
                authoringActions
            }
            Divider()
                .padding(.top, 8)
        }
    }

    /// Author and date for others' documents (own documents don't restate
    /// them), plus provenance links for any discourse relations this
    /// document carries: "Responding to <Original>" etc., each clickable.
    private var bylineRow: some View {
        let provenance = provenanceItems
        // Across in the classic layout; down the narrow column in compact,
        // where a horizontal row would crush every item into fragments.
        let layout = compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 5))
            : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            if model.authorIdentity.matches(author: doc.author) {
                // Provenance never hides, even from the author: a document
                // carrying someone else's words says so on its own byline.
                if let onBehalfOf = doc.onBehalfOf {
                    Text("On behalf of \(onBehalfOf)")
                        .help("This document carries \(onBehalfOf)’s words; \(doc.author) published it on their behalf")
                } else if provenance.isEmpty, !compact {
                    Text(" ")
                }
            } else if compact {
                VStack(alignment: .leading, spacing: 2) {
                    BylinePersonName(name: doc.displayAuthor)
                    Text(doc.date?.displayText ?? doc.created.formatted(date: .long, time: .shortened))
                        .textSelection(.enabled)
                        .help(doc.date == nil ? "" : "Created \(doc.created.formatted(date: .long, time: .shortened))")
                }
            } else {
                HStack(spacing: 0) {
                    BylinePersonName(name: doc.displayAuthor)
                    Text(" · \(doc.date?.displayText ?? doc.created.formatted(date: .long, time: .shortened))")
                        .textSelection(.enabled)
                        .help(doc.date == nil ? "" : "Created \(doc.created.formatted(date: .long, time: .shortened))")
                }
            }
            if !doc.attention.isEmpty {
                HStack(spacing: 0) {
                    Text("For the attention of ")
                    ForEach(Array(doc.attention.enumerated()), id: \.offset) { index, name in
                        if index > 0 { Text(", ") }
                        BylinePersonName(name: name)
                    }
                }
                .lineLimit(1)
            }
            ForEach(provenance, id: \.link.to) { item in
                Button {
                    model.follow(to: item.link.to, fragment: nil, rel: item.link.rel)
                } label: {
                    Text("\(item.label) \(Text(item.title).underline())")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help("Open “\(item.title)”")
            }
            // The way back to the transcript a statement was lifted from,
            // visible to every reader, not only the author.
            if let source = transcriptSourceLink {
                Button {
                    openTranscriptSource(source)
                } label: {
                    Text("Lifted from \(Text(model.title(for: source.to) ?? "the transcript").underline())")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help("Open the transcript this statement was lifted from, at the statement")
            }
            // The declared document type, on the page rather than only in
            // the export dialog and the Visual-Meta. Import guesses at
            // transcripts, so that tag is clickable to overrule it.
            if let type = doc.documentType {
                if type == LiquidDoc.DocumentType.transcript.rawValue {
                    Button {
                        confirmingNotTranscript = true
                    } label: {
                        typeTag(type)
                    }
                    .buttonStyle(.plain)
                    .help("Marked a transcript at import — click if that's wrong")
                    .confirmationDialog("Is this a transcript?",
                                        isPresented: $confirmingNotTranscript) {
                        Button("This is not a Transcript") {
                            model.setDocumentType(doc, to: .letter)
                        }
                    } message: {
                        Text("“This is not a Transcript” reclassifies it as a letter. The correction is written into the document itself.")
                    }
                } else {
                    typeTag(type)
                        .help("The author declared this document a \(type)")
                }
            }
            if let previous = previousVersion {
                Button {
                    showingRevisionDelta = true
                } label: {
                    Text("What changed?").underline()
                }
                .buttonStyle(.plain)
                .help("How much this version changed from the one it supersedes")
                .sheet(isPresented: $showingRevisionDelta) {
                    RevisionDeltaView(previousTitle: previous.title,
                                      delta: RevisionDelta.between(old: previous, new: doc))
                }
            }
            // Reading someone else's letter, the reply is at hand: the
            // same discourse verbs as the document context menu, pushed
            // to the byline's right edge (its own line in the narrow
            // column, where a Spacer would stretch the column instead).
            if !model.authorIdentity.matches(author: doc.author) {
                if !compact { Spacer(minLength: 12) }
                ReplyMenu(doc: doc)
                    .fixedSize()
                    .controlSize(.small)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func typeTag(_ type: String) -> some View {
        Text(LiquidDoc.DocumentType(rawValue: type)?.displayName ?? type)
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }

    /// The version this document supersedes, when it is in the library.
    private var previousVersion: LiquidDoc? {
        guard let previousID = doc.links.first(where: { $0.rel == "revises" })?.to else { return nil }
        return model.index.byID[previousID]?.doc
    }

    private struct ProvenanceItem {
        let label: String
        let title: String
        let link: LiquidDoc.Link
    }

    private var provenanceItems: [ProvenanceItem] {
        doc.links.compactMap { link in
            guard let relation = DocumentRelation.from(rel: link.rel),
                  let label = relation.bylineLabel else { return nil }
            return ProvenanceItem(label: label,
                                  title: model.title(for: link.to) ?? link.to,
                                  link: link)
        }
    }

    private var authoringActions: some View {
        // A flow, not a fixed row: in the narrow reading column the
        // pills wrap to the next line instead of crushing their labels.
        WrappingHStack(horizontalSpacing: 8, verticalSpacing: 6) {
            Button("Supersede") { model.supersede(doc) }
                .help("Start a new version; this one becomes superseded (a revises link records it)")
            Button("Follow Up") { model.followUp(doc) }
                .help("Start a connected follow-up document (a responds-to link records it)")
            if let previousID = doc.links.first(where: { $0.rel == "revises" })?.to,
               let previous = model.index.byID[previousID] {
                Button("Compare Versions") {
                    model.openTranspointing(from: doc, to: previous.doc)
                }
                .help("Read this version beside the one it supersedes")
            }
            Button("Use as Template") { model.useAsTemplate(doc) }
                .help("Start a fresh, unlinked document from this content")
            if !model.index.retractedIDs.contains(doc.id) {
                Button("Retract") { model.retract(doc) }
                    .tint(.red)
                    .help("Publish a retraction notice; readers will see this document as withdrawn")
            }
            if let source = transcriptSourceLink {
                Button("Transcript") { openTranscriptSource(source) }
                    .help("Open the transcript this statement was lifted from, at the statement")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// The way back to the transcript a lifted statement came from: a
    /// document carrying someone's words on their behalf cites the
    /// statement it was lifted from.
    private var transcriptSourceLink: LiquidDoc.Link? {
        guard doc.onBehalfOf != nil else { return nil }
        return doc.links.first { $0.rel == DocumentRelation.cites.rawValue }
    }

    /// Opens the source transcript wherever it lives — the library, the
    /// published copies, or (still unpublished) the draft editor — scrolled
    /// to the lifted statement where the reader can show it.
    private func openTranscriptSource(_ link: LiquidDoc.Link) {
        let id = LiquidAddress.canonical(link.to)
        if let entry = model.index.byID[id] {
            model.sidebarSelection = .allDocuments
            model.open(entry.doc, fragment: link.fragment, span: link.span)
        } else if let published = model.drafts.published.first(where: { $0.id == id }) {
            model.sidebarSelection = .published
            model.open(published, fragment: link.fragment, span: link.span)
        } else if let draft = model.drafts.documents.first(where: { $0.id == id }) {
            model.sidebarSelection = .drafts
            model.editDraft(draft)
        } else {
            model.showNote("The source transcript (\(id)) is not in the library")
        }
    }
}

/// The author's name on a document byline. Control-click answers with the
/// shared person actions — their profile; the record is edited from the
/// profile itself. Resting the pointer on a name with a contact record
/// floats that person's card: portrait, affiliation, and letters.
struct BylinePersonName: View {
    @Environment(AppModel.self) private var model
    let name: String
    @State private var showsCard = false
    @State private var pointerInCard = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        Text(name)
            .contextMenu {
                ContextActionItems(target: .person(name: name))
            }
            .help("\(name) — control-click for their profile")
            .onHover { inside in
                guard model.people.person(named: name) != nil else { return }
                if inside {
                    scheduleCard(shows: true, after: 350)
                } else {
                    scheduleCard(shows: false, after: 300)
                }
            }
            .popover(isPresented: $showsCard, arrowEdge: .bottom) {
                if let person = model.people.person(named: name) {
                    PersonHoverCard(person: person) {
                        hoverTask?.cancel()
                        showsCard = false
                    }
                    .onHover { inside in
                        pointerInCard = inside
                        if inside {
                            hoverTask?.cancel()
                        } else {
                            scheduleCard(shows: false, after: 250)
                        }
                    }
                }
            }
    }

    /// The dwell before showing, and the grace period that lets the
    /// pointer travel from the name onto the card without it vanishing.
    private func scheduleCard(shows: Bool, after milliseconds: Int) {
        hoverTask?.cancel()
        hoverTask = Task {
            try? await Task.sleep(for: .milliseconds(milliseconds))
            guard !Task.isCancelled else { return }
            if shows {
                showsCard = true
            } else if !pointerInCard {
                showsCard = false
            }
        }
    }
}

/// The attribution over a transcript statement — a name the system knows.
/// Click for the person's profile (their documents and everything they
/// have said); control-click for the same by menu.
struct SpeakerLabel: View {
    @Environment(AppModel.self) private var model
    let name: String
    var sizeScale: CGFloat = 1
    /// When the label knows which statement it heads and in which document,
    /// the context menu offers lifting that statement into a new draft.
    var liftContext: (source: LiquidDoc, paragraph: LiquidDoc.Paragraph)? = nil

    var body: some View {
        Button {
            model.openAuthorPage(named: name)
        } label: {
            Text(name)
                .font(.system(size: 12 * sizeScale, weight: .semibold))
                .kerning(0.8)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("\(name) — click for their profile")
        .contextMenu {
            // Shared person actions, then paragraph actions (Lift among
            // them). The record itself is edited from the profile.
            ContextActionItems(target: .person(name: name))
            if let liftContext {
                ContextActionItems(target: .paragraph(liftContext.paragraph, in: liftContext.source))
            }
        }
    }
}

/// The "What changed?" dialog: how much of the document changed from the
/// version it supersedes — the percentage as the headline, then the
/// paragraph breakdown.
private struct RevisionDeltaView: View {
    let previousTitle: String
    let delta: RevisionDelta
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Text("Changes from “\(previousTitle)”")
                .font(.title3)
                .multilineTextAlignment(.center)
            Text("\(delta.percentChanged)%")
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .foregroundStyle(delta.isIdentical ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            Text(delta.isIdentical
                 ? "No content changes — the text is identical."
                 : "of the document changed")
                .foregroundStyle(.secondary)
            if !delta.isIdentical {
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    breakdownRow("Edited", delta.edited)
                    breakdownRow("Added", delta.added)
                    breakdownRow("Removed", delta.removed)
                    breakdownRow("Unchanged", delta.unchanged)
                    GridRow {
                        Text("Length").gridColumnAlignment(.leading)
                        Text(lengthText).gridColumnAlignment(.trailing)
                    }
                }
                .font(.callout)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
        }
        .padding(28)
        .frame(width: 380)
    }

    private var lengthText: String {
        guard delta.wordDelta != 0 else { return "unchanged" }
        let count = abs(delta.wordDelta)
        return "\(delta.wordDelta > 0 ? "+" : "−")\(count) \(count == 1 ? "word" : "words")"
    }

    @ViewBuilder
    private func breakdownRow(_ label: String, _ count: Int) -> some View {
        if count > 0 || label == "Unchanged" {
            GridRow {
                Text(label).gridColumnAlignment(.leading)
                Text("\(count) \(count == 1 ? "paragraph" : "paragraphs")")
                    .gridColumnAlignment(.trailing)
            }
        }
    }
}

#Preview("What Changed") {
    RevisionDeltaView(previousTitle: "Notes on Spatial Reading",
                      delta: RevisionDelta(edited: 3, added: 2, removed: 1,
                                           unchanged: 14, wordDelta: 96))
}

struct ParagraphView: View {
    let paragraph: LiquidDoc.Paragraph
    let isHighlighted: Bool
    /// Span scope: when arriving by a span-scoped link, the exact words
    /// get a stronger mark than the paragraph's flash.
    var highlightedSpan: String? = nil
    var sizeScale: CGFloat = 1
    /// When set, citations grow an inline stretchtext mark (⧉) directly
    /// after the address; the id excludes self-references.
    var transcludeDocumentID: String? = nil
    var expandedTransclusionKeys: Set<String> = []
    /// The document this paragraph is read in; when present, a speaker's
    /// context menu can lift the statement into a new draft.
    var liftSource: LiquidDoc? = nil
    /// Flow: break dense prose open for reading (sentences, clauses,
    /// parentheses). Display only; headings are left alone.
    var flowed = false

    var body: some View {
        if isRule {
            Divider()
                .padding(.vertical, 10)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                if let speaker = paragraph.speaker {
                    SpeakerLabel(name: speaker, sizeScale: sizeScale,
                                 liftContext: liftSource.map { ($0, paragraph) })
                }
                // AppKit-backed since the context-menu work: same
                // rendering, but the selection is reachable and every
                // ctrl-click resolves to a ContextTarget.
                ReaderTextView(paragraph: paragraph,
                               attributed: renderedText,
                               sizeScale: sizeScale,
                               highlightedSpan: isHighlighted ? highlightedSpan : nil,
                               doc: liftSource)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .background(
                isHighlighted ? Color.yellow.opacity(0.35) : Color.clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
            .padding(.top, (paragraph.speaker == nil ? topPadding : 8) * sizeScale)
            .padding(.bottom, 8 * sizeScale)
        }
    }

    /// A paragraph of only dashes ("---" and friends) renders as a rule.
    private var isRule: Bool {
        let trimmed = paragraph.displayText.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 3 && trimmed.allSatisfy { "-—–".contains($0) }
    }

    private var renderedText: AttributedString {
        var attributed: AttributedString
        if let transcludeDocumentID {
            attributed = paragraph.renderedTextWithTransclusionMarks(
                excluding: transcludeDocumentID,
                expandedKeys: expandedTransclusionKeys)
        } else {
            attributed = paragraph.renderedText
        }
        // The span-scoped arrival: mark the exact words where they occur;
        // where they don't (a title-quote, or drifted text), the
        // paragraph flash alone stands — scope degrades, never breaks.
        if isHighlighted, let highlightedSpan,
           let range = attributed.range(of: highlightedSpan, options: [.caseInsensitive, .diacriticInsensitive]) {
            attributed[range].backgroundColor = Color.yellow.opacity(0.85)
        }
        if flowed, paragraph.effectiveHeading == nil {
            attributed = FlowBreaker.flowed(attributed)
        }
        return attributed
    }

    private var topPadding: CGFloat {
        switch paragraph.effectiveHeading {
        case 1: 20
        case 2: 14
        case 3: 10
        default: 0
        }
    }
}

/// Flow: dense prose broken open for reading. Whitespace runs become line
/// breaks where the surrounding characters say a thought ends — a blank
/// line after a sentence's period, a new line after an in-sentence comma,
/// and around parentheses. Punctuation inside numbers and abbreviations
/// stays put: a period breaks only between a letter and a following
/// capital; a comma never breaks against a digit. The transform edits the
/// composed AttributedString, so links and marks ride along untouched.
nonisolated enum FlowBreaker {
    static func flowed(_ attributed: AttributedString) -> AttributedString {
        let text = Array(String(attributed.characters))
        var replacements: [(start: Int, end: Int, breakText: String)] = []
        var i = 0
        while i < text.count {
            guard text[i] == " " || text[i] == "\t" else { i += 1; continue }
            var j = i
            while j < text.count, text[j] == " " || text[j] == "\t" { j += 1 }
            let before: Character = i > 0 ? text[i - 1] : "\n"
            let beforePrev: Character = i > 1 ? text[i - 2] : "\n"
            let after: Character = j < text.count ? text[j] : "\n"
            let breakText: String? = if before == ".", beforePrev.isLetter, after.isUppercase {
                "\n\n"   // a sentence ended; the next begins
            } else if before == ",", !beforePrev.isNumber, !after.isNumber {
                "\n"     // a clause ended
            } else if before == ")" || after == "(" {
                "\n"     // parentheses stand apart
            } else {
                nil
            }
            if let breakText {
                replacements.append((start: i, end: j, breakText: breakText))
            }
            i = j
        }
        var result = attributed
        for replacement in replacements.reversed() {
            let start = result.index(result.startIndex, offsetByCharacters: replacement.start)
            let end = result.index(result.startIndex, offsetByCharacters: replacement.end)
            result.replaceSubrange(start..<end, with: AttributedString(replacement.breakText))
        }
        return result
    }
}
