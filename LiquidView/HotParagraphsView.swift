import SwiftUI

/// The most-cited paragraphs across the library — the sentences the
/// community keeps pointing at. Clicking one opens the document scrolled
/// to that paragraph with the flash highlight.
struct HotParagraphsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hotParagraphs = model.hotParagraphs
        List {
            ForEach(hotParagraphs) { hot in
                Button {
                    model.openInLibrary(hot.doc, fragment: hot.paragraph.id)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(hot.citations.count)")
                            .font(.headline.monospacedDigit())
                            .frame(minWidth: 24)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 4)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            .help(hot.citations.count == 1 ? "Cited by 1 document" : "Cited by \(hot.citations.count) documents")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hot.paragraph.displayText)
                                .lineLimit(3)
                            Text("\(hot.doc.title) · \(hot.doc.displayAuthor) · ¶\(hot.paragraph.id)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            citingLine(for: hot)
                        }
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Hot Paragraphs")
        .overlay {
            if hotParagraphs.isEmpty {
                ContentUnavailableView {
                    Label(model.searchText.isEmpty ? "No Cited Paragraphs" : "No Results",
                          systemImage: "quote.bubble")
                } description: {
                    Text("Paragraphs appear here once documents cite them directly (links with a fragment).")
                }
            }
        }
    }

    @ViewBuilder
    private func citingLine(for hot: HotParagraph) -> some View {
        let names = hot.citations
            .compactMap { model.index.byID[$0.fromID]?.doc.title }
        if !names.isEmpty {
            Text("Cited in: \(names.joined(separator: ", "))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}

extension HotParagraphsView {
    /// The Hot Paragraphs view as an exchangeable module.
    @MainActor static let module = LibraryViewModule(
        id: "hot-paragraphs",
        name: "Hot Paragraphs",
        systemImage: "quote.bubble",
        makeContent: { AnyView(HotParagraphsView()) }
    )
}
