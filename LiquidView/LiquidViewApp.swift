import SwiftUI
import AppKit

@main
struct LiquidViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Origami Text", id: "main") {
            ZStack {
                ContentView()
                MainWindowConnector()
            }
            .environment(model)
            .onOpenURL { model.handleURL($0) }
            .task {
                appDelegate.model = model
                model.restoreFolderAccess()
                model.restoreReaderLibrary()
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
            }
            // The window toolbar is bare, as in Knowledge Space — these
            // menu items are where its former controls live on.
            CommandGroup(after: .windowArrangement) {
                Button("Library") { model.showLibraryOrOpenWindow() }
                    .keyboardShortcut("l", modifiers: .command)
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

/// Captures the SwiftUI openWindow action and the NSWindow reference so that
/// the AppKit NSEvent monitor (no SwiftUI environment) can reopen or restore
/// the main window after it has been closed or minimised.
private struct MainWindowConnector: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        EmptyView()
            .background(MainNSWindowCapture())
            .onAppear { model.openMainWindow = { openWindow(id: "main") } }
    }
}

/// Captures the hosting NSWindow the moment the view appears and stores a
/// weak reference in AppModel. The weak reference becomes nil automatically
/// when the window is closed, which is the signal that a fresh window must
/// be opened rather than just shown.
private struct MainNSWindowCapture: NSViewRepresentable {
    @Environment(AppModel.self) private var model

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            model.mainNSWindow = view.window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if model.mainNSWindow == nil, let w = nsView.window {
            model.mainNSWindow = w
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

        // Handled here rather than via menu shortcuts so they work even when
        // a text view has focus (text views claim keys like ⌘L for
        // themselves before the menu sees them).
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // ⌘L / ⌘0 → Library: restore all columns; reopen the window if closed.
            if modifiers == .command,
               let ch = event.charactersIgnoringModifiers?.lowercased(),
               ch == "l" || ch == "0" {
                self?.model?.showLibraryOrOpenWindow()
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
        if !flag { model?.showLibraryOrOpenWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.saveDraftIfNeeded()
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
