#if os(macOS)
import SwiftUI

/// OPDS catalogues — how libraries, publishers and open-access collections
/// publish their books: browse a feed (OPDS 1 Atom or OPDS 2 JSON), follow
/// its sections, and bring a DRM-free EPUB into the library in one click.
nonisolated enum OPDS {
    struct Link: Hashable, Sendable {
        let href: URL
        let title: String?
        let type: String?
        let rel: String?
    }

    struct Entry: Identifiable, Hashable, Sendable {
        let id = UUID()
        let title: String
        let authors: [String]
        let summary: String?
        /// Sub-feeds (sections, searches, next pages).
        let navigation: [Link]
        /// Downloadable EPUBs.
        let epubs: [Link]
    }

    struct Feed: Sendable {
        var title: String
        var entries: [Entry]
        var next: URL?
    }

    static func load(_ url: URL) async throws -> Feed {
        var request = URLRequest(url: url)
        request.setValue("application/opds+json, application/atom+xml;profile=opds-catalog, */*;q=0.5",
                         forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let base = response.url ?? url
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parseJSON(json, base: base)
        }
        return parseAtom(data, base: base)
    }

    // MARK: OPDS 2 (JSON)

    static func parseJSON(_ json: [String: Any], base: URL) -> Feed {
        func links(_ value: Any?) -> [Link] {
            ((value as? [[String: Any]]) ?? []).compactMap { link in
                guard let href = link["href"] as? String, let url = URL(string: href, relativeTo: base) else { return nil }
                return Link(href: url.absoluteURL, title: link["title"] as? String,
                            type: link["type"] as? String,
                            rel: (link["rel"] as? String) ?? (link["rel"] as? [String])?.first)
            }
        }
        func publication(_ p: [String: Any]) -> Entry? {
            let meta = p["metadata"] as? [String: Any] ?? [:]
            guard let title = meta["title"] as? String else { return nil }
            let authors: [String]
            if let one = meta["author"] as? String { authors = [one] }
            else if let one = meta["author"] as? [String: Any], let name = one["name"] as? String { authors = [name] }
            else { authors = ((meta["author"] as? [Any]) ?? []).compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["name"] as? String) } }
            let all = links(p["links"])
            return Entry(title: title, authors: authors, summary: meta["description"] as? String,
                         navigation: [], epubs: all.filter { $0.type?.contains("epub") == true })
        }
        var entries: [Entry] = []
        for nav in links(json["navigation"]) {
            entries.append(Entry(title: nav.title ?? nav.href.lastPathComponent, authors: [], summary: nil,
                                 navigation: [nav], epubs: []))
        }
        entries += ((json["publications"] as? [[String: Any]]) ?? []).compactMap(publication)
        for group in (json["groups"] as? [[String: Any]]) ?? [] {
            for nav in links(group["navigation"]) {
                entries.append(Entry(title: nav.title ?? "Section", authors: [], summary: nil, navigation: [nav], epubs: []))
            }
            entries += ((group["publications"] as? [[String: Any]]) ?? []).compactMap(publication)
        }
        let feedLinks = links(json["links"])
        return Feed(title: (json["metadata"] as? [String: Any])?["title"] as? String ?? "Catalogue",
                    entries: entries,
                    next: feedLinks.first { $0.rel == "next" }?.href)
    }

    // MARK: OPDS 1 (Atom)

    static func parseAtom(_ data: Data, base: URL) -> Feed {
        let xml = String(decoding: data, as: UTF8.self)
        func first(_ text: String, _ pattern: String) -> String? {
            guard let e = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
                  let m = e.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(m.range(at: 1), in: text) else { return nil }
            return decode(String(text[r]))
        }
        func all(_ text: String, _ pattern: String) -> [String] {
            guard let e = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
            return e.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range(at: $0.numberOfRanges > 1 ? 1 : 0), in: text).map { String(text[$0]) }
            }
        }
        func links(_ text: String) -> [Link] {
            all(text, #"(<link\b[^>]*>)"#).compactMap { tag in
                guard let href = first(tag, #"href=["']([^"']+)"#),
                      let url = URL(string: href, relativeTo: base) else { return nil }
                return Link(href: url.absoluteURL, title: first(tag, #"title=["']([^"']+)"#),
                            type: first(tag, #"type=["']([^"']+)"#), rel: first(tag, #"rel=["']([^"']+)"#))
            }
        }
        let head = xml.components(separatedBy: "<entry").first ?? xml
        var entries: [Entry] = []
        for entry in all(xml, #"(<entry\b.*?</entry>)"#) {
            let title = first(entry, #"<title[^>]*>(.*?)</title>"#) ?? "Untitled"
            let entryLinks = links(entry)
            let epubs = entryLinks.filter { $0.type?.contains("epub") == true
                && ($0.rel?.contains("acquisition") ?? true) }
            let navigation = entryLinks.filter { ($0.type ?? "").contains("opds-catalog") || $0.rel == "subsection" }
            let summary = first(entry, #"<summary[^>]*>(.*?)</summary>"#)
                ?? first(entry, #"<content[^>]*>(.*?)</content>"#)
            entries.append(Entry(title: title,
                                 authors: all(entry, #"<author>.*?<name>(.*?)</name>"#).map(decode),
                                 summary: summary.map { $0.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) },
                                 navigation: epubs.isEmpty ? navigation : [], epubs: epubs))
        }
        return Feed(title: first(head, #"<title[^>]*>(.*?)</title>"#) ?? "Catalogue",
                    entries: entries,
                    next: links(head).first { $0.rel == "next" }?.href)
    }

    private static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "<![CDATA[", with: "").replacingOccurrences(of: "]]>", with: "")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// File ▸ Browse Catalogues…: a feed at a time, sections followed with a
/// way back, each DRM-free EPUB one Get from the library.
struct OPDSBrowser: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("opdsCatalogues") private var savedRaw = ""
    @State private var address = ""
    @State private var stack: [OPDS.Feed] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var fetching: Set<URL> = []

    /// A few open catalogues to start from, then the reader's own.
    private var catalogues: [(name: String, url: String)] {
        let own = savedRaw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }.map { ($0, $0) }
        return [("Project Gutenberg", "https://www.gutenberg.org/ebooks.opds/")] + own
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if stack.count > 1 {
                    Button { stack.removeLast() } label: { Label("Back", systemImage: "chevron.backward") }
                }
                Text(stack.last?.title ?? "Catalogues").font(.headline).lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            HStack {
                TextField("OPDS catalogue address", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { open(address, remember: true) }
                Button("Open") { open(address, remember: true) }
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            Divider()
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure {
                ContentUnavailableView("Could Not Open", systemImage: "exclamationmark.triangle",
                                       description: Text(failure))
            } else if let feed = stack.last {
                List {
                    ForEach(feed.entries) { entry in row(entry) }
                    if let next = feed.next {
                        Button("More\u{2026}") { open(next.absoluteString, push: false) }
                    }
                }
            } else {
                List(catalogues, id: \.url) { catalogue in
                    Button { open(catalogue.url) } label: {
                        Label(catalogue.name, systemImage: "books.vertical")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 520)
    }

    private func row(_ entry: OPDS.Entry) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.body.bold())
                if !entry.authors.isEmpty {
                    Text(entry.authors.joined(separator: ", ")).foregroundStyle(.secondary)
                }
                if let summary = entry.summary, !summary.isEmpty {
                    Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer()
            // The richest edition offered: EPUB 3 with images first.
            if let epub = entry.epubs.first(where: { $0.href.absoluteString.contains("epub3") })
                ?? entry.epubs.first(where: { !$0.href.absoluteString.contains("noimages") })
                ?? entry.epubs.first {
                if fetching.contains(epub.href) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Get") { get(epub, title: entry.title) }
                        .help("Download this EPUB into the library")
                }
            } else if let section = entry.navigation.first {
                Button("Open \u{203A}") { open(section.href.absoluteString) }
            }
        }
        .padding(.vertical, 4)
    }

    private func open(_ text: String, remember: Bool = false, push: Bool = true) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else {
            failure = "That is not a web address."
            return
        }
        loading = true
        failure = nil
        Task {
            do {
                let feed = try await OPDS.load(url)
                if push || stack.isEmpty { stack.append(feed) }
                else if var last = stack.popLast() {
                    // "More…": the next page joins the one on screen.
                    last.entries += feed.entries
                    last.next = feed.next
                    stack.append(last)
                }
                if remember, !catalogues.contains(where: { $0.url == trimmed }) {
                    savedRaw = (savedRaw.isEmpty ? "" : savedRaw + "\n") + trimmed
                }
            } catch {
                failure = error.localizedDescription
            }
            loading = false
        }
    }

    private func get(_ link: OPDS.Link, title: String) {
        fetching.insert(link.href)
        Task {
            defer { fetching.remove(link.href) }
            do {
                let (temporary, _) = try await URLSession.shared.download(from: link.href)
                let safe = title.replacingOccurrences(of: "/", with: "-").prefix(80)
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent(String(safe) + ".epub")
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                model.importFile(at: destination)
            } catch {
                model.showNote("Could not download \u{201C}\(title)\u{201D}: \(error.localizedDescription)")
            }
        }
    }
}
#endif
