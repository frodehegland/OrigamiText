#if os(visionOS)
import SwiftUI

/// Persists the Knowledge Space arrangement — every card's x, y, and z —
/// so the space is where you left it, across sessions and across edits
/// made elsewhere. Positions are keyed by document id; on load, keys are
/// followed through revision chains, so a document superseded on the Mac
/// inherits the position its predecessor was given by hand.
nonisolated enum SpaceLayoutStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("KnowledgeSpaceLayout.json")
    }

    static func load() -> [String: SIMD3<Double>] {
        guard let data = try? Data(contentsOf: fileURL),
              let positions = try? JSONDecoder().decode([String: SIMD3<Double>].self, from: data)
        else { return [:] }
        return positions
    }

    static func save(_ positions: [String: SIMD3<Double>]) {
        guard let data = try? JSONEncoder().encode(positions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// The Knowledge Space: the library laid out on Author's Map logic — an
/// essentially 2D arrangement in a volume, where the hand can pull a card
/// toward you or push it away in Z. Every document is a small card, title
/// then author, readable from the front and the back. Links draw as
/// threads on the arrangement plane. Double-tap a card to open the full
/// article; pinch-drag to move it in all three dimensions.
struct KnowledgeSpaceView: View {
    @Environment(VisionModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("xrMaxTitleLines") private var maxTitleLines = 2
    @AppStorage("xrMaxAuthorLines") private var maxAuthorLines = 1
    @State private var positions: [String: SIMD3<Double>] = [:]
    @State private var dragStart: [String: SIMD3<Double>] = [:]
    @State private var showingSettings = false

    private var docs: [LiquidDoc] { model.index.timeline.map(\.doc) }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                connectionThreads(in: geometry.size)
                ForEach(docs) { doc in
                    card(for: doc)
                        .hoverEffect()
                        .position(planePoint(for: doc.id, in: geometry.size))
                        .offset(z: positions[doc.id]?.z ?? 0)
                        .gesture(drag(for: doc.id))
                        .onTapGesture(count: 2) {
                            openWindow(id: "reader", value: doc.id)
                        }
                }
                if docs.isEmpty {
                    ContentUnavailableView("Nothing in the Space",
                                           systemImage: "circle.hexagongrid",
                                           description: Text("Choose a community folder in the library window."))
                }
            }
            .onAppear {
                restorePositions()
                seedPositions(in: geometry.size)
            }
            .onChange(of: docs.map(\.id)) { seedPositions(in: geometry.size) }
        }
        .ornament(attachmentAnchor: .scene(.bottom)) {
            HStack(spacing: 12) {
                Text("\(docs.count) documents")
                    .foregroundStyle(.secondary)
                Button {
                    showingSettings = true
                } label: {
                    Label("Card Settings", systemImage: "slider.horizontal.3")
                }
                Button {
                    positions.removeAll()
                    seedPositions(in: nil)
                    SpaceLayoutStore.save(positions)
                } label: {
                    Label("Re-lay Out", systemImage: "square.grid.3x3")
                }
            }
            .padding(10)
            .glassBackgroundEffect()
        }
        .sheet(isPresented: $showingSettings) { cardSettings }
    }

    // MARK: Cards

    /// Front and back faces, so the card reads from either side of the
    /// volume — the back is the same face turned around.
    private func card(for doc: LiquidDoc) -> some View {
        ZStack {
            cardFace(for: doc)
            cardFace(for: doc)
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                .offset(z: -1)
        }
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

    // MARK: Layout and movement

    /// The arrangement as last left, with positions given to earlier
    /// revisions following the chain to the document's latest form — an
    /// edit on the Mac does not cost a card its place in the space.
    private func restorePositions() {
        guard positions.isEmpty else { return }
        let stored = SpaceLayoutStore.load()
        for (id, position) in stored {
            let current = model.index.latestRevision(of: id)
            if positions[current] == nil {
                positions[current] = position
            }
        }
    }

    /// First arrangement: a centered grid on the plane, newest last —
    /// essentially 2D, as Author's Map begins. Z starts at zero; depth is
    /// the reader's to give.
    private func seedPositions(in size: CGSize?) {
        let size = size ?? CGSize(width: 1200, height: 800)
        let columns = max(1, Int(Double(docs.count).squareRoot().rounded(.up)))
        let spacing = CGSize(width: 220, height: 120)
        let rows = (docs.count + columns - 1) / columns
        let origin = CGPoint(x: size.width / 2 - Double(columns - 1) * spacing.width / 2,
                             y: size.height / 2 - Double(rows - 1) * spacing.height / 2)
        for (index, doc) in docs.enumerated() where positions[doc.id] == nil {
            let column = index % columns
            let row = index / columns
            positions[doc.id] = SIMD3(origin.x + Double(column) * spacing.width,
                                      origin.y + Double(row) * spacing.height,
                                      0)
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
                // Every placement is kept: the space is where you left it,
                // next session included.
                SpaceLayoutStore.save(positions)
            }
    }

    // MARK: Connections

    /// Links as threads on the arrangement plane (their endpoints' cards
    /// may float above or below — the thread marks the connection, the
    /// depth stays the reader's).
    private func connectionThreads(in size: CGSize) -> some View {
        Canvas { context, _ in
            let ids = Set(docs.map(\.id))
            for doc in docs {
                for link in doc.links {
                    let target = model.index.latestRevision(of: LiquidAddress.canonical(link.to))
                    guard ids.contains(target), target != doc.id else { continue }
                    let a = planePoint(for: doc.id, in: size)
                    let b = planePoint(for: target, in: size)
                    var path = Path()
                    path.move(to: a)
                    path.addLine(to: b)
                    context.stroke(path, with: .color(.white.opacity(0.28)), lineWidth: 1.2)
                }
            }
        }
        .allowsHitTesting(false)
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
            .navigationTitle("Knowledge Space")
            .toolbar {
                Button("Done") { showingSettings = false }
            }
        }
        .frame(width: 420, height: 300)
    }
}
#endif
