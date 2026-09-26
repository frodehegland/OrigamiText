import Foundation
import Observation
import FoundationModels

/// The revised profile as the on-device model returns it.
@Generable
nonisolated struct GeneratedAuthorProfile {
    @Guide(description: "The revised profile: a short paragraph on this person's interests, concerns, temperament, and way of writing — only what their words support")
    var profile: String
    @Guide(description: "The subjects this person keeps returning to, a few words each")
    var interests: [String]
}

/// What the library has learned about one person, built up letter by
/// letter on this Mac. Distinct from the contact record's public profile
/// (the person's own words about themselves): this is the reader's
/// working impression, revised by the on-device model as writing arrives.
nonisolated struct PersonProfile: Codable, Sendable {
    var name: String
    /// The running personality profile — interests, concerns, temperament,
    /// way of writing.
    var summary: String = ""
    /// The subjects this person keeps returning to.
    var interests: [String] = []
    /// Documents already folded in — authored, or spoken in as a
    /// transcript statement — so each is digested exactly once.
    var digestedDocIDs: Set<String> = []
    var updated: Date = .distantPast
}

/// Defaults for profile building. Runs entirely on-device (Apple
/// Intelligence); no text leaves the Mac. The prompt is editable in
/// Settings → AI.
nonisolated enum AuthorProfiles {

    static let defaultPrompt = """
    You maintain a working profile of one member of a community of correspondents, revised as their letters arrive. From the existing profile and their new writing, produce the revised profile: a short paragraph describing their interests, concerns, temperament, and way of writing. Describe only what their words support — no flattery, no diagnosis, no guesses about their life outside the letters. Keep what the existing profile still gets right, revise what the new writing changes, and name the subjects they keep returning to.
    """

    /// Per-document and per-person caps keep the request inside the
    /// on-device model's window; long letters contribute their opening.
    static let perDocumentCharacterLimit = 1_200
    static let perPersonCharacterLimit = 8_000
}

/// One person's new writing from one document, awaiting digestion:
/// their letter's text, or the statements they spoke in a transcript.
nonisolated struct AuthorContribution: Sendable {
    let docID: String
    let title: String
    let date: Date
    let text: String
}

/// The store of built-up profiles: plain JSON in the app container, like
/// the person directory. `digest` is the continual entry point — called
/// whenever the library index changes, it folds in only documents not yet
/// digested, so a quiet library costs nothing.
///
/// Views use profiles through `AppModel.personality(for:)` (or
/// `profile(for:)` here for interests and dates): wherever a person's
/// known personality should color a view, that is the hook.
@MainActor @Observable
final class PersonProfileStore {
    private(set) var profiles: [PersonProfile] = []
    /// True while the model is revising; views may show a quiet indicator.
    private(set) var isDigesting = false
    private var pendingEntries: [IndexEntry]?
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = base.appendingPathComponent("AuthorProfiles.json")
        load()
    }

    func profile(for name: String) -> PersonProfile? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return profiles.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// The known personality of a person, or nil while the library has
    /// taught the model nothing about them yet.
    func personality(for name: String) -> String? {
        guard let summary = profile(for: name)?.summary, !summary.isEmpty else { return nil }
        return summary
    }

    /// Forgetting is always available: a person's built profile can be
    /// discarded; their documents will be digested afresh on the next pass.
    func removeProfile(for name: String) {
        profiles.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        save()
    }

    // MARK: Continual digestion

    /// Folds new documents into their authors' profiles: every letter is
    /// credited to its author, every transcript statement to its speaker,
    /// each document exactly once per person. Building must be enabled in
    /// Settings → AI and requires Apple Intelligence; a call that arrives
    /// mid-digestion is remembered and run after.
    func digest(entries: [IndexEntry]) {
        guard isEnabled else { return }
        guard case .available = SystemLanguageModel.default.availability else { return }
        if isDigesting {
            pendingEntries = entries
            return
        }
        let work = newContributions(in: entries)
        guard !work.isEmpty else { return }
        let prompt = UserDefaults.standard.string(forKey: AppSettings.aiPersonProfilePromptKey)
            ?? AuthorProfiles.defaultPrompt
        isDigesting = true
        Task {
            for (name, contributions) in work.sorted(by: { $0.key < $1.key }) {
                await revise(name: name, with: contributions, basePrompt: prompt)
            }
            isDigesting = false
            if let pending = pendingEntries {
                pendingEntries = nil
                digest(entries: pending)
            }
        }
    }

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: AppSettings.aiPersonProfilesEnabledKey) == nil
            || UserDefaults.standard.bool(forKey: AppSettings.aiPersonProfilesEnabledKey)
    }

    /// Everyone's undigested writing, keyed by name: the body of each
    /// letter for its credited author (the Visual-Meta appendix is
    /// metadata, never character evidence), and each transcript statement
    /// for its speaker.
    private func newContributions(in entries: [IndexEntry]) -> [String: [AuthorContribution]] {
        var work: [String: [AuthorContribution]] = [:]
        // Names unify case-insensitively, keeping the first-seen spelling.
        var spelling: [String: String] = [:]
        func canonical(_ name: String) -> String {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            let key = trimmed.lowercased()
            if let known = spelling[key] { return known }
            spelling[key] = trimmed
            return trimmed
        }
        for profile in profiles {
            spelling[profile.name.lowercased()] = profile.name
        }
        func add(_ name: String, docID: String, title: String, date: Date, text: String) {
            let person = canonical(name)
            guard !person.isEmpty, !text.isEmpty,
                  profile(for: person)?.digestedDocIDs.contains(docID) != true else { return }
            work[person, default: []].append(
                AuthorContribution(docID: docID, title: title, date: date, text: text))
        }
        for entry in entries {
            let doc = entry.doc
            let appendixIDs = doc.visualMetaParagraphIDs
            let paragraphs = (doc.body ?? []).filter {
                !appendixIDs.contains($0.id) && !$0.displayText.isEmpty
            }
            let authored = paragraphs
                .filter { $0.speaker == nil }
                .map(\.displayText)
                .joined(separator: "\n")
            add(doc.creditedAuthor, docID: doc.id, title: doc.title,
                date: doc.listedDate, text: authored)
            let bySpeaker = Dictionary(grouping: paragraphs.filter { $0.speaker != nil },
                                       by: { $0.speaker ?? "" })
            for (speaker, statements) in bySpeaker {
                add(speaker, docID: doc.id, title: doc.title, date: doc.listedDate,
                    text: statements.map(\.displayText).joined(separator: "\n"))
            }
        }
        return work
    }

    /// One person's revision: the existing profile and their new writing
    /// go to the on-device model; its answer replaces the summary. On any
    /// error the documents stay undigested and the next pass tries again.
    private func revise(name: String, with contributions: [AuthorContribution],
                        basePrompt: String) async {
        var profile = profile(for: name) ?? PersonProfile(name: name)
        var prompt = basePrompt
        prompt += "\n\nTHE PERSON: \(name)\n\nEXISTING PROFILE:\n"
        prompt += profile.summary.isEmpty ? "None yet — this is the first letter.\n" : "\(profile.summary)\n"
        prompt += "\nTHEIR NEW WRITING:\n\n"
        var budget = AuthorProfiles.perPersonCharacterLimit
        for contribution in contributions.sorted(by: { $0.date < $1.date }) {
            guard budget > 0 else { break }
            let text = String(contribution.text.prefix(
                min(AuthorProfiles.perDocumentCharacterLimit, budget)))
            budget -= text.count
            prompt += "— \(contribution.title), \(contribution.date.formatted(date: .abbreviated, time: .omitted)):\n\(text)\n\n"
        }
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt, generating: GeneratedAuthorProfile.self)
            profile.summary = response.content.profile
            profile.interests = response.content.interests
            profile.digestedDocIDs.formUnion(contributions.map(\.docID))
            profile.updated = .now
            upsert(profile)
        } catch {
            // Left undigested; a later pass will try again.
        }
    }

    private func upsert(_ profile: PersonProfile) {
        if let index = profiles.firstIndex(where: {
            $0.name.caseInsensitiveCompare(profile.name) == .orderedSame
        }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode([PersonProfile].self, from: data) else { return }
        profiles = loaded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(profiles) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
