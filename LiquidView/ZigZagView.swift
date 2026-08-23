import SwiftUI

/// ZigZag, after Ted Nelson: every document is a cell that sits on several
/// ranks at once — its place in time, in its author's sequence, among its
/// kind, and in the conversation it belongs to. The view shows two
/// dimensions at a time, crossing at the focused cell: one running across,
/// one running down. Arrow keys (or clicks) move the focus along either
/// rank; rotating swaps in another dimension, and the same cell reveals
/// different neighborhoods. Double-click a cell to read it.
struct ZigZagView: View {
    @Environment(AppModel.self) private var model
    @State private var focusedID: String?
    @State private var dimAcross: Dimension = .time
    @State private var dimDown: Dimension = .author

    /// The ranks a document lies on. Each dimension answers one question:
    /// who are this cell's previous and next along me?
    enum Dimension: String, CaseIterable, Identifiable {
        case time = "d.time"
        case author = "d.author"
        case type = "d.type"
        case discourse = "d.discourse"
        var id: String { rawValue }

        var color: Color {
            switch self {
            case .time: .cyan
            case .author: .orange
            case .type: .green
            case .discourse: .purple
            }
        }
    }

    private var focusedDoc: LiquidDoc? {
        focusedID.flatMap { model.index.byID[$0]?.doc }
    }

    var body: some View {
        Group {
            if let doc = focusedDoc {
                cross(around: doc)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(white: 0.08).ignoresSafeArea())
                    .focusable()
                    .focusEffectDisabled()
                    .onKeyPress(.leftArrow) { move(along: dimAcross, forward: false); return .handled }
                    .onKeyPress(.rightArrow) { move(along: dimAcross, forward: true); return .handled }
                    .onKeyPress(.upArrow) { move(along: dimDown, forward: false); return .handled }
                    .onKeyPress(.downArrow) { move(along: dimDown, forward: true); return .handled }
            } else {
                ContentUnavailableView("Nothing to ZigZag",
                                       systemImage: "arrow.triangle.swap",
                                       description: Text("ZigZag crosses two dimensions of the library at a focused document. Choose a community folder with documents to begin."))
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("Across", selection: $dimAcross) {
                    ForEach(Dimension.allCases) { Text($0.rawValue).tag($0) }
                }
                .help("The dimension running across")
                Picker("Down", selection: $dimDown) {
                    ForEach(Dimension.allCases) { Text($0.rawValue).tag($0) }
                }
                .help("The dimension running down")
                Button {
                    swap(&dimAcross, &dimDown)
                } label: {
                    Label("Rotate", systemImage: "arrow.triangle.swap")
                }
                .help("Swap the two visible dimensions — the same cell, different neighborhoods")
            }
        }
        .onChange(of: dimAcross) { keepDimensionsDistinct(changed: \.dimAcross) }
        .onChange(of: dimDown) { keepDimensionsDistinct(changed: \.dimDown) }
        .onAppear {
            if focusedID == nil {
                if let current = model.current?.doc, model.index.byID[current.id] != nil {
                    focusedID = current.id
                } else {
                    focusedID = model.index.timeline.last?.id
                }
            }
        }
    }

    /// Two dimensions showing the same rank teach nothing; when the user
    /// picks a duplicate, the other axis steps to the next dimension.
    private func keepDimensionsDistinct(changed: KeyPath<ZigZagView, Dimension>) {
        guard dimAcross == dimDown else { return }
        let others = Dimension.allCases.filter { $0 != dimAcross }
        if changed == \.dimAcross {
            dimDown = others.first ?? dimDown
        } else {
            dimAcross = others.first ?? dimAcross
        }
    }

    private func move(along dimension: Dimension, forward: Bool) {
        guard let doc = focusedDoc else { return }
        let neighbors = neighbors(of: doc, along: dimension)
        if let next = forward ? neighbors.next : neighbors.previous {
            withAnimation(.spring(duration: 0.3)) { focusedID = next.id }
        }
    }

    // MARK: The cross

    private func cross(around doc: LiquidDoc) -> some View {
        GeometryReader { geometry in
            // The arms only grow as far as the pane allows: each across
            // step needs a cell and connector (~180 points), each down
            // step ~88, and the focused cell holds the exact center.
            let acrossReach = max(1, min(3, Int((geometry.size.width - 280) / 2 / 180)))
            let downReach = max(1, min(2, Int((geometry.size.height - 170) / 2 / 88)))
            let across = rank(around: doc, along: dimAcross, reach: acrossReach)
            let down = rank(around: doc, along: dimDown, reach: downReach)
            VStack(spacing: 8) {
                ForEach(down.before) { neighbor in
                    cell(neighbor, on: dimDown)
                    connector(dimDown, vertical: true)
                }
                HStack(spacing: 8) {
                    ForEach(across.before) { neighbor in
                        cell(neighbor, on: dimAcross)
                        connector(dimAcross, vertical: false)
                    }
                    focusedCell(doc)
                    ForEach(across.after) { neighbor in
                        connector(dimAcross, vertical: false)
                        cell(neighbor, on: dimAcross)
                    }
                }
                ForEach(down.after) { neighbor in
                    connector(dimDown, vertical: true)
                    cell(neighbor, on: dimDown)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .overlay(alignment: .topLeading) { legend }
    }

    /// The two live dimensions, named in the corner rather than riding the
    /// arms — the cross stays symmetric around the focused cell.
    private var legend: some View {
        VStack(alignment: .leading, spacing: 3) {
            dimensionLabel(dimAcross, arrow: "→")
            dimensionLabel(dimDown, arrow: "↓")
        }
        .padding(12)
    }

    private func dimensionLabel(_ dimension: Dimension, arrow: String) -> some View {
        Text("\(dimension.rawValue) \(arrow)")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(dimension.color.opacity(0.85))
    }

    private func connector(_ dimension: Dimension, vertical: Bool) -> some View {
        Rectangle()
            .fill(dimension.color.opacity(0.6))
            .frame(width: vertical ? 2 : 14, height: vertical ? 14 : 2)
    }

    private func focusedCell(_ doc: LiquidDoc) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(doc.title)
                .font(.system(size: 14, weight: .semibold, design: .serif))
                .foregroundStyle(.black)
                .lineLimit(3)
            Text("\(doc.displayAuthor) · \(doc.listedDateText)")
                .font(.system(size: 10))
                .foregroundStyle(.black.opacity(0.6))
            Text(doc.id)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.black.opacity(0.4))
        }
        .padding(10)
        .frame(width: 200, alignment: .leading)
        .background(
            // The focused cell is the lit one: light card, dark ink.
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.99, green: 0.97, blue: 0.92))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.yellow.opacity(0.9), lineWidth: 1.5))
        )
        .onTapGesture(count: 2) { model.openInLibrary(doc) }
        .help("The focused cell — double-click to read")
    }

    private func cell(_ doc: LiquidDoc, on dimension: Dimension) -> some View {
        Button {
            withAnimation(.spring(duration: 0.3)) { focusedID = doc.id }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.title)
                    .font(.system(size: 11, design: .serif))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(doc.author) · \(doc.date?.yearText ?? doc.created.formatted(.dateTime.year()))")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(8)
            .frame(width: 150, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(white: 0.13))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(dimension.color.opacity(0.5), lineWidth: 1))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .onTapGesture(count: 2) { model.openInLibrary(doc) }
        .help("Step to “\(doc.title)” — double-click to read")
    }

    // MARK: Ranks

    /// Walks a dimension outward from the focused cell, a few steps each
    /// way, guarding against cycles.
    private func rank(around doc: LiquidDoc, along dimension: Dimension,
                      reach: Int) -> (before: [LiquidDoc], after: [LiquidDoc]) {
        var before: [LiquidDoc] = []
        var after: [LiquidDoc] = []
        var visited: Set<String> = [doc.id]
        var cursor = doc
        for _ in 0..<reach {
            guard let previous = neighbors(of: cursor, along: dimension).previous,
                  visited.insert(previous.id).inserted else { break }
            before.insert(previous, at: 0)
            cursor = previous
        }
        cursor = doc
        for _ in 0..<reach {
            guard let next = neighbors(of: cursor, along: dimension).next,
                  visited.insert(next.id).inserted else { break }
            after.append(next)
            cursor = next
        }
        return (before, after)
    }

    /// One cell's previous and next along a dimension.
    private func neighbors(of doc: LiquidDoc,
                           along dimension: Dimension) -> (previous: LiquidDoc?, next: LiquidDoc?) {
        switch dimension {
        case .time:
            return adjacent(in: model.index.timeline.map(\.doc), around: doc)
        case .author:
            let rank = model.index.byID.values.map(\.doc)
                .filter { $0.author == doc.author }
                .sorted { ($0.listedDate, $0.id) < ($1.listedDate, $1.id) }
            return adjacent(in: rank, around: doc)
        case .type:
            let type = effectiveType(of: doc)
            let rank = model.index.byID.values.map(\.doc)
                .filter { effectiveType(of: $0) == type }
                .sorted { ($0.listedDate, $0.id) < ($1.listedDate, $1.id) }
            return adjacent(in: rank, around: doc)
        case .discourse:
            // Backwards: the document this one speaks to. Forwards: the
            // first document that speaks to this one.
            let discourse = Set(DocumentRelation.discourseActions.map(\.rawValue))
            let previous = doc.links
                .first { $0.rel.map(discourse.contains) ?? false }
                .map { model.index.latestRevision(of: LiquidAddress.canonical($0.to)) }
                .flatMap { model.index.byID[$0]?.doc }
            let next = (model.index.backlinks[doc.id] ?? [])
                .first { $0.rel.map(discourse.contains) ?? false }
                .flatMap { model.index.byID[$0.fromID]?.doc }
            return (previous, next)
        }
    }

    private func effectiveType(of doc: LiquidDoc) -> String {
        doc.documentType
            ?? (TranscriptsView.isTranscript(doc)
                ? LiquidDoc.DocumentType.transcript.rawValue
                : LiquidDoc.DocumentType.letter.rawValue)
    }

    private func adjacent(in rank: [LiquidDoc], around doc: LiquidDoc) -> (previous: LiquidDoc?, next: LiquidDoc?) {
        guard let index = rank.firstIndex(where: { $0.id == doc.id }) else { return (nil, nil) }
        return (index > 0 ? rank[index - 1] : nil,
                index < rank.count - 1 ? rank[index + 1] : nil)
    }
}

extension ZigZagView {
    /// ZigZag as an exchangeable module.
    @MainActor static let module = LibraryViewModule(
        id: "zigzag",
        name: "ZigZag",
        systemImage: "arrow.triangle.swap",
        makeContent: { AnyView(DocumentListView()) },
        makeDetail: { _ in AnyView(ZigZagView()) },
        hidesDocumentList: true
    )
}
