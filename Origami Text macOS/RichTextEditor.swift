import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The writing surface: an AppKit text view editing the draft's own
/// storage in Author's shape — paragraph styles as attributes, pictures
/// and tables as attachments, citations as tagged runs. Formatting is
/// data, applied by the commands below (the Format menu, the context
/// menu, keyboard shortcuts), never re-derived from markers.
struct RichTextEditor: NSViewRepresentable {
    let editor: DraftEditor
    /// The transcript's known speakers. When the clicked paragraph opens
    /// with one of these names ("Tom Haymes: …"), the context menu offers
    /// lifting that statement into a new document.
    var speakers: [String] = []
    var onLiftStatement: ((String) -> Void)?
    /// The draft as it stands, for selection actions that cite it.
    var contextDoc: (() -> LiquidDoc)?
    /// Renders the shared context actions for a target.
    var contextMenuItems: ((ContextTarget) -> [NSMenuItem])?
    /// Set true to hand the keyboard to the body text; flips back once
    /// taken — how Tab in the title lands here.
    var claimFocus: Binding<Bool>? = nil
    /// Set to a 1-based paragraph number (the Nth non-empty paragraph —
    /// the numbering the saved document's ids follow) to scroll there and
    /// flash it; resets once done.
    var revealParagraph: Binding<Int?>? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let controller = context.coordinator
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        editor.textStorage.addLayoutManager(layoutManager)

        let textView = RichNSTextView(frame: .zero, textContainer: container)
        textView.controller = controller
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.delegate = controller
        textView.allowsUndo = true
        textView.isRichText = true
        textView.importsGraphics = false      // pictures come through our own insert
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: 12)
        textView.typingAttributes = AuthorStyle.body.attributes
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.labelColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: NSColor.tertiaryLabelColor,
        ]
        textView.registerForDraggedTypes([.fileURL, .tiff, .png])

        controller.textView = textView
        controller.editor = editor
        apply(to: controller)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let controller = context.coordinator
        apply(to: controller)
        guard let textView = controller.textView else { return }
        if claimFocus?.wrappedValue == true {
            textView.window?.makeFirstResponder(textView)
            let claimFocus = claimFocus
            Task { @MainActor in claimFocus?.wrappedValue = false }
        }
        if let target = revealParagraph?.wrappedValue {
            controller.reveal(paragraph: target)
            let revealParagraph = revealParagraph
            Task { @MainActor in revealParagraph?.wrappedValue = nil }
        }
    }

    private func apply(to controller: RichTextController) {
        controller.speakers = speakers
        controller.onLiftStatement = onLiftStatement
        controller.contextDoc = contextDoc
        controller.contextMenuItems = contextMenuItems
    }

    /// The draft's own controller, so menus reach the same object.
    func makeCoordinator() -> RichTextController { editor.controller }
}

/// The editor's AppKit side — the text view's delegate and the object
/// every command reaches: the Format menu through the focused scene,
/// the citation sheet through the draft editor. One per editor view.
@MainActor
final class RichTextController: NSObject, NSTextViewDelegate {
    weak var textView: RichNSTextView?
    weak var editor: DraftEditor?
    var speakers: [String] = []
    var onLiftStatement: ((String) -> Void)?
    var contextDoc: (() -> LiquidDoc)?
    var contextMenuItems: ((ContextTarget) -> [NSMenuItem])?
    /// A table was clicked: the host opens its grid editor.
    var onTableClicked: ((TableAttachment, NSRect) -> Void)?
    private var pendingLiftStatement: String?

    private var storage: NSTextStorage? { textView?.textStorage }

    // MARK: - Delegate

    func textDidChange(_ notification: Notification) {
        editor?.noteTextChanged()
    }

    /// Structured pastes become citations: Reader's "Copy as Quote"
    /// becomes the bracketed library citation with its record, BibTeX
    /// entries become citation runs. Everything else passes through.
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedRange: NSRange,
                  replacementString: String?) -> Bool {
        guard let replacementString, !replacementString.isEmpty else { return true }
        if let citation = CitationClipboard.read(matchingPlainText: replacementString) {
            if let bibtex = citation.bibtex, !bibtex.isEmpty {
                editor?.registerReference(address: citation.address, bibtex: bibtex)
            }
            insertPlain(citation.insertionText, replacing: affectedRange, in: textView)
            return false
        }
        if let quote = ReaderQuoteParser.parse(replacementString) {
            if let id = quote.derivedID, let bibtex = quote.synthesizedBibTeX {
                editor?.registerReference(address: id, bibtex: bibtex)
            }
            insertPlain(quote.draftText, replacing: affectedRange, in: textView)
            return false
        }
        if CitationPaste.handle(replacementString, replacing: affectedRange, controller: self) {
            return false
        }
        return true
    }

    /// Return inside a heading starts a body paragraph; inside a list
    /// item continues the list, or ends it when the item is empty.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)),
              let storage = textView.textStorage else { return false }
        let selection = textView.selectedRange()
        let string = storage.string as NSString
        guard storage.length > 0 else { return false }
        let paragraph = string.paragraphRange(for: NSRange(location: min(selection.location, string.length), length: 0))
        guard paragraph.length > 0 else { return false }
        let attributes = storage.attributes(at: paragraph.location, effectiveRange: nil)
        let style = AuthorStyle.from(identifier: attributes[AuthorAttributes.styleIdentifier] as? String)
        let hasAttachment = attributes[.attachment] != nil

        if style.isList {
            let words = string.substring(with: paragraph)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .drop(while: { "•-–*\t ".contains($0) })
            if words.isEmpty {
                // An empty item: the list ends here.
                setStyle(.body, paragraphRange: paragraph)
                return true
            }
            let stub = LiquidRichText.listStub(for: style)
            let item = NSMutableAttributedString(string: "\n", attributes: style.attributes)
            item.append(stub)
            item.addAttribute(AuthorAttributes.styleSecondaryIdentifier, value: style.rawValue,
                              range: NSRange(location: 0, length: item.length))
            guard textView.shouldChangeText(in: selection, replacementString: item.string) else { return true }
            storage.replaceCharacters(in: selection, with: item)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: selection.location + item.length, length: 0))
            var typing = style.attributes
            typing[AuthorAttributes.styleSecondaryIdentifier] = style.rawValue
            textView.typingAttributes = typing
            return true
        }
        if style.isHeading || hasAttachment || style == .attachmentDetails {
            let body = NSAttributedString(string: "\n", attributes: AuthorStyle.body.attributes)
            guard textView.shouldChangeText(in: selection, replacementString: "\n") else { return true }
            storage.replaceCharacters(in: selection, with: body)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            textView.typingAttributes = AuthorStyle.body.attributes
            return true
        }
        return false
    }

    func textView(_ textView: NSTextView, clickedOn cell: NSTextAttachmentCellProtocol,
                  in cellFrame: NSRect, at charIndex: Int) {
        guard let attachment = cell.attachment as? TableAttachment else { return }
        onTableClicked?(attachment, cellFrame)
    }

    /// The caret keeps the paragraph's style as it moves: typing into an
    /// empty body line after a heading writes body, not heading.
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return }
        if storage.length == 0 {
            textView.typingAttributes = AuthorStyle.body.attributes
            return
        }
        // Right after an attachment: new words are body, not attachment.
        let probe = min(max(selection.location - 1, 0), storage.length - 1)
        let attributes = storage.attributes(at: probe, effectiveRange: nil)
        if attributes[.attachment] != nil || attributes[AuthorAttributes.citationIdentifier] != nil {
            var typing = textView.typingAttributes
            let style = AuthorStyle.from(identifier: attributes[AuthorAttributes.styleIdentifier] as? String)
            let base = (style == .attachment ? AuthorStyle.body : style).attributes
            for (key, value) in base { typing[key] = value }
            for key in [AuthorAttributes.citationIdentifier, AuthorAttributes.citationFormat,
                        AuthorAttributes.citationStartMarker, AuthorAttributes.citationEndMarker,
                        .attachment, .link] {
                typing.removeValue(forKey: key)
            }
            textView.typingAttributes = typing
        }
    }

    // MARK: - Context menu

    func augment(_ menu: NSMenu, in view: NSTextView, at charIndex: Int) {
        let selectedRange = view.selectedRange()
        if let contextMenuItems, selectedRange.length > 0,
           NSLocationInRange(charIndex, selectedRange) {
            let selectedText = (view.string as NSString).substring(with: selectedRange)
            let shared = contextMenuItems(.selection(text: selectedText, doc: contextDoc?()))
            for (offset, item) in shared.enumerated() {
                menu.insertItem(item, at: offset)
            }
            if !shared.isEmpty {
                menu.insertItem(.separator(), at: shared.count)
            }
        }
        if onLiftStatement != nil, !speakers.isEmpty {
            let string = view.string as NSString
            if string.length > 0 {
                let location = min(charIndex, string.length - 1)
                let paragraph = string
                    .substring(with: string.paragraphRange(for: NSRange(location: location, length: 0)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let speaker = speakers.first(where: { paragraph.hasPrefix("\($0):") }) {
                    pendingLiftStatement = paragraph
                    let item = NSMenuItem(title: "Lift to New — statement by \(speaker)",
                                          action: #selector(liftPendingStatement), keyEquivalent: "")
                    item.target = self
                    menu.insertItem(item, at: 0)
                    menu.insertItem(.separator(), at: 1)
                }
            }
        }
        // The Format commands, within reach of the pointer.
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let format = NSMenu(title: "Format")
        for (title, style) in [("Body", AuthorStyle.body), ("Heading 1", .header1),
                               ("Heading 2", .header2), ("Heading 3", .header3),
                               ("Bullet List", .bulletList), ("Dash List", .dashList), ("Code", .code)] {
            let item = NSMenuItem(title: title, action: #selector(applyStyleItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            format.addItem(item)
        }
        let formatItem = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
        formatItem.submenu = format
        menu.addItem(formatItem)
        let insert = NSMenu(title: "Insert")
        for (title, selector) in [("Image…", #selector(insertImageItem)), ("Table…", #selector(insertTableItem)),
                                  ("Citation…", #selector(insertCitationItem)), ("Weblink…", #selector(insertLinkItem))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            insert.addItem(item)
        }
        let insertItem = NSMenuItem(title: "Insert", action: nil, keyEquivalent: "")
        insertItem.submenu = insert
        menu.addItem(insertItem)
    }

    @objc private func liftPendingStatement() {
        if let statement = pendingLiftStatement { onLiftStatement?(statement) }
        pendingLiftStatement = nil
    }

    @objc private func applyStyleItem(_ sender: NSMenuItem) {
        setStyle(AuthorStyle.from(identifier: sender.representedObject as? String))
    }

    @objc private func insertImageItem() { chooseAndInsertImages() }
    @objc private func insertTableItem() { editor?.requestTable = true }
    @objc private func insertCitationItem() { editor?.requestCitation = true }
    @objc private func insertLinkItem() { editor?.requestLink = true }

    // MARK: - Scrolling

    /// Scrolls to the Nth non-empty paragraph — paragraph pN in the saved
    /// document — and flashes it with the system's find indicator.
    func reveal(paragraph target: Int) {
        guard let textView, target > 0 else { return }
        let string = textView.string as NSString
        var count = 0
        var location = 0
        while location < string.length {
            let lineRange = string.paragraphRange(for: NSRange(location: location, length: 0))
            let line = string.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                count += 1
                if count == target {
                    textView.scrollRangeToVisible(lineRange)
                    textView.showFindIndicator(for: lineRange)
                    return
                }
            }
            let next = NSMaxRange(lineRange)
            if next <= location { break }
            location = next
        }
    }

    // MARK: - Formatting commands

    /// The paragraph ranges the selection touches (the caret's paragraph
    /// when nothing is selected).
    private func selectedParagraphRanges() -> [NSRange] {
        guard let textView, let storage else { return [] }
        let string = storage.string as NSString
        guard string.length > 0 else { return [] }
        let selection = textView.selectedRange()
        var ranges: [NSRange] = []
        var location = min(selection.location, string.length)
        let end = min(NSMaxRange(selection), string.length)
        repeat {
            let paragraph = string.paragraphRange(for: NSRange(location: min(location, max(string.length - 1, 0)), length: 0))
            if paragraph.length == 0 { break }
            ranges.append(paragraph)
            location = NSMaxRange(paragraph)
        } while location < end
        return ranges
    }

    /// Gives the selected paragraphs a style: heading, body, list or
    /// code. Bold and italic words keep their emphasis; links and
    /// citations keep their marks; a list's stub is added or removed.
    func setStyle(_ style: AuthorStyle) {
        for range in selectedParagraphRanges().reversed() {
            setStyle(style, paragraphRange: range)
        }
    }

    func setStyle(_ style: AuthorStyle, paragraphRange: NSRange) {
        guard let textView, let storage else { return }
        guard paragraphRange.location < storage.length else {
            textView.typingAttributes = style.attributes
            return
        }
        // Attachment paragraphs keep their own style.
        if storage.attribute(.attachment, at: paragraphRange.location, effectiveRange: nil) != nil { return }
        let string = storage.string as NSString
        var range = paragraphRange
        let current = AuthorStyle.from(identifier:
            storage.attribute(AuthorAttributes.styleIdentifier, at: range.location, effectiveRange: nil) as? String)

        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        // Drop an existing list stub.
        if current.isList {
            var stubLength = 0
            storage.enumerateAttribute(AuthorAttributes.structureIdentifiers, in: range) { value, stubRange, stop in
                if (value as? String) == AuthorAttributes.listStubValue, stubRange.location == range.location {
                    stubLength = stubRange.length
                }
                stop.pointee = true
            }
            if stubLength == 0 {
                let text = string.substring(with: range)
                stubLength = text.prefix(while: { "•-–*\t ".contains($0) }).count
            }
            if stubLength > 0, stubLength < range.length {
                storage.deleteCharacters(in: NSRange(location: range.location, length: stubLength))
                range.length -= stubLength
            }
        }
        // The style's attributes, fonts keeping their emphasis.
        let attributes = style.attributes
        storage.enumerateAttribute(.font, in: range) { value, fontRange, _ in
            let existing = value as? NSFont
            storage.addAttribute(.font, value: style.font.withTraits(
                bold: (existing?.isBold ?? false) && !current.font.isBold,
                italic: (existing?.isItalic ?? false) && !current.font.isItalic), range: fontRange)
        }
        storage.addAttributes([
            .paragraphStyle: attributes[.paragraphStyle] as Any,
            .foregroundColor: NSColor.labelColor,
            AuthorAttributes.styleIdentifier: style.rawValue,
            AuthorAttributes.characterRange: attributes[AuthorAttributes.characterRange] as Any,
        ], range: range)
        storage.removeAttribute(AuthorAttributes.styleSecondaryIdentifier, range: range)
        storage.removeAttribute(AuthorAttributes.structureIdentifiers, range: range)
        if style.isList {
            storage.insert(LiquidRichText.listStub(for: style), at: range.location)
            storage.addAttribute(AuthorAttributes.styleSecondaryIdentifier, value: style.rawValue,
                                 range: NSRange(location: range.location, length: range.length + (style.listStub?.count ?? 0)))
        }
        storage.endEditing()
        textView.didChangeText()
        var typing = style.attributes
        if style.isList { typing[AuthorAttributes.styleSecondaryIdentifier] = style.rawValue }
        textView.typingAttributes = typing
    }

    /// The style at the caret, for menus that show state.
    var currentStyle: AuthorStyle {
        guard let textView, let storage, storage.length > 0 else { return .body }
        let location = min(textView.selectedRange().location, storage.length - 1)
        return AuthorStyle.from(identifier:
            storage.attribute(AuthorAttributes.styleIdentifier, at: location, effectiveRange: nil) as? String)
    }

    func toggleBold() { toggleTrait(bold: true) }
    func toggleItalic() { toggleTrait(bold: false) }

    /// Bold or italic over the selection: on when any of it lacks the
    /// trait, off when all of it has it. With nothing selected, the
    /// typing attributes flip for what comes next.
    private func toggleTrait(bold: Bool) {
        guard let textView, let storage else { return }
        let selection = textView.selectedRange()
        if selection.length == 0 {
            var typing = textView.typingAttributes
            let font = (typing[.font] as? NSFont) ?? AuthorStyle.body.font
            let has = bold ? font.isBold : font.isItalic
            typing[.font] = font.withTraits(bold: bold ? !has : nil, italic: bold ? nil : !has)
            textView.typingAttributes = typing
            return
        }
        var allHave = true
        storage.enumerateAttribute(.font, in: selection) { value, _, stop in
            let font = (value as? NSFont) ?? AuthorStyle.body.font
            if !(bold ? font.isBold : font.isItalic) { allHave = false; stop.pointee = true }
        }
        guard textView.shouldChangeText(in: selection, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: selection) { value, range, _ in
            let font = (value as? NSFont) ?? AuthorStyle.body.font
            storage.addAttribute(.font, value: font.withTraits(bold: bold ? !allHave : nil,
                                                               italic: bold ? nil : !allHave), range: range)
        }
        storage.endEditing()
        textView.didChangeText()
    }

    /// A web link on the selected words (or the address itself when
    /// nothing is selected).
    func insertLink(_ url: URL) {
        guard let textView, let storage else { return }
        let selection = textView.selectedRange()
        if selection.length > 0 {
            guard textView.shouldChangeText(in: selection, replacementString: nil) else { return }
            storage.addAttribute(.link, value: url, range: selection)
            textView.didChangeText()
        } else {
            var attributes = textView.typingAttributes
            attributes[.link] = url
            let text = NSAttributedString(string: url.absoluteString, attributes: attributes)
            guard textView.shouldChangeText(in: selection, replacementString: text.string) else { return }
            storage.replaceCharacters(in: selection, with: text)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: selection.location + text.length, length: 0))
            var typing = textView.typingAttributes
            typing.removeValue(forKey: .link)
            textView.typingAttributes = typing
        }
    }

    // MARK: - Insertion

    /// Plain words at a range, in the paragraph's current style.
    func insertPlain(_ text: String, replacing range: NSRange, in textView: NSTextView) {
        var attributes = textView.typingAttributes
        for key in [AuthorAttributes.citationIdentifier, AuthorAttributes.citationFormat,
                    AuthorAttributes.citationStartMarker, AuthorAttributes.citationEndMarker, .link] {
            attributes.removeValue(forKey: key)
        }
        var transformed = text
        if range.location > 0, let storage = textView.textStorage {
            let previous = (storage.string as NSString).character(at: range.location - 1)
            if let scalar = Unicode.Scalar(previous), !CharacterSet.newlines.contains(scalar),
               text.contains("\n") {
                transformed = "\n\n" + text
            }
        }
        let piece = NSAttributedString(string: transformed, attributes: attributes)
        guard textView.shouldChangeText(in: range, replacementString: piece.string) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: piece)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: range.location + piece.length, length: 0))
    }

    /// A citation at the caret, as Author lays it out: with words
    /// selected, the words quoted and the label after them; with none, the
    /// bare "(Name Year)". The record joins the draft's store.
    func insertCitation(_ citation: AuthorCitation) {
        guard let textView, let storage else { return }
        editor?.addCitation(citation)
        let selection = textView.selectedRange()
        let base = baseAttributes(at: selection.location)
        let run: NSAttributedString
        if selection.length > 0 {
            let words = storage.attributedSubstring(from: selection)
            run = LiquidRichText.citationRun(citation, format: .quotesWithNameAndYear, content: words, base: base)
        } else {
            run = LiquidRichText.citationRun(citation, format: .nameAndDate, base: base)
        }
        let piece = NSMutableAttributedString()
        if selection.location > 0 {
            let previous = (storage.string as NSString).character(at: selection.location - 1)
            if previous != 0x20, previous != 0x0A, previous != 0x28 /* ( */, previous != 0x201C /* “ */ {
                piece.append(NSAttributedString(string: " ", attributes: base))
            }
        }
        piece.append(run)
        guard textView.shouldChangeText(in: selection, replacementString: piece.string) else { return }
        storage.replaceCharacters(in: selection, with: piece)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: selection.location + piece.length, length: 0))
        textView.typingAttributes = base
    }

    /// The paragraph's own attributes at a location, free of any run's
    /// link or citation marks — what new words there should wear.
    func baseAttributes(at location: Int) -> [NSAttributedString.Key: Any] {
        guard let textView, let storage else { return AuthorStyle.body.attributes }
        var attributes: [NSAttributedString.Key: Any]
        if storage.length == 0 {
            attributes = AuthorStyle.body.attributes
        } else {
            attributes = storage.attributes(at: min(max(location - 1, 0), storage.length - 1), effectiveRange: nil)
        }
        for key in [AuthorAttributes.citationIdentifier, AuthorAttributes.citationFormat,
                    AuthorAttributes.citationStartMarker, AuthorAttributes.citationEndMarker,
                    AuthorAttributes.citationPlaceholder, .link, .attachment] {
            attributes.removeValue(forKey: key)
        }
        let style = AuthorStyle.from(identifier: attributes[AuthorAttributes.styleIdentifier] as? String)
        if style == .attachment || style == .attachmentDetails {
            attributes = AuthorStyle.body.attributes
        }
        if attributes[.font] == nil { attributes[.font] = style.font }
        _ = textView
        return attributes
    }

    /// An attachment (picture or table) in a paragraph of its own at the
    /// caret: the line is broken before it when needed, and a body
    /// paragraph follows so writing continues below.
    func insertAttachmentParagraph(_ attachment: NSTextAttachment, caption: String? = nil) {
        guard let textView, let storage else { return }
        let selection = textView.selectedRange()
        let string = storage.string as NSString
        let location = min(selection.location, string.length)
        let piece = NSMutableAttributedString()
        if location > 0, string.character(at: location - 1) != 0x0A {
            piece.append(NSAttributedString(string: "\n", attributes: baseAttributes(at: location)))
        }
        piece.append(LiquidRichText.attachmentParagraph(attachment))
        if let caption, !caption.isEmpty {
            piece.append(NSAttributedString(string: "\n", attributes: AuthorStyle.attachment.attributes))
            piece.append(NSAttributedString(string: caption, attributes: AuthorStyle.attachmentDetails.attributes))
        }
        let atEnd = location >= string.length
        let nextIsBreak = !atEnd && string.character(at: location) == 0x0A
        if atEnd || !nextIsBreak {
            piece.append(NSAttributedString(string: "\n", attributes: AuthorStyle.body.attributes))
        } else {
            piece.append(NSAttributedString(string: "\n", attributes: AuthorStyle.attachment.attributes))
        }
        let range = NSRange(location: location, length: selection.length)
        guard textView.shouldChangeText(in: range, replacementString: piece.string) else { return }
        storage.replaceCharacters(in: range, with: piece)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: location + piece.length, length: 0))
        textView.typingAttributes = AuthorStyle.body.attributes
    }

    /// A picture from bytes, normalised to a sensible size, at the caret.
    func insertImage(data: Data, suggestedName: String?) {
        let normalized = ImageNormalizer.normalized(data: data) ?? (data, DraftEditor.imageExtension(name: suggestedName, data: data))
        let filename = "img-\(UUID().uuidString.prefix(8).lowercased()).\(normalized.1)"
        let attachment = LiquidRichText.imageAttachment(data: normalized.0, filename: filename)
        insertAttachmentParagraph(attachment)
    }

    /// Pictures from files (a drop, the open panel), each in its own
    /// paragraph at the caret.
    func insertImages(from urls: [URL]) {
        for url in urls {
            guard let data = try? Data(contentsOf: url), !data.isEmpty, NSImage(data: data) != nil else { continue }
            insertImage(data: data, suggestedName: url.lastPathComponent)
        }
    }

    /// The open panel, then the pictures chosen.
    func chooseAndInsertImages() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.message = "Choose an image to add to the document."
        panel.prompt = "Insert"
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        insertImages(from: panel.urls)
    }

    /// A new table at the caret.
    func insertTable(rows: Int, columns: Int) {
        let table = LATable(rows: rows, columns: columns)
        insertAttachmentParagraph(TableAttachment(table: table))
    }

    /// Tab-separated text as a table at the caret, as Author makes one
    /// from a paste out of a spreadsheet.
    func insertTable(tabSeparated text: String, replacing range: NSRange) {
        guard let textView, let storage else { return }
        let rows = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let cells = rows.map { $0.components(separatedBy: "\t") }
        let columns = cells.map(\.count).max() ?? 1
        let table = LATable(rows: rows.count, columns: columns)
        for (row, values) in cells.enumerated() {
            for (column, value) in values.enumerated() {
                table.setInput(value.trimmingCharacters(in: .whitespaces), row: row, column: column)
            }
        }
        table.recalculate()
        if range.length > 0 {
            guard textView.shouldChangeText(in: range, replacementString: "") else { return }
            storage.deleteCharacters(in: range)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
        }
        insertAttachmentParagraph(TableAttachment(table: table))
    }

    /// A table was edited in its grid: the attachment re-encodes and the
    /// layout re-measures where it sits.
    func tableDidChange(_ attachment: TableAttachment) {
        guard let textView, let storage else { return }
        attachment.updateFileWrapper()
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard (value as? TableAttachment) === attachment else { return }
            textView.layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            textView.layoutManager?.invalidateDisplay(forCharacterRange: range)
            stop.pointee = true
        }
        textView.needsDisplay = true
        editor?.noteTextChanged()
    }
}

/// The text view: owns the context menu (the text system builds its
/// menu without consulting the delegate on current SDKs), and takes
/// pictures by drop and paste.
final class RichNSTextView: NSTextView, NSMenuDelegate {
    weak var controller: RichTextController?

    override func menu(for event: NSEvent) -> NSMenu? {
        let system = super.menu(for: event)
        let menu = NSMenu()
        menu.allowsContextMenuPlugIns = false
        menu.delegate = self
        let point = convert(event.locationInWindow, from: nil)
        controller?.augment(menu, in: self, at: characterIndexForInsertion(at: point))
        if let system {
            let spelling = system.items.filter(Self.isSpellingItem)
            if !spelling.isEmpty {
                if !menu.items.isEmpty { menu.addItem(.separator()) }
                for item in spelling {
                    system.removeItem(item)
                    menu.addItem(item)
                }
            }
        }
        for item in menu.items { item.tag = Self.ownedItemTag }
        return menu
    }

    static let ownedItemTag = 0x0716
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.tag != Self.ownedItemTag {
            menu.removeItem(item)
        }
    }

    private nonisolated static func isSpellingItem(_ item: NSMenuItem) -> Bool {
        let spellingSelectors: Set<String> = [
            "changeSpelling:", "ignoreSpelling:", "learnSpelling:",
            "unlearnSpelling:", "showGuessPanel:", "checkSpelling:",
        ]
        func matches(_ menuItem: NSMenuItem) -> Bool {
            guard let action = menuItem.action else { return false }
            let name = NSStringFromSelector(action)
            return spellingSelectors.contains(name)
                || name.hasPrefix("toggleAutomaticSpellingCorrection")
                || name.hasPrefix("toggleContinuousSpellChecking")
                || name.hasPrefix("toggleGrammarChecking")
        }
        if matches(item) { return true }
        if let submenu = item.submenu { return submenu.items.contains(where: matches) }
        return false
    }

    // MARK: Paste

    /// A picture on the clipboard (and no words) is inserted as one;
    /// words go through the delegate's citation cascade as plain text —
    /// another app's fonts and colours never come along.
    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let hasWords = pasteboard.string(forType: .string)?.isEmpty == false
        if !hasWords, let controller {
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
                .urlReadingFileURLsOnly: true,
                .urlReadingContentsConformToTypes: [UTType.image.identifier],
            ]) as? [URL], !urls.isEmpty {
                controller.insertImages(from: urls)
                return
            }
            if let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage],
               let image = images.first, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                controller.insertImage(data: png, suggestedName: "pasted.png")
                return
            }
        }
        pasteAsPlainText(sender)
    }

    // MARK: Drop

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let controller,
           let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
               .urlReadingFileURLsOnly: true,
               .urlReadingContentsConformToTypes: [UTType.image.identifier],
           ]) as? [URL], !urls.isEmpty {
            let point = convert(sender.draggingLocation, from: nil)
            setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
            controller.insertImages(from: urls)
            return true
        }
        return super.performDragOperation(sender)
    }
}

/// Pictures added to a document made one sensible size: width-capped
/// and re-encoded, so documents stay small without visibly losing
/// anything — Author's rule, so a picture is the same in both apps.
enum ImageNormalizer {
    static let maxWidth: CGFloat = 2048

    /// The bytes and extension to store, or nil when the data is not an
    /// image this Mac can decode.
    static func normalized(data: Data) -> (Data, String)? {
        guard let bitmap = NSBitmapImageRep(data: data) else { return nil }
        let isJPEG = data.starts(with: [0xFF, 0xD8])
        let pixelsWide = CGFloat(bitmap.pixelsWide)
        let alreadySmall = pixelsWide <= maxWidth
        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        // Already a modest PNG or JPEG: keep the bytes as they are.
        if alreadySmall, isJPEG || isPNG { return (data, isJPEG ? "jpeg" : "png") }
        guard let image = NSImage(data: data) else { return nil }
        var size = image.size
        if pixelsWide > maxWidth {
            let scale = maxWidth / pixelsWide
            size = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        }
        let scaled = NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.high])
            return true
        }
        guard let tiff = scaled.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let hasAlpha = bitmap.hasAlpha
        if hasAlpha, let png = rep.representation(using: .png, properties: [:]) { return (png, "png") }
        if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) { return (jpeg, "jpeg") }
        return nil
    }
}
