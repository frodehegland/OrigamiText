import SwiftUI
import AppKit

/// A book opened just to look at — double-clicked from anywhere but the
/// community folder. The EPUB's own pages in the faithful WebView and
/// nothing else: no sidebar, no shelf record, no annotations, no trace
/// once the window closes. Import is the door to the library; this is
/// the window by it.
struct EPUBQuickViewScreen: View {
    let book: OpenEPUB
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    // The reader's own theme and type, so a look matches the reading.
    @AppStorage(AppSettings.readerThemeKey) private var themeRaw = ReaderTheme.highContrast.rawValue
    @AppStorage(AppSettings.readerBodyFontKey) private var bodyFont = ReaderStyle.defaultBodyFont
    @AppStorage(AppSettings.readerHeadingFontKey) private var headingFont = ReaderStyle.defaultHeadingFont
    @AppStorage(ThemeColorOverrides.tickKey) private var themeEditTick = 0

    @State private var chapterIndex = 0
    // The pinch answers with the contents here too — the same list the
    // reader's foot offers, in a look-only window without the foot.
    @State private var showsContents = false
    @State private var tocEntries: [OrigamiEPUBImporter.TOCEntry] = []
    @State private var requestedFragment: String?
    @State private var fragmentStamp = 0
    // A citation click answers with its card here too — a look-only
    // window still tells the reader what [1] names.
    @State private var citationCard: QuickViewCitation?

    private struct QuickViewCitation: Identifiable {
        let key: String
        var id: String { key }
    }

    // The reader's type values travel here too — a look matches the
    // reading's size and spacing, not only its theme.
    @AppStorage("readingFontDelta") private var fontDelta = 3.0
    @AppStorage("readingLineSpacing") private var lineSpacing = 3.0

    /// The reading's chosen theme — the page's colours, and the foot
    /// bar's, so a look wears one skin rather than a themed page above a
    /// system-grey bar. Edited theme colours apply live: every override
    /// write bumps the tick.
    private var theme: ReaderTheme {
        _ = themeEditTick
        return ReaderTheme(rawValue: themeRaw) ?? .highContrast
    }

    private var css: String {
        _ = themeEditTick
        return ReaderStyle.css(bodyFont: bodyFont, headingFont: headingFont,
                               theme: theme,
                               fontDelta: fontDelta, lineSpacing: lineSpacing)
    }

    private var currentContent: URL {
        book.chapters.indices.contains(chapterIndex)
            ? book.chapters[chapterIndex] : book.content
    }

    private func subpath(of url: URL) -> String {
        url.path.replacingOccurrences(of: book.base.path + "/", with: "")
    }

    var body: some View {
        VStack(spacing: 0) {
            reader
            // This window is a look, not a keeping: its unpack is deleted
            // the moment it closes. So the way to keep the book stands at
            // the foot, centred, in the lab's ember — unmissable, and in
            // a bar of its own rather than an overlay, so it never sits
            // over the words it is asking about. The bar wears the
            // reading's own theme, as the page above it does.
            // Only when there is a file to import: a button that cannot
            // do its one job should not be there at all.
            if book.sourceFile != nil {
                Divider()
                ImportToLibraryButton(book: book)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(theme.background(for: colorScheme)
                                ?? Color(nsColor: .windowBackgroundColor))
            }
        }
        .background(theme.background(for: colorScheme)
                    ?? Color(nsColor: .windowBackgroundColor))
    }

    private var reader: some View {
        EPUBReaderView(
            book: book,
            css: css,
            content: currentContent,
            chapterIndex: chapterIndex,
            chapterCount: book.chapters.count,
            onChapterStep: { delta in
                let next = chapterIndex + delta
                if book.chapters.indices.contains(next) { chapterIndex = next }
            },
            onPinchIn: { showsContents = true },
            onPinchOut: { showsContents = false },
            // A look-only window still unfolds notes: without this the
            // view's default resolver answers nil and every dagger reads
            // "The note could not be found."
            resolveEndnote: { id in model.endnoteText(inBook: book, id: id) },
            onCitation: { key, ref in
                let key = key.isEmpty ? ref : key
                if !key.isEmpty { citationCard = QuickViewCitation(key: key) }
            },
            requestedFragment: requestedFragment,
            fragmentStamp: fragmentStamp)
        .sheet(item: $citationCard) { citation in
            // The same card the reader shows, from the book's own
            // reference pool (or its Visual-Meta alone).
            if let doc = model.citationCardDoc(forBook: book) {
                CitationCardSheet(doc: doc, key: citation.key)
            } else {
                Text("The reference could not be read from this book.")
                    .foregroundStyle(.secondary)
                    .padding(30)
            }
        }
        // The contents cover the whole page, as the phone's pinch folds
        // the reading into its outline — not a popover, the document's
        // own map standing in for the document. Pinch out (or Escape,
        // or choosing an entry) returns to the reading.
        .overlay {
            if showsContents { contentsOverlay }
        }
        .frame(minWidth: 480, minHeight: 480)
    }

    private var contentsOverlay: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.title2.bold())
                    .padding(.bottom, 16)
                if tocEntries.isEmpty {
                    Text("This book carries no table of contents.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(tocEntries) { entry in
                        Button {
                            showsContents = false
                            if let index = book.chapters.firstIndex(where: {
                                subpath(of: $0) == entry.subpath
                            }) {
                                chapterIndex = index
                            }
                            requestedFragment = entry.fragment
                            fragmentStamp += 1
                        } label: {
                            Text(entry.label)
                                .font(.title3)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(48)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .simultaneousGesture(MagnifyGesture().onEnded { value in
            if value.magnification > 1.15 { showsContents = false }
        })
        .onExitCommand { showsContents = false }
        .onAppear {
            guard tocEntries.isEmpty,
                  let spine = OrigamiEPUBImporter.spine(inUnpackedFolder: book.base)
            else { return }
            tocEntries = OrigamiEPUBImporter.tocEntries(inUnpackedFolder: book.base,
                                                        spine: spine)
        }
    }
}

/// Cleans up after a quick-view window: deletes the temporary unpack and
/// tells the model to forget the window. Held strongly by the model for
/// the window's lifetime (NSWindow.delegate is weak).
final class EPUBQuickViewWindowDelegate: NSObject, NSWindowDelegate {
    /// The temporary unpack this window reads from — also what names the
    /// book (`quickview:<folder>`), so the model can find the window a
    /// given look belongs to.
    let root: URL
    var onClose: () -> Void = {}

    init(root: URL) {
        self.root = root
    }

    func windowWillClose(_ notification: Notification) {
        try? FileManager.default.removeItem(at: root)
        onClose()
    }
}

/// The look-only window's foot: an ember button, centred — a reader must
/// not close the window without noticing that the book was never kept.
/// The page and the bar wear the same reading theme, which is the point
/// of rendering it here: a themed page above a system-grey bar reads as
/// two windows badly joined.
#Preview("Import to Library", traits: .fixedLayout(width: 560, height: 300)) {
    let theme = ReaderTheme(rawValue: UserDefaults.standard
        .string(forKey: AppSettings.readerThemeKey) ?? "") ?? .highContrast
    let ink = theme.textColor(for: .light) ?? .primary
    let paper = theme.background(for: .light) ?? Color(nsColor: .textBackgroundColor)
    return VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 10) {
            Text("The Native Architecture of Reality")
                .font(.custom(ReaderStyle.defaultHeadingFont, size: 22).weight(.semibold))
            Text("…and so the last lines of a book being looked at, set in the reading's own type and colours, above the one thing it still needs.")
                .font(.custom(ReaderStyle.defaultBodyFont, size: 15))
        }
        .foregroundStyle(ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(34)
        .background(paper)
        Divider()
        ImportToLibraryButton(
            book: OpenEPUB(id: "quickview:preview", title: "A Book",
                           content: URL(fileURLWithPath: "/tmp/paper.html"),
                           base: URL(fileURLWithPath: "/tmp"),
                           // A book being looked at names its own file —
                           // which is what makes the offer appear at all.
                           sourceFile: URL(fileURLWithPath: "/tmp/a-book.epub")))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(paper)
    }
    .environment(AppModel())
}
