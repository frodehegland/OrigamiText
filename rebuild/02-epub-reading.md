# Chapter 2 — Opening and reading EPUBs

This chapter describes how Origami Text opens an EPUB, keeps it on the
shelf, and lets the user read it. It is written so that someone can
rebuild the reader on any platform (web, Windows, Linux, Android). It
describes behaviour, data and algorithms first; Apple-specific pieces
come last, with portable equivalents.

Everything here comes from the source in `Origami Text macOS/`. Where
the source does not settle a question, the text says "unclear from
source".

**Read these first. This chapter links to them rather than repeating
them:**

- [README.md](../README.md) and [ORIGAMI-TEXT-OVERVIEW.md](../ORIGAMI-TEXT-OVERVIEW.md): what the app is.
- [ORIGAMI-EPUB-PROFILE-1.0.md](../ORIGAMI-EPUB-PROFILE-1.0.md): the EPUB profile itself — the package, records, addressing and the reader algorithm (§17). This chapter does not restate the format.
- [ORIGAMI-EPUB-CONFORMANCE-PLAN.md](../ORIGAMI-EPUB-CONFORMANCE-PLAN.md): which EPUB 3 reading-system rules are built.
- [Origami Text macOS/WEB-READER-BRIEF.md](../Origami%20Text%20macOS/WEB-READER-BRIEF.md): a brief for a web reader. It gives the markup the reader must recognise (front matter, citations, notes, colophon, Visual-Meta) and the Map. Read it together with this chapter.
- [Origami Text macOS/ORIGAMI-TEXT-READER-ROADMAP.md](../Origami%20Text%20macOS/ORIGAMI-TEXT-READER-ROADMAP.md): the on-disk schemas for cross-document quote links and stretchtext (`››`).
- [CONTEXT-PANEL-PLAN.md](../CONTEXT-PANEL-PLAN.md): the plan for the selection context panel (§5.3 below covers what is actually built).
- [USER-GUIDE.md](../USER-GUIDE.md), which points to `Origami Text macOS/OrigamiTextUserGuide.md`: the guide as users see it.

File paths in this chapter are relative to `Origami Text macOS/` unless
they say otherwise.

---

## 1. Purpose of this layer

This layer turns a `.epub` file into a book the user can read, mark,
cite and listen to. It:

1. **Imports** the file: it unzips it once into a cache, keeps the
   original `.epub` next to it, and records the book on the shelf.
2. **Renders** it in one of two ways:
   - **"Scroll"** (internally `faithful`): the book's own XHTML pages in
     a web view, with the reader's CSS and scripts added.
   - **The native reading modes** (Horizontal, Focus, Transcript and the
     folds): the book is parsed into the app's own document model
     (`LiquidDoc`) and laid out natively.
3. **Connects** the page to the rest of the app through a JavaScript
   message bridge. Citations open cards, selections carry an anchor for
   highlights, quote links open other books, the scroll position is
   saved, and so on.
4. **Offers reading tools**: find, read aloud, the selection dot and
   context panel, Overview, equations, book information, bookmarks,
   OPDS catalogues and links that download books.

The book itself is never changed. Everything the reader makes —
annotations, positions, analyses — lives in separate files ("sidecars").
The book belongs to its author; the annotations belong to the reader
(`AnnotationStore.swift` header comment).

---

## 2. Architecture

### 2.1 The two renderers

| Renderer | Used for mode | Input | Implementation |
|---|---|---|---|
| Faithful web view | "Scroll" (`EPUBReaderMode.faithful`) | The unpacked XHTML chapter files, loaded directly from disk | `EPUBReaderView.swift` `EPUBReaderView` (wraps a WebKit view), `ReaderWebView`, `EPUBReaderView.Coordinator` |
| Native layout | Full Width (only while a fold is showing), Horizontal, Focus, Transcript, folds, find-fold | A `LiquidDoc` built by `OrigamiEPUBImporter.importDocument(inUnpackedFolder:)` | `OrigamiReadingView.swift` `OrigamiReadingView` |
| Whole-page screens | Overview, References, AI readings | `LiquidDoc` or the unpacked folder | `OverviewReadingScreen.swift`, `ReferencesScreen.swift`, `ReadingAnalysisView.swift` |

`EPUBReaderScreen` (`EPUBReaderView.swift`) is the container. Its `body`
picks what to show, in this order:

1. If an AI reading is active: `ReadingAnalysisScreen`.
2. Else if Overview is on and the `LiquidDoc` is ready: `OverviewReadingScreen`.
3. Else if References is on: `ReferencesScreen`.
4. Else if the mode is `faithful`: the web view, with the margin, slip
   and Back-button layers over it.
5. Else if the `LiquidDoc` is ready: `OrigamiReadingView`.
6. Else (the import failed or is still running): the web view.

**Rule:** the faithful web view is always the fallback. A book whose
structure cannot be parsed can still be read.

`BookNotices` (§5.11) sits above all of these, and the find bar above
that when it is open.

### 2.2 Core types

| Type | File | What it holds |
|---|---|---|
| `EPUBRecord` | `EPUBShelf.swift` | One shelved book: `id`, `title`, `author`, `authors?`, `dateISO?`, `folder`, `contentSubpath`, `openedAt`, `publication?`, `doi?`, `originalFilename?`, `packageIdentifier?`. The shelf is a JSON array of these. |
| `OpenEPUB` | `EPUBReaderView.swift` | One open reading. `id`, `title`, `content` (the first spine file), `base` (the unpacked folder the web view may read), `chapters` (spine order), `nav?`, and `sourceFile?` (set only for a look-only book). For a shelf book, `id == record.folder`. |
| `OrigamiEPUBImporter.BookSpine` | `OrigamiEPUBImport.swift` | `chapters` (folder-relative paths in spine order) and `nav?` |
| `OrigamiEPUBImporter.Rendition` | `OrigamiEPUBImport.swift` | `fixedLayout`, `rightToLeft`, `scriptedDocuments` |
| `OrigamiEPUBImporter.ImportResult` | `OrigamiEPUBImport.swift` | The parsed book: body paragraphs, links, references, concepts, tables, assets, equations, front-matter fields, `unreadableDocuments` |
| `LiquidDoc` | `LiquidDoc.swift` | The app's document model, built from `ImportResult` plus the record by `AppModel.structuredDoc(from:record:fallbackID:base:)` |
| `EPUBElementRef` | `EPUBReaderView.swift` | A clicked semantic element: `kind`, `id`, `text` |
| `ReaderSelection` | `EPUBReaderView.swift` | A text selection with its anchor: `text`, `fragment` (enclosing element id), `prefix`/`suffix` (up to 32 characters each), `glossaryTarget?`, `page?` |
| `PaintedAnnotation` | `EPUBReaderView.swift` | An annotation reduced to what the page script needs: `id`, `fragment?`, `exact`, `note?`, `kind` ("highlight" or "comment"), `colorHex`, `strike` |
| `ReaderStyle` | `EPUBReaderView.swift` | Builds the injected CSS (§4.2) |
| `EPUBReaderMode` | `OrigamiReadingView.swift` | `faithful, scroll, horizontal, focus, outline, transcript` (stored under the key `readerMode`) |

### 2.3 From file to page

```
.epub file
  │ AppModel.prepareEPUBImport (runs off the main thread)
  │   folder = identityKeyID(fileName) or fileName, with "/" and ":" replaced by "_"
  │   reuse the existing unpack if the source's mtime <= the unpacked content's mtime
  │   else OrigamiEPUBImporter.unpack:
  │       refuse DRM (throws .protected)
  │       de-obfuscate fonts (IDPF and Adobe schemes)
  │       write every zip entry into <folder>/, skipping any name containing ".."
  │   copy the .epub to <folder>.epub (the canonical copy)
  │   importMetadata: read the OPF and Visual-Meta only, not the body
  ▼
AppModel.applyPreparedImport (main thread)
  │   re-export check: same packageIdentifier under a different folder → move into the old folder, keep the old id
  │   duplicate gate: dc:identifier, then DOI, then title + first author → drop the new unpack
  │   insert the EPUBRecord at the top, persist library.json, rebuild the index
  ▼
AppModel.openStoredEPUB(record)
  │   reset reading state (fragment, Flow, fold, analysis, Overview, References, find-fold)
  │   spine = spineCache[folder] ?? OrigamiEPUBImporter.spine(inUnpackedFolder:)
  │   openEPUB = OpenEPUB(id: folder, content, base, chapters, nav)
  ▼
EPUBReaderScreen(book:)
  ├─ faithful: EPUBReaderView loads chapters[chapterIndex] from disk,
  │            with read access limited to `base`
  └─ native:   AppModel.readingDoc(forBook:) → LiquidDoc (cached; imported in the background)
```

How the import works:

- **Unpacking** is `OrigamiEPUBImporter.unpack(at:into:)`. It deletes the
  target folder first and fails with `corruptContainer` or
  `missingContent`.
- **The spine** comes from `META-INF/container.xml` `full-path` (default
  `package.opf`), then the OPF `<spine>` itemrefs. Paths are joined to
  the OPF's folder (`OrigamiEPUBImporter.spine(inUnpackedFolder:)`).
- **The structured import** (`OrigamiEPUBImporter.importDocument`) finds
  each record in this order:
  1. the record declared in the OPF by `<link rel="record" properties="origami:…">`;
  2. the well-known file name (`visual-meta.json`, `origami.json`);
  3. Visual-Meta embedded between `@visual-meta-start`/`@visual-meta-end`.

  A profile major version above 1 makes the book read as an ordinary
  EPUB (profile §16.2). Element addresses are the bare `id` for a
  one-document book, and `path#id` for a book with several documents
  (`OrigamiEPUBImport.swift`, the `address` closure near line 2326).
- **`AppModel.readingDoc(forBook:)`** never blocks the page:
  - It returns a cached doc, or a memoised index doc whose content stamp
    still matches.
  - Otherwise it starts one detached import and returns nil. The view
    redraws when the import finishes.
  - A failed import is remembered in `readingDocFailed` and not retried
    until the book is re-opened or re-imported
    (`clearReadingDocFailure`).
  - The content stamp is the content file's modification date and size,
    plus the record's `id` and `dateISO`
    (`AppModel.contentStamp(forUnpackedFolder:record:)`).
  - The index memo holds 24 books (`epubIndexMemoCap`). Index rebuilds
    are debounced by 250 ms (`rebuildEPUBIndex`).

### 2.4 Ways a book is opened

| Route | Behaviour | Code |
|---|---|---|
| File open, for a file already inside the community folder or the app's EPUB store | Import and open (joins the library) | `AppModel.importFile`, `epubJoinsLibraryOnOpen`, `openEPUBFile(at:revealInLibrary:)` |
| File open, any other file | **Look-only (Quick View).** The book is unpacked to `tmp/EPUBQuickView-<UUID>/` and opened in its own window with `OpenEPUB.id = "quickview:<dir>"` and `sourceFile` set. No record, no annotations. The temporary folder is deleted when the window closes. An orange "Import to Library" button stands where Pin and Set Aside would. | `AppModel.quickViewEPUB`, `showQuickView`, `EPUBQuickView.swift`, `ImportToLibraryButton` |
| Shelf row | `openStoredEPUB` | `AppModel.openStoredEPUB` |
| `origamitext://open/<address>[?q=…][#fragment]`, or `https://origamitext.app/o/<address>…` | Find the book by address, open it, and land on the fragment | `Coordinator.parseOrigamiURL`, `CitationClipboard.parse(href:)`, `AppModel.openEPUB(address:fragment:)` |
| A link to an `.epub`, a DOI, a "download" link, `gemini:`, `hm:` | `AppModel.claimLink` decides (§5.12) | `RemoteEPUB.swift` |
| OPDS catalogue | Download, then `importFile` | `OPDSCatalog.swift` |

`AppModel.openEPUB(address:fragment:)` looks the address up with
`epubRecord(forAddress:)`. It tries, in order: the canonical address
equal to `id`, the raw `id`, the `folder` (raw or canonical), and the
`originalFilename`. It then sets `pendingReaderFragment`.

### 2.5 State per open book

There are three places state lives.

**1. `AppModel` (shared across views)**
- `openEPUB`, `pendingReaderFragment`
- `readerFoldLevel`, `readerFindFoldTerm`
- `readingOverviewOn`, `readingReferencesOn`, `readingAnalysisKind`
- `flowReading`, `selectionContext`
- `annotationsStamp` (bumped on every annotation change so the page repaints)
- caches: `readingDocCache`, `spineCache`, `quoteLinksCache`, `glossaryCache`, `glossaryTargetCache`, `citedHereCache`

**2. `EPUBReaderScreen` (reset per book in `.task(id: book.id)`)**
- `chapterIndex`; `requestedFragment` with `fragmentStamp`; `requestedFraction`
- `initialFraction`, `lastFraction`
- `linkHistory` (up to 50 entries of chapter and fraction, for Back)
- `tocEntries`, `pageTargets`
- `currentHeadingID`, `currentOutlineID`
- `chapterWords` (word counts, computed in the background)
- find state: `showsFind`, `findText`, `findStamp`, `findForward`, `bookHits`
- read-aloud state: `pageReader`, `overlayPlayer`, `readingOn`
- margin visibility

**3. `EPUBReaderView.Coordinator` (per web view)**
- `loadedID` / `finishedLoadID`; `pendingFragment`, `pendingScrollFraction`, `pendingFind`
- `restoredBookID`
- the handled stamps, which make every "do it again" request fire exactly once
- `chapterPaths`, `bookBasePath`, `scriptedPaths`
- the latest closures

**The stamp pattern.** A command is sent as a value plus an integer that
increments each time; the view acts when the integer changes. Find next,
jump to fragment, heading step and read aloud all work this way. A
rebuild in any framework needs the same idea: a way to send the same
command twice.

### 2.6 Reading position

**Saving (Scroll mode).**
- The page posts `progress` with a 0–1 scroll fraction, throttled to
  400 ms (`progressScript`).
- The screen records `lastFraction` and calls
  `AppModel.saveReadingPosition(forFolder: book.id, chapter: <subpath>, fraction:)`.
- That writes the UserDefaults key `readingPosition:<folder>` =
  `{chapter, fraction, t}`, where `t` is Unix seconds.
- It also schedules a write of the shared file `_reading-positions.json`
  in the community folder (`AnnotationSync`).

**Reading.** `AppModel.readingPosition(forFolder:)` uses the shared
position if its `t` is newer than the local one, otherwise the local one.

**Restoring.**
- Only when `reopenWhereLeftOff` is true (default **false**), and never
  when a fragment is waiting (a quote link wins).
- The screen picks the saved chapter and sends `requestedFraction`.
- The web view calls
  `origamiScrollToFraction(f)` = `scrollTo(0, (scrollHeight - innerHeight) * f)`.
- A restored position is applied once per opened book (`restoredBookID`).

**Default.** A fresh book opens at the top of chapter 0. This matches
WEB-READER-BRIEF §3.

**Native modes.** `OrigamiReadingView.noteProgress` writes
`readingProgress.<doc.id>` (a scroll offset in points, 600 ms debounce).
Nothing reads it back (see §10, discrepancies).

**Bookmarks.** UserDefaults `bookmarks:<folder>` holds a JSON array of
`ReaderBookmark {id: UUID, chapter, fraction, label, created}`. The
label is "<chapter label> · NN%" (`EPUBReaderScreen.placeLabel`).

---

## 3. Data on disk

`AS` = the per-user application-support folder. `AS/EPUBs` is
`AppModel.epubsRoot`. `CF` = the user's community folder (an optional
synced folder).

**Identifier rule (verified).**
- Files shared between devices, in CF, are keyed by **`record.folder`**,
  which is derived from the file name and is the same on every device.
- Local sidecars in AS are keyed by **`record.id`** (the book's address)
  through `AppModel.annotationAddress(forBook:)`, which is `record.id`,
  or `book.id` when no record exists.
- UserDefaults position and bookmark keys use `folder`.

| Path | Format | Keyed by | Writer / reader |
|---|---|---|---|
| `AS/EPUBs/library.json` | JSON array of `EPUBRecord` (pretty, sorted keys), written atomically | — | `AppModel.persistEPUBRecords`. A failed write beeps and shows a note: the manifest *is* the shelf. |
| `AS/EPUBs/<folder>/` | The unpacked package (a rebuildable cache) | folder | `OrigamiEPUBImporter.unpack` |
| `AS/EPUBs/<folder>.epub` | The original bytes (the canonical copy) | folder | `prepareEPUBImport`. Missing copies are rebuilt at launch by `ensureStoredEPUBs`. |
| `AS/EPUBs/<folder>/origami-model-viewer.js`, `origami-model-stage-<file>.html` | A copy of the bundled viewer plus a generated stage page for 3D models | folder | `OrigamiModelView.buildStage` (`OrigamiReadingView.swift`). **This writes inside the unpacked cache, not inside the stored `.epub`.** |
| `AS/EPUBs/Annotations/<address>.annotations.jsonld` | A W3C AnnotationCollection (JSON-LD) | record.id | `AnnotationStore` (another chapter covers the annotation model) |
| `AS/EPUBs/Analyses/<address>.analyses.json` | `{kind: {text, names, keywords, created, glossary?, dismissed?}}` | record.id | `ReadingAnalysisStore`, `AppModel.saveAnalysis` |
| `CF/<folder>.epub` | The published copy of each shelf book | folder | `AppModel.mirrorShelfToCommunityFolder` |
| `CF/_annotations/<folder>.json` | `{annotations: [WebAnnotation], deleted: {id: Date}}`, ISO 8601 dates; merged per annotation, newest wins | folder | `AnnotationSync` (coordinated reads) |
| `CF/_reading-positions.json` | `{folder: {chapter, fraction, t}}` | folder | `AnnotationSync.positionsURL` |
| `CF/origami-standing.json` | `{pinned: [folder], setAside: [folder], concepts?, modified}` | folder (converted from local ids on write) | `EPUBStanding` (coordinated read) |
| `CF/origami-acquisitions.json`, `CF/_map-views.json`, `CF/` + `AS/` `origami-map-layout.json`, `origami-spatial-notes.json`, `AS/origami-concept-overrides.json` | The shelf and Map stores | see `EPUBShelf.swift` | Covered by the library/Map chapter. Listed here only so a rebuild knows they exist. |
| Shared App Group container `…/Library/Application Support/Overview Pictures/index.json` plus image files | The picture cache for Overview, shared with the Author app | name key | `OverviewPictureStore` (§5.5) |
| `~/Library/Application Support/Origami Text/Voices/qwen3-tts-0.6b-customvoice-bf16/` | The neural voice model and `manifest.json` | — | `VoiceInstaller` (§5.2) |
| `tmp/EPUBQuickView-<UUID>/` | A look-only unpack, deleted when its window closes | — | `quickViewEPUB` |

**UserDefaults keys this layer reads or writes**

| Key | Default | Meaning |
|---|---|---|
| `readerMode` | `faithful` | The current mode word |
| `readingPosition:<folder>` | — | `{chapter, fraction, t}` |
| `bookmarks:<folder>` | — | JSON `[ReaderBookmark]` |
| `readingProgress.<doc.id>` | — | Native scroll offset (written, never read) |
| `reopenWhereLeftOff` | false | Restore the position on open |
| `readingFontDelta` | 3.0 | Points added to an 18 pt base (all modes) |
| `readingLineSpacing` | 3.0 | Extra leading in points (all modes) |
| `faithfulMeasure` | 0 (read as 38) | Column width in ems: Wide 46, Medium 38, Narrow 32 |
| `faithfulJustify`, `faithfulHyphenate`, `faithfulPublisherStyles` | false | Scroll-mode page options |
| `readingMeasure` | 680 | Native windowed column width in points (380…1200, steps of 40) |
| `fullScreenWidthInternal` / `fullScreenWidthExternal` | 67 / 45 | Native full-screen column as a % of the display width (25…100, steps of 4); minimum 300 pt |
| `readerLeftMarginMode` | `nothing` | Left margin: `nothing`, `outline` or `annotation` |
| `readerRightMarginMode` | `outline` | Right margin |
| `readerMarginsAutoHide` | true | Margins fade 4 s after the pointer leaves |
| `readerTheme` | `highContrast` | Theme (§6) |
| `readerBodyFont` / `readerHeadingFont` | `Times New Roman` / `Georgia` | Families |
| `ThemeColorOverrides`, `themeColorOverridesTick` | — | Edited theme colours (§6) |
| `origamiNoteStyle` | `superscript` | Note marks: `superscript`, `bracketed`, `dagger`, `fold` |
| `notesOpenAsPopup` | true | Notes open as a popup (ignored when the style is `fold`) |
| `selectionContextStyle` | `custom` | `system` hides the selection dot |
| `readingFoldTarget` | `headings` | What the fold shows under headings |
| `origamiCitationStyle` | `authorDate` | Citation mark style in native modes |
| `readAloud.rate`, `readAloud.voiceID`, `readAloud.engine` | 1.0, "", `apple` | Read Aloud |
| `opdsCatalogues` | — | Newline-separated catalogue URLs |
| `linkedEPUBFolders` | — | `{downloadKey: folder}` for books fetched from links |

---

## 4. Rendering

### 4.1 Loading a chapter, and security

`EPUBReaderView.load` loads the current chapter file directly, allowing
the web view to read only the book's own folder:
`loadFileURL(chapter, allowingReadAccessTo: book.base)`. The web view has
a transparent background (`drawsBackground = false`, clear under-page
colour), so the themed native background shows through any repaint gap,
and back/forward swipe gestures are off.

`Coordinator.webView(_:decidePolicyFor:preferences:decisionHandler:)`
applies these rules, in order:

| # | Condition | Action |
|---|---|---|
| 1 | Main frame, `data:` URL | Cancel (EPUB 3.3: no top-level data pages) |
| 2 | Main frame, `file:` URL outside `book.base` | Cancel (no page outside the book) |
| 3 | Any `file:` URL | The page's own JavaScript runs only if the file is listed as `scripted` in the OPF (`preferences.allowsContentJavaScript`). The reader's injected scripts always run. |
| 4 | `origamitext:` | Parse it; `onFollowLink(address, fragment)`; cancel |
| 5 | A clicked http(s) link that parses as an `https://origamitext.app/o/…` carrier | `onFollowLink`; cancel |
| 6 | `onExternalLink(url)` returns true (`AppModel.claimLink`: a book link, DOI, capsule, Seed) | Cancel |
| 7 | Any other clicked http(s) link | Open in the system browser; cancel |
| 8 | Any other clicked non-file scheme (for example `mailto:`) | Hand to the system; cancel |
| 9 | A clicked `file:` link to one of the book's chapters | `onBookLink(index, fragment)`; cancel. The screen changes chapter and pushes the current place onto `linkHistory`. |
| 10 | A clicked `file:` link to an image (png, jpg, jpeg, gif, webp, svg, avif, heic, tif, tiff, bmp) | Show an in-page lightbox (`showImageLightbox`): fixed overlay, black at 0.55, image at most 78% × 82%, closed by a click or Escape; cancel |
| 11 | Otherwise | Allow |

`Coordinator.webView(_:didFinish:)` runs after every load, in this
order:

1. Record `finishedLoadID`.
2. Scroll to `pendingFragment` if there is one; else to `pendingScrollFraction`.
3. `origamiApplyQuoteLinks(list)`.
4. `origamiMarkCitedHere(counts)`.
5. A pending find (from "All Chapters").
6. `origamiPaintAnnotations(list)`.
7. `injectChapterFooter`: for books with more than one chapter, centred
   "‹ Previous Chapter" / "Next Chapter ›" buttons, swapped for
   right-to-left books.
8. `origamiFindCitationAnchors()`.

**Scrolling to a fragment** (`Coordinator.scrollToFragment`):
1. Take the text after the last `#`.
2. Unfold any stretchtext that contains the target.
3. Find the target by `id`, else by `[data-id]`.
4. Headings land at the top (`block: 'start'`); everything else is centred.
5. Scroll again after 350 ms, because fonts and late images reflow the page.
6. Flash the element: background `rgba(255,214,10,0.45)` for 1.6 s, with a 1.2 s transition.

### 4.2 The injected CSS

`ReaderStyle.css(bodyFont:headingFont:theme:fontDelta:lineSpacing:options:)`
builds one string, so theme and fonts change together.

**Formulas**
- `size% = max(50, round((18 + fontDelta) / 18 × 100))`
- `lineHeight = max(1.2, 1.2 + lineSpacing / (18 + max(fontDelta, −8)))`, written with 2 decimals

**Optional extras**
- Justify: `p, li, blockquote { text-align: justify !important }`
- Hyphenate: `-webkit-hyphens/hyphens: auto !important`
- Measure > 0: `body { max-width: <m>em !important; margin auto; padding 0 1.5em }`. In the Scroll screen the measure is always > 0 (`effectiveMeasure`, default 38).

**Publisher's Styles on.** Only the following are added, so the book's
own type stands:
- `a { color: inherit }`
- `img { max-width: 100%; height: auto }`
- the extras
- the theme CSS

**Normal output, in order**
1. Links: `a, a:link, a:visited { color: inherit; }` — never browser blue.
2. Body: `font-family: "<body>", 'Times New Roman', Times, serif; font-size: <size>%; line-height: <lh>`.
3. Headings: `h1–h6 { font-family: "<heading>", Georgia, serif }`.
4. A title-only header (`header.title-only h1`) also gets `color: #808080`.
5. Glossary terms read as plain text: `dfn { font-style: inherit; border-bottom: none }` and `a[role="doc-glossref"], a[data-glossary-id] { text-decoration: none; cursor: text }`.
6. Images and figures: `img { max-width: 100%; height: auto }`, `figure { margin-left/right: 0 }`.
7. Tables: border-collapse, centred, top and bottom rules; `th`/`td` left-aligned with right padding of 1.2em.
8. `pre`: grey `rgba(127,127,127,0.12)` box; `pre code` at 0.85em with `pre-wrap`.
9. Front matter in the body ink: `.affiliation, .author-detail, .author-details, .byline, .license, .acm-reference` and their links get `color: inherit !important`.
10. The extras.
11. The theme CSS (§6).

**Fixed-layout books get no reader CSS at all.** The screen passes
`css: ""` when `rendition.fixedLayout`.

**Order rule (verified).** `themeScript(css:)` creates or reuses
`<style id="origami-theme">` and appends it to
`document.head || document.documentElement`. It is installed twice:

- **At document start**, before there is a `<head>`, so it lands on
  `<html>`, ahead of the book's stylesheet.
- **At document end.** Appending the same element again moves it to the
  end of `<head>`. On equal specificity the theme then beats a book
  stylesheet that paints its own body (for example a
  `prefers-color-scheme` rule).

A rebuild must make the reader's CSS come *after* the book's, and
re-assert that after the document is parsed.

### 4.3 Injected scripts, in installation order

All scripts are main-frame only. Order matters, because several of them
register click listeners in the capture phase and call
`stopImmediatePropagation()`: whichever registers first wins the click.
`installUserScripts(into:themeCSS:noteFolds:fixedLayout:)` installs:

| # | Script | When | What it does |
|---|---|---|---|
| 0 | `fixedLayoutScript` (fixed-layout books only) | end | Reads `<meta name=viewport content="width=W,height=H">`. Scales `<html>` by `min(innerWidth/W, innerHeight/H)`, centred with translate; re-fits on resize. Does nothing without both numbers. |
| 1 | `themeScript` | start | §4.2 |
| 2 | `themeScript` | end | Moves the theme style to the end of `<head>` |
| 3 | `hideScript` | start | `<style id="origami-vm-style">#visual-meta{display:none}</style>` |
| 4 | `toggleButtonScript` | end | Inserts a centred "Metadata" button before `#visual-meta`. It toggles `hidden` and `display`; the label becomes "Hide Metadata" while open. |
| 5 | `glossaryScript` | end | Cancels clicks on `a[data-glossary-id], a[role="doc-glossref"]`. Definitions are reached through Show Definition in the context menu, not by clicking. |
| 6 | `endnoteScript(foldMarks:popups:)` | end | Note marks (§5.9). Must come before stretchtext so a note-mark click unfolds rather than jumps. |
| 7 | `stretchtextScript` | end | `a.ot-stretchtext` toggles (§5.9); exposes `origamiRevealStretchtext(id)` |
| 8 | `currentHeadingScript` | end | Posts `currentHeading`: the last visible heading whose top is ≤ 25 px, sent only when it changes. Runs 80 ms after scrolling settles, and once at 300 ms. |
| 9 | `figureLinkScript` | end | Figures whose `<img>` is wrapped in `<a href>`: adds class `ot-figure-link`, a hover lift, and a badge reading "Open in Interatlas" (for `interatlas:` or `link.augmentedtext.com` links not under `/liquid/`) or "Open Link". A click waits 280 ms so a double-click can claim it; keyboard activation opens at once. Hover posts `figurelinkhover`. |
| 10 | `citationScript` | end | Citation clicks post `citation` and never jump to the reference list (§5.8) |
| 11 | `citationAnchorScript` | end | Posts `citationAnchors` with normalised positions, on load and 150 ms after scrolling. Exposes `origamiFindCitationAnchors`. Used by the visionOS hallway. |
| 12 | `figureJumpScript` | end | `a.ot-jump` whose target is in a `<figure>` posts `figurejump` instead of scrolling. Double-clicking any figure posts `figurejump` with the figure's `data-id` or `id`. |
| 13 | `annotationScript` | end | Exposes `origamiPaintAnnotations`. A click on a painted range posts `annotation`. |
| 14 | `bridgeScript` | end | The semantic bridge: `activate`, `selection`, `selectionMoved` |
| 15 | `quoteLinkScript` | end | Decorates `origamitext://` links with a `[]` transclusion control. Exposes `origamiApplyQuoteLinks`, `origamiMarkCitedHere`, `origamiInsertTransclusion`. |
| 16 | `progressScript` | end | Posts `progress` (400 ms throttle). Exposes `origamiScrollToFraction`. |
| 17 | `readAloudScript` | end | Exposes `origamiReadAloudUnits`, `origamiReadAloudMark`, `origamiOverlayMark` |
| 18 | `greyContrastScript` (not for fixed layout) | end | For every element with a grey colour (channel spread ≤ 16) whose WCAG contrast against the body background is under 3, sets `color: inherit !important`. Coloured inks are left alone. |

**Live changes without reloading.** When the CSS, note style or popup
setting changes, `updateNSView` removes all user scripts, reinstalls
them, and evaluates `themeScript`, `endnoteScript` and
`greyContrastScript` on the live page. The scroll position is kept. The
endnote script guards itself (`window.origamiSetNoteFolds`), so running
it again only reapplies the marks and never adds a second listener.

### 4.4 The bridge: page to native

There is one channel: `window.webkit.messageHandlers.origami.postMessage(obj)`
(`EPUBReaderView.bridgeName = "origami"`). Every message is an object
with an `event` field. The handler is
`EPUBReaderView.Coordinator.userContentController(_:didReceive:)`.

| Message (`event`) | Direction | Payload | Handler and effect |
|---|---|---|---|
| `activate` | page → native | `kind` (`equation` / `citation` / `heading` / `paragraph`), `id`, `text` (≤ 200 characters) | `onActivate`. The screen opens the Equations sheet focused on that equation; any other kind shows a short note "<Kind> · <id>". Classification walks up from the click target: `math[id]`, `a.citation`, `h1–h6[id]`, `p/li[id]`. `dfn` is deliberately not classified. |
| `selection` | page → native | `text` (trimmed, ≤ 500 characters), `fragment` (nearest `[data-id]` or `[id]` ancestor), `prefix`, `suffix` (32 characters each side of the first occurrence of the text in that host), `page?` (the last `epub:type~=pagebreak` or `role=doc-pagebreak` marker before the selection: its `title`, `aria-label` or text), `glossary?` (the target id when inside a glossref link), `x`, `y` (viewport, where the mouse was released) | Sent on **every** mouseup, even an empty one. Sets `ReaderWebView.selectedText` and `currentSelection`, then `onSelect` and `onSelectionAt(selection, point)`, which drives the selection dot. |
| `selectionMoved` | page → native | `x`, `y` | Sent on scroll (one per animation frame) while a selection stands. Moves the dot. |
| `annotation` | page → native | `id`, `kind`, `note`, `x`, `y` | A click on a painted range (found with `caretRangeFromPoint` and `Range.comparePoint`). Shows the annotation popover with Remove. |
| `citedHere` | page → native | `id` | Click on a "❝ N" mark. Opens the list of library places that cite this passage. |
| `chapterStep` | page → native | `delta` (±1) | Chapter footer buttons |
| `progress` | page → native | `fraction` (0–1) | Saves the reading position |
| `citation` | page → native | `key` (`data-citation-id`, else `data-citation-key`, else the `href` target with a leading `bib-` removed), `ref` (`data-origami-ref` or "") | §5.8 |
| `figurejump` | page → native | `targetID` | Opens a figure window for that element |
| `figurelink` | page → native | `href` | Opens the figure's link outside the app (`AppModel.openFigureLink`) |
| `figurelinkhover` | page → native | `href` ("" on leave), `key`, `id` | Remembers which linked figure is under the pointer, for the context menu |
| `currentHeading` | page → native | `id` ("" above the first heading) | Bolds the matching entry in the Outline margin |
| `citationAnchors` | page → native | `anchors: [{id, ref, href, nx, ny, inView}]` | Stored on `model.openDocCitationAnchors` (used by visionOS) |
| `endnote` | page → native | `href`, plus either `reqId` (insert inline) or `popup: true, x, y` | Looks up the note text with `AppModel.endnoteText(inBook:id:)`. Popup: `ReaderWebView.showNotePopup`. Inline: evaluates `origamiInsertEndnote(reqId, text)`. If missing: "The note could not be found." |
| `transclude` | page → native | `href` (an `origamitext://` URL), `reqId` | `AppModel.transcludedText(forAddress:fragment:)`, else the link's `q` text, else "The quoted document is not in your library." Then evaluates `origamiInsertTransclusion(reqId, text)`. |

**Native to page.** The native side calls these page functions with
`evaluateJavaScript`. Strings are built with
`Coordinator.jsStringLiteral`, which escapes `\`, `"`, newlines, U+2028
and U+2029. JSON arguments also have U+2028/U+2029 escaped.

| Function | Called when |
|---|---|
| `origamiScrollToFraction(f)` | Restoring a position, Back, bookmarks |
| `origamiPaintAnnotations(list)` | After load, and whenever `annotationsStamp` changes |
| `origamiApplyQuoteLinks(list)` | After load. The list comes from Visual-Meta `links[]` (`fromAddress`, `toEdition`, `toAddress`, `quotedText`), via `AppModel.quoteLinks(forBook:)`. |
| `origamiMarkCitedHere(counts)` | After load: `{bareID: count}` |
| `origamiInsertEndnote(reqId, text)`, `origamiInsertTransclusion(reqId, text)` | Answers to `endnote` / `transclude` |
| `origamiReadAloudUnits()` | When `readAloudStamp` changes. Returns `{sentences, start}` as a JSON string. |
| `origamiReadAloudMark(i)`, `origamiOverlayMark(id)` | The spoken sentence or narrated element changes |
| `origamiFindCitationAnchors()` | After load |
| `headingStepScript(direction)` | Down/Up arrow (§4.7) |
| Native find (`WKWebView.find`, case-insensitive, wraps) | When `findStamp` changes; an empty text clears |

### 4.5 Annotation painting algorithm

The page DOM is never changed. Painting uses the CSS Custom Highlight
API (`annotationScript`). For each annotation:

1. **Normalise the fragment.** If it has the form `path#id`, keep the
   `id` only when the file name of `path` equals the page's file name.
   Otherwise drop it: another document may share the id.
2. **Find the host**: `getElementById(fragment)`, else `[data-id=fragment]`.
3. **Find the range** in this order:
   - the exact words inside the host — case-insensitive, matched across
     text nodes (`findRange`);
   - else the exact words anywhere in `body`;
   - else the whole host element. This step is skipped for a comment on a
     heading: those are drawn as floating slips by the native layer
     (`EPUBReaderScreen.commentSlipsLayer`), because inking a heading
     reads as marking the heading itself.
4. **Group and style.** Ranges are grouped per colour into a `Highlight`
   named `origami-k<RRGGBB>`, plus `-s` for strikethrough. Each group gets
   the rule `::highlight(name){color:#hex}` or
   `{text-decoration:line-through; text-decoration-color:#hex}`. **The ink
   colours the type itself; there is no background fill.** The default
   colour is `E8C51D`.

Lifted quotes ("Lift") and heading comments are drawn natively, as
draggable slips over the page (`MarginNoteView`). Their positions are
stored in the annotation's `placement` as absolute `dx`/`dy` within the
reader frame.

### 4.6 The Scroll page's context menu

The native menu is replaced completely (`ReaderWebView.willOpenMenu`).
Context-menu plug-ins (Services, Share) are turned off.

**With selected text**
1. **Show Definition** — only if the glossary resolves the selection's
   glossary target or the words themselves. Shows a popover.
2. **Highlight ▸** the annotation kinds: Important `i`, Quotable `q`,
   then Great `g`, Disagree `d`, Language Issue `l`, Problematic `p`,
   What is this? `/`, Highlight `h`, then Strikethrough `x`. The letters
   are bare-key shortcuts inside the submenu.
3. **Add Comment…**
4. **Copy to Cite**
5. **Copy**
6. **Look Up "…"** and **Translate "…"** — the text is shortened to 24
   characters plus "…" in the menu titles.

**On a linked figure, with nothing selected**
- The link's own action title, then **Show Image** (if the figure has an
  id) and **Show Reference** (if it has a citation key).

**With nothing selected**
1. **Copy to Cite** (the whole book)
2. **Copy Link to Paragraph** — the nearest ancestor with a stable id;
   in the margins, the block nearest the click's height
   (`fragmentAtPointJS`)
3. **Show Author's Map**
4. **Equations…**
5. **Book Information…**
6. **Add Comment…** (anchored to the paragraph under the click)
7. **Remove Comment** (only when comments exist on the page)

### 4.7 Reading modes and their layout rules

The **foot bar** (`ReadingFootBar`, `OrigamiReadingView.swift`) is the
mode switch. It has three regions:

- **Left:** Pin and Set Aside (or Import to Library for a look-only
  book); the book title in Horizontal (at most 420 pt, cut off with …);
  "Folded — level N" or "Finding "…"" while a fold stands.
- **Centre** (natural width, always truly centred), in this order:
  `AI` · `Scroll` · `Outline` · `Horizontal` · `Focus` · `References` ·
  (`Transcript` only when the book is a transcript).
  - `AI` opens to `[ AI | Issues ]`.
  - `Outline` opens to `[ Outline | Overview | Citations ]`.
  - In native modes, `Focus` opens to `[ Focus | Sentence | Paragraph | Word ]`.
- **Right:** contents (list icon), `Aa` type menu (native), and
  accessories (read aloud, progress readout, bookmarks, palette, type
  panel).

**Switching modes is instant, with no animation**
(`ReadingFootBar.modeSwitch = nil`). Choosing a mode word clears any
fold, find-fold, AI reading, Overview and References first, so the word
always shows its own view.

**A book is a transcript** when its document type is `transcript`, or
any paragraph has a `speaker`.

| Mode word | Internal | Layout rules and constants | Code |
|---|---|---|---|
| **Scroll** | `faithful` | The book's own pages in the web view. Column width `effectiveMeasure` em (Wide 46 / Medium 38 / Narrow 32), centred. **Margins** either side. One em = `16 × size% / 100` px. Column = `(measure + 3) × em`. Each margin = `floor((width − column) / 2)`, shown only if ≥ 120 pt; the right margin has 14 pt trailing padding. Margins are not shown for fixed layout, or when neither side is Annotation and the book has no table of contents. | `EPUBReaderScreen.faithfulReader`, `marginsLayer` |
| **Full Width** | `scroll` | No longer a choice of its own. A stored `scroll` value is read as Scroll unless a fold or find-fold stands; then the native article fills the window width (`maxWidth: .infinity`). | `EPUBReaderScreen.readerMode` |
| **Horizontal** | `horizontal` | Pages side by side. Page count = `min(max(floor(width/460), 2), pageCount)`. Pages are built by `OrigamiReading.horizontalColumns` (below). Prev/Next turn a whole spread (← →). A two-finger sideways swipe of more than 60 px turns one page, once per gesture, only when more than 2 pages are showing; momentum is ignored. Label: "Title — i–j of N". | `OrigamiReadingView.horizontalView`, `horizontalPageCount`, `turnPages` |
| **Focus** | `focus` | One page (one section) at a time. Column 560 pt windowed, or the measure in full screen; padding 40. Font delta + 1, line spacing × 2. Sub-modes: **Sentence** (one sentence at a time, 18 + delta pt, ← →), **Paragraph** (one paragraph at a time), **Word** (RSVP, 44 + delta pt, 60…800 wpm in steps of 25, default 250, back/forward 5 words). | `focusView`, `focusColumn`, `rsvpOverlay`, `sentenceDisplay`, `paragraphDisplay` |
| **Transcript** | `transcript` | Consecutive paragraphs with the same speaker form one turn. The speaker name is a headline; turns are indented 12 pt with a 3 pt rule. | `transcriptView` |
| **Outline ▸ Outline / Overview / Citations** | fold level > 0 | Native folded view (algorithm below). Overview opens its own page (§5.5). Citations shows each section's cited works. Choosing the same shape again unfolds. | `ReadingFootBar.outlineGroup`, `choose`, `OrigamiReadingView.foldedView` |
| **References** | `readingReferencesOn` | A page of the works this document cites (Title / Author / Date / Map views). Covered by another chapter. | `ReferencesScreen.swift` |
| **AI ▸ AI / Issues** | `readingAnalysisKind` | A summary, or a reviewer's pass, from the reader's chosen model. Stored per book under `Analyses/`. Covered by the AI chapter. | `ReadingAnalysisView.swift` |

**Horizontal pagination** (`OrigamiReading.horizontalColumns`, `wordsPerColumn = 300`):
1. Sections come from the headings (`OrigamiSection.build`).
2. A section with no body (a heading followed by another heading) waits
   and rides on top of the next section that has a body. Trailing
   headings join the last page.
3. A section heavier than 300 is split into column-sized parts. The
   first part keeps the heading; the rest have none.
4. Weight is counted in words, but a table, image or 3D model counts as
   100 (`figureColumnWeight`).

**Folding** (`OrigamiReading.folded(_:level:expanded:)`):
- `maxFoldLevel` = the number of distinct heading ranks + 1 (1 if there
  are no headings; 0 for an empty body).
- **Level 1:** every heading; the first sentence of the first paragraph
  after each heading; and every sentence containing `==Marked==` text.
  Stretch, table, image and `---` paragraphs are skipped.
- **Level 2:** headings only.
- **Each level above 2** drops the finest heading rank still showing.
- **Expanding:** a heading id in `expanded` shows its whole subtree,
  until the next heading of the same or a coarser rank.
- **⌘−** and **pinch in** (total ≤ −0.15) open Overview for an open book
  (`AppModel.foldOpenReadingIntoOverview`).
- **⌘+** and **pinch out** (≥ +0.15) unfold.

**Find-fold** (`OrigamiReading.folded(_:matching:)`):
- Shows every heading, plus, for each paragraph containing the term, only
  its sentences that contain it. Matching ignores case, diacritics and
  width.
- Returns nil when nothing matches.
- Clicking a line returns to the full reading at that paragraph
  (`jumpFromFindFold`); the find clears after 2 s.

**Native type limits**
- Font delta −6…18 everywhere.
- Line spacing 0…24 in native modes, 0…18 in the Scroll panel.
- Body size = system body size + delta (minimum 8).
- Heading size = `title1 × 0.88^(level−1)`, at least body + 1, then
  + delta − 1.
- Spacing between paragraphs: 18.

### 4.8 Native paragraph rendering (summary)

`OrigamiReadingView.standardParagraphView` picks the first rule that
applies:

1. A 3D model reference → `OrigamiModelView`
2. A linked image `![alt](asset:id)` whose asset has a link → `OrigamiAssetView` (click opens the link, double-click shows the image)
3. A plain image → `OrigamiAssetView`
4. A table found in `doc.tables` → `OrigamiTableView` (live formulas, with what-if overrides)
5. A missing table → monospaced pipe text
6. Fenced code → monospaced block
7. Display maths `$$…$$` → readable Unicode TeX, centred (no MathML rendering in native modes)
8. `---` → a divider
9. Anything else → `annotatedParagraph`: a selectable text view with paragraph numbers, cited-here marks, and a tint while it is being read aloud

**Inline passes** (`inlineTextNow`), applied in order:
1. Markdown, citations and `==Mark==`
2. The AI key sentence colour
3. Highlights (exact match, kind colour; comments become links)
4. Find matches: orange background at 0.5 on the current match, 0.22 on the others
5. Glossary display
6. Inline notes
7. Trailing and closing stretchtext
8. Text colouring (grammar / meaning / argument / key statement)

The result is cached by a signature of every input.

### 4.9 Keys and gestures

| Input | Where | Effect |
|---|---|---|
| ← / → | Scroll | Open the previous or next book in the same venue, else in the shown shelf (pinned books first). Beeps at either end. |
| ↓ / ↑ | Scroll | Next or previous heading. The paper title is skipped when no text stands above it. Up past the first heading goes to the top. |
| ← / → | Horizontal, Focus, Sentence | Turn the page or step |
| ⌘F | anywhere | Library find (in the book when the list is hidden). "Find in Book" opens the book's find bar; if text is selected in a native mode, it opens the find-fold instead. |
| ⌘G / ⇧⌘G | book | Next or previous match |
| ⌘− / ⌘= | book | Overview / unfold |
| ⇧⌘+ / ⇧⌘− and ⌥⌘+ / ⌥⌘− | native | Text size / line spacing |
| ⇧⌘F | native | Flow on or off |
| Space | native | Read Aloud: start, pause or resume |
| Tab | native | Glossary overview on or off |
| p / f / b | native | AI Paragraphs / Flow / colour key sentences |
| Esc | native | Leave venue focus, else toggle full screen |
| ⌘[ | Scroll | Back (when a link was followed) |
| Pinch | both | In: Overview. Out: close the contents or unfold. |

---

## 5. Features

### 5.1 Find

**In the open book (Scroll).**
- The bar holds a field, ↑ ↓, **All Chapters**, and ✕ (Esc).
- Each step uses the web view's own find (case-insensitive, wraps).
  Closing the bar sends an empty find, which clears the highlights.

**All Chapters** (`EPUBReaderScreen.searchWholeBook`):
1. For every chapter file: decode it (BOM, then the XML declaration's
   encoding, then UTF-8), keep everything from `<body`, replace tags with
   spaces, decode `&nbsp;` and `&amp;`, and collapse whitespace.
2. Search ignoring case and diacritics.
3. Each hit gets 60 characters before and 80 after, with "…" where cut.
4. Stop at 300 hits.
5. A popover lists them: "No matches in this book", "1 match", "N matches"
   or "The first 300 matches".
6. Clicking a hit in another chapter loads that chapter and finds once it
   has loaded (`findOnLoad`).

**Native modes** (`OrigamiReadingView.stepFind`):
- Steps paragraph by paragraph through `doc.body`, ignoring case,
  diacritics and width, and wraps.
- Turns the page in Horizontal or Focus, and opens a folded stretch first.
- The current match is shaded 0.5 and the others 0.22.

**Find-fold**: see §4.7.

**"Where Have I Read This?"** (⌥⌘F, plus a system Service)
(`ReadingSearch.swift`):
- Searches every indexed library document, and optionally a folder of
  PDFs.
- Normalising: fold case and diacritics, straighten quotes, turn dashes
  into hyphens, remove soft hyphens, collapse whitespace.
- The phrase must be at least 3 characters.
- An **exact** hit is a substring match. A **loose** hit (only for
  phrases of more than one word) needs every word present somewhere in
  the paragraph.
- Order: exact hits by title, then loose hits by title.
- Snippets are 140 characters each side.
- PDF search is limited to 2,000 files, one hit per file.
- Settings keys: `findInReading.searchesLibrary`,
  `findInReading.searchesPDFs` (both default true).
- Known quirk: snippets show the *normalised* (lower-case) text.

### 5.2 Read Aloud

**Scroll mode** (`EPUBReaderScreen.faithfulTypeControls`):

1. **If the chapter has a media overlay**, play the book's own narration:
   - `MediaOverlay.clips(inUnpackedFolder:chapter:)` reads the OPF
     `media-overlay` attribute of the chapter's manifest item and finds
     its SMIL file.
   - For each `<par>`: `<text src="…#id">` and `<audio src clipBegin clipEnd>`.
     A `par` with no `#` is skipped; nested `<seq>` is flattened in
     document order.
   - Clock values accept `ms`, `min`, `h`, `s`, or `H:MM:SS.f` / `MM:SS.f`
     / a bare number.
   - `MediaOverlayPlayer` plays clip by clip. It seeks only if the player
     is more than 0.25 s away; checks every 50 ms; advances at `end`, or
     when playback stops if there is no end.
   - It marks the narrated element (`origamiOverlayMark`: highlight
     `rgba(255,196,0,0.35)`, scrolled into view if within 60 px of an
     edge, to one third of the way down).
2. **Otherwise**, the page splits itself into sentences
   (`origamiReadAloudUnits`):
   - Blocks: `h1–h6, p, li, blockquote, dd, dt, figcaption, td, th`.
     Nested counted blocks, hidden blocks and empty blocks are skipped.
   - Splitting uses `Intl.Segmenter(lang, {granularity:'sentence'})`, or
     the whole block when that is unavailable.
   - Start: the sentence containing the selection's anchor, else the
     first block whose bottom is below 0 (in view).
   - The native side speaks the sentences as `SpeechUnit`s with ids `s0…`.
     The spoken one is marked with `origamiReadAloudMark(i)`.
3. **Carrying on across chapters**: `readingOn` stays true. When speech
   ends, the reader advances a chapter and starts again after 1.2 s.
   Changing chapter by hand stops reading.
4. **Progress readout**: "NN% · M min left". It is weighted by each
   chapter's word count, at 238 words per minute. It shortens to "NN%",
   then hides, in a narrow window.

**Native modes** (`ReadAloudController.makeUnits`):
- A selection becomes one unit. Otherwise each heading and each
  paragraph of the current page (Horizontal, Focus) or of the whole
  document becomes a unit. Empty paragraphs and `---` are skipped.
- The paragraph being read is tinted 0.10 accent.

**Engines** (`SpeechEngine` protocol: `prepare`,
`speak(units, options) → stream of events`, `pause`, `resume`, `stop`;
events `loading`, `started(unit)`, `wordRange`, `finished`, `ended`,
`failed`):

- **`AppleSpeechEngine`**
  - Splits each unit into sentences with the system sentence tokenizer.
  - Rate = system default × `readAloud.rate`.
  - 0.25 s pause after headings.
  - Voice from `readAloud.voiceID`, or the system default.
- **`Qwen3SpeechEngine`** (arm64 with at least 16 GiB of RAM; selected with `readAloud.engine = qwen3`)
  - A local neural model; speaker `readAloud.qwen3.speaker` (default "Ryan").
  - Rate is ignored. Pause stops: there is no real resume.
  - Any failure falls back to the Apple voice and shows the banner
    "Neural voice unavailable — using Apple voice".
- **`VoiceInstaller`** downloads the model:
  - From Hugging Face (`https://huggingface.co/api/models/<repo>/tree/main?recursive=true`
    for the file list, `…/resolve/main/<path>` for each file).
  - Repos `aufklarer/Qwen3-TTS-12Hz-0.6B-CustomVoice-MLX-bf16` and
    `Qwen/Qwen3-TTS-Tokenizer-12Hz`.
  - Needs 4 GB free. Checks SHA-256 against the LFS ids. Downloads into a
    `.partial-<UUID>` folder, then moves it into place.

### 5.3 Selection dot and context panel

The selection dot, its menu, and the context panel with its rings and
Claim Check are planned in [CONTEXT-PANEL-PLAN.md](../CONTEXT-PANEL-PLAN.md).
What is built:

**When the dot appears**
- After a selection in Scroll, or in Horizontal. **No other native mode
  reports selections**: `OrigamiReadingView.reportSelection` only acts
  in Horizontal.
- Not when `selectionContextStyle = system`.

**The dot**
- An 18 pt chrome sphere, placed at the mouse-release point + (12, 16).
- 30 × 30 hit area. Scales 1.15 on hover.
- It follows the words as the page scrolls (`selectionMoved`).
- Code: `SelectionDot` and `SelectionDotLayer`
  (`OrigamiReading.swift`, `SelectionContext.swift`).

**The menu** (opens on hover or click, top-left at dot + (18, −8)), in order:
1. An optional one-line quick answer (at most 90 characters)
2. **Show All** — the find-fold for the words
3. **Annotate ▸** the kinds, then Comment…
4. **Copy as Citation**
5. **Context**

**The panel** (`SelectionContextPanel`)
- 380 wide, at most 420 tall, draggable. First placed at the point
  + (260, 170).
- Results are debounced by 250 ms.
- The selection is classified (`ContextQuery.make`, first match wins):
  citation → identifier (DOI / URL / arXiv / ISBN) → figure or table →
  known name → number → symbol → term → claim → passage.
- Sections:
  - **This paper:** uses, first and last use, definition, citation line,
    caption.
  - **Your notes**
  - **Standing:** retraction marks, for citations
  - **Cited Here**
  - **In your library:** up to 6 hits
  - **Online**, only while the panel is open, after 400 ms, 12 s timeout:
    - Wikipedia REST summary, else a search — for terms and names
    - OpenAlex `works?search=` or `works/doi:` — for terms, claims,
      passages, identifiers, citations
    - Semantic Scholar `snippet/search` — for claims, passages, terms
  - Each source has a switch: `contextLocalOnly`,
    `contextOnlineWikipedia`, `contextOnlineOpenAlex`,
    `contextOnlineSemanticScholar`.
  - **Explain in Context** and **Check This Claim** (AI, through the
    reader's chosen model). Every quotation in the answer must be found
    word for word in the material, or that sentence or verdict is dropped.
- **Keep** writes the panel's offline findings as a comment on the
  selection.

### 5.4 Context actions and paragraph menus

There are three action systems; keep them apart.

1. **`ContextActions.swift`** — `ContextActionBuilder`
   - Hard-coded actions per target: `selection`, `person`, `address`,
     `paragraph`, `document`.
   - Selection actions: Copy to Cite, Lift, Find ▸ Find in Document /
     Find Online (`https://www.google.com/search?q=`).
   - Used by the native text views' menus (`ReaderTextView`).
2. **`OrigamiContextAction`** (key `origamiContextActions`, a
   comma-separated list)
   - The native paragraph menu's entries: Copy Text, Copy as Citation
     (+ Copy Link to Paragraph), Copy View Specification, Highlight ▸,
     Comment (Note Here… / Open Note… / Remove Comment), Concepts Here,
     Show References, and Provenance (not in the default list).
   - With a selection, these follow: Copy to Cite, Look Up, Translate,
     Lift, Highlight ▸, Flow, AI ▸.
   - Code: `OrigamiReadingView.menuEntries`, `selectionEntries`.
3. **`AIPromptPreset`** (key `readingAIPrompts`, a JSON array of
   `{id, name, prompt}`)
   - Default: "Simplify Text".
   - The result replaces the selection in place, while everything else is
     greyed (`SelectionViewMode`).

### 5.5 Overview

Opened by Outline ▸ Overview, ⌘−, or pinch in (`OverviewReadingScreen.swift`).

**Layout:** a page at most 820 wide with the title "Overview". For each
section, indented 22 pt per level:

1. **Heading** (clicking it returns to the reading there)
2. **Picture strip:** up to 10 pictures at 30 pt; circles for people,
   rounded squares for the rest
3. **Names line:** people *italic*, places **bold**, organisations
   ***bold italic***, concepts plain — no colours
4. **Marked** `==…==` lines
5. **Bold** `**…**` lines
6. **The reader's highlights** (yellow 0.35) **and comments** (italic)
7. **Citations** (off by default)

Settings keys `overviewShow*` and `overviewLighterHeadings`.

**Names** (`OverviewEntities.find`)
- Found on the device with a named-entity tagger (person, place,
  organisation, names joined), plus the book's defined concepts.
- Rules: at least 3 characters, starting with a capital; a person needs
  at least 2 words; a small list of interjections is ignored.
- With at least 4 sections, a name found in more than half of them is
  dropped.

**Pictures** (`OverviewPictureStore`)
1. People the user's People directory knows use their own portrait and
   are never looked up.
2. Everything else is looked up on Wikipedia:
   `w/api.php?action=query&generator=search&gsrlimit=6&prop=pageimages|description|pageprops&piprop=thumbnail&pithumbsize=120&ppprop=disambiguation`.
3. Matching rules reject disambiguation pages and works (novel, film,
   album, …), and a title qualifier must match words in the document.
   For a person, the surname must match exactly.
4. "Find Alternatives" also searches Wikimedia Commons.
5. Images are framed square and stored as PNG in the App Group folder
   shared with Author (`9Q5N4A727S.com.liquid.author.shared`).
6. "Nothing found" is retried after 30 days; failed requests are retried
   with backoff, at most 4 tries.
7. Only names leave the machine, never text.

The Manage Pictures window is `OverviewPicturesWindow.swift`.

### 5.6 Parallel reading

`ParallelReading.swift` and `ParallelReadingView.swift` (Go ▸ Read in
Parallel). This works on **library documents** shown in the main
document view. It does not belong to the EPUB reader screen.

**Candidates:** documents linked from or to the current one.

**Connections**
- The target paragraph is the link's fragment.
- The source paragraph is the first paragraph whose text contains the
  target's id; otherwise the document header.

**Layout**
- Two columns. **Each scrolls on its own; scrolling is not synchronised.**
- Cubic "beams" join the connected paragraphs: control-point bend
  `max(30, dx × 0.4)`, stroke 2.5, colour opacity 0.5, 6 pt end dots.
- Connected paragraphs are tinted 10% with a 3 pt bar.
- Relation colours:

| Relation | Colour |
|---|---|
| cites | blue |
| responds-to | green |
| revises | orange |
| relates-to | purple |
| extends | teal |
| supports | mint |
| questions | yellow |
| summarizes | indigo |
| disagrees-with, retracts | red |
| anything else | grey |

### 5.7 Mathematics and equations

**Scroll mode.** MathML in the book renders natively in the web view.
Clicking `math[id]` opens the **Equations** sheet focused on that
equation.

**Equation index** (`OrigamiEPUBImporter.equationIndex`, `OrigamiMath.swift` `EquationIndex.build`):
- The Visual-Meta equations block when present (`@{visual-meta-equations-start}`
  … `-end}`, `@equation{eq-…, display, label, format, tex, tex-sha256, mathml-sha256, converter, href, section, heading}`).
- Otherwise a body scan of `<math id>`: TeX from
  `<annotation encoding="application/x-tex">` or `data-latex`.

**Equations sheet** (`EquationsSheet.swift`, at least 620 × 440). Each
row shows its label and heading, and the TeX in monospace — or the note
"No TeX travels with this equation; Copy MathML gives it exactly". Its
buttons:
- Copy LaTeX
- Copy MathML (the raw `<math>` element)
- Copy Link (titled "Equation <label>")
- Go

**Native modes.** `$$…$$` and inline `$…$` (Pandoc rules) are shown as
readable Unicode (`OrigamiMath.readableTeX`). A recursive-descent
LaTeX-to-MathML converter (`TeXMathML`) exists, for export. Any unknown
command makes it return nil rather than guess.

### 5.8 Citations, quotes and Copy to Cite

**Citation click (Scroll).** `citationScript` recognises any of these:
- `a.citation`
- `[data-citation-id]`
- `[data-citation-key]`
- `role~=doc-biblioref`
- `epub:type~=biblioref`

A figure's own image link is excluded. The screen
(`EPUBReaderScreen.faithfulReader` `onCitation`) then tries, in order:
1. If `ref` (`data-origami-ref`) names a book in the library — after
   splitting `#fragment` and dropping a `scheme:` prefix that has no dot
   before the colon — open that book at the fragment.
2. If the reference's BibTeX has `vm-id`, or a `url` of the form
   `origamitext://open/…`, that names a library book, open it
   (`AppModel.openCitedLibraryBook`).
3. Otherwise show the **citation card** (`CitationCardSheet`): the full
   import's reference pool, or, if the body will not parse, the
   Visual-Meta citation pool alone (`AppModel.citationCardDoc`). The card
   is described in WEB-READER-BRIEF §4.

**Quote links** (see the roadmap's on-disk schema):
- Every `origamitext://` anchor gets class `origami-quote` and a
  following `[]` control.
- Clicking `[]` asks for the source paragraph (`transclude`) and unfolds
  it in place in italics. A second click folds it.
- Profile 1.0 books carry their quote links in Visual-Meta `links[]`.
  `origamiApplyQuoteLinks` wraps the quoted words in the linking element
  with an anchor, or adds " ↗" at the element's end when the words are
  not found.

**Cited here.** For each passage that other library documents cite, a
right-floated "❝ N" mark at 0.55 opacity. Clicking it lists the citers.

**Copy to Cite** (`EPUBReaderScreen.copyAsQuote`, `CitationClipboard.write` in `ReaderQuote.swift`)
- It builds an `OrigamiCitation` with:
  - `to` = `record.id`, `rel` = "cites", the quoted text
  - author and year (the first 4 characters of `dateISO`)
  - a BibTeX `@misc` (from `OrigamiReading.bibTeXEntry`) carrying
    `quote`, `printpage`, `vm-id` and the carrier `url`
  - the print page from the selection
- The clipboard gets four forms:
  1. `info.futuretextlab.origami-citation`: JSON of `OrigamiCitation`
     (Author reads this type by name; keep the string)
  2. the Liquid Author keyed-archive dictionary
     (`Content`, `BibTeX`, `Annotation`)
  3. HTML: `<a href="origamitext://open/<to>?q=…#frag">(Author, Year, p. N)</a>`
  4. plain text: the selected words exactly
- Carrier URL: `https://origamitext.app/o/<to>[?q=<quote>][#fragment]`.
  It carries identity only and is never fetched.
- With nothing selected, Copy to Cite cites the whole book
  (`AppModel.copyCitation(book:)`).
- **Copy Link to Paragraph** copies a link to the clicked block's stable
  id (`AppModel.copyParagraphLink`).

**Pasting a Reader "Copy Quote"** (`ReaderQuote.swift`):
- Recognised only when the text has curly-quoted words, then an
  attribution line `Author. 'Title'. p. N` and a Visual-Meta locator
  `(…-YYYY-MM-DDTHH_MM_SSZ)`.
- Builds an address and an `@article` record. Anything else pastes
  normally.

### 5.9 Notes, stretchtext and glossary on the page

**Note marks** (`endnoteScript`). A mark is `a.ot-inline-note`,
`role~=doc-noteref`, or `epub:type~=noteref`.

- **Closed:**
  - style `fold`: the mark reads `[]`;
  - any other style: the book's own printed mark is kept
    (in `data-ot-note-mark`).
- **Popup** (`notesOpenAsPopup`, never with `fold`):
  - the book's footnote `aside`s (`epub:type`/`role` footnote) are hidden;
  - a click opens a popup under the mark.
- **Inline:**
  - a click inserts the note's words after the mark: `[ words ]` for
    fold, or the printed mark followed by ` [words]`;
  - clicking the mark or the words folds it back.
- **Where the note text comes from** (`AppModel.endnoteText`):
  - the element with that id in any chapter;
  - else an element whose id ends in `-<id>` (re-exported chaptered books
    prefix their ids).

**Stretchtext** (`stretchtextScript`)
- The marker `a.ot-stretchtext` (`role=button`) controls the hidden
  `aside.ot-stretchtext-content` named by `aria-controls` or its `href`.
- A click or Space toggles it. The glyph becomes `‹‹` while open; the
  original marker text is restored on close. 0.18 s fade.
- In-page links and arriving fragments unfold a containing region first.
- If the book has no `origami.css`, fallback styling is injected
  (border-left 2 px, 1 em indent).
- Native modes: `StretchtextDisplay` (callout or inline) in the Aa menu.

**Glossary**
- In Scroll, terms are never links. **Show Definition** appears in the
  context menu when:
  - the selection sits inside a glossref link whose target has a
    definition (`AppModel.glossaryDefinition(target:)`, which reads the
    glossary entries of every chapter); or
  - the trimmed words (at most 100 characters, quotes and punctuation
    removed, lower-cased) match a concept name from Visual-Meta
    `concepts` or Author's `origami.json` `glossary`.
- Native `GlossaryDisplay` modes:
  - `hidden`
  - `bracketed` (the definition always shown)
  - `icon` (a `]` after the term; click to show the definition)
  - `tab` (Tab greys the text and marks the terms)

### 5.10 Figures, images and 3D models

- **Double-click any figure**, or click a jump link to a figure: a figure
  window (`FigureWindowView`) fitted within 900 pt per side.
- **A link straight to an image file:** an in-page lightbox (§4.1).
- **A figure whose image is wrapped in a link:** the link opens outside
  the app (Interatlas, or the browser).
- **3D models (native modes):** the bundled `model-viewer.min.js` is
  copied into the book folder, and a stage page
  `<model-viewer src=… camera-controls interaction-prompt="none">` is
  written and loaded into a separate local web view, 460 pt tall.
  Double-click opens a system Quick Look sheet for USDZ. If the stage
  cannot be built, the poster image is shown.

### 5.11 Book Information and notices

**Book Information** (`BookInformation.swift`), read from the OPF:

- **About:**
  - title, authors, publisher, date, language, identifier, rights
  - alternate forms of the title, subtitle and author names from
    Visual-Meta (translation, transliteration, display form)
- **Accessibility:** statements in the order of the W3C display guide 2.0:
  - visual adjustments
  - nonvisual reading
  - prerecorded audio
  - conformance (WCAG level, certifier)
  - navigation
  - rich content
  - hazards
  - summary

  They are built from `schema:accessMode`, `accessModeSufficient`,
  `accessibilityFeature`, `accessibilityHazard` and
  `accessibilitySummary`, `dcterms:conformsTo` and `a11y:certifiedBy`.
  With nothing declared: "The publisher provided no accessibility
  information for this book."

**BookNotices** (shelf books only), a strip above the page:
- **Unreadable chapters:** "N chapters could not be laid out for the
  reading styles; Scrolling shows the whole book."
- **Newer profile** (§16.2)
- **Untrusted records** (§17.1)
- **Colophon disagreement** (§8.4.6)
- **Newer edition in the library**, with Open Newer Edition and Compare
  Side by Side
- **Notes from other editions**, each resolved here or not

**DRM** is refused at import, not shown as a notice. The import throws
`protected` for:
- `META-INF/license.lcpl` (Readium LCP)
- `sinf.xml` (FairPlay)
- `rights.xml` (Adobe)
- any `encryption.xml` algorithm other than font obfuscation

### 5.12 OPDS catalogues and books from links

**`AppModel.claimLink(url)`** decides, in order:
1. `origamitext:`
2. `gemini:`
3. `hm:`
4. a path ending `.epub`
5. a DOI
6. a Hypermedia gateway URL
7. an http(s) URL that looks like a download (a path segment like
   `download`, `attachment`, `file`, `get`, `epub`, …; a query `dl=1`,
   `download`, `export=download`; or any query value containing "epub").
   A HEAD request (8 s) confirms `application/epub+zip`, a `.epub`
   Content-Disposition, or a final URL ending `.epub`.
8. otherwise false — the browser takes it

**A DOI**
1. Open the library book with that DOI.
2. Else ask Crossref (`https://api.crossref.org/works/<doi>`, 15 s) for
   a link of type `application/epub+zip`.
3. Else fetch the `https://doi.org/<doi>` landing page (20 s, first 2 MB)
   and look for, in order:
   - `citation_epub_url`
   - `<link type=application/epub+zip>`
   - `<a type=application/epub+zip>`
   - any `href="….epub"`
4. Else open the DOI in the browser.

**Download** (`RemoteEPUB.swift` `fetch`)
- Dropbox links are rewritten to `dl=1`. Timeout 120 s; at most 200 MB.
- The file must start with `PK\x03\x04` and contain
  `META-INF/container.xml`.
- If an HTML page arrives instead, the first EPUB it advertises is
  followed (one hop only).
- The URL is remembered (`linkedEPUBFolders`), so the same link reopens
  the shelf copy.

**OPDS** (`OPDSCatalog.swift`)
- Project Gutenberg is built in (`https://www.gutenberg.org/ebooks.opds/`).
- Accepts OPDS 2 JSON first, then OPDS 1 Atom (parsed with regular
  expressions).
- Publications: EPUB links are those whose type contains "epub" (Atom
  also needs an acquisition rel, or no rel).
- Navigation and groups are supported. "More…" follows `rel=next`.
- **No search; no authentication.**
- Edition choice: an href with "epub3" first, then one without
  "noimages".

### 5.13 Chapters, contents, page list, Back and bookmarks

**Contents popover** (Scroll) (`OrigamiEPUBImporter.tocEntries`):
- **Go to page** — when the book has a page list
  (`OrigamiEPUBImporter.pageList`).
- **Chapter stepper** "‹ i / N ›" — for books with more than one chapter.
- **The contents themselves**, from the first of these that exists:
  1. the nav document's `epub:type="toc"` list, nesting kept;
  2. the headings, for a single-document book;
  3. one entry per chapter, titled by its first heading or `<title>`.

**Outline margin** (`ReaderOutlineMargin`)
- Author's design: headings at 16 pt (top level) or 13 pt, at 60% of
  the ink; the current heading bold.
- 12 pt step in per level; 36 pt inset on the side facing the text and
  16 pt on the outer side; rows 6 pt apart, plus 24 pt above each later
  top-level heading.
- Clicking a heading goes there.

**Annotation margin** (`ReaderAnnotationMargin`): an editable note on
the whole document, saved as you type.

**Back:** a capsule button appears after following a link inside the
book (⌘[).

### 5.14 Look Up, Translate and Hold Up a Page

- **Look Up** uses the system dictionary popover; **Translate** uses the
  system translation popover (`ReaderLookup.swift`). Nothing is sent
  over the network by the app itself.
- **Hold Up a Page** (`PageCamera.swift`)
  - OCR of a printed page held up to the webcam, every 800 ms.
    Requirements: at least 10 words and mean confidence ≥ 0.45.
  - Matching against the library uses shingles: 4-word runs taken every
    2 words. Score = the number of runs found in a document, + 5 if its
    title appears on the page. The winner needs a score ≥ 3 and a lead
    of ≥ 2.
  - The document opens in Scroll at the matching paragraph.
  - Hand-drawn underlines of 3 or more words become highlights.

### 5.15 Reading functions (native modes)

- **Flow** (⇧⌘F / f) breaks text into lines at sentence ends:
  - also at commas when `flowBreakOnComma` (default true);
  - a blank line after each sentence when `flowDoubleBreakOnPeriod`;
  - abbreviations and initials do not break.

  Code: `ReadingAI.flowLines`, `OrigamiReading.flowText`.
- **Bionic Reading:** bolds the first `ceil(len/2)` characters of each
  word of 2 or more characters.
- **Reading Ruler:** a band at accent 0.12, `lineSpacing + 28` tall,
  following the pointer.
- **Paragraphs (p):** the AI splits paragraphs over 350 characters
  (with at least 6 flow lines) at changes of meaning.
- **Key sentences (b):** the AI picks one sentence per paragraph (at
  least 3 flow lines), coloured.

  Both go through `ReadingAI` → the reader's chosen model
  (`OrigamiLLM`), and are cached per paragraph id. A refusal turns the
  feature off with a notice.
- **Text colouring:**
  - `grammar`: parts of speech
  - `meaning`: named entities, dates and quantities
  - `argument`: cue phrases
  - `keyStatement`: the AI-chosen sentence

  Code: `TextColoring.swift`.
- **Paragraph Numbers** (View menu): each body paragraph numbered
  through the document, in the left margin (x −44). Clicking a number
  copies its link.
- **Scroll mode** shows a notice and refuses these functions, because
  they need the parsed document.

---

## 6. Themes and typography

A theme sets **only background and text colours**. Links, headings and
front-matter blocks inherit the text colour.

**CSS a theme emits** (`ReaderTheme.css`):

```
:root { color-scheme: light dark; }
html, body { background-color: <bgLight>; color: <textLight>; }
@media (prefers-color-scheme: dark) {
  html, body { background-color: <bgDark>; color: <textDark>; }
}
```

An untouched High Contrast theme emits only
`:root { color-scheme: light; }`, which leaves the system colours.

| Raw value | Name | Light bg | Light text | Dark bg | Dark text |
|---|---|---|---|---|---|
| `highContrast` (default) | High Contrast | system | system | system | system |
| `sepia` | Sepia | #eee2cc | #32281d | #393329 | #ede3d3 |
| `grey` | Grey | #dddddd | #272727 | #3f3f3f | #dddddd |
| `gentle` | Gentle | #ffffff | #666666 | #353534 | #aeaeae |
| `lowContrast` | Low Contrast | #dcdddc | #585958 | #222221 | #7b7a79 |
| `warm` | Warm | #f5ecdc | #494742 | #3d3633 | #f9f9f8 |
| `warmStrong` | Warm Strong | #c3ad9b | #26231f | #26201e | #ffffff |
| `cool` | Cool | #d8e1ea | #575a5d | #2b3e4f | #b1bbc0 |
| `coolStrong` | Cool Strong | #b7c4cf | #37536b | #2c3840 | #b1b9be |
| `cream` | Cream | #fffdd0 | #1a1a2e | #1a1a0a | #fffdd0 |
| `softPeach` | Soft Peach | #ffe4c4 | #2c1810 | #2c1810 | #ffe4c4 |
| `irlenYellow` | Yellow Tint | #fffff0 | #1a1a1a | #1a1a00 | #fffff0 |
| `irlenGreen` | Green Tint | #d8f5d8 | #0d2d0d | #0d2d0d | #d8f5d8 |
| `irlenPurple` | Purple Tint | #e8d9f0 | #1f0d2d | #1f0d2d | #e8d9f0 |
| `macular` | Black on Yellow | #ffff00 | #000000 | #333300 | #ffff00 |
| `night` | Night | #faf5e4 | #2d1a0d | #1a1209 | #d4b896 |
| `solarized` | Solarized | #fdf6e3 | #657b83 | #002b36 | #839496 |

**Overrides** (`ThemeColorOverrides`, `ReaderTheme.swift`)
- Stored in UserDefaults `ThemeColorOverrides` as
  `{"<theme>.background"|"<theme>.text": {"light"|"dark": "#hex"}}`.
- Every write bumps `themeColorOverridesTick`, which every reader
  observes to repaint live.
- An edited High Contrast theme falls back to #ffffff / #000000 /
  #1e1e1e / #ffffff for the values not overridden.

**Typography**

| Setting | Values | Applies to |
|---|---|---|
| Body family | Any installed family; default Times New Roman (fallback `'Times New Roman', Times, serif`) | All modes |
| Heading family | Any installed family; default Georgia (fallback `Georgia, serif`) | All modes |
| Size | `readingFontDelta`, −6…18, default +3, on an 18-point base (§4.2) | All modes (disabled under Publisher's Styles) |
| Spacing | `readingLineSpacing`, 0…18 (Scroll) or 0…24 (native), default 3 | All modes |
| Width | Scroll: Wide 46 / Medium 38 / Narrow 32 em. Native: 380…1200 pt windowed; 25…100% of the display in full screen | Per mode family |
| Justify / Hyphenate / Publisher's Styles | Booleans | Scroll |
| Notes | Superscript / Bracketed / Dagger / Fold, plus popup on or off | Both |

**Libertinus fonts.** The bundled `Libertinus*.woff2` files are used
**only when exporting** ACM-style EPUBs (`OrigamiEPUB.swift`
`embeddedFonts`). The reader neither registers them nor injects them.
An Origami EPUB that embeds them shows them through its own `@font-face`
only under Publisher's Styles; otherwise the reader's chosen family wins.

---

## 7. Platform notes and portable equivalents

| Apple piece | What it does here | Portable equivalent |
|---|---|---|
| `WKWebView`, `loadFileURL(_:allowingReadAccessTo:)` | Renders the chapters from disk, with read access limited to the book | Browser: serve the unpacked folder from a scoped origin (a service worker or a blob/virtual file system). Electron: `BrowserWindow` with a custom `protocol.handle` restricted to the book. Windows: WebView2 `SetVirtualHostNameToFolderMapping`. Android: `WebViewAssetLoader`. |
| `WKUserScript` at document start / end | Script injection | Electron preload plus `executeJavaScript` on `dom-ready`; WebView2 `AddScriptToExecuteOnDocumentCreatedAsync`; Android `evaluateJavascript` in `onPageFinished`; in a browser reader, use an iframe and inject into `contentDocument`. Keep the two-pass theme rule. |
| `WKScriptMessageHandler` (`messageHandlers.origami`) | Page-to-native bridge | `window.postMessage` / `ipcRenderer` / `chrome.webview.postMessage` / `@JavascriptInterface`. Keep the `{event, …}` payloads in §4.4 unchanged. |
| `decidePolicyFor` with `allowsContentJavaScript` per page | Navigation rules and scripted-page gating | Electron `will-navigate` plus a CSP per page; an iframe `sandbox` without `allow-scripts` for unscripted pages. |
| CSS Custom Highlight API | Painting annotations without changing the DOM | Chromium 105+, Safari 17.2+, Firefox 140+. Fallback: wrap ranges in `<mark>` elements, accepting DOM changes. |
| `WKWebView.find` | In-page find | `window.find()`, Electron `findInPage`, or your own text-walker with highlight ranges |
| `NSMenu`, `willOpenMenu` | Owning the context menu | Handle `contextmenu` in the page and draw your own menu |
| `NSEvent` monitors (magnify, scroll, key) | Pinch, swipe, keys | Pointer events / `gesturechange` / `wheel` with `ctrlKey` (pinch on trackpads) |
| SwiftUI native layout (`OrigamiReadingView`) | Native modes | Any UI toolkit, or simply a second HTML rendering of the `LiquidDoc` |
| `AVSpeechSynthesizer` | Voice | Web Speech API `speechSynthesis`; Windows `SpeechSynthesizer`; Android `TextToSpeech`; Linux speech-dispatcher or Piper |
| `NLTokenizer(.sentence)` | Sentence splitting | `Intl.Segmenter` (already used on the page) or ICU `BreakIterator` |
| `NLTagger(.nameType / .lexicalClass)` | Overview names, text colouring | compromise.js, spaCy, wink-nlp |
| `AVAudioPlayer` | Media-overlay playback | An HTML `<audio>` element with `currentTime` and `timeupdate` |
| Vision OCR, AVCapture | Hold Up a Page | `getUserMedia` plus Tesseract.js |
| PDFKit `findString` | PDF search | pdf.js text layer |
| `NSFileCoordinator` | Safe reads of synced files | Atomic write-then-rename plus retry on read |
| UserDefaults / `@AppStorage` | Settings, positions, bookmarks | `localStorage` / IndexedDB / a JSON settings file |
| App Group container | Picture cache shared with Author | A shared folder path agreed between apps |
| FoundationModels and `OrigamiLLM` | AI functions | Any local model API (for example Ollama's HTTP API). Keep refusals visible: never swallow them. |
| System dictionary and translation popovers | Look Up, Translate | A dictionary API or a link out; a browser translate API |

**Comparisons with existing EPUB engines**
- **epub.js** paginates with CSS columns inside an iframe. Origami Text
  does not paginate the book's own pages at all: "Scroll" is one long
  column per chapter, and pagination happens only in the native
  Horizontal mode, by semantic section.
- **Readium** (Navigator / ReadiumCSS) offers comparable user settings
  and injection. ReadiumCSS's "user settings" layer is close to
  `ReaderStyle.css`. A rebuild could use Readium for the faithful view,
  provided it can add the bridge scripts and the CSS-after-book rule.

---

## 8. The shared OrigamiFormat package

`~/Documents/OrigamiFormat` (Swift package) contains `EPUBImport`,
`EPUBReadingStyle`, `EPUBReadingTheme` (with `EPUBReadingLayout` and
`EPUBReadingFont`), `EPUBPackage`, `DocumentIdentity`,
`AnnotationAnchor`, `AnnotationStore`, `WebAnnotation`, `OrigamiPalette`
and `DOI`.

**Origami Text does not import it yet.** No app file has
`import OrigamiFormat`. A pending migration is in
`OrigamiFormat-migration/`. Origami Text's own copies differ in concept:

- **Themes.** The package's 16 palettes have the same hex values. But:
  - its `system` theme draws its own colours (#fbfaf8 / #16171a,
    #1c1d1f / #e8e6e3), where Origami Text's `highContrast` leaves the
    system colours;
  - its names differ (System, Irlen Yellow/Green/Purple, Macular);
  - it has no user overrides;
  - it detects dark paper by luminance (< 0.45), where Origami Text
    follows `prefers-color-scheme`.
- **Fonts.** The package offers abstract stacks (book, system, serif,
  sans-serif, rounded, monospaced). Origami Text offers any installed
  family by name.
- **Reading CSS.** The package's `EPUBReadingStyle.css`:
  - sizes the body in px (17 × scale) with line spacing 1.6;
  - colours links and headings with the ink;
  - clears the book's own backgrounds on dark paper;
  - supports a **Columns** layout (section columns) and paging scripts.

  Origami Text uses a percentage of an 18-point base, `color: inherit`
  links, and has no Columns or paged mode for the book's own pages.
- **Scripts.** The package carries its own page scripts (dark ink, code
  highlighting, a maths `[data-latex]` gatherer, find, position,
  highlight, section columns, paging). How they map onto
  `EPUBReaderView.swift`'s scripts is unclear from source.

---

## 9. Rebuild order and acceptance checks

### 9.1 Order

1. **Unpack and shelf.**
   - Zip reading, safe paths (refuse `..`), the DRM refusal, font
     de-obfuscation.
   - The `folder` derivation, `library.json`, the canonical `.epub` copy.
   - Reuse based on modification time; the re-export and duplicate gates.
2. **Spine and contents**: `container.xml` → OPF → spine, nav, TOC
   fallback, page list.
3. **Faithful view**:
   - load one chapter with read access limited to the book;
   - the navigation rules (§4.1);
   - `ReaderStyle.css` and the two-pass theme injection;
   - the chapter footer and chapter stepping.
4. **The bridge**: `progress` and `origamiScrollToFraction`; then
   `selection`, with the anchor ladder; then `citation`, `activate`,
   `currentHeading`.
5. **Annotation painting** with highlight ranges (§4.5), the context
   menu (§4.6), and sidecars keyed as in §3.
6. **Notes, stretchtext, glossary and quote links** (§5.9, §5.8).
7. **Structured import** to the document model, in the background, with
   caching and remembered failures.
8. **Native modes**: Horizontal pagination, Focus and its sub-modes,
   Transcript, folding, find-fold, the foot bar.
9. **Find** (page, all chapters, native), **Read Aloud** (page sentences
   first, then media overlays), bookmarks, the Back stack, the progress
   readout.
10. **Selection dot and panel**, then Overview, Book Information,
    notices, Equations, OPDS and link claiming, and the optional extras
    (neural voice, page camera, parallel reading).

### 9.2 Acceptance checks

Each check can be tested by hand or automatically.

1. **Re-opening is cheap.** Opening the same `.epub` twice creates one
   record and one folder. A file with the same `dc:identifier` under a
   new name replaces the old text but keeps the old `id` and folder.
   Annotations survive.
2. **A different file of the same book is refused.** Same DOI, or same
   title and first author: the note reads "Already in the library as
   "…" — skipped …".
3. **DRM is refused before anything is written.** A book with
   `META-INF/license.lcpl` fails with the "copy-protected" message.
4. **The theme wins.** With the Sepia theme, a book whose stylesheet
   sets `body { background: white }` still shows #eee2cc. The
   `<style id="origami-theme">` element is the last child of `<head>`.
5. **The page cannot escape.** A link to `file:///etc/hosts`, or a
   top-level `data:` URL, does nothing. A chapter not listed as
   `scripted` cannot run its own `<script>`, but the reader's scripts
   still work.
6. **Links go to the right place.** A clicked `https://` link opens the
   system browser. `mailto:` opens the mail client. A link to another
   chapter changes chapter, and Back returns to the previous fraction.
7. **Fragments land.** Following `origamitext://open/<id>#p3` opens the
   book at element `p3`, centred (or at the top for a heading),
   flashes it yellow for about 1.6 s, and corrects itself after 350 ms.
   A target inside a closed stretchtext is unfolded first.
8. **Position is restored only when asked.** With `reopenWhereLeftOff`
   off, a book opens at the top. With it on, it returns to the saved
   chapter and fraction (±1%). A newer position from another device
   wins.
9. **Selections carry their anchor.** Selecting words inside
   `<p id="x">` posts `fragment = "x"`, a prefix and suffix of up to 32
   characters each, and the page number when page-break markers exist.
10. **Highlights survive and degrade.** A highlight paints in the kind's
    colour as coloured type, not a background. After the words are
    edited away, the whole element is inked — except for a comment on
    a heading, which becomes a slip.
11. **Citations open their target.** Clicking `[3]` on an Author-made
    EPUB (`href="#bib-key"`, no data attributes) opens the card for
    `key` and does not scroll to References. A citation naming a
    library book opens that book.
12. **Notes follow the note style.** Superscript plus popup: the note
    opens in a popup and the footnote asides are hidden. Fold: the mark
    reads `[]` and opens in place as `[ words ]`. Changing the style
    re-marks the open page without reloading.
13. **Horizontal paginates as specified.** At 1400 pt wide: 3 pages. At
    700 pt: 2. A 900-word section spans 3 pages; a lone heading shares
    its page with the next section.
14. **Folding works by level.** On a document with h1/h2/h3: level 1
    shows headings, first sentences and `==Marked==` sentences; level 2
    shows headings only; level 3 drops h3; ⌘+ unfolds.
15. **All Chapters is capped.** A search for a common word stops at 300
    hits with the title "The first 300 matches". Clicking a hit in
    another chapter loads it and finds there.
16. **Read Aloud starts in the right place.** In Scroll, it begins at the
    first sentence in view (or the selected one), marks each sentence,
    and carries on into the next chapter. A chapter with a SMIL overlay
    plays its audio instead.
17. **Copy to Cite fills the clipboard.** It holds the four forms of
    §5.8; the plain text equals the selected words exactly; the HTML
    link is `origamitext://open/<record.id>?q=…`.
18. **Faint greys become readable.** Under the Night theme (dark), a
    grey author line with contrast under 3 is re-inked to the body
    colour; a red link keeps its colour.
19. **Look-only books leave nothing behind.** Opening a file from
    Downloads shows Import to Library. Closing the window leaves no
    record and deletes its temporary folder.
20. **A broken body still reads.** For a book whose content will not
    parse, Scroll still renders, the notice reports unreadable chapters,
    and native modes fall back to the web view.

---

## 10. Discrepancies found between docs and code

- **WEB-READER-BRIEF §2 "Links"** says citations are
  `<a class="origami-cite" href="#bib-…">`. The exporter
  (`OrigamiEPUB.swift` around line 2221) writes
  `class="citation" epub:type="biblioref" role="doc-biblioref" data-citation-id=…`,
  and the reader's `citationScript` does not look for `origami-cite`.
  (It still catches such anchors through role or epub:type when those
  are present.)
- **WEB-READER-BRIEF §3** says a figure jump shows a lightbox. On the
  Mac it opens a separate figure window. The lightbox is used only for
  plain links to image files.
- **Native reading progress.** `OrigamiReadingView` says the scroll
  offset is "saved a moment after every move and restored on return".
  `readingProgress.<doc.id>` is written but never read. It is also keyed
  by `doc.id` (the address), unlike the Scroll position, which is keyed
  by `folder`.
- **Memory note "per-book files keyed by record.folder, never
  record.id".** This holds for the **shared** community-folder files
  (`_annotations/<folder>.json`, `_reading-positions.json`, standing,
  map layout). **Local** sidecars — `Annotations/<id>.annotations.jsonld`
  and `Analyses/<id>.analyses.json` — and the UserDefaults pin and
  set-aside lists are keyed by `record.id`.
- **The 3D stage files** (`origami-model-viewer.js`,
  `origami-model-stage-*.html`) are written into the unpacked book
  folder. That contradicts "the book itself is never modified" for the
  cache, though not for the stored `.epub`.
- **Line-spacing limits differ**: 0…18 in the Scroll type panel, 0…24 in
  native modes, for the same stored value.
- **Selection dot coverage.** Only Scroll and Horizontal report
  selections. Focus, Transcript and folded views do not, despite the
  plan's "every reading" framing.
- **CONTEXT-PANEL-PLAN.md** header still says "nothing here is built",
  which its own Status section contradicts. The dot's menu is
  hand-built, not rendered from the shared `ContextActions` list as §2
  of the plan proposes. Hovering the dot opens only the menu, not the
  panel (the `SelectionContext.swift` header comment says otherwise).
- **ReadingSearch** comments say snippets are cut "at word boundaries";
  the code cuts at character counts, from normalised (lower-cased)
  text.
- **`AppModel.foldOpenReadingIntoOverview`'s comment** mentions "each
  section's first sentence". The Overview screen does not show first
  sentences (the level-1 fold does).
- **Mode names.** There is no "Paged" or "Columns" mode in Origami Text.
  The words are Scroll, Horizontal, Focus (Sentence / Paragraph / Word),
  Transcript, Outline (Outline / Overview / Citations), References and
  AI. "Full Width" survives only as the host of a standing fold.
  "Columns" exists only in the unadopted OrigamiFormat package.
- **Qwen3 voice.** Pause has no real resume (it stops). The controller
  sends pause and resume to the preferred engine even after falling back
  to the Apple voice.
