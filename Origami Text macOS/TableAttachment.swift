import AppKit

/// An inline table in the editor's text: one attachment character
/// standing for an `LATable`, the grid stored as JSON in the attachment's
/// file wrapper exactly as Author does (`AuthorTable-<id>.json`), so the
/// table rides through the `.liquid` archive and the RTFD alike. The
/// archive writes this class under Author's name (see `LiquidPackage`),
/// so Author rebuilds its own `LATableAttachment` from the same wrapper.
final class TableAttachment: NSTextAttachment {

    private(set) var table: LATable

    init(table: LATable) {
        self.table = table
        super.init(data: nil, ofType: nil)
        table.recalculate()
        installCell()
        updateFileWrapper()
    }

    required init?(coder: NSCoder) {
        table = LATable()
        super.init(coder: coder)
        if let fileWrapper, let decoded = Self.table(from: fileWrapper) { table = decoded }
        table.recalculate()
        installCell()
    }

    /// The text system's designated initializer, used when attachments
    /// are rebuilt from an RTFD — the table decodes from the wrapper.
    override init(data contentData: Data?, ofType uti: String?) {
        table = LATable()
        super.init(data: contentData, ofType: uti)
        if let fileWrapper, let decoded = Self.table(from: fileWrapper) { table = decoded }
        table.recalculate()
        installCell()
    }

    private func installCell() {
        let cell = TableAttachmentCell()
        cell.tableAttachment = self
        attachmentCell = cell
    }

    /// Re-encodes the grid into the file wrapper — call after every edit,
    /// so what is saved is what is shown.
    func updateFileWrapper() {
        (attachmentCell as? TableAttachmentCell)?.invalidateMetrics()
        guard let data = try? JSONEncoder().encode(table) else { return }
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = AuthorAttributes.tableFilePrefix + table.identifier + ".json"
        fileWrapper = wrapper
    }

    /// The table in a wrapper, when the wrapper holds one of ours (or
    /// Author's — same prefix, same JSON).
    static func table(from fileWrapper: FileWrapper) -> LATable? {
        let name = fileWrapper.preferredFilename ?? fileWrapper.filename ?? ""
        guard name.hasPrefix(AuthorAttributes.tableFilePrefix) || name.hasSuffix(".json"),
              let data = fileWrapper.regularFileContents else { return nil }
        return try? JSONDecoder().decode(LATable.self, from: data)
    }

    /// Whether a plain attachment read from an archive is really a table.
    static func isTableWrapper(_ fileWrapper: FileWrapper?) -> Bool {
        guard let fileWrapper else { return false }
        return table(from: fileWrapper) != nil
    }

    /// The grid as pipe-table text — the document format's plain-text
    /// fallback for a table paragraph.
    var pipeText: String {
        table.cells.map { row in
            "| " + row.map(\.value).joined(separator: " | ") + " |"
        }.joined(separator: "\n")
    }
}

/// Draws the grid inline, the table stretched to the text column:
/// columns sized to what they hold (short labels keep what they ask for,
/// long prose takes the rest), rows as tall as their wrapped text.
final class TableAttachmentCell: NSTextAttachmentCell {

    weak var tableAttachment: TableAttachment?

    private let minimumRowHeight: CGFloat = 26
    private let minimumColumnWidth: CGFloat = 44
    private let textInset: CGFloat = 6
    private let verticalInset: CGFloat = 5
    private let fallbackWidth: CGFloat = 480

    private static let cellFont = NSFont.systemFont(ofSize: 13)
    private static let headerFont = NSFont.systemFont(ofSize: 13, weight: .semibold)

    struct Metrics {
        var columnWidths: [CGFloat]
        var rowHeights: [CGFloat]
        var height: CGFloat { rowHeights.reduce(0, +) + 1 }
    }

    private var metricsByWidth: [CGFloat: Metrics] = [:]

    func invalidateMetrics() { metricsByWidth.removeAll() }

    private func textAttributes(header: Bool) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return [
            .font: header ? Self.headerFont : Self.cellFont,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph,
        ]
    }

    func metrics(forWidth width: CGFloat) -> Metrics {
        let key = width.rounded()
        if let cached = metricsByWidth[key] { return cached }
        let computed = computedMetrics(forWidth: key)
        if metricsByWidth.count > 8 { metricsByWidth.removeAll() }
        metricsByWidth[key] = computed
        return computed
    }

    private func computedMetrics(forWidth width: CGFloat) -> Metrics {
        guard let table = tableAttachment?.table, table.columnCount > 0, table.rowCount > 0 else {
            return Metrics(columnWidths: [max(width, minimumColumnWidth)], rowHeights: [minimumRowHeight])
        }
        var natural = [CGFloat](repeating: minimumColumnWidth, count: table.columnCount)
        for row in 0..<table.rowCount {
            let attributes = textAttributes(header: row == 0 && table.rowCount > 1)
            for column in 0..<table.columnCount {
                let value = table.cell(row: row, column: column).value
                guard !value.isEmpty else { continue }
                let needed = (value as NSString).size(withAttributes: attributes).width + textInset * 2
                natural[column] = max(natural[column], needed.rounded(.up))
            }
        }
        let columnWidths = fitting(natural, into: width)
        var rowHeights: [CGFloat] = []
        for row in 0..<table.rowCount {
            let attributes = textAttributes(header: row == 0 && table.rowCount > 1)
            var height = minimumRowHeight
            for column in 0..<table.columnCount {
                let value = table.cell(row: row, column: column).value
                guard !value.isEmpty else { continue }
                let available = max(1, columnWidths[column] - textInset * 2)
                let bounds = (value as NSString).boundingRect(
                    with: NSSize(width: available, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: attributes)
                height = max(height, bounds.height.rounded(.up) + verticalInset * 2)
            }
            rowHeights.append(height)
        }
        return Metrics(columnWidths: columnWidths, rowHeights: rowHeights)
    }

    /// Shares `width` among columns: one asking less than its fair share
    /// keeps what it asks; the rest divide the remainder in proportion.
    private func fitting(_ natural: [CGFloat], into width: CGFloat) -> [CGFloat] {
        let wanted = natural.reduce(0, +)
        guard wanted > 0, width > 0 else { return natural }
        if wanted <= width {
            // Room to spare: stretch in proportion so the grid fills the measure.
            let scale = width / wanted
            return natural.map { ($0 * scale).rounded(.down) }
        }
        var widths = natural
        var remaining = width
        var flexible = Array(natural.indices)
        var changed = true
        while changed {
            changed = false
            let share = remaining / CGFloat(max(flexible.count, 1))
            for index in flexible where natural[index] <= share {
                widths[index] = natural[index]
                remaining -= natural[index]
                flexible.removeAll { $0 == index }
                changed = true
            }
        }
        let wantedFlexible = flexible.reduce(0) { $0 + natural[$1] }
        for index in flexible {
            widths[index] = max(minimumColumnWidth,
                                (remaining * natural[index] / max(wantedFlexible, 1)).rounded(.down))
        }
        return widths
    }

    // MARK: Layout

    // The text system declares these without isolation; it calls them
    // on the main thread, which is where the table lives.
    nonisolated override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                                        glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        MainActor.assumeIsolated {
            let width = max(minimumColumnWidth,
                            textContainer.size.width - textContainer.lineFragmentPadding * 2 - 2)
            let metrics = metrics(forWidth: width)
            return NSRect(x: 0, y: 0, width: width, height: metrics.height)
        }
    }

    nonisolated override func cellSize() -> NSSize {
        MainActor.assumeIsolated {
            let metrics = metrics(forWidth: fallbackWidth)
            return NSSize(width: fallbackWidth, height: metrics.height)
        }
    }

    nonisolated override func cellBaselineOffset() -> NSPoint { .zero }

    // MARK: Drawing

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?,
                       characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let table = tableAttachment?.table else { return }
        let metrics = metrics(forWidth: cellFrame.width)
        let flipped = controlView?.isFlipped ?? true
        let gridColor = NSColor.separatorColor
        let headerFill = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)

        var y = cellFrame.minY
        for row in 0..<table.rowCount {
            let rowHeight = row < metrics.rowHeights.count ? metrics.rowHeights[row] : minimumRowHeight
            var x = cellFrame.minX
            let isHeader = row == 0 && table.rowCount > 1
            if isHeader {
                headerFill.setFill()
                NSRect(x: cellFrame.minX, y: y, width: cellFrame.width, height: rowHeight).fill()
            }
            for column in 0..<table.columnCount {
                let columnWidth = column < metrics.columnWidths.count ? metrics.columnWidths[column] : minimumColumnWidth
                let rect = NSRect(x: x, y: y, width: columnWidth, height: rowHeight)
                gridColor.setStroke()
                let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
                path.lineWidth = 1
                path.stroke()
                let value = table.cell(row: row, column: column).value
                if !value.isEmpty {
                    let textRect = rect.insetBy(dx: textInset, dy: verticalInset)
                    (value as NSString).draw(
                        with: textRect,
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        attributes: textAttributes(header: isHeader))
                }
                x += columnWidth
            }
            y += rowHeight
        }
        _ = flipped
    }
}

/// Draws an image scaled to the text column — the editor's picture cell.
/// TextKit 1 centres an attachment's image at its stored point size and
/// clips; this fits it to the measure, aspect kept.
final class ScaledImageAttachmentCell: NSTextAttachmentCell {
    private let fallbackWidth: CGFloat = 480

    private func fitted(_ size: NSSize, toWidth width: CGFloat) -> NSSize {
        guard size.width > 0, size.height > 0 else { return NSSize(width: width, height: width * 0.6) }
        let scale = min(1, width / size.width)
        return NSSize(width: (size.width * scale).rounded(.down), height: (size.height * scale).rounded(.down))
    }

    nonisolated override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                                        glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        MainActor.assumeIsolated {
            let width = max(40, textContainer.size.width - textContainer.lineFragmentPadding * 2 - 2)
            let size = fitted(image?.size ?? .zero, toWidth: width)
            return NSRect(origin: .zero, size: size)
        }
    }

    nonisolated override func cellSize() -> NSSize {
        MainActor.assumeIsolated { fitted(image?.size ?? .zero, toWidth: fallbackWidth) }
    }

    nonisolated override func cellBaselineOffset() -> NSPoint { .zero }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?,
                       characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        image?.draw(in: cellFrame, from: .zero, operation: .sourceOver,
                    fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
}
