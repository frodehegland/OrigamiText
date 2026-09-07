import SwiftUI

// In its own file (moved from EPUBReaderView.swift, which is
// macOS-only) so the iOS reader shares the one theme set — the choice
// itself travels under AppSettings.readerThemeKey ("readerTheme").

/// An app-wide colour theme: background and text for every column — the
/// list, the detail, and the reading surface. The CSS variant also themes
/// EPUBs shown in the faithful WebView. Light/dark handled per theme.
/// Sources: Knowledge Space AppTheme (gentle–coolStrong); BDA Style Guide
/// 2014 & Rello/Bigham CHI 2017 (cream, softPeach); Irlen Institute
/// (irlenYellow, irlenGreen, irlenPurple); Almutairi et al. PMC3880533
/// (macular); Ethan Schoonover Solarized (solarized); TheraSpecs FL-41 (night).
enum ReaderTheme: String, CaseIterable, Identifiable, Sendable {
    // ── Standard ─────────────────────────────────────────────────────────
    case highContrast
    case sepia
    case grey
    // ── From Knowledge Space (gentle contrast gradations) ─────────────────
    case gentle
    case lowContrast
    case warm
    case warmStrong
    case cool
    case coolStrong
    // ── Dyslexia / visual stress ──────────────────────────────────────────
    case cream        // BDA standard; intentionally below 4.5:1
    case softPeach    // top CHI 2017 performer for dyslexic readers
    // ── Irlen syndrome overlay simulations ────────────────────────────────
    case irlenYellow
    case irlenGreen
    case irlenPurple
    // ── Macular degeneration ──────────────────────────────────────────────
    case macular      // black on yellow; 71% of AMD patients preferred this
    // ── Photophobia / night reading ───────────────────────────────────────
    case night        // warm dark; avoids blue-heavy tones that trigger photophobia
    case solarized    // Schoonover's perceptually uniform scheme

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .highContrast: "High Contrast"
        case .sepia:        "Sepia"
        case .grey:         "Grey"
        case .gentle:       "Gentle"
        case .lowContrast:  "Low Contrast"
        case .warm:         "Warm"
        case .warmStrong:   "Warm Strong"
        case .cool:         "Cool"
        case .coolStrong:   "Cool Strong"
        case .cream:        "Cream"
        case .softPeach:    "Soft Peach"
        case .irlenYellow:  "Yellow Tint"
        case .irlenGreen:   "Green Tint"
        case .irlenPurple:  "Purple Tint"
        case .macular:      "Black on Yellow"
        case .night:        "Night"
        case .solarized:    "Solarized"
        }
    }

    /// CSS injected into the faithful (WebView) rendering. High Contrast
    /// keeps the EPUB's own black-on-white; every other theme overrides
    /// background and text so the page matches the rest of the app.
    var css: String {
        switch self {
        case .highContrast:
            return ":root { color-scheme: light; }"
        case .sepia:
            return themeCSS(lb: "#eee2cc", lt: "#32281d",
                            db: "#393329", dt: "#ede3d3")
        case .grey:
            return themeCSS(lb: "#dddddd", lt: "#272727",
                            db: "#3f3f3f", dt: "#dddddd")
        case .gentle:
            return themeCSS(lb: "#ffffff", lt: "#666666",
                            db: "#353534", dt: "#aeaeae")
        case .lowContrast:
            return themeCSS(lb: "#dcdddc", lt: "#585958",
                            db: "#222221", dt: "#7b7a79")
        case .warm:
            return themeCSS(lb: "#f5ecdc", lt: "#494742",
                            db: "#3d3633", dt: "#f9f9f8")
        case .warmStrong:
            return themeCSS(lb: "#c3ad9b", lt: "#26231f",
                            db: "#26201e", dt: "#ffffff")
        case .cool:
            return themeCSS(lb: "#d8e1ea", lt: "#575a5d",
                            db: "#2b3e4f", dt: "#b1bbc0")
        case .coolStrong:
            return themeCSS(lb: "#b7c4cf", lt: "#37536b",
                            db: "#2c3840", dt: "#b1b9be")
        case .cream:
            return themeCSS(lb: "#fffdd0", lt: "#1a1a2e",
                            db: "#1a1a0a", dt: "#fffdd0")
        case .softPeach:
            return themeCSS(lb: "#ffe4c4", lt: "#2c1810",
                            db: "#2c1810", dt: "#ffe4c4")
        case .irlenYellow:
            return themeCSS(lb: "#fffff0", lt: "#1a1a1a",
                            db: "#1a1a00", dt: "#fffff0")
        case .irlenGreen:
            return themeCSS(lb: "#d8f5d8", lt: "#0d2d0d",
                            db: "#0d2d0d", dt: "#d8f5d8")
        case .irlenPurple:
            return themeCSS(lb: "#e8d9f0", lt: "#1f0d2d",
                            db: "#1f0d2d", dt: "#e8d9f0")
        case .macular:
            return themeCSS(lb: "#ffff00", lt: "#000000",
                            db: "#333300", dt: "#ffff00")
        case .night:
            return themeCSS(lb: "#faf5e4", lt: "#2d1a0d",
                            db: "#1a1209", dt: "#d4b896")
        case .solarized:
            return themeCSS(lb: "#fdf6e3", lt: "#657b83",
                            db: "#002b36", dt: "#839496")
        }
    }

    private func themeCSS(lb: String, lt: String, db: String, dt: String) -> String {
        """
        :root { color-scheme: light dark; }
        html, body { background-color: \(lb); color: \(lt); }
        @media (prefers-color-scheme: dark) {
          html, body { background-color: \(db); color: \(dt); }
        }
        """
    }

    /// Background colour for native views. Nil for High Contrast means
    /// use the system text background unchanged.
    func background(for scheme: ColorScheme) -> Color? {
        let d = scheme == .dark
        switch self {
        case .highContrast: return nil
        case .sepia:        return Color(hexCode: d ? "#393329" : "#eee2cc")
        case .grey:         return Color(hexCode: d ? "#3f3f3f" : "#dddddd")
        case .gentle:       return Color(hexCode: d ? "#353534" : "#ffffff")
        case .lowContrast:  return Color(hexCode: d ? "#222221" : "#dcdddc")
        case .warm:         return Color(hexCode: d ? "#3d3633" : "#f5ecdc")
        case .warmStrong:   return Color(hexCode: d ? "#26201e" : "#c3ad9b")
        case .cool:         return Color(hexCode: d ? "#2b3e4f" : "#d8e1ea")
        case .coolStrong:   return Color(hexCode: d ? "#2c3840" : "#b7c4cf")
        case .cream:        return Color(hexCode: d ? "#1a1a0a" : "#fffdd0")
        case .softPeach:    return Color(hexCode: d ? "#2c1810" : "#ffe4c4")
        case .irlenYellow:  return Color(hexCode: d ? "#1a1a00" : "#fffff0")
        case .irlenGreen:   return Color(hexCode: d ? "#0d2d0d" : "#d8f5d8")
        case .irlenPurple:  return Color(hexCode: d ? "#1f0d2d" : "#e8d9f0")
        case .macular:      return Color(hexCode: d ? "#333300" : "#ffff00")
        case .night:        return Color(hexCode: d ? "#1a1209" : "#faf5e4")
        case .solarized:    return Color(hexCode: d ? "#002b36" : "#fdf6e3")
        }
    }

    /// Text colour for native views. Nil for High Contrast means use the
    /// system label colour unchanged.
    func textColor(for scheme: ColorScheme) -> Color? {
        let d = scheme == .dark
        switch self {
        case .highContrast: return nil
        case .sepia:        return Color(hexCode: d ? "#ede3d3" : "#32281d")
        case .grey:         return Color(hexCode: d ? "#dddddd" : "#272727")
        case .gentle:       return Color(hexCode: d ? "#aeaeae" : "#666666")
        case .lowContrast:  return Color(hexCode: d ? "#7b7a79" : "#585958")
        case .warm:         return Color(hexCode: d ? "#f9f9f8" : "#494742")
        case .warmStrong:   return Color(hexCode: d ? "#ffffff" : "#26231f")
        case .cool:         return Color(hexCode: d ? "#b1bbc0" : "#575a5d")
        case .coolStrong:   return Color(hexCode: d ? "#b1b9be" : "#37536b")
        case .cream:        return Color(hexCode: d ? "#fffdd0" : "#1a1a2e")
        case .softPeach:    return Color(hexCode: d ? "#ffe4c4" : "#2c1810")
        case .irlenYellow:  return Color(hexCode: d ? "#fffff0" : "#1a1a1a")
        case .irlenGreen:   return Color(hexCode: d ? "#d8f5d8" : "#0d2d0d")
        case .irlenPurple:  return Color(hexCode: d ? "#e8d9f0" : "#1f0d2d")
        case .macular:      return Color(hexCode: d ? "#ffff00" : "#000000")
        case .night:        return Color(hexCode: d ? "#d4b896" : "#2d1a0d")
        case .solarized:    return Color(hexCode: d ? "#839496" : "#657b83")
        }
    }
}
