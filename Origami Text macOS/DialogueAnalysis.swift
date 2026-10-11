import Foundation
import CryptoKit
import Observation

/// Who is who across meetings (ORIGAMI-DIALOGUE-PROFILE.md §6): the ORCID
/// iD when given, else the full name folded — case, accents and spacing
/// do not count — and every alias a participant declares answers for them.
enum DialoguePeople {

    /// A person's key across every meeting and series.
    static func key(name: String, orcid: String?) -> String {
        if let orcid = orcid?.trimmingCharacters(in: .whitespaces), !orcid.isEmpty {
            return "orcid:" + orcid.replacingOccurrences(of: "https://orcid.org/", with: "")
        }
        return "name:" + fold(name)
    }

    static func fold(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    /// A meeting's names → person keys: each participant's name and
    /// aliases, folded.
    static func directory(_ participants: [DialogueInfo.Participant]) -> [String: String] {
        var out: [String: String] = [:]
        for participant in participants {
            let key = key(name: participant.name, orcid: participant.orcid)
            for name in participant.names { out[fold(name)] = key }
        }
        return out
    }
}

/// The first analysis of a meeting — no model at all, so it is instant
/// and certain: speaking, answering, mentioning, linking, the words used.
/// Topics, themes and claims come from the model later, anchored to the
/// same turn ids.
enum MeetingAnalyser {

    /// One meeting analysed from its body and its dialogue facts.
    static func analyse(body: [LiquidDoc.Paragraph], info: DialogueInfo,
                        meeting: String, recordID: String, title: String) -> MeetingAnalysis {
        let names = DialoguePeople.directory(info.participants)
        var displayName: [String: String] = [:]
        for participant in info.participants {
            displayName[DialoguePeople.key(name: participant.name, orcid: participant.orcid)] = participant.name
        }
        func person(for speaker: String) -> String {
            let folded = DialoguePeople.fold(speaker)
            if let known = names[folded] { return known }
            let key = DialoguePeople.key(name: speaker, orcid: nil)
            if displayName[key] == nil { displayName[key] = speaker }
            return key
        }

        // The turns: a paragraph with a speaker begins one; an unlabelled
        // paragraph after it continues it (§4), until a heading. A letter's
        // paragraphs are all its sender's.
        let sender = info.kind == .letter
            ? info.participants.first { ["sender", "aut"].contains($0.role ?? "") }?.name
                ?? info.participants.first?.name
            : nil
        var turns: [MeetingAnalysis.Turn] = []
        var texts: [String: String] = [:]
        var sections: [MeetingAnalysis.Section] = []
        var section: String?
        var current: String? = sender.map(person(for:))
        for paragraph in body {
            if let level = paragraph.effectiveHeading, level >= 1 {
                section = paragraph.id
                sections.append(.init(id: paragraph.id, title: paragraph.displayText,
                                      firstTurn: nil, turns: 0))
                if sender == nil { current = nil }
                continue
            }
            if let speaker = paragraph.speaker {
                current = person(for: speaker)
            }
            guard let who = current else { continue }
            let text = spokenText(paragraph)
            let words = text.split(whereSeparator: \.isWhitespace).count
            guard words > 0 else { continue }
            turns.append(.init(id: paragraph.id, person: who, words: words, section: section))
            texts[paragraph.id] = text
            if let index = sections.lastIndex(where: { $0.id == section }) {
                if sections[index].firstTurn == nil { sections[index].firstTurn = paragraph.id }
                sections[index].turns += 1
            }
        }

        // Speaking.
        let totalWords = max(turns.reduce(0) { $0 + $1.words }, 1)
        var order: [String] = []
        var spoken: [String: (turns: Int, words: Int, first: String)] = [:]
        var previous: String?
        for turn in turns {
            if spoken[turn.person] == nil { order.append(turn.person) }
            var entry = spoken[turn.person] ?? (0, 0, turn.id)
            // A continuation is the same turn, not another.
            if previous != turn.person { entry.turns += 1 }
            entry.words += turn.words
            spoken[turn.person] = entry
            previous = turn.person
        }
        let speakers = order.map { key -> MeetingAnalysis.Speaker in
            let entry = spoken[key]!
            return .init(person: key, name: displayName[key] ?? key, turns: entry.turns,
                         words: entry.words, share: Double(entry.words) / Double(totalWords),
                         firstTurn: entry.first)
        }

        // Answering: a turn after another speaker's answers it.
        var exchangeCounts: [String: Int] = [:]
        for (earlier, later) in zip(turns, turns.dropFirst()) where earlier.person != later.person {
            exchangeCounts[later.person + "→" + earlier.person, default: 0] += 1
        }
        let exchanges = exchangeCounts.map { pair, count -> MeetingAnalysis.Exchange in
            let parts = pair.components(separatedBy: "→")
            return .init(from: parts[0], to: parts[1], count: count)
        }.sorted { ($0.count, $0.from, $0.to) > ($1.count, $1.from, $1.to) }

        // Mentioning: a participant's name or alias in another's words.
        var mentionTurns: [String: [String]] = [:]
        for participant in info.participants {
            let key = DialoguePeople.key(name: participant.name, orcid: participant.orcid)
            let patterns = participant.names.filter { $0.count >= 3 }.compactMap { name in
                try? NSRegularExpression(
                    pattern: "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b",
                    options: [.caseInsensitive])
            }
            for turn in turns where turn.person != key {
                guard let text = texts[turn.id] else { continue }
                let range = NSRange(text.startIndex..., in: text)
                if patterns.contains(where: { $0.firstMatch(in: text, range: range) != nil }) {
                    mentionTurns[turn.person + "→" + key, default: []].append(turn.id)
                }
            }
        }
        let mentions = mentionTurns.map { pair, ids -> MeetingAnalysis.Mention in
            let parts = pair.components(separatedBy: "→")
            return .init(by: parts[0], of: parts[1], turns: ids)
        }.sorted { ($0.turns.count, $0.by) > ($1.turns.count, $1.by) }

        // Linking and citing.
        var links: [MeetingAnalysis.Link] = []
        let patterns: [(String, String)] = [
            ("web", #"https?://[^\s\)\]>]+"#),
            ("citation", #"\[cites?:([^\]]+)\]"#),
            ("address", #"origamitext://open/[^\s\)\]>]+"#)]
        for paragraph in body {
            guard let turn = turns.first(where: { $0.id == paragraph.id }) else { continue }
            let text = paragraph.text
            for (kind, pattern) in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let ns = text as NSString
                for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    let target = kind == "citation"
                        ? ns.substring(with: match.range(at: 1))
                        : ns.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
                    links.append(.init(target: target, kind: kind, person: turn.person, turn: turn.id))
                }
            }
        }

        return MeetingAnalysis(
            version: MeetingAnalysis.currentVersion, meeting: meeting, recordID: recordID,
            title: title, date: info.date, number: info.number,
            contentHash: contentHash(body),
            analysed: .now, speakers: speakers, turns: turns, exchanges: exchanges,
            mentions: mentions, links: links,
            terms: terms(in: turns, texts: texts, exclude: Set(info.participants.flatMap(\.names)
                .flatMap { $0.lowercased().split(separator: " ").map(String.init) })),
            // A heading no one spoke under (the transcript's own title) is
            // no section of the meeting.
            sections: sections.filter { $0.turns > 0 })
    }

    /// The words of a turn, its speaker label and the format's tokens gone.
    static func spokenText(_ paragraph: LiquidDoc.Paragraph) -> String {
        var text = paragraph.displayText
        if let speaker = paragraph.speaker, text.hasPrefix(speaker + ":") {
            text = String(text.dropFirst(speaker.count + 1))
        }
        text = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1",
                                         options: .regularExpression)
            .replacingOccurrences(of: #"\[(?:cites?|note|inote):[^\]]*\]"#, with: "",
                                  options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What the meeting is made of, so an unchanged transcript is not
    /// analysed twice.
    static func contentHash(_ body: [LiquidDoc.Paragraph]) -> String {
        var hasher = SHA256()
        for paragraph in body {
            hasher.update(data: Data(paragraph.id.utf8))
            hasher.update(data: Data((paragraph.speaker ?? "").utf8))
            hasher.update(data: Data(paragraph.text.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Terms

    /// The meeting's terms: two-word phrases said at least twice, and
    /// single words said at least three times, common words and the
    /// participants' own names left out — the most used first.
    static func terms(in turns: [MeetingAnalysis.Turn], texts: [String: String],
                      exclude: Set<String>) -> [MeetingAnalysis.Term] {
        var counts: [String: Int] = [:]
        var people: [String: Set<String>] = [:]
        var where_: [String: [String]] = [:]
        for turn in turns {
            guard let text = texts[turn.id] else { continue }
            let words = text.lowercased()
                .split(whereSeparator: { !$0.isLetter && $0 != "-" && $0 != "'" })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-'")) }
                .filter { !$0.isEmpty }
            var seenHere = Set<String>()
            func count(_ term: String) {
                counts[term, default: 0] += 1
                people[term, default: []].insert(turn.person)
                if seenHere.insert(term).inserted, where_[term, default: []].count < 8 {
                    where_[term, default: []].append(turn.id)
                }
            }
            for (index, word) in words.enumerated() {
                let content = word.count >= 4 && !stopwords.contains(word) && !exclude.contains(word)
                if content { count(word) }
                if index + 1 < words.count {
                    let next = words[index + 1]
                    if content, next.count >= 3, !stopwords.contains(next), !exclude.contains(next) {
                        count(word + " " + next)
                    }
                }
            }
        }
        var kept = counts.filter { term, count in
            term.contains(" ") ? count >= 2 : count >= 3
        }
        // A word said only as part of a kept phrase is the phrase's, not a
        // term of its own: "spatial" in "spatial reading".
        for phrase in kept.keys where phrase.contains(" ") {
            for word in phrase.split(separator: " ").map(String.init)
            where (kept[word] ?? 0) <= (kept[phrase] ?? 0) {
                kept[word] = nil
            }
        }
        // A phrase outranks the words it is made of.
        return kept.map { term, count in
            MeetingAnalysis.Term(term: term, count: count,
                                 people: people[term].map { Array($0).sorted() } ?? [],
                                 turns: where_[term] ?? [])
        }
        .sorted { ($0.term.contains(" ") ? $0.count * 2 : $0.count, $0.term)
                > ($1.term.contains(" ") ? $1.count * 2 : $1.count, $1.term) }
        .prefix(40).map { $0 }
    }

    static let stopwords: Set<String> = [
        "about", "above", "actually", "after", "again", "against", "also", "always", "another",
        "anything", "around", "because", "been", "before", "being", "below", "between", "both",
        "could", "didn't", "does", "doesn't", "doing", "don't", "down", "during", "each", "else",
        "even", "every", "everything", "few", "first", "from", "further", "going", "gonna", "good",
        "great", "have", "having", "he's", "here", "hers", "herself", "him", "himself", "his",
        "i'm", "i've", "into", "it's", "itself", "just", "kind", "know", "like", "little", "look",
        "made", "make", "many", "maybe", "mean", "might", "more", "most", "much", "must", "myself",
        "need", "never", "no", "nothing", "now", "okay", "once", "only", "other", "ours",
        "ourselves", "over", "own", "people", "pretty", "probably", "quite", "really", "right",
        "said", "same", "saying", "says", "see", "should", "since", "some", "something", "sort",
        "still", "such", "sure", "take", "than", "thank", "thanks", "that", "that's", "their",
        "theirs", "them", "themselves", "then", "there", "there's", "these", "they", "they're",
        "thing", "things", "think", "this", "those", "though", "through", "time", "today", "together",
        "too", "under", "until", "very", "want", "wanted", "was", "wasn't", "we're", "well", "were",
        "what", "what's", "when", "where", "which", "while", "who", "whom", "why", "will", "with",
        "within", "without", "won't", "would", "yeah", "years", "you're", "your", "yours",
        "yourself", "yourselves", "able", "already", "anyway", "back", "come", "doing", "done",
        "give", "got", "guess", "keep", "kinda", "lot", "lots", "next", "point", "put", "rather",
        "seems", "start", "talk", "talking", "tell", "thought", "trying", "used", "using", "way",
        "work", "yes", "they've", "we've", "you've", "i'd", "you'd", "we'd", "let's", "can't"]
}

/// Keeps every series' analysis current on the Mac, in the community
/// folder beside the EPUBs: each meeting analysed once, again only when
/// its transcript or the analysis changes; the series file rebuilt from
/// the meetings. The headset reads what this writes.
@MainActor @Observable
final class DialogueAnalyst {
    static let shared = DialogueAnalyst()

    private(set) var isRunning = false
    private(set) var lastRun: Date?
    private var pending = false

    /// Analyses every dialogue series on the shelf — in the background,
    /// skipping meetings already analysed as they stand.
    func refresh(records: [EPUBRecord], epubsRoot: URL, community: URL?) {
        guard let community else { return }
        guard !isRunning else { pending = true; return }
        isRunning = true
        let dialogues = records.filter { $0.dialogue != nil }
        Task {
            await Task.detached(priority: .utility) {
                let scoped = community.startAccessingSecurityScopedResource()
                defer { if scoped { community.stopAccessingSecurityScopedResource() } }
                // The ones naming no series share their kind's unlabeled room.
                let bySeries = Dictionary(grouping: dialogues) { AppModel.seriesName(of: $0.dialogue!) }
                for (series, meetings) in bySeries {
                    Self.analyseSeries(series, meetings: meetings,
                                       epubsRoot: epubsRoot, community: community)
                }
            }.value
            isRunning = false
            lastRun = .now
            if pending {
                pending = false
                refresh(records: records, epubsRoot: epubsRoot, community: community)
            }
        }
    }

    nonisolated private static func analyseSeries(_ series: String, meetings: [EPUBRecord],
                                                  epubsRoot: URL, community: URL) {
        let folder = DialogueFiles.seriesURL(series, in: community)
        var analyses: [MeetingAnalysis] = []
        for record in meetings {
            guard let info = record.dialogue else { continue }
            let unpacked = epubsRoot.appendingPathComponent(record.folder, isDirectory: true)
            guard let body = try? OrigamiEPUBImporter.importDocument(inUnpackedFolder: unpacked).body
            else { continue }
            let url = folder.appendingPathComponent(record.folder + ".analysis.json")
            if let held: MeetingAnalysis = DialogueFiles.read(url),
               held.version == MeetingAnalysis.currentVersion,
               held.contentHash == MeetingAnalyser.contentHash(body) {
                analyses.append(held)
                continue
            }
            let analysis = MeetingAnalyser.analyse(body: body, info: info, meeting: record.folder,
                                                   recordID: record.id, title: record.title)
            DialogueFiles.write(analysis, to: url)
            analyses.append(analysis)
        }
        let kind = meetings.first?.dialogue?.kind ?? .transcript
        let participants = meetings.flatMap { $0.dialogue?.participants ?? [] }
        DialogueFiles.write(seriesAnalysis(series, kind: kind, meetings: analyses,
                                           participants: participants),
                            to: folder.appendingPathComponent("series.json"))
    }

    /// The series from its meetings: in date order, the people across
    /// them, their exchanges summed, the terms that recur.
    nonisolated static func seriesAnalysis(_ series: String, kind: DialogueInfo.Kind,
                                           meetings: [MeetingAnalysis],
                                           participants: [DialogueInfo.Participant]) -> SeriesAnalysis {
        let ordered = meetings.sorted {
            ($0.date ?? "", $0.number ?? 0, $0.title) < ($1.date ?? "", $1.number ?? 0, $1.title)
        }
        var people: [String: SeriesAnalysis.Person] = [:]
        var order: [String] = []
        for meeting in ordered {
            for speaker in meeting.speakers {
                if people[speaker.person] == nil {
                    order.append(speaker.person)
                    people[speaker.person] = .init(person: speaker.person, name: speaker.name,
                                                   orcid: nil, aliases: [], meetings: [],
                                                   turns: 0, words: 0, share: 0)
                }
                people[speaker.person]!.meetings.append(meeting.meeting)
                people[speaker.person]!.turns += speaker.turns
                people[speaker.person]!.words += speaker.words
            }
        }
        for participant in participants {
            let key = DialoguePeople.key(name: participant.name, orcid: participant.orcid)
            guard people[key] != nil else { continue }
            if let orcid = participant.orcid { people[key]!.orcid = orcid }
            let aliases = Set(people[key]!.aliases).union(participant.aliases ?? [])
            people[key]!.aliases = aliases.sorted()
        }
        let total = max(people.values.reduce(0) { $0 + $1.words }, 1)
        for key in order { people[key]!.share = Double(people[key]!.words) / Double(total) }

        var exchanges: [String: Int] = [:]
        for meeting in ordered {
            for exchange in meeting.exchanges {
                exchanges[exchange.from + "→" + exchange.to, default: 0] += exchange.count
            }
        }
        var terms: [String: SeriesAnalysis.Term] = [:]
        for meeting in ordered {
            for term in meeting.terms {
                var entry = terms[term.term] ?? .init(term: term.term, count: 0, meetings: [], people: [])
                entry.count += term.count
                entry.meetings.append(meeting.meeting)
                entry.people = Array(Set(entry.people).union(term.people)).sorted()
                terms[term.term] = entry
            }
        }
        // A series term is one that recurs — said in two meetings or more
        // (or, in a series of one, the meeting's own).
        let recurring = terms.values
            .filter { ordered.count < 2 || $0.meetings.count >= 2 }
            .sorted { ($0.meetings.count, $0.count, $0.term) > ($1.meetings.count, $1.count, $1.term) }
        return SeriesAnalysis(
            version: MeetingAnalysis.currentVersion, series: series, kind: kind, analysed: .now,
            meetings: ordered.map { meeting in
                .init(meeting: meeting.meeting, recordID: meeting.recordID, title: meeting.title,
                      date: meeting.date, number: meeting.number,
                      turns: meeting.speakers.reduce(0) { $0 + $1.turns },
                      words: meeting.speakers.reduce(0) { $0 + $1.words },
                      people: meeting.speakers.map(\.person))
            },
            people: order.compactMap { people[$0] }.sorted { $0.words > $1.words },
            exchanges: exchanges.map { pair, count in
                let parts = pair.components(separatedBy: "→")
                return .init(from: parts[0], to: parts[1], count: count)
            }.sorted { ($0.count, $0.from) > ($1.count, $1.from) },
            terms: Array(recurring.prefix(60)))
    }
}
