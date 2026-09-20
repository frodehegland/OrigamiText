// FETCH BY DOI OR URL — a paper that is free to read, brought into the
// library as a document one can actually read: its sections, its
// citations, its figures, not a picture of a page.
//
// Two rules decide everything here.
//
// The first is about permission. Only what the registries say is open
// is fetched, the app names itself and its contact in every request (as
// Crossref and OpenAlex ask), and a host that refuses is simply
// refused: no challenge is worked around, no paywall is stepped over.
// A publisher must be able to watch this code and find nothing to
// object to — which matters more for a format seeking adoption than any
// one paper does.
//
// The second is about quality. A research PDF converted by pulling its
// words out is a poor thing: two columns interleaved, ligatures broken,
// hyphens welded into the middle of words, running heads in the prose.
// So structured sources are preferred in a strict order, and the PDF is
// the last resort, named as such. The importers this hands to already
// exist — BITS/JATS XML, EPUB, LaTeX, PDF — so this file is a resolver
// and a polite downloader, nothing more.
#if os(macOS)
import Foundation
import AppKit

enum OnlineFetch {

    // MARK: - What the registries say

    /// One place a free copy might be had, and what it is worth.
    struct Source {
        enum Kind: Int, Comparable {
            /// JATS/BITS XML — the publisher's own structure.
            case structuredXML = 0
            /// An EPUB the publisher offers.
            case epub = 1
            /// A LaTeX project (Author's own export, or a zip found online).
            case latex = 2
            /// Words pulled out of a PDF: the last resort.
            case pdf = 3

            static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

            var fileExtension: String {
                switch self {
                case .structuredXML: "xml"
                case .epub: "epub"
                case .latex: "zip"
                case .pdf: "pdf"
                }
            }

            var worth: String {
                switch self {
                case .structuredXML: "the publisher's own XML — sections, citations and figures intact"
                case .epub: "the publisher's EPUB"
                case .latex: "the LaTeX source"
                case .pdf: "a PDF — the words come across, the fine structure may not"
                }
            }
        }

        let kind: Kind
        let url: URL
        /// Where this came from, for the report: "Europe PMC", "arXiv".
        let host: String
    }

    /// What the registries know about the work.
    struct Finding {
        var doi: String?
        var title: String
        var authors: String
        var year: String
        var isOpenAccess: Bool
        /// gold, green, hybrid, bronze, closed — OpenAlex's word for it.
        var status: String
        var landingPage: URL?
        var sources: [Source]
    }

    enum FetchError: LocalizedError {
        case notUnderstood
        case notFound
        case notOpenAccess(Finding)
        case everySourceRefused(Finding, [String])
        case importFailed(String)

        var errorDescription: String? {
            switch self {
            case .notUnderstood:
                "That is not a DOI or a web address."
            case .notFound:
                "No work with that DOI is registered."
            case .notOpenAccess:
                "This paper is not open access."
            case .everySourceRefused:
                "No free copy could be downloaded."
            case .importFailed(let why):
                "The file arrived but would not import: \(why)"
            }
        }
    }

    // MARK: - Reading what the reader typed

    /// A DOI out of whatever was pasted: the bare form, a doi.org link,
    /// or a publisher URL with the DOI in its path (ACM, Springer and
    /// friends all put it there).
    static func doi(in raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = text.range(of: "10\\.\\d{4,9}/[^\\s\"<>]+",
                                     options: [.regularExpression]) else { return nil }
        var doi = String(text[match])
        // A DOI at the end of a sentence or a URL query keeps its own
        // characters, not the page's punctuation.
        while let last = doi.last, ".,;)]".contains(last) { doi.removeLast() }
        if let query = doi.firstIndex(of: "?") { doi = String(doi[..<query]) }
        return doi.lowercased()
    }

    /// arXiv's own identifier, from a link or a bare id.
    static func arxivID(in raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = text.range(of: "arxiv\\.org/(abs|pdf|html)/([^\\s?#]+)",
                                  options: [.regularExpression, .caseInsensitive]) {
            var id = String(text[match]).components(separatedBy: "/").last ?? ""
            if id.lowercased().hasSuffix(".pdf") { id = String(id.dropLast(4)) }
            return id.isEmpty ? nil : id
        }
        if text.range(of: "^\\d{4}\\.\\d{4,5}(v\\d+)?$",
                      options: [.regularExpression]) != nil { return text }
        return nil
    }

    // MARK: - Asking the registries

    /// Every request says who is asking: the convention Crossref and
    /// OpenAlex ask for, and the difference between a good citizen and
    /// a scraper.
    private static func request(_ url: URL, accept: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let contact = UserDefaults.standard.string(forKey: AppSettings.authorEmailKey) ?? ""
        let mail = contact.isEmpty ? "info@futuretextlab.info" : contact
        request.setValue("OrigamiText/1.0 (https://futuretextlab.info; mailto:\(mail))",
                         forHTTPHeaderField: "User-Agent")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        return request
    }

    private static func json(_ url: URL) async -> [String: Any]? {
        guard let (data, response) = try? await URLSession.shared.data(for: request(url, accept: "application/json")),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    /// What is known about the work, and every free copy worth trying.
    static func look(up raw: String) async throws -> Finding {
        let doi = doi(in: raw)
        let arxiv = arxivID(in: raw)
        let direct = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard doi != nil || arxiv != nil || direct?.scheme?.hasPrefix("http") == true else {
            throw FetchError.notUnderstood
        }

        var finding = Finding(doi: doi, title: "", authors: "", year: "",
                              isOpenAccess: false, status: "unknown",
                              landingPage: doi.flatMap { URL(string: "https://doi.org/\($0)") }
                                  ?? direct,
                              sources: [])

        if let doi {
            if let work = await json(URL(string: "https://api.crossref.org/works/\(doi)")!),
               let message = work["message"] as? [String: Any] {
                finding.title = (message["title"] as? [String])?.first ?? ""
                let people = (message["author"] as? [[String: Any]]) ?? []
                finding.authors = people.compactMap { person in
                    [person["given"] as? String, person["family"] as? String]
                        .compactMap { $0 }.joined(separator: " ")
                }.joined(separator: ", ")
                if let parts = (message["published"] as? [String: Any])?["date-parts"]
                    as? [[Int]], let year = parts.first?.first {
                    finding.year = String(year)
                }
            } else if arxiv == nil {
                throw FetchError.notFound
            }

            // OpenAlex: is it free, and where. (CitationLookup already
            // speaks to this service; the open-access fields are the
            // part it does not use yet.)
            let alexURL = URL(string: "https://api.openalex.org/works/doi:\(doi)")!
            if let work = await json(alexURL) {
                let openAccess = work["open_access"] as? [String: Any] ?? [:]
                finding.isOpenAccess = openAccess["is_oa"] as? Bool ?? false
                finding.status = openAccess["oa_status"] as? String ?? "unknown"
                if finding.title.isEmpty {
                    finding.title = work["title"] as? String ?? ""
                }
                // Europe PMC carries JATS for anything with a PMCID —
                // the best source there is, and freely fetchable.
                if let ids = work["ids"] as? [String: Any],
                   let pmcid = (ids["pmcid"] as? String)?
                    .components(separatedBy: "/").last, !pmcid.isEmpty,
                   let xml = URL(string: "https://www.ebi.ac.uk/europepmc/webservices/rest/\(pmcid)/fullTextXML") {
                    finding.sources.append(Source(kind: .structuredXML, url: xml,
                                                  host: "Europe PMC"))
                }
                for location in (work["locations"] as? [[String: Any]]) ?? [] {
                    guard location["is_oa"] as? Bool == true else { continue }
                    let host = ((location["source"] as? [String: Any])?["display_name"]
                        as? String) ?? "the publisher"
                    if let pdf = (location["pdf_url"] as? String).flatMap(URL.init(string:)) {
                        finding.sources.append(Source(kind: kind(of: pdf), url: pdf, host: host))
                    }
                }
            }
        }

        // arXiv: fetchable, and generous about it.
        if let arxiv, let pdf = URL(string: "https://arxiv.org/pdf/\(arxiv)") {
            finding.isOpenAccess = true
            if finding.status == "unknown" { finding.status = "arXiv" }
            finding.sources.append(Source(kind: .pdf, url: pdf, host: "arXiv"))
            if finding.title.isEmpty { finding.title = "arXiv:\(arxiv)" }
        }

        // A link straight at a file is worth trying on its own terms —
        // the reader found it, after all.
        if let direct, ["pdf", "epub", "xml", "zip"].contains(direct.pathExtension.lowercased()) {
            finding.sources.append(Source(kind: kind(of: direct), url: direct,
                                          host: direct.host ?? "that address"))
        }

        // Best first, and never the same URL twice.
        var seen = Set<String>()
        finding.sources = finding.sources
            .sorted { $0.kind < $1.kind }
            .filter { seen.insert($0.url.absoluteString).inserted }
        return finding
    }

    private static func kind(of url: URL) -> Source.Kind {
        switch url.pathExtension.lowercased() {
        case "xml": .structuredXML
        case "epub": .epub
        case "zip": .latex
        default: .pdf
        }
    }

    // MARK: - Fetching, politely

    /// Tries each source in turn. Returns the downloaded file and the
    /// source it came from, or every reason it could not.
    static func download(_ finding: Finding) async -> (file: URL, source: Source)? {
        for source in finding.sources {
            guard let data = await bytes(from: source.url),
                  looksLike(source.kind, data) else { continue }
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("OrigamiFetch", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = (finding.doi?.replacingOccurrences(of: "/", with: "_")
                        ?? UUID().uuidString) + "." + source.kind.fileExtension
            let file = folder.appendingPathComponent(name)
            guard (try? data.write(to: file)) != nil else { continue }
            return (file, source)
        }
        return nil
    }

    private static func bytes(from url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(for: request(url)),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200
        else { return nil }
        return data
    }

    /// Is this the thing it claimed to be? A challenge page arrives as
    /// HTML with a 200 as often as a 403, and would otherwise be
    /// imported as a document called "Just a moment…".
    private static func looksLike(_ kind: Source.Kind, _ data: Data) -> Bool {
        let head = data.prefix(1024)
        let text = String(decoding: head, as: UTF8.self).lowercased()
        if text.contains("<!doctype html") || text.contains("<html") {
            // HTML is never one of the kinds fetched here.
            return false
        }
        switch kind {
        case .pdf: return head.starts(with: Array("%PDF".utf8))
        case .epub, .latex: return head.starts(with: [0x50, 0x4B])   // PK — a zip
        case .structuredXML: return text.contains("<") && data.count > 512
        }
    }
}

// MARK: - The reader's side of it

extension AppModel {

    /// File ▸ Fetch by DOI or URL… — the prompt.
    func fetchOnlineDocumentPrompt() {
        let alert = NSAlert()
        alert.messageText = "Fetch a Paper"
        alert.informativeText = "Paste a DOI, a doi.org link, an arXiv address, or a direct link to a PDF, EPUB or JATS XML. Only papers the registries report as open access are fetched."
        alert.addButton(withTitle: "Fetch")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "10.1145/3603163.3609048"
        if let clipboard = NSPasteboard.general.string(forType: .string),
           OnlineFetch.doi(in: clipboard) != nil || OnlineFetch.arxivID(in: clipboard) != nil {
            field.stringValue = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let typed = field.stringValue
        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task { await fetchOnlineDocument(typed) }
    }

    /// Look the work up, take the best free copy there is, and import
    /// it with whichever importer suits what arrived.
    func fetchOnlineDocument(_ input: String) async {
        showNote("Asking the registries…")
        let finding: OnlineFetch.Finding
        do {
            finding = try await OnlineFetch.look(up: input)
        } catch {
            fetchAlert("Could Not Fetch", error.localizedDescription, landing: nil)
            return
        }

        let name = finding.title.isEmpty ? input : "\u{201C}\(finding.title)\u{201D}"
        guard finding.isOpenAccess || !finding.sources.isEmpty else {
            fetchAlert(
                "Not Open Access",
                "\(name) is not reported as open access (\(finding.status)), so there is no free copy to fetch. Open it at the publisher and, if you have access, drop the file here to import it.",
                landing: finding.landingPage)
            return
        }

        showNote("Fetching \(name)…")
        guard let got = await OnlineFetch.download(finding) else {
            // The commonest case, and worth saying exactly: a paper can
            // be open access and still refuse an app. ACM's library
            // answers software with a Cloudflare challenge.
            fetchAlert(
                "The Publisher Refused",
                "\(name) is open access (\(finding.status)), but no host would hand the file to an app — several publishers answer software with a challenge page. Open it in your browser, download it, and drop it here; the import is the same.",
                landing: finding.landingPage)
            return
        }

        showNote("Importing \(got.source.kind.worth)…")
        importFile(at: got.file)
        showNote("Fetched \(name) from \(got.source.host).")
    }

    private func fetchAlert(_ title: String, _ text: String, landing: URL?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        if landing != nil { alert.addButton(withTitle: "Open in Browser") }
        alert.addButton(withTitle: "OK")
        let answer = alert.runModal()
        if let landing, answer == .alertFirstButtonReturn {
            NSWorkspace.shared.open(landing)
        }
    }
}
#endif
