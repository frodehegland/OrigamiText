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
| `CF/origami-to-read.json` | `{items: [{name: folder, at?, quote?, marked}], modified}` | folder (converted from local ids on write) | `EPUBToRead` (coordinated read). iOS marks with a 1 s press behind a paragraph (`ToReadPress` in PhoneReadView.swift) or the selection card; opening lands at `at`, else at the paragraph whose text contains the first 40 characters of `quote`. |
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
| `readerLeftMarginMode` | `annotation` | Left margin: `nothing`, `outline` or `annotation`. An empty Annotation margin shows the grey prompt "Annotations for this document". |
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
| 4 | `toggleButtonScript(records:)` | end | Inserts a centred "Metadata" button before `#visual-meta`. It toggles `hidden` and `display`; the label becomes "Hide Metadata" while open. Opening it also appends the book's metadata in full (`metadataRecords(in:)`): the OPF's `<metadata>`, then `visual-meta.json`, `origami.json` and `references.bib` as written, each as a titled `<pre>` — the appendix itself only carries Visual-Meta as a hidden JSON `<script>`, which never renders. |
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
| 18 | `greyContrastScript` (not for fixed layout) | end | The book's paper and ink give way to the theme's. Walks `body *` in document order, skipping media (`img`, `svg`, `video`, `canvas`, `picture`, `iframe`, `object`, `embed`), anything inside `svg`/`math`, and the reader's own furniture (ids starting `origami`, classes starting `ot-` or `origami`). A neutral (channel spread ≤ 16) background with alpha ≥ 0.5 becomes `transparent !important` (`pre` gets `rgba(127,127,127,0.12)` instead); a coloured background is kept, and that element and its descendants keep their ink. Otherwise a neutral ink that is near-black (max channel ≤ 0x33), near-white (min channel ≥ 0xE0), or under WCAG contrast 3 against the body background gets `color: inherit !important`. Coloured inks, fonts, sizes and spacing are never touched. The walk is a function, `pass`, run at once; the first run also registers, once per page (`window.__origamiContrastWatch`), a `matchMedia('(prefers-color-scheme: dark)')` change listener that runs `pass` again two animation frames later. A system light/dark switch changes no theme setting, so the Swift side never re-injects, but a grey kept as readable on the light page must be judged again on the dark one. |

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

**Numbered citations in plain EPUBs (10 Oct 2026).** A publisher's EPUB carrying no Origami records has no reference pool, only a printed list. `NumberedReferences.infer(in:)` (end of `OrigamiEPUBImport.swift`) runs at the end of `importDocument` when `references` is still empty:
- **Section:** the *last* heading whose folded text (leading numbering stripped) is one of references, reference, reference list, bibliography, works cited, literature cited, literature, sources, cited works, references and notes, bibliographic references, citations. Entries are the non-heading paragraphs up to the next heading of the same or higher rank.
- **Entries:** `[n] …`, `n. …` or `n) …` gives the printed number. Publisher apparatus (©, Copyright, DOI:, ISBN, ACM ISBN, Permission to make…, Received/Accepted/Published) is dropped. When most entries print a number, unnumbered lines are dropped; otherwise entries are numbered by position. Needs ≥ 3 entries, at least half showing a year (1500–2099) or a DOI.
- **Fields:** a quoted title (IEEE, Chicago) splits authors/title; else ACM `Authors. Year. Title.`; else APA `Authors (Year). Title.`; else first sentence authors, second title. Authors "A, B, and C" become BibTeX `and`-lists when every part has a space; surname-first lists stay as printed. DOI and URL by pattern. Each becomes `@misc{refN, author, title, year, doi, url, note = whole entry}`, `citedAs "[n]"`, `number n`.
- **Body:** outside the list, `[[n](origami-jump:…bib|ref|cit…)]` first reads as `[n]`; `[n, locator]` (p., pp., ch., sec., §, fig., table, vol., no., para., l.) becomes `[cite:refN] (locator)`; a bracket group of only numbers, commas, semicolons and ranges (≤ 30 wide), not followed by `(`, becomes `[cite:refA] [cite:refB]…` when every number is in the list.
- **Scrolling view:** `citationScript` also answers a click inside a bracketed number when `window.origamiNumberedReferences` (set at document start from `AppModel.numberedReferenceCount(forBook:)`, which reads only cached imports) covers it: the caret's offset in its block's text is matched against the same bracket pattern, the number under the caret (else the group's first) posts `{event:'citation', key:'refN'}`, and the existing path opens the card.
- Verified on `Beyond_The_Page-Break.epub` (ACM, plain): 83 references (the five apparatus lines after the list excluded), 78 citations, `[83, Ch.2]` with its locator.

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

### 5.16 Bound volumes read as their articles (31 October 2026)

A volume bound from several works — a journal issue, proceedings, a collection such as The Future of Text — can be read whole or one article at a time.

**The data** (`BoundVolume` in `EPUBShelf.swift`, shared by every target). `BoundVolume.read(inUnpackedFolder:)` reads `document.binding` from the Visual-Meta record (found through `OrigamiEPUBImporter.recordData`, properties `origami:visual-meta`): each `works[]` entry becomes an `Article` (id, title, author names, `file` and `anchor` from its `href` resolved against the package document's directory, the concept and reference ids from `resources`, `abstract`, `keywords`), and each `matter[]` entry one too, with its href as id and no authors. Nil when the record has no works. The pieces are sorted by the spine position of their file (ties keep record order); a matter piece before the first work is `.front`, any other `.back`, whatever the record called it. `articleDocID(volume:article:)` is `volume + "#article=" + article`; `split(articleDocID:)` reverses it.

`document(for:in:)` cuts an article out of the volume's structured document: the paragraphs whose ids begin `file#` (importer ids are `file#elementID`), from the one whose id is `file#anchor` (else the file's first) up to, not including, the next piece's anchor in the same file. The copy takes the article's title, its byline as `author` (the volume's author when it has none), `authors`, `abstract`, `keywords`; the volume's title as `publication`; the volume's date, language, document type, journal, assets and tables; the volume's concepts filtered to the article's listed ones (all of them when it lists none) and its references filtered to the listed ones, or, when the binding lists none, to the ids of the `[cite:ID]` tokens in the article's own paragraphs. (Verified 31 October 2026 on The Future of Text Vol 1: the two agree for all 8 citing articles.)

**What each piece is** (31 October 2026). Each `Article` has a `Kind`: article, front, part, collection, back or appendix. The kind gives its `Zone`: opening, articles, or appendices ("Appendices & Records"). It may also have a `label` (FOREWORD, TIMELINE…), a `voices` count for collections, and `declared`. A `role` in the binding (works or matter), using EPUB structural-vocabulary words (`declaredKinds`), always wins; matter's bare front/back do not count as declared. Otherwise `BoundVolume.classify` reads each piece in spine order, using its file's `PieceShape` (word count, heading texts, first six paragraphs, tags stripped without spaces). The rules, in order:
1. A title starting "appendix" is an appendix.
2. An unsigned piece of 15 words or fewer is a part.
3. An unsigned title equal to the volume title, the series name, or the series name followed by vol/|/volume is a title page (front, or back once closing has begun).
4. Opening words at the start of the title (`openingWords`) make it front (back once closing has begun).
5. Closing words (`closingWords`) make it back.
6. An unsigned title containing symposium, transcript or "proceedings of" is a record (back).
7. An unsigned piece whose first line is only names (`byline`: 2–14 capitalised words or connectors, every name at least two words) gets those authors and becomes an article.
8. An unsigned piece with 8 or more headings is a collection (voices = headings − 1).
9. Otherwise: back once closing has begun; front if unsigned before any article; article.

Closing begins at the first appendices-zone piece after an article. Verified on Future of Text Vols 1–6, as opening/articles/appendices: 8/169/4, 3/40/5, 3/51/7, 3/52/7, 6/46/8 and 5/29/3. The two unsigned Vol 4 articles (Wasilko, Bonfert) are recovered. `correcting(_:)` lays the reader's `[piece id: Kind]` over the result. On visionOS, `VisionModel.setKind(_:forDocID:)` writes `annotationsRoot/piece-kinds.json` (`[folder: [piece id: kind]]`), forgets the caches and bumps `volumeStamp`. The room reloads on `volumeStamp` and `shownZones`. In a volume's room the wall holds only articles-zone pieces; opening pieces stand in a column 1.6 pitches left of the wall, and appendices-zone pieces in one to its right, from the wall's top down (`sideItems`). Every non-article card wears `pieceLabel` in small capitals (PART, COLLECTION · n VOICES, FOREWORD…), and part cards have no byline. `standsOnWall` keeps Select All, Layout's Arrange and the Views to the wall's articles. The volume bar adds one word per zone (`shownZones` in UserDefaults `volumeShownZones`, all on by default) and **Ask**. Since 1 Nov 2026 the zone words stand without a "Show" label, as plain buttons: a zone standing reads in the primary colour, one put away in `.tertiary` grey. The forearm chips are also away (`EPUBMapView.armChipsWorn = false` filters every chip out; the menu still installs for its hand tracking). A selected card in a volume room adds **Kind** (a row of the six kinds, the current one bold) and **Similar**. On the Mac, `VolumeArticlesList` groups by zone in sections, with part titles as small headings and kind labels over the rows.

**The series assistant.** `SeriesIndex` (EPUBShelf.swift; Codable) holds one `Entry` per work of every shelved volume whose binding `series.id` matches. A volume with no series counts as its own series. Each entry has its article doc id, volume id, title and number, title, authors, kind, a gist (the abstract, else the first 70 words of its opening) and its concept names. The concepts that 15% or more of the series' articles share are removed. Each entry also has a vector of "title. " + its first 2,400 characters, made with LiquidKit's `BGEEmbedder` (bge-small, 384 dimensions, batches of 32; `#if canImport(KnowledgeIndex)`, reached through LiquidShared and bundled into every app) or, failing that, the mean of Apple `NLEmbedding` sentence vectors. Vectors are centred on the series mean and normalised again. `likeness` is 0.85 × cosine + 0.15 × concept Jaccard. `similar(to:)` gives the top matches; `search` lists articles named by title first, then the nearest to the question, which bge embeds with its retrieval prefix. The index is saved in Caches/SeriesIndex/<series>.json and reused while `signature` (sorted record id:works count) matches. Built in 3.5 s for 385 articles on a Mac; loaded again in 0.03 s. `VisionModel.prepareSeriesIndex()` runs when a volume's room stands. The `volume-assistant` window (`VisionVolumeAssistant`) lists "Like …" for the card chosen with Similar. A question takes the focus article, its 8 nearest and the 10 the question is most about (12 at most), as a numbered `briefing`, to `OrigamiLLM.respond`. The answer streams, cites [n], and is shown with the articles it names. Tapping one calls `openPiece`, which opens that volume's room if it isn't open and stands the article in front of the reader.

**visionOS.** The volume becomes a room: `VisionModel.openArticles(of:)` sets `openJournalVenue = "volume:" + record.id` (remembering the venue before in `venueBeforeArticles`), and `records(inVenue:)` answers `articleRecords(of:)` — one `EPUBRecord` per piece, id the article doc id, author the byline (the volume title for matter), folder the volume's, `contentSubpath` the piece's own file, publication the volume title. The Hallway builds its cards from these like any journal's. `document(_:)` answers the index's document, else the cut-out article (cached); `record(forDocID:)` likewise; every reader and Hallway lookup goes through them. An article's annotations file under its volume (`annotationAddress`, applied in `ReaderSelection`'s initialiser and the annotation reads), so notes show in both. Articles share their volume's folder, so they take no place from the shared layout, and floats are read once per sidecar. **Opening a bound volume opens its room** (31 October 2026): `openInRoom` (the shelf row, Open EPUB…, Files' Open In) and a volume card's double tap call `openArticles(of:)` instead of opening one long reading, so a volume's articles stand as a proceedings' papers do, each card raising its own citations on selection. The Library window's journal list adds every bound volume as a room after the journals (`volumeVenues`, by title; `venueTitle` names it; books icon; count of pieces). **The volume bar** (31 October 2026): while a volume's room stands, a single-instance window `volume-toolbar` (`VisionVolumeToolbar`, utility-panel placement, glass, 56 pt high, Author's Map Toolbar in kind) offers **Select All** (reads Deselect All when every article card is selected; `toggleSelect(.documents)`, which raises every selected article's citations) and **Layout**, a menu: *Arrange* (every `WatchLayoutOption`, acting on the selected cards or all when none is selected) and *Views* (`offeredWatchViews`, the whole wall). The bar posts `VisionModel.volumeBarRequest`; `EPUBMapView.performVolumeBarRequest` carries it out. `syncVolumeBar()` runs on every venue change: it publishes Layout's choices (`layoutArrangements`, `layoutViews`) and opens the window in a volume's room, dismissing it anywhere else. `reload()` keeps `allArticlesSelected` current. Every reading opened in the room (`EPUBMapView.openReading`) starts in **Horizontal** (`visionReaderMode = "horizontal"`), except a Transpoint reading, which keeps its flowing page; the foot bar changes it once open. Also: **Articles** on a selected card's verbs and on a shelf row's context menu (always present, disabled for a book with no binding); the row also shows "n articles". Inside the room every card's verbs offer **Whole Volume** (`openWholeVolume`: back to the earlier venue, the volume opened in the room). Binding and article caches are forgotten whenever the shelf's documents are rebuilt.

**macOS.** `OpenEPUB.article` marks a reading of one article: `openArticle(_:of:)` opens the volume, then replaces `openEPUB` with one whose `chapters` is only the article's file, `id` and `base` kept (so annotations and reading place stay the volume's), and sets `pendingReaderFragment` to the anchor when other pieces share the file. `readingID` (`id` plus `#article=…`) keys the reader's identity and its book-change task. `readingDoc(forBook:)` answers an article with its cut-out document. `openWholeVolume()` reopens the volume at the article's heading. The foot bar carries **Articles** for every EPUB (disabled when not bound; reading one it reads "Article n / count"), opening `VolumeArticlesList`: Whole Volume, previous and next work, a filter on title and authors, and every piece (matter in italic secondary). The library row's context menu has **Read Article ▸** listing every piece.

### 5.17 A series' hallway (1 November 2026)

Every volume of one series (binding `series.id`, e.g. The Future of Text Vols 1–6) can stand in one room. On visionOS the venue is `series:<seriesID>` (`VisionModel.seriesVenuePrefix`). It is listed first in the Library's journal list as "<series name> — n volumes" when two or more volumes of the series are on the shelf (`seriesVenues`), and a volume room's card offers **Whole Series**. `seriesVolumes(_:)` orders the volumes by series volume number, then date, then title. `records(inVenue:)` returns every volume's article records. `isVolumeRoom` (a volume or a series room) gates the volume bar, zones, Kind, Similar and Whole Volume (`openWholeVolume(from:)` takes the card's own volume). `roomPieceIndex()` merges the piece indexes of every member. `standMap` and `openPiece` stay in the series room when the article belongs to it.

**Layout** (`journalItems`, `EPUBMapView.swift`):
- Each volume is a plane: its articles form a wall with the usual columns and top, its opening pages stand to the left and its appendices to the right.
- The newest volume is nearest, at z −1.2. Each older one stands `seriesPlaneGap` (0.9 m) deeper, so the progression reads into depth.
- The plane owns the depth, as the year does in other rooms: X/Y keep where the hand left them.
- Cards read "author · Vol n · year".

**Metadata for the assistant.** `BoundVolume.read` now strips U+FFFC from titles (falling back to "Untitled") and gives a work whose id repeats an earlier work's (FoT Vol 3's Softspace pair) its href as id. `SeriesIndex.Entry` gains `year` and `keywords`. Where a work has no binding `keywords`, the six highest-scoring nouns are taken by TF‑IDF across the series, under these rules:
- A term must occur at least twice in the article and in at least 2 articles, but in no more than a fifth of them.
- Contributors' names are excluded.
- `nounCounts` uses NLTagger nouns and lemmas, and falls back to every non-common word when the device has no tagging model.

`briefing` sends "(Vol n, year) [keywords: …]" with each gist. Cards with no abstract wear the gist plus their keywords once the index arrives; its arrival bumps `volumeStamp`.

### 5.18 Build Article Metadata (macOS, 1 November 2026)

A bound volume's library-row menu has **Build Article Metadata…**. For any other book it is dimmed, never hidden. It opens the window `articleMetadata` (`ArticleEnrichmentView`, `ArticleEnrichment.swift`, macOS only), with the volume's whole series ticked. The window shows the bound volumes grouped by series, with per-volume coverage, a Review list (each value with its source), Build / Build Again, Stop, "Redo AI abstracts and keywords made by an earlier pass", and Show Record in Finder.

**The pass.** Each work's text is read straight from its content document: `BoundVolume.blocks(of:inUnpackedFolder:)` runs from the work's anchor to the next piece's anchor in the same file.

The abstract comes from the first source that has one:
1. the binding;
2. a printed Abstract (`printedAbstract(in:)`, within the first 16 blocks);
3. the volume's summaries page (`summaries(inUnpackedFolder:)`). This reads "Name - summary … Kw, Kw (Gen:AI)" paragraphs and matches them by author, then by title. It matches 43 of FoT Vol 5's 46 works;
4. `OrigamiLLM.respond` with `transformingContent: true`. The prompt sends title, byline, volume, year and the first 7000 characters, and asks for "Abstract: … / Keywords: …", parsed by `ArticleEnrichment.parse`.

Keywords come from the binding, else the summaries page, else the model. When no model answers they fall back to TF-IDF terms over the run (`distinctiveTerms`).

Model errors are logged (`ReadingAI.reason`) into the entry's `note`, never kept as an answer. Articles under 40 words get a note instead. An AI value is kept on later passes while the article's text hash is unchanged, unless Redo is on.

Defined Concepts are re-checked on every pass. Each live library concept, under its term or any alternative name, is matched as a whole word with `ConceptTerm.text(_:contains:)`.

**The store.** `ArticleMetadata` (`EPUBShelf.swift`, shared) holds `{format "origami-article-metadata", version 1, modified, volumes: {bookFolder: {workID: Entry}}}`. Each entry has title, abstract, abstractSource ("book", "summaries", "summaries · Gen:AI", "ai · <model>"), keywords, keywordsSource (likewise, or "terms"), concepts [{id, name}], textHash, made and note. It is written as `origami-article-metadata.json` beside the shelf (`epubsRoot`) and in the community folder, every 8 articles and at the end. The reads and writes are coordinated. Nothing is written into the EPUBs.

**The headset.** `adoptStanding` reads the file whenever its modification date changes. `VisionModel.boundVolume(for:)` applies `.enriched(with:)`, which supplies an abstract or keywords only where the binding has none, and the Defined Concepts always (`Article.definedConcepts`, `abstractSource`). A newer file forgets every cached binding, bumps `volumeStamp` and rebuilds the series index. Card faces show the abstract ("(AI)" when AI-made), its keywords and its Defined Concepts. `SeriesIndex` likeness uses the concepts. `briefing` adds "[keywords: …] [concepts: …]". The Mac's own `boundVolume(for:)` is not enriched, so the Binder never carries AI abstracts into a new binding.

### 5.19 Corpus relations: who cites what (1 November 2026)

This is the first part of CORPUS-RELATIONS-PLAN.md, and it holds facts only. A bound volume's row menu has **Build Corpus Relations…**. For an unbound book it is dimmed, never hidden. It opens the window `corpusRelations` (`CorpusRelationsView`, `CorpusRelationsBuild.swift`, macOS only).

**The window.**
- One row per series, or per lone volume, with Build / Build Again.
- The pass's findings, and Show Record in Finder.
- On the right, each corpus's most widely cited outside works.

**The pass.** `CorpusRelations.build(name:volumes:known:)` lives in `EPUBShelf.swift`, which is shared. It reads the volumes in series order. For each volume it reads `references.bib`, plus `visual-meta.json`'s `endnotes`, `citations` and `document.binding.works`.

An entry belongs to the first volume that holds its id. FoT's volumes each carry every endnote of the volume before (Vol 6 holds 830, and 789 of them are earlier volumes'), and Vol 3 repeats 125 of Vol 2's bibliography entries. A later volume claims an entry only if it traces the entry to an article and the first volume did not.

Within its volume, an entry is traced in this order:
1. by the binding's own lists of each work's references and notes (`attributedBy: "binding"`);
2. by the file it is placed in, when exactly one work stands in that file (`"anchor"`). For a bibliography entry the file comes from the `citations` href; for a note, from its `anchor`. A note left at the back says nothing;
3. otherwise it stands for the volume (`from: "volume:<folder>"`).

What becomes a work:
- **Bibliography entries.** One with no title, DOI or URL is a filed quotation and is skipped.
- **Endnotes that carry an address or a DOI.** The rest are asides. Note text has its HTML entities decoded.

Work keys are `doi:<doi>` (the first `10.…` anywhere in the doi or url field, since some records double "https://doi.org/"), else `url:<normalised address>`, else `title:<folded title>` when it is at least 12 characters.

A work is the corpus's own when its folded title equals a piece's title (`inCorpus: "piece:<key>"`), or when it names the series and a volume number in digits, roman numerals, "Vol N" or pipes (`volume:<folder>`, `volumeNumber(inTitle:series:)`). A piece citing itself, or a volume citing itself, is dropped. A piece cites a given work only once.

`known` is the Mac's master list (`origami-cited-works.json`), matched by DOI and then by title key. It supplies the year, venue, authors and DOI where the volume gave none, the registry's title for endnote-listed works, the world citation count (`live.citedBy`), and `retracted` (OpenAlex).

The pass also computes:
- **Shares sources** (bibliographic coupling): the top 8 per piece. Each shared work counts log(1 + pieces ÷ its citing pieces).
- **Canon**: the top 40 outside works with at least 2 citing pieces or volumes.

**The file.** `origami-corpus-relations.json` has this shape:

```
{ format: "origami-corpus-relations", version: 1, modified,
  publisher: {name, role},   // the first volume's binding compiler, "editor and publisher"
  licence: "CC-BY-4.0",   // Creative Commons Attribution 4.0, Frode's choice
  corpora: { seriesID: {
      name, volumes[],
      pieces { "folder#work": {folder, work, title, authors, volume} },
      works { key: {title, authors, year, venue, doi, url, listedAs, inCorpus,
                    citedByPieces, citedByVolumes, citedByWorld, retracted} },
      citations [ {from, to, attributedBy, entry} ],
      sharesSources { piece: [ {piece, shared, score} ] },
      canon [],
      findings []
  } } }
```

The Mac writes it beside the shelf and publishes it to the community folder. Reads and writes are coordinated, and the encoding is pretty-printed with sorted keys. It is published as the editor's optional metadata and is never written into the EPUBs.

FoT Vols 1–6 (1 Nov) give 1,156 citations of 1,085 works:
- 464 are traced to their article;
- 692 stand for their volume (275 of them are Vol 1's book-level bibliography);
- 3 cite the corpus itself.

The file is about 880 KB.

**The headset.**
- `adoptStanding` reads the file (`CorpusRelations.readShared`).
- `VisionModel.adoptCorpusRelations` indexes piece key → corpus and bumps `volumeStamp`.
- `corpusCitations(forDocID:)` returns an article's traced works, resolving the corpus's own pieces to their ids in the room.
- In `EPUBMapView.journalItems`, an article the record knows takes its citations from it, as `cited:<work key>` cards with title, up to 3 authors ("et al." beyond) and year. A cited corpus piece standing in the room connects to its own card.
- An article the record does not know keeps its own `doc.references`, as before.

### 5.20 A chosen paper's star menu (visionOS, 1 November 2026)

A chosen article card (not a ghost, not set aside) wears a star menu instead of the row of verbs under it (`paperStar(for:)` in `EPUBMapView`).

**Placement.** Its attachment anchor is `AnchorRule(anchor: (0.5, 0.5, 0.5), offset: (0, 0, -0.006))`: centred on the card, 6 mm behind its face. The card keeps its pinch, and the verbs stand clear of its edges.

**Size.** The view is laid out at twice size and drawn with `.scaleEffect(0.5)`, as the old verbs were. The card's gap is (card size × 1.2 chosen growth) × 1360 pt/m × 2, plus 28 × 20 pt.
- The card size comes from `cardSizes.base[id]`: the width and height in metres of the unchosen face. `cardEntity` writes it into a plain, unobserved box.
- The fallback is `nodeMaxWidth / crisp / 1000` × 0.07 m × `documentCardMagnify`.

**Layout, top to bottom:**
1. A hidden copy of the lower verbs, which keeps the star centred on the card whatever unfolds beneath it.
2. **Focus / Un-Focus.** This is the room's `focusMode`, kept in step with the wrist chip's title and active state.
3. **Open**, the double tap.
4. The relations, either side of the card's gap. Outward relations (Cites, Shares Sources, Similar) stand on the left; inward ones (Cited by, and the stances: Agrees, Contradicts, Extends…) on the right. Each column is 210 pt wide.
5. **Close** (the deselect tap) and **Hide** (deselect, then `toggleSetAside`).
6. The card's other verbs (`onePaperButtons`, now without Open): Abstract, Lift, Transpoint, Whole Volume, Whole Series, Kind. (The assistant's Similar list left the card: a card's results show only as lines to other cards.) With several papers chosen, Layout and its arrangements stand here too.

**The relations** (`starRelations(for:)`). Only relations reaching at least one standing card are offered. Each shows its count, and a small "AI" when a model inferred it.
- **Cites**: `item.citedIDs`. Tapping raises the citation cards if they are down (`raisedArticleIDs`), then draws its lines like any other relation. Selecting still raises them, as before.
- **Cited by**: articles whose `citedIDs` hold this one.
- **From the corpus record** (`VisionModel.corpusRelated(forDocID:)`): Shares Sources (fact), Similar (`Corpus.similar`, AI), and every stance type (`Corpus.stances`). Stances read both ways and leave out the editor's rejected ones.
- **Similar from the series index**: until the record holds Similar, `seriesIndex.similar(to:limit: 6)` stands in, marked AI.

Tapping a relation sets `relationShown {from, title, ids}`, and `conceptEdges` adds a line from the card to each of those cards (drawn by `conceptConnectionLines`). Nothing else in the room changes: **a card's results are shown only by connection — never in a panel, never by hiding** (Frode, 1 Nov 2026). A second tap, Close, Hide, or deselecting the card takes the lines away.

**Schema additions** (optional, absent until later passes):
- `Corpus.similar: [piece: [Neighbour]]`.
- `Corpus.stances: [Stance {from, to, type (CiTO), point, source, review}]`.
- `Stance.title` maps types to words: agreesWith/supports → Agrees; disagreesWith/disputes → Contradicts; extends; respondsTo → Responds to; questions.
- `isAI` is true when the source starts "llm" and the editor has not confirmed it.

### 5.21 Experimental layouts: Cluster (visionOS, 1 November 2026)

Layout's ladder on the right arm gains a fifth rung, **Experimental** (`LayoutFan.experimental`). Its fan holds `ExperimentalLayout` options (chip ids `map.arm.layout.experimental.<raw>`). With several papers chosen, the star menu's Layout list shows them too, in a row headed "Experimental". Like Align, Distribute and Sort, they act on the chosen papers, or on every standing paper when none is chosen (`watchLayoutTargets`).

**Cluster** (`runClusterLayout`) groups papers by what they are about, with no regard for the timeline.

**Meaning** (`clusterVectors`):
- The series index's entry vector where the room has one; otherwise `NLEmbedding.sentenceEmbedding(for: .english)` of the title plus the first 600 characters of the abstract.
- Vectors are made unit length. Only the most common dimension is kept, since vectors from two sources can't be compared.

**Groups** (`sphericalKMeans`, a nonisolated static):
- k = √(n/2) rounded, held between 2 and 10.
- Farthest-first deterministic seeds: the vector least like the mean, then each next the one least like any seed so far.
- Cosine assignment and re-normalised means, for up to 25 rounds.
- Each member keeps its cosine to its group's centre (`fit`).

**Placement:**
- Groups are sorted largest first. The largest stands straight ahead; the rest alternate right and left along an arc around the room origin (`spaceShift + documentsShift`), with 40 cm of air between groups.
- Radius = max(2.0 m, the groups' total width ÷ 2.6).
- Each group is a small wall of ceil(√m × 1.3) columns, centred at 1.45 m high. Its across runs along the arc's tangent.
- Each paper stands nearer the reader by (fit − the group's mean fit) × 0.6, held within ±10 cm.
- Cards are not turned; they face the room's front as everywhere else.

**Applying it** (`applyWatchPositions3D`):
- Writes x, y and z (x within ±5 m of the shift, y within 0.95…2.2).
- Snapshots positions for Undo, records the room's previous state in `watchUndoTimeFree`, frees the room, then calls `keepPlacements` and reloads.

**Free of the timeline:**
- `@AppStorage("mapTimeFreeVenues")` holds one venue per line.
- While a room is free, `journalItems` leaves every paper's z as placed instead of reclaiming its year or volume plane (articles and side columns alike). `articleYearZ` is emptied, so drags move in depth too.
- **Wall** gives the timeline back (`setTimeFree(false)`).
- **Undo View** restores the previous state with the places.
- The 2D arrangements leave the state as it is.

### 5.22 Keywords in the room (visionOS, 1 November 2026)

**Adding one.** The volume bar (`VisionVolumeToolbar`, a utility-panel window sized to its contents) leads with a **Keyword** text field: `text.badge.plus`, 220 pt wide. Its keyboard's microphone takes dictation. On submit it calls `VisionModel.addSpaceKeyword`:
- Trims whitespace and punctuation, so a spoken keyword loses dictation's full stop.
- Ignores a duplicate regardless of case.
- Stores into `spaceKeywords: [venue: [String]]`, persisted in UserDefaults under `"spaceKeywordsByVenue"`.

`roomKeywords` is the open venue's list, and the Hallway reloads on any change to it.

**The cards.** Each keyword stands as a `.concept` item with id `keyword:<lowercased>`.
- Seed: x = (index mod 5 − 2) × 0.28, y = 1.9 + 0.1 × (index ÷ 5), z = −0.85, plus `spaceShift`. After a drag it stands where it was left (`placed`).
- Byline: "Keyword · N papers".
- Select ▸ Concepts leaves keyword cards out.

**Matching** (`keywordMatches`): a case-insensitive whole-word regex (`\b…\b`) over each standing article's title and card abstract (which carries its keywords), then its document's paragraphs. Results are cached per keyword in `keywordMatchCache`, which is cleared, along with `keywordModes`, when the venue changes.

**A chosen keyword's verbs**, a row under the card at half scale, each lit while on (`keywordModes[id]`):
- **Lines**: `conceptEdges` adds an edge from the keyword to each match, drawn by `conceptConnectionLines`. Other concepts' edges no longer include keyword cards.
- **Only**: sets the room's concept Focus (`focusedConceptID` = the keyword, `focusedConceptArticleIDs` = its matches), so only the keyword and its papers stand.
- **Gather** (`gatherPapers`): the matches, most-cited first, go into a small wall of ceil(√n × 1.4) columns. It is centred under the card, 12 cm below it and 8 cm behind, at wall pitch, written with `applyWatchPositions3D`. The gathered papers are also selected, set directly rather than through the tap, so their citation walls do not all rise at once; Layout and the Shapes then act on them. That frees the room from the timeline; Shapes ▸ Hallway or Undo View sends the papers home.
- **Remove**: ends the keyword's mode and Focus, then calls `removeSpaceKeyword`.

The same verb again turns it off. Letting the card go ends Lines and Only. A Gather's moved papers stay where they are; **Shapes ▸ Hallway** sends them home (Wall no longer does — see 5.23).

### 5.23 Reading the corpus, and the room's Shapes (1 November 2026)

**The reading** (the Mac's Build Corpus Relations, after the citation facts; `CorpusRelationsBuilder.read(into:sources:)`):
- **Gathered per piece:** title, authors, keywords (the binding's plus `ArticleMetadata`'s), the whole text from `blocks`, and an embedding input. The input is the title, the abstract and the first 2000 characters of the body; qwen3-embedding:8b takes 1.3 s at 3000 characters and 7 s at 6000. The books' glossaries come from `visual-meta.json` `concepts`.
- **People** (`peopleMentioned`):
  - Names the corpus knows are matched whole and case-sensitively: the contributors, plus the authors of its cited works, two or more words long and at least 6 characters. A surname search screens out absent names before the full match.
  - Apple's `NLTagger` `.nameType` names are added. The simulator's tagger finds none; the Mac's may.
  - A piece's own authors aren't counted as its mentions.
  - Short forms fold into the full name; a shared surname with the same first initial joins the most used form.
  - Kept: names in 2+ pieces, at least two words. `isContributor` is set too.
- **Glossary** (`glossaryTerms`): one term per lower-cased name. Dropped:
  - everyday words (`everydayTerms`);
  - people (the contributors and the found names);
  - single lower-case words;
  - terms used by more than 30% of pieces.

  Acronyms match case-sensitively. Kept: terms in 2+ pieces.
- **Themes** (`keywordThemes`):
  - Keywords are normalised (`normalizedKeyword`): lower case, abbreviations spelled out (vr, xr, ar, ai, hci, llm…), a last word's plain plural dropped with exceptions.
  - With vectors, it is greedy leader clustering, most-used first, at cosine ≥ 0.85. 0.75 and 0.8 over-merge: "text" swallowed 92 pieces.
  - Kept: themes carried by 2+ pieces. Without the model, themes merge by spelling only.
- **Meaning** (`meaningMap`, only when `OrigamiLLM.hasEmbeddingModel()`): the pieces are embedded through `OrigamiLLM.embed` in batches of 8. Vectors are cached per model in Caches/CorpusVectors/<model>.json, keyed by the SHA-256 of the text, so a rebuild embeds only what changed. From the vectors:
  - each piece's 8 nearest by cosine (`Corpus.similar`);
  - spherical k-means groups, √(n/2) between 2 and 12. Each is named by the theme scoring highest by Σ 1/√(theme size) over its members, unused names first.
  - 3D coordinates from PCA through the Gram matrix (`principalCoordinates`, cblas/vDSP), each axis scaled to ±1.
- **On FoT (simulator trial, 1 Nov):**
  - keyword themes at 0.85: 254 themes, in 361 pieces;
  - glossary: 145 terms;
  - people: 91 (Engelbart 47, Nelson 43…);
  - embedding: 0.8 s a piece; a 74-piece sample made 6 sensible groups.

**Schema additions** (`Corpus`, all optional):
- `themes [Theme {id, label, keywords, pieces}]`;
- `terms [Term {name, definition, pieces}]`;
- `people [Person {name, pieces, mentions, isContributor}]`;
- `meaning Meaning {model, groups [{id, label, pieces}], coordinates {piece: [x, y, z]}}`;
- `similar`, now filled.

`CorpusRelations.sphericalKMeans` is the one copy; the Map's own was removed.

**Shapes** (visionOS): the volume bar has a **Shapes** menu right of Layout, listing every `RoomShape`. A Shape whose data the room's record lacks is dimmed, never hidden, and titled "… — Build Corpus Relations on the Mac"; a journal's room reads the same, its record built per journal (5.31). Hallway, Meaning, Authors, Images and Constellation always stand; Meaning and Constellation fall back on `NLEmbedding.sentenceEmbedding` where no series index or record knows the papers. The current Shape wears a checkmark. Each runs through `volumeBarRequest .shape(id)`, then `runShape`.
- **Hallway** (`RoomShape.timeline`; titled Timeline until 1 Nov 2026): the only Shape that orders by time. Every standing paper's `placed` is cleared and `setTimeFree(false)` is called, so each paper returns to its volume or year plane seat and the labels go. Undo View restores.
- **Meaning, Themes, Concepts, Authors, People Mentioned** (`shapeGroups`, then `coveringGroups`): greedy cover, up to 12 groups. Each takes the set reaching the most unplaced papers, so every paper stands in one group; a group needs 3 or more. The left-overs gather as "Elsewhere", "Other themes", "No shared concept", "Single contributions" or "Names no one".
  - Meaning uses the record's groups, else local k-means named by a member's first keyword.
  - Authors merge name forms by first and last name with accents folded ("Frode Alexander Hegland" = "Frode Hegland"), and are named by the commonest form.
- **Placement** (`placeGroups`):
  - Groups are sorted by size, the largest ahead, alternating along the arc (as 5.21's Cluster, which now runs Meaning).
  - The left-overs stand as a broad, low field behind the arc: radius + 1.4 m, 1.15 m high, ceil(√n × 2.2) columns.
  - Each group, and the field, has a **label card** (`shape:<shape>.<n>`, a `.concept` item, byline "N papers") 13 cm above its top row. Choosing a label draws a line to every member (`conceptEdges`); labels carry no verbs.
  - The Shape and its labels are stored per venue in `@AppStorage("mapShapesByVenue")` (JSON `{venue: {shape, labels}}`).
- **Constellation**: each paper is placed at x = c₀ × 2.2, y = 1.45 + c₁ × 0.5, z = −2.0 + c₂ × 1.2 (plus origin), from the record's meaning coordinates. Without them, PCA runs over the series index's vectors. Meaning group labels stand at their members' centroid, 18 cm up.

**Wall** no longer restores time. In a time-free room it is a rectangle on one plane, z = −1.2.

### 5.25 Labels as words in the room (visionOS, 1 November 2026)

**What counts as a label.** `EPUBMapView.isSpatialLabel` is every `.concept` item that is not a note (`noteItemPrefix`) or a floated passage (`float:`): keywords, Shape group labels, topic magnets and concept cards. Papers and cited works keep their cards.

**Drawing.** A label's face (`cardFace`) is plain text with no pane, glass or border:
- the title in a 22 pt semibold serif (× crisp), the byline in 10 pt at 70%;
- a black shadow at 60%, radius 3 (× crisp), for legibility;
- at most 320 pt wide, held within `nodeMaxWidth`'s 240;
- white ink, turning warm gold (1.0, 0.84, 0.45) when chosen.

**Surfaces.** In the drag constraint a label is snapped by `surfacePose(for:)`, as a lifted card is, onto the nearest real wall (flush) or table (flat).
- The pose is kept in `labelStuck [id: quaternion vector]`, persisted in UserDefaults under `"mapLabelSurfacePoses"`.
- Dragging the label away from any surface clears it.
- `MapCardTick` holds a stuck label at that pose (`stuckOrientation` reads `liftedCards[id].stuck ?? labelStuck[id]`; `anyLifted` is true while any label is stuck).

**Verbs.** A chosen label shows one row: **Gather**, **Lines**, **Focus**, each lit while on (`keywordModes`). A keyword adds **Remove**; a concept adds **Hide**. Each acts on `labelMembers(item)`:
- for a Shape label, its group's members;
- for anything else, `keywordMatches(title)`: a whole-word match in the standing papers' titles, abstracts and text.

**Behaviour.**
- A chosen label, dragged, carries every paper it relates to (`labelMembers`). Through the engine's `shouldMoveAnotherNode` the riders obey the same drag constraint, so in Timeline they keep their year or volume depth. The set is worked out once per drag (`cardSizes.riders`) and cleared at the drag's end.
- Lines are drawn only on request (`conceptEdges`). Choosing a concept, topic or Shape label no longer draws them by itself.
- Focus is the room's concept Focus.
- Gather brings the members round the label and selects them (5.22).
- Letting the label go ends Lines and Focus.

**Article cards less transparent** (1 Nov 2026): an unchosen paper's face fills `Color(white: 0.1).opacity(0.72)` under its glass, so the room shows only faintly through and the words read cleanly while views change. A chosen card stays solid `white: 0.12`; lifted cards are unchanged.

### 5.27 Chosen, then open (visionOS, 1 November 2026)

A paper or citation card has two states beyond standing:
- **Chosen** (one tap, `handleTap(count: 1)`): selected, its citations raised as before. It carries no controls at all; two taps open it.
- **Open** (two taps; `toggleOpen`): chosen first if it was not, then `abstractOpenIDs` / `showsAbstract` set, so the face shows its abstract in the system serif, New York (`.system(size: 5.8 × crisp, design: .serif)`).
  - **The unfolding:** opening marks the card in `cardSizes.unfolding`. When the engine rebuilds it, `cardEntity` starts the holder at scale (1, 0.06, 1), folded flat along its middle, and 16 ms later moves it to full scale over 0.38 s (ease out). The star menu is the holder's child, so it unfolds with the card.
  - An open paper wears the star menu (5.20). The star's anchor applies only while open (`item.showsAbstract`), and its top row reads **Read** (`readCard`: a bound volume opens as its articles, anything else opens its reading in situ, which is what a double tap used to do) and **Fold**.
  - An open citation shows **Record** (`openCitationCard`), **Fold**, and Lift / Put Back.
- Two taps on an open card, or Fold, fold it back to chosen. A single tap that lets the card go also folds it.
- The Abstract verb is gone from the card's verbs, since opening shows the abstract.

**A closed card's face** (neither chosen nor open):
- **Byline:** the first authors only; the series stamp ("Vol 3 · 2022") is now `EPUBMapItem.stamp`, kept apart from `author`, so it no longer shows.
- **First sentence:** under the byline, in serif, 4.6 pt (× crisp), at 75%, at most two lines.
- **When chosen or open:** the full byline with " · " and the stamp.

`EPUBMapView.firstSentence(of:title:)` builds the sentence in `journalItems`' existing text pass:
- It takes the first paragraph that is not a heading, not the title again, not a byline (`BoundVolume.byline`) and at least 40 characters long, with `[cite:]` tokens removed.
- It cuts that at the first sentence's end (`NLTokenizer(.sentence)`), held to 180 characters at a word boundary with "…".

**The open card's sides and edge** (1 Nov 2026, later):
- **Pictures:** the paper's pictures are no longer an "Images (n)" relation. Up to eight stand as thumbnails along the open card's lower edge (`thumbnailStrip`, 72 × 54 doubled points, decoded at 240 px; "+n" beyond eight). A hidden copy above the card keeps the star centred. Tapping any thumbnail raises or puts away the gallery (5.26), and the thumbnails' border turns gold while it stands.
- **Similar** reads **Similar to**.
- **New relations** (`peopleAndVocabularyRelations`), each offered only when it reaches a standing card:
  - **Same author** (inward): other papers sharing an author. Names match by `personKey`, folded first and last name.
  - **Mentions** (outward): papers whose authors this paper names in its text. These are named, not cited (`Corpus.people`).
  - **Mentioned by** (inward): papers that name this paper's authors.
  - **Names same people** (outward): papers sharing named people.
  - **Same themes** (outward): papers sharing keyword themes.
  - **Shares concepts** (outward): papers sharing two or more of the books' glossary terms.
  - The rankings take the eight most-shared first. All but Same author read the room's corpus record (`roomCorpus`) and wait for the Mac's Build Corpus Relations.

- **Forward when open** (`openCardLift`, 3 cm):
  - On an open card (chosen and unfolded, paper or citation), everything seen of it rides one child entity (`body`): the faces, a citation's slab and a lifted card's extrusion. That child stands 3 cm out along the card's facing.
  - The collision box is offset with it (`offsetBy`), and the star's or the citation's verbs' anchor offset gains the same 3 cm.
  - The node itself (its saved place and its timeline depth) does not move.
  - The child glides forward during the unfold. On fold, the rebuilt card stands back at once.

### 5.26 Pictures in the room (visionOS, 1 November 2026)

**Source.** `BoundVolume.Article.images` is the binding's `resources.images`, joined to the package directory as hrefs are (e.g. `content/images/image1.png`). FoT has 241 images in 85 articles, all PNG, 69 MB.

`EPUBMapView.imagePaths(forDocID:)` turns an article id into absolute paths: its volume record's folder under `VisionModel.epubsRoot`, plus each image.

**Loading.** `CardImages.image(path:maxPixel:)` (main actor) decodes with ImageIO's `CGImageSourceCreateThumbnailAtIndex` straight to the asked size (`kCGImageSourceThumbnailMaxPixelSize`, with its transform), so a large figure never stands in memory whole. Results are cached in an `NSCache` keyed by size and path.

**Thumbnails.** `EPUBMapItem.imagePath` is part of visual equality. A standing paper or side piece gets its first image. The card face shows it above the title, aspect-fit, at most 24 pt (× crisp) high, which keeps the wall's row pitch clear. It is decoded at 320 px. Set-aside slips show none.

**Images Shape.** `RoomShape.images` is always available. It groups the targets by picture count:
- "Many pictures" (5 or more);
- "Several pictures" (2–4);
- "One picture".

The text-only rest is "Text only", standing as the field behind. On FoT the groups are 14, 27 and 44.

**Gallery.** The star menu gains an outward relation, **Images (n)**, whose ids are `image:<docID>|<i>`.
- Tapping it sets `galleryOf`. `reload` then builds one `.concept` card per picture, in rows of four to the paper's right: x + 0.24 + col × 0.2, y + 0.06 − row × 0.17, z + 0.05. Each card's face is the picture alone (decoded at 900 px, at most 150 × 120 pt × crisp), with a hairline border that turns gold when chosen.
- `relationShown` draws a line from the paper to each picture.
- A second tap, choosing another relation, or letting the paper go puts the gallery away.
- Gallery cards are not labels (`isSpatialLabel` excludes `image:`), and a double tap on them, or on a label, opens nothing.

### 5.28 Many cards: what each costs (visionOS, 1 November 2026)

A series room stands about 400 cards. Four measures keep each one cheap:
1. **Measure, don't render** (`NodeImmersiveView.measuresNodesOnly`, an engine addition owed back to Author).
   - Before: the engine drew every node's view to an image at 4× and uploaded it as a `TextureResource`. The face itself is laid out at 4× crisp, so that was about 1800 px across, used only to measure the holder, then discarded.
   - Now `update` asks `UIView.sizeThatFits` and makes a bare `generatePlane` of that size at 1000 pt/m, with no image and no texture.
2. **Attachments only where needed** (`needsAttachmentBlock` / `.needsAttachment`, also an engine addition). Only items with `isAttachmentsEnabled` (chosen, not a ghost or faded) declare an `Attachment`, instead of every item declaring one (mostly `EmptyView`).
3. **Back faces on demand.**
   - A card's back face entity is built without its `ViewAttachmentComponent`. `CardFacesComponent.makeBack` holds a maker.
   - `CardFaceTurner.turn` sets the component the first time the reader is behind the card. Most cards are never seen from behind, so most never pay for a second live attachment.
4. **No live blur on papers and citations.** Their faces fill `Color(white: 0.1).opacity(0.88)` (a chosen card is solid `white: 0.12`), and `glassBackgroundEffect` is `.never` for `.article`, `.cited` and `.citedDeep`. Labels, concepts and notes keep their own looks.

### 5.30 The bar in every room (visionOS, 1 November 2026)

Every room now carries the bar: journals such as the Hypertext proceedings as well as volumes and series.
- **Opening it:** `syncVolumeBar` opens `volume-toolbar` whenever `openJournalVenue` is set, both on venue change and on the Hallway's `onAppear`. `prepareSeriesIndex` still runs for volume rooms only.
- **Documents** (`openWindow(id: "library")`), which was the arm's Documents chip, now leads the bar. It is the way back to the document chooser.
- **Dimmed in a journal's room**, never hidden: the zone words and **Ask**, which reads a series index.
- **Journal fallbacks:**
  - `paperAuthors(_:)`: a piece's bylines, else the shelf record's `authors`, else its `author` split on `,` `;` `&` and " and ". These feed Authors and Same author.
  - `bookImagePaths(forDocID:)`: for a book read whole, every png/jpg/gif/webp/heic in its unpacked folder, in name order, skipping names containing cover or logo and files under 8 KB. These feed the thumbnails, the gallery and Images.
- **Still volume-only:** the series index's Similar, and Ask. The corpus record came to journals in 5.31.

### 5.31 Corpus relations for journals (1 November 2026)

A journal (every shelf record declaring one venue that is not itself a bound volume, e.g. the Hypertext proceedings) is a corpus like a series.
- **Its identity:**
  - Corpus id: `CorpusRelations.journalPrefix + venue` (`"journal:"`). Its name is the venue.
  - Each paper is one piece, read whole: `folder#whole` (`CorpusRelations.wholeWork`). Its title and authors come from the library's document, falling back to the record.
- **The window:** `CorpusRelationsBuilder.corpus(of:in:)` returns a `Target` (id, name, volumes, papers). The window lists series first, then every journal of two or more papers ("n papers"). Build takes the first volume or paper.
- **Citations:** `CorpusRelations.build(name:volumes:papers:known:)` takes `PaperSource`s (folder, title, authors, the BibTeX of each `LiquidDoc.Reference`).
  - Each entry is read under its paper (`piece|entryKey|n`), because entry keys repeat from paper to paper. It is attributed `"paper"`.
  - Works, in-corpus matching by title, the counts, Shares Sources and the canon are as for volumes. A finding reports the entries read and the papers with no reference list. Papers not yet in the library index are left out and logged.
- **The reading:** `read(into:sources:papers:paperGlossary:)` appends one `PieceText` per paper:
  - keywords: the document's own;
  - text: title and body paragraphs;
  - embedding input: title, abstract and the body's first 2000 characters.
  The glossary is extended with every paper's Defined Concepts (the user definition, else the description). People, terms, themes, meaning and Similar then run unchanged.
- **The headset:**
  - `VisionModel.pieceKey(forDocID:folders:)` maps a volume article to `folder#article` and a plain record id to `folder#whole`. `docID(forPiece:)` is its inverse.
  - `roomCorpus`, `corpusCitations` and `corpusRelated` all go through these, so a journal room's Shapes and star relations read its record exactly as a series room does.

### 5.32 Library Upkeep (macOS, 1 November 2026)

The Mac keeps the library's metadata current without being asked, so the reader reads and never manages documents (`LibraryUpkeep.swift`).
- **The loop:** `LibraryUpkeep.shared.start(model:)` runs from the main window's `.task`. It waits 60 s, then ticks every 60 s at `.background` priority. While any pass is running (started by hand or not), a tick does nothing.
- **What it looks for, in order** (each feeds the next):
  1. A bound volume with a work that has no `ArticleMetadata` entry. This runs `ArticleEnrichment.start(volumes:model:background: true)`.
  2. Library documents not yet in the looked-up set (UserDefaults `libraryUpkeepCitedDocs`), or a cited-works record over 30 days old. This runs `CitedWorksCheck.start(docs:folder:background: true)`.
  3. A corpus from `CorpusRelationsBuilder.allCorpora(in:)` that is missing, whose volume or paper folders differ from `Corpus.volumes`, whose `themes` is nil, or whose `meaning` is nil while the embedding model stands. This runs `build(corpusOf:model:background: true)`.
- **Retries:** each job remembers its last try and the folder set it tried on (`attempts`). It is tried again when that set changes, or after 24 h, so a pass that cannot finish (Ollama away, a paper unread) never loops.
- **Pacing** (`BackgroundPace`): in background mode every pass runs its detached work at `.background` priority. Before each step it awaits `waitForQuiet()`:
  - steps are each article (ArticleEnrichment), each cited work (CitedWorksCheck), and the reading stage plus each batch of 8 embeddings (CorpusRelationsBuilder);
  - "quiet" means no keyboard, mouse or trackpad input for 20 s (`CGEventSource.secondsSinceLastEventType(.combinedSessionState, ~0)`), thermal state below serious, and Low Power Mode off; it polls every 5 s.
  - A pass started by hand keeps full speed.
- **Settings ▸ AI ▸ Library Upkeep** (`LibraryUpkeepSettingsSection`, after Embedding Model): a toggle, on by default (`libraryUpkeepEnabled`), and the upkeep's one-line status.

### 5.33 AI on This Mac: models Origami runs itself (macOS, 2 November 2026)

No Ollama or LM Studio is needed: Origami downloads and runs models in-process on MLX (`LocalModels.swift`).
- **Packages** linked to the macOS target:
  - mlx-swift-lm, **exact 3.31.4** (speech-swift pins it): MLXLLM, MLXLMCommon, MLXEmbedders, MLXHuggingFace;
  - swift-transformers: Tokenizers;
  - swift-huggingface: HuggingFace.
  The MLXHuggingFaceMacros macro must be trusted once in Xcode; command-line builds pass `-skipMacroValidation`. All the code is behind `#if os(macOS) && canImport(MLXLLM)…`.
- **The ladder** (`LocalModelChoice.ladder`): each rung pairs a chat model with an embedding model (all from mlx-community, 4-bit). Download sizes are the two together.

| Rung | Chat model | Embedding model | Download | Memory needed |
|---|---|---|---|---|
| 0.8B | Qwen3.5-0.8B-4bit | Qwen3-Embedding-0.6B-4bit-DWQ | 1.0 GB | 4 GB |
| 4B | Qwen3.5-4B-MLX-4bit | Qwen3-Embedding-0.6B-4bit-DWQ | 3.3 GB | 8 GB |
| 9B | Qwen3.5-9B-MLX-4bit | Qwen3-Embedding-4B-4bit-DWQ | 8.3 GB | 16 GB |
| 35B-A3B | Qwen3.5-35B-A3B-4bit | Qwen3-Embedding-4B-4bit-DWQ | 22.7 GB | 32 GB |
| 122B-A10B | Qwen3.5-122B-A10B-4bit | Qwen3-Embedding-8B-4bit-DWQ | 73.9 GB | 96 GB |

- **What a Mac is offered** (`offered`): the three largest rungs that fit `physicalMemory`, labelled Light, Balanced and Best.
- **Download** (`LocalModels.download`): `#hubDownloader()` fetches the embedding model, then the chat model (patterns `*.safetensors *.json *.jinja *.txt *.model`). Progress is weighted 4 % to the embedding model. A stopped download resumes. When both are in, the pair is recorded in UserDefaults `localModelsReady` and selected.
- **Selection:** `OrigamiLLM.selectedID = "local|<id>"`. `selectedLocalChoice` is nil unless that pair is ready.
  - `respond` goes to `LocalModels.respond`: a `ChatSession` with `enable_thinking: false`, maxTokens 4096 and temperature 0.6 (top-p 0.95), with any `<think>` text cut.
  - `generate<T>` sends the same JSON-schema prompt a server gets, read back by `decode`.
  - `canRespond`, `respondJSON`, `embed` and `hasEmbeddingModel` all honour the selection.
  - `activeEmbeddingModel` (the embedding repo) names the corpus vector cache, so two models' vectors never mix.
- **Embedding** runs one text at a time: tokens are truncated to `maxPositionEmbeddings`, then `model(…)` and `pooling(normalize: true)`.
- **Memory:** loaded containers are released after 10 idle minutes (`MLX.GPU.clearCache()`).
- **Settings ▸ AI:** **AI on This Mac** comes first, one row per offered rung: tier, model, summary and size, then *Download and Use*, a progress bar with *Stop*, *Use*, or a green *In Use*. **Model in Use** (the former Language Model picker) follows. It lists the ready pairs first, and leaves out embedding-only models (`isEmbeddingOnly`: names containing "embed", or bge-).

### 5.34 Every card verb in the bar, two rows (visionOS, 2 November 2026)

This supersedes the star's buttons (5.20, 5.27, 5.29) and every row of verbs that hung under a chosen card. Cards now carry only content: an open paper keeps its picture strip, and while a relation is lit, the miniature ring.
- **The paper's surround** (`paperStar`) is the thumbnail strip, mirrored unseen above so the card stays centred, plus the ring.
  - Ring radii: half the gap plus half a miniature, plus 40 across and 110 down.
  - Gone with the buttons: `relationColumn`, `starExtras`, `manyPaperButtons`, `onePaperButtons`, `kindRowCardID` and `layoutRowCardID`. Several-paper Layout now lives only in the bar's Layout menu.
- **The bar** (`VisionVolumeToolbar`) is a `VStack` of two 56-pt rows with a divider between them:
  1. **The room:** everything it held before.
  2. **The chosen card**, scrollable sideways: its kind in small capitals (PAPER or the piece's Kind, CITATION, KEYWORD, CONCEPT, LABEL, NOTE, PASSAGE), its title (at most 260 pt), its verbs, a divider, then its relations. Each relation shows its count, a small AI where a model inferred it, and accent and semibold while lit. Verbs with options (Kind) are a `Menu` with a checkmark on the current one. With nothing chosen, the row reads "Choose a card — what it can do stands here." in tertiary.
- **Data:** `VisionModel.CardBar` holds itemID, title, kindLabel, verbs and relations. Each `Verb` has id, title, isOn, isAI, count, isEnabled and options.
  - `EPUBMapView.syncCardBar()` publishes it (only on change) at the end of `reload()`, after every tap, and after open/fold.
  - The bar's card is `cardSizes.barItemID`: the last card chosen while it stays chosen. Otherwise it is an open paper, then any paper, then any chosen card.
  - A press posts `volumeBarRequest .card(itemID, verbID)`, which `performCardVerb` carries out.
- **The verbs:**

| Card | Verbs |
|---|---|
| Paper | Read, Open/Fold, Focus/Un-Focus (lit for a relation focus or Focus mode), Hide, Pictures n (the gallery), Lift (when enabled), Transpoint; Kind (a menu) in volume rooms, Articles elsewhere |
| Paper's relations | One **Relations** menu (`relationsMenu`). Each entry is `title  n · AI`, and the lit one is checked. While a relation stands, the menu reads "Relations: <title>" in accent and semibold. Each entry posts `rel:<title>`, which calls `toggleRelation` |
| Citation | Open/Fold, Record, Lift |
| Label | Gather, Lines, Focus (lit by mode), Remove (keywords), Hide (concepts) |
| Note | Write, Delete |
| Passage | Delete |

There is no Close: tapping the card lets it go.

**Row 1, in order:** Documents · Keyword · Opening/Articles/Appendices · Select All · Layout · Shapes · **Whole Volume** · **Whole Series** · Ask.
- **Whole Volume** runs `openWholeVolume(from: cardBar?.itemID)`. It is dimmed unless the room is a volume's, or the chosen card is a volume's article.
- **Whole Series** runs `openSeries(wholeSeriesID)`. It is dimmed unless the room is a volume's whose series has two or more volumes on the shelf, and the series room is not already standing.

### 5.29 Miniatures on the star, and jumping to a card (visionOS, 1 November 2026)

When a relation on an open paper's star is lit (Similar to, Mentioned by, Cites…), its cards also stand in miniature on a ring round the star. The lines to the real cards still run.
- **The ring** (`miniatureRing`):
  - It is an ellipse about the star, inside the same attachment. While the ring stands, the star's `ZStack` is framed to hold it, so nothing clips.
  - Radii: half of (gap width + 440) + 140 across, and half the gap height + 210 down, in doubled points.
  - The first miniature is at the top, the rest evenly clockwise, at most 14 (`ringLimit`).
  - Images rings nothing: it has the gallery (5.26).
- **A miniature** (`miniatureCard`): 230 × 96 doubled points, on the cards' 0.88 dark ground, with the title in serif semibold (2 lines) and the byline beneath.
- **Tapping a miniature** (`jumpToCard`):
  - The relation and gallery are put away.
  - The whole space is carried (`carrySpace`, so Undo View takes it back) until the card stands 0.75 m (`jumpDistance`) in front of the eyes and 6 cm below them. It lands along the cards' own facing axis (Z), on the side the reader is turned toward. Without a head pose, the eyes are taken as (0, walk height, 0).
  - The card then opens (`toggleOpen`) unless it is open already.
  - A card stuck to a real surface does not travel with the space. It is not carried, but it still opens.
- **A lit relation is a Focus** (`shouldEnableNode`, checked before every other focus):
  - Only the paper and the cards the relation reaches stand; every other card, citation and label steps away.
  - Images is exempt, because it is the gallery, not a relation.
  - While a relation focus stands, the star of the paper, or of any card in the relation, shows a lit **Un-Focus** in place of Focus.
  - The focus ends when the same relation is tapped again, on Un-Focus, or when the paper is let go (Close or Hide). Tapping another relation moves the focus to that one.
  - A jump keeps the focus and the lines, and puts only the ring away (`RelationShown.ringed = false`). The reader moves among the same cards.

### 5.24 A reading panel faces the reader while carried (visionOS, 1 November 2026)

A reading panel is dragged by its grab bar (`ReaderHandleComponent`) through the Hallway's simultaneous `DragGesture`. Each change moves the panel root and, when `faceTurner.headPose()` gives a head pose, calls `ReaderPanels.turn(docID:toward:)` with the head's position.
- The turn is about the vertical only: `yaw(facing:)` of head minus panel, flattened to the floor.
- It is stored as the panel's own facing (`yaws[docID]`), composed with the panel's current lean: upright 0, tilted −π/4, flat −π/2.
- On release nothing more happens, so the panel keeps the angle it last had, and a later pose change composes with that facing.
- Without a head pose (the simulator) the panel keeps its facing while it moves.



## 6. Themes and typography

A theme sets **only background and text colours**. Links, headings and
front-matter blocks inherit the text colour.

**CSS a theme emits** (`ReaderTheme.css`):

```
:root { color-scheme: light dark; }
html, body { background-color: <bgLight> !important; color: <textLight> !important; }
@media (prefers-color-scheme: dark) {
  html, body { background-color: <bgDark> !important; color: <textDark> !important; }
}
```

The `!important` is required: Google Docs exports paint the body through
a class (`<body class="c5">`, `.c5 { background-color: #ffffff }`), which
outranks a plain `html, body` rule.

An untouched High Contrast theme emits `:root { color-scheme: light dark; }`
and only a dark rule, `html, body { background-color: #1e1e1e !important;
color: #ffffff !important; }` inside `@media (prefers-color-scheme: dark)`.
In light mode the book keeps its own black-on-white. It once emitted only
`color-scheme: light`, which left a dark Mac reading black type: the web view
draws no background, so the dark window showed through (fixed 1 Nov 2026).

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

**Light and dark on the Mac (1 Nov 2026).** The native reading views draw each paragraph in an AppKit text view (`SelectableParagraph` in `OrigamiReadingView.swift`). It replaces its text storage only when the converted text compares unequal, so as to keep a live selection. System colours, such as the label colour a paragraph without a theme ink wears, compare equal across light and dark, so after a system switch the view kept its old ink. The paragraph now reads `@Environment(\.colorScheme)` and keeps the last scheme in its coordinator. On a change it lays the text in afresh and marks the view for display. The web reader follows by itself through the contrast pass's media listener (see the user-script table above).

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
    colour; a red link keeps its colour. A Google Docs EPUB (black `p`
    and spans, `<body class="c5">` painted white) takes the theme's page
    and ink, keeps its 26 pt Arial title, and a navy box keeps its white
    text.
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
