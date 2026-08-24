import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The reader's chosen faces, wherever words render — Settings ▸
/// Reading ▸ Fonts, one choice for every view: the reading styles, the
/// document views, the cards and columns. A family the device does not
/// know falls back to the system serif, never to sans.
///
/// In its own file (not EPUBReaderView.swift, which is WebKit/macOS) so
/// the visionOS target renders with the same faces. The keys are the
/// ones Settings ▸ Reading writes (AppSettings.readerBodyFontKey and
/// .readerHeadingFontKey on the Mac), spelled out here so the font
/// logic compiles everywhere.
enum AppFonts {
    static let bodyFamilyKey = "readerBodyFont"
    static let headingFamilyKey = "readerHeadingFont"
    static let defaultBodyFamily = "Times New Roman"
    static let defaultHeadingFamily = "Georgia"

    static var bodyFamily: String {
        UserDefaults.standard.string(forKey: bodyFamilyKey) ?? defaultBodyFamily
    }

    static var headingFamily: String {
        UserDefaults.standard.string(forKey: headingFamilyKey) ?? defaultHeadingFamily
    }

    static func body(_ size: CGFloat, weight: Font.Weight? = nil) -> Font {
        custom(bodyFamily, size, weight)
    }

    static func heading(_ size: CGFloat, weight: Font.Weight? = nil) -> Font {
        custom(headingFamily, size, weight)
    }

    private static func custom(_ family: String, _ size: CGFloat,
                               _ weight: Font.Weight?) -> Font {
        #if os(macOS)
        let known = NSFont(name: family, size: size) != nil
        #else
        let known = UIFont(name: family, size: size) != nil
        #endif
        let font = known ? Font.custom(family, size: size)
                         : Font.system(size: size, design: .serif)
        return weight.map { font.weight($0) } ?? font
    }

    #if os(macOS)
    static func nsBody(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        var font = NSFont(name: bodyFamily, size: size)
            ?? fallbackSerif(size, bold: bold)
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        if !traits.isEmpty {
            let descriptor = font.fontDescriptor.withSymbolicTraits(
                font.fontDescriptor.symbolicTraits.union(traits))
            font = NSFont(descriptor: descriptor, size: size) ?? font
        }
        return font
    }

    private static func fallbackSerif(_ size: CGFloat, bold: Bool) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        var descriptor = base.fontDescriptor
        if let serif = descriptor.withDesign(.serif) { descriptor = serif }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
    #endif
}
