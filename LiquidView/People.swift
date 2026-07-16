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
    var localID: String = UUID().uuidString

    var id: String { orcid.isEmpty ? localID : orcid }

    var displayName: String {
        [givenName, middleName, familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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

/// The local directory of people: plain JSON in the app container.
/// Muting, correspondence ranking, and attention all speak in names;
/// this directory is where names gain records and canonical identity.
@MainActor @Observable
final class PersonDirectory {
    private(set) var people: [Person] = []
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = base.appendingPathComponent("People.json")
        load()
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

    func person(named name: String) -> Person? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return people.first { $0.displayName.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode([Person].self, from: data) else { return }
        people = loaded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(people) {
            try? data.write(to: fileURL, options: .atomic)
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
}
