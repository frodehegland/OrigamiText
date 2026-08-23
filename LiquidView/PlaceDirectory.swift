import Foundation
import CoreLocation
import Observation

/// The library's gazetteer: every distinct place a note has carried,
/// searched exactly once (the format stores place names, never
/// coordinates) and remembered forever. A place whose own text names its
/// country — "Wimbledon, London, United Kingdom" — verifies itself; a
/// bare one like "Ytrebygda" waits for the reader to confirm what the
/// search found before it groups under that country.
@MainActor @Observable
final class PlaceDirectory {

    nonisolated struct Record: Codable, Identifiable, Hashable, Sendable {
        var id: String          // normalized place text
        var place: String       // the place as a note wrote it
        var latitude: Double?
        var longitude: Double?
        var locality: String?   // the town/city the search found
        var country: String?    // the country the search found
        var status: Status

        enum Status: String, Codable, Sendable {
            case pending    // found; awaiting the reader's confirmation
            case verified   // confirmed (or self-evident from the text)
            case rejected   // the reader said the search got it wrong
            case failed     // the search found nothing; never re-asked
        }

        var coordinate: CLLocationCoordinate2D? {
            guard let latitude, let longitude else { return nil }
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    private(set) var records: [String: Record] = [:]
    private var queue: [String] = []
    private var queued: Set<String> = []
    private var isGeocoding = false
    private let geocoder = CLGeocoder()

    init() {
        load()
    }

    nonisolated static func key(_ place: String) -> String {
        place.trimmingCharacters(in: .whitespaces).lowercased()
    }

    func record(for place: String) -> Record? {
        records[Self.key(place)]
    }

    /// The confirmed country for a place, for grouping bare place names
    /// under their country once the reader has verified the search.
    func verifiedCountry(for place: String) -> String? {
        guard let record = records[Self.key(place)], record.status == .verified else { return nil }
        return record.country
    }

    /// Places found by search and awaiting the reader's word.
    var pendingVerification: [Record] {
        records.values
            .filter { $0.status == .pending && $0.country != nil }
            .sorted { $0.place.localizedCaseInsensitiveCompare($1.place) == .orderedAscending }
    }

    /// Queues a search for every place not yet known — called whenever a
    /// list or map meets the library's locations. One search per place,
    /// ever; results persist across launches.
    func resolveMissing(in locations: [String?]) {
        for case let location? in locations {
            let key = Self.key(location)
            guard !key.isEmpty, records[key] == nil, !queued.contains(key) else { continue }
            queued.insert(key)
            queue.append(location)
        }
        processQueue()
    }

    func verify(_ record: Record) {
        setStatus(.verified, for: record)
    }

    func reject(_ record: Record) {
        setStatus(.rejected, for: record)
    }

    private func setStatus(_ status: Record.Status, for record: Record) {
        guard var updated = records[record.id] else { return }
        updated.status = status
        records[record.id] = updated
        save()
    }

    // MARK: The search

    private func processQueue() {
        guard !isGeocoding, !queue.isEmpty else { return }
        isGeocoding = true
        let place = queue.removeFirst()
        Task {
            let placemark = try? await geocoder.geocodeAddressString(place).first
            var record = Record(id: Self.key(place), place: place,
                                latitude: placemark?.location?.coordinate.latitude,
                                longitude: placemark?.location?.coordinate.longitude,
                                locality: placemark?.locality,
                                country: placemark?.country,
                                status: placemark == nil ? .failed : .pending)
            // A place whose own text names its country needs no
            // confirming — the search only adds coordinates for the map.
            if record.status == .pending, place.contains(",") {
                record.status = .verified
            }
            records[record.id] = record
            save()
            // Geocoding is rate-limited: a breath between searches.
            try? await Task.sleep(for: .milliseconds(400))
            isGeocoding = false
            processQueue()
        }
    }

    // MARK: Persistence

    private nonisolated static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("PlaceDirectory.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([String: Record].self, from: data)
        else { return }
        records = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}

/// One named locality the phone published into the community folder — a
/// nickname the user gave a spot, kept with the automatic locality the
/// reverse-geocode found and the precise fix taken at naming. The field
/// shape matches the phone's `MyPlaces.Record`, so the shared
/// `Localities.json` decodes on either platform.
nonisolated struct Locality: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String        // the nickname the user chose
    var latitude: Double
    var longitude: Double
    var tail: String        // "Wimbledon, London, United Kingdom"

    /// The whole stamp a note from here carries — nickname, then the
    /// surroundings — matching the phone's `stamp`.
    var stamp: String { tail.isEmpty ? name : "\(name), \(tail)" }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// The named-locality registry as the Mac sees it: **read-only**. Naming
/// takes a precise on-device fix and so happens only on the phone, which
/// publishes `Localities.json` into the community folder; the Mac reads
/// it so the user can refer to a nickname and the system knows where it
/// is. Adding on the Mac is deliberately not offered yet.
@MainActor @Observable
final class LocalityDirectory {
    private(set) var localities: [Locality] = []

    nonisolated static let communityFileName = "Localities.json"

    /// Reads the registry the phone published into the open folder.
    func attach(folder: URL) {
        let url = folder.appendingPathComponent(Self.communityFileName)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Locality].self, from: data)
        else { localities = []; return }
        localities = decoded.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// The locality a nickname refers to, so a reference to "the studio"
    /// resolves to where it is. Matches the chosen name, case-insensitively.
    func locality(named name: String) -> Locality? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return localities.first {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }
}
