#!/bin/bash
# Applies the OrigamiFormat migration to Origami Text's source.
#
# Run this AFTER the Xcode step in README.md (adding the package and
# linking it to Origami Text macOS), because the edits below need the package's
# types to exist. Idempotent: running it twice is harmless.
#
#   bash "OrigamiFormat-migration/apply.sh"

set -e
cd "$(dirname "$0")/.."
LV="Origami Text macOS"
MIG="OrigamiFormat-migration"

echo "→ adding the re-export and the LiquidDoc adapter"
cp "$MIG/OrigamiFormatExports.swift" "$LV/OrigamiFormatExports.swift"
cp "$MIG/AnnotationAnchor+LiquidDoc.swift" "$LV/AnnotationAnchor+LiquidDoc.swift"

echo "→ retiring the two files the package now owns"
for f in WebAnnotation.swift AnnotationStore.swift; do
    if [ -f "$LV/$f" ]; then
        mv "$LV/$f" "$MIG/$f.removed"
        echo "   $f → $MIG/$f.removed"
    else
        echo "   $f already gone"
    fi
done

echo "→ patching the two source sites that must change"
python3 - <<'PY'
import sys

def patch(path, old, new, why):
    src = open(path, encoding='utf-8').read()
    if new in src:
        print(f"   {path}: already done ({why})")
        return
    if old not in src:
        sys.exit(f"   ✘ {path}: could not find the text to replace ({why}).\n"
                 f"     Expected:\n{old}")
    open(path, 'w', encoding='utf-8').write(src.replace(old, new, 1))
    print(f"   {path}: {why}")

# 1. The Selector enum gained `.page` (a PDF fragment, RFC 8118). This is
#    the one switch in Origami Text that is exhaustive over it.
patch("Origami Text macOS/EPUBReaderView.swift",
      "                case .position, .progression: break",
      "                case .position, .progression, .page: break",
      "handle the new .page selector")

# 2. The palettes are read from the shared table rather than held twice.
old_palette = '''    var builtinPalette: (lightBackground: String, lightText: String,
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
    }'''
new_palette = '''    var builtinPalette: (lightBackground: String, lightText: String,
                         darkBackground: String, darkText: String)? {
        // Read from OrigamiPalette, the table Reader reads too, so the
        // numbers cannot drift apart again. Several of them are cited
        // clinical values, not preferences.
        guard let colours = OrigamiPalette.colours(rawValue) else { return nil }
        return (colours.lightPaper, colours.lightInk,
                colours.darkPaper, colours.darkInk)
    }'''
patch("Origami Text macOS/ReaderTheme.swift", old_palette, new_palette,
      "read the palettes from the shared table")
PY

echo
echo "Done. In Xcode: the two removed files will show red in the navigator —"
echo "delete those references (Remove Reference, not Move to Trash; the"
echo "originals are kept in $MIG/*.removed), add the two new files to the"
echo "Origami Text macOS target, then build."
