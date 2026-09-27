#if os(macOS)
import Foundation

/// W3C EPUB Annotations 1.0: a reader's highlights and notes on one book,
/// written as an AnnotationSet — a `.annotations` zip holding
/// `annotations.json` — that other reading systems (Thorium from 3.6)
/// read, and read back from one. The sidecar stays the source of truth;
/// this is the exchange form.
enum EPUBAnnotationExchange {
    static let htmlFragment = "http://tools.ietf.org/rfc/rfc3236"
    static let textFragment = "https://wicg.github.io/scroll-to-text-fragment/"

    // MARK: Export

    /// The book's annotations as a `.annotations` package.
    static func export(_ annotations: [WebAnnotation], bookFolder: URL,
                       title: String, creators: [String], date: String?,
                       identifier: String?) -> Data? {
        let locator = ContentLocator(folder: bookFolder)
        let iso = ISO8601DateFormatter()
        var items: [[String: Any]] = []
        for annotation in annotations where annotation.motivation != WebAnnotation.Motivation.describing {
            var fragment: String?
            var quote: (exact: String, prefix: String?, suffix: String?)?
            for selector in annotation.target.selectors {
                switch selector {
                case .fragment(let value, _): fragment = fragment ?? value
                case .quote(let exact, let prefix, let suffix): quote = quote ?? (exact, prefix, suffix)
                default: break
                }
            }
            let (source, id) = locator.locate(fragment)
            guard let source else { continue }
            var selectors: [[String: Any]] = []
            let text: [String: Any]? = quote.map {
                ["type": "FragmentSelector", "conformsTo": textFragment,
                 "value": ":~:text=" + textDirective(exact: $0.exact, prefix: $0.prefix, suffix: $0.suffix)]
            }
            if let id {
                var element: [String: Any] = ["type": "FragmentSelector", "conformsTo": htmlFragment, "value": id]
                if let text { element["refinedBy"] = text }
                selectors.append(element)
            } else if let text {
                selectors.append(text)
            }
            // Kind and note: a tag names one of the reader's kinds.
            let kind: ReaderAnnotationKind? = annotation.motivation == WebAnnotation.Motivation.tagging
                ? annotation.body.flatMap { ReaderAnnotationKind(rawValue: $0.value) } : .highlight
            var body: [String: Any] = ["type": "TextualBody"]
            if annotation.motivation == WebAnnotation.Motivation.commenting,
               let note = annotation.body?.value { body["value"] = note } else { body["value"] = "" }
            body["color"] = color(for: kind)
            body["highlight"] = kind == .strikethrough ? "strikethrough" : "solid"
            if let kind, kind != .highlight { body["tags"] = [kind.rawValue] }
            var item: [String: Any] = [
                "id": annotation.id, "type": "Annotation", "motivation": "highlighting",
                "created": iso.string(from: annotation.created),
                "target": ["source": source, "selector": selectors] as [String: Any],
                "body": body,
            ]
            if let modified = annotation.modified { item["modified"] = iso.string(from: modified) }
            if let name = annotation.creator?.name, !name.isEmpty {
                item["creator"] = ["id": "urn:origami-text:reader", "type": "Person", "name": name]
            }
            items.append(item)
        }
        var about: [String: Any] = ["dc:title": title]
        if !creators.isEmpty { about["dc:creator"] = creators }
        if let date { about["dc:date"] = date }
        if let identifier, !identifier.isEmpty { about["dc:identifier"] = identifier }
        let set: [String: Any] = [
            "@context": "https://www.w3.org/ns/epub-anno.jsonld",
            "id": "urn:uuid:" + UUID().uuidString.lowercased(),
            "type": "AnnotationSet",
            "generated": iso.string(from: .now),
            "about": about,
            "items": items,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: set,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        var zip = ZipWriter()
        zip.add("annotations.json", json)
        return zip.finished()
    }

    /// The text-fragment directive: `prefix-,start,-suffix`, each part
    /// percent-encoded so its own commas and dashes cannot break it.
    static func textDirective(exact: String, prefix: String?, suffix: String?) -> String {
        var allowed = CharacterSet.urlFragmentAllowed
        allowed.remove(charactersIn: ",-&")
        func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        var parts: [String] = []
        if let prefix = prefix?.trimmingCharacters(in: .whitespaces), !prefix.isEmpty {
            parts.append(encode(String(prefix.suffix(40))) + "-")
        }
        parts.append(encode(exact))
        if let suffix = suffix?.trimmingCharacters(in: .whitespaces), !suffix.isEmpty {
            parts.append("-" + encode(String(suffix.prefix(40))))
        }
        return parts.joined(separator: ",")
    }

    private static func color(for kind: ReaderAnnotationKind?) -> String {
        switch kind {
        case .important: "orange"
        case .quotable: "blue"
        case .great: "green"
        case .disagree, .problematic: "pink"
        case .languageIssue, .whatIsThis: "purple"
        default: "yellow"
        }
    }

    // MARK: Import

    struct ImportedSet {
        var title: String?
        var identifier: String?
        var annotations: [WebAnnotation]
    }

    /// Reads an AnnotationSet from a `.annotations` package or a bare
    /// `annotations.json`.
    static func read(_ url: URL) throws -> ImportedSet {
        var data = try Data(contentsOf: url)
        if data.starts(with: [0x50, 0x4B]) {
            guard let json = try ZipReader(url: url).entry("annotations.json") else {
                throw CocoaError(.fileReadCorruptFile)
            }
            data = json
        }
        guard let set = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let about = set["about"] as? [String: Any]
        let iso = ISO8601DateFormatter()
        var annotations: [WebAnnotation] = []
        for item in (set["items"] as? [[String: Any]]) ?? [] {
            guard let target = item["target"] as? [String: Any],
                  let source = target["source"] as? String else { continue }
            var selectors: [WebAnnotation.Selector] = []
            var pending = (target["selector"] as? [[String: Any]]) ?? []
            while let selector = pending.first {
                pending.removeFirst()
                if let refined = selector["refinedBy"] as? [String: Any] { pending.append(refined) }
                guard selector["type"] as? String == "FragmentSelector",
                      let value = selector["value"] as? String else { continue }
                if selector["conformsTo"] as? String == htmlFragment {
                    selectors.append(.fragment(value: value, conformsTo: WebAnnotation.fragmentConformsTo))
                } else if selector["conformsTo"] as? String == textFragment,
                          let quote = parseTextDirective(value) {
                    selectors.append(.quote(exact: quote.exact, prefix: quote.prefix, suffix: quote.suffix))
                }
            }
            let body = item["body"] as? [String: Any]
            let note = (body?["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let kind = ((body?["tags"] as? [String]) ?? []).compactMap(ReaderAnnotationKind.init(rawValue:)).first
                ?? (body?["highlight"] as? String == "strikethrough" ? .strikethrough : nil)
            let motivation: String
            let textual: WebAnnotation.TextualBody?
            if !note.isEmpty {
                motivation = WebAnnotation.Motivation.commenting
                textual = .init(value: note)
            } else if let kind, kind != .highlight {
                motivation = WebAnnotation.Motivation.tagging
                textual = .init(value: kind.rawValue, purpose: "tagging")
            } else {
                motivation = WebAnnotation.Motivation.highlighting
                textual = nil
            }
            let creator = ((item["creator"] as? [String: Any])?["name"] as? String).map(WebAnnotation.Person.init)
            annotations.append(WebAnnotation(
                id: item["id"] as? String ?? "urn:uuid:" + UUID().uuidString.lowercased(),
                motivation: motivation,
                created: (item["created"] as? String).flatMap(iso.date(from:)) ?? .now,
                modified: (item["modified"] as? String).flatMap(iso.date(from:)),
                creator: creator,
                body: textual,
                target: .init(source: source, selectors: selectors)))
        }
        return ImportedSet(title: about?["dc:title"] as? String,
                           identifier: about?["dc:identifier"] as? String,
                           annotations: annotations)
    }

    /// `:~:text=prefix-,start,end,-suffix` back into quote parts.
    static func parseTextDirective(_ value: String) -> (exact: String, prefix: String?, suffix: String?)? {
        guard let range = value.range(of: "text=") else { return nil }
        var parts = value[range.upperBound...].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        var prefix: String?, suffix: String?
        if let first = parts.first, first.hasSuffix("-") { prefix = String(first.dropLast()); parts.removeFirst() }
        if let last = parts.last, last.hasPrefix("-") { suffix = String(last.dropFirst()); parts.removeLast() }
        guard let start = parts.first else { return nil }
        let decode: (String) -> String = { $0.removingPercentEncoding ?? $0 }
        // A start,end range reads as its two ends joined.
        let exact = parts.count > 1 ? decode(start) + "\u{2026}" + decode(parts[1]) : decode(start)
        return (exact, prefix.map(decode), suffix.map(decode))
    }

    // MARK: Content documents

    /// Finds the content document (container-relative) an element address
    /// belongs to: `path#id` directly, a bare id by looking in the spine.
    struct ContentLocator {
        let folder: URL
        private let opfDirectory: String
        private let chapters: [String]

        init(folder: URL) {
            self.folder = folder
            let spine = OrigamiEPUBImporter.spine(inUnpackedFolder: folder)
            chapters = spine?.chapters ?? []
            let container = (try? String(contentsOf: folder.appendingPathComponent("META-INF/container.xml"),
                                         encoding: .utf8)) ?? ""
            let opf = container.range(of: #"full-path="([^"]+)""#, options: .regularExpression)
                .map { String(container[$0]).replacingOccurrences(of: "full-path=", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"")) } ?? "package.opf"
            opfDirectory = (opf as NSString).deletingLastPathComponent
        }

        func locate(_ fragment: String?) -> (source: String?, id: String?) {
            guard let fragment, !fragment.isEmpty else { return (chapters.first, nil) }
            if let hash = fragment.lastIndex(of: "#") {
                let path = String(fragment[..<hash])
                let id = String(fragment[fragment.index(after: hash)...])
                let candidate = opfDirectory.isEmpty ? path : opfDirectory + "/" + path
                return (chapters.contains(candidate) ? candidate : (chapters.contains(path) ? path : candidate), id)
            }
            for chapter in chapters {
                if let html = try? String(contentsOf: folder.appendingPathComponent(chapter), encoding: .utf8),
                   html.contains("id=\"\(fragment)\"") || html.contains("id='\(fragment)'") {
                    return (chapter, fragment)
                }
            }
            return (chapters.first, fragment)
        }
    }
}
#endif
