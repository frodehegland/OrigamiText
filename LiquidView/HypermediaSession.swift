import Foundation
import Security

// MARK: - Provider

/// Registered hypermedia annotation providers. Seed is the first;
/// others can be added as new cases when their APIs are known.
enum HypermediaProvider: String, CaseIterable, Identifiable {
    case seed = "Seed"
    var id: String { rawValue }
}

// MARK: - Connection states

enum SeedConnectionState: Equatable {
    case disconnected
    case connecting
    case connected(username: String, serverURL: String)
    case failed(String)
}

/// Hypothesis authentication state. Note that reading public annotations
/// does not require authentication — `signedOut` does not block fetching.
enum HypothesisAuthState: Equatable {
    case signedOut
    case connecting
    case signedIn(username: String)
    case failed(String)
}

// MARK: - Session

/// Runtime state for live hypermedia connections.
/// Persistent settings (what to share, server URL, username) live in
/// UserDefaults/Keychain; this class holds only what is in flux.
@Observable
@MainActor
final class HypermediaSession {

    static let shared = HypermediaSession()

    // MARK: Seed
    var seedState: SeedConnectionState = .disconnected
    /// The EPUB that is currently being broadcast to connected servers.
    var broadcastingAddress: String? = nil
    var broadcastingTitle: String? = nil

    // MARK: Hypothesis
    var hypothesisAuthState: HypothesisAuthState = .signedOut
    /// Whether to fetch and display public Hypothesis annotations.
    /// No account required — public annotations are readable without auth.
    var hypothesisPublicEnabled: Bool {
        get { UserDefaults.standard.object(forKey: AppSettings.hypothesisPublicEnabledKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: AppSettings.hypothesisPublicEnabledKey) }
    }
    /// Community annotations loaded for the currently open document.
    /// Volatile — fetched on document open, cleared on close. Not persisted.
    var communityAnnotations: [WebAnnotation] = []

    private init() {
        restoreSeedSession()
        restoreHypothesisSession()
    }

    // MARK: - Auto-restore

    /// Re-connects from persisted credentials so the user does not
    /// have to sign in again after a relaunch.
    private func restoreSeedSession() {
        let url  = UserDefaults.standard.string(forKey: AppSettings.seedServerURLKey) ?? ""
        let user = UserDefaults.standard.string(forKey: AppSettings.seedUsernameKey)  ?? ""
        guard !url.isEmpty, !user.isEmpty else { return }
        guard HypermediaKeychain.load(service: url, account: user) != nil else { return }
        seedState = .connected(username: user, serverURL: url)
    }

    // MARK: - Sign in / out

    func signInToSeed(serverURL: String, username: String, password: String) async {
        seedState = .connecting

        // TODO: Replace with real Seed handshake once the API docs arrive.
        // The placeholder below persists credentials and immediately succeeds
        // so the rest of the UI (sharing toggles, broadcast stubs) is testable.
        try? await Task.sleep(for: .milliseconds(400))

        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            seedState = .failed("Server URL is empty.")
            return
        }

        UserDefaults.standard.set(trimmedURL,  forKey: AppSettings.seedServerURLKey)
        UserDefaults.standard.set(username,    forKey: AppSettings.seedUsernameKey)
        HypermediaKeychain.save(service: trimmedURL, account: username, password: password)

        seedState = .connected(username: username, serverURL: trimmedURL)
    }

    func signOutFromSeed() {
        if case .connected(let user, let url) = seedState {
            HypermediaKeychain.delete(service: url, account: user)
        }
        UserDefaults.standard.removeObject(forKey: AppSettings.seedServerURLKey)
        UserDefaults.standard.removeObject(forKey: AppSettings.seedUsernameKey)
        seedState = .disconnected
        broadcastingAddress = nil
        broadcastingTitle   = nil
    }

    // MARK: - Hypothesis sign in / out

    private func restoreHypothesisSession() {
        let username = UserDefaults.standard.string(forKey: AppSettings.hypothesisUsernameKey) ?? ""
        guard !username.isEmpty,
              HypermediaKeychain.load(service: AppSettings.hypothesisService,
                                      account: username) != nil
        else { return }
        hypothesisAuthState = .signedIn(username: username)
    }

    func connectHypothesis(token: String) async {
        hypothesisAuthState = .connecting
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            hypothesisAuthState = .failed("Token is empty.")
            return
        }
        do {
            let username = try await HypothesisClient.validateToken(trimmed)
            HypermediaKeychain.save(service: AppSettings.hypothesisService,
                                    account: username, password: trimmed)
            UserDefaults.standard.set(username, forKey: AppSettings.hypothesisUsernameKey)
            hypothesisAuthState = .signedIn(username: username)
        } catch {
            hypothesisAuthState = .failed(error.localizedDescription)
        }
    }

    func disconnectHypothesis() {
        if case .signedIn(let user) = hypothesisAuthState {
            HypermediaKeychain.delete(service: AppSettings.hypothesisService, account: user)
        }
        UserDefaults.standard.removeObject(forKey: AppSettings.hypothesisUsernameKey)
        hypothesisAuthState = .signedOut
        communityAnnotations = []
    }

    // MARK: - Broadcast stubs
    // Each method is a no-op until the Seed API is wired; callers
    // (EPUBReaderView, AnnotationStore) can already invoke them safely.

    /// Call when the user opens or switches to a different EPUB.
    func documentOpened(address: String, title: String) async {
        guard case .connected = seedState else { return }
        let shareDoc = UserDefaults.standard.object(forKey: AppSettings.hypermediaShareDocKey) as? Bool ?? true
        guard shareDoc else { return }
        broadcastingAddress = address
        broadcastingTitle   = title
        // TODO: POST document presence to Seed server
    }

    /// Call when the reading position changes significantly.
    func readingPositionChanged(documentAddress: String, progression: Double, fragmentID: String?) async {
        guard case .connected = seedState else { return }
        let sharePos = UserDefaults.standard.object(forKey: AppSettings.hypermediaSharePositionKey) as? Bool ?? true
        guard sharePos else { return }
        // TODO: POST position update to Seed server
    }

    /// Call immediately after a W3C WebAnnotation is saved locally.
    /// The annotation is already properly encoded as JSON-LD — pass it
    /// straight through once the Seed POST endpoint is known.
    func annotationCreated(_ annotation: WebAnnotation) async {
        guard case .connected = seedState else { return }
        let shareAnno = UserDefaults.standard.object(forKey: AppSettings.hypermediaShareAnnotationsKey) as? Bool ?? true
        guard shareAnno else { return }
        // TODO: POST W3C annotation JSON-LD to Seed server
    }
}

// MARK: - Keychain

enum HypermediaKeychain {

    static func save(service: String, account: String, password: String) {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass      as String: kSecClassInternetPassword,
            kSecAttrServer  as String: keychainKey(service),
            kSecAttrAccount as String: account,
            kSecValueData   as String: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass         as String: kSecClassInternetPassword,
            kSecAttrServer     as String: keychainKey(service),
            kSecAttrAccount    as String: account,
            kSecReturnData     as String: true,
            kSecMatchLimit     as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass      as String: kSecClassInternetPassword,
            kSecAttrServer  as String: keychainKey(service),
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func keychainKey(_ service: String) -> String {
        "com.origamitext.hypermedia.\(service)"
    }
}
