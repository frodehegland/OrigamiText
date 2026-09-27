#if os(macOS)
import SwiftUI

/// What a book's package says about it, for people: the bibliographic
/// basics and its accessibility, read from the EPUB Accessibility 1.1
/// metadata and phrased after the W3C "Accessibility Metadata Display
/// Guide for Digital Publications" 2.0 — key statements a reader can act
/// on, not raw vocabulary.
struct BookInformation: Sendable {
    struct Statement: Identifiable, Sendable {
        let id = UUID()
        let heading: String
        let text: String
    }

    var title = ""
    var creators: [String] = []
    var publisher: String?
    var date: String?
    var language: String?
    var identifier: String?
    var rights: String?
    var accessibility: [Statement] = []
    /// True when the book carries any accessibility metadata at all.
    var declaresAccessibility = false

    static func read(inUnpackedFolder folder: URL) -> BookInformation {
        var info = BookInformation()
        let opfSubpath = (try? String(
            contentsOf: folder.appendingPathComponent("META-INF/container.xml"), encoding: .utf8))
            .flatMap { first(in: $0, #"full-path="([^"]+)""#) } ?? "package.opf"
        guard let opf = try? String(contentsOf: folder.appendingPathComponent(opfSubpath),
                                    encoding: .utf8) else { return info }
        func tag(_ name: String) -> [String] {
            all(in: opf, "<\(name)\\b[^>]*>([^<]*)</\(name)>").map(unescaped).filter { !$0.isEmpty }
        }
        func meta(_ property: String) -> [String] {
            all(in: opf, "<meta[^>]*property=[\"']\(NSRegularExpression.escapedPattern(for: property))[\"'][^>]*>([^<]*)</meta>")
                .map(unescaped).filter { !$0.isEmpty }
        }
        info.title = tag("dc:title").first ?? ""
        info.creators = tag("dc:creator")
        info.publisher = tag("dc:publisher").first
        info.date = tag("dc:date").first
        info.language = tag("dc:language").first
        info.identifier = OrigamiEPUBImporter.uniqueIdentifier(in: opf)
        info.rights = tag("dc:rights").first

        let modes = Set(meta("schema:accessMode").map { $0.lowercased() })
        let sufficient = meta("schema:accessModeSufficient").map { $0.lowercased() }
        let features = Set(meta("schema:accessibilityFeature").map { $0.lowercased() })
        let hazards = Set(meta("schema:accessibilityHazard").map { $0.lowercased() })
        let summary = meta("schema:accessibilitySummary").first
        let conformsTo = all(in: opf, #"<(?:dc:|dcterms:)?conformsTo[^>]*>([^<]*)<"#)
            + meta("dcterms:conformsTo")
        let certifiedBy = meta("a11y:certifiedBy").first
        info.declaresAccessibility = !modes.isEmpty || !sufficient.isEmpty || !features.isEmpty
            || !hazards.isEmpty || summary != nil
            || conformsTo.contains { $0.lowercased().contains("epub/a11y") }
        guard info.declaresAccessibility else { return info }

        var out: [Statement] = []
        // Ways of reading.
        let textOnly = sufficient.contains { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } == ["textual"] }
        if features.contains("displaytransformability") {
            out.append(.init(heading: "Visual adjustments", text: "Appearance can be modified — text size, spacing and colours adapt to your settings."))
        } else if !features.isEmpty {
            out.append(.init(heading: "Visual adjustments", text: "No information about changing the appearance is available."))
        }
        if textOnly || features.contains("alternativetext") || features.contains("longdescription") {
            out.append(.init(heading: "Nonvisual reading",
                             text: textOnly ? "Readable in read aloud or dynamic braille — all content is available as text."
                                            : "Images have text descriptions, so the book can be read without seeing them."))
        } else if modes.contains("visual") {
            out.append(.init(heading: "Nonvisual reading", text: "May not be fully readable in read aloud or dynamic braille."))
        }
        if modes.contains("auditory") || features.contains("synchronizedaudiotext") {
            out.append(.init(heading: "Prerecorded audio",
                             text: features.contains("synchronizedaudiotext")
                                ? "Prerecorded audio is synchronised with the text." : "Contains prerecorded audio."))
        }
        // Conformance.
        if let level = conformsTo.first(where: { $0.lowercased().contains("wcag") }) {
            let grade = level.uppercased().contains("AAA") ? "AAA" : level.uppercased().contains("-AA") ? "AA" : "A"
            out.append(.init(heading: "Conformance",
                             text: "Meets the EPUB Accessibility standard at WCAG level \(grade)."
                                + (certifiedBy.map { " Certified by \($0)." } ?? "")))
        }
        // Navigation.
        var navigation: [String] = []
        if features.contains("tableofcontents") { navigation.append("a table of contents") }
        if features.contains("index") { navigation.append("an index") }
        if features.contains("structuralnavigation") { navigation.append("headings for moving by section") }
        if features.contains("pagenavigation") || features.contains("printpagenumbers") { navigation.append("print page numbers") }
        if !navigation.isEmpty {
            out.append(.init(heading: "Navigation", text: "Has " + listed(navigation) + "."))
        }
        // Rich content.
        var rich: [String] = []
        if features.contains("mathml") { rich.append("mathematics as MathML") }
        if features.contains("latex") { rich.append("mathematics as LaTeX") }
        if features.contains("describedmath") { rich.append("mathematics with text descriptions") }
        if features.contains("chemml") { rich.append("chemistry as ChemML") }
        if features.contains("longdescription") { rich.append("long descriptions for complex images") }
        if features.contains("closedcaptions") || features.contains("opencaptions") { rich.append("captioned video") }
        if features.contains("transcript") { rich.append("transcripts") }
        if !rich.isEmpty { out.append(.init(heading: "Rich content", text: "Includes " + listed(rich) + ".")) }
        // Hazards.
        if hazards.contains("none") || (hazards.contains("noflashinghazard") && hazards.contains("nomotionsimulationhazard") && hazards.contains("nosoundhazard")) {
            out.append(.init(heading: "Hazards", text: "No hazards."))
        } else if !hazards.isEmpty {
            var present: [String] = []
            if hazards.contains("flashing") { present.append("flashing") }
            if hazards.contains("motionsimulation") { present.append("motion simulation") }
            if hazards.contains("sound") { present.append("sound") }
            out.append(.init(heading: "Hazards",
                             text: present.isEmpty ? "The book declares its hazards; none of flashing, motion or sound is listed as present."
                                                   : "Contains " + listed(present) + " hazards."))
        }
        if let summary { out.append(.init(heading: "Accessibility summary", text: summary)) }
        info.accessibility = out
        return info
    }

    private static func listed(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
    }

    private static func first(in text: String, _ pattern: String) -> String? { all(in: text, pattern).first }

    private static func all(in text: String, _ pattern: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    private static func unescaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// The sheet: the book's details, then its accessibility statements —
/// or a plain word that the publisher gave none.
struct BookInformationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let info: BookInformation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Book Information").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            Form {
                Section("About") {
                    LabeledContent("Title", value: info.title)
                    if !info.creators.isEmpty {
                        LabeledContent(info.creators.count == 1 ? "Author" : "Authors",
                                       value: info.creators.joined(separator: ", "))
                    }
                    if let publisher = info.publisher { LabeledContent("Publisher", value: publisher) }
                    if let date = info.date { LabeledContent("Date", value: date) }
                    if let language = info.language {
                        LabeledContent("Language",
                                       value: Locale.current.localizedString(forIdentifier: language) ?? language)
                    }
                    if let identifier = info.identifier, !identifier.isEmpty {
                        LabeledContent("Identifier") { Text(identifier).textSelection(.enabled) }
                    }
                    if let rights = info.rights { LabeledContent("Rights", value: rights) }
                }
                Section("Accessibility") {
                    if info.accessibility.isEmpty {
                        Text(info.declaresAccessibility
                             ? "The publisher declared accessibility information, but none of it could be summarised."
                             : "The publisher provided no accessibility information for this book.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(info.accessibility) { statement in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(statement.heading).font(.callout.bold())
                            Text(statement.text).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 520, minHeight: 480)
    }
}
#endif
