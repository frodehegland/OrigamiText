#if os(macOS)
import SwiftUI
import AppKit

// MARK: - What the reader keeps

/// The reader's own arrangement of a book's Map, kept apart from the book:
/// Author's published positions are never rewritten (Profile 1.0 §10.3,
/// §15). Moves, gathers and arrangements are kept per book and per view
/// in UserDefaults; Layout ▸ Author's Layout brings the published
/// arrangement back. Saved views are the reader's too, never the book's.
enum ReaderMapStore {
    struct SavedView: Codable, Identifiable, Hashable {
        var id = UUID()
        var name: String
        var positions: [String: [Double]]
    }

    private static func positionsKey(_ book: String, _ view: String) -> String {
        "readerMap.positions.\(book).\(view)"
    }
    private static func viewsKey(_ book: String) -> String { "readerMap.views.\(book)" }

    static func positions(book: String, view: String) -> [String: CGPoint]? {
        guard let raw = UserDefaults.standard.dictionary(forKey: positionsKey(book, view))
                as? [String: [Double]] else { return nil }
        return raw.compactMapValues { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
    }

    static func setPositions(_ positions: [String: CGPoint]?, book: String, view: String) {
        let key = positionsKey(book, view)
        guard let positions else { UserDefaults.standard.removeObject(forKey: key); return }
        UserDefaults.standard.set(positions.mapValues { [Double($0.x), Double($0.y)] }, forKey: key)
    }

    static func savedViews(book: String) -> [SavedView] {
        guard let data = UserDefaults.standard.data(forKey: viewsKey(book)),
              let views = try? JSONDecoder().decode([SavedView].self, from: data) else { return [] }
        return views
    }

    static func setSavedViews(_ views: [SavedView], book: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(views), forKey: viewsKey(book))
    }
}

/// Whether a book carries a Map worth opening: a view with placed members.
extension LiquidDoc {
    var hasAuthoredMap: Bool { layouts.contains { !$0.positions.isEmpty } }
}

// MARK: - The Map

/// Author's Map, in the reader (after Author's CanvasViewController and
/// CanvasView): the book's concepts where the writer placed them, bare
/// text at rest; select one and its connections appear — solid where its
/// definition mentions another concept, light where another's definition
/// mentions it — with the mentioning sentence on hover and a pill at the
/// window's edge for every linked concept out of sight. Space focuses,
/// Tab selects what is connected, Z fits or returns, G gathers, ⌘F finds,
/// ⌘M returns to the text. Double-click reads a definition and offers
/// Show in Text. Everything Author lets a writer *author* — new concepts,
/// edited definitions, deletions — is left out: the book is the author's.
/// What the reader arranges is the reader's (ReaderMapStore).
struct ReaderMapView: View {
    let doc: LiquidDoc
    let extras: AuthoredMapExtras
    /// The book's stable key for the reader's own arrangement.
    let bookKey: String
    /// Opens a paragraph of the reading (Show in Text).
    let onShowInText: (String) -> Void
    /// Back to the text (⌘M, or the Map word).
    let onClose: () -> Void
    /// Selected on opening — for previews.
    var initialSelection: Set<String> = []
    /// The reading's own foot bar in Map mode, given the Map's left tools
    /// (Ask AI | Views) and right tools (Select | Show | Layout), as
    /// Author lays its Map bar out — the mode words stay in the middle,
    /// Map bold. Nil draws a stand-alone bar (previews).
    var footBar: ((AnyView, AnyView) -> AnyView)? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.undoManager) private var undoManager
    @AppStorage(AppSettings.readerThemeKey) private var themeRaw = ReaderTheme.highContrast.rawValue
    @AppStorage("readerMode") private var readerModeRaw = EPUBReaderMode.faithful.rawValue

    /// One member of the Map as drawn.
    struct Item: Identifiable {
        enum Kind { case concept, heading, passage, reference, other }
        let id: String
        let label: String
        let kind: Kind
        let definition: String
        /// The paragraph a passage or heading opens.
        let paragraphID: String?
    }

    @State private var viewIndex = 0
    @State private var positions: [String: CGPoint] = [:]
    @State private var selection: Set<String> = []
    @State private var links: [ReaderMapLink] = []
    @State private var hidden: Set<String> = []
    @State private var focusMode = false
    @State private var onlyInText = false
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// Z's other state: where the view stood before it fitted.
    @State private var unzoomed: (scale: CGFloat, offset: CGSize)?
    @State private var viewport: CGSize = .zero
    @State private var mapFrame: CGRect = .zero
    @State private var window: NSWindow?
    @State private var dragOrigin: [String: CGPoint]?
    @State private var dragMoved = false
    @State private var marqueeStart: CGPoint?
    @State private var marqueeBase: Set<String> = []
    @State private var marquee: CGRect?
    @State private var hoverPoint: CGPoint?
    @State private var showsFind = false
    @State private var findText = ""
    @State private var activeFind: String?
    @State private var definitionFor: String?
    @State private var showsAskAI = false
    @State private var aiQuestion = ""
    @State private var aiAnswer: String?
    @State private var aiRunning = false
    @State private var showsSaveView = false
    @State private var saveViewName = ""
    @State private var savedViews: [ReaderMapStore.SavedView] = []
    @State private var keyMonitor: Any?
    @State private var wheelMonitor: Any?

    /// Author's node face: the reading's body type at Author's default
    /// node size (Settings ▸ node font size 1 → 17 pt).
    private static let fontSize: CGFloat = 17
    private static let pillSize = CGSize(width: 120, height: 24)

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                canvas
                    .onAppear { viewport = proxy.size; mapFrame = proxy.frame(in: .global) }
                    .onChange(of: proxy.size) { _, size in viewport = size; mapFrame = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in mapFrame = frame }
            }
            .clipped()
            .overlay(alignment: .top) { if showsFind { findField } }
            if let footBar {
                footBar(AnyView(leftTools), AnyView(rightTools))
            } else {
                mapBar
            }
        }
        .background(themeBackground)
        .background(WindowFinder { window = $0 })
        .onAppear(perform: appear)
        .onDisappear(perform: disappear)
        .onChange(of: selection) { recomputeLinks() }
        // Another mode word chosen from the bar: the Map gives way to it.
        .onChange(of: readerModeRaw) { onClose() }
        .onChange(of: model.readingReferencesOn) { onClose() }
        .onChange(of: model.readingOverviewOn) { onClose() }
        .onChange(of: model.readingAnalysisKind) { onClose() }
        .onChange(of: viewIndex) { loadPositions(); recentre() }
    }

    // MARK: The canvas

    private var canvas: some View {
        let shown = visibleItems
        let sizes = Dictionary(uniqueKeysWithValues: items.map { ($0.id, size(of: $0)) })
        let linked = linkedIDs
        let hoveredLink = hoverPoint.flatMap { link(near: $0) }
        return ZStack(alignment: .topLeading) {
            // The ground: a drag draws the marquee, a click clears.
            themeBackground
                .contentShape(Rectangle())
                .gesture(marqueeGesture(shown: shown, sizes: sizes))

            Canvas { context, _ in
                for link in links {
                    guard let a = positions[link.from], let b = positions[link.to],
                          isShown(link.from, in: shown), isShown(link.to, in: shown) else { continue }
                    var path = Path()
                    path.move(to: screen(a))
                    path.addLine(to: screen(b))
                    context.stroke(path, with: .color(link.solid ? solidLine : lightLine),
                                   lineWidth: 0.5)
                }
            }
            .allowsHitTesting(false)

            ForEach(sectionLabels) { label in
                if let point = positions[label.key] {
                    Text(label.title)
                        .font(AppFonts.heading(Self.fontSize, weight: .bold))
                        .foregroundStyle(ink.opacity(0.7))
                        .fixedSize()
                        .scaleEffect(scale)
                        .position(screen(point))
                        .allowsHitTesting(false)
                }
            }

            ForEach(shown) { item in
                if let point = positions[item.id] {
                    node(item, linked: linked.contains(item.id))
                        .gesture(nodeGesture(item))
                        .contextMenu { nodeMenu(item) }
                        .popover(isPresented: definitionBinding(item.id), arrowEdge: .bottom) {
                            definitionCard(item)
                        }
                        .scaleEffect(scale)
                        .position(screen(point))
                }
            }

            if let hoveredLink, let label = hoverLabel(for: hoveredLink) {
                label
            }

            if let marquee {
                Rectangle()
                    .fill(Color.gray.opacity(0.1))
                    .overlay(Rectangle().strokeBorder(Color.gray.opacity(0.6), lineWidth: 1))
                    .frame(width: marquee.width, height: marquee.height)
                    .offset(x: marquee.minX, y: marquee.minY)
                    .allowsHitTesting(false)
            }

            offscreenPills(shown: shown, sizes: sizes)
        }
        .coordinateSpace(name: "map")
        .onContinuousHover(coordinateSpace: .named("map")) { phase in
            if case .active(let point) = phase { hoverPoint = point } else { hoverPoint = nil }
        }
    }

    private func node(_ item: Item, linked: Bool) -> some View {
        let selected = selection.contains(item.id)
        let found = activeFind != nil && selected
        var font = AppFonts.body(Self.fontSize, weight: item.kind == .heading ? .bold : nil)
        if item.kind == .reference { font = font.italic() }
        return Text(item.label)
            .font(font)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .foregroundStyle(selected ? Color.white : (linked ? linkedInk : ink))
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(selected ? selectedFill : (linked ? linkedFill : Color.clear)))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(selected ? selectedBorder : (linked ? linkedBorder : Color.clear),
                                  lineWidth: found ? 1.5 : 1))
            .opacity(hidden.contains(item.id) ? 0.75 : 1)
            .help(item.definition.isEmpty ? item.label : item.definition)
    }

    // MARK: Gestures

    /// A press selects as Author's handleSinglePress does — Shift adds,
    /// ⌘ toggles, a plain press on an unselected node selects it alone —
    /// and a drag moves the whole selection together. A click without a
    /// move on a node of a larger selection narrows to that node; a
    /// double-click reads its definition.
    private func nodeGesture(_ item: Item) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("map"))
            .onChanged { value in
                if dragOrigin == nil {
                    let flags = NSEvent.modifierFlags
                    if flags.contains(.shift) {
                        selection.insert(item.id)
                    } else if flags.contains(.command) {
                        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
                    } else if !selection.contains(item.id) {
                        selection = [item.id]
                    }
                    dragOrigin = positions.filter { selection.contains($0.key) }
                    dragMoved = false
                }
                let delta = CGSize(width: value.translation.width / scale,
                                   height: value.translation.height / scale)
                if dragMoved || hypot(value.translation.width, value.translation.height) > 3,
                   let origin = dragOrigin {
                    dragMoved = true
                    for (id, point) in origin {
                        positions[id] = CGPoint(x: point.x + delta.width, y: point.y + delta.height)
                    }
                }
            }
            .onEnded { _ in
                defer { dragOrigin = nil; dragMoved = false }
                if dragMoved, let origin = dragOrigin {
                    var before = positions
                    for (id, point) in origin { before[id] = point }
                    commit(from: before, action: "Move Items")
                    return
                }
                if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                    selection = [item.id]
                    definitionFor = item.id
                } else if NSEvent.modifierFlags.intersection([.shift, .command]).isEmpty {
                    selection = [item.id]
                }
            }
    }

    private func marqueeGesture(shown: [Item], sizes: [String: CGSize]) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("map"))
            .onChanged { value in
                if marqueeStart == nil {
                    marqueeStart = value.startLocation
                    marqueeBase = NSEvent.modifierFlags.contains(.shift) ? selection : []
                    definitionFor = nil
                }
                guard let start = marqueeStart,
                      hypot(value.translation.width, value.translation.height) > 3 else { return }
                let rect = CGRect(x: min(start.x, value.location.x), y: min(start.y, value.location.y),
                                  width: abs(value.location.x - start.x),
                                  height: abs(value.location.y - start.y))
                marquee = rect
                var picked = marqueeBase
                for item in shown {
                    guard let point = positions[item.id] else { continue }
                    if rect.intersects(screenRect(point, size: sizes[item.id] ?? .zero)) { picked.insert(item.id) }
                }
                if picked != selection { selection = picked }
            }
            .onEnded { _ in
                if marquee == nil, !NSEvent.modifierFlags.contains(.shift) { selection = [] }
                marquee = nil
                marqueeStart = nil
            }
    }

    // MARK: Menus

    @ViewBuilder private func nodeMenu(_ item: Item) -> some View {
        Button("Read Definition") { selection = [item.id]; definitionFor = item.id }
        if appearsInText(item) {
            Button("Show in Text") { showInText(item) }
        }
        Divider()
        Button("Focus") { if !selection.contains(item.id) { selection = [item.id] }; focusMode.toggle() }
        Button("Select Connected") { if !selection.contains(item.id) { selection = [item.id] }; selectConnected() }
        if selection.count > 1, selection.contains(item.id) {
            Menu("Layout") { arrangeItems }
        }
        Divider()
        Button("Hide") { hideSelection(including: item.id) }
    }

    @ViewBuilder private var arrangeItems: some View {
        Button("Gather") { gather() }
        Menu("Align") {
            Button("Left") { arrange(action: "Align Left") { ReaderMapLayouts.align($0, ids: selection, sizes: sizesByID, to: .left) } }
            Button("Center") { arrange(action: "Align Center") { ReaderMapLayouts.align($0, ids: selection, sizes: sizesByID, to: .center) } }
            Button("Right") { arrange(action: "Align Right") { ReaderMapLayouts.align($0, ids: selection, sizes: sizesByID, to: .right) } }
        }
        .disabled(selection.count < 2)
        Menu("Distribute") {
            Button("Vertically") { arrange(action: "Distribute") { ReaderMapLayouts.distribute($0, ids: selection, sizes: sizesByID, along: .vertical) } }
            Button("Horizontally") { arrange(action: "Distribute") { ReaderMapLayouts.distribute($0, ids: selection, sizes: sizesByID, along: .horizontal) } }
        }
        .disabled(selection.count < 2)
        Menu("Sort") {
            Button("Vertical") { sort(.vertical, reverse: false) }
            Button("Vertical Reverse") { sort(.vertical, reverse: true) }
            Button("Horizontal") { sort(.horizontal, reverse: false) }
            Button("Horizontal Reverse") { sort(.horizontal, reverse: true) }
        }
        .disabled(selection.count < 2)
    }

    /// Author's Map-mode bar, left: Ask AI | Views, and the find in force.
    private var leftTools: some View {
        HStack(spacing: 10) {
            Button("Ask AI") { showsAskAI = true }
                .popover(isPresented: $showsAskAI) { askAIForm }
            toolSeparator
            viewsMenu
            if let activeFind {
                toolSeparator
                Text("Find: \(activeFind)")
                Button { clearFind() } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(.tertiary)
                    .help("Clear the find (Esc)")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// …and right: Select | Show | Layout.
    private var rightTools: some View {
        HStack(spacing: 10) {
            selectMenu
            toolSeparator
            showMenu
            toolSeparator
            layoutMenu
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var toolSeparator: some View {
        Rectangle().fill(.quaternary).frame(width: 1, height: 14)
    }

    private var selectMenu: some View {
        Menu("Select") {
            Button("All  \u{2318}A") { selectAll() }
            Button("Find\u{2026}") { showsFind = true }
            Button("Connected") { selectConnected() }.disabled(selection.isEmpty)
            Button("None") { selection = [] }.disabled(selection.isEmpty)
        }
    }

    private var showMenu: some View {
        Menu("Show") {
            Button("All") { focusMode = false; onlyInText = false }
            Toggle("Focus", isOn: $focusMode).disabled(selection.isEmpty)
            Toggle("Only Concepts in the Text", isOn: $onlyInText)
            Divider()
            Button("Hide Selection") { hideSelection(including: nil) }.disabled(selection.isEmpty)
            Button("Reveal Hidden") { hidden = [] }.disabled(hidden.isEmpty)
        }
    }

    private var layoutMenu: some View {
        Menu("Layout") {
            Button("Author\u{2019}s Layout") { restoreAuthorsLayout() }
            Divider()
            ForEach([ReaderMapAnalysis.magneticCenter, .islands, .spine, .orbits]) { kind in
                Button(kind.title) { analyse(kind) }
            }
            Divider()
            arrangeItems
        }
    }

    private var viewsMenu: some View {
        Menu("Views") {
            if doc.layouts.count > 1 {
                ForEach(Array(doc.layouts.enumerated()), id: \.offset) { index, layout in
                    Toggle(layout.name, isOn: Binding(get: { viewIndex == index },
                                                      set: { if $0 { viewIndex = index } }))
                }
                Divider()
            }
            ForEach(savedViews) { saved in
                Button(saved.name) { apply(saved) }
            }
            Button("Save View\u{2026}") { saveViewName = ""; showsSaveView = true }
            if !savedViews.isEmpty {
                Menu("Delete View") {
                    ForEach(savedViews) { saved in
                        Button(saved.name) { deleteView(saved) }
                    }
                }
            }
        }
        .popover(isPresented: $showsSaveView) { saveViewForm }
    }

    /// The stand-alone bar (previews): Author's three groups — Ask AI |
    /// Views at the left, the Map word bold in the middle, Select | Show |
    /// Layout at the right.
    private var mapBar: some View {
        HStack(spacing: 14) {
            HStack { leftTools; Spacer(minLength: 0) }.frame(maxWidth: .infinity)
            Button { onClose() } label: { Text("Map").fontWeight(.semibold) }
                .buttonStyle(.plain)
                .help("Back to the text (\u{2318}M)")
            HStack { Spacer(minLength: 0); rightTools }.frame(maxWidth: .infinity)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(themeBackground)
        .overlay(alignment: .top) { Divider() }
    }

    private var findField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find on the Map", text: $findText)
                .textFieldStyle(.plain)
                .frame(width: 240)
                .onSubmit { runFind() }
                .onExitCommand { showsFind = false }
            Button("Done") { showsFind = false }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 14)
    }

    private func definitionCard(_ item: Item) -> some View {
        let mentions = ReaderMapLinks.links(forSelection: [item.id], among: mapNodes)
            .filter(\.solid).compactMap { link in items.first { $0.id == link.to }?.label }
        return VStack(alignment: .leading, spacing: 10) {
            Text(item.label).font(AppFonts.heading(17, weight: .bold))
            Text(item.definition.isEmpty ? "No definition." : item.definition)
                .font(AppFonts.body(15))
                .foregroundStyle(item.definition.isEmpty ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !mentions.isEmpty {
                Text("Mentions " + mentions.sorted().joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if appearsInText(item) {
                HStack {
                    Spacer()
                    Button("Show in Text") { showInText(item) }
                        .help("Find \u{201C}\(item.label)\u{201D} in the text, shown in Outline")
                }
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private var saveViewForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save this arrangement as a view of your own.").font(.callout)
            TextField("Name", text: $saveViewName).frame(width: 240).onSubmit(saveView)
            HStack { Spacer(); Button("Save", action: saveView).disabled(saveViewName.trimmingCharacters(in: .whitespaces).isEmpty) }
        }
        .padding(14)
    }

    /// Author's Ask AI on the Map: the question with every concept as
    /// "definition : phrase", one per line — through OrigamiLLM, so the
    /// reader's chosen model answers.
    private var askAIForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask about this Map\u{2019}s concepts").font(.headline)
            TextField("Question", text: $aiQuestion, axis: .vertical)
                .lineLimit(1...4)
                .frame(width: 360)
                .onSubmit(askAI)
            HStack {
                if aiRunning { ProgressView().controlSize(.small) }
                Spacer()
                Button("Ask", action: askAI)
                    .disabled(aiRunning || aiQuestion.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let aiAnswer {
                ScrollView {
                    Text(aiAnswer).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 360, height: 220)
            }
        }
        .padding(14)
    }

    // MARK: Off-screen pills and hover labels

    /// Author's off-screen ghosts: each linked concept beyond the window
    /// stands as a 120×24 pill 10 pt inside the edge where its line
    /// leaves; a click brings it into view (the reader's version of Bring
    /// Node Here — the book's arrangement is not changed).
    @ViewBuilder private func offscreenPills(shown: [Item], sizes: [String: CGSize]) -> some View {
        let pills = offscreenTargets(shown: shown, sizes: sizes)
        ForEach(pills, id: \.id) { pill in
            Text(pill.label)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(width: Self.pillSize.width, height: Self.pillSize.height)
                .background(RoundedRectangle(cornerRadius: 5).fill(themeBackground.opacity(0.92)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(ink.opacity(0.4), lineWidth: 0.5))
                .foregroundStyle(ink)
                .contentShape(Rectangle())
                .onTapGesture { centre(on: pill.id) }
                .help("Bring \(pill.label) into view")
                .position(pill.point)
        }
    }

    private struct Pill { let id: String; let label: String; let point: CGPoint }

    private func offscreenTargets(shown: [Item], sizes: [String: CGSize]) -> [Pill] {
        guard !selection.isEmpty, viewport.width > 0 else { return [] }
        let bounds = CGRect(origin: .zero, size: viewport)
        let inner = bounds.insetBy(dx: 10 + Self.pillSize.width / 2, dy: 10 + Self.pillSize.height / 2)
        var pills: [Pill] = []
        for link in links {
            let (near, far) = selection.contains(link.from) ? (link.from, link.to) : (link.to, link.from)
            guard !selection.contains(far), isShown(far, in: shown),
                  let farPoint = positions[far], let nearPoint = positions[near],
                  !pills.contains(where: { $0.id == far }) else { continue }
            let target = screen(farPoint)
            if bounds.insetBy(dx: 4, dy: 4).contains(target) { continue }
            let origin = screen(nearPoint)
            guard let exit = Self.exitPoint(from: origin, toward: target, in: inner) else { continue }
            var point = exit
            // Pills on the same stretch of edge stack 4 pt apart.
            while pills.contains(where: { abs($0.point.x - point.x) < Self.pillSize.width
                                          && abs($0.point.y - point.y) < Self.pillSize.height + 4 }) {
                point.y += Self.pillSize.height + 4
                if point.y > inner.maxY { point.y = inner.minY; point.x -= Self.pillSize.width + 4 }
            }
            pills.append(Pill(id: far, label: items.first { $0.id == far }?.label ?? far, point: point))
        }
        return pills
    }

    /// Where the segment from `origin` toward `target` crosses `rect`
    /// (origin clamped inside it first).
    private static func exitPoint(from origin: CGPoint, toward target: CGPoint, in rect: CGRect) -> CGPoint? {
        let start = CGPoint(x: min(max(origin.x, rect.minX), rect.maxX),
                            y: min(max(origin.y, rect.minY), rect.maxY))
        let dx = target.x - start.x, dy = target.y - start.y
        guard dx != 0 || dy != 0 else { return nil }
        var t = CGFloat.infinity
        if dx > 0 { t = min(t, (rect.maxX - start.x) / dx) }
        if dx < 0 { t = min(t, (rect.minX - start.x) / dx) }
        if dy > 0 { t = min(t, (rect.maxY - start.y) / dy) }
        if dy < 0 { t = min(t, (rect.minY - start.y) / dy) }
        guard t.isFinite else { return nil }
        let clampedT = min(max(t, 0), 1)
        return CGPoint(x: start.x + dx * clampedT, y: start.y + dy * clampedT)
    }

    /// Within 12 pt of a drawn line, the first sentence of the definition
    /// that mentions the other concept (Author's transient connection
    /// label) — solid links only; light ones carry no sentence.
    private func link(near point: CGPoint) -> ReaderMapLink? {
        var best: (ReaderMapLink, CGFloat)?
        for link in links where link.solid && !link.sentences.isEmpty {
            guard let a = positions[link.from], let b = positions[link.to] else { continue }
            let distance = Self.distance(from: point, toSegment: screen(a), screen(b))
            if distance <= 12, distance < (best?.1 ?? .infinity) { best = (link, distance) }
        }
        return best?.0
    }

    private func hoverLabel(for link: ReaderMapLink) -> AnyView? {
        guard let a = positions[link.from], let b = positions[link.to],
              let sentence = link.sentences.first else { return nil }
        let mid = CGPoint(x: (screen(a).x + screen(b).x) / 2, y: (screen(a).y + screen(b).y) / 2)
        return AnyView(
            Text(sentence)
                .font(.callout)
                .foregroundStyle(colorScheme == .dark ? Color(white: 0.855) : Color(white: 0.42))
                .frame(maxWidth: 320)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(themeBackground)
                    .shadow(color: .black.opacity(0.5), radius: 10, x: -5, y: 2))
                .position(mid)
                .allowsHitTesting(false))
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: The members

    /// The current view's members, each named from what the document
    /// knows of it: a concept (with its definition), a heading or
    /// passage, a reference — the same resolution the book's map always had.
    private var items: [Item] {
        guard let layout = doc.layouts[safe: viewIndex] else { return [] }
        let body = doc.body ?? []
        return layout.positions.map { position in
            let ref = position.id
            let bare = ref.split(separator: "#").last.map(String.init) ?? ref
            if let concept = doc.concepts.first(where: { $0.id == ref || $0.id == bare }) {
                let definition = concept.userDefinition.flatMap { $0.isEmpty ? nil : $0 } ?? concept.description
                return Item(id: ref, label: extras.labels[ref] ?? concept.name, kind: .concept,
                            definition: definition, paragraphID: nil)
            }
            if let paragraph = body.first(where: { $0.id == ref }) ?? AnnotationAnchor.sameElement(ref, in: body) {
                let words = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let short = words.count > 90 ? String(words.prefix(90)) + "\u{2026}" : words
                return Item(id: ref, label: extras.labels[ref] ?? short,
                            kind: paragraph.heading != nil ? .heading : .passage,
                            definition: "", paragraphID: paragraph.id)
            }
            if let reference = doc.references.first(where: { $0.id == ref || $0.id == bare }) {
                return Item(id: ref, label: extras.labels[ref] ?? reference.citedAs ?? ref,
                            kind: .reference, definition: reference.bibtex, paragraphID: nil)
            }
            return Item(id: ref, label: extras.labels[ref] ?? ref, kind: .other,
                        definition: "", paragraphID: nil)
        }
    }

    private var mapNodes: [ReaderMapNode] {
        items.filter { $0.kind == .concept }.map {
            ReaderMapNode(id: $0.id, name: $0.label, definition: $0.definition, size: size(of: $0))
        }
    }

    private var sizesByID: [String: CGSize] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.id, size(of: $0)) })
    }

    /// Show ▸ filters and Focus, as Author's shouldShow decides.
    private var visibleItems: [Item] {
        let inText = onlyInText ? bodyTextLowercased : nil
        let focusSet = focusMode && !selection.isEmpty ? selection.union(linkedIDs) : nil
        return items.filter { item in
            if hidden.contains(item.id) { return false }
            if let focusSet, !focusSet.contains(item.id) { return false }
            if let inText, item.kind == .concept, !inText.contains(item.label.lowercased()) { return false }
            return true
        }
    }

    private func isShown(_ id: String, in shown: [Item]) -> Bool { shown.contains { $0.id == id } }

    private var linkedIDs: Set<String> {
        Set(links.flatMap { [$0.from, $0.to] }).subtracting(selection)
    }

    private var bodyTextLowercased: String {
        (doc.body ?? []).map(\.text).joined(separator: "\n").lowercased()
    }

    private struct SectionLabel: Identifiable { let key: String; let title: String; var id: String { key } }

    private var sectionLabels: [SectionLabel] {
        sections.enumerated().map { SectionLabel(key: ReaderMapLayouts.sectionKey($0.offset), title: $0.element.title) }
    }

    /// The document's headings in order, with the text under each — Spine's sections.
    private var sections: [(title: String, text: String)] {
        var out: [(title: String, text: String)] = []
        for paragraph in doc.body ?? [] {
            if paragraph.heading != nil {
                out.append((paragraph.text, ""))
            } else if !out.isEmpty {
                out[out.count - 1].text += paragraph.text + "\n"
            }
        }
        return out
    }

    /// A node's drawn size in canvas points: its label measured in the
    /// face it is drawn in, plus Author's 5 pt and 3 pt insets.
    private func size(of item: Item) -> CGSize {
        let family = AppFonts.bodyFamily
        let base = NSFont(name: family, size: Self.fontSize) ?? .systemFont(ofSize: Self.fontSize)
        let font = item.kind == .heading
            ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
        let measured = (item.label as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(measured.width) + 10, height: ceil(measured.height) + 6)
    }

    // MARK: Coordinates

    /// Canvas points (centre-origin, y down — Author's canvas) to the
    /// view, and the view's rect for a node.
    private func screen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: viewport.width / 2 + offset.width + point.x * scale,
                y: viewport.height / 2 + offset.height + point.y * scale)
    }

    private func screenRect(_ point: CGPoint, size: CGSize) -> CGRect {
        let centre = screen(point)
        return CGRect(x: centre.x - size.width * scale / 2, y: centre.y - size.height * scale / 2,
                      width: size.width * scale, height: size.height * scale)
    }

    /// The book's positions for the current view, in canvas points with
    /// y down: a y-up view (§10.3) is flipped once; pre-1.0 maps written
    /// in 0–1 fractions are spread onto Author's canvas.
    private var authoredPositions: [String: CGPoint] {
        guard let layout = doc.layouts[safe: viewIndex] else { return [:] }
        let yUp = extras.yUpViews.contains(layout.sourceID ?? layout.name)
        let extent = layout.positions.map { max(abs($0.x), abs($0.y)) }.max() ?? 0
        let spread: Double = extent > 0 && extent <= 2 ? 900 : 1
        var out: [String: CGPoint] = [:]
        for position in layout.positions {
            out[position.id] = CGPoint(x: position.x * spread, y: (yUp ? -position.y : position.y) * spread)
        }
        return out
    }

    private var viewKey: String {
        doc.layouts[safe: viewIndex].map { $0.sourceID ?? $0.name } ?? "view"
    }

    // MARK: Actions

    private func appear() {
        model.isReaderMapShown = true
        savedViews = ReaderMapStore.savedViews(book: bookKey)
        loadPositions()
        recentre()
        if !initialSelection.isEmpty { selection = initialSelection; recomputeLinks() }
        installMonitors()
    }

    private func disappear() {
        model.isReaderMapShown = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        keyMonitor = nil
        wheelMonitor = nil
    }

    private func loadPositions() {
        positions = ReaderMapStore.positions(book: bookKey, view: viewKey)
            .map { authoredPositions.merging($0) { _, mine in mine } } ?? authoredPositions
        selection = []
        hidden = []
        focusMode = false
    }

    private func recomputeLinks() {
        links = selection.isEmpty ? [] : ReaderMapLinks.links(forSelection: selection, among: mapNodes)
        if selection.isEmpty { focusMode = false }
    }

    /// Opening as Author's Map opens: at actual size, centred — here on
    /// the arrangement itself rather than the canvas's middle, since a
    /// book's origin is arbitrary (§10.3).
    private func recentre() {
        let points = visibleItems.compactMap { positions[$0.id] }
        guard !points.isEmpty else { scale = 1; offset = .zero; return }
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        scale = 1
        offset = CGSize(width: -(minX + maxX) / 2, height: -(minY + maxY) / 2)
        unzoomed = nil
    }

    private func centre(on id: String) {
        guard let point = positions[id] else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            offset = CGSize(width: -point.x * scale, height: -point.y * scale)
        }
    }

    /// Z: zoom out to fit everything shown (40 pt padding, never below
    /// 0.25, never in); Z again returns to where the reader was.
    private func toggleZoom() {
        if let unzoomed {
            withAnimation(.easeInOut(duration: 0.25)) { scale = unzoomed.scale; offset = unzoomed.offset }
            self.unzoomed = nil
            return
        }
        let rects = visibleItems.compactMap { item -> CGRect? in
            guard let point = positions[item.id] else { return nil }
            let size = size(of: item)
            return CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                          width: size.width, height: size.height)
        }
        guard let first = rects.first else { return }
        let union = rects.dropFirst().reduce(first) { $0.union($1) }
        let fit = ReaderMapLayouts.fitScale(for: rects, in: viewport)
        unzoomed = (scale, offset)
        withAnimation(.easeInOut(duration: 0.25)) {
            scale = fit
            offset = CGSize(width: -union.midX * fit, height: -union.midY * fit)
        }
    }

    private func zoom(by factor: CGFloat, around point: CGPoint) {
        let newScale = min(max(scale * factor, 0.25), 3)
        let ratio = newScale / scale
        // Keep the canvas point under the pointer where it is.
        let centre = CGPoint(x: viewport.width / 2 + offset.width, y: viewport.height / 2 + offset.height)
        offset = CGSize(width: offset.width + (point.x - centre.x) * (1 - ratio),
                        height: offset.height + (point.y - centre.y) * (1 - ratio))
        scale = newScale
        unzoomed = nil
    }

    private func selectAll() { selection = Set(visibleItems.map(\.id)) }

    /// Tab: the selection becomes what it links to.
    private func selectConnected() {
        let connected = linkedIDs
        if !connected.isEmpty { selection = connected }
    }

    private func hideSelection(including id: String?) {
        var hiding = selection
        if let id { hiding.insert(id) }
        hidden.formUnion(hiding)
        selection.subtract(hiding)
    }

    private func runFind() {
        let term = findText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { clearFind(); return }
        let lowered = term.lowercased()
        selection = Set(visibleItems.filter {
            $0.label.lowercased().contains(lowered) || $0.definition.lowercased().contains(lowered)
        }.map(\.id))
        activeFind = term
        showsFind = false
    }

    private func clearFind() {
        activeFind = nil
        findText = ""
        selection = []
    }

    /// Whether the text uses this member at all — Show in Text is
    /// offered only then. A passage or heading is the text itself.
    private func appearsInText(_ item: Item) -> Bool {
        if item.paragraphID != nil { return true }
        let name = item.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !name.isEmpty && bodyTextLowercased.contains(name)
    }

    /// Show in Text does what Find does: the reading returns folded to
    /// its headings with every use of the name around them, highlighted,
    /// ⌘G stepping through (AppModel.showFindFold). A passage or heading
    /// on the Map is a place, not a term — the reading opens at it.
    private func showInText(_ item: Item) {
        definitionFor = nil
        onClose()
        if let paragraphID = item.paragraphID {
            onShowInText(paragraphID)
        } else {
            model.showFindFold(term: item.label.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func definitionBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { definitionFor == id }, set: { if !$0 { definitionFor = nil } })
    }

    // MARK: Arranging, with undo

    /// Positions change, are kept for this book and view, and can be
    /// undone — Author's undoable moveTo.
    private func commit(from before: [String: CGPoint], action: String) {
        let after = positions
        ReaderMapStore.setPositions(after, book: bookKey, view: viewKey)
        let restore = self
        undoManager?.registerUndo(withTarget: model) { _ in
            restore.positions = before
            ReaderMapStore.setPositions(before, book: restore.bookKey, view: restore.viewKey)
            restore.undoManager?.registerUndo(withTarget: restore.model) { _ in
                restore.positions = after
                ReaderMapStore.setPositions(after, book: restore.bookKey, view: restore.viewKey)
            }
        }
        undoManager?.setActionName(action)
    }

    private func arrange(action: String, _ change: ([String: CGPoint]) -> [String: CGPoint]) {
        let before = positions
        withAnimation(.easeInOut(duration: 0.3)) { positions = change(positions) }
        commit(from: before, action: action)
    }

    /// G: each press draws the selection (or, with one or none selected,
    /// everything shown) a fifth of the way together.
    private func gather() {
        let ids = selection.count > 1 ? selection : Set(visibleItems.map(\.id))
        arrange(action: "Gather") { ReaderMapLayouts.gather($0, ids: ids, sizes: sizesByID) }
    }

    private func sort(_ axis: ReaderMapLayouts.Axis, reverse: Bool) {
        let names = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.label) })
        arrange(action: "Sort") {
            ReaderMapLayouts.sort($0, ids: selection, names: names, sizes: sizesByID, along: axis, reverse: reverse)
        }
    }

    private func analyse(_ kind: ReaderMapAnalysis) {
        let computed = ReaderMapLayouts.analysis(kind, nodes: mapNodes, sections: sections)
        arrange(action: kind.title) { current in
            // Spine's section labels join; any earlier ones go.
            current.filter { !$0.key.hasPrefix("section:") }.merging(computed) { _, new in new }
        }
        recentre()
    }

    private func restoreAuthorsLayout() {
        let before = positions
        withAnimation(.easeInOut(duration: 0.3)) { positions = authoredPositions }
        ReaderMapStore.setPositions(nil, book: bookKey, view: viewKey)
        undoManager?.registerUndo(withTarget: model) { [self] _ in
            positions = before
            ReaderMapStore.setPositions(before, book: bookKey, view: viewKey)
        }
        undoManager?.setActionName("Author\u{2019}s Layout")
        recentre()
    }

    private func saveView() {
        let name = saveViewName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        savedViews.append(.init(name: name, positions: positions.mapValues { [Double($0.x), Double($0.y)] }))
        ReaderMapStore.setSavedViews(savedViews, book: bookKey)
        showsSaveView = false
    }

    private func apply(_ saved: ReaderMapStore.SavedView) {
        let restored = saved.positions.compactMapValues { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        arrange(action: saved.name) { current in current.merging(restored) { _, saved in saved } }
        recentre()
    }

    private func deleteView(_ saved: ReaderMapStore.SavedView) {
        savedViews.removeAll { $0.id == saved.id }
        ReaderMapStore.setSavedViews(savedViews, book: bookKey)
    }

    private func askAI() {
        let question = aiQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !aiRunning else { return }
        let concepts = items.filter { $0.kind == .concept }
            .map { "\($0.definition) : \($0.label)" }.joined(separator: "\n")
        aiRunning = true
        aiAnswer = nil
        Task {
            do {
                let reply = try await OrigamiLLM.shared.respond(
                    instructions: "You answer questions about the defined concepts of one document. Use the concepts given; say so when they do not answer the question.",
                    to: "The concepts of \u{201C}\(doc.title)\u{201D}, one per line as definition : concept:\n\n\(concepts)\n\nQuestion: \(question)")
                aiAnswer = reply.text
            } catch {
                aiAnswer = "The model could not answer: \(error.localizedDescription)"
            }
            aiRunning = false
        }
    }

    // MARK: Keys, scroll and pinch

    /// The Map's keys (Author's CanvasView keyDown and performKeyEquivalent),
    /// the scroll wheel as pan and the pinch as zoom. The reading's own
    /// monitors stand down while `isReaderMapShown` is set.
    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window, event.window === window, window.attachedSheet == nil else { return event }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if flags == .command, key == "m" { onClose(); return nil }
            // A field being typed in keeps its keys.
            if let editor = window.firstResponder as? NSTextView, editor.isEditable { return event }
            if flags == .command, key == "a" { selectAll(); return nil }
            if flags == .command, key == "f" { showsFind = true; return nil }
            guard flags.isEmpty else { return event }
            switch event.keyCode {
            case 49:   // Space — Focus
                if !selection.isEmpty { focusMode.toggle() } else { focusMode = false }
                return nil
            case 48:   // Tab — Select Connected
                selectConnected(); return nil
            case 53:   // Esc — a search first, then full screen as everywhere
                if activeFind != nil { clearFind() } else if definitionFor != nil { definitionFor = nil }
                else { window.toggleFullScreen(nil) }
                return nil
            default:
                break
            }
            switch key {
            case "z": toggleZoom(); return nil
            case "g": gather(); return nil
            default: return event
            }
        }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { event in
            guard let window, event.window === window, let content = window.contentView else { return event }
            let location = event.locationInWindow
            let point = CGPoint(x: location.x, y: content.bounds.height - location.y)
            guard mapFrame.contains(point) else { return event }
            let local = CGPoint(x: point.x - mapFrame.minX, y: point.y - mapFrame.minY)
            switch event.type {
            case .scrollWheel:
                let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                offset.width += event.scrollingDeltaX * step
                offset.height += event.scrollingDeltaY * step
                unzoomed = nil
            case .magnify:
                zoom(by: 1 + event.magnification, around: local)
            default:
                return event
            }
            return nil
        }
    }

    // MARK: Colours — Author's flow-node colours on the reading's theme

    private var theme: ReaderTheme { ReaderTheme(rawValue: themeRaw) ?? .highContrast }
    private var themeBackground: Color { theme.background(for: colorScheme) ?? Color(nsColor: .textBackgroundColor) }
    private var ink: Color { theme.textColor(for: colorScheme) ?? .primary }
    private var dark: Bool { colorScheme == .dark }
    private var selectedFill: Color { dark ? Color(white: 0.098) : Color(white: 0.455) }
    private var selectedBorder: Color { dark ? .white : .clear }
    private var linkedFill: Color { dark ? Color.white.opacity(0.14) : Color(white: 0.922) }
    private var linkedBorder: Color { dark ? Color.white.opacity(0.8) : Color.black.opacity(0.85) }
    private var linkedInk: Color { dark ? Color(white: 0.63) : Color(white: 0.35) }
    private var solidLine: Color { dark ? Color.white.opacity(0.8) : Color(white: 0.12).opacity(0.92) }
    private var lightLine: Color { ink.opacity(0.28) }
}

/// Hands back the window a view stands in, for the Map's event monitors —
/// once, when the view joins a window.
private struct WindowFinder: NSViewRepresentable {
    let found: (NSWindow?) -> Void
    init(_ found: @escaping (NSWindow?) -> Void) { self.found = found }

    final class Probe: NSView {
        var found: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            DispatchQueue.main.async { [found] in found?(window) }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.found = found
        return probe
    }
    func updateNSView(_ view: Probe, context: Context) {}
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// The four concepts of "Welcome to Origami Text", where Author put them
/// (y-up, as exported) — for the preview.
private func welcomeMapSample() -> LiquidDoc {
    var doc = LiquidDoc(format: LiquidDoc.knownFormat, id: "preview-welcome",
                        title: "Welcome to Origami Text", author: "Frode Hegland",
                        created: .now, body: [], links: [], wraps: nil,
                        fileURL: FileManager.default.temporaryDirectory)
    let epub = LiquidDoc.Concept(id: "EPUB", name: "EPUB", description: "A document format")
    let lab = LiquidDoc.Concept(id: "FTL", name: "Future Text Lab",
                                description: "Open lab for discussing the future of text.")
    let app = LiquidDoc.Concept(id: "APP", name: "Origami Text application",
                                description: "Software for reading EPUB with extended interactions for Origami Text Variant EPUB. Developed by the Future Text Lab.")
    let variant = LiquidDoc.Concept(id: "VAR", name: "Origami Text Variant EPUB",
                                    description: "Variant of EPUB. Adheres to EPUB 3 and feaures further metadata, both in the main document and in JSON form in the EPUB package to enable richer interactions. Developed by the Future Text Lab.")
    doc.concepts = [epub, lab, app, variant]
    let positions: [LiquidDoc.Layout.Position] = [
        .init(id: "FTL", x: 24.8, y: -104.4, z: 0),
        .init(id: "APP", x: 141.9, y: 235.6, z: 0),
        .init(id: "EPUB", x: 46.8, y: 34.8, z: 0),
        .init(id: "VAR", x: -132.3, y: 128.4, z: 0),
    ]
    doc.layouts = [LiquidDoc.Layout(index: 1, name: "Map", positions: positions, sourceID: "MAP-1")]
    return doc
}

#Preview("Map — Welcome to Origami Text", traits: .fixedLayout(width: 900, height: 600)) {
    ReaderMapView(doc: welcomeMapSample(), extras: AuthoredMapExtras(yUpViews: ["MAP-1"]),
                  bookKey: "preview-welcome", onShowInText: { _ in }, onClose: {})
        .environment(AppModel())
}
#endif

#if os(macOS)
/// ⌘M opens the Map from the reading, as in Author — only in a window
/// whose book carries one (there it takes ⌘M from Minimize, as Author does).
struct ReaderMapShortcut: ViewModifier {
    let available: Bool
    let open: () -> Void
    @State private var window: NSWindow?
    @State private var monitor: Any?
    /// The live values, for a monitor installed once.
    @State private var current = Current()

    final class Current {
        var available = false
        var open: () -> Void = {}
    }

    func body(content: Content) -> some View {
        current.available = available
        current.open = open
        return content
            .background(MapWindowProbe { window = $0 })
            .onAppear {
                let current = current
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard current.available, let window, event.window === window,
                          window.attachedSheet == nil,
                          event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
                          event.charactersIgnoringModifiers?.lowercased() == "m" else { return event }
                    current.open()
                    return nil
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

private struct MapWindowProbe: NSViewRepresentable {
    let found: (NSWindow?) -> Void
    init(_ found: @escaping (NSWindow?) -> Void) { self.found = found }

    final class Probe: NSView {
        var found: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            DispatchQueue.main.async { [found] in found?(window) }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.found = found
        return probe
    }
    func updateNSView(_ view: Probe, context: Context) {}
}
#endif

#if os(macOS)
#Preview("Map — a concept selected", traits: .fixedLayout(width: 900, height: 600)) {
    ReaderMapView(doc: welcomeMapSample(), extras: AuthoredMapExtras(yUpViews: ["MAP-1"]),
                  bookKey: "preview-welcome-selected", onShowInText: { _ in }, onClose: {},
                  initialSelection: ["APP"],
                  footBar: { left, right in
                      AnyView(ReadingFootBar(modes: [.faithful, .horizontal, .focus], outlineAvailable: true,
                                             leadingContent: { left }, onMap: {}, mapActive: true,
                                             trailingContent: { right }))
                  })
        .environment(AppModel())
}
#endif
