import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

// Gemtext in the app: importing a `.gmi` file, fetching a page over
// `gemini://`, and exporting any document as well-formed gemtext.
//
// An imported gemtext document is a read-only source, so it travels the
// road every other converted source travels — parsed into the document
// model, written through the Origami EPUB exporter, filed on the shelf —
// which is also what gives it the reader's annotations for nothing: the
// overlays anchor by document id and element id exactly as they do for
// any book, and the source bytes are never touched.

#if os(macOS)

// MARK: - Import, fetch, export

extension AppModel {

    /// A `.gmi` (or `.gemini`) file from the Import… panel, Finder, or a
    /// drop. Relative links resolve against the containing folder.
    @MainActor
    @discardableResult
    func importGemtext(at url: URL, andOpen: Bool = true) -> LibraryImportOutcome {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            if andOpen {
                NSSound.beep()
                showNote("Could not read “\(url.lastPathComponent)” as UTF-8 gemtext.")
            }
            return .failed
        }
        let base = url.deletingLastPathComponent()
        let fallback = url.deletingPathExtension().lastPathComponent
        return shelve(gemtext: source, base: base, fallbackTitle: fallback,
                      sourceURL: nil, author: authorName, response: nil,
                      andOpen: andOpen)
    }

    /// File ▸ Open Gemini URL… — the address, then the page.
    @MainActor
    func openGeminiURLPrompt() {
        let alert = NSAlert()
        alert.messageText = "Open Gemini URL"
        alert.informativeText = "The address of a page on a Gemini capsule, e.g. gemini://geminiprotocol.net/"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "gemini://"
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        Task { await openGeminiURL(typed) }
    }

    /// Fetches a Gemini page and reads it here: gemtext imports through the
    /// normal path, other text arrives as one preformatted document, and
    /// anything else is offered to disk. Certificates are trust-on-first-
    /// use; a changed one stops and asks.
    @MainActor
    func openGeminiURL(_ address: String) async {
        guard let url = Self.geminiURL(from: address) else {
            NSSound.beep()
            showNote("That is not a gemini:// address.")
            return
        }
        // A page already read opens from the shelf; Fetch Again is how a
        // reader asks the capsule for its words afresh.
        if let known = GemtextStore.source(forURL: url.absoluteString),
           let record = epubRecords.first(where: { $0.id == known.documentID }) {
            openStoredEPUB(record)
            return
        }
        await fetchGemini(url, trustingNewCertificateFor: nil)
    }

    /// Fetch again from the same address: the same document id, a new
    /// digest when the capsule's words have changed.
    @MainActor
    func reloadGemtext(_ doc: LiquidDoc) async {
        guard let address = gemtextSourceURL(for: doc),
              let url = Self.geminiURL(from: address) else {
            showNote("This document names no Gemini source.")
            return
        }
        await fetchGemini(url, trustingNewCertificateFor: nil)
    }

    /// Whether this document came from a capsule — what the reload action
    /// is offered on.
    @MainActor
    func gemtextSourceURL(for doc: LiquidDoc) -> String? {
        guard let address = GemtextStore.source(forDocument: doc.id)?.sourceURL,
              address.hasPrefix("gemini://") else { return nil }
        return address
    }

    @MainActor
    private func fetchGemini(_ url: URL, trustingNewCertificateFor host: String?,
                             followingCrossScheme: Bool = false) async {
        showNote("Fetching \(url.host ?? url.absoluteString)…")
        do {
            let response = try await GeminiClient.fetch(
                url, trustingNewCertificateFor: host,
                followingCrossScheme: followingCrossScheme)
            await present(response)
        } catch GeminiError.certificateChanged(let mismatch) {
            guard confirmNewCertificate(mismatch) else {
                showNote("Left \(mismatch.host) alone.")
                return
            }
            await fetchGemini(url, trustingNewCertificateFor: mismatch.host)
        } catch GeminiError.crossSchemeRedirect(let target) {
            guard confirm(message: "Leave Gemini?",
                          detail: "\(url.host ?? url.absoluteString) redirects to \(target).",
                          action: "Follow") else { return }
            await fetchGemini(url, trustingNewCertificateFor: host,
                              followingCrossScheme: true)
        } catch {
            NSSound.beep()
            showNote(error.localizedDescription)
        }
    }

    /// What to do with an answered request. Input statuses come back as
    /// responses, not errors: the page is asking a question.
    @MainActor
    private func present(_ response: GeminiResponse) async {
        if let prompt = response.inputPrompt {
            guard let answer = askGemini(prompt: prompt.prompt, secure: prompt.secure),
                  let next = GeminiClient.url(response.url, answering: answer) else { return }
            await fetchGemini(next, trustingNewCertificateFor: nil)
            return
        }
        let fallback = Self.pageName(for: response.url)
        // A capsule serving a book is a book: it joins the shelf, exactly
        // as an EPUB linked from anywhere else does.
        if response.mimeType == EPUBLink.epubMIME || EPUBLink.namesEPUB(response.url) {
            await openLinkedEPUB(response.url)
            return
        }
        guard let text = response.text else {
            saveGeminiBody(response)
            return
        }
        if response.isGemtext {
            shelve(gemtext: text, base: response.url, fallbackTitle: fallback,
                   sourceURL: response.url.absoluteString,
                   author: response.url.host ?? "Gemini", response: response)
        } else if response.mimeType.hasPrefix("text/") {
            // Other text arrives whole, in one preformatted block, marked
            // with the type the capsule declared.
            let fenced = "```\(response.mimeType)\n\(text)\n```"
            shelve(gemtext: "# \(fallback)\n\n" + fenced + "\n",
                   base: response.url, fallbackTitle: fallback,
                   sourceURL: response.url.absoluteString,
                   author: response.url.host ?? "Gemini", response: response)
        } else {
            saveGeminiBody(response)
        }
    }

    // MARK: Shelving

    /// Gemtext → blocks → EPUB → the shelf. The raw source is kept beside
    /// the document, and the registry keeps the identity stable so an
    /// annotation made on one import still resolves after the next.
    @MainActor
    @discardableResult
    private func shelve(gemtext: String, base: URL?, fallbackTitle: String,
                        sourceURL: String?, author: String,
                        response: GeminiResponse?,
                        andOpen: Bool = true) -> LibraryImportOutcome {
        let assembled = Gemtext.assemble(gemtext, base: base, fallbackTitle: fallbackTitle)
        // Identity per source, not per fetch: an address keys by address,
        // a local file by the digest of its bytes.
        let key = sourceURL.map(GemtextStore.canonical) ?? "sha256:" + assembled.sourceDigest
        let existing = sourceURL.flatMap(GemtextStore.source(forURL:))
            ?? GemtextStore.source(forDigest: assembled.sourceDigest)
        let documentID = existing?.documentID ?? GemtextStore.documentID(forKey: key)
        // A refetch keeps the document's date of record; only its digest
        // moves when the capsule's words do.
        let created = existing?.firstReadAt ?? .now

        var doc = LiquidDoc(format: LiquidDoc.knownFormat,
                            id: documentID,
                            title: assembled.title,
                            author: author,
                            created: created,
                            body: assembled.body,
                            links: [],
                            wraps: nil,
                            fileURL: FileManager.default.temporaryDirectory)
        // Text from outside the community, as the vocabulary names it.
        doc.documentType = LiquidDoc.DocumentType.external.rawValue
        // Provenance: the address, so a citation copied out of this
        // document can point back at the capsule. The MIME parameters the
        // capsule sent — charset, lang — and the certificate that served
        // it are kept in the registry beside the raw source.
        doc.sourceURL = sourceURL

        do {
            // Through the exporter and straight back in: the EPUB is the
            // document; the .gmi was the carrier.
            let epubURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(documentID + ".epub")
            try OrigamiEPUBExporter.write(doc: doc, resolve: { _ in nil }, to: epubURL)
            defer { try? FileManager.default.removeItem(at: epubURL) }
            // No title-and-author dedupe here: a capsule's pages all
            // carry the host as their author and often repeat a heading,
            // and each page's address already says which page it is.
            guard let record = importEPUB(at: epubURL, dedupe: false) else { return .failed }

            // The unmodified original is kept beside the registry entry
            // and never rewritten: an unedited export hands these very
            // bytes back (§3.5).
            GemtextStore.remember(
                GemtextSource(documentID: documentID,
                              sourceURL: sourceURL,
                              sourceDigest: assembled.sourceDigest,
                              contentDigest: assembled.contentDigest,
                              title: assembled.title,
                              readAt: .now,
                              firstReadAt: created,
                              charset: response?.charset,
                              language: response?.language,
                              tlsFingerprint: response?.fingerprint,
                              truncated: response?.truncated ?? false),
                raw: Data(gemtext.utf8))

            if andOpen {
                openStoredEPUB(record)
                var note = "Opened “\(assembled.title)” — \(assembled.body.count) blocks"
                if response?.truncated == true {
                    note += " · the connection closed early, so this page may be short"
                }
                showNote(note)
                mirrorShelfToCommunityFolder()
            }
            return .imported
        } catch {
            if andOpen {
                NSSound.beep()
                showNote("Could not read the gemtext: \(error.localizedDescription)")
            }
            return .failed
        }
    }

    // MARK: Export

    /// Export ▸ Gemtext (.gmi)… — 100% valid gemtext any Gemini client
    /// renders as it stands, with the Visual-Meta appendix as its last
    /// preformatted block. An unmodified gemtext import re-exports as the
    /// stored raw source, byte for byte.
    @MainActor
    func exportGemtext(_ doc: LiquidDoc) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "gmi") ?? .plainText]
        panel.nameFieldStringValue = (LiquidDoc.fileSlug(from: doc.title).isEmpty
            ? doc.id : LiquidDoc.fileSlug(from: doc.title)) + ".gmi"
        panel.canCreateDirectories = true
        panel.message = "Export this document as gemtext — plain text any Gemini client reads, its Visual-Meta carried in the final preformatted block."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let text = gemtextForExport(documentForGemtextExport(doc))
        do {
            // UTF-8, no BOM, LF endings, one trailing newline.
            try Data(text.utf8).write(to: url, options: .atomic)
            showNote("Exported “\(url.lastPathComponent)”")
        } catch {
            NSSound.beep()
            showNote("Gemtext export failed: \(error.localizedDescription)")
        }
    }

    /// The File-menu export, on whatever is in front: the draft being
    /// written, else the book being read, else the document showing. The
    /// item is always offered — a menu that says why nothing happened is
    /// kinder than one that dims without explanation.
    @MainActor
    func exportGemtextFront() {
        if let draftEditor {
            exportGemtext(draftEditor.buildDocument())
            return
        }
        if let book = openEPUB,
           let record = epubRecords.first(where: { $0.folder == book.id }) {
            exportGemtext(book: record)
            return
        }
        if let doc = current?.doc {
            exportGemtext(doc)
            return
        }
        NSSound.beep()
        showNote("Open a document or a book to export it as gemtext.")
    }

    /// A shelved book: the listing stub is enough, since the export reads
    /// the document back from the package itself.
    @MainActor
    func exportGemtext(book record: EPUBRecord) {
        exportGemtext(LiquidDoc(
            format: LiquidDoc.knownFormat, id: record.id, title: record.title,
            author: record.author,
            created: record.dateISO.flatMap(LiquidDoc.parseISO8601) ?? record.openedAt,
            body: [], links: [], wraps: nil,
            documentType: LiquidDoc.DocumentType.book.rawValue,
            fileURL: Self.unpackedEPUBURL(inFolder: record.folder)))
    }

    /// The document behind a row or a reading view: a listing entry for a
    /// shelved book carries no body, so the book's own document is read
    /// back from its unpacked package before it is flattened to gemtext.
    @MainActor
    func documentForGemtextExport(_ doc: LiquidDoc) -> LiquidDoc {
        if doc.body?.isEmpty == false { return doc }
        if let entry = index.byID[LiquidAddress.canonical(doc.id)],
           entry.doc.body?.isEmpty == false {
            return entry.doc
        }
        guard let record = epubRecords.first(where: { $0.id == doc.id || $0.folder == doc.id }),
              let result = try? OrigamiEPUBImporter.importDocument(
                  inUnpackedFolder: Self.unpackedEPUBURL(inFolder: record.folder))
        else { return doc }
        var book = LiquidDoc(format: LiquidDoc.knownFormat,
                             id: doc.id,
                             title: result.title.isEmpty ? doc.title : result.title,
                             author: result.author ?? doc.author,
                             created: doc.created,
                             body: result.body,
                             links: result.links,
                             wraps: nil,
                             date: doc.date,
                             documentType: doc.documentType,
                             concepts: result.concepts,
                             layouts: result.layouts,
                             mapConnections: result.mapConnections,
                             references: result.references,
                             tables: result.tables,
                             assets: result.assets,
                             fileURL: doc.fileURL)
        book.subtitle = result.subtitle
        book.publication = result.publication
        book.doi = result.doi
        book.affiliations = result.affiliations
        book.acmReference = result.acmReference
        book.license = result.license
        book.licenseURI = result.licenseURI
        return book
    }

    /// The bytes to write: the retained source for an untouched import,
    /// the generated document for anything else.
    @MainActor
    func gemtextForExport(_ doc: LiquidDoc) -> String {
        if let known = GemtextStore.source(forDocument: doc.id),
           let raw = GemtextStore.rawSource(forDocument: doc.id),
           // Untouched since import? Then the retained source is the
           // truest export there can be — byte for byte.
           known.matches(body: doc.body ?? []) {
            return raw
        }
        return Gemtext.export(doc, identity: authorIdentity)
    }

    // MARK: Prompts

    /// A 10/11 input page: the capsule's question, the reader's line.
    @MainActor
    private func askGemini(prompt: String, secure: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = "The page asks for input"
        alert.informativeText = prompt
        let field = secure
            ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            : NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let answer = field.stringValue
        return answer.isEmpty ? nil : answer
    }

    /// A changed certificate is a hard stop with both fingerprints and
    /// their dates in front of the reader — the whole point of pinning.
    @MainActor
    private func confirmNewCertificate(_ mismatch: GeminiTrust.Mismatch) -> Bool {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        func expiry(_ date: Date?) -> String {
            date.map { ", expires \(formatter.string(from: $0))" } ?? ""
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "\(mismatch.host) is serving a different certificate"
        alert.informativeText = """
        Remembered since \(formatter.string(from: mismatch.stored.firstSeen))\
        \(expiry(mismatch.stored.notAfter)):
        \(mismatch.stored.fingerprint)

        Offered now\(expiry(mismatch.offeredNotAfter)):
        \(mismatch.offered)

        This is expected when a capsule renews its certificate, and is what an \
        impersonation looks like. Nothing has been sent to this server.
        """
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Trust New Certificate")
        return alert.runModal() == .alertSecondButtonReturn
    }

    @MainActor
    private func confirm(message: String, detail: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// A body Origami Text cannot read: offered to disk rather than
    /// silently dropped.
    @MainActor
    private func saveGeminiBody(_ response: GeminiResponse) {
        let name = response.url.path.split(separator: "/").last.map(String.init)
            ?? "gemini-download"
        guard confirm(message: "Save this file?",
                      detail: "\(response.url.absoluteString) served \(response.mimeType), which the reader cannot show.",
                      action: "Save…") else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try response.body.write(to: url, options: .atomic)
            showNote("Saved “\(url.lastPathComponent)”")
        } catch {
            NSSound.beep()
            showNote("Could not save: \(error.localizedDescription)")
        }
    }

    // MARK: Addresses

    /// A page's name when its gemtext declares no title: its last path
    /// segment, or the capsule's host for a front page (`/` is a path, not
    /// a name).
    nonisolated static func pageName(for url: URL) -> String {
        let segments = url.path.split(separator: "/").map(String.init)
        guard let last = segments.last, !last.isEmpty else {
            return url.host ?? "Gemini page"
        }
        return (last as NSString).deletingPathExtension
    }

    /// What a person might type: a full address, or a bare host that means
    /// a capsule's front page.
    nonisolated static func geminiURL(from address: String) -> URL? {
        var trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "gemini://" + trimmed }
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "gemini",
              let host = url.host, !host.isEmpty else { return nil }
        // A bare host names the root.
        if url.path.isEmpty, let rooted = URL(string: trimmed + "/") { return rooted }
        return url
    }
}

#endif
