import AppKit

/// An Author document on disk: the `.liquid` package, read and written
/// in Author's own layout so the two apps share one editable file.
///
/// ```
/// Name.liquid/
///   Contents/
///     Content.liquidstore   NSKeyedArchiver of the body NSAttributedString
///     Content.rtfd/         the same text as RTFD — Author's fallback
///     Version.plist         FormatVersion, FontSizeModifier, …
///     Author.plist          Title, and Origami Text's fields under "origami"
///     Citations.plist       [citation id: record]
///     …                     anything else Author keeps (glossary, Map) — preserved
/// ```
///
/// Origami Text owns the first five members; every other member of
/// `Contents` (and of the package root) is carried through a save
/// untouched, so a document that came from Author keeps its Map and
/// glossary when it goes back.
struct LiquidPackage {
    static let fileExtension = "liquid"

    /// The body as Author archives it: structure in attributes (see
    /// `AuthorAttributes`), images and tables as attachments.
    var text: NSAttributedString
    var citations: [AuthorCitation]
    var title: String
    /// Author.plist as read, less the title — round-tripped whole.
    var authorPlist: [String: Any]
    /// Version.plist as read — round-tripped, our values refreshed.
    var versionPlist: [String: Any]
    /// Origami Text's document fields (see `LiquidRichText.origamiRecord`),
    /// a JSON document kept as a string under `Author.plist["origami"]`.
    var origamiJSON: String?
    /// What the Origami EPUB export asks (`ExportSettings`): its own part
    /// under `Author.plist["origamiExport"]`, and abstract, keywords and
    /// acknowledgements in Author's `Contents/exportMeta.json`.
    var exportSettings = ExportSettings()
    /// `exportMeta.json` as read — Author's meeting details and the rest
    /// ride through a save untouched.
    var exportMeta: [String: Any] = [:]
    /// Author's `Contents/glossary.json` entries by id, as read — the
    /// document's Defined Concepts in Author's own shape, Author's section
    /// entries and all. Origami's concepts are written into it (see
    /// `LiquidRichText.glossaryEntries`), so Author sees them as its own.
    var glossaryEntries: [String: Any] = [:]
    /// Members of `Contents/` that are not ours, by name.
    var otherContents: [String: FileWrapper]
    /// Members of the package root other than `Contents` (Author's
    /// QuickLook folder).
    var otherRoot: [String: FileWrapper]

    init(text: NSAttributedString, citations: [AuthorCitation] = [], title: String) {
        self.text = text
        self.citations = citations
        self.title = title
        authorPlist = [:]
        versionPlist = [:]
        origamiJSON = nil
        otherContents = [:]
        otherRoot = [:]
    }

    enum ReadError: LocalizedError {
        case notAPackage(URL)
        case noContents(URL)
        case noText(URL)

        var errorDescription: String? {
            switch self {
            case .notAPackage(let url): "“\(url.lastPathComponent)” is not an Author document."
            case .noContents(let url): "“\(url.lastPathComponent)” has no Contents folder."
            case .noText(let url): "The text of “\(url.lastPathComponent)” could not be read."
            }
        }
    }

    // MARK: Reading

    static func read(at url: URL) throws -> LiquidPackage {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw ReadError.notAPackage(url) }
        let root = try FileWrapper(url: url, options: .immediate)
        guard let contents = root.fileWrappers?[AuthorAttributes.contentsFolder],
              let members = contents.fileWrappers else { throw ReadError.noContents(url) }

        func plist(_ name: String) -> [String: Any] {
            guard let wrapper = members[name], wrapper.isRegularFile,
                  let data = wrapper.regularFileContents,
                  let object = try? PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any] else { return [:] }
            return object
        }

        // The text: Author's archive first, the RTFD when the archive
        // cannot be read.
        var text: NSAttributedString?
        if let store = members[AuthorAttributes.liquidstoreMember], store.isRegularFile,
           let data = store.regularFileContents {
            text = unarchive(data)
        }
        if text == nil, let rtfd = members[AuthorAttributes.rtfdMember], rtfd.isDirectory {
            text = NSAttributedString(rtfdFileWrapper: rtfd, documentAttributes: nil)
        }
        guard let text else { throw ReadError.noText(url) }

        var authorPlist = plist(AuthorAttributes.authorMember)
        let title = (authorPlist[AuthorAttributes.titleKey] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let origamiJSON = authorPlist[AuthorAttributes.origamiKey] as? String
        let exportJSON = authorPlist[AuthorAttributes.origamiExportKey] as? String
        authorPlist.removeValue(forKey: AuthorAttributes.titleKey)
        authorPlist.removeValue(forKey: AuthorAttributes.origamiKey)
        authorPlist.removeValue(forKey: AuthorAttributes.origamiExportKey)
        var exportMeta: [String: Any] = [:]
        if let wrapper = members[AuthorAttributes.exportMetaMember], wrapper.isRegularFile,
           let data = wrapper.regularFileContents,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            exportMeta = object
        }
        var glossaryEntries: [String: Any] = [:]
        if let wrapper = members[AuthorAttributes.glossaryMember], wrapper.isRegularFile,
           let data = wrapper.regularFileContents,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let entries = object["entries"] as? [String: Any] {
            glossaryEntries = entries
        }

        let citations = plist(AuthorAttributes.citationsMember)
            .compactMap { key, value -> AuthorCitation? in
                guard let record = value as? [String: Any] else { return nil }
                var citation = AuthorCitation(plist: record)
                if citation.identifier.isEmpty { citation.identifier = key }
                return citation
            }
            .sorted { $0.identifier < $1.identifier }

        var package = LiquidPackage(text: LiquidRichText.normalizedForEditing(text),
                                    citations: citations, title: title)
        package.authorPlist = authorPlist
        package.versionPlist = plist(AuthorAttributes.versionMember)
        package.origamiJSON = origamiJSON
        package.exportMeta = exportMeta
        package.glossaryEntries = glossaryEntries
        package.exportSettings = (exportJSON.flatMap(ExportSettings.init(json:)) ?? ExportSettings())
            .merging(exportMeta: exportMeta)
        let owned: Set<String> = [
            AuthorAttributes.liquidstoreMember, AuthorAttributes.rtfdMember,
            AuthorAttributes.versionMember, AuthorAttributes.authorMember,
            AuthorAttributes.citationsMember, AuthorAttributes.exportMetaMember,
            AuthorAttributes.glossaryMember,
        ]
        package.otherContents = members.filter { !owned.contains($0.key) }
        package.otherRoot = (root.fileWrappers ?? [:]).filter { $0.key != AuthorAttributes.contentsFolder }
        return package
    }

    /// Author's archive, read with Author's own attachment classes
    /// mapped to this app's: tables become `TableAttachment`s, pictures
    /// plain attachments, their drawing cells the system's. Anything
    /// else the archive names that descends from an attachment or a
    /// cell reads the same way; a truly unknown class fails the read,
    /// and the RTFD stands in.
    private static func unarchive(_ data: Data) -> NSAttributedString? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = false
        for name in AuthorAttributes.archivedTableClassNames {
            unarchiver.setClass(TableAttachment.self, forClassName: name)
        }
        for name in AuthorAttributes.archivedImageClassNames {
            unarchiver.setClass(NSTextAttachment.self, forClassName: name)
        }
        for name in AuthorAttributes.archivedCellClassNames {
            unarchiver.setClass(NSTextAttachmentCell.self, forClassName: name)
        }
        let substitutes = ClassSubstitution()
        unarchiver.delegate = substitutes
        defer { unarchiver.finishDecoding() }
        return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSAttributedString
    }

    private final class ClassSubstitution: NSObject, NSKeyedUnarchiverDelegate {
        func unarchiver(_ unarchiver: NSKeyedUnarchiver,
                        cannotDecodeObjectOfClassName name: String,
                        originalClasses classNames: [String]) -> AnyClass? {
            if classNames.contains("NSTextAttachment") { return NSTextAttachment.self }
            if classNames.contains("NSTextAttachmentCell") { return NSTextAttachmentCell.self }
            return nil
        }
    }

    // MARK: Writing

    /// Writes the package, atomically, at `url` (replacing what is there).
    func write(to url: URL) throws {
        let saved = archiveReady(text)

        var contents: [String: FileWrapper] = otherContents
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.setClassName(AuthorAttributes.archivedTableClassName, for: TableAttachment.self)
        archiver.encode(saved, forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        contents[AuthorAttributes.liquidstoreMember] = FileWrapper(regularFileWithContents: archiver.encodedData)

        // The RTFD backup — Author's fallback reader, and what any other
        // app sees. A failure here is not fatal: the archive is the record.
        if let rtfd = try? saved.fileWrapper(
            from: NSRange(location: 0, length: saved.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) {
            contents[AuthorAttributes.rtfdMember] = rtfd
        }

        var version = versionPlist
        version["FormatVersion"] = AuthorAttributes.formatVersion
        // No text size of ours. Author re-applies every style from its
        // own settings on opening (its format pass ends in repairFontSizes
        // and applyUserFonts), scaled by the document's FontSizeModifier
        // — so a package we made carries none, and Author uses its
        // default, as for a document of its own. Only a value Author
        // itself wrote (the reader's ⌘+/⌘− on that document) is kept; the
        // 0 written before this was understood would have taken 17 points
        // off every face.
        let modifier = (version["FontSizeModifier"] as? NSNumber)?.doubleValue ?? 0
        if modifier <= 0 { version.removeValue(forKey: "FontSizeModifier") }
        if version["Type"] == nil { version["Type"] = "readwrite" }
        version["LastOpenedBy"] = "macOS"
        contents[AuthorAttributes.versionMember] = try Self.plistWrapper(version)

        var author = authorPlist
        // A capital "Title" from packages written before the key was
        // corrected: Author never read it; it goes.
        author.removeValue(forKey: "Title")
        author[AuthorAttributes.titleKey] = title
        if let origamiJSON { author[AuthorAttributes.origamiKey] = origamiJSON }
        if let exportJSON = exportSettings.json { author[AuthorAttributes.origamiExportKey] = exportJSON }
        contents[AuthorAttributes.authorMember] = try Self.plistWrapper(author)

        // Author's export metadata, with the abstract, keywords and
        // acknowledgements as set here — written when there is anything
        // to say, so an untouched document gains no empty member.
        let settings = exportSettings
        if !exportMeta.isEmpty || !settings.abstract.isEmpty || !settings.keywords.isEmpty
            || !settings.acknowledgements.isEmpty {
            let meta = settings.exportMeta(updating: exportMeta)
            if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
                contents[AuthorAttributes.exportMetaMember] = FileWrapper(regularFileWithContents: data)
            }
        }

        // The Defined Concepts, in Author's glossary shape, when there are any.
        if !glossaryEntries.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: ["entries": glossaryEntries],
                                                   options: [.prettyPrinted, .sortedKeys]) {
            contents[AuthorAttributes.glossaryMember] = FileWrapper(regularFileWithContents: data)
        }

        var citationStore: [String: Any] = [:]
        for citation in citations { citationStore[citation.identifier] = citation.plist() }
        contents[AuthorAttributes.citationsMember] = try Self.plistWrapper(citationStore)

        var root = otherRoot
        root[AuthorAttributes.contentsFolder] = FileWrapper(directoryWithFileWrappers: contents)
        let package = FileWrapper(directoryWithFileWrappers: root)
        try package.write(to: url, options: .atomic, originalContentsURL: nil)
    }

    private static func plistWrapper(_ plist: [String: Any]) throws -> FileWrapper {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        return FileWrapper(regularFileWithContents: data)
    }

    /// The text as the archive should hold it: display-only attributes
    /// gone; every run in Author's own face for its style (the editor's
    /// reading faces are this app's, not the document's — emphasis
    /// beyond the style's own weight carries over as bold and italic);
    /// and every attachment's drawing cell dropped — a cell class of
    /// this app's would stop Author's reader; Author installs its own
    /// cells on load, as this app does.
    private func archiveReady(_ text: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: copy.length)
        for key in AuthorAttributes.transientKeys { copy.removeAttribute(key, range: full) }
        let string = copy.string as NSString
        var location = 0
        while location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            defer { location = NSMaxRange(paragraph) }
            guard paragraph.length > 0 else { continue }
            let attributes = copy.attributes(at: paragraph.location, effectiveRange: nil)
            guard attributes[.attachment] == nil else { continue }
            let style = AuthorStyle.from(identifier: attributes[AuthorAttributes.styleIdentifier] as? String)
            let editorFace = style.font
            let authorFace = style.authorFont
            copy.enumerateAttribute(.font, in: paragraph) { value, range, _ in
                let existing = value as? NSFont
                let bold = (existing?.isBold ?? false) && !editorFace.isBold
                let italic = (existing?.isItalic ?? false) && !editorFace.isItalic
                copy.addAttribute(.font, value: authorFace.withTraits(bold: bold ? true : nil,
                                                                      italic: italic ? true : nil), range: range)
            }
        }
        copy.enumerateAttribute(.attachment, in: full) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let bare: NSTextAttachment
            if let table = attachment as? TableAttachment {
                // A fresh table attachment carries the same wrapper and
                // no cell; the archiver names it for Author.
                table.updateFileWrapper()
                bare = TableAttachment(table: table.table)
                bare.attachmentCell = nil
            } else {
                bare = NSTextAttachment(fileWrapper: attachment.fileWrapper)
                if bare.fileWrapper == nil, let image = attachment.image,
                   let tiff = image.tiffRepresentation {
                    let wrapper = FileWrapper(regularFileWithContents: tiff)
                    wrapper.preferredFilename = "image.tiff"
                    bare.fileWrapper = wrapper
                }
                bare.image = attachment.image
            }
            copy.addAttribute(.attachment, value: bare, range: range)
        }
        return copy
    }
}
