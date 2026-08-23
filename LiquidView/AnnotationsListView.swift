import SwiftUI

/// Views ▸ Annotations: every annotation across every book — the
/// reader's own layer over the library. Each is a W3C Web Annotation
/// (the Hypothesis model), held in a JSON-LD sidecar beside the
/// unpacked books, never inside them: the book is the author's, the
/// annotations are the reader's.
///
/// Grouped by book, the most recently annotated book first. Find (at
/// the foot of the list) searches across every document at once — the
/// quoted words, the notes, and the books' titles. Click an annotation
/// to open its book at the very words, by the same anchoring ladder
/// the reader paints highlights with.
struct AnnotationsListView: View {
    @Environment(AppModel.self) private var model

    private struct BookGroup: Identifiable {
        let address: String
        let title: String
        let items: [AppModel.LibraryAnnotation]
        var id: String { address }
    }

    /// The annotations Find leaves standing, grouped by book — the
    /// group order follows each book's newest annotation.
    private var groups: [BookGroup] {
        let query = model.searchText.trimmingCharacters(in: .whitespaces)
        let shown = model.allAnnotations.filter { item in
            guard !query.isEmpty else { return true }
            let haystack = [item.exact,
                            item.annotation.body?.value,
                            item.annotation.creator?.name,
                            bookTitle(for: item.address)]
                .compactMap { $0 }
                .joined(separator: " ")
            return haystack.localizedCaseInsensitiveContains(query)
        }
        var order: [String] = []
        var byAddress: [String: [AppModel.LibraryAnnotation]] = [:]
        for item in shown {   // already newest first
            if byAddress[item.address] == nil { order.append(item.address) }
            byAddress[item.address, default: []].append(item)
        }
        return order.map { address in
            BookGroup(address: address,
                      title: bookTitle(for: address),
                      items: byAddress[address] ?? [])
        }
    }

    private func bookTitle(for address: String) -> String {
        model.epubRecord(forAddress: address)?.title ?? address
    }

    var body: some View {
        List {
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.items) { item in
                        row(for: item)
                    }
                }
            }
        }
        .overlay {
            if groups.isEmpty {
                if model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView {
                        Label("No Annotations Yet", systemImage: "highlighter")
                    } description: {
                        Text("Select words in a book and highlight or comment — your annotations live beside the books, never inside them, and gather here across the whole library.")
                    }
                } else {
                    ContentUnavailableView(
                        "No Matching Annotations",
                        systemImage: "magnifyingglass")
                }
            }
        }
    }

    private func row(for item: AppModel.LibraryAnnotation) -> some View {
        Button {
            model.openAnnotation(item)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon(for: item.annotation.motivation))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    if let exact = item.exact {
                        Text("“\(exact)”")
                            .italic()
                            .lineLimit(3)
                    }
                    if let note = item.annotation.body?.value, !note.isEmpty {
                        Text(note)
                            .lineLimit(3)
                    }
                    Text(item.annotation.created.formatted(date: .abbreviated,
                                                           time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Remove Annotation", role: .destructive) {
                model.removeAnnotation(id: item.annotation.id, address: item.address)
            }
        }
    }

    private func icon(for motivation: String) -> String {
        switch motivation {
        case WebAnnotation.Motivation.commenting: "text.bubble"
        case WebAnnotation.Motivation.tagging: "tag"
        default: "highlighter"
        }
    }
}
