import Foundation

/// Opening Hypermedia documents in the reader: from a space's list, from a
/// pasted address, from an `hm://` link inside a document. The document
/// is converted once and read like any other; it is never written to
/// Drafts or the community folder — the space keeps the record.
extension AppModel {

    /// A document chosen from a space's listing.
    @MainActor
    func openHypermedia(_ info: HypermediaDocumentInfo, space: HypermediaSpace) async {
        if let cached = hypermedia.documentCache[info.id] {
            open(cached)
            return
        }
        showNote("Fetching from \(space.domain)…")
        do {
            let result = try await HypermediaFetcher.fetch(address: info.address, origin: space.origin)
            presentHypermedia(result, fragment: nil)
        } catch {
            showNote(error.localizedDescription)
        }
    }

    /// Anything a person might paste or click: `hm://uid/path#block`, a
    /// gateway URL, or a page on a Hypermedia space. Lands on the block
    /// the address names — the imported document's paragraph IDs are
    /// those same block IDs (see HypermediaFetcher.convert).
    @MainActor
    func openHypermediaURL(_ urlString: String) async {
        let address = HypermediaAddress.parse(urlString)
        if let address, let cached = hypermedia.documentCache[address.canonicalID] {
            open(cached, fragment: address.blockRef)
            return
        }
        let where_ = address?.origin?.host ?? hypermedia.spaces.first?.domain ?? HypermediaFetcher.gatewayDomain
        showNote("Fetching from \(where_)…")
        do {
            let result = try await HypermediaFetcher.fetch(urlString: urlString, spaces: hypermedia.spaces)
            let fragment = address?.blockRef
                ?? HypermediaAddress.blockID(fromFragment: URL(string: urlString)?.fragment)
            presentHypermedia(result, fragment: fragment)
        } catch {
            showNote(error.localizedDescription)
        }
    }

    /// Turns a fetched document into a LiquidDoc, remembers it, and opens it.
    @MainActor
    func presentHypermedia(_ result: HypermediaFetcher.FetchResult, fragment: String?) {
        if let cached = hypermedia.documentCache[result.canonicalID] {
            open(cached, fragment: fragment)
            return
        }
        let id = LiquidAddress.makeID(author: result.author, created: result.created) { candidate in
            self.index.byID[candidate] != nil
                || self.drafts.documents.contains { $0.id == candidate }
                || self.hypermedia.documentCache.values.contains { $0.id == candidate }
        }
        let doc = LiquidDoc(
            format: LiquidDoc.knownFormat,
            id: id,
            title: result.title,
            author: result.author,
            created: result.created,
            body: result.body,
            links: [],
            wraps: nil,
            // Provenance: the document remembers its network address, so a
            // citation copied out of it can point back at the space, at
            // the paragraph.
            sourceURL: result.canonicalID,
            // Never written: the space is the record. The path only names
            // where a copy would go.
            fileURL: FileManager.default.temporaryDirectory
                .appending(path: "Hypermedia", directoryHint: .isDirectory)
                .appending(path: "\(id).origamitext"))
        hypermedia.cacheDocument(doc, id: result.canonicalID,
                                 origin: result.origin, version: result.version)
        open(doc, fragment: fragment)
    }

    /// The first slice of annotation sharing: the document's own
    /// annotation, posted as this account's comment on the document's
    /// space — one annotation per document, standing in the thread any
    /// Seed reader sees. Only documents that CAME from a space carry
    /// the address (`sourceURL`); mapping library EPUBs to their Seed
    /// renditions is the next slice.
    @MainActor
    func shareDocumentAnnotationToSeed(for doc: LiquidDoc) async {
        guard let source = doc.sourceURL,
              let address = HypermediaAddress.parse(source) else {
            showNote("This document names no Seed source.")
            return
        }
        let canonical = address.canonicalID
        let text = documentAnnotation(forAddress: doc.id)?.body?.value ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showNote("Write the document's annotation first.")
            return
        }
        showNote("Sharing annotation…")
        do {
            // The space wants the document's version alongside the
            // comment; a fresh session may not hold it — fetch quietly
            // to learn it before speaking.
            if hypermedia.documentVersions[canonical]?.isEmpty != false {
                let result = try await HypermediaFetcher.fetch(
                    urlString: canonical, spaces: hypermedia.spaces)
                hypermedia.cacheDocument(doc, id: result.canonicalID,
                                         origin: result.origin,
                                         version: result.version)
            }
            try await hypermedia.postComment(text: text, on: canonical, replyTo: nil)
            showNote("Annotation shared to the document's space")
        } catch {
            showNote(error.localizedDescription)
        }
    }
}
