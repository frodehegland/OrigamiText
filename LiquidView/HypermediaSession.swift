import Foundation
import Security

// MARK: - Connection states

/// Hypothesis authentication state. Note that reading public annotations
/// does not require authentication — `signedOut` does not block fetching.
enum HypothesisAuthState: Equatable {
    case signedOut
    case connecting
    case signedIn(username: String)
    case failed(String)
}

// MARK: - Session

/// Runtime state for live hypermedia connections (Hypothesis today).
/// Persistent settings (username) live in UserDefaults/Keychain; this
/// class holds only what is in flux. Hypermedia protocol spaces need no
/// session at all — see HypermediaSites.
@Observable
@MainActor
final class HypermediaSession {

    static let shared = HypermediaSession()

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
        restoreHypothesisSession()
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
