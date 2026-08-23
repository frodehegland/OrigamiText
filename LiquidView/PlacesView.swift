import SwiftUI
import MapKit

/// Places: the library on a map. Every place the notes have carried
/// stands as a marker bearing its note count; choosing one lists the
/// notes made there, each a doorway to the reader. Places found by
/// search but not yet confirmed wait in the corner for the reader's
/// word. The format stores place names, never coordinates — the pins
/// come from the PlaceDirectory's one-time searches.
struct PlacesView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedKey: String?

    private struct Pin: Identifiable {
        let id: String
        let name: String
        let coordinate: CLLocationCoordinate2D
        let docs: [LiquidDoc]
        let unverified: Bool
    }

    private var pins: [Pin] {
        var docsByKey: [String: [LiquidDoc]] = [:]
        var nameByKey: [String: String] = [:]
        for entry in model.filteredEntries {
            guard let location = entry.doc.location else { continue }
            let key = PlaceDirectory.key(location)
            docsByKey[key, default: []].append(entry.doc)
            nameByKey[key] = location
        }
        return docsByKey.compactMap { key, docs in
            guard let record = model.places.records[key],
                  record.status != .rejected,
                  let coordinate = record.coordinate else { return nil }
            let written = nameByKey[key] ?? record.place
            // A pin at the reader's Home or Work says so; the record
            // keeps the full place name.
            let name = AppLocations.label(for: written)
                ?? written.split(separator: ",").first
                    .map { $0.trimmingCharacters(in: .whitespaces) } ?? written
            return Pin(id: key, name: name, coordinate: coordinate,
                       docs: docs.sorted { $0.listedDate > $1.listedDate },
                       unverified: record.status == .pending)
        }
    }

    var body: some View {
        Map {
            ForEach(pins) { pin in
                Annotation(pin.name, coordinate: pin.coordinate) {
                    Button {
                        selectedKey = selectedKey == pin.id ? nil : pin.id
                    } label: {
                        ZStack {
                            Circle()
                                .fill(pin.unverified ? Color.orange : Color.accentColor)
                                .frame(width: 26, height: 26)
                                .shadow(radius: 1)
                            Text("\(pin.docs.count)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(pin.unverified
                          ? "\(pin.name) — placement not yet confirmed"
                          : pin.name)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if let pin = pins.first(where: { $0.id == selectedKey }) {
                placeCard(pin)
            }
        }
        .overlay(alignment: .bottomLeading) {
            verificationCard
        }
        .overlay {
            if pins.isEmpty {
                ContentUnavailableView(
                    "No Places Yet",
                    systemImage: "map",
                    description: Text("Notes that carry a place appear here once its one-time search has run."))
                .allowsHitTesting(false)
            }
        }
        // Every location the library holds gets its one search.
        .task(id: model.index.timeline.count) {
            model.places.resolveMissing(in: model.filteredEntries.map(\.doc.location))
        }
        .navigationTitle("Places")
    }

    /// The notes made at the chosen place.
    private func placeCard(_ pin: Pin) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(pin.name)
                    .font(.headline)
                Spacer()
                Button {
                    selectedKey = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(pin.docs) { doc in
                        Button {
                            model.openInLibrary(doc)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(doc.title)
                                    .lineLimit(1)
                                Text(doc.listedDateText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(12)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 4)
        .padding(12)
    }

    /// Places the search found whose grouping awaits the reader's word.
    @ViewBuilder private var verificationCard: some View {
        let pending = model.places.pendingVerification
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Confirm Places")
                    .font(.headline)
                ForEach(pending) { record in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.place)
                            .font(.subheadline.weight(.semibold))
                        Text(foundText(record))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Confirm") { model.places.verify(record) }
                            Button("Not This") { model.places.reject(record) }
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(12)
            .frame(width: 260)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 4)
            .padding(12)
        }
    }

    private func foundText(_ record: PlaceDirectory.Record) -> String {
        let country = record.country ?? "an unknown country"
        if let locality = record.locality, PlaceDirectory.key(locality) != record.id {
            return "Found in \(country), near \(locality)."
        }
        return "Found in \(country)."
    }
}

extension PlacesView {
    @MainActor static let module = LibraryViewModule(
        id: "places",
        name: "Map",
        systemImage: "map",
        makeContent: { AnyView(DocumentListView()) },
        makeDetail: { _ in AnyView(PlacesView()) },
        hidesDocumentList: true
    )
}
