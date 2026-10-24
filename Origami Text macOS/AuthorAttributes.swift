import AppKit

/// Author's conventions for structure inside an attributed string,
/// mirrored by name so a `.liquid` written here opens in Author
/// unchanged and one saved by Author reads back. Nothing of Author's is
/// linked: these are the attribute keys, style identifiers and format
/// names its `LiquidAuthorTextCore` archives into `Content.liquidstore`.
/// Change one only when Author changes it.
enum AuthorAttributes {

    // MARK: Attribute keys

    /// The paragraph's style — `body`, `header1`…, `bulletList` — the
    /// one attribute every run carries. See `AuthorStyle`.
    static let styleIdentifier = NSAttributedString.Key("LATextStyleIdentifierAttribute")
    /// A list item's second style: the list kind rides on every run of
    /// the item, the stub included.
    static let styleSecondaryIdentifier = NSAttributedString.Key("LATextStyleSecondaryIdentifierAttribute")
    /// Marks the "• " / "- " stub of a list item (value `listStub`).
    static let structureIdentifiers = NSAttributedString.Key("LATextStructureIdentifiersAttribute")
    static let listStubValue = "listStub"
    /// Author stores a character range with every style; always (0, 0)
    /// in saved documents, kept for fidelity.
    static let characterRange = NSAttributedString.Key("LATextAttributesCharacterRange")

    /// A citation run: the record's identifier (a key into
    /// `Citations.plist`), and how the citation is shown.
    static let citationIdentifier = NSAttributedString.Key("LACitationIdentifierAttributeName")
    static let citationFormat = NSAttributedString.Key("LACitationFormatAttributeName")
    /// The citation's opening ("(" or "“") and closing ("Name Year)")
    /// runs — what stands around the cited words.
    static let citationStartMarker = NSAttributedString.Key("LACitationStartMarker")
    static let citationEndMarker = NSAttributedString.Key("LACitationEndMarker")
    static let citationStartMarkerValue = "LACitationStartMarker"
    static let citationEndMarkerValue = "LACitationEndMarker"
    /// A citation Origami Text is still looking up (a pasted DOI); never
    /// saved — the lookup replaces the run or removes it.
    static let citationPlaceholder = NSAttributedString.Key("citationPlaceholderAttributeName")

    /// Text the user may not edit by hand (an image's caption line).
    static let uneditable = NSAttributedString.Key("uneditable")

    /// Attributes Author strips before saving — display-only state.
    static let transientKeys: [NSAttributedString.Key] = [
        NSAttributedString.Key("LACitationIdentifierForOutput"),
        NSAttributedString.Key("GlossaryIdentifierForOutput"),
        NSAttributedString.Key("CodeBlockIntentLanguageHint"),
        NSAttributedString.Key("blockBackgroundColor"),
        NSAttributedString.Key("thematicBreak"),
        NSAttributedString.Key("quoteStripe"),
        citationPlaceholder,
    ]

    // MARK: Archived class names

    /// What Author's archive calls its own attachment classes. Tables
    /// must be written under Author's name or Author shows a broken
    /// image; images may be plain `NSTextAttachment`s, which Author
    /// normalises into its own class on load.
    static let archivedTableClassName = "LiquidAuthorTextCore.LATableAttachment"
    static let archivedTableClassNames = [archivedTableClassName, "LATableAttachment"]
    static let archivedImageClassNames = [
        "LiquidAuthorTextCore.InlineImageAttachment", "InlineImageAttachment",
        "LiquidAuthorTextCore.LAModelAttachment", "LAModelAttachment",
    ]
    static let archivedCellClassNames = [
        "LiquidAuthorTextCore.ScaledImageCell", "ScaledImageCell",
        "LiquidAuthorTextCore.LATableAttachmentCell", "LATableAttachmentCell",
    ]
    /// A table's JSON lives in its attachment's file wrapper under this
    /// prefix, as Author names it.
    static let tableFilePrefix = "AuthorTable-"

    // MARK: Package members

    static let contentsFolder = "Contents"
    static let liquidstoreMember = "Content.liquidstore"
    static let rtfdMember = "Content.rtfd"
    static let versionMember = "Version.plist"
    static let authorMember = "Author.plist"
    static let citationsMember = "Citations.plist"
    static let formatVersion = 8.11
    /// Author's `DocumentTitleKey` — lowercase; a capital "Title" is a
    /// key Author never reads, and the document would open under its
    /// file name instead.
    static let titleKey = "title"
    /// Origami Text's own fields, kept under one key in `Author.plist`,
    /// which Author round-trips whole.
    static let origamiKey = "origami"
    /// The Origami EPUB export's settings, beside it.
    static let origamiExportKey = "origamiExport"
    /// Author's export metadata: abstract, keywords, acknowledgements,
    /// meeting details (its `DocumentExportMeta`).
    static let exportMetaMember = "exportMeta.json"
    /// Author's Defined Concepts: `{"entries": {id: GlossaryEntry}}`.
    static let glossaryMember = "glossary.json"
}

/// How a citation is rendered in the text — Author's `LACitationFormat`,
/// its raw values as archived. Origami Text writes two: a bare
/// name-and-year "(Hegland 2026)", and cited words with the label after
/// them "“words” (Hegland 2026)". The rest are read.
enum AuthorCitationFormat: String {
    case quoteMarks = "quotesNoName"
    case quotesWithNameAndYear = "quoteWithName"
    case italicText = "paraphrased"
    case italicTextWithNameAndYear = "quote"
    case textWithNameAndYear = "invisible"
    case textWithYear = "date"
    case annotatedBibliography = "annotatedBibliography"
    case blockQuote = "paragraphQuote"
    case blockQuoteWithName = "paragraphQuoteWithName"
    case nameAndDate = "nameAndDate"
    case attachment = "attachment"
}

/// Author's paragraph styles, by their archived identifier. The editor
/// applies one per paragraph; the bridge reads one back into the
/// document's heading levels and list lines.
enum AuthorStyle: String, CaseIterable {
    case body, code, bibliography, citation
    case header1, header2, header3, header4, header5, header6
    case bulletList, dashList
    case attachment, attachmentDetails

    /// The heading level this style stands for, clamped to the
    /// document format's three (header4–6 read as 3).
    var headingLevel: Int? {
        switch self {
        case .header1: 1
        case .header2: 2
        case .header3: 3
        case .header4, .header5, .header6: 3
        default: nil
        }
    }

    static func heading(_ level: Int) -> AuthorStyle {
        switch level {
        case ...1: .header1
        case 2: .header2
        default: .header3
        }
    }

    /// The characters a list item opens with, as Author writes them.
    var listStub: String? {
        switch self {
        case .bulletList: "• "
        case .dashList: "- "
        default: nil
        }
    }

    var isList: Bool { listStub != nil }
    var isHeading: Bool { headingLevel != nil }

    /// Reads a style identifier as archived, Author's three list spellings
    /// included; anything unknown is body.
    static func from(identifier: String?) -> AuthorStyle {
        guard let identifier else { return .body }
        if let style = AuthorStyle(rawValue: identifier) { return style }
        switch identifier {
        case "list": return .bulletList
        case "imageAttachment": return .attachment
        default: return .body
        }
    }

    // MARK: Editor presentation

    /// The face a paragraph of this style wears in Origami Text's editor —
    /// the reader's chosen families (Settings ▸ Reading ▸ Fonts), at
    /// Author's sizes so the two apps agree on measure. Author maps
    /// families to its own on load; sizes and traits travel.
    var font: NSFont {
        switch self {
        case .header1: AuthorStyle.headingFont(25)
        case .header2: AuthorStyle.headingFont(19)
        case .header3: AuthorStyle.headingFont(17)
        case .header4: AuthorStyle.headingFont(15)
        case .header5: AuthorStyle.headingFont(14)
        case .header6: AuthorStyle.headingFont(12)
        case .code: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        case .attachmentDetails: AppFonts.nsBody(15, italic: true)
        default: AppFonts.nsBody(17)
        }
    }

    /// The face Author gives a paragraph of this style by default — its
    /// own families at its own sizes: Times New Roman 17 for body, Optima
    /// for headings (25/19/17/15/14/12), Menlo for code, Times italic for
    /// a caption. This is what the archive carries. Author re-applies
    /// every style from its user's settings when it opens a document, so
    /// these decide nothing there; they keep the RTFD backup, which any
    /// other app reads, in Author's shape rather than Origami Text's.
    var authorFont: NSFont {
        func named(_ name: String, _ size: CGFloat, fallback: NSFont) -> NSFont {
            NSFont(name: name, size: size) ?? fallback
        }
        let times = { (size: CGFloat) in
            named("Times New Roman", size, fallback: AuthorStyle.fallbackSerif(size))
        }
        let optima = { (size: CGFloat) in
            named("Optima Regular", size, fallback: NSFont(name: "Optima", size: size) ?? times(size))
        }
        switch self {
        case .header1: return optima(25)
        case .header2: return optima(19)
        case .header3: return optima(17)
        case .header4: return optima(15)
        case .header5: return optima(14)
        case .header6: return optima(12)
        case .code: return named("Menlo Regular", 17, fallback: NSFont.monospacedSystemFont(ofSize: 17, weight: .regular))
        case .attachmentDetails: return times(17).withTraits(italic: true)
        default: return times(17)
        }
    }

    private static func fallbackSerif(_ size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        guard let serif = base.fontDescriptor.withDesign(.serif) else { return base }
        return NSFont(descriptor: serif, size: size) ?? base
    }

    private static func headingFont(_ size: CGFloat) -> NSFont {
        let family = AppFonts.headingFamily
        let base = NSFont(name: family, size: size) ?? AppFonts.nsBody(size, bold: true)
        let descriptor = base.fontDescriptor.withSymbolicTraits(
            base.fontDescriptor.symbolicTraits.union(.bold))
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        switch self {
        case .header1, .header2, .header3, .header4, .header5, .header6:
            style.paragraphSpacingBefore = 14
            style.paragraphSpacing = 6
            style.lineSpacing = 2
        case .bulletList, .dashList:
            style.headIndent = 22
            style.firstLineHeadIndent = 0
            style.tabStops = [NSTextTab(textAlignment: .left, location: 22)]
            style.paragraphSpacing = 3
            style.lineSpacing = 4
        case .code:
            style.paragraphSpacing = 0
            style.lineSpacing = 2
        case .attachment:
            style.alignment = .center
            style.paragraphSpacingBefore = 10
            style.paragraphSpacing = 4
        case .attachmentDetails:
            style.alignment = .center
            style.paragraphSpacing = 12
        default:
            style.paragraphSpacing = 8
            style.lineSpacing = 5
        }
        return style
    }

    /// The complete attribute set for a run of this style, as Author
    /// stores it: font, colour, paragraph style, the identifier, and the
    /// (always empty) character range.
    var attributes: [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle,
            AuthorAttributes.styleIdentifier: rawValue,
            AuthorAttributes.characterRange: NSValue(range: NSRange(location: 0, length: 0)),
        ]
    }
}

extension NSFont {
    /// This font with bold and/or italic added or removed, same family
    /// and size — how the editor emphasises and how the bridge reads
    /// emphasis back.
    func withTraits(bold: Bool? = nil, italic: Bool? = nil) -> NSFont {
        var traits = fontDescriptor.symbolicTraits
        if let bold { if bold { traits.insert(.bold) } else { traits.remove(.bold) } }
        if let italic { if italic { traits.insert(.italic) } else { traits.remove(.italic) } }
        let descriptor = fontDescriptor.withSymbolicTraits(traits)
        if let font = NSFont(descriptor: descriptor, size: pointSize) { return font }
        // A family without the face (no italic cut): the font manager's
        // synthesised variant.
        var font = self
        let manager = NSFontManager.shared
        if let bold { font = manager.convert(font, toHaveTrait: bold ? .boldFontMask : .unboldFontMask) }
        if let italic { font = manager.convert(font, toHaveTrait: italic ? .italicFontMask : .unitalicFontMask) }
        return font
    }

    var isBold: Bool { fontDescriptor.symbolicTraits.contains(.bold) }
    var isItalic: Bool { fontDescriptor.symbolicTraits.contains(.italic) }
}
