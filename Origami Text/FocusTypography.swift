import UIKit
import SwiftUI
import CoreText

/// How Focus sets its words. Focus is where a reader settles into one
/// section, one paragraph or one sentence, so it is set as a book is:
/// a reading face with its real ligatures, old-style figures, acronyms in
/// small capitals, hyphenation, and no word left alone on a last line.
///
/// Only the presentation changes. The characters are exactly the book's —
/// highlights and notes find their place by matching them — so straight
/// quotes stay straight; ligatures, small caps, figures and hyphens are all
/// drawn by the font and the layout, not written into the text.
enum FocusFace: String, CaseIterable, Identifiable {
    case iowan, newYork, hoefler, baskerville

    static let defaultsKey = "iosFocusFace"
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .iowan: "Iowan Old Style"
        case .newYork: "New York"
        case .hoefler: "Hoefler Text"
        case .baskerville: "Baskerville"
        }
    }

    /// The face's regular PostScript name; nil for New York, the system
    /// serif, which is reached by design rather than by name.
    private var postScriptName: String? {
        switch self {
        case .iowan: "IowanOldStyle-Roman"
        case .newYork: nil
        case .hoefler: "HoeflerText-Regular"
        case .baskerville: "Baskerville"
        }
    }

    /// Whether the face carries rare or historical ligatures (ct, st and
    /// their kin) — checked against the fonts iOS ships.
    var hasRareLigatures: Bool { self == .hoefler || self == .baskerville }

    /// Whether the face draws true small capitals FROM capitals (OpenType
    /// c2sc) — Iowan Old Style and New York do. Hoefler Text and
    /// Baskerville offer small caps only for lowercase, which would mean
    /// changing the book's characters, so their acronyms stay capitals
    /// rather than being faked by shrinking.
    var smallCapsFromCapitals: Bool { self == .iowan || self == .newYork }

    /// Leading the face wants beyond the reading's own: Hoefler Text sets
    /// short on the line and needs air; Baskerville a little.
    func extraLeading(size: CGFloat) -> CGFloat {
        switch self {
        case .hoefler: size * 0.22
        case .baskerville: size * 0.1
        case .iowan, .newYork: 0
        }
    }

    /// The face at a size, with the traits a run asks for.
    func font(size: CGFloat, traits: UIFontDescriptor.SymbolicTraits = []) -> UIFont {
        var base: UIFont
        if let name = postScriptName, let named = UIFont(name: name, size: size) {
            base = named
        } else {
            let system = UIFont.systemFont(ofSize: size)
            base = system.fontDescriptor.withDesign(.serif)
                .map { UIFont(descriptor: $0, size: size) } ?? system
        }
        if !traits.isEmpty,
           let descriptor = base.fontDescriptor.withSymbolicTraits(
               base.fontDescriptor.symbolicTraits.union(traits)) {
            base = UIFont(descriptor: descriptor, size: size)
        }
        return base
    }

    /// The face for SwiftUI headings.
    func swiftUIFont(size: CGFloat, weight: Font.Weight) -> Font {
        if let name = postScriptName {
            return Font.custom(name, fixedSize: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .serif)
    }
}

/// The settings Focus reads, gathered for the text views.
struct FocusTypography: Equatable {
    var face: FocusFace
    var justified: Bool
    var rareLigatures: Bool

    static let justifyKey = "iosFocusJustified"
    static let rareLigaturesKey = "iosFocusRareLigatures"

    /// The OpenType features every Focus run wears: old-style figures,
    /// common ligatures (always), and — where chosen and the face has
    /// them — rare and historical ligatures.
    private func features(smallCapsFromCapitals: Bool) -> [[UIFontDescriptor.FeatureKey: Int]] {
        var settings: [[UIFontDescriptor.FeatureKey: Int]] = [
            [.type: kNumberCaseType, .selector: kLowerCaseNumbersSelector],
            [.type: kLigaturesType, .selector: kCommonLigaturesOnSelector],
        ]
        if rareLigatures, face.hasRareLigatures {
            settings.append([.type: kLigaturesType, .selector: kRareLigaturesOnSelector])
            settings.append([.type: kLigaturesType, .selector: kHistoricalLigaturesOnSelector])
        }
        if smallCapsFromCapitals {
            settings.append([.type: kUpperCaseType, .selector: kUpperCaseSmallCapsSelector])
        }
        return settings
    }

    /// The run's font with Focus's features applied. `plainLigatures`
    /// keeps the rare ones off — for ordinals, where 21st must not
    /// become 21ﬆ.
    func font(size: CGFloat, traits: UIFontDescriptor.SymbolicTraits,
              smallCapsFromCapitals: Bool = false,
              plainLigatures: Bool = false) -> UIFont {
        let base = face.font(size: size, traits: traits)
        var copy = self
        if plainLigatures { copy.rareLigatures = false }
        let descriptor = base.fontDescriptor.addingAttributes(
            [.featureSettings: copy.features(smallCapsFromCapitals: smallCapsFromCapitals)])
        return UIFont(descriptor: descriptor, size: size)
    }

    /// Ordinal suffixes after figures (21st, 2nd, 3rd, 4th) as ranges.
    static func ordinalRanges(in text: String) -> [NSRange] {
        guard let pattern = try? NSRegularExpression(pattern: #"\d(st|nd|rd|th)\b"#) else { return [] }
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
    }

    /// Hyphenated, justified if chosen. (No lone last word is kept by
    /// `NoLoneLastWord`: neither text system honours `.pushOut`.) Ragged text hyphenates sparingly — a short line is kinder
    /// than a broken word — and justified text more readily, since there
    /// a hyphen is what keeps the word spaces even.
    func paragraphStyle(lineSpacing: CGFloat, size: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing + face.extraLeading(size: size)
        style.usesDefaultHyphenation = false
        style.hyphenationFactor = justified ? 0.9 : 0.4
        style.lineBreakStrategy = [.pushOut, .standard]
        style.alignment = justified ? .justified : .natural
        return style
    }

    /// Acronyms — runs of two or more capitals (EPUB, ACM, DOI, HT’26) —
    /// as ranges in `text`, to be set in small capitals so they sit at
    /// the height of the lowercase rather than shouting over it.
    static func acronymRanges(in text: String) -> [NSRange] {
        guard let pattern = try? NSRegularExpression(
            pattern: #"\b[A-Z][A-Z0-9’'&]*[A-Z0-9]\b"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            let word = (text as NSString).substring(with: match.range)
            return word.filter(\.isUppercase).count >= 2 ? match.range : nil
        }
    }
}

/// Keeps a paragraph's last word company: the layout may not break a line
/// just before it (by word or by hyphen), so the word before comes down
/// with it. Measured on iOS 27: neither TextKit honours `.pushOut`, and a
/// no-break space would change the book's characters, so the rule is kept
/// in the layout instead. Classic TextKit only — Focus's text views use it.
final class NoLoneLastWord: NSObject, NSLayoutManagerDelegate {
    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldBreakLineByWordBeforeCharacterAt charIndex: Int) -> Bool {
        guard let storage = layoutManager.textStorage, storage.length > 0 else { return true }
        let string = storage.string as NSString
        let paragraph = string.paragraphRange(
            for: NSRange(location: min(charIndex, string.length - 1), length: 0))
        let body = string.substring(with: paragraph)
            .trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        let lastSpace = body.range(of: " ", options: .backwards)
        guard lastSpace.location != NSNotFound else { return true }
        let leading = string.substring(with: paragraph).prefix { $0.isWhitespace }.utf16.count
        return charIndex < paragraph.location + leading + lastSpace.location + 1
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldBreakLineByHyphenatingBeforeCharacterAt charIndex: Int) -> Bool {
        self.layoutManager(layoutManager, shouldBreakLineByWordBeforeCharacterAt: charIndex)
    }
}
