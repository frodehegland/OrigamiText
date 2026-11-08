import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(UIKit)
import UIKit
#endif

// Every colour Origami draws in XR, in one table, and the guard that keeps
// them clear of the writer's concept colours (CONCEPT-COLOURS-IN-XR-PLAN.md,
// section 4). In a view that shows concept colours, a hue that is one of the
// six kinds means that kind and nothing else, so no XR colour is written at
// the point where it is drawn: it is a role here, and the guard measures it.
//
// The core (colours, OKLab, roles, guard) uses Foundation only, so it can be
// checked from any target. Drawing adapters sit at the end of the file.
//
// Left out on purpose: the reader's accent (system-owned), hues made from a
// name (Weave threads, bot monograms; plan step 5 confines them), subject
// tags (the reader's own data, kept as ground in plan step 3) and Timeflows'
// earth tones (no concepts shown there).

/// An sRGB colour, 0…1 per channel.
nonisolated struct XRColour: Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red; self.green = green; self.blue = blue
    }

    init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    /// "#RRGGBB" or "RRGGBB"; anything else is nil.
    init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(hex: value)
    }

    static let white = XRColour(hex: 0xFFFFFF)

    var hex: UInt32 {
        func byte(_ c: Double) -> UInt32 { UInt32((min(max(c, 0), 1) * 255).rounded()) }
        return byte(red) << 16 | byte(green) << 8 | byte(blue)
    }

    /// "RRGGBB", the form the reader's colour settings store.
    var hexString: String { String(format: "%06X", hex) }

    /// Björn Ottosson's OKLab, from sRGB.
    var oklab: (l: Double, a: Double, b: Double) {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = linear(red), g = linear(green), b = linear(blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// OKLab ΔE × 100. Below 10 two colours read as one; 10–15 can be
    /// confused at a glance; 18 and up are clearly different.
    func distance(to other: XRColour) -> Double {
        let p = oklab, q = other.oklab
        let dl = p.l - q.l, da = p.a - q.a, db = p.b - q.b
        return 100 * (dl * dl + da * da + db * db).squareRoot()
    }
}

/// The six kinds of concept Author and Knowledge Space colour, with their
/// published defaults. A writer's own choices (categoryColors.json) replace
/// these; Origami never moves them.
nonisolated enum ConceptKind: String, CaseIterable, Sendable {
    case person, artifact, event, location, institution, concept

    var defaultColour: XRColour {
        switch self {
        case .person: XRColour(hex: 0xFF9440)
        case .artifact: XRColour(hex: 0xC9935A)
        case .event: XRColour(hex: 0xFFD233)
        case .location: XRColour(hex: 0x4FC96A)
        case .institution: XRColour(hex: 0x5FA0FF)
        case .concept: XRColour(hex: 0xB07CFF)
        }
    }

    /// A key from categoryColors.json; older files say "product".
    init?(fileKey: String) {
        let key = fileKey.lowercased()
        self.init(rawValue: key == "product" ? "artifact" : key)
    }

    static var defaults: [ConceptKind: XRColour] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.defaultColour) })
    }
}

/// A system colour some roles still draw with. The hex is what the guard
/// measures it as (the system's published value); drawing uses the real
/// system colour, so nothing changes on screen.
nonisolated enum XRSystemColour: Sendable {
    case yellow, orange, red, green, blue, purple

    var measured: XRColour {
        switch self {
        case .yellow: XRColour(hex: 0xFFCC00)
        case .orange: XRColour(hex: 0xFF9500)
        case .red: XRColour(hex: 0xFF3B30)
        case .green: XRColour(hex: 0x34C759)
        case .blue: XRColour(hex: 0x007AFF)
        case .purple: XRColour(hex: 0xAF52DE)
        }
    }
}

/// One thing Origami marks with colour in XR.
nonisolated struct XRColourRole: Identifiable, Sendable {
    /// Where roles are seen together. Two roles only need to stay apart
    /// from each other when they share a view.
    enum Place: String, Sendable {
        case page        // the reading page: Find, annotations, the mark
        case standing    // a cited work's trust words and stance verdicts
        case map         // the Map and its citations
        case conceptSpace
        case lineage
    }

    /// How the role is drawn. Two roles in one view may share a hue when
    /// their forms differ (a fill and a wavy underline).
    enum Form: String, Sendable {
        case fill, ink, line, outline, glyph
    }

    let id: String
    /// What the role marks, in words, for the guard's notes.
    let use: String
    let colour: XRColour
    /// Set when the role draws with a system colour.
    let system: XRSystemColour?
    /// The opacity it is drawn at, where it has one.
    let opacity: Double
    let view: Place
    let form: Form
    /// The plan step that changes this role, while it still clashes. The
    /// guard reports these as planned; any other clash is a failure.
    let owedToStep: Int?

    init(_ id: String, _ use: String, hex: UInt32, opacity: Double = 1,
         view: Place, form: Form, owedToStep: Int? = nil) {
        self.id = id; self.use = use
        colour = XRColour(hex: hex); system = nil
        self.opacity = opacity; self.view = view; self.form = form
        self.owedToStep = owedToStep
    }

    init(_ id: String, _ use: String, system: XRSystemColour, opacity: Double = 1,
         view: Place, form: Form, owedToStep: Int? = nil) {
        self.id = id; self.use = use
        colour = system.measured; self.system = system
        self.opacity = opacity; self.view = view; self.form = form
        self.owedToStep = owedToStep
    }
}

/// The table. Values are exactly what each place drew before it was moved
/// here (8 Nov 2026); plan steps 2–5 change them.
nonisolated enum XRColourRoles {

    // MARK: The page

    static let find = XRColourRole("find", "a Find match", system: .yellow, opacity: 0.45,
                                   view: .page, form: .fill, owedToStep: 2)

    /// Author's mark: Orange, High Contrast and Blue, per appearance.
    static let markOrangeDark = XRColourRole("mark.orange.dark", "Author's mark (orange)", hex: 0xFFBB5F,
                                             view: .page, form: .ink, owedToStep: 2)
    static let markOrangeLight = XRColourRole("mark.orange.light", "Author's mark (orange, light)", hex: 0xBB6A26,
                                              view: .page, form: .ink, owedToStep: 2)
    static let markHighContrastDark = XRColourRole("mark.highContrast.dark", "Author's mark (high contrast)",
                                                   hex: 0xECECEC, view: .page, form: .ink)
    static let markBlue = XRColourRole("mark.blue", "Author's mark (blue)", hex: 0x3678B0,
                                       view: .page, form: .ink)

    /// Annotation kinds, keyed by ReaderAnnotationKind's raw value. These
    /// are defaults: a reader's own colours win, and are only ever warned
    /// about (plan section 8).
    static let annotationKinds: [String: XRColourRole] = {
        let kinds: [(String, UInt32, Int?)] = [
            ("Important", 0xE4572E, 4),
            ("Quotable", 0x2E8B8B, 4),
            ("Great", 0x3A9B35, 4),
            ("Disagree", 0xC93C3C, 4),
            ("Language Issue", 0x8E5BC0, 4),
            ("Problematic", 0xD98E1B, 4),
            ("What is this?", 0x3B6FD4, 4),
            ("Highlight", 0xE8C51D, 2),
            // A mid grey, 12.1 from Artifact; goes to #7A7A7A in step 4.
            ("Strikethrough", 0x8A8A8A, 4),
        ]
        return Dictionary(uniqueKeysWithValues: kinds.map { name, hex, step in
            (name, XRColourRole("annotation." + name, "the \(name) annotation", hex: hex,
                                opacity: 0.35, view: .page, form: .fill, owedToStep: step))
        })
    }()

    // MARK: Standing (VisionMarkPill and stance verdicts)

    static let alarm = XRColourRole("standing.alarm", "an alarm", system: .red,
                                    view: .standing, form: .ink)
    static let caution = XRColourRole("standing.caution", "a caution", system: .orange,
                                      view: .standing, form: .ink, owedToStep: 2)
    static let info = XRColourRole("standing.info", "information", system: .blue,
                                   view: .standing, form: .ink, owedToStep: 2)
    static let good = XRColourRole("standing.good", "a good standing or an agreeing stance", system: .green,
                                   view: .standing, form: .ink, owedToStep: 2)

    // MARK: The Map

    static let selection = XRColourRole("map.selection", "a chosen label or picture", hex: 0xFFD673,
                                        view: .map, form: .outline, owedToStep: 2)
    static let pin = XRColourRole("map.pin", "a pinned card", hex: 0xF2AD40,
                                  view: .map, form: .glyph, owedToStep: 2)
    static let warningAlarm = XRColourRole("map.warning.alarm", "an alarm pill", hex: 0xD12929,
                                           view: .map, form: .fill)
    static let warningCaution = XRColourRole("map.warning.caution", "a caution pill", hex: 0xE0851A,
                                             view: .map, form: .fill, owedToStep: 2)
    static let citationLine = XRColourRole("map.citation", "a citation landing on a section", hex: 0x33B8CC,
                                           opacity: 0.85, view: .map, form: .line, owedToStep: 5)
    static let citedDot = XRColourRole("map.citedDot", "a cited section", hex: 0x33B8CC,
                                       view: .map, form: .glyph, owedToStep: 5)
    static let deeperCitationLine = XRColourRole("map.deeperCitation", "a line to a deeper citation",
                                                 hex: 0xFFB84D, opacity: 0.08, view: .map, form: .line,
                                                 owedToStep: 5)
    /// Lines from a selected work's citations, one colour per kind.
    static let selectedCitationLines: [XRColourRole] = [
        (0x33BF4D, "green"), (0x3373E6, "blue"), (0xE6CC1A, "yellow"),
        (0x8C8C8C, "grey"), (0xE03333, "red"),
    ].enumerated().map { index, entry in
        XRColourRole("map.selectedCitation.\(index)", "a selected work's \(entry.1) citation line",
                     hex: entry.0, opacity: 0.45, view: .map, form: .line, owedToStep: 5)
    }
    static let orbitBorder = XRColourRole("map.orbitBorder", "an orbiting document card", system: .blue,
                                          opacity: 0.5, view: .map, form: .outline, owedToStep: 5)

    // MARK: Concept spaces

    static let conceptSpaceHighlight = XRColourRole("conceptSpace.highlight", "a highlighted concept card",
                                                    system: .purple, opacity: 0.18, view: .conceptSpace,
                                                    form: .fill, owedToStep: 5)
    static let conceptSpaceLine = XRColourRole("conceptSpace.line", "a line between concepts",
                                               system: .purple, opacity: 0.28, view: .conceptSpace,
                                               form: .line, owedToStep: 5)
    /// Knowledge Space view: concept lines and the chosen concept.
    static let ksConcept = XRColourRole("ks.concept", "a concept line or the chosen concept", system: .purple,
                                        opacity: 0.55, view: .conceptSpace, form: .outline, owedToStep: 5)
    /// Knowledge Space view: document lines and document card borders.
    static let ksDocument = XRColourRole("ks.document", "a document line or card", system: .blue,
                                         opacity: 0.45, view: .conceptSpace, form: .line, owedToStep: 5)

    // MARK: Lineage

    static let lineageRoots = XRColourRole("lineage.roots", "what a work drew on", hex: 0x2743C4,
                                           view: .lineage, form: .line)
    static let lineageInfluence = XRColourRole("lineage.influence", "what built on a work", hex: 0xC4791C,
                                               view: .lineage, form: .line, owedToStep: 2)

    // MARK: The guard

    static var all: [XRColourRole] {
        [find, markOrangeDark, markOrangeLight, markHighContrastDark, markBlue]
            + ReaderKindOrder.names.compactMap { annotationKinds[$0] }
            + [alarm, caution, info, good,
               selection, pin, warningAlarm, warningCaution, citationLine, citedDot, deeperCitationLine]
            + selectedCitationLines
            + [orbitBorder, conceptSpaceHighlight, conceptSpaceLine, ksConcept, ksDocument,
               lineageRoots, lineageInfluence]
    }

    /// Annotation kinds in the reader's menu order, so reports read steadily.
    private enum ReaderKindOrder {
        static let names = ["Important", "Quotable", "Great", "Disagree", "Language Issue",
                            "Problematic", "What is this?", "Highlight", "Strikethrough"]
    }

    /// Below this, a role and a concept colour (or two roles in one view
    /// and form) can be taken for each other.
    static let threshold = 15.0

    struct Clash: Sendable, CustomStringConvertible {
        enum Other: Sendable {
            case concept(ConceptKind)
            case role(XRColourRole)
        }
        let role: XRColourRole
        let other: Other
        let distance: Double

        /// A clash some plan step already owns.
        var isPlanned: Bool {
            if role.owedToStep != nil { return true }
            if case .role(let r) = other, r.owedToStep != nil { return true }
            return false
        }

        var description: String {
            let name: String = switch other {
            case .concept(let kind): "the \(kind.rawValue) colour"
            case .role(let r): r.use
            }
            let owed = isPlanned ? " (planned: step \(role.owedToStep.map(String.init) ?? "—"))" : ""
            return "\(role.id): \(role.use) is \(String(format: "%.1f", distance)) from \(name)\(owed)"
        }
    }

    /// Every pair that comes too close: each role against each concept
    /// colour, and roles that share a view and a form against each other.
    /// Colours are compared solid, whatever opacity they draw at: blending
    /// two colours at the same opacity pulls both toward the ground and
    /// shrinks the distance with it, while the hue — what the eye names —
    /// stays the same.
    static func clashes(roles: [XRColourRole] = all,
                        concepts: [ConceptKind: XRColour] = ConceptKind.defaults) -> [Clash] {
        var found: [Clash] = []
        for role in roles {
            for kind in ConceptKind.allCases {
                guard let colour = concepts[kind] else { continue }
                let d = role.colour.distance(to: colour)
                if d < threshold { found.append(Clash(role: role, other: .concept(kind), distance: d)) }
            }
        }
        for (i, a) in roles.enumerated() {
            for b in roles[(i + 1)...] where a.view == b.view && a.form == b.form {
                let d = a.colour.distance(to: b.colour)
                if d < threshold { found.append(Clash(role: a, other: .role(b), distance: d)) }
            }
        }
        return found
    }

    /// The clashes no plan step owns. Empty is the goal at every step.
    static func unplannedClashes(concepts: [ConceptKind: XRColour] = ConceptKind.defaults) -> [Clash] {
        clashes(concepts: concepts).filter { !$0.isPlanned }
    }

    /// A reader's own annotation colour that sits close to a concept
    /// colour, as a note for Settings ("Quotable is close to your Location
    /// colour"). Their choice stays; this only warns.
    static func note(forAnnotation name: String, hex: String,
                     concepts: [ConceptKind: XRColour] = ConceptKind.defaults) -> String? {
        guard let colour = XRColour(hexString: hex) else { return nil }
        let nearest = ConceptKind.allCases.compactMap { kind in
            concepts[kind].map { (kind, colour.distance(to: $0)) }
        }.min { $0.1 < $1.1 }
        guard let (kind, d) = nearest, d < threshold else { return nil }
        return "\(name) is close to your \(kind.rawValue.capitalized) colour."
    }
}

// MARK: - Drawing

#if canImport(SwiftUI)
nonisolated extension XRColourRole {
    /// The role's colour at its own opacity.
    var color: Color { color(opacity: opacity) }

    /// The role's colour at another opacity, for places that draw one
    /// role at two strengths (a line's two ends).
    func color(opacity: Double) -> Color {
        let base: Color = switch system {
        case .yellow: .yellow
        case .orange: .orange
        case .red: .red
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case nil: Color(red: colour.red, green: colour.green, blue: colour.blue)
        }
        return opacity < 1 ? base.opacity(opacity) : base
    }
}
#endif

#if canImport(UIKit)
nonisolated extension XRColourRole {
    /// The role's colour at its own opacity, for RealityKit materials.
    var uiColor: UIColor { uiColor(opacity: opacity) }

    func uiColor(opacity: Double) -> UIColor {
        let base: UIColor = switch system {
        case .yellow: .systemYellow
        case .orange: .systemOrange
        case .red: .systemRed
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case nil: UIColor(red: colour.red, green: colour.green, blue: colour.blue, alpha: 1)
        }
        return base.withAlphaComponent(opacity)
    }
}
#endif
