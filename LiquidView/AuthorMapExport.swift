import SwiftUI
import AppKit

/// Export to XR: sends chosen pieces of the Origami library into an
/// Author (.liquid) document's Map — documents and people become Defined
/// Concepts with positions and connections, which Author renders spatially
/// (and in XR, where z matters).
///
/// The writer never builds a package from scratch: Author's package layout
/// is its own, so we copy a real Author document the user chooses and merge
/// into its `Contents/glossary.json` (entries) and `Contents/DynamicView.json`
/// (connections, plus a new custom layout named "Origami Web"). Both files
/// are round-tripped as dictionaries, so everything we don't understand is
/// preserved byte-for-meaning. The original document is never touched.
nonisolated enum AuthorMapExporter {

    struct Node {
        let key: String            // our identity (origami id, or person name)
        let phrase: String         // the Defined Concept's term
        let description: String
        let tag: String?           // "person" etc.; nil for plain concepts
        let url: String?           // origamitext://open/… back-link
        let date: Date
        let z: Double              // XR depth: documents flat, people lifted
    }

    struct Connection {
        let fromKey: String
        let toKey: String
    }

    enum ExportError: LocalizedError {
        case notAuthorPackage
        case malformedMember(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorPackage:
                "The chosen file is not an Author document (no Contents/glossary.json and DynamicView.json inside)."
            case .malformedMember(let name):
                "Could not read \(name) in the Author document."
            }
        }
    }

    /// Copies `source` to `destination` and merges the nodes and
    /// connections into the copy. Returns how many entries were added
    /// (existing entries with the same phrase are reused, not duplicated).
    @discardableResult
    static func export(nodes: [Node], connections: [Connection],
                       from source: URL, to destination: URL) throws -> Int {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)

        let glossaryURL = destination.appendingPathComponent("Contents/glossary.json")
        let dynamicURL = destination.appendingPathComponent("Contents/DynamicView.json")
        guard fm.fileExists(atPath: glossaryURL.path), fm.fileExists(atPath: dynamicURL.path) else {
            throw ExportError.notAuthorPackage
        }

        // Glossary: one Defined Concept per node, shaped like Author's own.
        guard var glossary = try JSONSerialization.jsonObject(
            with: Data(contentsOf: glossaryURL)) as? [String: Any] else {
            throw ExportError.malformedMember("glossary.json")
        }
        var entries = glossary["entries"] as? [String: Any] ?? [:]
        var uuidByKey: [String: String] = [:]
        var added = 0
        for node in nodes {
            if let existing = entries.first(where: {
                (($0.value as? [String: Any])?["phrase"] as? String)?
                    .caseInsensitiveCompare(node.phrase) == .orderedSame
            }) {
                uuidByKey[node.key] = existing.key   // connect to the existing concept
                continue
            }
            let uuid = UUID().uuidString
            uuidByKey[node.key] = uuid
            var entry: [String: Any] = [
                "identifier": uuid,
                "phrase": node.phrase,
                "description": node.description,
                "isLiked": false,
                "isContext": false,
                "citationIdentifiers": [] as [String],
                "urls": node.url.map { [["url": $0]] } ?? [] as [[String: String]],
                "documentPath": "",
                "date": node.date.timeIntervalSinceReferenceDate,
            ]
            if let tag = node.tag { entry["tag"] = tag }
            entries[uuid] = entry
            added += 1
        }
        glossary["entries"] = entries
        try JSONSerialization.data(withJSONObject: glossary, options: [.prettyPrinted, .sortedKeys])
            .write(to: glossaryURL, options: .atomic)

        // Dynamic view: our web as connections, and a custom layout that
        // keeps the document's existing arrangement and rings ours around it.
        guard var dynamic = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dynamicURL)) as? [String: Any] else {
            throw ExportError.malformedMember("DynamicView.json")
        }
        var existingConnections = dynamic["connections"] as? [[String: Any]] ?? []
        for connection in connections {
            guard let from = uuidByKey[connection.fromKey],
                  let to = uuidByKey[connection.toKey], from != to else { continue }
            existingConnections.append([
                "identifier": UUID().uuidString,
                "startNodeIdentifier": from,
                "endingNodeIdentifier": to,
            ])
        }
        dynamic["connections"] = existingConnections

        var layouts = dynamic["customLayouts"] as? [[String: Any]] ?? []
        var positions = (layouts.last?["layout"] as? [String: Any])?["nodePositions"]
            as? [[String: Any]] ?? []
        let placed = Set(positions.compactMap { $0["id"] as? String })
        let newIDs = nodes.compactMap { node in
            uuidByKey[node.key].flatMap { placed.contains($0) ? nil : ($0, node.z) }
        }
        for (index, entry) in newIDs.enumerated() {
            // A ring around the existing map, wider than the sample's
            // extent, so the arrivals read as a constellation of guests.
            let angle = 2 * Double.pi * Double(index) / Double(max(newIDs.count, 1)) - .pi / 2
            positions.append([
                "id": entry.0,
                "x": 1300 * cos(angle),
                "y": 1300 * sin(angle),
                "z": entry.1,
            ])
        }
        layouts.append([
            "id": UUID().uuidString,
            "name": "Origami Web",
            "layout": ["nodePositions": positions],
        ])
        dynamic["customLayouts"] = layouts
        try JSONSerialization.data(withJSONObject: dynamic, options: [.prettyPrinted, .sortedKeys])
            .write(to: dynamicURL, options: .atomic)
        return added
    }
}

/// The Export to XR sheet: the user decides what travels — which
/// documents and which people become nodes in Author's Map.
struct ExportToXRSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDocs: Set<String> = []
    @State private var selectedPeople: Set<String> = []
    @State private var includeConnections = true

    private var documents: [LiquidDoc] {
        model.index.byID.values.map(\.doc).sorted { $0.listedDate > $1.listedDate }
    }

    /// Everyone the library has heard from: authors and meeting speakers.
    private var people: [String] {
        var names: Set<String> = []
        for entry in model.index.byID.values {
            names.insert(entry.doc.author)
            for paragraph in entry.doc.body ?? [] {
                if let speaker = paragraph.speaker { names.insert(speaker) }
            }
        }
        return names.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export to XR — Author Map")
                .font(.title3.bold())
            Text("Choose what becomes a node. The selection is merged into a copy of an Author document you pick; the copy's Map gains the nodes, their connections, and a layout named “Origami Web”. Your original Author document is untouched.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List {
                Section {
                    ForEach(documents) { doc in
                        Toggle(isOn: binding(for: doc.id, in: $selectedDocs)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(doc.title).lineLimit(1)
                                Text("\(doc.displayAuthor) · \(doc.listedDateText)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    selectAllHeader("Documents (\(documents.count))",
                                    all: Set(documents.map(\.id)), selection: $selectedDocs)
                }
                Section {
                    ForEach(people, id: \.self) { name in
                        Toggle(isOn: binding(for: name, in: $selectedPeople)) {
                            Text(name)
                        }
                    }
                } header: {
                    selectAllHeader("People (\(people.count))",
                                    all: Set(people), selection: $selectedPeople)
                }
            }
            .frame(minHeight: 320)

            Toggle("Include connections (citations, authorship, who spoke where)",
                   isOn: $includeConnections)

            HStack {
                Text("\(selectedDocs.count + selectedPeople.count) nodes")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Export…") {
                    model.exportToXR(documentIDs: selectedDocs,
                                     people: selectedPeople,
                                     includeConnections: includeConnections)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedDocs.isEmpty && selectedPeople.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, height: 560)
    }

    private func binding(for key: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(key) },
                set: { included in
                    if included { set.wrappedValue.insert(key) }
                    else { set.wrappedValue.remove(key) }
                })
    }

    private func selectAllHeader(_ title: String, all: Set<String>,
                                 selection: Binding<Set<String>>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button(selection.wrappedValue.count == all.count ? "None" : "All") {
                selection.wrappedValue = selection.wrappedValue.count == all.count ? [] : all
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
    }
}
