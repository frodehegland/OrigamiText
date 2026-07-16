import SwiftUI

// Visible transclusion as stretchtext, in honor of Ted Nelson: each
// citation carries a small ⧉ mark directly after it in the text stream.
// Clicking unfolds the cited passage in place — quoted live from the
// source document, with provenance — and clicking again folds it away.

extension LiquidDoc.Paragraph {
    /// The paragraph text with a stretchtext mark (⧉) inserted directly
    /// after each citation. The mark is an inline link on the private
    /// origamitext-transclude scheme, so it flows with the line like a character.
    nonisolated func renderedTextWithTransclusionMarks(excluding documentID: String,
                                                       expandedKeys: Set<String>) -> AttributedString {
        var attributed = renderedText
        let plain = String(attributed.characters)
        let marks = LiquidAddress.matches(in: plain)
            .filter { $0.id != documentID && !LiquidAddress.isPersonAddress($0.id) }
            .sorted { $0.range.location > $1.range.location }   // insert back-to-front
        for match in marks {
            guard let range = Range(match.range, in: attributed) else { continue }
            var urlString = "origamitext-transclude://\(match.id)/\(id)"
            if let fragment = match.fragment { urlString += "#\(fragment)" }
            guard let url = URL(string: urlString) else { continue }
            let key = "\(id)|\(match.id)#\(match.fragment ?? "")"
            var glyph = AttributedString("\u{2009}⧉")
            glyph.link = url
            glyph.font = .system(size: 12)
            glyph.foregroundColor = expandedKeys.contains(key) ? .primary : .secondary
            attributed.insert(glyph, at: range.upperBound)
        }
        return attributed
    }
}

/// The unfolded passage: shown beneath the citing paragraph while its
/// stretchtext mark is open.
struct TransclusionQuoteView: View {
    @Environment(AppModel.self) private var model
    let match: AddressMatch

    var body: some View {
        Group {
            if let entry = model.resolve(target: match.id, rel: nil) {
                quotation(for: entry)
            } else {
                Text("“\(match.id)” is not in the community folder yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    @ViewBuilder
    private func quotation(for entry: IndexEntry) -> some View {
        let quoted = quotedParagraphs(for: entry)
        VStack(alignment: .leading, spacing: 8) {
            if quoted.isEmpty {
                Text(match.fragment == nil
                     ? "This document has no text body to quote."
                     : "Paragraph “\(match.fragment ?? "")” was not found; it may have changed in a revision.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(quoted) { paragraph in
                    Text(paragraph.renderedText)
                        .font(.system(size: 15, design: .serif))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
            }
            Button {
                model.open(entry.doc, fragment: match.fragment)
            } label: {
                Text("— \(entry.doc.title) · \(entry.doc.displayAuthor), \(entry.doc.date?.yearText ?? entry.doc.created.formatted(.dateTime.year()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open the source document")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor.opacity(0.7))
                .frame(width: 3)
                .padding(.vertical, 6)
                .padding(.leading, 3)
        }
    }

    /// The passage to transclude: the addressed paragraph, or the opening
    /// paragraph when the citation addresses the whole document.
    private func quotedParagraphs(for entry: IndexEntry) -> [LiquidDoc.Paragraph] {
        guard let body = entry.doc.body else { return [] }
        if let fragment = match.fragment {
            return body.first(where: { $0.id == fragment }).map { [$0] } ?? []
        }
        return body.first.map { [$0] } ?? []
    }
}
