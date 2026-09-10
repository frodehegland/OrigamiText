import Foundation

/// The Hypermedia spaces the reader follows, and what has been read from
/// them this session. Spaces persist (Settings ▸ Hypermedia); listings and
/// documents are fetched on demand and kept in memory — a space is the
/// authority on its own documents, so nothing is written to disk.
@Observable
@MainActor
final class HypermediaSpaces {

    enum Listing {
        case loading
        case loaded([HypermediaDocumentInfo])
        case failed(String)
    }

    private(set) var spaces: [HypermediaSpace] = []
    /// Per domain: the space's documents, or why they could not be listed.
    private(set) var listings: [String: Listing] = [:]
    /// Documents already converted, by canonical `hm://` address, so a
    /// second visit — from the list, a link, a citation — is instant.
    var documentCache: [String: LiquidDoc] = [:]
    /// Which space each cached document was read from — the one to ask
    /// for its comments — and the version that was read, which a comment
    /// refers to.
    var documentOrigins: [String: URL] = [:]
    var documentVersions: [String: String] = [:]

    // MARK: Account

    /// The person's signing key, when they have made an account. Kept in
    /// the Keychain; only the seed is stored.
    private(set) var identity: HypermediaIdentity?
    /// The name the profile was published with.
    var accountName: String {
        UserDefaults.standard.string(forKey: AppSettings.hypermediaAccountNameKey) ?? ""
    }
    private static let keychainService = "hypermedia.identity"
    private static let keychainAccount = "signing-key"

    enum Comments {
        case loading
        case loaded([HypermediaComment])
        case failed(String)
    }
    /// Comments by canonical document address, fetched when the reader
    /// reaches them.
    private(set) var comments: [String: Comments] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: AppSettings.hypermediaSpacesKey),
           let saved = try? JSONDecoder().decode([HypermediaSpace].self, from: data) {
            spaces = saved
        }
        if let stored = HypermediaKeychain.load(service: Self.keychainService, account: Self.keychainAccount),
           let seed = Data(base64Encoded: stored) {
            identity = try? HypermediaIdentity(seed: seed)
        }
    }

    /// Makes the account: a new key, saved, and a profile carrying the
    /// name, published to every followed space (and the public gateway,
    /// so the account exists somewhere even before a space is followed).
    /// Fails only when no space at all accepted the profile — the key is
    /// kept either way, and can be published again.
    func createAccount(name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw HypermediaError.serverError("A name is needed.") }
        let fresh = HypermediaIdentity.generate()
        HypermediaKeychain.save(service: Self.keychainService, account: Self.keychainAccount,
                                password: fresh.seed.base64EncodedString())
        UserDefaults.standard.set(trimmed, forKey: AppSettings.hypermediaAccountNameKey)
        identity = fresh
        let failed = await publishProfile()
        if failed.count == profileDestinations.count {
            throw HypermediaError.serverError("The profile could not be published to any space (\(failed.joined(separator: ", "))). Your key is saved; try Publish Profile Again later.")
        }
    }

    /// Where the profile goes: every followed space, plus the gateway.
    private var profileDestinations: [URL] {
        var origins = spaces.map(\.origin)
        if !origins.contains(where: { $0.host == HypermediaFetcher.gatewayDomain }) {
            origins.append(URL(string: "https://\(HypermediaFetcher.gatewayDomain)")!)
        }
        return origins
    }

    /// Publishes the profile everywhere; returns the domains that did not
    /// take it.
    func publishProfile() async -> [String] {
        guard let identity else { return [] }
        var failed: [String] = []
        for origin in profileDestinations {
            if (try? await publishProfile(identity: identity, to: origin)) == nil {
                failed.append(origin.host ?? origin.absoluteString)
            }
        }
        return failed
    }

    private func publishProfile(identity: HypermediaIdentity, to origin: URL) async throws {
        let blob = try HypermediaBlobs.profile(name: accountName, identity: identity)
        try await HypermediaBlobs.publish([blob], to: origin)
    }

    /// Speaks on a document: a comment, or a reply to one, published to
    /// the space the document was read from. Returns the record id.
    @discardableResult
    func postComment(text: String, on canonicalID: String, replyTo parent: HypermediaComment?) async throws -> String {
        guard let identity else { throw HypermediaError.serverError("Create an account in Settings ▸ Hypermedia to comment.") }
        guard let address = HypermediaAddress.parse(canonicalID) else { throw HypermediaError.invalidAddress }
        guard let version = documentVersions[canonicalID], !version.isEmpty else {
            throw HypermediaError.serverError("The document's version is not known; open it again and retry.")
        }
        let origin = documentOrigins[canonicalID]
            ?? spaces.first { $0.uid == address.uid }?.origin
            ?? URL(string: "https://\(HypermediaFetcher.gatewayDomain)")!
        let replyTo = parent.map { ($0.version, $0.threadRootVersion ?? $0.version) }
        let timestamp = UInt64(Date.now.timeIntervalSince1970 * 1000)
        let blob = try HypermediaBlobs.comment(text: text, on: address, documentVersion: version,
                                               replyTo: replyTo, identity: identity, timestamp: timestamp)
        try await HypermediaBlobs.publish([blob], to: origin)
        return HypermediaBlobs.commentRecordID(data: blob.data, identity: identity, timestamp: timestamp)
    }

    func space(for domain: String) -> HypermediaSpace? {
        spaces.first { $0.domain == domain }
    }

    func documents(for domain: String) -> [HypermediaDocumentInfo]? {
        if case .loaded(let docs)? = listings[domain] { return docs }
        return nil
    }

    /// Follows a space by domain: asks it who it is, then remembers it.
    /// Re-adding a followed space just refreshes its title.
    @discardableResult
    func add(domain raw: String) async throws -> HypermediaSpace {
        let space = try await HypermediaFetcher.resolveSpace(domain: raw)
        if let index = spaces.firstIndex(where: { $0.domain == space.domain }) {
            spaces[index] = space
        } else {
            spaces.append(space)
        }
        persist()
        // A new space should know who the reader is before they speak
        // there. Best effort: the space is followed either way, and the
        // profile can be published again from Settings.
        if let identity {
            try? await publishProfile(identity: identity, to: space.origin)
        }
        return space
    }

    func remove(_ space: HypermediaSpace) {
        spaces.removeAll { $0.domain == space.domain }
        listings[space.domain] = nil
        persist()
    }

    /// Fetches the space's document list, replacing whatever was shown.
    func refresh(_ space: HypermediaSpace) async {
        listings[space.domain] = .loading
        do {
            let docs = try await HypermediaFetcher.listDocuments(space: space)
            listings[space.domain] = .loaded(docs)
        } catch {
            listings[space.domain] = .failed(error.localizedDescription)
        }
    }

    /// Loads a listing the first time a space is visited; later visits
    /// keep what they have until Refresh.
    func loadIfNeeded(_ space: HypermediaSpace) async {
        guard listings[space.domain] == nil else { return }
        await refresh(space)
    }

    /// Fetches a document's comments, replacing whatever was shown.
    func refreshComments(for canonicalID: String) async {
        guard let address = HypermediaAddress.parse(canonicalID) else { return }
        let origin = documentOrigins[canonicalID]
            ?? spaces.first { $0.uid == address.uid }?.origin
            ?? URL(string: "https://\(HypermediaFetcher.gatewayDomain)")!
        comments[canonicalID] = .loading
        do {
            comments[canonicalID] = .loaded(try await HypermediaFetcher.listComments(address: address, origin: origin))
        } catch {
            comments[canonicalID] = .failed(error.localizedDescription)
        }
    }

    func loadCommentsIfNeeded(for canonicalID: String) async {
        guard comments[canonicalID] == nil else { return }
        await refreshComments(for: canonicalID)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(spaces) {
            UserDefaults.standard.set(data, forKey: AppSettings.hypermediaSpacesKey)
        }
    }
}
