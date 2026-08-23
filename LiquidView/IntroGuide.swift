import Foundation

/// The built-in introduction: the user guide to Origami Text, written as
/// an Origami-profile EPUB and shipped through the app's own exporter —
/// the guide IS the demonstration. It lives in the library like any book,
/// takes annotations like any book, and the sidebar's Intro button always
/// finds it. `AppModel.openIntroGuide()` (AppModel.swift) regenerates the
/// unpacked copy when `introGuideVersion` moves past the stored one.
extension AppModel {

    /// Bump whenever the guide's text changes: the next Intro click
    /// replaces the unpacked copy with the new edition. The document id
    /// stays `introGuideID`, so the reader's annotations survive editions.
    nonisolated static let introGuideVersion = 4
    nonisolated static let introGuideID = "origami-text-intro"

    nonisolated static func introGuideDoc() -> LiquidDoc {
        var counter = 0
        func p(_ text: String, heading: Int? = nil) -> LiquidDoc.Paragraph {
            counter += 1
            return LiquidDoc.Paragraph(id: "p\(counter)", heading: heading, text: text)
        }

        let body: [LiquidDoc.Paragraph] = [

            // MARK: Welcome

            p("Welcome", heading: 1),
            p("Origami Text is a reader for EPUB books and academic papers, made by the Future Text Lab. It is open source under the MIT license, and it is built on one conviction: the book belongs to its author, and the reading belongs to you. Everything you do here — highlights, notes, judgments, AI readings — lives beside the books, in open formats, never inside them."),
            p("This guide is itself a book in your library, exported by Origami Text through its own EPUB writer. Read it in any of the reading styles, annotate it, fold it to its headings — everything described here works on the page you are looking at. The Intro button in the sidebar always brings it back."),

            // MARK: The library

            p("Your Library", heading: 1),
            p("Bringing books in", heading: 2),
            p("Open an EPUB with Cmd-O or drag one into the window; it is unpacked into the app's own shelf and remembered. A zip of LaTeX sources — an ACM proceedings download, say — imports directly: the paper's title, authors, venue, citations, and even its live tables are captured on the way in. Unread books show their titles in bold until you open them."),
            p("The shelves", heading: 2),
            p("The Library section of the sidebar offers the same books several ways. Pinned holds the books you have pinned — right-click any book and choose Pin, and it floats first in every list, wearing a small pin beside its title. Time is the home list, every book newest first. Alpha is the same books by title; both can narrow to unread from their sidebar context menus. Below the standing shelves come your own folders — file a book from its context menu — and Set Aside, where books rest out of the way without leaving the library. Move to Trash, available wherever a book is listed, sends the unpacked copy to the macOS Trash, recoverable as anything else there."),
            p("Journals", heading: 2),
            p("Papers that declare the journal or proceedings they belong to gather under Journals — or Proceedings; the label is yours to choose in Settings, Layout. Two venue names that are really one — the same conference cited two slightly different ways — are merged by right-clicking one and choosing Is the Same As; Separate undoes it. Click a venue for its papers, exactly as clicking an author under Views lists theirs."),

            // MARK: Reading

            p("Reading", heading: 1),
            p("The reading styles", heading: 2),
            p("The words at the foot of every reading are the styles. Default shows the book's own pages exactly as published. Scroll is the document as written, one flow, in your type. Horizontal sets pages side by side, two or more as the window allows; Focus gives one section alone, arrow keys moving through; Outline folds the sections under their headings; Transcript groups a conversation by who is speaking. Beside Scroll, the Outline group's shapes fold the flow to its headings at a click."),
            p("The page", heading: 2),
            p("A reading opens on its cover when the book carries one, then the title, the authors and date, and a quiet line of what the document holds — its sections, references, and concepts. The Aa menu at the foot sets the type: size, spacing, measure. The contents button lists every section, one click away."),
            p("Citations and references", heading: 2),
            p("A citation in the text opens its card: the cited work, its abstract when one can be found, and the way to it. The full reference list closes the reading, numbered as the body counts them. Terms the author declared as concepts open their definitions in place, and stretchtext — folded detail the author tucked behind a mark — unfolds where it stands."),

            // MARK: Annotations

            p("Annotations", heading: 1),
            p("Highlights and judgments", heading: 2),
            p("Select words and right-click for the Highlight menu: Important, Quotable, Great, Disagree, Language Issue, Problematic, What is this?, Highlight, and Strikethrough. Each has a bare key — I, Q, G, D, L, P, slash, H, X — so a judgment is one keystroke. The annotated words themselves take the kind's colour; nothing is boxed or framed. With nothing selected, the sentence under the pointer is what is annotated — never the whole paragraph. Triple-click selects a sentence, or a paragraph; which one is a toggle in Settings, Reading."),
            p("Notes on the page", heading: 2),
            p("Note, from the right-click menu, writes a free-standing slip — a small paper note touching no text, showing its first sentence. Drag it where you like; its place is anchored to the nearest paragraph and travels with the annotation itself, so it stands correctly at any window size and on any Mac. Click a slip to read, edit, copy, or delete it."),
            p("The document annotation", heading: 2),
            p("Under the title of every reading stands a pill: Annotate, outlined, while the document as a whole carries no note of yours; Annotation, filled, once it does. This is your one-line judgment of the whole work, and it is what the book lists print beneath the author's name — your own words, not the publisher's."),
            p("The Annotations view", heading: 2),
            p("Views, Annotations gathers every annotation across every book, grouped by book, each book's annotations in reading order. Find, at the foot, searches the quoted words, your notes, and the books' titles across the whole library at once. Click an annotation and its book opens at the very words. An annotation whose words have been edited out from under it is marked unanchored — kept and shown, never lost. Right-click a book's name there to export its annotations as a standard file."),
            p("Making them yours", heading: 2),
            p("Settings, Annotations renames any kind and recolours it — your Important need not be anyone else's. The names and colours are how this reader shows them; the stored annotation always carries the canonical kind, so an exported set means the same thing everywhere."),

            // MARK: AI

            p("AI, On Your Mac", heading: 1),
            p("The AI group stands at the left of the foot bar. Click it and the on-device model reads the open book three ways: Summary, an abstract with the key concepts; Proposals, what the document argues for; Issues, where it strains — each taking the full page, streaming as it is written, and stored with the book so it is read once, not every time. Regenerate re-reads; Remove forgets. A concept named in a summary is a click: the reading returns folded to the find, headings plus the full sentences carrying the words. The three prompts are yours to edit in Settings, AI."),
            p("All of it runs on this Mac, through Apple's on-device language model. Nothing you read and nothing you write leaves the machine."),

            // MARK: Approaches and technologies

            p("Approaches and Technologies", heading: 1),
            p("The Origami EPUB profile and Visual-Meta", heading: 2),
            p("An Origami document is a standard EPUB 3 — any reader anywhere can open it — carrying one extra file: visual-meta.json, the document's intellectual structure made explicit. Title, authors, date, and venue; every heading with a stable address; the defined concepts with their definitions; the full citation graph; spatial concept maps with saved views; live tables with their formulas. The idea descends from Visual-Meta (visual-meta.info): metadata should travel with the document itself, readable by people and machines alike, not sit in a database that will not outlive the app."),
            p("Annotations as W3C Web Annotations", heading: 2),
            p("Every highlight, judgment, note, and slip is a W3C Web Annotation — the same open model Hypothesis built the web's annotation layer on — stored as JSON-LD in a sidecar file beside the unpacked book, one per book, in the app's Annotations folder. The book is never modified. Each annotation anchors by a ladder of standard selectors: a FragmentSelector naming the paragraph's stable id, a TextQuoteSelector carrying the exact words with their surrounding context, a TextPositionSelector, and a ProgressionSelector recording how far through the document the words stand."),
            p("Re-anchoring, the Hypothesis way", heading: 2),
            p("Documents change; anchors must survive. When an annotation's words are sought, the selectors are tried most-specific first: the stable id with the exact words, then a fuzzy search inside that paragraph, then the exact words anywhere scored by their context, then a fuzzy search everywhere, ordered outward from where the position and progression selectors expect the words to be. The fuzzy match is an edit-distance search with a budget proportional to the quote, and it highlights the document's own current words, not the stale quote. An annotation that fails every rung becomes an orphan: kept, listed, and marked unanchored rather than silently dropped. A page slip's position travels inside its annotation as a placement extension — nearest paragraph plus offset — so the layer is portable, not just the text."),
            p("The whole-document annotation is the same model with the W3C's describing motivation and no selectors at all: its target is the document itself. And a book's annotations export as a self-contained W3C AnnotationCollection, the interchange shape the Readium community is standardising for EPUB annotations."),
            p("The reader itself", heading: 2),
            p("Origami Text is native SwiftUI, macOS 26. The Default style renders the EPUB's own HTML in a WebView, where highlights are painted with the CSS Custom Highlight API — colour laid over the page without touching the author's markup. The native styles set the same document in Swift text, which is what makes the folding, the find-fold, sentence-level annotation, and the type controls possible. The AI readings run on Apple's FoundationModels framework, entirely on device. Imports understand EPUB 3, LaTeX with BibTeX, and Visual-Meta; citation abstracts are enriched from open scholarly indexes when the network allows, and cached."),
            p("License", heading: 2),
            p("Origami Text is MIT-licensed, from the Future Text Lab. The formats it writes — the Origami EPUB profile, the Visual-Meta appendix, the Web Annotation sidecars — are documented and open, on the grounds that a reader you cannot leave is a trap, not a tool."),

            // MARK: Colophon

            p("About This Guide", heading: 1),
            p("This guide was written as an Origami document and exported by the copy of Origami Text you are running, through the same EPUB writer any document here goes through. When the guide is revised, the Intro button quietly replaces it with the new edition — and because your annotations live beside the book, not inside it, whatever you marked here survives."),
        ]

        var doc = LiquidDoc(
            format: LiquidDoc.knownFormat,
            id: introGuideID,
            title: "Introducing Origami Text",
            author: "Future Text Lab",
            created: LiquidDoc.parseISO8601("2026-08-23T09:00:00Z") ?? .now,
            body: body,
            links: [],
            wraps: nil,
            fileURL: FileManager.default.temporaryDirectory)
        doc.date = LiquidDate(isoString: "2026-08-23")
        doc.documentType = LiquidDoc.DocumentType.book.rawValue
        doc.concepts = [
            LiquidDoc.Concept(
                id: "intro-visual-meta", name: "Visual-Meta",
                description: "The approach of carrying a document's metadata and intellectual structure with the document itself, readable by people and machines alike. See visual-meta.info.",
                urls: ["https://visual-meta.info"]),
            LiquidDoc.Concept(
                id: "intro-web-annotation", name: "Web Annotation",
                description: "The W3C's open data model for annotations: each one a small JSON-LD record naming what it targets through standard selectors, portable between systems.",
                urls: ["https://www.w3.org/TR/annotation-model/"]),
            LiquidDoc.Concept(
                id: "intro-sidecar", name: "Sidecar",
                description: "A file standing beside a document, carrying a reader's layer — here, each book's annotations — so the document itself is never modified."),
            LiquidDoc.Concept(
                id: "intro-orphan", name: "Orphan",
                description: "An annotation whose words can no longer be found in its document, even fuzzily. Kept and marked unanchored, never silently dropped."),
        ]
        return doc
    }
}
