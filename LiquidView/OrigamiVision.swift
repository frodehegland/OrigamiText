#if os(visionOS)
import SwiftUI
import UniformTypeIdentifiers

/// Origami Text for visionOS — the same app (one bundle id, one App Store
/// listing), the same library. The session is not a document but the
/// community folder on iCloud, so everything published from the Mac is
/// instantly present here; nothing is exported, nothing goes stale.
@main
struct OrigamiVisionApp: App {
    @State private var model = VisionModel()

    var body: some Scene {
        WindowGroup(id: "library") {
            VisionLibraryView()
                .environment(model)
        }
        .defaultSize(width: 560, height: 720)

        // The Knowledge Space: a volume, Author-Map logic — an essentially
        // 2D arrangement whose cards the hand can pull and push in Z.
        WindowGroup(id: "space") {
            KnowledgeSpaceView()
                .environment(model)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 1.6, height: 1.1, depth: 0.7, in: .meters)

        WindowGroup(id: "reader", for: String.self) { $docID in
            VisionReaderView(docID: docID ?? "")
                .environment(model)
        }
        .defaultSize(width: 660, height: 840)

        // zzStructure navigation in a volume: the bound Z dimension is
        // literal depth — posward recedes, negward approaches.
        WindowGroup(id: "zz") {
            VisionZZView()
                .environment(model)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 1.5, height: 1.0, depth: 0.7, in: .meters)
    }
}

/// visionOS session state: the same LibraryIndex the Mac uses, plus a
/// folder bookmark that survives relaunch. Rescans happen on demand and
/// when a scene returns to the foreground (no FSEvents here).
@MainActor @Observable
final class VisionModel {
    let index = LibraryIndex()
    private static let bookmarkKey = "communityFolderBookmark"

    init() { restoreFolder() }

    func openFolder(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        if let bookmark = try? url.bookmarkData() {
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        }
        index.setFolder(url)
    }

    private func restoreFolder() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return }
        index.setFolder(url)
    }
}

/// The library window: choose the community folder once, then the list.
struct VisionLibraryView: View {
    @Environment(VisionModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @State private var choosingFolder = false
    @State private var showingTranscriptsOnly = false

    /// The same rule as the Mac's Transcripts view: declared `transcript`,
    /// or (for documents from before the type existed) at least two
    /// distinct speaker attributions.
    private func isTranscript(_ doc: LiquidDoc) -> Bool {
        if doc.documentType == LiquidDoc.DocumentType.transcript.rawValue { return true }
        return Set((doc.body ?? []).compactMap(\.speaker)).count >= 2
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.index.folderURL == nil {
                    ContentUnavailableView {
                        Label("No Community Folder", systemImage: "folder")
                    } description: {
                        Text("Choose the iCloud folder your community shares. Everything published from your Mac appears here instantly.")
                    } actions: {
                        Button("Choose Folder…") { choosingFolder = true }
                    }
                } else {
                    let entries = model.index.timeline.reversed()
                        .filter { !showingTranscriptsOnly || isTranscript($0.doc) }
                    List(entries) { entry in
                        Button {
                            openWindow(id: "reader", value: entry.doc.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.doc.title)
                                    .lineLimit(1)
                                Text("\(entry.doc.displayAuthor) · \(entry.doc.listedDateText)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .safeAreaInset(edge: .top) {
                        Picker("Showing", selection: $showingTranscriptsOnly) {
                            Text("All Documents").tag(false)
                            Text("Transcripts").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                    }
                }
            }
            .navigationTitle("Origami Text")
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        choosingFolder = true
                    } label: {
                        Label("Choose Folder", systemImage: "folder")
                    }
                    Button {
                        openWindow(id: "space")
                    } label: {
                        Label("Knowledge Space", systemImage: "circle.hexagongrid")
                    }
                    .disabled(model.index.folderURL == nil)
                    Button {
                        openWindow(id: "zz")
                    } label: {
                        Label("zzStructure", systemImage: "circle.grid.cross")
                    }
                }
            }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.openFolder(url) }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active { model.index.rescan() }
        }
    }
}

/// The full article, opened by double-tapping a card in the Knowledge
/// Space (or a row in the library).
struct VisionReaderView: View {
    @Environment(VisionModel.self) private var model
    let docID: String
    /// The speaker whose statements are being browsed, sheet-presented.
    @State private var browsingSpeaker: SpeakerSelection?

    private struct SpeakerSelection: Identifiable {
        let name: String
        var id: String { name }
    }

    var body: some View {
        if let doc = model.index.byID[docID]?.doc {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(doc.title)
                        .font(.system(size: 32, design: .serif))
                        .padding(.bottom, 4)
                    Text("\(doc.displayAuthor) · \(doc.listedDateText)")
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 20)
                    let appendixIDs = doc.visualMetaParagraphIDs
                    ForEach((doc.body ?? []).filter { !appendixIDs.contains($0.id) }) { paragraph in
                        VStack(alignment: .leading, spacing: 2) {
                            // The attribution is an affordance here as on
                            // the Mac: the name opens everything this
                            // person has said across the library.
                            if let speaker = paragraph.speaker {
                                Button {
                                    browsingSpeaker = SpeakerSelection(name: speaker)
                                } label: {
                                    Text(speaker)
                                        .font(.system(size: 12, weight: .semibold))
                                        .kerning(0.8)
                                        .textCase(.uppercase)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Everything \(speaker) has said in this library")
                            }
                            Text(paragraph.renderedText)
                                .font(font(for: paragraph))
                                .textSelection(.enabled)
                        }
                        .padding(.bottom, 12)
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(28)
            }
            .navigationTitle(doc.title)
            .sheet(item: $browsingSpeaker) { selection in
                VisionSpeakerStatementsView(name: selection.name)
            }
        } else {
            ContentUnavailableView("Document Not Available", systemImage: "doc",
                                   description: Text("This document is not in the library folder."))
        }
    }

    private func font(for paragraph: LiquidDoc.Paragraph) -> Font {
        let size: CGFloat = switch paragraph.effectiveHeading {
        case 1: 28
        case 2: 23
        case 3: 19
        default: 17
        }
        return .system(size: size,
                       weight: paragraph.effectiveHeading == nil ? .regular : .bold,
                       design: .serif)
    }
}

/// zzStructure Dimensional Navigation, spatially: the same engine, views,
/// and weave semantics as the Mac navigator, with the Z axis made literal —
/// a cell's place on the bound depth rank pulls it toward you (negward) or
/// pushes it away (posward). Tap to make a cell accursed; double-tap a
/// document cell to read it. Virtual copies render dashed: wormholes.
struct VisionZZView: View {
    @Environment(VisionModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    private var store: ZZStructure { ZZStore.shared }

    @State private var accursedID: UUID?
    @State private var axes = AxisBinding(x: ZZStructure.System.dimensions,
                                          y: ZZStructure.System.namespaceMembers,
                                          z: nil)
    @State private var viewKey = HView.key

    private static let cellSize = CGSize(width: 190, height: 64)
    private static let gap = CGSize(width: 28, height: 26)
    private static let depthStep: CGFloat = 110   // points per z rank step

    private var placed: [PlacedCell] {
        guard let accursedID else { return [] }
        return ZZViewRegistry.view(for: viewKey)
            .layout(accursed: accursedID, axes: axes, in: store)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(placed) { cell in
                    cellView(cell)
                        .hoverEffect()
                        .position(x: geometry.size.width / 2
                                    + CGFloat(cell.x) * (Self.cellSize.width + Self.gap.width),
                                  y: geometry.size.height / 2
                                    + CGFloat(cell.y) * (Self.cellSize.height + Self.gap.height))
                        .offset(z: CGFloat(-cell.z) * Self.depthStep)
                }
            }
            .animation(.spring(duration: 0.35), value: placed)
        }
        .ornament(attachmentAnchor: .scene(.bottom)) { controls }
        .onAppear {
            if accursedID == nil {
                accursedID = ZZStructure.System.cellID(for: ZZStructure.System.dimensions)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Picker("View", selection: $viewKey) {
                ForEach(ZZViewRegistry.all.map { $0.key }, id: \.self) { key in
                    Text(ZZViewRegistry.all.first { $0.key == key }?.displayName ?? key)
                        .tag(key)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
            dimensionPicker("X", selection: $axes.x)
            dimensionPicker("Y", selection: $axes.y)
            Picker("Z", selection: $axes.z) {
                Text("Z: flat").tag(UUID?.none)
                ForEach(store.allDimensions()) { dimension in
                    Text("Z: \(dimension.qualifiedName)").tag(UUID?.some(dimension.id))
                }
            }
            .frame(width: 220)
            Menu {
                ForEach(model.index.timeline.reversed()) { entry in
                    Button(entry.doc.title) { weave(documentID: entry.doc.id) }
                }
            } label: {
                Label("Weave Document", systemImage: "plus.circle")
            }
        }
        .padding(12)
        .glassBackgroundEffect()
    }

    private func dimensionPicker(_ title: String, selection: Binding<UUID>) -> some View {
        Picker(title, selection: selection) {
            ForEach(store.allDimensions()) { dimension in
                Text("\(title): \(dimension.qualifiedName)").tag(dimension.id)
            }
        }
        .frame(width: 220)
    }

    private func cellView(_ placedCell: PlacedCell) -> some View {
        let isAccursed = placedCell.cellID == accursedID && !placedCell.isVirtualCopy
        return VStack(alignment: .leading, spacing: 2) {
            Text(label(for: placedCell.cellID))
                .font(.system(size: 13, weight: isAccursed ? .semibold : .regular, design: .serif))
                .lineLimit(2)
            Text(placedCell.isVirtualCopy ? "wormhole" : kindName(of: placedCell.cellID))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: Self.cellSize.width, height: Self.cellSize.height, alignment: .leading)
        .background {
            if isAccursed {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(red: 0.99, green: 0.97, blue: 0.92))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.yellow.opacity(0.9), lineWidth: 1.5))
            }
        }
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 10),
                               displayMode: isAccursed ? .never : .always)
        .overlay {
            if placedCell.isVirtualCopy {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.white.opacity(0.6),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .foregroundStyle(isAccursed ? AnyShapeStyle(.black) : AnyShapeStyle(.primary))
        .onTapGesture(count: 2) { open(placedCell.cellID) }
        .onTapGesture {
            withAnimation(.spring(duration: 0.35)) { accursedID = placedCell.cellID }
        }
    }

    private func weave(documentID: String) {
        let cell = store.cell(forDocument: documentID)
        defer { store.save() }
        guard let accursedID, accursedID != cell else {
            accursedID = cell
            return
        }
        if (try? store.link(accursedID, poswardTo: cell, along: axes.x, splice: true)) != nil {
            withAnimation(.spring(duration: 0.35)) { self.accursedID = cell }
        }
    }

    private func label(for cellID: UUID) -> String {
        switch store.cells[cellID]?.kind {
        case .document(let documentID):
            return model.index.byID[documentID]?.doc.title ?? documentID
        case .dimension(let dimensionID):
            return store.dimensions[dimensionID]?.qualifiedName ?? "dimension"
        case .view(let viewID):
            return ZZViewRegistry.all.first { $0.key == viewID }?.displayName ?? viewID
        case .namespaceHead(let name):
            return "namespace \(name)"
        case .clone(let head):
            return label(for: head)
        case .plain:
            return "cell"
        case nil:
            return "?"
        }
    }

    private func kindName(of cellID: UUID) -> String {
        switch store.cells[cellID]?.kind {
        case .document: "document"
        case .dimension: "dimension"
        case .view: "view"
        case .namespaceHead: "namespace"
        case .clone: "clone"
        case .plain: "cell"
        case nil: "unknown"
        }
    }

    private func open(_ cellID: UUID) {
        let head = store.contentHead(of: cellID)
        if case .document(let documentID)? = store.cells[head]?.kind,
           model.index.byID[documentID] != nil {
            openWindow(id: "reader", value: documentID)
        }
    }
}

/// Everything the named person has said across the library's transcripts —
/// the Mac author page's speaker section, as a sheet. Tap a statement to
/// open the meeting it was spoken in.
struct VisionSpeakerStatementsView: View {
    @Environment(VisionModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    let name: String

    /// LibraryInsights.statements(by:) — restated here because that file
    /// belongs to the Mac target; same rule, same ordering.
    private var statements: [SpokenStatement] {
        var result: [SpokenStatement] = []
        for entry in model.index.byID.values {
            for paragraph in entry.doc.body ?? []
            where paragraph.speaker?.caseInsensitiveCompare(name) == .orderedSame {
                result.append(SpokenStatement(doc: entry.doc, paragraph: paragraph))
            }
        }
        return result.sorted { lhs, rhs in
            if lhs.doc.listedDate != rhs.doc.listedDate { return lhs.doc.listedDate > rhs.doc.listedDate }
            if lhs.doc.id != rhs.doc.id { return lhs.doc.id < rhs.doc.id }
            return lhs.paragraph.id.localizedStandardCompare(rhs.paragraph.id) == .orderedAscending
        }
    }

    private struct SpokenStatement: Identifiable {
        let doc: LiquidDoc
        let paragraph: LiquidDoc.Paragraph
        var id: String { "\(doc.id)#\(paragraph.id)" }
    }

    var body: some View {
        NavigationStack {
            let statements = statements
            List(statements) { statement in
                Button {
                    dismiss()
                    openWindow(id: "reader", value: statement.doc.id)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(statement.paragraph.displayText)
                            .lineLimit(4)
                        Text("\(statement.doc.title) · \(statement.doc.listedDateText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle(name)
            .overlay {
                if statements.isEmpty {
                    ContentUnavailableView("Nothing on Record", systemImage: "text.bubble",
                                           description: Text("\(name) has no statements in this library's transcripts."))
                }
            }
            .toolbar {
                Button("Done") { dismiss() }
            }
        }
        .frame(minWidth: 520, minHeight: 480)
    }
}
#endif
