# Putting Origami Text on the shared format package

**21 September 2026.** Reader and Origami Text each carried their own copy
of the format: the annotation model, its sidecar, the anchoring ladder, the
EPUB container reader, the reading palettes. The copies had drifted —
`WebAnnotation` was 58% identical, `AnnotationStore` 53%, the palettes 34% —
and, worse than drift, the two apps had come to disagree about **what a
document is**: Origami Text wrote `origamitext://open/<address>`, Reader
wrote `urn:x-reader:<record id>`, so the same book annotated in both
produced notes about two unrelated resources as far as any conforming
consumer could tell. For a format whose argument is that structure should
be declared and durable, that was the wrong bug to have.

The format now lives once, in **`~/Documents/OrigamiFormat`** — a plain
SwiftPM package, no UI, no app model, no network, buildable on macOS, iOS
and visionOS. Reader is already on it (95 tests, app builds). This is the
Origami Text half.

---

## What the package holds

| | |
|---|---|
| `WebAnnotation` | the union of both apps' models — Origami Text's annotation *kinds* and `origami:placement` / `origami:float`, Reader's passage anchoring, page selector and `reader:place` |
| `AnnotationStore` | the `<id>.annotations.jsonld` sidecar; Reader's superset (`append`/`update`/`remove`, an optional folder, security-scoped access) |
| `AnnotationAnchor` | your ladder, cut free of `LiquidDoc` so it runs over any `[AnchoredParagraph]` — Reader had no re-anchoring at all before this |
| `DocumentIdentity` | **new**: the fix for the disagreement above |
| `OrigamiPalette` | the 17 palettes, once |
| `EPUBPackage`, `ZipReader`, `EPUBMetadata` | the container reader |
| `EPUBReadingStyle`, `EPUBReadingTheme/Layout/Font` | the reading presentation |
| `DOI` | the scraper, which document identity depends on |

## The identity rule

1. **The DOI**, where the work has one — the name the world already uses.
2. **A content hash** otherwise, `urn:origami:sha256:<hex>`, so two readers
   with the same file reach the same name without asking anybody.
3. **A local name** last, `urn:origami:local:<name>`, for a card with
   neither.

Reading is deliberately more generous than writing: `DocumentIdentity.normalised`
folds every form either app has ever written onto one comparable key, so
**sidecars already on disk keep working**. Reader's record ids are content
SHA-256s, so its old `urn:x-reader:<hash>` files land on the same key as
the new canonical URN — nothing to migrate, nothing orphaned.

**One gap, stated rather than hidden.** After this migration Origami Text
writes the DOI when a document has one (so published work joins up with
Reader perfectly) and a *local* name when it does not — and Reader names an
un-DOI'd book by its content hash. Those two do not match. Closing it needs
Origami Text to hash the book file it opened and pass `contentHash:` in
`AnnotationAnchor.source(of:)`; the call is already shaped for it and the
comment there says so. Worth doing, but it is a separate change and it does
not block this one.

---

## Step 1 — Xcode (yours; it touches the project file)

1. **File ▸ Add Package Dependencies…**
2. **Add Local…**, choose `~/Documents/OrigamiFormat`, **Add Package**.
3. In the sheet that asks which target to add the `OrigamiFormat` library
   to, choose **LiquidView** (the framework, not the app targets — the app
   targets get it transitively).
4. If the sheet does not appear: select the project ▸ **LiquidView** target
   ▸ **General** ▸ **Frameworks and Libraries** ▸ **+** ▸ `OrigamiFormat`.

Deployment targets are compatible: the package declares macOS 26 / iOS 26 /
visionOS 26, against your 26 / 26 / 27.

## Step 2 — the source changes (one command)

```bash
bash "~/Documents/Origami Text/OrigamiFormat-migration/apply.sh"
```

It adds two files, retires two, and makes two edits. Both edit targets were
dry-run against your current source and match exactly once; the script
refuses rather than guesses if that ever stops being true, and running it
twice is harmless.

**Added to `LiquidView/`**

- `OrigamiFormatExports.swift` — `@_exported import OrigamiFormat`, so none
  of the seven files using `WebAnnotation` need an import added.
- `AnnotationAnchor+LiquidDoc.swift` — ten lines putting the ladder back in
  touch with `LiquidDoc`, so `AnnotationAnchor.resolve(_:in: doc)` and
  `AnnotationAnchor.target(in: doc, paragraphID:exact:)` keep their exact
  signatures. All seven existing call sites are unchanged.

**Retired** (moved to `*.removed` here, not deleted)

- `LiquidView/WebAnnotation.swift`
- `LiquidView/AnnotationStore.swift`

**Edited**

- `EPUBReaderView.swift:956` — `Selector` gained a `.page` case (Reader's
  RFC 8118 page fragment), and this is the one switch in Origami Text that
  is exhaustive over it. Becomes `case .position, .progression, .page: break`.
- `ReaderTheme.swift` — `builtinPalette` reads from `OrigamiPalette`
  instead of holding its own copy of the table. The enum, its raw values,
  the display names and `ThemeColorOverrides` all stay exactly as they are,
  so no persisted setting changes.

## Step 3 — Xcode again

The two retired files show red in the navigator. **Remove Reference**
(not Move to Trash — the originals are kept here). Add the two new files to
the **LiquidView** target. Build.

---

## What to expect, and what not to

**No behaviour changes** except these two, both intended:

- Origami Text now writes a DOI-based annotation target for documents that
  have a DOI, and `urn:origami:local:<address>` for those that do not,
  instead of `origamitext://open/<address>`. Sidecar files are keyed by
  filename, not by this string, so nothing on disk stops being found, and
  `normalised` treats old and new as the same document.
- A malformed annotation carrying no `motivation` at all now decodes as
  `commenting` rather than `highlighting`. Neither app has ever *written*
  one — the encoder always emits a motivation — so this can only affect a
  file written by something else.

## OT-5, while you are in there

`Origami TextTests` does not link `LiquidView`, so its existing
`CitationClipboardTests.swift` already fails to compile ("cannot find
'CitationClipboard' in scope"). This migration quietly improves the
position: everything that moved into `OrigamiFormat` is now tested by that
package's own target — **71 tests, all passing**, with no Xcode target
membership to get wrong. Only the export/import side
(`OrigamiEPUB.swift`, `profileWarnings`) still needs the app target fixed;
those tests are parked at `OrigamiEPUBProfileTests.swift.pending`.
