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

    private var css: String {
        _ = themeEditTick
        return ReaderStyle.css(bodyFont: bodyFont, headingFont: headingFont,
                               theme: ReaderTheme(rawValue: themeRaw) ?? .highContrast)
    }

    var body: some View {
        EPUBReaderView(
            book: book,
            css: css,
            content: book.chapters.indices.contains(chapterIndex)
                ? book.chapters[chapterIndex] : book.content,
            chapterIndex: chapterIndex,
            chapterCount: book.chapters.count,
            onChapterStep: { delta in
                let next = chapterIndex + delta
                if book.chapters.indices.contains(next) { chapterIndex = next }
            })
        .frame(minWidth: 480, minHeight: 480)
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
