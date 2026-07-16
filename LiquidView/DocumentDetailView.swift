import SwiftUI
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
    @AppStorage(AppSettings.fullScreenContentWidthKey) private var fullScreenContentWidth = 760.0
    @AppStorage(AppSettings.hideVisualMetaKey) private var hideVisualMeta = false

    private var doc: LiquidDoc { destination.doc }

    var body: some View {
        Group {
            if doc.isSidecar {
                SidecarView(doc: doc)
            } else {
                textBody
            }
        }
        .navigationTitle(doc.title)
    }

    private var textBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DocumentHeader(doc: doc, showsAuthoringActions: true)
                        .contextMenu {
                            Button("Copy to Cite") {
                                model.copyCitation(doc: doc)
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
                        .padding(.bottom, 8)
                    HStack(spacing: 8) {
                        Spacer()
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
                    }
                    .padding(.bottom, 16)
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
                }
                .frame(maxWidth: model.isFullScreen ? CGFloat(fullScreenContentWidth) : 620,
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
                    liftSource: isAppendix ? nil : doc
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

struct DocumentHeader: View {
    @Environment(AppModel.self) private var model
    let doc: LiquidDoc
    /// True only in the main reader: own published documents offer
    /// Supersede and Follow Up where the byline would be.
    var showsAuthoringActions = false
    @State private var showingRevisionDelta = false
    @State private var confirmingNotTranscript = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(doc.title)
                    .font(.system(size: 32, design: .serif))
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
        return HStack(spacing: 10) {
            if model.authorIdentity.matches(author: doc.author) {
                // Provenance never hides, even from the author: a document
                // carrying someone else's words says so on its own byline.
                if let onBehalfOf = doc.onBehalfOf {
                    Text("On behalf of \(onBehalfOf)")
                        .help("This document carries \(onBehalfOf)’s words; \(doc.author) published it on their behalf")
                } else if provenance.isEmpty {
                    Text(" ")
                }
            } else {
                Text("\(doc.displayAuthor) · \(doc.date?.displayText ?? doc.created.formatted(date: .long, time: .shortened))")
                    .textSelection(.enabled)
                    .help(doc.date == nil ? "" : "Created \(doc.created.formatted(date: .long, time: .shortened))")
            }
            if !doc.attention.isEmpty {
                Text("For the attention of \(doc.attention.joined(separator: ", "))")
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
        HStack(spacing: 8) {
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

/// The attribution over a transcript statement — a name the system knows.
/// Click for the person's page (their documents and everything they have
/// said); control-click to open that page, see their contact record, or
/// add them to People when they have none.
struct SpeakerLabel: View {
    @Environment(AppModel.self) private var model
    let name: String
    var sizeScale: CGFloat = 1
    /// When the label knows which statement it heads and in which document,
    /// the context menu offers lifting that statement into a new draft.
    var liftContext: (source: LiquidDoc, paragraph: LiquidDoc.Paragraph)? = nil
    @State private var contactPerson: Person?

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
        .help(model.people.person(named: name) == nil
              ? "\(name) — click for their page; control-click to add them to People"
              : "\(name) — click for their page")
        .contextMenu {
            // Shared person actions, then paragraph actions (Lift among
            // them), then this view's local sheet items.
            ContextActionItems(target: .person(name: name))
            if let liftContext {
                ContextActionItems(target: .paragraph(liftContext.paragraph, in: liftContext.source))
            }
            if let known = model.people.person(named: name) {
                Button("Contact Record…") { contactPerson = known }
            } else {
                Button("Add \(name) to People…") { contactPerson = Person(displayName: name) }
            }
        }
        .sheet(item: $contactPerson) { person in
            PersonFormView(person: person, heading: "Contact Record") { updated in
                model.people.upsert(updated)
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
