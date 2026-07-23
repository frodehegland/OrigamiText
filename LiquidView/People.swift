import Foundation
import Observation

/// A person as a contact record. When an ORCID iD is present it is the
/// canonical identity for the person; the local id covers everyone else.
nonisolated struct Person: Codable, Identifiable, Hashable, Sendable {
    var givenName: String = ""
    var middleName: String = ""
    var familyName: String = ""
    var affiliation: String = ""
    /// Canonical academic identity when present.
    var orcid: String = ""
    // Additional fields ORCID returns, kept visible in the record.
    var creditName: String = ""
    var otherNames: [String] = []
    var emails: [String] = []
    /// The person's public profile in their own words — a bio shown on
    /// their card and page. Optional so records saved before the field
    /// existed still decode.
    var publicProfile: String?
    /// Whether the letter post mails published letters to this person.
    /// Optional so earlier records still decode; absent means included,
    /// which is what the post always did before the choice existed.
    var letterDistribution: Bool?
    var isInLetterDistribution: Bool { letterDistribution ?? true }
    /// Other spellings this person answers to — a transcript's rendering
    /// of their name, associated with the record by hand. Optional so
    /// records saved before the field existed still decode.
    var aliases: [String]?
    var localID: String = UUID().uuidString

    var id: String { orcid.isEmpty ? localID : orcid }

    var displayName: String {
        [givenName, middleName, familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Whether this record answers to a name: the display name, or any
    /// stored alias.
    func answersTo(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if displayName.caseInsensitiveCompare(trimmed) == .orderedSame { return true }
        return (aliases ?? []).contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// The two cards folded into one, for the user to approve: this
    /// record's identity leads, the other's fills its gaps, addresses
    /// and names all kept — and the absorbed display name becomes an
    /// alias, so documents and statements under either name answer to
    /// the one record.
    func merged(absorbing other: Person) -> Person {
        var merged = self
        if merged.orcid.isEmpty { merged.orcid = other.orcid }
        if merged.affiliation.isEmpty { merged.affiliation = other.affiliation }
        if merged.creditName.isEmpty { merged.creditName = other.creditName }
        if (merged.publicProfile ?? "").isEmpty { merged.publicProfile = other.publicProfile }
        if merged.letterDistribution == nil { merged.letterDistribution = other.letterDistribution }
        for email in other.emails
        where !merged.emails.contains(where: { $0.caseInsensitiveCompare(email) == .orderedSame }) {
            merged.emails.append(email)
        }
        for name in other.otherNames
        where !merged.otherNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            merged.otherNames.append(name)
        }
        var aliases = merged.aliases ?? []
        func addAlias(_ name: String) {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  displayName.caseInsensitiveCompare(trimmed) != .orderedSame,
                  !aliases.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
            else { return }
            aliases.append(trimmed)
        }
        addAlias(other.displayName)
        for alias in other.aliases ?? [] { addAlias(alias) }
        merged.aliases = aliases.isEmpty ? nil : aliases
        return merged
    }

    init() {}

    /// Best-effort split of a display name into parts.
    init(displayName: String) {
        self.init()
        let parts = displayName.split(separator: " ").map(String.init)
        givenName = parts.first ?? ""
        familyName = parts.count > 1 ? (parts.last ?? "") : ""
        middleName = parts.count > 2 ? parts.dropFirst().dropLast().joined(separator: " ") : ""
    }
}

/// The directory of people. It lives twice: a copy in the app container
/// so it works before any folder is chosen, and — the moment a community
/// folder is open — a copy in the folder itself (People.json), where the
/// phone and the headset find the community's contact information.
/// Muting, correspondence ranking, and attention all speak in names;
/// this directory is where names gain records and canonical identity.
@MainActor @Observable
final class PersonDirectory {
    private(set) var people: [Person] = []
    private let localURL: URL
    /// The community folder's copy, once a folder is open.
    private var communityURL: URL?
    /// True when the community folder refused the last write — the saved
    /// folder access may predate contact sharing and be read-only;
    /// choosing the folder again renews it with write access.
    private(set) var communityWriteFailed = false

    /// The file name every platform looks for in the community folder.
    nonisolated static let communityFileName = "People.json"

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        localURL = base.appendingPathComponent("People.json")
        load()
    }

    /// Points the directory at an open community folder: records already
    /// in the folder's copy are folded in (local records win a conflict,
    /// since this Mac is where records are edited), then the merged
    /// directory is written back so the folder always holds the fullest
    /// picture.
    func attach(folder: URL) {
        let shared = folder.appendingPathComponent(Self.communityFileName)
        communityURL = shared
        if let data = try? Data(contentsOf: shared),
           let arrived = try? JSONDecoder().decode([Person].self, from: data) {
            for person in arrived where !contains(person) {
                people.append(person)
            }
        }
        save()
    }

    /// Replaces by canonical identity (ORCID), else by matching name,
    /// else inserts.
    func upsert(_ person: Person) {
        if !person.orcid.isEmpty,
           let index = people.firstIndex(where: { $0.orcid == person.orcid }) {
            people[index] = person
        } else if let index = people.firstIndex(where: {
            $0.displayName.caseInsensitiveCompare(person.displayName) == .orderedSame
        }) {
            people[index] = person
        } else {
            people.append(person)
        }
        save()
    }

    /// The record answering to a name — its display name first, so an
    /// alias can never shadow someone's actual name, then any alias.
    func person(named name: String) -> Person? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let exact = people.first(where: {
            $0.displayName.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return exact
        }
        return people.first { $0.answersTo(trimmed) }
    }

    /// Removes a record entirely — merging folds two into one.
    func remove(_ person: Person) {
        people.removeAll { $0.localID == person.localID }
        save()
    }

    /// Records that a person answers to another name — a transcript's
    /// spelling of them, associated with their record. The alias is
    /// stored on the record and travels with the directory.
    func associate(alias: String, with person: Person) {
        let trimmed = alias.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !person.answersTo(trimmed) else { return }
        var updated = person
        updated.aliases = (updated.aliases ?? []) + [trimmed]
        upsert(updated)
    }

    private func contains(_ person: Person) -> Bool {
        if !person.orcid.isEmpty, people.contains(where: { $0.orcid == person.orcid }) {
            return true
        }
        return people.contains {
            $0.displayName.caseInsensitiveCompare(person.displayName) == .orderedSame
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: localURL),
              let loaded = try? JSONDecoder().decode([Person].self, from: data) else { return }
        people = loaded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(people) else { return }
        try? data.write(to: localURL, options: .atomic)
        guard let communityURL else { return }
        do {
            try data.write(to: communityURL, options: .atomic)
            communityWriteFailed = false
        } catch {
            communityWriteFailed = true
        }
    }
}

/// One result from ORCID's public expanded search — every field the API
/// returns, kept visible.
nonisolated struct ORCIDResult: Identifiable, Sendable {
    let orcid: String
    let givenNames: String
    let familyNames: String
    let creditName: String
    let otherNames: [String]
    let emails: [String]
    let institutions: [String]
    var id: String { orcid }
}

/// Minimal client for ORCID's public API (pub.orcid.org, no key required).
nonisolated enum ORCIDClient {

    static func search(givenName: String, familyName: String) async throws -> [ORCIDResult] {
        var terms: [String] = []
        let given = givenName.trimmingCharacters(in: .whitespaces)
        let family = familyName.trimmingCharacters(in: .whitespaces)
        if !given.isEmpty { terms.append("given-names:\(given)") }
        if !family.isEmpty { terms.append("family-name:\(family)") }
        guard !terms.isEmpty else { return [] }

        var components = URLComponents(string: "https://pub.orcid.org/v3.0/expanded-search/")
        components?.queryItems = [
            URLQueryItem(name: "q", value: terms.joined(separator: " AND ")),
            URLQueryItem(name: "rows", value: "10"),
        ]
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, _) = try await URLSession.shared.data(for: request)

        struct Envelope: Decodable {
            let expandedResult: [Item]?
            enum CodingKeys: String, CodingKey { case expandedResult = "expanded-result" }
        }
        struct Item: Decodable {
            let orcidId: String?
            let givenNames: String?
            let familyNames: String?
            let creditName: String?
            let otherName: [String]?
            let email: [String]?
            let institutionName: [String]?
            enum CodingKeys: String, CodingKey {
                case orcidId = "orcid-id"
                case givenNames = "given-names"
                case familyNames = "family-names"
                case creditName = "credit-name"
                case otherName = "other-name"
                case email
                case institutionName = "institution-name"
            }
        }

        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        return (envelope.expandedResult ?? []).compactMap { item in
            guard let orcid = item.orcidId, !orcid.isEmpty else { return nil }
            return ORCIDResult(orcid: orcid,
                               givenNames: item.givenNames ?? "",
                               familyNames: item.familyNames ?? "",
                               creditName: item.creditName ?? "",
                               otherNames: item.otherName ?? [],
                               emails: item.email ?? [],
                               institutions: item.institutionName ?? [])
        }
    }

    /// The public name behind an ORCID iD, for photograph search when the
    /// form holds only the iD.
    static func name(forORCID orcid: String) async throws -> String? {
        let id = orcid.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty,
              let url = URL(string: "https://pub.orcid.org/v3.0/\(id)/personal-details") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)

        struct Envelope: Decodable {
            struct Name: Decodable {
                struct Value: Decodable { let value: String }
                let givenNames: Value?
                let familyName: Value?
                enum CodingKeys: String, CodingKey {
                    case givenNames = "given-names"
                    case familyName = "family-name"
                }
            }
            let name: Name?
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        let full = [envelope.name?.givenNames?.value, envelope.name?.familyName?.value]
            .compactMap { $0 }
            .joined(separator: " ")
        return full.isEmpty ? nil : full
    }
}

/// A photograph found online for a person: the lead image of a Wikipedia
/// page matching the name.
nonisolated struct FoundPhoto: Identifiable, Sendable {
    /// The page title — names the person or article the image leads.
    let title: String
    let imageURL: URL
    var id: String { title }
}

/// Keyless photograph search: Wikipedia's public API, taking the lead
/// image of each page that matches the person's name.
nonisolated enum PhotoSearchClient {
    static func searchPhotos(name: String) async throws -> [FoundPhoto] {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: name),
            URLQueryItem(name: "gsrlimit", value: "12"),
            URLQueryItem(name: "gsrnamespace", value: "0"),
            URLQueryItem(name: "prop", value: "pageimages"),
            URLQueryItem(name: "piprop", value: "thumbnail"),
            URLQueryItem(name: "pithumbsize", value: "600"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
        ]
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url)
        // Wikimedia asks API clients to identify themselves.
        request.setValue("OrigamiText/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)

        struct Envelope: Decodable {
            struct Query: Decodable { let pages: [Page]? }
            struct Page: Decodable {
                let title: String
                let index: Int?
                let thumbnail: Thumbnail?
            }
            struct Thumbnail: Decodable { let source: String }
            let query: Query?
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        return (envelope.query?.pages ?? [])
            .sorted { ($0.index ?? .max) < ($1.index ?? .max) }
            .compactMap { page in
                guard let source = page.thumbnail?.source,
                      let imageURL = URL(string: source) else { return nil }
                return FoundPhoto(title: page.title, imageURL: imageURL)
            }
    }
}
