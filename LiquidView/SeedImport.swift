import Foundation

/// Converts a fetched Seed document into a draft and opens it in the reader.
extension AppModel {
    @MainActor
    func importSeedDocument(_ result: SeedFetcher.FetchResult) throws {
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
            fileURL: drafts.fileURL(for: id))
        try drafts.save(doc)
        sidebarSelection = .drafts
        open(doc)
    }
}
