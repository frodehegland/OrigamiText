import Foundation

// MARK: - Errors

enum HypothesisError: LocalizedError {
    case invalidToken
    case httpError(Int)
    case decodingError

    var errorDescription: String? {
        switch self {
        case .invalidToken:    "The API token was rejected by Hypothesis."
        case .httpError(let c): "Hypothesis returned HTTP \(c)."
        case .decodingError:   "Unexpected response format from Hypothesis."
        }
    }
}

// MARK: - Client

/// Hypothesis API calls and the codec between Origami's WebAnnotation
/// and Hypothesis's JSON format. All functions are nonisolated and async
/// so they can be called from any context without capturing actor state.
nonisolated enum HypothesisClient {

    static let baseURL = "https://api.hypothes.is"

    // MARK: - Auth

    /// Validates `token` against the Hypothesis API and returns the
    /// display username. Throws `HypothesisError.invalidToken` on 401.
    static func validateToken(_ token: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)/api/profile") else {
            throw HypothesisError.decodingError
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HypothesisError.decodingError
        }
        if http.statusCode == 401 { throw HypothesisError.invalidToken }
        guard http.statusCode == 200 else { throw HypothesisError.httpError(http.statusCode) }

        // Profile response: { "userid": "acct:username@hypothes.is", ... }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userid = json["userid"] as? String
        else { throw HypothesisError.decodingError }

        // Strip "acct:" prefix and "@<authority>" suffix to get the display name.
        let display = userid
            .replacingOccurrences(of: "acct:", with: "")
            .components(separatedBy: "@").first ?? userid
        return display.isEmpty ? userid : display
    }

    // MARK: - Canonical URI

    /// The canonical URI Origami Text uses to identify an EPUB on Hypothesis.
    /// Priority: DOI (globally interoperable) → package identifier (file-stable)
    /// → nil (no community identity available for this book).
    static func canonicalURI(for record: EPUBRecord) -> String? {
        if let doi = record.doi, !doi.isEmpty {
            return "https://doi.org/" + doi
        }
        if let pkg = record.packageIdentifier, !pkg.isEmpty {
            // Use the EPUB's own package identifier as an Origami-namespaced URI.
            // This is stable across installations of the same file but is not
            // interoperable with browser Hypothesis clients.
            let encoded = pkg.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? pkg
            return "https://origamitext.app/epub/\(encoded)"
        }
        return nil
    }

    // MARK: - Push / delete (Phase 2 — stubs)

    // Full implementation in Phase 2 after the DOI interoperability spike.

    // MARK: - Fetch community annotations (Phase 3 — stub)

    // Full implementation in Phase 3.
}
