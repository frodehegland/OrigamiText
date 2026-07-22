#if os(visionOS)
import SwiftUI

// MARK: - Spatial card plane

/// Persists a spatial arrangement — every card's x, y, and z — keyed by
/// item id, one file per named layout, so each space is where you left
/// it, across sessions.
nonisolated enum SpatialLayoutStore {
    private static func fileURL(for name: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("\(name).json")
    }

    static func load(_ name: String) -> [String: SIMD3<Double>] {
        guard let data = try? Data(contentsOf: fileURL(for: name)),
              let positions = try? JSONDecoder().decode([String: SIMD3<Double>].self, from: data)
        else { return [:] }
        return positions
    }

    static func save(_ name: String, _ positions: [String: SIMD3<Double>]) {
        guard let data = try? JSONEncoder().encode(positions) else { return }
        try? data.write(to: fileURL(for: name), options: .atomic)
    }
}

/// A thread drawn between two cards, on the arrangement plane.
struct SpatialCardConnection {
    let from: String
    let to: String
}

/// How a layout first arranges its cards on the z = 0 plane.
enum SpatialCardSeed {
    case grid(spacing: CGSize)
    case circle
}

/// Author's Map logic, generalized: any collection of identifiable items
/// laid out as cards in a volume. Cards seed flat — z starts at zero;
/// depth is the reader's to give — and the same pinch that moves a card
/// on the plane pulls it toward you or pushes it away in Z. Each card
/// reads from the front and the back. The arrangement persists per
/// layout name, and every placement is kept: the space is where you left
/// it, next session included.
struct SpatialCardPlane<Item: Identifiable, CardFace: View, Extras: View>: View where Item.ID == String {
    private let layoutName: String
    private let items: [Item]
    private let countNoun: String
    private let seed: SpatialCardSeed
    private let connections: [SpatialCardConnection]
    private let resolveID: (String) -> String
    private let onOpen: ((Item) -> Void)?
    private let cardFace: (Item) -> CardFace
    private let extraOrnament: () -> Extras

    @State private var positions: [String: SIMD3<Double>] = [:]
    @State private var dragStart: [String: SIMD3<Double>] = [:]

    /// - Parameters:
    ///   - layoutName: The persistence key; each space keeps its own file.
    ///   - countNoun: What the ornament counts — "documents", "authors".
    ///   - resolveID: Follows a stored id to its current form (revision
    ///     chains), so an edit elsewhere does not cost a card its place.
    init(layoutName: String,
         items: [Item],
         countNoun: String,
         seed: SpatialCardSeed = .grid(spacing: CGSize(width: 220, height: 120)),
         connections: [SpatialCardConnection] = [],
         resolveID: @escaping (String) -> String = { $0 },
         onOpen: ((Item) -> Void)? = nil,
         @ViewBuilder cardFace: @escaping (Item) -> CardFace,
         @ViewBuilder extraOrnament: @escaping () -> Extras) {
        self.layoutName = layoutName
        self.items = items
        self.countNoun = countNoun
        self.seed = seed
        self.connections = connections
        self.resolveID = resolveID
        self.onOpen = onOpen
        self.cardFace = cardFace
        self.extraOrnament = extraOrnament
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                connectionThreads(in: geometry.size)
                ForEach(items) { item in
                    card(for: item)
                        .hoverEffect()
                        .position(planePoint(for: item.id, in: geometry.size))
                        .offset(z: positions[item.id]?.z ?? 0)
                        .gesture(drag(for: item.id))
                        .onTapGesture(count: 2) { onOpen?(item) }
                }
            }
            .onAppear {
                restorePositions()
                seedPositions(in: geometry.size)
            }
            .onChange(of: items.map(\.id)) { seedPositions(in: geometry.size) }
        }
        .ornament(attachmentAnchor: .scene(.bottom)) {
            HStack(spacing: 12) {
                Text("\(items.count) \(countNoun)")
                    .foregroundStyle(.secondary)
                extraOrnament()
                Button {
                    positions.removeAll()
                    seedPositions(in: nil)
                    SpatialLayoutStore.save(layoutName, positions)
                } label: {
                    Label("Re-lay Out", systemImage: "square.grid.3x3")
                }
            }
            .padding(10)
            .glassBackgroundEffect()
        }
    }

    // MARK: Cards

    /// Front and back faces, so the card reads from either side of the
    /// volume — the back is the same face turned around.
    private func card(for item: Item) -> some View {
        ZStack {
            cardFace(item)
            cardFace(item)
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                .offset(z: -1)
        }
    }

    // MARK: Layout and movement

    /// The arrangement as last left, with stored ids followed to their
    /// current form before a position is claimed.
    private func restorePositions() {
        guard positions.isEmpty else { return }
        let stored = SpatialLayoutStore.load(layoutName)
        for (id, position) in stored {
            let current = resolveID(id)
            if positions[current] == nil {
                positions[current] = position
            }
        }
    }

    /// First arrangement, essentially 2D, as Author's Map begins: a
    /// centered grid, or a circle starting at the top — no rotation, the
    /// circle holds still. Only unplaced items are seeded.
    private func seedPositions(in size: CGSize?) {
        let size = size ?? CGSize(width: 1200, height: 800)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        switch seed {
        case .grid(let spacing):
            let columns = max(1, Int(Double(items.count).squareRoot().rounded(.up)))
            let rows = (items.count + columns - 1) / columns
            let origin = CGPoint(x: center.x - Double(columns - 1) * spacing.width / 2,
                                 y: center.y - Double(rows - 1) * spacing.height / 2)
            for (index, item) in items.enumerated() where positions[item.id] == nil {
                let column = index % columns
                let row = index / columns
                positions[item.id] = SIMD3(origin.x + Double(column) * spacing.width,
                                           origin.y + Double(row) * spacing.height,
                                           0)
            }
        case .circle:
            let radius = min(size.width, size.height) / 2 - 130
            let count = max(items.count, 1)
            for (index, item) in items.enumerated() where positions[item.id] == nil {
                let angle = -Double.pi / 2 + Double(index) / Double(count) * 2 * .pi
                positions[item.id] = SIMD3(center.x + cos(angle) * radius,
                                           center.y + sin(angle) * radius,
                                           0)
            }
        }
    }

    private func planePoint(for id: String, in size: CGSize) -> CGPoint {
        let p = positions[id] ?? SIMD3(size.width / 2, size.height / 2, 0)
        return CGPoint(x: p.x, y: p.y)
    }

    /// visionOS drags carry all three dimensions: the same pinch moves a
    /// card on the plane and pulls or pushes it in Z.
    private func drag(for id: String) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = dragStart[id] ?? positions[id] ?? .zero
                if dragStart[id] == nil { dragStart[id] = start }
                positions[id] = SIMD3(start.x + value.translation3D.x,
                                      start.y + value.translation3D.y,
                                      start.z + value.translation3D.z)
            }
            .onEnded { _ in
                dragStart[id] = nil
                SpatialLayoutStore.save(layoutName, positions)
            }
    }

    // MARK: Connections

    /// Threads on the arrangement plane (their endpoints' cards may float
    /// above or below — the thread marks the connection, the depth stays
    /// the reader's).
    private func connectionThreads(in size: CGSize) -> some View {
        Canvas { context, _ in
            for connection in connections {
                let a = planePoint(for: connection.from, in: size)
                let b = planePoint(for: connection.to, in: size)
                var path = Path()
                path.move(to: a)
                path.addLine(to: b)
                context.stroke(path, with: .color(.white.opacity(0.28)), lineWidth: 1.2)
            }
        }
        .allowsHitTesting(false)
    }
}

extension SpatialCardPlane where Extras == EmptyView {
    init(layoutName: String,
         items: [Item],
         countNoun: String,
         seed: SpatialCardSeed = .grid(spacing: CGSize(width: 220, height: 120)),
         connections: [SpatialCardConnection] = [],
         resolveID: @escaping (String) -> String = { $0 },
         onOpen: ((Item) -> Void)? = nil,
         @ViewBuilder cardFace: @escaping (Item) -> CardFace) {
        self.init(layoutName: layoutName,
                  items: items,
                  countNoun: countNoun,
                  seed: seed,
                  connections: connections,
                  resolveID: resolveID,
                  onOpen: onOpen,
                  cardFace: cardFace,
                  extraOrnament: { EmptyView() })
    }
}

// MARK: - Knowledge Space

/// The Knowledge Space: the library laid out on Author's Map logic — an
/// essentially 2D arrangement in a volume, where the hand can pull a card
/// toward you or push it away in Z. Every document is a small card, title
/// then author, readable from the front and the back. Links draw as
/// threads on the arrangement plane. Double-tap a card to open the full
/// article; pinch-drag to move it in all three dimensions.
///
/// The mechanics — seeding, dragging, persistence — live in
/// SpatialCardPlane above; this view supplies the documents, their card
/// face, and the link threads. Layout persists under the same file as
/// before, so arrangements made in earlier versions carry over.
struct KnowledgeSpaceView: View {
    @Environment(VisionModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("xrMaxTitleLines") private var maxTitleLines = 2
    @AppStorage("xrMaxAuthorLines") private var maxAuthorLines = 1
    @State private var showingSettings = false

    private var docs: [LiquidDoc] { model.index.timeline.map(\.doc) }

    /// Links as threads, with targets followed through revision chains —
    /// an edit on the Mac does not break a thread.
    private var connections: [SpatialCardConnection] {
        let ids = Set(docs.map(\.id))
        var result: [SpatialCardConnection] = []
        for doc in docs {
            for link in doc.links {
                let target = model.index.latestRevision(of: LiquidAddress.canonical(link.to))
                guard ids.contains(target), target != doc.id else { continue }
                result.append(SpatialCardConnection(from: doc.id, to: target))
            }
        }
        return result
    }

    var body: some View {
        SpatialCardPlane(layoutName: "KnowledgeSpaceLayout",
                         items: docs,
                         countNoun: "documents",
                         connections: connections,
                         resolveID: { model.index.latestRevision(of: $0) },
                         onOpen: { openWindow(id: "reader", value: $0.id) },
                         cardFace: { doc in cardFace(for: doc) },
                         extraOrnament: {
            Button {
                showingSettings = true
            } label: {
                Label("Card Settings", systemImage: "slider.horizontal.3")
            }
        })
        .overlay {
            if docs.isEmpty {
                ContentUnavailableView("Nothing in the Space",
                                       systemImage: "circle.hexagongrid",
                                       description: Text("Choose a community folder in the library window."))
            }
        }
        .sheet(isPresented: $showingSettings) { cardSettings }
    }

    private func cardFace(for doc: LiquidDoc) -> some View {
        VStack(spacing: 5) {
            Text(doc.title)
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .lineLimit(maxTitleLines)
            Text(doc.displayAuthor)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(maxAuthorLines)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 190)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Settings

    private var cardSettings: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Title: up to \(maxTitleLines) \(maxTitleLines == 1 ? "line" : "lines")",
                            value: $maxTitleLines, in: 1...6)
                    Stepper("Author: up to \(maxAuthorLines) \(maxAuthorLines == 1 ? "line" : "lines")",
                            value: $maxAuthorLines, in: 1...4)
                } header: {
                    Text("Cards")
                } footer: {
                    Text("Cards show the document's title, then its author, on both faces. Double-tap any card to open the full article.")
                }
            }
            .toolbar {
                Button("Done") { showingSettings = false }
            }
        }
        .frame(width: 420, height: 300)
    }
}
#endif
