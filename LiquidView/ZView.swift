import SwiftUI

/// Z: the library as a Zettelkasten. One slip at a time — the current
/// document as an index card, with its neighbors filed around it: what it
/// cites, what cites it, and its Folgezettel (the same author's slips
/// just before and after it in time). Click a neighbor to step to it; the
/// trail of slips you have walked stays visible across the top, and any
/// slip on it takes you back. Double-click any slip to read it in full.
/// The box converses by adjacency: each step shows you what the last one
/// was filed next to.
struct ZView: View {
    @Environment(AppModel.self) private var model
    /// The walk so far, as document ids; the last is the current slip.
    @State private var trail: [String] = []

    private var currentDoc: LiquidDoc? {
        trail.last.flatMap { model.index.byID[$0]?.doc }
    }

    var body: some View {
        Group {
            if model.index.byID.isEmpty {
                ContentUnavailableView("The Box Is Empty",
                                       systemImage: "z.square",
                                       description: Text("Z walks the community library slip by slip. Choose a folder with documents to begin."))
            } else if let doc = currentDoc {
                VStack(spacing: 0) {
                    trailBar
                    Divider()
                    ScrollView {
                        VStack(spacing: 22) {
                            currentSlip(doc)
                            neighborShelves(around: doc)
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity)
                    }
                }
                .background(desk)
            } else {
                startState
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    pullRandomSlip()
                } label: {
                    Label("Pull a Slip", systemImage: "die.face.3")
                }
                .help("Pull a random slip from the box and start a new trail there")
            }
        }
        .onAppear {
            // Enter the box where you already are, if you are anywhere.
            if trail.isEmpty, let current = model.current?.doc,
               model.index.byID[current.id] != nil {
                trail = [current.id]
            }
        }
    }

    private var desk: some View {
        Color(red: 0.93, green: 0.91, blue: 0.87).ignoresSafeArea()
    }

    private var startState: some View {
        ContentUnavailableView {
            Label("Z", systemImage: "z.square")
        } description: {
            Text("Pull a slip and follow its neighbors — what it cites, what cites it, what its author filed beside it. The box answers one slip at a time.")
        } actions: {
            Button("Pull a Slip") { pullRandomSlip() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func pullRandomSlip() {
        guard let doc = model.index.byID.values.map(\.doc)
            .filter({ !model.index.supersededIDs.contains($0.id) })
            .randomElement() else { return }
        withAnimation { trail = [doc.id] }
    }

    private func step(to id: String) {
        let resolved = model.index.latestRevision(of: id)
        guard model.index.byID[resolved] != nil else { return }
        withAnimation {
            if let existing = trail.firstIndex(of: resolved) {
                trail = Array(trail.prefix(through: existing))
            } else {
                trail.append(resolved)
            }
        }
    }

    // MARK: The trail

    private var trailBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(trail.enumerated()), id: \.offset) { index, id in
                        if index > 0 {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        Button {
                            step(to: id)
                        } label: {
                            Text(model.index.byID[id]?.doc.title ?? id)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(index == trail.count - 1 ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                                            in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onChange(of: trail.count) {
                proxy.scrollTo(trail.count - 1, anchor: .trailing)
            }
        }
    }

    // MARK: The current slip

    private func currentSlip(_ doc: LiquidDoc) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(doc.title)
                    .font(.system(size: 21, weight: .semibold, design: .serif))
                Spacer()
                Text(doc.id)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text("\(doc.displayAuthor) · \(doc.listedDateText)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
            ForEach((doc.body ?? [])
                .filter { $0.effectiveHeading == nil && !$0.displayText.isEmpty }
                .prefix(3)) { paragraph in
                Text(paragraph.displayText)
                    .font(.system(size: 13, design: .serif))
                    .lineLimit(4)
            }
            Button("Read in full") { model.openInLibrary(doc) }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(18)
        .frame(maxWidth: 560, alignment: .leading)
        .background(slipPaper)
        .onTapGesture(count: 2) { model.openInLibrary(doc) }
    }

    // MARK: The neighbors

    private func neighborShelves(around doc: LiquidDoc) -> some View {
        let cites = doc.links
            .map { model.index.latestRevision(of: LiquidAddress.canonical($0.to)) }
            .filter { $0 != doc.id }
            .compactMap { model.index.byID[$0]?.doc }
        let citedBy = (model.index.backlinks[doc.id] ?? [])
            .compactMap { model.index.byID[$0.fromID]?.doc }
        let folge = folgezettel(of: doc)
        return HStack(alignment: .top, spacing: 18) {
            shelf("← Cited by", citedBy,
                  empty: "No slip points here yet.")
            shelf("Folgezettel", folge,
                  empty: "No neighboring slips by this author.")
            shelf("Cites →", cites,
                  empty: "This slip points at no other.")
        }
        .frame(maxWidth: 900)
    }

    /// The slips the same author filed just before and after this one —
    /// the sequence a Zettelkasten keeps by physical order.
    private func folgezettel(of doc: LiquidDoc) -> [LiquidDoc] {
        let theirs = model.index.byID.values.map(\.doc)
            .filter { $0.author == doc.author }
            .sorted { $0.created < $1.created }
        guard let index = theirs.firstIndex(where: { $0.id == doc.id }) else { return [] }
        var neighbors: [LiquidDoc] = []
        if index > 0 { neighbors.append(theirs[index - 1]) }
        if index < theirs.count - 1 { neighbors.append(theirs[index + 1]) }
        return neighbors
    }

    private func shelf(_ title: String, _ docs: [LiquidDoc], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.6)
            if docs.isEmpty {
                Text(empty)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(docs.prefix(6)) { neighbor in
                slip(neighbor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func slip(_ doc: LiquidDoc) -> some View {
        Button {
            step(to: doc.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(doc.title)
                    .font(.system(size: 12, weight: .medium, design: .serif))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(doc.displayAuthor) · \(doc.date?.yearText ?? doc.created.formatted(.dateTime.year()))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(slipPaper)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onTapGesture(count: 2) { model.openInLibrary(doc) }
        .help("Step to “\(doc.title)” — double-click to read it in full")
    }

    private var slipPaper: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(.white)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.black.opacity(0.10), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
    }
}

extension ZView {
    /// Z as an exchangeable module.
    @MainActor static let module = LibraryViewModule(
        id: "z",
        name: "Z",
        systemImage: "z.square",
        makeContent: { AnyView(DocumentListView()) },
        makeDetail: { _ in AnyView(ZView()) },
        hidesDocumentList: true
    )
}
