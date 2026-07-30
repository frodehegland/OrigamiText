import SwiftUI
import WebKit

/// One open EPUB, rendered faithfully from its own content document.
/// `content` is paper.html on disk; `base` is the unpacked package root the
/// WebView is allowed to read, so relative images and style.css resolve.
struct OpenEPUB: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let content: URL
    let base: URL
}

/// A remembered EPUB in the reader's library: enough to list it (title,
/// author, date) and to reopen its rendered page (the unpacked `folder`
/// under the app container's EPUBs directory, and the content document's
/// path within it). Persisted to an internal manifest — no JSON document
/// is written, per the EPUB-only direction.
struct EPUBRecord: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let author: String
    /// ISO 8601, when the Visual-Meta carried a date.
    let dateISO: String?
    /// The unpack folder name under the EPUBs directory.
    let folder: String
    /// The content document's path within `folder`, e.g. "content/paper.html".
    let contentSubpath: String
    /// When it was opened, for ordering the library newest-first.
    let openedAt: Date
}

/// A semantic element the reader's WebView reported — the Step 0 bridge.
/// `kind` is the format's own type (equation, citation, concept, heading,
/// paragraph); `id` is the element id / address; `text` is a short excerpt.
/// Everything richer (view-spec, stretchtext, select-and-act) is built on
/// this round trip.
struct EPUBElementRef: Hashable, Sendable {
    let kind: String
    let id: String
    let text: String
}

/// A reading theme: the page's background and text colours, applied as CSS
/// over the EPUB's own styling. Light/dark are handled with a
/// `prefers-color-scheme` block so a theme follows the system appearance.
enum ReaderTheme: String, CaseIterable, Identifiable, Sendable {
    case highContrast
    case sepia
    case grey

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .highContrast: "High Contrast"
        case .sepia: "Sepia"
        case .grey: "Grey"
        }
    }

    /// The CSS injected for this theme; empty for High Contrast, which
    /// leaves the EPUB's own crisp black-on-white as-is. Text colour is set
    /// on `body`, so headings inherit it (no separate heading colour yet).
    var css: String {
        switch self {
        case .highContrast:
            return ""
        case .sepia:
            return themeCSS(lightBackground: "#eee2cc", lightText: "#32281d",
                            darkBackground: "#393329", darkText: "#ede3d3")
        case .grey:
            return themeCSS(lightBackground: "#dddddd", lightText: "#272727",
                            darkBackground: "#3f3f3f", darkText: "#dddddd")
        }
    }

    private func themeCSS(lightBackground: String, lightText: String,
                          darkBackground: String, darkText: String) -> String {
        """
        :root { color-scheme: light dark; }
        html, body { background-color: \(lightBackground); color: \(lightText); }
        @media (prefers-color-scheme: dark) {
          html, body { background-color: \(darkBackground); color: \(darkText); }
        }
        """
    }
}

/// Assembles the full CSS the reader injects: links in the body colour
/// (never browser blue), the user's chosen body and heading fonts, then the
/// theme's colours. One string so theme and fonts switch together, live.
enum ReaderStyle {
    static let defaultBodyFont = "Times New Roman"
    static let defaultHeadingFont = "Georgia"

    static func css(bodyFont: String, headingFont: String, theme: ReaderTheme) -> String {
        """
        a, a:link, a:visited { color: inherit; }
        body { font-family: \(family(bodyFont, fallback: "'Times New Roman', Times, serif")); }
        h1, h2, h3, h4, h5, h6 { font-family: \(family(headingFont, fallback: "Georgia, serif")); }
        \(theme.css)
        """
    }

    private static func family(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : "\"\(trimmed)\", \(fallback)"
    }
}

/// The rendered EPUB with its chrome: a thin bar naming the book and the
/// way back. The Visual-Meta toggle lives inline in the page itself (a
/// centered button where the appendix sits), not up here.
struct EPUBReaderScreen: View {
    @AppStorage(AppSettings.readerThemeKey) private var themeRaw = ReaderTheme.highContrast.rawValue
    @AppStorage(AppSettings.readerBodyFontKey) private var bodyFont = ReaderStyle.defaultBodyFont
    @AppStorage(AppSettings.readerHeadingFontKey) private var headingFont = ReaderStyle.defaultHeadingFont
    @Environment(AppModel.self) private var model
    let book: OpenEPUB
    var onClose: () -> Void

    private var theme: ReaderTheme { ReaderTheme(rawValue: themeRaw) ?? .highContrast }

    /// Windowed reading is always High Contrast with the default fonts; the
    /// chosen theme and fonts apply only in full screen — the focused
    /// reading mode where personalization belongs.
    private var readerCSS: String {
        if model.isFullScreen {
            return ReaderStyle.css(bodyFont: bodyFont, headingFont: headingFont, theme: theme)
        }
        return ReaderStyle.css(bodyFont: ReaderStyle.defaultBodyFont,
                               headingFont: ReaderStyle.defaultHeadingFont,
                               theme: .highContrast)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Full focus (full screen) is bare: just the page. The title
            // bar and Close return when the window is not full screen.
            if !model.isFullScreen {
                HStack(spacing: 10) {
                    Text(book.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        onClose()
                    } label: {
                        Label("Close", systemImage: "xmark")
                    }
                    .help("Close this EPUB")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                Divider()
            }
            EPUBReaderView(
                book: book,
                css: readerCSS,
                // Step 0 substrate: for now, clicking a semantic element
                // names it and selecting text records the selection. Real
                // behaviours (furl/unfurl, stretchtext, select-and-act) plug
                // in here next.
                onActivate: { ref in
                    model.showNote("\(ref.kind.capitalized)\(ref.id.isEmpty ? "" : " · \(ref.id)")")
                },
                onSelect: { text in
                    model.lastEPUBSelection = text
                },
                onCopyQuote: { text in copyAsQuote(text) })
        }
    }

    /// Builds a three-flavour citation from the selection and the open book's
    /// stored metadata, then writes it to the clipboard — the same "Copy as
    /// Quote" that the document reader offers, now reachable in the EPUB's own
    /// context menu. The address is the book's Origami id; paragraph-scoped
    /// fragments are a later step.
    private func copyAsQuote(_ text: String) {
        guard !text.isEmpty else { return }
        let record = model.epubRecords.first { $0.folder == book.id }
        let citation = OrigamiCitation(
            to: record?.id ?? book.id,
            fragment: nil,
            rel: "cites",
            quotedText: text,
            author: record?.author ?? "",
            year: record?.dateISO.map { String($0.prefix(4)) } ?? "",
            bibtex: nil)
        CitationClipboard.write(citation)
        model.showNote("Copied as quote")
    }
}

/// Renders an EPUB's own `paper.html` + `style.css` in a `WKWebView` —
/// headings, sub-headings, images, tables, lists, and formatting exactly as
/// authored. The Visual-Meta appendix starts hidden, with a centered
/// "Metadata" button injected inline in the page to reveal it.
struct EPUBReaderView: NSViewRepresentable {
    let book: OpenEPUB
    /// The reader styling (link colour, fonts, theme colours) as one CSS
    /// string, injected over the EPUB's own stylesheet.
    var css: String = ""
    /// A semantic element was clicked (Step 0 bridge).
    var onActivate: (EPUBElementRef) -> Void = { _ in }
    /// The reader's text selection changed (empty string when cleared).
    var onSelect: (String) -> Void = { _ in }
    /// "Copy as Quote" was chosen from the page's context menu, carrying the
    /// selected text. The screen builds the citation from the book's metadata.
    var onCopyQuote: (String) -> Void = { _ in }

    /// The message channel name the injected bridge posts to.
    private static let bridgeName = "origami"

    /// Installs the document scripts: theme + appendix-hide before paint,
    /// then the metadata toggle button and the Step 0 semantic bridge.
    private static func installUserScripts(into controller: WKUserContentController, themeCSS: String) {
        controller.addUserScript(WKUserScript(source: themeScript(css: themeCSS),
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: hideScript,
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: toggleButtonScript,
                                              injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: bridgeScript,
                                              injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        Self.installUserScripts(into: controller, themeCSS: css)
        controller.add(context.coordinator, name: Self.bridgeName)
        context.coordinator.themeCSS = css

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = ReaderWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = false
        // The subclass owns the page's context menu; it calls back through
        // the coordinator so the latest closure (and book) is always used.
        webView.onCopyQuote = { [weak coordinator = context.coordinator] text in
            coordinator?.onCopyQuote(text)
        }
        context.coordinator.webView = webView
        load(into: webView, context: context)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onActivate = onActivate
        context.coordinator.onSelect = onSelect
        context.coordinator.onCopyQuote = onCopyQuote
        if context.coordinator.loadedID != book.id {
            context.coordinator.themeCSS = css
            load(into: webView, context: context)
            return
        }
        // A theme or font change: re-inject the style live, no reload, so the
        // reader's scroll position holds.
        if context.coordinator.themeCSS != css {
            context.coordinator.themeCSS = css
            let controller = webView.configuration.userContentController
            controller.removeAllUserScripts()
            Self.installUserScripts(into: controller, themeCSS: css)
            webView.evaluateJavaScript(Self.themeScript(css: css))
        }
    }

    private func load(into webView: WKWebView, context: Context) {
        context.coordinator.onActivate = onActivate
        context.coordinator.onSelect = onSelect
        context.coordinator.loadedID = book.id
        webView.loadFileURL(book.content, allowingReadAccessTo: book.base)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var loadedID: String?
        var themeCSS: String = ""
        var onActivate: (EPUBElementRef) -> Void = { _ in }
        var onSelect: (String) -> Void = { _ in }
        var onCopyQuote: (String) -> Void = { _ in }
        weak var webView: ReaderWebView?

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            switch body["event"] as? String {
            case "activate":
                onActivate(EPUBElementRef(
                    kind: body["kind"] as? String ?? "element",
                    id: body["id"] as? String ?? "",
                    text: body["text"] as? String ?? ""))
            case "selection":
                let text = body["text"] as? String ?? ""
                // The subclass reads this when the page's menu opens, to
                // decide whether to offer "Copy as Quote".
                webView?.selectedText = text
                onSelect(text)
            default:
                break
            }
        }
    }

    /// Injects (or updates) the theme's `<style id="origami-theme">` with the
    /// given CSS. Runs both at document start (before paint) and live on a
    /// theme change. The CSS goes in a template literal — it carries no
    /// backticks or `${`, so it needs no escaping.
    private static func themeScript(css: String) -> String {
        """
        (function(){
          var s = document.getElementById('origami-theme') || document.createElement('style');
          s.id = 'origami-theme';
          s.textContent = `\(css)`;
          (document.head || document.documentElement).appendChild(s);
        })();
        """
    }

    /// Hides the appendix before first paint.
    private static let hideScript = """
    (function(){
      var s = document.getElementById('origami-vm-style') || document.createElement('style');
      s.id = 'origami-vm-style';
      s.textContent = '#visual-meta{display:none;}';
      (document.head || document.documentElement).appendChild(s);
    })();
    """

    /// Inserts a horizontally-centered toggle button in the document flow,
    /// just before the Visual-Meta appendix. Hidden by default, it reads
    /// "Metadata"; revealed, it reads "Hide Metadata".
    private static let toggleButtonScript = """
    (function(){
      var vm = document.getElementById('visual-meta');
      if (!vm || document.getElementById('origami-vm-toggle')) return;
      var btn = document.createElement('button');
      btn.id = 'origami-vm-toggle';
      btn.type = 'button';
      btn.textContent = 'Metadata';
      btn.style.cssText = 'display:block;margin:2em auto;padding:0.4em 1.2em;font:inherit;'
        + 'cursor:pointer;border:1px solid currentColor;border-radius:6px;'
        + 'background:transparent;color:inherit;opacity:0.7;';
      btn.addEventListener('click', function(){
        var hidden = (vm.style.display === 'none' || vm.style.display === '');
        vm.style.display = hidden ? 'block' : 'none';
        btn.textContent = hidden ? 'Hide Metadata' : 'Metadata';
      });
      vm.parentNode.insertBefore(btn, vm);
    })();
    """

    /// The Step 0 bridge. One delegated click listener classifies the
    /// nearest semantic ancestor by the format's own markup and posts its
    /// kind + id to Swift; a mouseup listener reports any non-empty text
    /// selection. This is the substrate the reader's real interactions
    /// (view specification, stretchtext, select-and-act) will be built on.
    private static let bridgeScript = """
    (function(){
      function classify(el){
        while (el && el !== document.body) {
          var tag = el.tagName ? el.tagName.toLowerCase() : '';
          if (tag === 'math' && el.id) return {kind:'equation', id:el.id};
          if (tag === 'a' && (el.className || '').indexOf('citation') >= 0)
            return {kind:'citation', id: el.getAttribute('data-origami-ref')
              || el.getAttribute('data-citation-id') || el.id || ''};
          if (tag === 'dfn') return {kind:'concept', id: el.id || ''};
          if (/^h[1-6]$/.test(tag) && el.id) return {kind:'heading', id: el.id};
          if ((tag === 'p' || tag === 'li') && el.id) return {kind:'paragraph', id: el.id};
          el = el.parentElement;
        }
        return null;
      }
      var bridge = window.webkit && window.webkit.messageHandlers
        && window.webkit.messageHandlers.origami;
      if (!bridge) return;
      document.addEventListener('click', function(e){
        var info = classify(e.target);
        if (!info) return;
        var text = (e.target.textContent || '').trim().slice(0, 200);
        bridge.postMessage({event:'activate', kind:info.kind, id:info.id, text:text});
      }, true);
      document.addEventListener('mouseup', function(){
        var sel = window.getSelection ? String(window.getSelection()) : '';
        // Report every mouseup, empty included, so the native "Copy as
        // Quote" item appears only while text is actually selected.
        bridge.postMessage({event:'selection', text: sel.trim().slice(0, 500)});
      }, false);
    })();
    """
}

/// The EPUB reader's `WKWebView`, with a context menu we own completely.
/// The rendered page is a real web view with its own AppKit menu, so the
/// SwiftUI `.contextMenu` never reaches it; instead `willOpenMenu` clears
/// WebKit's default items and builds ours from scratch. This is the one
/// place to add, remove, or reorder what appears on ctrl-click in an EPUB.
final class ReaderWebView: WKWebView {
    /// The page's current selection, kept current by the Step 0 bridge's
    /// mouseup reports (see `bridgeScript`).
    var selectedText: String = ""
    /// Invoked with the selected text when "Copy as Quote" is chosen.
    var onCopyQuote: (String) -> Void = { _ in }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        // Take full ownership: drop everything WebKit proposes (Reload,
        // Back/Forward, Look Up, …) and show only our own commands.
        menu.removeAllItems()
        // Services, Share, and "Ask Siri" are contextual-menu plug-in items
        // AppKit appends *after* this method returns, so removeAllItems can't
        // reach them. Turning off plug-ins keeps them off the menu.
        menu.allowsContextMenuPlugIns = false

        let text = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            addItem(to: menu, title: "Copy as Quote", action: #selector(copyAsQuote(_:)))
            addItem(to: menu, title: "Copy", action: #selector(copySelection(_:)))
        }
        // With no selection the menu is intentionally empty, so nothing
        // extraneous appears. New commands (Define, Copy Link, Add to
        // Concepts, …) go here.
    }

    private func addItem(to menu: NSMenu, title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func copyAsQuote(_ sender: Any?) {
        onCopyQuote(selectedText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Plain "Copy" of the current selection — WebKit's own copy, so rich
    /// text and formatting come along, not just the plain string.
    @objc private func copySelection(_ sender: Any?) {
        evaluateJavaScript("document.execCommand('copy')")
    }
}
