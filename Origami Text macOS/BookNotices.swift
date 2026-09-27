#if os(macOS)
import SwiftUI

/// A quiet strip above the reading when the book has something to say
/// for itself: a profile newer than this reader (§16.2) or records that
/// describe another publication (§17.1); a colophon that disagrees with
/// its metadata (§8.4.6 asks that it be reported); and company among the
/// editions of its work
/// (§4.3) — a newer edition in the library, and the reader's notes made
/// on another edition. Those notes
/// attach exactly to the edition they were made on; here they are an
/// inference (§6.4), so they are listed apart — each saying whether its
/// words were found in this edition — and never painted as this
/// edition's own.
struct BookNotices: View {
    @Environment(AppModel.self) private var model
    let book: OpenEPUB

    @State private var showsNotes = false

    private var record: EPUBRecord? {
        model.epubRecords.first { $0.folder == book.id }
    }

    var body: some View {
        // Nothing is read on the main thread: until the background checks
        // land, the strip waits, then appears.
        if let record, !model.bookChecksReady(for: record) {
            Color.clear.frame(height: 0)
                .task(id: record.folder) { model.prefetchBookChecks(for: record) }
        } else if let record {
            let newer = model.newerEdition(of: record)
            let notes = model.earlierEditionAnnotations(for: record)
            let colophon = model.colophonCheck(for: record)
            let disagreement = colophon.flatMap { $0.verified ? nil : $0 }
            let profile = model.profileCheck(for: record)
            let newerProfile = profile?.newerThanReader == true
            let untrusted = profile?.untrustedRecords ?? []
            let unreadable = model.unreadableChapters[book.id] ?? 0
            if newer != nil || !notes.isEmpty || disagreement != nil || newerProfile
                || !untrusted.isEmpty || unreadable > 0 {
                HStack(spacing: 14) {
                    Image(systemName: "square.stack.3d.up")
                        .foregroundStyle(.secondary)
                    if unreadable > 0 {
                        // Never a silently shorter book.
                        Label(unreadable == 1
                              ? "One chapter could not be laid out for the reading styles; Scrolling shows the whole book."
                              : "\(unreadable) chapters could not be laid out for the reading styles; Scrolling shows the whole book.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if newerProfile {
                        // §16.2: said plainly, and read as an ordinary EPUB.
                        Label("This book follows Origami profile \(profile?.declaredVersion ?? "?"), newer than this version of Origami Text knows. It is read as an ordinary EPUB.",
                              systemImage: "info.circle")
                    }
                    if !untrusted.isEmpty {
                        // §17.1: a record naming another publication is
                        // untrusted, and the reader says so.
                        Label("This book\u{2019}s \(untrusted.joined(separator: " and ")) says it describes a different publication; its metadata may not belong to this book.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if let disagreement {
                        Label("The printed colophon disagrees with the book\u{2019}s metadata: \(disagreement.disagreements.joined(separator: ", ")). The metadata is used.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if let newer {
                        Text("A newer edition of this work is in your library\(label(for: newer)).")
                        Button("Open Newer Edition") { model.openStoredEPUB(newer) }
                            .buttonStyle(.link)
                        Button("Compare Side by Side") {
                            model.sideBySide = SideBySideRequest(left: record.folder, right: newer.folder)
                        }
                        .buttonStyle(.link)
                    }
                    if !notes.isEmpty {
                        Text(notes.count == 1 ? "1 of your notes is on another edition."
                                              : "\(notes.count) of your notes are on another edition.")
                        Button("Show") { showsNotes = true }
                            .buttonStyle(.link)
                    }
                    Spacer(minLength: 0)
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.bar)
                .sheet(isPresented: $showsNotes) {
                    EditionNotesSheet(book: book, record: record, notes: notes)
                }
            }
        }
    }

    private func label(for edition: EPUBRecord) -> String {
        guard let info = model.editionInfo(for: edition) else { return "" }
        if let version = info.versionLabel { return " (\(version))" }
        if let modified = info.modified { return " (\(modified.prefix(10)))" }
        return ""
    }
}

/// The notes from other editions, each with where it lands here — found
/// by its words (inferred) or not found — and the edition it belongs to.
private struct EditionNotesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let book: OpenEPUB
    let record: EPUBRecord
    let notes: [(edition: EPUBRecord, annotation: WebAnnotation)]

    var body: some View {
        let doc = model.readingDoc(forBook: book)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Notes from Other Editions").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Text("These were made on another edition of this work. Where their words are found in this edition they are placed by inference, not attached exactly.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            Divider()
            List(Array(notes.enumerated()), id: \.offset) { _, entry in
                let resolution = doc.flatMap { AnnotationAnchor.resolve(entry.annotation, in: $0) }
                VStack(alignment: .leading, spacing: 4) {
                    if let quote = entry.annotation.quotedText, !quote.isEmpty {
                        Text("\u{201C}\(quote)\u{201D}").lineLimit(3)
                    }
                    if let note = entry.annotation.body?.value, !note.isEmpty {
                        Text(note).foregroundStyle(.secondary).lineLimit(3)
                    }
                    HStack {
                        Label(resolution == nil ? "Not found in this edition"
                                                : "Found here \u{2014} inferred",
                              systemImage: resolution == nil ? "questionmark.circle" : "arrow.triangle.branch")
                            .foregroundStyle(resolution == nil ? .orange : .secondary)
                        Text("from \u{201C}\(entry.edition.title)\u{201D}")
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        Spacer()
                        if let resolution {
                            Button("Go") {
                                dismiss()
                                model.openEPUB(address: record.id, fragment: resolution.paragraphID)
                            }
                        }
                        Button("Open in Its Edition") {
                            dismiss()
                            let fragment = entry.annotation.target.selectors.compactMap { selector -> String? in
                                if case .fragment(let value, _) = selector { return value }
                                return nil
                            }.first
                            model.openEPUB(address: entry.edition.id, fragment: fragment)
                        }
                    }
                    .font(.caption)
                }
                .padding(.vertical, 4)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}
#endif
