import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// zzStructure Dimensional Navigation (per Eric's brief): a cursor-centric
/// view over the zz layer woven across library documents. The accursed
/// cell sits at the origin; two dimensions bind to the axes (a third to
/// depth); H-view drops full columns through the crossbar, I-view lays
/// full rows through the spine. Arrow keys move the accursed cell along
/// the bound ranks (⌥↑/⌥↓ along Z); Tab swaps H and I. Virtual copies —
/// the same cell placed twice, the space being non-Euclidean — render
/// dashed: they are wormholes, and are never suppressed.
struct ZZNavigatorView: View {
    @Environment(AppModel.self) private var model
    private var store: ZZStructure { ZZStore.shared }

    @State private var accursedID: UUID?
    @State private var axes = AxisBinding(x: ZZStructure.System.dimensions,
                                          y: ZZStructure.System.namespaceMembers,
                                          z: nil)
    @State private var viewKey = HView.key
    @State private var showingNewDimension = false
    @State private var newDimensionName = ""

    private static let cellSize = CGSize(width: 176, height: 58)
    private static let gap = CGSize(width: 26, height: 22)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 240)
            Divider()
            canvas
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("View", selection: $viewKey) {
                    ForEach(ZZViewRegistry.all.map { $0.key }, id: \.self) { key in
                        Text(ZZViewRegistry.all.first { $0.key == key }?.displayName ?? key)
                            .tag(key)
                    }
                }
                .pickerStyle(.segmented)
                .help("H-view: columns through the crossbar. I-view: rows through the spine. Tab swaps them.")

                Menu {
                    ForEach(model.index.timeline.reversed()) { entry in
                        Button(entry.doc.title) { weave(documentID: entry.doc.id) }
                    }
                } label: {
                    Label("Weave Document", systemImage: "plus.circle")
                }
                .help("Give a library document a cell and link it posward of the accursed cell along X")

                Button {
                    showingNewDimension = true
                } label: {
                    Label("New Dimension", systemImage: "slider.horizontal.3")
                }
                .help("Create a user dimension — it joins the d.dimensions ring")

                layoutsMenu
            }
        }
        .sheet(isPresented: $showingNewDimension) { newDimensionSheet }
        .onAppear {
            if accursedID == nil {
                // Enter at d.dimensions: the structure describing itself.
                accursedID = ZZStructure.System.cellID(for: ZZStructure.System.dimensions)
            }
        }
    }

    // MARK: Canvas

    private var placed: [PlacedCell] {
        guard let accursedID else { return [] }
        return ZZViewRegistry.view(for: viewKey)
            .layout(accursed: accursedID, axes: axes, in: store)
    }

    private var canvas: some View {
        GeometryReader { geometry in
            ZStack {
                Color(white: 0.09)
                ForEach(placed) { cell in
                    cellView(cell)
                        .position(x: geometry.size.width / 2
                                    + CGFloat(cell.x) * (Self.cellSize.width + Self.gap.width),
                                  y: geometry.size.height / 2
                                    + CGFloat(cell.y) * (Self.cellSize.height + Self.gap.height))
                }
            }
            .animation(.spring(duration: 0.32), value: placed)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .overlay(alignment: .bottomLeading) {
            Text("← → along \(dimensionName(axes.x)) · ↑ ↓ along \(dimensionName(axes.y))\(axes.z != nil ? " · ⌥↑ ⌥↓ along \(dimensionName(axes.z!))" : "") · Tab swaps H/I · double-click reads")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
                .padding(10)
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .leftArrow: return step(along: axes.x, forward: false)
        case .rightArrow: return step(along: axes.x, forward: true)
        case .upArrow:
            if press.modifiers.contains(.option), let z = axes.z {
                return step(along: z, forward: false)
            }
            return step(along: axes.y, forward: false)
        case .downArrow:
            if press.modifiers.contains(.option), let z = axes.z {
                return step(along: z, forward: true)
            }
            return step(along: axes.y, forward: true)
        case .tab:
            viewKey = viewKey == HView.key ? IView.key : HView.key
            return .handled
        default:
            return .ignored
        }
    }

    private func step(along dimension: UUID, forward: Bool) -> KeyPress.Result {
        guard let accursedID else { return .ignored }
        let next = forward ? store.posward(of: accursedID, along: dimension)
                           : store.negward(of: accursedID, along: dimension)
        guard let next else { return .ignored }
        withAnimation(.spring(duration: 0.32)) { self.accursedID = next }
        return .handled
    }

    private func cellView(_ placedCell: PlacedCell) -> some View {
        let isAccursed = placedCell.cellID == accursedID && !placedCell.isVirtualCopy
        return VStack(alignment: .leading, spacing: 2) {
            Text(label(for: placedCell.cellID))
                .font(.system(size: 11.5, weight: isAccursed ? .semibold : .regular,
                              design: .serif))
                .foregroundStyle(isAccursed ? .black : .white)
                .lineLimit(2)
            HStack(spacing: 5) {
                Text(kindName(of: placedCell.cellID))
                if placedCell.z != 0 {
                    Text("z \(placedCell.z > 0 ? "+" : "")\(placedCell.z)")
                        .padding(.horizontal, 4)
                        .background(.purple.opacity(0.5), in: Capsule())
                }
                if placedCell.isVirtualCopy {
                    Text("wormhole")
                }
            }
            .font(.system(size: 8))
            .foregroundStyle(isAccursed ? .black.opacity(0.55) : .white.opacity(0.45))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(width: Self.cellSize.width, height: Self.cellSize.height, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isAccursed ? Color(red: 0.99, green: 0.97, blue: 0.92) : Color(white: 0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(isAccursed ? Color.yellow.opacity(0.9)
                                                 : Color.white.opacity(placedCell.isVirtualCopy ? 0.55 : 0.25),
                                      style: StrokeStyle(lineWidth: isAccursed ? 1.5 : 1,
                                                         dash: placedCell.isVirtualCopy ? [4, 3] : []))
                )
        )
        .onTapGesture(count: 2) { open(placedCell.cellID) }
        .onTapGesture { withAnimation(.spring(duration: 0.32)) { accursedID = placedCell.cellID } }
        .help(placedCell.isVirtualCopy
              ? "A virtual copy — the same cell, reachable along another path"
              : label(for: placedCell.cellID))
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List {
            if let accursedID {
                Section("Accursed cell") {
                    Text(label(for: accursedID))
                        .font(.system(size: 12, weight: .medium))
                    Text(kindName(of: accursedID))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Dimensions at this cell") {
                    let present = store.dimensions(at: accursedID)
                    if present.isEmpty {
                        Text("No connections yet — weave a document in.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(present) { dimension in
                        HStack {
                            Text(dimension.qualifiedName)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                            axisButton("X", isOn: axes.x == dimension.id) { axes.x = dimension.id }
                            axisButton("Y", isOn: axes.y == dimension.id) { axes.y = dimension.id }
                            axisButton("Z", isOn: axes.z == dimension.id) {
                                axes.z = axes.z == dimension.id ? nil : dimension.id
                            }
                        }
                    }
                }
                Section("Unweave") {
                    ForEach(store.dimensions(at: accursedID)) { dimension in
                        if let posward = store.posward(of: accursedID, along: dimension.id) {
                            Button("Unlink posward · \(dimension.qualifiedName)") {
                                store.unlink(accursedID, poswardFrom: posward, along: dimension.id)
                                store.save()
                            }
                            .font(.caption)
                        }
                        if let negward = store.negward(of: accursedID, along: dimension.id) {
                            Button("Unlink negward · \(dimension.qualifiedName)") {
                                store.unlink(negward, poswardFrom: accursedID, along: dimension.id)
                                store.save()
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            Section("Axes") {
                dimensionPicker("X (across)", selection: $axes.x)
                dimensionPicker("Y (down)", selection: $axes.y)
                Picker("Z (depth)", selection: $axes.z) {
                    Text("None").tag(UUID?.none)
                    ForEach(store.allDimensions()) { dimension in
                        Text(dimension.qualifiedName).tag(UUID?.some(dimension.id))
                    }
                }
                .font(.caption)
            }
        }
        .listStyle(.sidebar)
    }

    private func axisButton(_ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
                .foregroundStyle(isOn ? .white : .secondary)
        }
        .buttonStyle(.plain)
        .help("Bind \(label == "Z" ? "or unbind " : "")this dimension to the \(label) axis")
    }

    private func dimensionPicker(_ title: String, selection: Binding<UUID>) -> some View {
        Picker(title, selection: selection) {
            ForEach(store.allDimensions()) { dimension in
                Text(dimension.qualifiedName).tag(dimension.id)
            }
        }
        .font(.caption)
    }

    private var newDimensionSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Dimension")
                .font(.headline)
            TextField("Name (e.g. argues-with, follows, teaches)", text: $newDimensionName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            Text("The dimension joins the d.dimensions ring — navigable like everything else, because dimensions are cells too.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showingNewDimension = false }
                Button("Create") {
                    let name = newDimensionName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    if let dimension = try? store.addDimension(name: name) {
                        axes.x = dimension.id
                        store.save()
                    }
                    newDimensionName = ""
                    showingNewDimension = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(newDimensionName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    // MARK: Weaving

    // MARK: Layouts

    /// Saved layouts are cells in the structure (a clone of the view cell
    /// with axis and anchor links), so they persist with the weave and
    /// travel inside it. Export/Import move a single layout as a small
    /// .zzlayout file between structures.
    private var layoutsMenu: some View {
        let layouts = store.savedLayouts()
        return Menu {
            Button("Save Current Layout") { saveCurrentLayout() }
            if !layouts.isEmpty {
                Divider()
                ForEach(layouts) { layout in
                    Button(layoutLabel(layout)) { apply(layout) }
                }
                Divider()
                Menu("Delete Layout") {
                    ForEach(layouts) { layout in
                        Button(layoutLabel(layout), role: .destructive) {
                            store.removeLayout(layout.cellID)
                            store.save()
                        }
                    }
                }
            }
            Divider()
            Button("Export Layout…") { exportLayout() }
            Button("Import Layout…") { importLayout() }
        } label: {
            Label("Layouts", systemImage: "squareshape.split.3x3")
        }
        .help("Keep, restore, and exchange arrangements: view, axes, and anchor")
    }

    /// "H-view · user.person × user.marriage @ <anchor>".
    private func layoutLabel(_ layout: ZZStructure.ZZLayout) -> String {
        let view = ZZViewRegistry.all.first { $0.key == layout.viewKey }?.displayName
            ?? layout.viewKey
        let x = store.dimensions[layout.axes.x]?.qualifiedName ?? "?"
        let y = store.dimensions[layout.axes.y]?.qualifiedName ?? "?"
        var text = "\(view) · \(x) × \(y)"
        if let z = layout.axes.z, let name = store.dimensions[z]?.qualifiedName {
            text += " × \(name)"
        }
        if let anchor = layout.anchor {
            text += " @ \(label(for: anchor))"
        }
        return text
    }

    private func apply(_ layout: ZZStructure.ZZLayout) {
        withAnimation(.spring(duration: 0.32)) {
            viewKey = layout.viewKey
            axes = layout.axes
            if let anchor = layout.anchor, store.cells[anchor] != nil {
                accursedID = anchor
            }
        }
    }

    private func saveCurrentLayout() {
        do {
            try store.saveLayout(viewKey: viewKey, axes: axes, anchor: accursedID)
            store.save()
            model.showNote("Layout saved — it lives in the structure and travels with it")
        } catch {
            model.showNote("Could not save layout: \(error.localizedDescription)")
        }
    }

    private static let layoutFileType = UTType(filenameExtension: "zzlayout",
                                               conformingTo: .json) ?? .json

    private func exportLayout() {
        guard let archive = store.layoutArchive(viewKey: viewKey, axes: axes,
                                                anchor: accursedID) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.layoutFileType]
        panel.nameFieldStringValue = "Layout.zzlayout"
        panel.message = "The current arrangement — view, axes, anchor — as a file another structure can import."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(archive) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Importing both applies the arrangement and saves it as a layout
    /// cell, so it appears in this menu from now on.
    private func importLayout() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.layoutFileType, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let archive = try JSONDecoder().decode(ZZLayoutArchive.self, from: data)
            guard archive.format.hasPrefix("origami-zz-layout/") else {
                model.showNote("This file is not a zz layout.")
                return
            }
            let resolved = try store.resolveLayoutArchive(archive)
            try store.saveLayout(viewKey: resolved.viewKey, axes: resolved.axes,
                                 anchor: resolved.anchor)
            store.save()
            withAnimation(.spring(duration: 0.32)) {
                viewKey = resolved.viewKey
                axes = resolved.axes
                if let anchor = resolved.anchor { accursedID = anchor }
            }
        } catch {
            model.showNote("Could not import layout: \(error.localizedDescription)")
        }
    }

    /// A document joins the structure: it gets a cell (or is found), and —
    /// when a cell is accursed — is linked posward of it along X. Splice
    /// mode, so weaving into the middle of a rank threads, not breaks.
    private func weave(documentID: String) {
        let cell = store.cell(forDocument: documentID)
        defer { store.save() }
        guard let accursedID, accursedID != cell else {
            accursedID = cell
            return
        }
        do {
            try store.link(accursedID, poswardTo: cell, along: axes.x, splice: true)
            withAnimation(.spring(duration: 0.32)) { self.accursedID = cell }
        } catch {
            model.showNote("Could not weave: \(error.localizedDescription)")
        }
    }

    // MARK: Labels

    private func label(for cellID: UUID) -> String {
        switch store.cells[cellID]?.kind {
        case .document(let documentID):
            return model.title(for: documentID) ?? documentID
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

    private func dimensionName(_ id: UUID) -> String {
        store.dimensions[id]?.qualifiedName ?? "?"
    }

    private func open(_ cellID: UUID) {
        let head = store.contentHead(of: cellID)
        if case .document(let documentID)? = store.cells[head]?.kind,
           let entry = model.index.byID[documentID] {
            model.openInLibrary(entry.doc)
        }
    }
}

extension ZZNavigatorView {
    /// zzStructure navigation as an exchangeable module.
    @MainActor static let module = LibraryViewModule(
        id: "zz-structure",
        name: "zzStructure",
        systemImage: "circle.grid.cross",
        makeContent: { AnyView(DocumentListView()) },
        makeDetail: { _ in AnyView(ZZNavigatorView()) },
        hidesDocumentList: true
    )
}
