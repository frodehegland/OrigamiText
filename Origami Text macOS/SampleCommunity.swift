import Foundation
import AppKit

/// Test scaffolding: writes a small, clearly fictional community into the
/// community folder, so multi-author behavior — attention bolding,
/// discourse links, revision chains, transcripts, lifting on someone's
/// behalf, AI provenance — can be exercised from a single machine.
/// Every file name begins with "sample--", so removal is exact.
@MainActor
extension AppModel {

    private static let samplePrefix = "sample--"

    func createSampleCommunity() {
        guard let folder = index.folderURL else {
            NSSound.beep()
            showNote("Choose a community folder first — the sample is written into it")
            return
        }
        let me = authorName
        let day: TimeInterval = 86_400
        let now = Date.now

        // Ids derive from author + creation time; build them first so the
        // documents can cite each other.
        func makeID(_ author: String, _ created: Date) -> String {
            LiquidAddress.makeID(author: author, created: created) { candidate in
                self.index.byID[candidate] != nil
            }
        }
        func paragraphs(_ texts: [String]) -> [LiquidDoc.Paragraph] {
            texts.enumerated().map { index, text in
                LiquidDoc.Paragraph(id: "p\(index + 1)", heading: nil, text: text)
            }
        }

        let aliceLetterDate = now.addingTimeInterval(-21 * day)
        let aliceLetterID = makeID("Alice Winter", aliceLetterDate)
        let benReplyDate = now.addingTimeInterval(-18 * day)
        let benReplyID = makeID("Ben Okafor", benReplyDate)
        let chiyoDisagreeDate = now.addingTimeInterval(-16 * day)
        let chiyoDisagreeID = makeID("Chiyo Tanaka", chiyoDisagreeDate)
        let aliceV2Date = now.addingTimeInterval(-12 * day)
        let aliceV2ID = makeID("Alice Winter", aliceV2Date)
        let davidExtendDate = now.addingTimeInterval(-10 * day)
        let davidExtendID = makeID("David Lem", davidExtendDate)
        let transcriptDate = now.addingTimeInterval(-8 * day)
        let transcriptID = makeID(me, transcriptDate)
        let extractDate = now.addingTimeInterval(-7 * day)
        let extractID = makeID(me, extractDate)
        let rfcDate = now.addingTimeInterval(-5 * day)
        let rfcID = makeID("Esther Marchetti", rfcDate)
        let benNotesDate = now.addingTimeInterval(-2 * day)
        let benNotesID = makeID("Ben Okafor", benNotesDate)

        let chiyoStatement = "I want to push back on Alice here: the letter is the wrong unit of memory. What we keep returning to is never the document, it is the connection between two of them."

        var docs: [LiquidDoc] = []

        docs.append(LiquidDoc(
            format: LiquidDoc.knownFormat, id: aliceLetterID,
            title: "On Letters as Working Memory",
            author: "Alice Winter", created: aliceLetterDate,
            body: paragraphs([
                "A letter is a thought that survived its author's attention span. When I write to this community I am not broadcasting — I am parking working memory somewhere it can be retrieved by someone else.",
                "The library we share is therefore not an archive. It is a distributed short-term memory with very long persistence.",
                "If that is true, the important operations are not filing and finding but re-encountering and responding.",
                "I would like to know what the rest of you think the unit of memory actually is.",
            ]),
            links: [], wraps: nil, documentType: "letter",
            fileURL: folder))

        docs.append(LiquidDoc(
            format: LiquidDoc.knownFormat, id: benReplyID,
            title: "Responding to Alice: Letters Need Addresses",
            author: "Ben Okafor", created: benReplyDate,
            body: paragraphs([
                "Alice says a letter is parked working memory. I agree, but memory you cannot address is memory you have lost.",
                "The address is the retrieval cue. A letter without one is a bottle in the sea.",
                "So the unit of memory is not the letter — it is the letter plus every address that points at it.",
            ]),
            links: [LiquidDoc.Link(to: aliceLetterID, fragment: nil, rel: "responds-to")],
            wraps: nil, attention: [me], documentType: "letter",
            fileURL: folder))

        docs.append(LiquidDoc(
            format: LiquidDoc.knownFormat, id: chiyoDisagreeID,
            title: "Disagreeing: Memory Lives in the Web, Not the Letter",
            author: "Chiyo Tanaka", created: chiyoDisagreeDate,
            body: paragraphs([
                "I disagree with the framing in Alice's second paragraph. A distributed memory with no forgetting is not a memory at all; it is a landfill.",
                "What makes the library a memory is the citation web — the paths we wear into it by responding, extending, and disputing.",
                "The letter is the substrate. The web is the memory.",
            ]),
            links: [LiquidDoc.Link(to: aliceLetterID, fragment: "p2", rel: "disagrees-with")],
            wraps: nil, documentType: "letter",
            fileURL: folder))

        docs.append(LiquidDoc(
            format: LiquidDoc.knownFormat, id: aliceV2ID,
            title: "On Letters as Working Memory (revised)",
            author: "Alice Winter", created: aliceV2Date,
            body: paragraphs([
                "A letter is a thought that survived its author's attention span. When I write to this community I am parking working memory where someone else can retrieve it.",
                "Chiyo is right that persistence alone is not memory: the library remembers through its connections, not its contents. I have revised my claim — the library is a distributed memory whose recall is the citation web.",
                "The important operations remain re-encountering and responding; I now think the web does the first and letters do the second.",
            ]),
            links: [LiquidDoc.Link(to: aliceLetterID, fragment: nil, rel: "revises")],
            wraps: nil, documentType: "letter",
            fileURL: folder))

        docs.append(LiquidDoc(
            format: LiquidDoc.knownFormat, id: davidExtendID,
            title: "Extending Ben: Addresses as Promises",
            author: "David Lem", created: davidExtendDate,
            body: paragraphs([
                "Ben calls the address a retrieval cue. I want to extend that: an address is a promise that the community will keep resolving it.",
                "That promise is social, not technical — which is why a shared folder with visible files honors it better than any database.",
            ]),
            links: [LiquidDoc.Link(to: benReplyID, fragment: nil, rel: "extends")],
            wraps: nil, documentType: "letter",
            fileURL: folder))

        let statements: [(String, String)] = [
            ("Alice Winter", "Shall we start? I wanted to talk about what we mean when we say the library remembers."),
            ("Ben Okafor", "My position is unchanged: no address, no memory. Everything else is poetry."),
            ("Chiyo Tanaka", "And my position is that the poetry is the point, Ben. The web of responses is what any of us actually recall."),
            (me, "Could both be true at different scales? Addresses for retrieval, the web for recall."),
            ("Chiyo Tanaka", chiyoStatement),
            ("Alice Winter", "That is a better statement of my revision than my revision."),
            ("Ben Okafor", "Fine — but someone lift what Chiyo just said into a letter, or in a month it will exist only in this transcript."),
            (me, "Lifting it now. That is rather the point of the tool."),
        ]
        docs.append(LiquidDoc(
            format: LiquidDoc.knownFormat, id: transcriptID,
            title: "Sample Community Call",
            author: me, created: transcriptDate,
            body: statements.enumerated().map { index, statement in
                LiquidDoc.Paragraph(id: "p\(index + 1)", heading: nil,
                                    text: "\(statement.0): \(statement.1)",
                                    speaker: statement.0)
            },
            links: [], wraps: nil,
            date: LiquidDate(isoString: ISO8601DateFormatter().string(from: transcriptDate).prefix(10).description),
            documentType: "transcript",
            fileURL: folder))

        docs.append(LiquidDoc(
            format: LiquidDoc.knownFormat, id: extractID,
            title: "Chiyo Tanaka — Sample Community Call",
            author: me, created: extractDate,
            body: paragraphs([
                chiyoStatement,
                "Spoken by Chiyo Tanaka in “Sample Community Call” [\(transcriptID)#p5]",
            ]),
            links: [LiquidDoc.Link(to: transcriptID, fragment: "p5", rel: "cites",
                                   span: chiyoStatement)],
            wraps: nil, attention: ["Chiyo Tanaka"],
            onBehalfOf: "Chiyo Tanaka", documentType: "extract",
            fileURL: folder))

        docs.append(LiquidDoc(
            format: LiquidDoc.knownFormat, id: rfcID,
            title: "RFC: A Shared Glossary for This Community",
            author: "Esther Marchetti", created: rfcDate,
            body: paragraphs([
                "Proposal: we maintain one glossary letter, superseded as terms settle, so that words like memory, web, and address stop meaning five things.",
                "Request for comment: does a glossary freeze language that should stay liquid? I genuinely do not know, and I would like responses either way.",
            ]),
            links: [LiquidDoc.Link(to: chiyoDisagreeID, fragment: nil, rel: "questions")],
            wraps: nil, attention: [me, "Alice Winter"], documentType: "rfc",
            fileURL: folder))

        docs.append(LiquidDoc(
            format: LiquidDoc.knownFormat, id: benNotesID,
            title: "Notes on the Week's Thread",
            author: "Ben Okafor", created: benNotesDate,
            body: paragraphs([
                "A summary of where the memory discussion stands, produced with machine help and checked by me: Alice revised her claim after Chiyo's dispute [\(chiyoDisagreeID)], David reframed addresses as social promises [\(davidExtendID)], and the transcript holds the best single statement of the synthesis.",
                "Open: Esther's glossary RFC awaits responses.",
            ]),
            links: [
                LiquidDoc.Link(to: chiyoDisagreeID, fragment: nil, rel: "cites"),
                LiquidDoc.Link(to: davidExtendID, fragment: nil, rel: "cites"),
            ],
            wraps: nil, aiOnBehalf: true, documentType: "letter",
            fileURL: folder))

        var written = 0
        do {
            for doc in docs {
                let url = folder.appendingPathComponent(Self.samplePrefix + doc.suggestedExportFileName)
                try doc.jsonData().write(to: url, options: .atomic)
                written += 1
            }
            index.rescan()
            showNote("Wrote \(written) sample documents by 5 fictional authors — Remove Sample Community deletes exactly these")
        } catch {
            NSSound.beep()
            showNote("Sample community failed after \(written) documents: \(error.localizedDescription)")
        }
    }

    /// Deletes exactly the files the generator wrote: those whose name
    /// begins with the sample prefix. Nothing else is touched.
    func removeSampleCommunity() {
        guard let folder = index.folderURL else { return }
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(Self.samplePrefix) }
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
        index.rescan()
        showNote(files.isEmpty ? "No sample documents to remove"
                               : "Removed \(files.count) sample documents")
    }
}
