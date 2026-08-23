import SwiftUI
import AppKit

/// The reader's text, AppKit-backed: what SwiftUI `Text` could not give —
/// access to the live selection, per-character hit testing, and a real
/// context menu — this view provides, while rendering exactly what the
/// old path rendered (serif typography, heading scale, live links, span
/// highlights, transclusion marks). A ctrl-click resolves to a
/// ContextTarget: the selection under the pointer, a known person's name,
/// a document address, and always the paragraph itself.
struct ReaderTextView: NSViewRepresentable {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    let paragraph: LiquidDoc.Paragraph
    /// The fully composed text (markdown rendered, links detected,
    /// transclusion marks in place) from the existing pipeline.
    let attributed: AttributedString
    var sizeScale: CGFloat = 1
    /// The exact words to mark, on a span-scoped arrival.
    var highlightedSpan: String? = nil
    /// The document this paragraph is read in, when known.
    var doc: LiquidDoc? = nil

    /// The menu is owned at the view level: on current SDKs the text
    /// system can build its menu without consulting the delegate hook, so
    /// the override is the reliable seam.
    final class ReaderNSTextView: NSTextView, NSMenuDelegate {
        var augmentMenu: ((NSMenu, Int) -> Void)?
        /// The document and paragraph this text is read in — lets app-wide
        /// commands (New Document with a live selection) cite what was
        /// selected and attribute it to its transcript speaker.
        var doc: LiquidDoc?
        var paragraph: LiquidDoc.Paragraph?

        /// The reader's menu is entirely ours: no system items at all
        /// (keyboard shortcuts still work — ⌘C copies a selection).
        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = NSMenu()
            // AppKit injects Services, AutoFill, and similar into context
            // menus on its own; refuse plug-ins and gate the rest at open.
            menu.allowsContextMenuPlugIns = false
            menu.delegate = self
            let point = convert(event.locationInWindow, from: nil)
            augmentMenu?(menu, characterIndexForInsertion(at: point))
            for item in menu.items { item.tag = Self.ownedItemTag }
            return menu.items.isEmpty ? nil : menu
        }

        /// Anything in the menu we did not put there was injected by the
        /// system after we returned it; it goes.
        static let ownedItemTag = 0x0716
        func menuNeedsUpdate(_ menu: NSMenu) {
            for item in menu.items where item.tag != Self.ownedItemTag {
                menu.removeItem(item)
            }
        }

        /// Triple-click selects the sentence around the click — the
        /// reading's natural unit — unless Settings ▸ Reading turns it
        /// back to the paragraph, AppKit's own way. Double-click keeps
        /// the word.
        override func selectionRange(forProposedRange proposedCharRange: NSRange,
                                     granularity: NSSelectionGranularity) -> NSRange {
            let standard = super.selectionRange(forProposedRange: proposedCharRange,
                                                granularity: granularity)
            guard granularity == .selectByParagraph,
                  UserDefaults.standard.object(
                      forKey: AppSettings.tripleClickSelectsSentenceKey) as? Bool ?? true,
                  let storage = textStorage
            else { return standard }
            let text = storage.string as NSString
            var sentence = standard
            text.enumerateSubstrings(in: NSRange(location: 0, length: text.length),
                                     options: .bySentences) { _, range, _, stop in
                if NSLocationInRange(proposedCharRange.location, range) {
                    sentence = range
                    stop.pointee = true
                }
            }
            // The sentence without its trailing whitespace.
            while sentence.length > 0 {
                let last = text.character(at: sentence.location + sentence.length - 1)
                guard let scalar = Unicode.Scalar(last),
                      CharacterSet.whitespacesAndNewlines.contains(scalar) else { break }
                sentence.length -= 1
            }
            return sentence.length > 0 ? sentence : standard
        }
    }

    func makeNSView(context: Context) -> ReaderNSTextView {
        let textView = ReaderNSTextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.delegate = context.coordinator
        // Links read as body text with a quiet underline, not browser blue.
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.labelColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.augmentMenu = { [weak coordinator = context.coordinator] menu, charIndex in
            coordinator?.augment(menu, in: textView, at: charIndex)
        }
        return textView
    }

    func updateNSView(_ textView: ReaderNSTextView, context: Context) {
        context.coordinator.model = model
        context.coordinator.paragraph = paragraph
        context.coordinator.doc = doc
        textView.doc = doc
        textView.paragraph = paragraph
        context.coordinator.openURL = openURL
        textView.textStorage?.setAttributedString(renderedNSText())
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView textView: ReaderNSTextView,
                      context: Context) -> CGSize? {
        guard let container = textView.textContainer,
              let layoutManager = textView.layoutManager else { return nil }
        // Stacks probe with zero, unspecified, and infinite widths before
        // settling on one. Returning nil for those probes fell back to
        // NSTextView's empty intrinsic size, and a cited paragraph (sharing
        // an HStack with its badge) collapsed to a one-character column.
        if proposal.width == 0 { return .zero }
        if let width = proposal.width, width.isFinite, width > 0 {
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: container)
            let height = ceil(layoutManager.usedRect(for: container).height)
            return CGSize(width: width, height: max(height, 1))
        }
        // Unspecified or unbounded width: the natural, unwrapped extent.
        container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                         height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return CGSize(width: ceil(used.width), height: max(ceil(used.height), 1))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: Rendering (mirrors the old SwiftUI Text styling exactly)

    private func renderedNSText() -> NSAttributedString {
        let plain = String(attributed.characters)
        let result = NSMutableAttributedString(string: plain)
        let full = NSRange(location: 0, length: (plain as NSString).length)

        let headingSize: CGFloat = switch paragraph.effectiveHeading {
        case 1: 28
        case 2: 23
        case 3: 19
        default: 17
        }
        let isHeading = paragraph.effectiveHeading != nil
        let baseFont = Self.serifFont(size: headingSize * sizeScale,
                                      bold: isHeading, italic: false)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = (isHeading ? 3 : 6) * sizeScale
        result.addAttributes([.font: baseFont,
                              .foregroundColor: NSColor.labelColor,
                              .paragraphStyle: style], range: full)

        // Carry over what the composed AttributedString knows: links, and
        // markdown emphasis.
        for run in attributed.runs {
            let lower = attributed.characters.distance(from: attributed.startIndex,
                                                       to: run.range.lowerBound)
            let length = attributed.characters.distance(from: run.range.lowerBound,
                                                        to: run.range.upperBound)
            let nsRange = NSRange(location: lower, length: length)
            if let link = run.link {
                result.addAttribute(.link, value: link, range: nsRange)
            }
            if let intent = run.inlinePresentationIntent {
                let bold = isHeading || intent.contains(.stronglyEmphasized)
                let italic = intent.contains(.emphasized)
                if bold || italic {
                    result.addAttribute(.font,
                                        value: Self.serifFont(size: headingSize * sizeScale,
                                                              bold: bold, italic: italic),
                                        range: nsRange)
                }
            }
        }

        // The span-scoped arrival: mark the exact words where they occur;
        // where they don't, the paragraph flash alone stands.
        if let highlightedSpan {
            let range = (plain as NSString).range(of: highlightedSpan,
                                                  options: [.caseInsensitive, .diacriticInsensitive])
            if range.location != NSNotFound {
                result.addAttribute(.backgroundColor,
                                    value: NSColor.systemYellow.withAlphaComponent(0.85),
                                    range: range)
            }
        }
        return result
    }

    /// The reader's chosen body face (Settings ▸ Reading ▸ Fonts) —
    /// the one choice every view honours.
    private static func serifFont(size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        AppFonts.nsBody(size, bold: bold, italic: italic)
    }

    // MARK: Interaction

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var model: AppModel?
        var paragraph: LiquidDoc.Paragraph?
        var doc: LiquidDoc?
        var openURL: OpenURLAction?

        /// Links route through the same environment action the reader
        /// already uses (origamitext:// navigation, transclusion marks).
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else {
                return false
            }
            openURL?(url)
            return true
        }

        /// The ctrl-click contract: name what the pointer is on, render
        /// the shared answer, keep the system's text items below.
        func augment(_ menu: NSMenu, in view: NSTextView, at charIndex: Int) {
            guard let model else { return }
            var targets: [ContextTarget] = []

            let selectedRange = view.selectedRange()
            let text = view.string as NSString
            if selectedRange.length > 0, NSLocationInRange(charIndex, selectedRange) {
                targets.append(.selection(text: text.substring(with: selectedRange), doc: doc))
            } else if charIndex < text.length {
                // Special text under the pointer: an address link, or a
                // name the library knows.
                if let link = view.textStorage?.attribute(.link, at: charIndex,
                                                          effectiveRange: nil),
                   let url = link as? URL, url.scheme?.lowercased() == "origamitext" {
                    let id = url.host() ?? url.lastPathComponent
                    targets.append(.address(id: id, fragment: url.fragment))
                } else {
                    let wordRange = view.selectionRange(
                        forProposedRange: NSRange(location: charIndex, length: 0),
                        granularity: .selectByWord)
                    let word = text.substring(with: wordRange)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !word.isEmpty,
                       model.people.person(named: word) != nil || model.knowsAuthor(named: word) {
                        targets.append(.person(name: word))
                    }
                }
            }
            if let paragraph, let doc {
                targets.append(.paragraph(paragraph, in: doc))
            }

            var offset = 0
            for target in targets {
                let items = ContextActionBuilder.menuItems(for: target, mode: .reading,
                                                           model: model)
                for item in items {
                    menu.insertItem(item, at: offset)
                    offset += 1
                }
            }
        }
    }
}
