import Foundation
#if os(macOS)
import AppKit
#endif

// A book behind a link.
//
// Wherever an address in Origami Text names an EPUB — in a book being
// read, in a letter, on a capsule page, in a citation's renditions — the
// click belongs here, not in a browser: the file is fetched and joins the
// shelf, read in the app that can actually read it. A DOI is the same
// wish one step removed, so it is resolved first (Crossref's own link
// records, then the landing page the DOI redirects to) and the EPUB it
// names is fetched the same way.
//
// Nothing here decides *where* a link was clicked: `AppModel.claimLink`
// is the one door every surface knocks on, so the reader, the letters,
// the citation cards and the capsule pages all behave alike.

// MARK: - Recognising the links

nonisolated enum EPUBLink {

    /// Whether an address names an EPUB file. The path decides, so a
    /// query string ("?download=1") or a fragment never hides the name.
    static func namesEPUB(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "epub"
    }

    /// The bare DOI an address resolves — `https://doi.org/10.1145/…`,
    /// `dx.doi.org`, or a `doi:` URI — else nil. Normalised through the
    /// app's one DOI normaliser (LineageGraph).
    static func doi(in url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        let scheme = url.scheme?.lowercased() ?? ""
        let candidate: String?
        if scheme == "doi" {
            candidate = url.absoluteString
        } else if host == "doi.org" || host == "dx.doi.org" || host == "www.doi.org" {
            candidate = String(url.path.dropFirst())   // the leading "/"
        } else {
            candidate = nil
        }
        guard let candidate, !candidate.isEmpty,
              let doi = LineageGraph.normalizedDOI(candidate),
              // A DOI always begins with its registrant prefix.
              doi.hasPrefix("10.") else { return nil }
        return doi
    }

    /// The canonical `https://doi.org/…` page for a bare DOI — where a
    /// reader is sent when no EPUB edition can be found.
    static func doiPage(_ doi: String) -> URL? {
        URL(string: "https://doi.org/" + doi)
    }

    // MARK: Finding an EPUB behind a DOI

    /// The EPUB a DOI leads to, or nil when the work has no EPUB edition
    /// anyone advertises. Two doors, cheapest first:
    ///
    /// 1. **Crossref**, which many publishers populate with full-text
    ///    `link` records naming a content type — an
    ///    `application/epub+zip` entry is a direct answer.
    /// 2. **The landing page** the DOI redirects to, read for the ways a
    ///    page advertises an edition: a `citation_epub_url` meta tag, a
    ///    `<link rel="alternate">` of the EPUB type, or a plain link to
    ///    an `.epub`.
    ///
    /// Most publishers offer only PDF, so nil is the common answer and
    /// not a failure — the caller opens the page instead.
    static func epubURL(forDOI doi: String) async -> URL? {
        if let fromCrossref = await crossrefEPUB(doi: doi) { return fromCrossref }
        return await landingPageEPUB(doi: doi)
    }

    /// Crossref's `link` array: `{URL, content-type, intended-application}`.
    /// An explicit EPUB content type wins; failing that, a link whose URL
    /// simply ends in `.epub`.
    private static func crossrefEPUB(doi: String) async -> URL? {
        guard let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let endpoint = URL(string: "https://api.crossref.org/works/\(encoded)"),
              let message = (await json(from: endpoint))?["message"] as? [String: Any],
              let links = message["link"] as? [[String: Any]] else { return nil }
        func address(_ link: [String: Any]) -> URL? {
            guard let raw = link["URL"] as? String else { return nil }
            return URL(string: raw)
        }
        for link in links {
            let type: String = (link["content-type"] as? String)?.lowercased() ?? ""
            if type == epubMIME, let url = address(link) { return url }
        }
        // No declared type: a URL that simply ends in .epub still says so.
        for link in links {
            if let url = address(link), namesEPUB(url) { return url }
        }
        return nil
    }

    /// The DOI's landing page, read for an advertised EPUB. Relative
    /// addresses resolve against the page the redirects actually landed
    /// on, not the doi.org address we asked for.
    private static func landingPageEPUB(doi: String) async -> URL? {
        guard let page = doiPage(doi) else { return nil }
        var request = URLRequest(url: page, timeoutInterval: 20)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              // A publisher's page can be large; the head carries the
              // metadata, and a cap keeps a hostile page from filling
              // memory.
              let html = String(data: data.prefix(2_000_000), encoding: .utf8)
                  ?? String(data: data.prefix(2_000_000), encoding: .isoLatin1)
        else { return nil }
        let base = response.url ?? page
        for candidate in advertisedEPUBs(inHTML: html) {
            if let resolved = URL(string: candidate, relativeTo: base)?.absoluteURL {
                return resolved
            }
        }
        return nil
    }

    /// The ways a page advertises an EPUB edition, in order of how much
    /// the page means it.
    static func advertisedEPUBs(inHTML html: String) -> [String] {
        var found: [String] = []
        func append(_ value: String) {
            // An href in HTML is entity-encoded: a download URL's
            // `&amp;` between query items is an ampersand, and asking a
            // server for the literal five characters gets the wrong file
            // (or none).
            let trimmed = entityDecoded(value)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !found.contains(trimmed) else { return }
            found.append(trimmed)
        }
        // <meta name="citation_epub_url" content="…"> — the scholarly
        // metadata convention, either attribute order.
        let patterns: [String] = [
            #"<meta[^>]+name=["']citation_epub_url["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]+name=["']citation_epub_url["']"#,
            // <link rel="alternate" type="application/epub+zip" href="…">
            #"<link[^>]+type=["']application/epub\+zip["'][^>]+href=["']([^"']+)["']"#,
            #"<link[^>]+href=["']([^"']+)["'][^>]+type=["']application/epub\+zip["']"#,
            // <a href="…" type="application/epub+zip">
            #"<a[^>]+href=["']([^"']+)["'][^>]+type=["']application/epub\+zip["']"#,
            // A plain link to a .epub, query string and all.
            #"href=["']([^"']+\.epub(?:\?[^"']*)?)["']"#,
        ]
        for pattern in patterns {
            for match in captures(pattern, in: html) { append(match) }
        }
        return found
    }

    /// The handful of named entities an href actually carries.
    private static let namedEntities: [String: String] = [
        "&amp;": "&",
        "&lt;": "<",
        "&gt;": ">",
        "&quot;": "\"",
        "&apos;": "'",
        "&nbsp;": " ",
    ]

    /// Those entities, plus numeric character references. A full HTML
    /// entity table is not the job here.
    static func entityDecoded(_ value: String) -> String {
        var out: String = value
        for (entity, character) in namedEntities {
            out = out.replacingOccurrences(of: entity, with: character,
                                           options: [.caseInsensitive])
        }
        guard out.contains("&#") else { return out }
        // &#38; and &#x26; — decimal and hexadecimal.
        var result: String = ""
        var rest: Substring = out[...]
        while let start: Range<String.Index> = rest.range(of: "&#") {
            result.append(contentsOf: rest[..<start.lowerBound])
            let afterHash: Substring = rest[start.upperBound...]
            guard let semicolon: String.Index = afterHash.firstIndex(of: ";") else {
                result.append(contentsOf: rest[start.lowerBound...])
                return result
            }
            let digits: Substring = afterHash[..<semicolon]
            let isHex: Bool = digits.first == "x" || digits.first == "X"
            let number: Substring = isHex ? digits.dropFirst() : digits
            let code: UInt32? = UInt32(number, radix: isHex ? 16 : 10)
            if let code, let scalar = Unicode.Scalar(code) {
                result.append(Character(scalar))
            } else {
                // Not a character reference after all: the text stands.
                result.append("&#")
                result.append(contentsOf: digits)
                result.append(";")
            }
            rest = afterHash[afterHash.index(after: semicolon)...]
        }
        result.append(contentsOf: rest)
        return result
    }

    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { match in
                Range(match.range(at: 1), in: text).map { String(text[$0]) }
            }
    }

    // MARK: Fetching

    static let epubMIME = "application/epub+zip"

    /// Crossref etiquette, as the citation verifier practises it.
    static let userAgent = "OrigamiText/1.0 (mailto:frode@hegland.com)"

    /// A book is a big file; this is where a runaway download stops.
    static let maximumBytes = 200 * 1024 * 1024

    enum FetchError: LocalizedError {
        case httpError(Int)
        case notAnEPUB(String)
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .httpError(let code): "the server returned HTTP \(code)"
            case .notAnEPUB(let what): "it is \(what), not an EPUB"
            case .tooLarge: "it is larger than 200 MB"
            }
        }
    }

    /// Whether an address looks like a download rather than a page.
    ///
    /// This is the gate on asking a server anything: an ordinary web link
    /// opens at once, and nothing is said to its host first. Only an
    /// address that advertises itself as a file — a `download` or
    /// `attachment` in its path, an `ebooks` shelf, a `dl=1`-style
    /// parameter — earns the one HEAD request that can tell a book from a
    /// page when the name doesn't.
    static func looksLikeADownload(_ url: URL) -> Bool {
        let segments: [String] = url.path.split(separator: "/").map {
            $0.lowercased()
        }
        let fileWords: Set<String> = ["file", "files", "get", "fetch", "content",
                                      "ebook", "ebooks", "book", "books", "epub"]
        for segment in segments {
            if segment.contains("download") || segment.contains("attachment") {
                return true
            }
            if fileWords.contains(segment) { return true }
        }
        let items: [URLQueryItem] = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems ?? []
        for item in items {
            let name: String = item.name.lowercased()
            let value: String = (item.value ?? "").lowercased()
            if name == "dl" || name == "download" || name == "attachment" {
                // `dl=0` is the preview form: the page, not the file.
                return value != "0" && value != "false"
            }
            if name == "export", value == "download" { return true }
            if value.contains("epub") { return true }
        }
        return false
    }

    /// What a server says it will serve, asked with a HEAD request: the
    /// cheapest question that distinguishes a book from a page when the
    /// address itself does not say. A server that refuses HEAD, answers
    /// vaguely, or says nothing useful is treated as a page — the browser
    /// is the safe answer, never a shelf full of guesses.
    static func servesEPUB(_ url: URL) async -> Bool {
        var request = URLRequest(url: directDownloadURL(for: url), timeoutInterval: 8)
        request.httpMethod = "HEAD"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return false }
        let type: String = (http.value(forHTTPHeaderField: "Content-Type") ?? "")
            .lowercased()
        if type.contains(epubMIME) { return true }
        // An attachment names its file even when the type is generic.
        let disposition: String = (http.value(forHTTPHeaderField: "Content-Disposition") ?? "")
            .lowercased()
        if disposition.contains(".epub") { return true }
        // The redirects may have landed on a name that says it outright.
        if let landed = http.url, namesEPUB(landed) { return true }
        return false
    }

    /// A share link that shows a preview page where a file is meant,
    /// rewritten to the address that actually yields the bytes.
    ///
    /// Dropbox is the one that matters here: the same link differs only
    /// in `dl=0` (its own viewer, an HTML page) and `dl=1` (the file), and
    /// a person copying a link out of Dropbox gets `dl=0`. Asking for the
    /// file is what a reader meant by clicking a book.
    static func directDownloadURL(for url: URL) -> URL {
        guard let host = url.host?.lowercased(),
              host == "dropbox.com" || host == "www.dropbox.com" else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = (components?.queryItems ?? [])
            .filter { $0.name != "dl" }
        items.append(URLQueryItem(name: "dl", value: "1"))
        components?.queryItems = items
        return components?.url ?? url
    }

    /// The bytes behind an address: the web over HTTP, a capsule over
    /// Gemini (where the trust store applies exactly as it does to a
    /// gemtext page). A share link is asked for its file, not its page.
    static func fetch(_ url: URL) async throws -> Data {
        let url = directDownloadURL(for: url)
        if url.scheme?.lowercased() == "gemini" {
            let response = try await GeminiClient.fetch(url)
            guard response.status / 10 == 2 else {
                throw FetchError.notAnEPUB("a status \(response.status) answer")
            }
            guard response.body.count <= maximumBytes else { throw FetchError.tooLarge }
            return response.body
        }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue("\(epubMIME),application/zip,*/*", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw FetchError.httpError(http.statusCode)
        }
        guard data.count <= maximumBytes else { throw FetchError.tooLarge }
        return data
    }

    /// Whether these bytes open as an EPUB: a zip carrying the package
    /// container every EPUB must have. Checked before anything joins the
    /// shelf, so a login page served in place of a book says so plainly
    /// instead of failing deep in the importer.
    static func isEPUB(_ data: Data, writtenTo url: URL) -> Bool {
        guard data.count > 4, data.prefix(4).elementsEqual([0x50, 0x4B, 0x03, 0x04]) else {
            return false
        }
        guard let zip = try? ZipReader(url: url) else { return false }
        return zip.entryNames.contains("META-INF/container.xml")
            || zip.entryNames.contains { $0.hasSuffix("META-INF/container.xml") }
    }

    /// What a page served instead, for the note that explains the refusal.
    static func describe(_ data: Data) -> String {
        let head = String(data: data.prefix(512), encoding: .utf8)?.lowercased() ?? ""
        if head.contains("<html") || head.contains("<!doctype html") { return "a web page" }
        if data.prefix(5).elementsEqual([0x25, 0x50, 0x44, 0x46, 0x2D]) { return "a PDF" }
        if data.isEmpty { return "empty" }
        return "not a book"
    }

    private static func json(from url: URL) async -> [String: Any]? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

#if os(macOS)

// MARK: - Claiming a link

extension AppModel {

    /// The one door every clickable address in the app knocks on. Returns
    /// true when Origami Text took the link — an `origamitext://` address,
    /// a Seed document, a capsule page, an EPUB anywhere, or a DOI that
    /// may lead to one — and false when it belongs to the browser.
    ///
    /// The answer is immediate; the work (a download, a DOI lookup) runs
    /// on behind a note, because a click cannot wait for a network.
    @MainActor
    func claimLink(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "origamitext":
            handleURL(url)
            return true
        case "gemini":
            Task { await openGeminiURL(url.absoluteString) }
            return true
        case "hm":
            Task { await openHypermediaURL(url.absoluteString) }
            return true
        default:
            break
        }
        // A book, wherever it lives — including beside the one being read.
        if EPUBLink.namesEPUB(url) {
            Task { await openLinkedEPUB(url) }
            return true
        }
        // A DOI: the work is named, the edition still has to be found.
        if let doi = EPUBLink.doi(in: url) {
            Task { await openDOI(doi, page: url) }
            return true
        }
        // A gateway URL for a Seed document reads here too.
        if HypermediaAddress.parse(url.absoluteString) != nil {
            Task { await openHypermediaURL(url.absoluteString) }
            return true
        }
        // An address that looks like a download but names no type: the
        // server is asked once, with a HEAD, and answers for it. Claimed
        // provisionally — if it turns out to be a page after all, it goes
        // to the browser as it would have anyway.
        if let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           EPUBLink.looksLikeADownload(url) {
            Task { await openProbedLink(url) }
            return true
        }
        return false
    }

    /// A download-shaped address, resolved by asking its server what it
    /// serves: a book joins the shelf, anything else opens where the
    /// click was always going.
    @MainActor
    private func openProbedLink(_ url: URL) async {
        if await EPUBLink.servesEPUB(url) {
            await openLinkedEPUB(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: A book behind a link

    /// Fetches the EPUB an address names and opens it on the shelf. A
    /// local file needs no fetching; an address already fetched opens
    /// from the shelf rather than downloading twice.
    @MainActor
    func openLinkedEPUB(_ url: URL, afterFollowingAPage: Bool = false) async {
        if url.isFileURL {
            openEPUBFile(at: url)
            return
        }
        if let known = linkedEPUBRecord(for: url) {
            openStoredEPUB(known)
            showNote("Already on the shelf: “\(known.title)”")
            return
        }
        let name = EPUBLink.namesEPUB(url)
            ? url.lastPathComponent
            : (url.host ?? url.absoluteString)
        showNote("Downloading \(name)…")
        do {
            let data = try await EPUBLink.fetch(url)
            // A deterministic name per address: the same link fetched
            // again lands in the same unpack folder, so the shelf
            // recognises it rather than shelving a twin.
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent(Self.downloadFileName(for: url))
            defer { try? FileManager.default.removeItem(at: file) }
            try data.write(to: file, options: .atomic)
            guard EPUBLink.isEPUB(data, writtenTo: file) else {
                // A page arrived where a file was meant — a share page, a
                // publisher's landing page. It may still name the book:
                // one hop after it, never a chain.
                if !afterFollowingAPage,
                   let html = String(data: data.prefix(2_000_000), encoding: .utf8),
                   let named = EPUBLink.advertisedEPUBs(inHTML: html).first,
                   let next = URL(string: named, relativeTo: url)?.absoluteURL,
                   Self.downloadKey(for: next) != Self.downloadKey(for: url) {
                    await openLinkedEPUB(next, afterFollowingAPage: true)
                    return
                }
                // The link stays here: a book's address is Origami Text's
                // to answer, and handing it to a browser would only
                // download the file somewhere the reader has to go and
                // find it. What went wrong is said instead.
                NSSound.beep()
                showNote("\(name) could not be read: \(EPUBLink.describe(data)).")
                return
            }
            guard let record = importEPUB(at: file) else { return }
            rememberLinkedEPUB(url, folder: record.folder)
            openStoredEPUB(record)
            showNote("Opened “\(record.title)”")
            mirrorShelfToCommunityFolder()
        } catch {
            // A refusal is usually a paywall or a login. Even then the
            // link is not passed to a browser: the reason is reported,
            // and the address stays on the clipboard's reach rather than
            // opening a second reader behind the app's back.
            NSSound.beep()
            let reason = (error as? EPUBLink.FetchError)?.errorDescription
                ?? error.localizedDescription
            showNote("Could not fetch \(name): \(reason)")
        }
    }

    // MARK: A book behind a DOI

    /// Resolves a DOI to an EPUB edition and opens it. When no one
    /// advertises one — the common case, since most publishers offer only
    /// PDF — the DOI's own page opens in the browser, so the click still
    /// goes somewhere.
    @MainActor
    func openDOI(_ doi: String, page: URL) async {
        // A DOI already on the shelf needs no network at all: the book
        // is here, and its record knows its DOI.
        if let held = epubRecords.first(where: {
            LineageGraph.normalizedDOI($0.doi) == doi
        }) {
            openStoredEPUB(held)
            showNote("Already on the shelf: “\(held.title)”")
            return
        }
        showNote("Looking for an EPUB edition of \(doi)…")
        guard let epub = await EPUBLink.epubURL(forDOI: doi) else {
            showNote("No EPUB edition is advertised for \(doi) — opening the page.")
            NSWorkspace.shared.open(page)
            return
        }
        await openLinkedEPUB(epub)
    }

    // MARK: What has been fetched before

    private static let linkedEPUBsKey = "linkedEPUBFolders"

    /// Addresses fetched before, each remembering the unpack folder its
    /// book landed in — so a second click opens the shelf's copy.
    private static func linkedEPUBFolders() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: linkedEPUBsKey) as? [String: String] ?? [:]
    }

    @MainActor
    private func rememberLinkedEPUB(_ url: URL, folder: String) {
        var all = Self.linkedEPUBFolders()
        all[Self.downloadKey(for: url)] = folder
        UserDefaults.standard.set(all, forKey: Self.linkedEPUBsKey)
    }

    @MainActor
    private func linkedEPUBRecord(for url: URL) -> EPUBRecord? {
        guard let folder = Self.linkedEPUBFolders()[Self.downloadKey(for: url)] else {
            return nil
        }
        return epubRecords.first { $0.folder == folder }
    }

    /// One address, one key: the fragment never names a different book,
    /// and a share link's preview and download forms (Dropbox's `dl=0`
    /// and `dl=1`) are one address, so clicking either finds the copy the
    /// other fetched.
    nonisolated static func downloadKey(for url: URL) -> String {
        var components = URLComponents(url: EPUBLink.directDownloadURL(for: url),
                                       resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return (components?.url ?? url).absoluteString
    }

    /// The downloaded file's name: the address's own, kept readable, with
    /// a short digest of the full address so two books called `paper.epub`
    /// never share an unpack folder.
    nonisolated static func downloadFileName(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let digest = OrigamiMath.sha256Hex(downloadKey(for: url)).prefix(8)
        let base = stem.isEmpty ? "book" : String(stem.prefix(120))
        return "\(base)-\(digest).epub"
    }
}

#endif
