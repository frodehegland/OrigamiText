import Foundation

/// Converts a fetched Seed document into a draft and opens it in the reader.
extension AppModel {
    @MainActor
    func importSeedDocument(_ result: SeedFetcher.FetchResult,
                            fragment: String? = nil) throws {
        // The same origin already imported opens in place rather than
        // duplicating — provenance makes the identity.
        if let existing = drafts.documents.first(where: {
            $0.sourceURL == result.sourceURL && !result.sourceURL.isEmpty
        }) {
            sidebarSelection = .drafts
            open(existing, fragment: fragment)
            return
        }
        let created = result.created
        let id = LiquidAddress.makeID(author: result.author, created: created) { candidate in
            self.index.byID[candidate] != nil
                || self.drafts.documents.contains { $0.id == candidate }
        }
        let doc = LiquidDoc(
            format:  LiquidDoc.knownFormat,
            id:      id,
            title:   result.title,
            author:  result.author,
            created: created,
            body:    result.body,
            links:   [],
            wraps:   nil,
            // Provenance: the document remembers its Seed origin, so a
            // citation copied out of it can point back at the network —
            // paragraph IDs are the Seed block IDs (see SeedFetcher).
            sourceURL: result.sourceURL,
            fileURL: drafts.fileURL(for: id))
        try drafts.save(doc)
        sidebarSelection = .drafts
        open(doc, fragment: fragment)
    }

    /// Fetch-and-open by URL, landing on the fragment's paragraph when
    /// the address carries one (a Seed block ID — the imported document's
    /// paragraph IDs are those same block IDs). Shared by Settings ▸
    /// Hypermedia and the citation card's Seed rendition button.
    @MainActor
    func openSeedURL(_ urlString: String) async {
        let parts = urlString.components(separatedBy: "#")
        let base = parts[0]
        let fragment = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        do {
            let result = try await SeedFetcher.fetch(urlString: base)
            try importSeedDocument(result, fragment: fragment)
        } catch {
            showNote(error.localizedDescription)
        }
    }
}
