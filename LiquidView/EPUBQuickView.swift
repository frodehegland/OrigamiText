import SwiftUI
import AppKit

/// A book opened just to look at — double-clicked from anywhere but the
/// community folder. The EPUB's own pages in the faithful WebView and
/// nothing else: no sidebar, no shelf record, no annotations, no trace
/// once the window closes. Import is the door to the library; this is
/// the window by it.
struct EPUBQuickViewScreen: View {
    let book: OpenEPUB

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

    private var css: String {
        _ = themeEditTick
        return ReaderStyle.css(bodyFont: bodyFont, headingFont: headingFont,
                               theme: ReaderTheme(rawValue: themeRaw) ?? .highContrast)
    }

    private var currentContent: URL {
        book.chapters.indices.contains(chapterIndex)
            ? book.chapters[chapterIndex] : book.content
    }

    private func subpath(of url: URL) -> String {
        url.path.replacingOccurrences(of: book.base.path + "/", with: "")
    }

    var body: some View {
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
            requestedFragment: requestedFragment,
            fragmentStamp: fragmentStamp)
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
    private let root: URL
    var onClose: () -> Void = {}

    init(root: URL) {
        self.root = root
    }

    func windowWillClose(_ notification: Notification) {
        try? FileManager.default.removeItem(at: root)
        onClose()
    }
}
