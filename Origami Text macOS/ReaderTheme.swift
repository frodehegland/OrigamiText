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

    /// The built-in palette — light background/text, dark background/text —
    /// the single source the CSS and the native colours both read.
    /// High Contrast has none: it is the system's own black-on-white.
    var builtinPalette: (lightBackground: String, lightText: String,
                         darkBackground: String, darkText: String)? {
        switch self {
        case .highContrast: nil
        case .sepia:        ("#eee2cc", "#32281d", "#393329", "#ede3d3")
        case .grey:         ("#dddddd", "#272727", "#3f3f3f", "#dddddd")
        case .gentle:       ("#ffffff", "#666666", "#353534", "#aeaeae")
        case .lowContrast:  ("#dcdddc", "#585958", "#222221", "#7b7a79")
        case .warm:         ("#f5ecdc", "#494742", "#3d3633", "#f9f9f8")
        case .warmStrong:   ("#c3ad9b", "#26231f", "#26201e", "#ffffff")
        case .cool:         ("#d8e1ea", "#575a5d", "#2b3e4f", "#b1bbc0")
        case .coolStrong:   ("#b7c4cf", "#37536b", "#2c3840", "#b1b9be")
        case .cream:        ("#fffdd0", "#1a1a2e", "#1a1a0a", "#fffdd0")
        case .softPeach:    ("#ffe4c4", "#2c1810", "#2c1810", "#ffe4c4")
        case .irlenYellow:  ("#fffff0", "#1a1a1a", "#1a1a00", "#fffff0")
        case .irlenGreen:   ("#d8f5d8", "#0d2d0d", "#0d2d0d", "#d8f5d8")
        case .irlenPurple:  ("#e8d9f0", "#1f0d2d", "#1f0d2d", "#e8d9f0")
        case .macular:      ("#ffff00", "#000000", "#333300", "#ffff00")
        case .night:        ("#faf5e4", "#2d1a0d", "#1a1209", "#d4b896")
        case .solarized:    ("#fdf6e3", "#657b83", "#002b36", "#839496")
        }
    }

    /// What the High Contrast editor wells show before any edit — the
    /// system's effective colours (its native views stay system-drawn
    /// until an override exists).
    static let highContrastEditorPalette = (lightBackground: "#ffffff",
                                            lightText: "#000000",
                                            darkBackground: "#1e1e1e",
                                            darkText: "#ffffff")

    // The keys an edited colour is stored under (Settings ▸ Reading ▸
    // Edit Theme Colors…) — per theme, per role, light and dark apart.
    var backgroundOverrideKey: String { rawValue + ".background" }
    var textOverrideKey: String { rawValue + ".text" }
    var overrideKeys: [String] { [backgroundOverrideKey, textOverrideKey] }

    /// The hex actually in force: the reader's override first, the
    /// built-in palette otherwise. Nil only for untouched High Contrast.
    func effectiveBackgroundHex(dark: Bool) -> String? {
        ThemeColorOverrides.hex(for: backgroundOverrideKey, dark: dark)
            ?? builtinPalette.map { dark ? $0.darkBackground : $0.lightBackground }
    }

    func effectiveTextHex(dark: Bool) -> String? {
        ThemeColorOverrides.hex(for: textOverrideKey, dark: dark)
            ?? builtinPalette.map { dark ? $0.darkText : $0.lightText }
    }

    /// CSS injected into the faithful (WebView) rendering. High Contrast
    /// keeps the EPUB's own black-on-white (until its colours are
    /// edited); every other theme overrides background and text so the
    /// page matches the rest of the app.
    var css: String {
        if self == .highContrast,
           !ThemeColorOverrides.hasOverride(backgroundOverrideKey),
           !ThemeColorOverrides.hasOverride(textOverrideKey) {
            return ":root { color-scheme: light; }"
        }
        let fallback = ReaderTheme.highContrastEditorPalette
        return """
        :root { color-scheme: light dark; }
        html, body { background-color: \(effectiveBackgroundHex(dark: false) ?? fallback.lightBackground); color: \(effectiveTextHex(dark: false) ?? fallback.lightText); }
        @media (prefers-color-scheme: dark) {
          html, body { background-color: \(effectiveBackgroundHex(dark: true) ?? fallback.darkBackground); color: \(effectiveTextHex(dark: true) ?? fallback.darkText); }
        }
        """
    }

    /// Background colour for native views. Nil for untouched High
    /// Contrast means use the system text background unchanged.
    func background(for scheme: ColorScheme) -> Color? {
        effectiveBackgroundHex(dark: scheme == .dark).flatMap { Color(hexCode: $0) }
    }

    /// Text colour for native views. Nil for untouched High Contrast
    /// means use the system label colour unchanged.
    func textColor(for scheme: ColorScheme) -> Color? {
        effectiveTextHex(dark: scheme == .dark).flatMap { Color(hexCode: $0) }
    }
}

/// The reader's own colours for a theme, edited in Settings ▸ Reading ▸
/// Edit Theme Colors… — the same shape as Author's: a defaults
/// dictionary keyed by role, each role holding a light and a dark hex.
/// An absent entry means the built-in colour; Reset is removal. Every
/// write bumps a tick key the themed views observe, so edits apply live.
enum ThemeColorOverrides {

    static let defaultsKey = "ThemeColorOverrides"
    /// Bumped on every change — themed views declare it with @AppStorage
    /// so an edit repaints them without a relaunch.
    static let tickKey = "themeColorOverridesTick"

    /// In-memory copy so colour lookups in drawing code don't hit
    /// UserDefaults on every access.
    private nonisolated(unsafe) static var cachedStorage: [String: [String: String]]?

    private static var storage: [String: [String: String]] {
        get {
            if let cachedStorage { return cachedStorage }
            let stored = UserDefaults.standard.dictionary(forKey: defaultsKey)
                as? [String: [String: String]] ?? [:]
            cachedStorage = stored
            return stored
        }
        set {
            cachedStorage = newValue
            if newValue.isEmpty {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            } else {
                UserDefaults.standard.set(newValue, forKey: defaultsKey)
            }
            UserDefaults.standard.set(
                UserDefaults.standard.integer(forKey: tickKey) + 1, forKey: tickKey)
        }
    }

    static func hex(for name: String, dark: Bool) -> String? {
        storage[name]?[dark ? "dark" : "light"]
    }

    static func setHex(_ hex: String?, for name: String, dark: Bool) {
        var all = storage
        var entry = all[name] ?? [:]
        entry[dark ? "dark" : "light"] = hex
        all[name] = entry.isEmpty ? nil : entry
        storage = all
    }

    static func reset(_ name: String) {
        var all = storage
        all[name] = nil
        storage = all
    }

    static func reset(names: [String]) {
        var all = storage
        names.forEach { all[$0] = nil }
        storage = all
    }

    static func hasOverride(_ name: String) -> Bool {
        storage[name] != nil
    }
}
