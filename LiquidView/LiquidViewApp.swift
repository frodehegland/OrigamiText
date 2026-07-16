import SwiftUI
import AppKit

@main
struct LiquidViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Origami Text") {
            ContentView()
                .environment(model)
                .onOpenURL { model.handleURL($0) }
                .task {
                    appDelegate.model = model
                    model.restoreFolderAccess()
                    model.restoreReaderLibrary()
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Origami Text") { showAboutPanel() }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Document") { model.newDraft() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Import…") { model.importDocumentFile() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Export to XR (Author Map)…") { model.showXRExport = true }
                Button("Export Library Manifest…") { model.exportLibraryManifest() }
                Divider()
                Button("Choose Community Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                // Replacing .saveItem also removes the system Close item,
                // so it is restored here — Settings and every other window
                // need ⌘W.
                Button("Close") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w", modifiers: .command)
                Divider()
                Button("Save") { model.saveDraft() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.draftEditor?.hasUnsavedChanges != true)
                Button("Export…") { model.exportDraft() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.draftEditor == nil)
            }
            CommandGroup(after: .windowArrangement) {
                Button("Library") { model.showLibrary() }
                    .keyboardShortcut("l", modifiers: .command)
                Button(model.isListHidden ? "Show Documents" : "Hide Documents") {
                    model.toggleListColumn()
                }
                Button(model.showLinksInspector ? "Hide Links Panel" : "Show Links Panel") {
                    model.showLinksInspector.toggle()
                }
                .keyboardShortcut("l", modifiers: [.option, .command])
                Divider()
            }
            CommandMenu("Go") {
                Button("Back") { model.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!model.canGoBack)
                Button("Forward") { model.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!model.canGoForward)
            }
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
            string: "\n\nThe Origami Text application and the document specifications are fully free and open source.",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

/// Receives documents double-clicked in Finder, buffering any that arrive
/// before the SwiftUI scene has handed over the model.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel? { didSet { flushPending() } }
    private var pending: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Handled here rather than via menu shortcuts so they work even when
        // a text view has focus (text views claim keys like ⌘L for
        // themselves before the menu sees them).
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // ⌘L → Library: restore all columns, leaving full screen if needed.
            if modifiers == .command,
               event.charactersIgnoringModifiers?.lowercased() == "l" {
                self?.model?.showLibrary()
                return nil
            }

            // Escape toggles full screen, as in Author and Reader. Sheets and
            // popovers keep Escape for themselves (their windows can't go
            // full screen, so the guard passes the event through).
            guard event.keyCode == 53,   // Escape
                  modifiers.intersection([.command, .option, .control]).isEmpty,
                  let window = event.window,
                  window.isKeyWindow,
                  window.attachedSheet == nil,
                  window.collectionBehavior.contains(.fullScreenPrimary)
            else { return event }
            window.toggleFullScreen(nil)
            return nil
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        pending.append(contentsOf: urls)
        flushPending()
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
