import SwiftUI
import AppKit

@main
struct LiquidViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        // macOS 27 escalates a display-cycle layout exception to abort()
        // via +[NSApplication _crashOnException:] — and its own
        // NavigationSplitView throws one on the first constraints pass
        // after a remount (SizeConstraints.update → invalidateLayout →
        // setNeedsUpdate, mid-flush), which the full-screen exit cannot
        // avoid. Opting out restores AppKit's log-and-continue: the
        // exception is a redundant needs-layout request, recoverable.
        // Every structural cause we control (move transitions over
        // platform views, dynamic column widths, animated swaps) is
        // already removed; this is the net under the OS regression.
        UserDefaults.standard.set(false, forKey: "NSApplicationCrashOnExceptions")
    }

    var body: some Scene {
        WindowGroup("Origami Text", id: "main") {
            ZStack {
                ContentView()
                MainWindowConnector()
            }
            .background(MainNSWindowCapture())
            // A file open (or any external event) lands in THIS window —
            // without the preference, SwiftUI opened a fresh library
            // window per double-clicked EPUB; hidden or stacked, they
            // accumulated across sessions, each holding a live reader
            // that reloaded the book on every navigation.
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            .environment(model)
            .onOpenURL { model.handleURL($0) }
            .task {
                appDelegate.model = model
                model.restoreFolderAccess()
                model.restoreReaderLibrary()
                #if DEBUG
                model.runFormatSelfTestIfRequested()
                #endif
            }
            .background(TabBarRemover())
        }
        .defaultSize(width: 1240, height: 864)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Origami Text") { showAboutPanel() }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Document") { model.newDraft() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Note") { model.newNote() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Book") { model.newBook() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("New Author") { model.newAuthor = Person() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
            }
            CommandGroup(after: .newItem) {
                Button("Open…") { model.openDocumentFile() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Import…") { model.importDocumentFile() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                // A paper that is free to read, brought in as a
                // document rather than as a page — see FetchOnline.
                Button("Fetch by DOI or URL…") { model.fetchOnlineDocumentPrompt() }
                Button("Import Reference Dataset…") { model.importReferenceDatasetPanel() }
                // The second half of the workflow: a paper written in
                // Author and exported as an Origami EPUB is rendered here
                // in a publisher's format.
                Button("Import to Format…") { model.importEPUBToFormat() }
                // A capsule's page, read here: gemtext is another
                // hypermedia protocol the reader speaks.
                Button("Open Gemini URL…") { model.openGeminiURLPrompt() }
                Button("Export to XR (Author Map)…") { model.showXRExport = true }
                Button("Export Library Manifest…") { model.exportLibraryManifest() }
                Divider()
                Button("Choose Community Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            // Where paper meets the app, as in Knowledge Space: the
            // camera reads a printed page and opens its document at
            // that place.
            PageCaptureCommands()
            // Edit ▸ Edit Document… — the Editor reached without the
            // shelf. Publisher builds only, and only with Editor Mode
            // on, exactly as the book's context-menu entry.
            #if DEBUG || EDITOR
            EditorCommands(model: model)
            #endif
            CommandGroup(replacing: .saveItem) {
                // Replacing .saveItem also removes the system Close item,
                // so it is restored here — Settings and every other window
                // need ⌘W. In the main window with a just-opened document
                // being written, ⌘W closes that editor and goes back one
                // instead of taking the whole window with it.
                Button("Close") {
                    if model.draftEditor != nil,
                       let key = NSApp.keyWindow, key == NSApp.mainWindow {
                        model.closeEditor()
                    } else {
                        NSApp.keyWindow?.performClose(nil)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
                Divider()
                Button("Save") { model.saveDraft() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.draftEditor?.hasUnsavedChanges != true)
                Button("Export…") { model.exportDraft() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.draftEditor == nil)
                Button("Export as Gemtext (.gmi)…") { model.exportGemtextFront() }
            }
            // The window toolbar is bare, as in Knowledge Space — these
            // menu items are where its former controls live on.
            CommandGroup(after: .windowArrangement) {
                Button(model.isListHidden ? "Show Documents" : "Hide Documents") {
                    model.toggleListColumn()
                }
                Button(model.showLinksInspector ? "Hide Links Panel" : "Show Links Panel") {
                    model.showLinksInspector.toggle()
                }
                .keyboardShortcut("l", modifiers: [.option, .command])
                Divider()
                Picker("Sort By", selection: Bindable(model).sortOrder) {
                    ForEach(ListSortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                Toggle("Show Superseded", isOn: Bindable(model).showSuperseded)
                Divider()
            }
            // The reading's View-menu verbs: Flow (⌘⇧F) and the colour
            // views, fold/unfold (⌘−/⌘+), and the type (⇧⌘±, ⌥⌘±) —
            // answered by the front reading.
            ReadingCommands(model: model)
            // The Liquid verb, in this app's own menus: a phrase from
            // the clipboard (or typed) found in everything one has read.
            ReadingSearchCommands(model: model)
            LibraryWindowCommands(model: model)
            CommandMenu("Go") {
                Button("Back") { model.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!model.canGoBack)
                Button("Forward") { model.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!model.canGoForward)
                Divider()
                Menu("Read in Parallel") {
                    if model.parallelDoc != nil {
                        Button("Exit Parallel Reading") { model.exitParallel() }
                        Divider()
                    }
                    ForEach(model.parallelCandidates) { entry in
                        Button(entry.doc.title) { model.enterParallel(with: entry.doc) }
                    }
                }
                .disabled(model.current == nil
                          || (model.parallelCandidates.isEmpty && model.parallelDoc == nil))
            }
        }

        // A lifted document annotation: its own window, titled with the
        // article, room to write while the main window reads anything —
        // Save still lands on the original document.
        WindowGroup("Annotation", for: LiftedAnnotation.self) { $target in
            if let target {
                LiftedAnnotationWindow(target: target)
                    .environment(model)
            }
        }
        .defaultSize(width: 560, height: 440)

        // A figure lifted from a jump link: the image in its own
        // window, beside the reading, closed when the reader is done —
        // several can stand open at once.
        WindowGroup("Figure", for: FigureWindowValue.self) { $target in
            if let target {
                FigureWindowView(target: target)
                    .environment(model)
            }
        }

        // Editor Mode's window — the publisher's corrections (see
        // EDITOR-MODE-PLAN.md). Compiled only into publisher builds;
        // a Release build carries no editor at all.
        #if DEBUG || EDITOR
        Window("Edit Document", id: "epub-editor") {
            DocumentEditorView()
                .environment(model)
        }
        .defaultSize(width: 900, height: 940)
        #endif

        // Where Have I Read This? — a phrase from any app, found in
        // one's own reading (ReadingSearch.swift).
        Window("Where Have I Read This?", id: "readingSearch") {
            ReadingSearchView()
                .environment(model)
        }
        .defaultSize(width: 720, height: 560)

        // File ▸ Hold Up a Page… — the camera reads a printed page and
        // opens its document in the main window at the page's place.
        Window("Hold Up a Page", id: "pageCamera") {
            PageCaptureView()
                .environment(model)
        }

        Settings {
            SettingsView()
                .environment(model)
        }

    }

    /// The standard About panel with Future Text Lab credits beneath the
    /// version line; the lab URL is clickable.
    private func showAboutPanel() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSMutableAttributedString(
            string: "Origami Text is a Future Text Lab project. It was initiated by Frode Hegland, who designed the format and built the first implementation. Please feel free to learn more about what we are doing and to join any of our open lab sessions on Mondays.\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ])
        var linkAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .paragraphStyle: paragraph
        ]
        if let url = URL(string: "https://futuretextlab.info") {
            linkAttributes[.link] = url
        }
        credits.append(NSAttributedString(string: "https://futuretextlab.info",
                                          attributes: linkAttributes))
        credits.append(NSAttributedString(
            string: "\n\nThe Origami Text application and the document specifications are fully free and open source, released under the MIT License.",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

/// The File menu's paper door: Hold Up a Page… opens the camera window
/// that reads a printed page back to its library document. Its own
/// Commands struct so it can reach openWindow.
private struct PageCaptureCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Hold Up a Page\u{2026}") {
                openWindow(id: "pageCamera")
            }
        }
    }
}

/// Where Have I Read This?, in the Edit menu beside the other things
/// one does to a piece of text. Takes whatever is on the clipboard so
/// the verb works the moment a phrase is copied — and the same act is
/// offered to every other app through the Services menu (see
/// AppDelegate's service provider).
/// Window ▸ Library (⌘L): the way back to the main window after it has
/// been closed — App Review's case. The menu bar lives at the app level,
/// so its `openWindow` works with no window open at all, whereas one
/// captured inside the main window dies with it. The same action is
/// handed to the model so the ⌘L key monitor and the Dock click reopen
/// through it too.
private struct LibraryWindowCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(before: .windowArrangement) {
            Button("Library") {
                model.openMainWindow = { openWindow(id: "main") }
                model.showLibraryOrOpenWindow()
            }
            .keyboardShortcut("l", modifiers: .command)
            Divider()
        }
    }
}

private struct ReadingSearchCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Where Have I Read This?") {
                let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
                openWindow(id: "readingSearch")
                if !clipboard.trimmingCharacters(in: .whitespaces).isEmpty {
                    model.findInMyReading(clipboard)
                }
            }
            // ⌥⌘F: ⌘F is the reading's own find and ⇧⌘F is Flow, while
            // ⌃⌘F is macOS's Enter Full Screen everywhere.
            .keyboardShortcut("f", modifiers: [.command, .option])
        }
    }
}

/// Editor Mode in the Edit menu: correcting a document that is not on
/// the shelf. The book's context menu edits what the library already
/// holds; this edits a file — one just exported, one a colleague sent —
/// without importing it first, which is the difference between fixing a
/// word and adopting a stranger into the library.
#if DEBUG || EDITOR
private struct EditorCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            if model.isEditorModeOn {
                Divider()
                Button("Edit Document\u{2026}") {
                    model.beginEditFile()
                    if model.editorSession != nil {
                        openWindow(id: "epub-editor")
                    }
                }
            }
        }
    }
}
#endif

/// Captures the SwiftUI openWindow action and the NSWindow reference so that
/// the AppKit NSEvent monitor (no SwiftUI environment) can reopen or restore
/// the main window after it has been closed or minimised.
private struct MainWindowConnector: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        EmptyView()
            .background(MainNSWindowCapture())
            .onAppear {
                model.openMainWindow = { openWindow(id: "main") }
                model.openReadingSearchWindow = { openWindow(id: "readingSearch") }
            }
    }
}

/// Captures the hosting NSWindow the moment the view appears and stores a
/// weak reference in AppModel. The weak reference becomes nil automatically
/// when the window is closed, which is the signal that a fresh window must
/// be opened rather than just shown.
private struct MainNSWindowCapture: NSViewRepresentable {
    @Environment(AppModel.self) private var model

    /// Reports the hosting window the moment the view actually joins
    /// it — a dispatch-async peek can run before attachment and miss,
    /// which is how restored duplicate windows dodged the dedupe.
    final class CaptureView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = CaptureView()
        view.onWindow = { [weak model] window in
            Task { @MainActor in model?.captureMainWindow(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if model.mainNSWindow == nil, let w = nsView.window {
            model.captureMainWindow(w)
        }
    }
}

/// Disallowing automatic tabbing (see AppDelegate) stops new tabs, but a
/// tab bar the user once showed is restored with the window and would still
/// appear. This reaches the hosting window to disallow tabbing outright and
/// fold away any tab bar that came back with restored state.
///
/// IMPORTANT: setting tabbingMode = .disallowed is an AppKit side-effect
/// that silently sets .fullScreenNone and clears .fullScreenPrimary on the
/// window's collectionBehavior. We must re-insert .fullScreenPrimary
/// afterwards, or ESC / the View menu can no longer enter full screen.
private struct TabBarRemover: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.tabbingMode = .disallowed
            if let tabGroup = window.tabGroup, tabGroup.isTabBarVisible {
                window.toggleTabBar(nil)
            }
            // Restore full-screen capability that tabbingMode = .disallowed
            // removes as a side-effect.
            var cb = window.collectionBehavior
            cb.remove(.fullScreenNone)
            cb.insert(.fullScreenPrimary)
            window.collectionBehavior = cb
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Receives documents double-clicked in Finder, buffering any that arrive
/// before the SwiftUI scene has handed over the model.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel? { didSet { flushPending() } }
    private var pending: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One window is the app: window tabs would only duplicate it, so
        // the tab bar (and its + button) never appears.
        NSWindow.allowsAutomaticWindowTabbing = false

        // The Liquid lift: any app's selection can ask this app where
        // it was read. The provider is registered here; the menu entry
        // itself is declared in Info.plist (NSServices).
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        // Handled here rather than via menu shortcuts so they work even when
        // a text view has focus (text views claim keys like ⌘L for
        // themselves before the menu sees them).
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // ⌘L / ⌘0 → Library: restore all columns; reopen the window if closed.
            if modifiers == .command,
               let ch = event.charactersIgnoringModifiers?.lowercased(),
               ch == "l" || ch == "0" {
                self?.showLibrary()
                return nil
            }

            // Escape toggles full screen, as in Author and Reader. Sheets and
            // popovers keep Escape for themselves (their windows can't go
            // full screen, so the guard passes the event through).
            // Guard allows either entering (.fullScreenPrimary set) OR
            // exiting (.fullScreen in styleMask) — so if collectionBehavior
            // ever gets corrupted again, ESC can still exit full screen.
            guard event.keyCode == 53,   // Escape
                  modifiers.intersection([.command, .option, .control]).isEmpty,
                  let window = event.window,
                  window.isKeyWindow,
                  window.attachedSheet == nil,
                  window.collectionBehavior.contains(.fullScreenPrimary)
                      || window.styleMask.contains(.fullScreen)
            else { return event }
            window.toggleFullScreen(nil)
            return nil
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        pending.append(contentsOf: urls)
        flushPending()
    }

    /// Dock-icon click with no visible windows: reopen the main window just
    /// as Cmd-L does, rather than doing nothing (the default macOS behaviour
    /// for apps that don't implement this delegate method).
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showLibrary() }
        return true
    }

    /// Runs Window ▸ Library itself rather than calling the model
    /// directly: the menu item's `openWindow` is the app-level one, alive
    /// with no window open, so a closed main window really comes back.
    /// Falls back to the model if the item cannot be found.
    private func showLibrary() {
        if let (menu, index) = libraryMenuItem() {
            menu.performActionForItem(at: index)
        } else {
            model?.showLibraryOrOpenWindow()
        }
    }

    private func libraryMenuItem() -> (NSMenu, Int)? {
        func search(_ menu: NSMenu) -> (NSMenu, Int)? {
            for (index, item) in menu.items.enumerated() {
                if item.keyEquivalent == "l",
                   item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command,
                   item.title == "Library" {
                    return (menu, index)
                }
                if let sub = item.submenu, let found = search(sub) { return found }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(search)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.saveDraftIfNeeded()
    }

    /// The Services entry, named by Info.plist's NSMessage: a phrase
    /// selected in any app at all — a mail, a web page, a colleague's
    /// draft — asked of one's own reading. The app comes forward with
    /// the answer; nothing is pasted back, because the question is
    /// "where did I read this", not "change this".
    @objc func findInMyReading(_ pasteboard: NSPasteboard,
                               userData: String?,
                               error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let phrase = pasteboard.string(forType: .string),
              !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = "Select some words first." as NSString
            return
        }
        guard let model else {
            error.pointee = "Origami Text is still starting up — try again." as NSString
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        model.findInMyReading(phrase)
        model.opensReadingSearchWindow()
    }

    private func flushPending() {
        guard let model else { return }
        let urls = pending
        pending = []
        for url in urls {
            model.handleURL(url)
        }
    }
}
