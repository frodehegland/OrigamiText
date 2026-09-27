#if os(macOS)
import AppKit
import SwiftUI
import Translation

/// Look Up and Translate for selected words — the system dictionary panel
/// and the system translation popover, shown where the pointer is. The
/// reading menus drop the system's own items (Services, Share, WebKit's
/// defaults), so these are offered as the reader's own.
@MainActor
enum ReaderLookup {
    /// The system dictionary panel for the words, at the pointer.
    static func lookUp(_ text: String) {
        guard let (view, point) = pointerInKeyWindow() else { return }
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        view.showDefinition(for: NSAttributedString(string: text, attributes: [.font: font]),
                            at: point)
    }

    /// The system translation popover for the words, at the pointer. A
    /// one-point host view carries the popover and removes itself when
    /// the popover closes.
    static func translate(_ text: String) {
        guard let (view, point) = pointerInKeyWindow() else { return }
        let host = NSHostingView(rootView: TranslationAnchor(text: text))
        host.frame = NSRect(x: point.x, y: point.y, width: 1, height: 1)
        view.addSubview(host)
    }

    /// The key window's content view and the pointer in its coordinates.
    private static func pointerInKeyWindow() -> (NSView, NSPoint)? {
        guard let window = NSApp.keyWindow, let view = window.contentView else { return nil }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return (view, view.convert(inWindow, from: nil))
    }
}

/// Presents the translation popover as soon as it appears, and takes its
/// host view away once the popover is dismissed.
private struct TranslationAnchor: View {
    let text: String
    @State private var shown = false
    @State private var appeared = false

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationPresentation(isPresented: $shown, text: text)
            .onAppear {
                appeared = true
                shown = true
            }
            .background(HostRemover(remove: appeared && !shown))
    }
}

/// Removes the hosting view from its superview when asked.
private struct HostRemover: NSViewRepresentable {
    let remove: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        guard remove else { return }
        DispatchQueue.main.async {
            // The anchor's own hosting view: the first ancestor that is one.
            var candidate = view.superview
            while let current = candidate, !(current is NSHostingView<TranslationAnchor>) {
                candidate = current.superview
            }
            candidate?.removeFromSuperview()
        }
    }
}
#endif
