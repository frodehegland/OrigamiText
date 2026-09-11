import Foundation
import Compression
import QuickLookUI
import UniformTypeIdentifiers

enum EPUBPreviewError: Error {
    case notAnEPUB
    case corruptContainer
    case missingContent
    case unsupportedCompression(Int)
}

/// Builds a Quick Look HTML reply from an EPUB, entirely in memory: the
/// first spine document with its stylesheets inlined and its images turned
/// into cid: attachments — the page as the book styles it, no unpacking,
/// no WebKit in-process. Self-contained: the extension target needs only
/// this file and PreviewProvider.swift.
struct EPUBPreviewBuilder {

    struct Built {
        let html: Data
        let title: String
        let attachments: [String: QLPreviewReplyAttachment]
    }

    private let zip: PreviewZipReader

    init(fileURL: URL) throws {
        zip = try PreviewZipReader(data: try Data(contentsOf: fileURL))
    }

    func build() throws -> Built {
        // container.xml names the OPF; the OPF names the title and spine.
        guard let containerData = entry("META-INF/container.xml"),
              let container = String(data: containerData, encoding: .utf8),
              let opfPath = firstMatch(in: container, pattern: "full-path=\"([^\"]+)\"")
        else { throw EPUBPreviewError.corruptContainer }
        guard let opfData = entry(opfPath),
              let opf = String(data: opfData, encoding: .utf8)
        else { throw EPUBPreviewError.corruptContainer }
        let opfDirectory = directory(of: opfPath)
        let title = firstMatch(in: opf, pattern: "<dc:title[^>]*>([^<]+)</dc:title>")
            .map(decodedEntities) ?? "EPUB"

        // The manifest maps ids to hrefs; the spine orders the ids.
        var manifest: [String: String] = [:]
        for match in allMatches(in: opf,
                                pattern: "<item\\s[^>]*>",
                                group: 0) {
            guard let id = firstMatch(in: match, pattern: "\\bid=\"([^\"]+)\""),
                  let href = firstMatch(in: match, pattern: "\\bhref=\"([^\"]+)\"")
            else { continue }
            manifest[id] = href
        }
        let spineIDs = allMatches(in: opf, pattern: "<itemref\\s[^>]*idref=\"([^\"]+)\"", group: 1)
        let chapterPaths = spineIDs.compactMap { manifest[$0] }
            .map { joined(opfDirectory, $0) }
        guard let contentPath = chapterPaths.first,
              let contentData = entry(contentPath),
              var html = String(data: contentData, encoding: .utf8)
        else { throw EPUBPreviewError.missingContent }
        let contentDirectory = directory(of: contentPath)

        // Linked stylesheets inline as <style> so the page previews as
        // the book styles it.
        for link in allMatches(in: html,
                               pattern: "<link\\s[^>]*rel=\"stylesheet\"[^>]*/?>",
                               group: 0) {
            guard let href = firstMatch(in: link, pattern: "\\bhref=\"([^\"]+)\""),
                  let cssData = entry(joined(contentDirectory, href)),
                  let css = String(data: cssData, encoding: .utf8)
            else { continue }
            html = html.replacingOccurrences(of: link, with: "<style>\n\(css)\n</style>")
        }

        // Embedded fonts named by the inlined stylesheets ride as cid:
        // attachments too — the title face survives into the preview.
        var attachments: [String: QLPreviewReplyAttachment] = [:]
        for (index, ref) in allMatches(in: html,
                                       pattern: "url\\(\"?([^\")]+\\.woff2?)\"?\\)",
                                       group: 1).enumerated() {
            guard let fontData = entry(joined(contentDirectory, ref)) else { continue }
            let key = "font\(index)"
            attachments[key] = QLPreviewReplyAttachment(
                data: fontData,
                contentType: UTType(filenameExtension: (ref as NSString).pathExtension) ?? .data)
            html = html.replacingOccurrences(of: ref, with: "cid:\(key)")
        }

        // Every image rides along as a cid: attachment.
        for (index, tag) in allMatches(in: html, pattern: "<img\\s[^>]*/?>", group: 0).enumerated() {
            guard let src = firstMatch(in: tag, pattern: "\\bsrc=\"([^\"]+)\""),
                  !src.hasPrefix("http"), !src.hasPrefix("data:"),
                  let imageData = entry(joined(contentDirectory, src)),
                  let type = imageType(for: src)
            else { continue }
            let key = "image\(index)"
            attachments[key] = QLPreviewReplyAttachment(data: imageData, contentType: type)
            html = html.replacingOccurrences(of: "src=\"\(src)\"", with: "src=\"cid:\(key)\"")
        }

        // The Visual-Meta appendix stays folded, as the reader folds it;
        // and a chaptered book says how much more it holds.
        var footer = "<style>#visual-meta { display: none; }</style>"
        if chapterPaths.count > 1 {
            footer += "<p style=\"text-align:center;color:#888888;font-style:italic;\">"
                + "First chapter of \(chapterPaths.count) — open the book to read on.</p>"
        }
        if let end = html.range(of: "</body>", options: [.caseInsensitive, .backwards]) {
            html = html.replacingCharacters(in: end, with: footer + "</body>")
        } else {
            html += footer
        }

        return Built(html: Data(html.utf8), title: title, attachments: attachments)
    }

    // MARK: Paths and lookups

    /// Zip entry by path, tolerant of percent-encoded hrefs.
    private func entry(_ path: String) -> Data? {
        zip.entry(path) ?? path.removingPercentEncoding.flatMap { zip.entry($0) }
    }

    private func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// Joins a base directory and a relative href, resolving "../".
    private func joined(_ base: String, _ relative: String) -> String {
        var parts = base.isEmpty ? [] : base.split(separator: "/").map(String.init)
        for piece in relative.split(separator: "/") {
            switch piece {
            case "..": if !parts.isEmpty { parts.removeLast() }
            case ".": continue
            default: parts.append(String(piece))
            }
        }
        return parts.joined(separator: "/")
    }

    private func imageType(for path: String) -> UTType? {
        switch (path as NSString).pathExtension.lowercased() {
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        case "gif": return .gif
        case "svg": return .svg
        case "webp": return .webP
        default: return nil
        }
    }

    private func decodedEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    // MARK: Regex helpers

    private func firstMatch(in text: String, pattern: String) -> String? {
        allMatches(in: text, pattern: pattern, group: 1).first
    }

    private func allMatches(in text: String, pattern: String, group: Int) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard group < match.numberOfRanges,
                  let r = Range(match.range(at: group), in: text) else { return nil }
            return String(text[r])
        }
    }
}

/// A minimal zip-in-memory reader — the app's ZipReader, freed of its
/// error type so the extension stays self-contained. Central directory
/// from the back, stored and DEFLATE entries only.
struct PreviewZipReader {

    private var entriesByName: [String: Data] = [:]

    func entry(_ name: String) -> Data? { entriesByName[name] }

    init(data: Data) throws {
        let minimumEOCD = 22
        guard data.count >= minimumEOCD else { throw EPUBPreviewError.notAnEPUB }
        var eocd: Int?
        var probe = data.count - minimumEOCD
        let lowest = max(0, data.count - 66_000)
        while probe >= lowest {
            if le32(data, probe) == 0x0605_4b50 { eocd = probe; break }
            probe -= 1
        }
        guard let eocd else { throw EPUBPreviewError.notAnEPUB }

        let count = Int(le16(data, eocd + 10))
        var offset = Int(le32(data, eocd + 16))
        for _ in 0..<count {
            guard offset + 46 <= data.count,
                  le32(data, offset) == 0x0201_4b50 else {
                throw EPUBPreviewError.corruptContainer
            }
            let method = Int(le16(data, offset + 10))
            let compressedSize = Int(le32(data, offset + 20))
            let uncompressedSize = Int(le32(data, offset + 24))
            let nameLength = Int(le16(data, offset + 28))
            let extraLength = Int(le16(data, offset + 30))
            let commentLength = Int(le16(data, offset + 32))
            let localOffset = Int(le32(data, offset + 42))
            let name = String(decoding: slice(data, offset + 46, nameLength), as: UTF8.self)

            guard localOffset + 30 <= data.count,
                  le32(data, localOffset) == 0x0403_4b50 else {
                throw EPUBPreviewError.corruptContainer
            }
            let localName = Int(le16(data, localOffset + 26))
            let localExtra = Int(le16(data, localOffset + 28))
            let start = localOffset + 30 + localName + localExtra
            guard start + compressedSize <= data.count else {
                throw EPUBPreviewError.corruptContainer
            }
            let raw = slice(data, start, compressedSize)

            switch method {
            case 0:
                entriesByName[name] = raw
            case 8:
                entriesByName[name] = try Self.inflated(raw, size: uncompressedSize)
            default:
                throw EPUBPreviewError.unsupportedCompression(method)
            }
            offset += 46 + nameLength + extraLength + commentLength
        }
    }

    private static func inflated(_ data: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { out -> Int in
            data.withUnsafeBytes { input -> Int in
                guard let outBase = out.bindMemory(to: UInt8.self).baseAddress,
                      let inBase = input.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_decode_buffer(outBase, size, inBase, data.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw EPUBPreviewError.corruptContainer }
        return output
    }

    private func le16(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private func le32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }

    private func slice(_ data: Data, _ offset: Int, _ length: Int) -> Data {
        let base = data.startIndex + offset
        return Data(data[base..<base + length])
    }
}
