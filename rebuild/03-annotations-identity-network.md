# Chapter 3 — Annotations, Document Identity and Network Integrations

This chapter belongs to the Origami Text rebuild guide. It covers the reader's
own layer over the library (highlights, comments, tags, page notes and
document notes), how that layer is stored, synced and exported, how a
document is named, and every network integration the macOS app has: Hypothesis,
Seed Hypermedia (`hm://`), Gemini and gemtext, the letter post, fetch-by-DOI,
calendar and data series.

Source paths are relative to the repository root. Unless stated otherwise a file
is in `Origami Text macOS/`.

Read these first. This chapter links to them and does not repeat them:

- [README.md](../README.md): build entry point and the documentation index.
- [ORIGAMI-DOCUMENT-FORMAT.md](../ORIGAMI-DOCUMENT-FORMAT.md): the `.origamitext` format. Paragraph ids, addresses and the span-matching rule (case- and diacritic-insensitive) come from here.
- [ORIGAMI-EPUB-PROFILE-1.0.md](../ORIGAMI-EPUB-PROFILE-1.0.md): the EPUB profile. §6 (Addressing, in particular "Annotation consequence" at the end of §6) and §15 (Authored intent and reader activity) are the normative basis for this chapter: *reader state lives outside the publication, and a conforming reader MUST NOT modify a publication.*
- [hypothesis-integration-plan.md](../hypothesis-integration-plan.md): the plan for Hypothesis, of which only Phase 1 exists in code (see §5.1).
- `~/Documents/OrigamiFormat/README.md`: the shared Swift package that holds the format code once, including the **document identity rule (DOI, then `urn:origami:sha256:`, then `urn:origami:local:`)**. **Origami Text does not link this package yet.** It has its own older copies of `WebAnnotation`, `AnnotationStore` and `AnnotationAnchor`. The migration kit is in `OrigamiFormat-migration/` (README, `apply.sh`, `OrigamiFormatExports.swift`, `AnnotationAnchor+LiquidDoc.swift`), and it has not been applied: `OrigamiText.xcodeproj/project.pbxproj` contains no reference to `OrigamiFormat`. (The package README says "Origami Text links it into `LiquidView`". That is not true of the repository today.)

---

## 1. Purpose

The annotation subsystem lets a reader mark up any book in the library and
keep those marks for good, without ever touching the book:

1. **Never write into the book.** Every annotation lives in a JSON-LD sidecar
   file beside the unpacked books, one per book (`AnnotationStore.swift`,
   header comment: "the book is the author's; the annotations are the
   reader's"). This is the profile's §15 rule.
2. **Standard model.** Each annotation is a W3C Web Annotation, the same model
   Hypothesis and Readium use. Any conforming consumer can read the sidecar.
3. **Anchors that survive revision.** A target carries a "selector ladder":
   stable element id, then the quoted words with context, then position and
   progression hints. A re-anchoring cascade finds the words again after the
   text changes. An annotation that can no longer be placed is an *orphan*.
   It is kept and shown as "unanchored", never deleted.
4. **Travel.** Annotations sync between the user's devices through a shared
   "community folder", merged per annotation with tombstones. They export as a
   W3C AnnotationCollection, W3C EPUB Annotations 1.0 (`.annotations`),
   Markdown and Readwise CSV, and can be posted to Seed Hypermedia as signed
   comments.

The network integrations bring documents in (Seed, Gemini, open-access
registries, data APIs) and send the reader's voice out (Seed comments,
letters through Mail). One rule covers all of them: **nothing at launch may
prompt for network access, sign-in or the Keychain** (§5.9).

---

## 2. The annotation model

### 2.1 Types

Defined in `WebAnnotation.swift` (struct `WebAnnotation`, header comment
"Ported verbatim from Knowledge Space's WebAnnotation.swift").

| Field | Type | Notes |
|---|---|---|
| `id` | string | Default `"urn:uuid:" + lowercase UUID`. If missing on decode, a fresh one is minted. |
| `motivation` | string | Open W3C vocabulary. Origami Text writes `highlighting`, `commenting`, `tagging`, `describing`. If missing on decode it defaults to `highlighting`. |
| `created` | date | ISO 8601 with time zone, **whole seconds only** (`ISO8601DateFormatter` with `.withInternetDateTime`). If missing or unparseable on decode, it becomes "now". |
| `modified` | date, optional | Same format. Set whenever a body or placement is rewritten. |
| `creator` | `Person {name}`, optional | Encoded as `{"type":"Person","name":…}`. Decoded leniently: if it fails, it is dropped. |
| `body` | `TextualBody {value, purpose?}`, optional | Encoded as `{"type":"TextualBody","value":…,"format":"text/plain","purpose"?:…}`. |
| `target` | `Target {source, selectors[]}` | `source` is the document IRI (see §4). The `selector` key is omitted when the list is empty. |
| `origami:placement` | `{near?, dx, dy}`, optional | Where a page note or slip stands on the page. `near` is a stable element id. `dx`/`dy` are offsets from that element's top-left, or absolute page coordinates when `near` is absent. |
| `origami:float` | `{x, y, z}`, optional | Where a floated quote stands in the visionOS Map's own space, in metres. |

Constants:

- `@context` = `http://www.w3.org/ns/anno.jsonld`, written on every annotation.
- `type` = `"Annotation"`, always written.
- `WebAnnotation.fragmentConformsTo` = `https://origamitext.app/ns/data-id`. A FragmentSelector conforming to this names an Origami stable paragraph id (the `data-id` / `id` an Origami EPUB carries).

### 2.2 Selectors (the ladder, most robust first)

Enum `WebAnnotation.Selector`:

| Case | JSON `type` | JSON fields | Meaning |
|---|---|---|---|
| `.fragment(value, conformsTo?)` | `FragmentSelector` | `value`, `conformsTo?` | Stable element id. It may be bare (`P-1`) or path-qualified (`content.xhtml#P-1`). |
| `.quote(exact, prefix?, suffix?)` | `TextQuoteSelector` | `exact`, `prefix?`, `suffix?` | The exact words, plus up to 32 characters of context on each side. |
| `.position(start, end)` | `TextPositionSelector` | `start`, `end` | Character offsets **within the paragraph's text** (not the document's). Used only as a hint. |
| `.progression(Double)` | `ProgressionSelector` | `value` | Fraction through the document: `paragraphIndex / paragraphCount`. Readium's selector. Used for ordering and hinting. |

Decoding is lenient (`WebAnnotation.Target.init(from:)`):

- `selector` may be a single object or an array.
- A selector with an unknown `type` is skipped, never fatal (`Lossy` wrapper).
- One annotation that fails to decode is skipped and never sinks the sidecar
  (`AnnotationStore.CollectionFile.Lossy`).

### 2.3 Motivations and kinds

`ReaderAnnotationKind` (in `WebAnnotation.swift`) is the reader's judgement
vocabulary. Except for Highlight, each kind travels as a **standard W3C tagging
body**: motivation `tagging`, body `{value: <raw value>, purpose: "tagging"}`.

| Kind (raw value, stored) | Key in Annotate menu | Default colour (`AnnotationKindStyle.defaultHex`) | EPUB-Annotations colour |
|---|---|---|---|
| Important | i | E4572E | orange |
| Quotable | q | 2E8B8B | blue |
| Great | g | 3A9B35 | green |
| Disagree | d | C93C3C | pink |
| Language Issue | l | 8E5BC0 | purple |
| Problematic | p | D98E1B | pink |
| What is this? | / | 3B6FD4 | purple |
| Highlight | h | E8C51D | yellow |
| Strikethrough | x | 8A8A8A | yellow, with `highlight: "strikethrough"` |

`ReaderAnnotationKind.kind(of:)` works out an annotation's kind like this:

1. If `body.purpose == "tagging"` and `body.value` is a known raw value, that kind.
2. Else, if the motivation is `highlighting`, Highlight.
3. Else none (a plain comment, a document note).

Display names and colours can be overridden per reader in Settings ▸
Annotations (`AnnotationKindStyle` in `AnnotationsListView.swift`; stored in
user defaults under `annotationKindNames` and `annotationKindColors` as
`{rawValue: "RRGGBB"}`). **The stored annotation always carries the canonical
raw value.** Renaming is presentation only.

What each user action writes:

| Action | motivation | body | selectors | extensions | Code |
|---|---|---|---|---|---|
| Highlight words (WebView reader) | highlighting | none | fragment (if the selection sits in an element with `data-id`/`id`), quote with prefix/suffix | — | `AppModel.addAnnotation(motivation:note:purpose:on:)` in `AppModel.swift` |
| Comment on words (WebView) | commenting | `{value: note}` | as above | — | `AppModel.addComment(_:on:)` |
| Tag words with a kind (WebView) | tagging | `{value: "Important", purpose: "tagging"}` | as above | — | `AppModel.addTag(_:on:)` |
| Highlight / tag / comment (native reading modes) | as above | as above | fragment, quote, position, progression (full ladder) | — | `AppModel.addHighlight(to:paragraphID:exact:)`, `addTag(_:to:…)`, `addComment(_:to:…)` + `AnnotationAnchor.target(in:paragraphID:exact:)` |
| Page note (ctrl-click on empty page) | commenting | `{value}` | **none** | `origami:placement` | `AppModel.addMarginNote(_:to:placement:)` |
| Float a selection | highlighting | none | quote only, no context | `origami:float` = (0, 1.35, −0.9); `origami:placement` = the measured spot, or `{dx:160, dy:300}` | `AppModel.floatSelection(_:in:placement:)` |
| Document note (one per book) | describing | `{value, purpose: "describing"}` | **none** | — | `AppModel.setDocumentAnnotation(_:forAddress:)` |

Rules from the code:

- A comment with empty text after trimming is never saved.
- A WebView annotation needs selected text **or** an enclosing element id.
  A comment with no words anchors by element id alone.
- There is at most one document note per book: the first annotation with
  motivation `describing` and no selectors. Saving empty text removes it.
- Page notes are annotations with no selectors, a non-empty body and
  motivation `commenting`, or any annotation with `origami:float`
  (`AppModel.marginNotes(for:)`). **Annotations with no selectors are never
  orphans** (`AppModel.orphanedAnnotationIDs(for:)`).
- In the WebView reader, comments on headings (`h1`–`h6`) are not painted as
  ink. They float as slips (`EPUBReaderView.swift`, `headingComments`, and the
  JavaScript guard in `annotationScript`).
- Small inconsistency: the WebView paths and native tagging set `creator` to
  the user's author name. Native `addHighlight(to:…)` and `addComment(_:to:…)`
  do not.

Where the selection's context comes from (`EPUBReaderView.swift`, the
selection script near the `mouseup` handler):

- `text` = the selection, trimmed, cut to 500 characters.
- `fragment` = `data-id` or `id` of the closest ancestor that has either.
- `prefix` / `suffix` = up to 32 characters either side of the first
  occurrence of the **untrimmed** selection inside that element's
  `textContent`.
- Also reported, but not stored in the annotation: the print page (from the
  last `epub:type~="pagebreak"` or `role="doc-pagebreak"` marker before the
  selection) and the glossary target.

### 2.4 Worked example: one sidecar

File `f.hegla.093000k.annotations.jsonld`. This is the shape
`AnnotationStore.save` writes: pretty-printed, keys sorted, slashes not
escaped. Whitespace does not matter to readers.

```json
{
  "@context": "http://www.w3.org/ns/anno.jsonld",
  "items": [
    {
      "@context": "http://www.w3.org/ns/anno.jsonld",
      "body": {
        "format": "text/plain",
        "purpose": "tagging",
        "type": "TextualBody",
        "value": "Important"
      },
      "created": "2026-10-05T09:12:44Z",
      "creator": { "name": "Frode Hegland", "type": "Person" },
      "id": "urn:uuid:5b0e4c1a-2f7e-4d0b-9c55-3f1a2b7c9d10",
      "motivation": "tagging",
      "target": {
        "selector": [
          { "conformsTo": "https://origamitext.app/ns/data-id",
            "type": "FragmentSelector", "value": "P-68353888-1EA7-4D0B-A084-D9F8F6027523" },
          { "exact": "We have long celebrated the pen",
            "prefix": "", "suffix": "… Socrates worried that",
            "type": "TextQuoteSelector" },
          { "end": 31, "start": 0, "type": "TextPositionSelector" },
          { "type": "ProgressionSelector", "value": 0.0425 }
        ],
        "source": "origamitext://open/f.hegla.093000k"
      },
      "type": "Annotation"
    },
    {
      "@context": "http://www.w3.org/ns/anno.jsonld",
      "body": { "format": "text/plain", "type": "TextualBody", "value": "Check this against chapter 4." },
      "created": "2026-10-05T09:20:03Z",
      "id": "urn:uuid:9d6a0c2e-6b1f-4a43-8a6f-0f0b9c6e1a22",
      "modified": "2026-10-05T10:01:17Z",
      "motivation": "commenting",
      "origami:placement": { "dx": 24, "dy": 8, "near": "P-0979114B" },
      "target": { "source": "origamitext://open/f.hegla.093000k" },
      "type": "Annotation"
    }
  ],
  "total": 2,
  "type": "AnnotationCollection"
}
```

Notes on the example:

- When the native reader builds the quote, a `prefix`/`suffix` that comes out
  empty is omitted (written as nil), not written as `""`. The empty prefix
  above is only for illustration. A rebuild should omit empty context.
- The second item is a page note. It has no `selector`, so it is never an
  orphan.

### 2.5 Anchoring: making a target

`AnnotationAnchor.target(in:paragraphID:exact:)` in `AnnotationStore.swift`:

1. Always add `.fragment(paragraphID, conformsTo: fragmentConformsTo)`.
2. If `exact` is non-empty:
   - Search for it in that paragraph's text with the **matching options**:
     case-, diacritic- and width-insensitive.
   - If found: add `.quote(exact: <the document's own spelling of the match>,
     prefix: last ≤32 characters before it, suffix: first ≤32 characters after
     it)`, with empty context left out. Then add `.position(start, end)` as
     character offsets within the paragraph.
   - If not found: add `.quote(exact, nil, nil)`.
3. If the paragraph is in the body: add
   `.progression(index / body.count)`.
4. `source` = `"origamitext://open/" + doc.id`.

### 2.6 Re-anchoring: the resolve cascade (native reading modes)

`AnnotationAnchor.resolve(_:in:)` in `AnnotationStore.swift`. Input is an
annotation and a document as an ordered list of paragraphs `(id, text)`.
Output is `Resolution {paragraphID, exact?, method}` or nil (orphan).

Gather the hints. Where a selector type appears more than once, the first one
wins: `fragmentID`, `quote` (the first with non-empty `exact`),
`positionHint = position.start`, `progressionHint`.

**Step 1: find the anchored paragraph.**
- Look for a paragraph whose id equals `fragmentID` exactly.
- If none, try `sameElement(fragmentID, in:)`. Take the part after the last
  `#` in both the address and each paragraph id. Accept a paragraph only if
  exactly **one** has that fragment. If the address itself contains `#`,
  paragraph ids that also contain `#` are excluded, because two different
  `path#id` forms name different documents.
- This bridges Scrolling mode, which files bare `P-1`, and the native modes,
  which use `content.xhtml#P-1`.

**Step 2: the anchored paragraph exists.**
- No quote: return `(paragraph, nil, .fragment)`.
- The quote is found exactly (matching options) in the paragraph: return
  `(paragraph, quote.exact, .quoteInParagraph)`.
- Else `fuzzyMatch(quote.exact, in: paragraph.text)` succeeds: return
  `(paragraph, <the document's matched words>, .quoteInParagraph)`.
- Else return `(paragraph, nil, .paragraph)`. Paragraph scope stands. Never break.

**Step 3: no anchored paragraph, and no quote:** return nil (orphan).

**Step 4: exact words anywhere, scored by context.** For each paragraph and
each exact occurrence of `quote.exact`:
- `score = 0`.
- +1 if the `prefix.count + 8` characters before the match, case-, diacritic-
  and width-folded, **end with** the folded prefix.
- +1 if the `suffix.count + 8` characters after the match, folded, **start
  with** the folded suffix.
- Keep the first occurrence with the strictly highest score.

If any occurrence was found, return `(bestParagraph, quote.exact, .quoteInDocument)`.

**Step 5: fuzzy words anywhere, searched outward from the hint.**
- Paragraph offsets: running total of `text.count + 2` per paragraph.
- Target offset = `positionHint` if present, else
  `round-down(total × clamp(progression, 0, 1))`.
- Sort paragraphs by `|offset − target|`. With neither hint, use document order.
- Return the first paragraph where `fuzzyMatch` succeeds, as `.quoteInDocument`.

**Step 6:** return nil (orphan).

Caveat: the position hint is a paragraph-local offset (§2.5), but step 5
compares it with document-global offsets. So for most annotations the hint
mostly favours paragraphs near the start of the document. The shared package
has the same behaviour. A rebuild may store a global offset instead, but must
still read the old form.

**`fuzzyMatch(quote, text)`** is Sellers' approximate substring search
(edit distance where the match may start anywhere in the text):

- Lowercase both strings. Work on characters (Swift `Character`, which is a
  grapheme cluster).
- Quotes shorter than **8** characters never fuzzy-match.
- Budget = `max(2, min(len(quote) / 5, 24))` edits (integer division).
- Dynamic programming over the text, column by column. `D[0] = 0` in every
  column, so a match can start anywhere. Substitution costs 0 or 1, insertion
  and deletion cost 1. A parallel `start[i]` array tracks where each match
  began. When costs tie, prefer substitution, then deletion, then insertion.
- Keep the end position with the smallest distance ≤ budget. The first such
  end wins ties.
- Return the original-case text from `start` to `end`, trimmed of whitespace.
  Return nil if empty.

The result is cached per `(doc.id, annotationsStamp)`
(`AppModel.resolvedAnnotations(for:)`). `annotationsStamp` is a counter bumped
on every annotation change.

### 2.7 Re-anchoring in the WebView reader (page script)

The WebView (EPUB page) reader does **not** run the Swift cascade. It sends a
flattened list to JavaScript (`PaintedAnnotation` in `EPUBReaderView.swift`:
id, first fragment, first quote's `exact`, note, `"comment"|"highlight"`,
colour hex, strike flag). The JavaScript is `annotationScript` in
`EPUBReaderView.swift`:

1. If the fragment is `path#id`, keep the id only when the file name of the
   path equals the file name of the page on show (both URL-decoded).
   Otherwise drop it.
2. The host element is `getElementById(frag)`, else `[data-id="frag"]`.
3. Range search: concatenate all text nodes under a container and find
   `exact` with **lowercase `indexOf`**. This is case-insensitive only: no
   diacritic folding, no fuzzy match, no prefix/suffix scoring.
4. Order: try the words in the host; else the words anywhere in `document.body`;
   else the whole host element. The exception is a comment on a heading,
   which is skipped.
5. Paint with the CSS Custom Highlight API. There is one `Highlight` group per
   colour, plus one per colour with strike: `::highlight(origami-k<hex>)`,
   either `{color:#hex}` (the words take the ink colour, they are not given a
   background) or `{text-decoration:line-through; text-decoration-color:#hex}`.
6. A click whose caret falls in a painted range (and is not a selection
   gesture) posts `{event:'annotation', id, kind, note, x, y}` to the native
   side, which offers removal or editing.

**Divergence to know about:** the same annotation may land differently in the
WebView reader (exact-ish only) and the native modes (full fuzzy cascade). A
rebuild should run one cascade everywhere. The shared package's
`EPUBReadingStyle` is the intended home for it.

### 2.8 Orphans

`orphanedAnnotationIDs(for:)` = annotations with at least one selector where
`resolve` returns nil. The Annotations list marks them "· unanchored" in
orange. They are never deleted automatically. (This meets profile §6's
requirement to tell an exact attachment from an inferred one only partly:
`Resolution.method` records the difference, but the UI shows only orphan or
not.)

---

## 3. Storage, sync and export

### 3.1 Sidecars on this device

| Item | Value | Source |
|---|---|---|
| Folder | `<Application Support>/EPUBs/Annotations/`. The app is sandboxed (`ENABLE_APP_SANDBOX = YES`, bundle `info.futuretextlab.origamitext`), so on macOS this is `~/Library/Containers/info.futuretextlab.origamitext/Data/Library/Application Support/EPUBs/Annotations/` | `AppModel.annotationsRoot`, `AppModel.epubsRoot` in `AppModel.swift`. visionOS has the same layout: `OrigamiVision.swift` `annotationsRoot` |
| File name | `<address>.annotations.jsonld` | `AnnotationStore.fileName(for:)` |
| Content | One W3C `AnnotationCollection`: `{"@context", "type":"AnnotationCollection", "total": n, "items":[…]}`. All items inline, no paging | `AnnotationStore.CollectionFile` |
| Load | Missing or unreadable file gives an empty list. Items sorted by `created`, oldest first | `AnnotationStore.load` |
| Save | Create the folder. **If the list is empty, delete the file.** Otherwise atomic write, pretty-printed, sorted keys, unescaped slashes. Returns false on failure. The caller beeps and shows "The annotation could not be saved to its sidecar." | `AnnotationStore.save`, `AppModel.persistAnnotations` |
| Scan all | Every `*.annotations.jsonld` in the folder, keyed by the file name without the suffix | `AnnotationStore.loadAll` |

**Where the sidecar is *not*:** never inside the `.epub` or its unpacked
folder. Unpacked books live in `<Application Support>/EPUBs/<folder>/`, the
canonical copy is `<Application Support>/EPUBs/<folder>.epub`, and the
manifest is `EPUBs/library.json`. The `Annotations` folder sits beside them,
so re-unpacking a book never loses notes. Origami Text does not read or write
annotations embedded in EPUB packages. The profile lists `annotations` and
`highlights` among the reader state that must stay outside the publication
(profile §10, interaction-record members forbidden, and §15).

**The address that keys a sidecar** (`AppModel.annotationAddress(forBook:)`)
is the book's `EPUBRecord.id`. If no record matches, it is the unpack folder
name. How `EPUBRecord.id` is chosen (`AppModel.applyPreparedImport` area,
`prepareEPUBImport`):

1. Use the `origami-id` in the book's Visual-Meta, if present (`meta.origamiID`).
2. Else the "identity key" parsed from the file name. A name like
   `Title(Author-Name-2026-07-11T09_32_52Z).epub` gives
   `LiquidAddress.makeID(author:created:)`, for example `f.hegla.093000k`
   (`LiquidDocWriting.swift` `identityKeyID(inFileName:)`, `LiquidAddress.swift`
   `makeID`).
3. Else the file name without its extension.

A re-export of the same book (same OPF `dc:identifier`, new file name) takes
over the existing record's folder **and id**, so its sidecar still applies.
A superseded book's sidecar is renamed to the successor's id on visionOS
(`OrigamiVision.swift` `retireSuperseded`).

Other sidecar-adjacent state, all in user defaults and so not portable:

- `annotationTombstones:<address>` (§3.3).
- `marginNotePositions` (an older per-device position map, by annotation id).
- `readingPosition:<folder>`.
- Bookmarks (`bookmarks:<folder>`).

### 3.2 Writing path

Every mutation follows the same steps (`AppModel.swift`):

1. Load the whole sidecar.
2. Change the list in memory (append, edit with `modified = now`, or remove by id).
3. `persistAnnotations(all, for: address)`:
   - load `previous`;
   - save;
   - on failure, beep and show the note;
   - on success, `shareAnnotations(all, previous:, for:)` (§3.3).
4. `annotationsStamp += 1`, which repaints readers and lists.

### 3.3 Sync between devices (community folder)

`AnnotationSync.swift` (macOS only). The "community folder" is a folder the
user picked (`index.folderURL`, held as a security-scoped bookmark), shared
between their devices through a file-sync service. Chapter on the library
covers it.

| File | Shape | Key |
|---|---|---|
| `<community>/_annotations/<book folder>.json` (any `/` in the folder name becomes `_`) | `{"annotations":[<WebAnnotation JSON-LD>…], "deleted":{"<annotation id>":"<ISO 8601 date>"}}`, keys sorted, not pretty-printed | **`EPUBRecord.folder`**, never `record.id`. The local id can differ between devices; the folder is the book's community identity |
| `<community>/_reading-positions.json` | `{"<book folder>": {"chapter": string?, "fraction": number, "t": ISO date}}` | book folder |
| `<community>/_seed-links.json` | `{"links": {"<book address>": {"webURL", "canonicalID", "sharedAnnotationIDs":[…]}}}` | **book address (`record.id`)**. See discrepancies, §3.6 |

**Merge rule** (`AnnotationSync.merge(a, aDeleted, b, bDeleted)`):

1. `deleted` = union of both tombstone maps. Where an id is in both, keep the
   later date.
2. `stamp(x) = x.modified ?? x.created`.
3. For each id across `a + b` (in that order), keep the version with the
   strictly newer stamp. When stamps are equal the first seen wins, which is
   the `a`/local side. Stamps have one-second resolution.
4. Drop an annotation if `deleted[id] >= stamp(annotation)`. It survives only
   if it was changed **after** it was deleted.
5. Sort by `created`.

**After a local save** (`AppModel.shareAnnotations`):

1. Tombstones += every id in `previous` but not in `all`, dated now. Persist
   them in user defaults.
2. In the background: read the community file with a **coordinated read**
   (`NSFileCoordinator`), merge, and write it back with a coordinated
   **replacing write**.
3. If the merged *id set* differs from the local one, re-save the local
   sidecar and bump the stamp.

**Adopting from other devices** (`AppModel.adoptSyncedAnnotations`):

- Runs every **4 seconds** from the root view's task loop
  (`ContentView.swift`, next to `adoptStanding()`).
- For each library record, if the community file's modification date is newer
  than the last one seen for that folder: coordinated read, merge with the
  local sidecar and local tombstones, save the local sidecar if the list
  changed, store the merged tombstones.
- Reading positions are read in the same pass.

**Reading positions out** (`scheduleSharedPositionWrite`): at most one write
every **8 s**. For each folder, the entry with the newer `t` wins. The write
is coordinated.

A portable rebuild needs:

- Any shared folder.
- An advisory lock or atomic rename in place of `NSFileCoordinator`.
- A last-seen modification time per file.

Writes must always **read, merge, then write**. Never write blind.

### 3.4 Exports and imports

All in the Annotations list's per-book context menu
(`AnnotationsListView.swift`), plus File menu items.

| Format | Shape | Code |
|---|---|---|
| **W3C AnnotationCollection** (`<title>.annotation`) | The sidecar bytes exactly as stored | `AnnotationStore.exportData`, `AnnotationsListView.exportAnnotations(for:)` |
| **W3C EPUB Annotations 1.0** (`<title>.annotations`, a zip holding `annotations.json`) | See below | `EPUBAnnotationExchange.export`, `AppModel.exportEPUBAnnotations` |
| **Markdown** (`<title> — annotations.md`) | YAML front matter (`title`, `author`, `year`, `doi`, `source: origamitext://open/<address>`, `exported`), then `# Title`, `*Author, Year*`. Each entry: the quote as `> ` lines, a blank line, the note, then a footer joined by ` · `: tags as `#Tag-Name`, `p. <page>`, `[Open in Origami Text](origamitext://open/<book>#<fragment>)`, then `---` | `AnnotationExports.markdown` |
| **Readwise CSV** | Header `Highlight,Title,Author,URL,Note,Location,Date`. Every cell double-quoted with `""` escaping. Highlight = quote, else note, else first tag. Note = note (only when there is a quote) plus tags as `.Tag-Name`. Location = print page, else `Int(progression × 10000)`. Date = `yyyy-MM-dd HH:mm:ss` (POSIX locale) | `AnnotationExports.readwiseCSV` |
| **BibTeX citation** of one annotation (Copy as Citation) | `OrigamiReading.bibTeXEntry` with `quote`, `annotation` and `address = <book>#<fragment>` | `AnnotationsListView.copyCitation` |

Markdown and Readwise share these rules (`AnnotationExports.entries`):

- `describing` annotations are skipped.
- Tagging annotations become tags with no note.
- Order is by progression; entries with no progression sort as 2, so they go
  last. Ties are broken by `created`.
- The print page comes from `OrigamiEPUBImporter.PrintPageLocator`.

**EPUB Annotations export mapping** (`EPUBAnnotationExchange.export`):

- Set:
  - `@context: https://www.w3.org/ns/epub-anno.jsonld`
  - `type: AnnotationSet`
  - fresh `id: urn:uuid:…`
  - `generated`
  - `about {dc:title, dc:creator[], dc:date?, dc:identifier?}`, from
    `BookInformation.read`
- Items. `describing` annotations are skipped. For each other annotation:
  - `target.source` = the container-relative content document
    (`ContentLocator.locate`). A `path#id` is joined to the OPF directory. A
    bare id is found by scanning the spine documents for `id="…"`; if not
    found, the first spine document is used.
  - Selector: if there is an element id, a `FragmentSelector`
    (`conformsTo: http://tools.ietf.org/rfc/rfc3236`, `value: id`), with
    `refinedBy` a text-fragment selector when there is a quote. With no id, the
    text-fragment selector alone.
  - Text-fragment selector: `FragmentSelector`,
    `conformsTo https://wicg.github.io/scroll-to-text-fragment/`,
    `value ":~:text=" + [prefix-,]exact[,-suffix]`.
    - Each part is percent-encoded with `,`, `-` and `&` also escaped.
    - The prefix is cut to its last 40 characters and the suffix to its first 40.
  - `motivation` is always `highlighting`.
  - `body`:
    - `type: TextualBody`
    - `value`: the note when the motivation is `commenting`, else `""`
    - `color`: from the kind table
    - `highlight`: `"strikethrough"` or `"solid"`
    - `tags`: `[kind]` for any kind except Highlight
  - `creator`, when present: `{id: "urn:origami-text:reader", type: Person, name}`.

**EPUB Annotations import** (`EPUBAnnotationExchange.read`,
`AppModel.importEPUBAnnotations`):

- Accepts a zip (starts with `PK`) holding `annotations.json`, or bare JSON.
- Walks selectors and their `refinedBy` chains:
  - an RFC 3236 fragment becomes `.fragment(value, data-id conformsTo)`;
  - a text fragment is parsed (`parseTextDirective`) into a quote. A
    `start,end` range becomes `start + "…" + end`.
- Motivation: a non-empty note gives `commenting`; else a known tag other
  than Highlight gives `tagging`; else `highlighting`. `highlight:
  "strikethrough"` with no tag gives Strikethrough.
- Matching the book: by `dc:identifier` (`libraryRecord(forIdentity:)`), else
  by title (case- and diacritic-insensitive), else the open book.
- Annotations whose ids are already in the sidecar are skipped.

### 3.5 The cross-document view

Views ▸ Annotations (`AnnotationsListView`) reads `allAnnotations` (cached per
stamp):

- Groups by book. The book with the newest annotation comes first.
- Within a book, sorted by progression (none counts as 2), then `created`.
- Find searches the quote, the note, the creator and the book title.
- Clicking a row opens the book at the first fragment
  (`AppModel.openAnnotation`).

`NotesListView.swift` is **not** about annotations. It lists "notes", which
are small standalone documents (drafts or arrivals through the community
folder), filtered and filed like other documents.

### 3.6 Discrepancies found in storage

1. `_seed-links.json` is keyed by `record.id` and written with a plain atomic
   write, not a coordinated one. This breaks the standing rule "shared per-book
   files key by `record.folder`; coordinated access only".
2. Imported EPUB-Annotations items keep their foreign `target.source`, a
   content-document path such as `OEBPS/ch1.xhtml`, not
   `origamitext://open/<address>`. One sidecar can therefore hold two source
   forms.
3. An imported `start…end` quote cannot match exactly, and the WebView reader
   will only find it if the literal "…" is in the text. In practice it falls
   back to the element id.
4. `shareAnnotations` re-saves locally only when the **id set** changes. A
   newer remote edit to an existing id reaches this device on the next
   4-second adopt pass, not at once.
5. `KnowledgeSpaceAnchoring.swift` has nothing to do with Web Annotation
   anchoring. It is visionOS-only (`#if os(visionOS)`). It persists 3D node
   placements as ARKit world anchors (concept id → anchor UUID in user
   defaults key `knowledgeSpace.anchors`) and snaps dropped cards to detected
   planes:
   - snap only within 0.5 m perpendicular and 3 m laterally;
   - score = |perpendicular| + 0.3 × lateral;
   - offset 5 mm off the surface;
   - a card on a horizontal surface (|normal·up| > 0.85) is turned so its text
     top points away from the viewer.

   A portable equivalent is any persistent spatial anchor API (ARCore Cloud
   Anchors, OpenXR spatial anchors).

---

## 4. Document identity: what Origami Text writes vs the OrigamiFormat rule

### 4.1 What Origami Text writes today

| Context | Identifier written | Source |
|---|---|---|
| Annotation `target.source` (every local annotation) | `origamitext://open/<address>`. `<address>` is the `EPUBRecord.id` (Visual-Meta `origami-id`, else file-name identity key such as `f.hegla.093000k`, else file name), or the unpack folder | `AppModel.addAnnotation`, `AnnotationAnchor.target`, `setDocumentAnnotation`, `addMarginNote`, `floatSelection` |
| Sidecar file name | `<address>.annotations.jsonld` | `AnnotationStore.fileName` |
| Community sync file | `_annotations/<record.folder>.json` | `AnnotationSync.url(forBookFolder:in:)` |
| Paragraph links and Markdown links | `origamitext://open/<address>#<fragment>`. A `#` inside the fragment is percent-encoded | `OrigamiCitation.openURL` in `OrigamiReading.swift`, `AppModel.paragraphLink` |
| Hypothesis canonical URI (defined, **never called**) | `https://doi.org/<doi>`, else `https://origamitext.app/epub/<percent-encoded package dc:identifier>`, else nil | `HypothesisClient.canonicalURI(for:)` |
| Gemini documents | Document id `g.gmi.<first 10 hex of SHA-256(key)>`. The key is the canonical URL, or `"sha256:" + SHA-256(source)` for local files | `GemtextStore.documentID(forKey:)` in `GemtextSources.swift` |
| Seed documents | Kept in memory under the canonical `hm://uid/path`. The converted document gets a fresh `LiquidAddress` id and `sourceURL = hm://…` | `AppModel.presentHypermedia` |

So **Origami Text writes neither DOIs nor content hashes into annotation
targets.** It writes its own local address under its own historical URL scheme.

### 4.2 The OrigamiFormat package rule

`~/Documents/OrigamiFormat/Sources/OrigamiFormat/DocumentIdentity.swift`,
`DocumentIdentity.canonical(doi:contentHash:localName:)`:

1. `https://doi.org/<bare DOI>` when there is a DOI.
2. `urn:origami:sha256:<lowercase hex>` when a 64-hex content hash is given,
   or when `localName` itself is 64 hex digits.
3. `urn:origami:local:<localName>`.
4. `""` when there is nothing.

Reading is more generous than writing. `normalised(_:)` folds onto one
comparison key:

- any DOI spelling (`https://doi.org/`, `http://dx.doi.org/`, `doi:`, or a
  bare `10.…` when the whole string is a DOI) becomes `doi:<bare>`;
- `urn:origami:sha256:` becomes `sha256:`;
- `urn:origami:local:` becomes `local:`;
- legacy `urn:x-reader:<x>` and **legacy `origamitext://open/<x>`** become
  `sha256:<x>` if `x` is 64 hex digits, else `local:<x>`;
- anything else is lowercased.

`isSameDocument(a, b)` compares the normalised keys. A rebuild must compare
targets this way, never as raw strings.

### 4.3 Where they diverge

| Aspect | Origami Text (in this repo) | OrigamiFormat package |
|---|---|---|
| Target IRI written | `origamitext://open/<address>` | DOI URL, then `urn:origami:sha256:`, then `urn:origami:local:` |
| Same-document test | String equality of sidecar key (address) | `DocumentIdentity.isSameDocument` |
| Selectors | fragment, quote, position, progression | Same, plus `.page(n)`, written as `FragmentSelector {value:"page=7", conformsTo:"http://tools.ietf.org/rfc/rfc8118"}` |
| Extensions | `origami:placement`, `origami:float` | Same, plus `reader:place` (schema.org Place: `{type:"Place", name, latitude?, longitude?}`) |
| Body purpose on passage notes | none for comments | `passageNote` writes `purpose:"commenting"` |
| `sameElement` (bare id vs `path#id` bridge) | Yes | **No.** The package resolves fragments by exact id only |
| Store | load/save/loadAll/exportData, fixed folder | Adds `append`/`update`/`remove`, optional folder, security-scoped access |
| Anchor input | `LiquidDoc` | `[AnchoredParagraph(id, text)]` |

**Round-trip hazards today:**

- A package-written sidecar opened in Origami Text loses `reader:place` the
  next time Origami Text saves that book. The decoder drops unknown keys.
- A page selector becomes `.fragment("page=7")` and never resolves, so the
  annotation shows as unanchored.
- Package-written targets (`https://doi.org/…`) are not compared with
  Origami Text's `origamitext://open/…`, because Origami Text keys sidecars by
  file name, not by target.

The migration README states one remaining gap even after migration. Origami
Text would write the DOI when there is one, but a *local* name otherwise,
while Reader names a book with no DOI by its content hash. To close it,
Origami Text must hash the opened file and pass `contentHash:`.

**Recommendation for a rebuild:**

- Write `DocumentIdentity.canonical(doi: record.doi, contentHash:
  sha256(<canonical .epub bytes>), localName: record.id)`.
- Read every historical form through `normalised`.
- Keep sidecar *file names* keyed by the local address, so existing files
  still open.
- Carry unknown top-level keys through save untouched, so other apps'
  extensions survive.

---

## 5. Network integrations

### 5.1 Hypothesis

Status: **Phase 1 only.** That means auth UI, the `packageIdentifier` field
and the stubs. Nothing is pushed or fetched. See
[hypothesis-integration-plan.md](../hypothesis-integration-plan.md) for the
planned codec (FragmentSelector and ProgressionSelector dropped, `origami-kind:`
tags, `https://hypothes.is/a/<id>` ids, deduplication via `HypothesisIDMap`)
and its open DOI-equivalence spike (Phase 0).

| Item | Value | Source |
|---|---|---|
| Base URL | `https://api.hypothes.is` | `HypothesisClient.baseURL` |
| Validate token | `GET /api/profile` with `Authorization: Bearer <token>`. 401 → `invalidToken`. Non-200 → `httpError`. Display name = `userid` without `acct:` and without `@authority` | `HypothesisClient.validateToken` |
| Token storage | Keychain internet password, server `com.origamitext.hypermedia.https://api.hypothes.is`, account = username | `HypermediaKeychain`, `AppSettings.hypothesisService` (`SettingsView.swift`) |
| Username | user defaults `hypothesis.username` | `AppSettings.hypothesisUsernameKey` |
| "Show public annotations" toggle | user defaults `hypothesis.publicAnnotationsEnabled`. **Stored, but nothing reads it to fetch** | `HypermediaSession.hypothesisPublicEnabled` |
| Community annotations | `HypermediaSession.communityAnnotations`, always empty today | — |

Launch behaviour: `restoreHypothesisSession()` reads only the username from
preferences and shows "signed in". The token is read from the Keychain only
when `hypothesisToken()` is called for a request. Nothing calls it yet.

### 5.2 Seed Hypermedia (`hm://`)

Files: `HypermediaFetcher.swift` (read), `HypermediaBlobs.swift` (sign and
publish), `HypermediaSpaces.swift` (followed spaces, account, comments),
`HypermediaSession.swift` (Keychain), `HypermediaOpen.swift` (into the
reader), `HypermediaSpaceListView.swift` and `HypermediaCommentsView.swift`
(UI), plus the Seed-link code in `AppModel.swift` (`SeedLink`, `linkSeed`,
`shareAnnotationsToSeed`).

**Addresses** (`HypermediaAddress.parse`):

- Forms:
  - `hm://<uid>/<path…>?v=<version>#<block>`
  - gateway form `https://<host>/hm/<uid>/<path…>`. Here `origin` is the host.
    The first segment must not be one of `download, connect, register,
    profile, contact, api`.
- `canonicalID` = `hm://uid[/path]`.
- The block fragment may be `id`, `id+` or `id[3:9]`. Only `id` is kept
  (`blockID(fromFragment:)`).
- Space domains are normalised to lowercase host only (`normalizeDomain`).

**Reading.** No auth. JSON responses are SuperJSON-wrapped, and the `json`
member is the payload.

| Call | Request | Use |
|---|---|---|
| Who is this space | `OPTIONS https://<domain>/`, timeout 20 s. Read headers `x-hypermedia-id` (an `hm://uid`) and `x-hypermedia-title` (percent-decoded). No header or a non-2xx status → "not a space" | `resolveSpace` |
| Web URL to `hm://` (second way) | `GET <origin>/hm/api/config` gives `registeredAccountUid`, cached per host for the session. Address = `hm://<uid>/<URL path>` | `resolveViaConfig` |
| List documents | `GET /api/Query?includes=[{"space":"<uid>","path":"","mode":"AllDescendants"}]&sort=[{"term":"updated","reverse":true}]`. Entries that "moved away" are dropped (`redirectInfo` without `republish`) | `listDocuments` |
| One document | `GET /api/Resource?id=<canonical[?v=version]>`. `type` is one of `document`, `redirect` (followed **once** only), `not-found`, `comment`, `tombstone`, `error` | `fetch(address:origin:)` |
| Author names | `GET /api/Account?…`, cached per space. Names are joined; zero names gives "Unknown" | `accountName`, `authorName` |
| Comments | `GET /api/ListComments?targetId=<JSON {id,uid,path[],version:null,blockRef:null,blockRange:null,hostname:null,scheme:"hm",latest:true}>` | `listComments` |
| Files | `ipfs://<cid>` becomes `<origin>/hm/api/file/<cid>` | `fileURL(for:origin:)` |

All GETs send `Accept: application/json` with a 30 s timeout. Non-2xx is
`httpError`.

**Resolution order for a bare `hm://` address** (`fetch(urlString:spaces:)`):

1. Followed spaces whose uid matches.
2. Then the other followed spaces.
3. Then the gateway `hyper.media`.

`notFound` moves on to the next origin. Any other error is remembered. A
non-`hm` web URL is resolved through its OPTIONS headers, else through the
site config. The URL's own `?v=` and `#fragment` still apply.

**Converting a document to paragraphs** (`convert`, `paragraphs(from:origin:)`).
Walk the block tree depth-first:

- **The paragraph id is the block id**, so `hm://uid/path#block` and
  `<docID>#block` map onto each other. A block with no id gets `p<n>`.
- `Heading`: heading level from `attributes.level`, clamped to 1–3.
- `Paragraph`: text.
- `Code`: a fenced block with the language.
- `Math`: `$$…$$`.
- `Image`, `Video`, `File`: `[caption](fileURL)`.
- `Embed`: `[label](link)`.
- Anything else: its text, or `[Type: link]`.
- Empty paragraphs are skipped.

Inline annotations become Markdown: Bold `**`, Italic `_`, Strike `~~`, Code
`` ` ``, Link and Embed `[…](…)`. **Offsets count Unicode scalars**
(`renderText`).

**In the reader** (`HypermediaOpen.swift`):

- The converted document gets a new `LiquidAddress.makeID` id, with
  collisions checked against the index, drafts and the cache.
- `sourceURL` = canonical `hm://`.
- It is **never written to disk**.
- `HypermediaSpaces.cacheDocument` keeps at most **24** documents (oldest
  evicted), with origin and version per document.
- `hm://` links and gateway URLs are claimed by `AppModel.claimLink` in
  `RemoteEPUB.swift`.

**Account and signing** (`HypermediaBlobs.swift`, `HypermediaSpaces.swift`):

- **Identity.** An Ed25519 key (`Curve25519.Signing`).
  - `principal` = `0xED 0x01` + 32-byte public key.
  - `uid` = multibase base58btc: `"z" + base58(principal)`, which starts
    `z6Mk…`.
  - Only the 32-byte seed is stored: Keychain internet password, server
    `com.origamitext.hypermedia.hypermedia.identity`, account `signing-key`,
    value base64.
  - The uid and name are also kept in user defaults (`hypermedia.account.uid`,
    `hypermedia.account.name`), so "signed in" can be shown without the
    Keychain.
- **Sign in to an existing account** (`HypermediaSignIn.candidates`).
  - Accepts a key as hex, base64, base64url or base58. The bytes may be a
    32-byte seed, a 64-byte seed‖public key (self-checking), a libp2p
    protobuf or multicodec `ed25519-priv`.
  - Or a 12-word BIP-39 phrase: PBKDF2-HMAC-SHA512, 2048 rounds, salt
    `"mnemonic"`, 64 bytes. Two candidates are derived, the first 32 bytes and
    the SLIP-0010 master key (HMAC-SHA512 key "ed25519 seed", left half). Both
    addresses are shown and the user confirms which one. Unclear from source
    which one Seed uses; the code says so.
- **DAG-CBOR** (`CBORValue`):
  - map keys sorted shortest first, then bytewise;
  - integers in shortest form;
  - CIDs as tag 42 over their bytes.
- **CID** = `0x01 0x71 0x12 0x20` + SHA-256(bytes), written as multibase
  base32 lowercase without padding, prefix `b` (`bafy…`).
- **Signing** (`HypermediaBlobs.sign`):
  1. Remove any `sig`/`signer` fields.
  2. Append `signer: principal` and `sig: 64 zero bytes`.
  3. Encode, then sign the encoding with Ed25519.
  4. Replace `sig` with the signature and encode again.
- **Profile blob:** `{type:"Profile", name, ts: ms since epoch}` + signer/sig.
  - Published to every followed space plus `https://hyper.media`.
  - Account creation fails only if **no** destination accepts it.
- **Comment blob** (`HypermediaBlobs.comment`):
  - Fields:
    - `type:"Comment"`
    - `body: [{id: random 8-char [A-Za-z0-9], type:"Paragraph", text, annotations:[], children:[]}…]`, one per paragraph split on blank lines
    - `space: principal(fromUID: doc uid)`
    - `path: "/a/b"` or `""`
    - `version: [CID…]`, the document version split on `.`
    - `ts`
  - For a reply, add `replyParent: CID` and `threadRoot: CID`.
  - **The document version is required.** If it is not known in this session,
    the document is fetched quietly first.
- **Publish:** `POST <origin>/api/PublishBlobs`, `Content-Type:
  application/cbor`, body = CBOR `{blobs:[{cid: string, data: bytes}…]}`.
  Non-2xx → `serverError(<response text>)`.
- **Record id** after posting = `uid + "/" + base58btc(6-byte big-endian ts ‖ first 4 bytes of SHA-256(blob))`.

**Comment threads** (`listComments`):

- Comments are nested by `replyParent`. They are attached deepest first.
- Replies are sorted oldest first and top-level comments newest first.
- A missing author name shows the first 8 characters of the uid.

**Annotations to Seed** (`AppModel.linkSeed`, `shareAnnotationsToSeed`):

1. Connect: paste the document's web URL. It resolves to the canonical
   `hm://`. Origin and version are remembered, and a `SeedLink` is stored in
   `_seed-links.json`.
2. Share: for each annotation on the book whose id is not yet in
   `sharedAnnotationIDs`, post one top-level comment:
   `“<quote>”\n<note>\n— shared from Origami Text`. Annotations with neither
   quote nor note are skipped.
3. Each id is recorded **as soon as its comment posts**, so a failure part-way
   keeps what was said. Re-sharing posts only new annotations.

There is also `shareDocumentAnnotationToSeed`, which posts the document note
of a document that came from a space.

Space list and persistence:

- Followed spaces are stored in user defaults `hypermedia.spaces` as JSON
  `[{domain, uid, title}]`.
- Listings and comments are kept in memory per session.
- Following a space publishes the profile there (best effort) if an account
  exists.

### 5.3 Gemini and gemtext

Files: `GeminiClient.swift` (protocol), `Gemtext.swift` (format),
`GemtextOpen.swift` (into the library), `GemtextSources.swift` (provenance
store).

**Protocol** (`GeminiClient`):

- TLS ≥ 1.2 over TCP, default port **1965**.
- SNI is set to the host.
- Request = absolute URL without fragment (and without `:1965`) + CRLF.
  At most **1024** bytes.
- Response header = `<2 digits><space><META>CRLF`, read with at most
  1030 bytes. A bare LF is accepted.
- The body runs until the server closes, capped at **10 MiB**. A close without
  TLS close-notify sets `truncated`, which is recorded and not fatal.
- Timeouts: connect 10 s, total 30 s.

| Status class | Behaviour |
|---|---|
| 1x (10, 11) | Return the response. The app prompts (11 = secure entry) and re-requests with the answer as the percent-encoded query (`GeminiClient.url(_:answering:)`) |
| 2x | Success. An empty META means `text/gemini`. MIME params `charset` (default UTF-8) and `lang` |
| 3x | Redirect resolved against the current URL. Up to **5** hops, with loop detection. A non-`gemini` target stops with `crossSchemeRedirect` until the user confirms "Follow" |
| 4x / 5x | Temporary or permanent failure, with META shown |
| 6x | Client certificate required. Not supported |

**TLS trust-on-first-use** (`GeminiTrustStore`, `tlsOptions`):

1. System validation is replaced. The verify block always completes `true` and
   records the leaf certificate's **SHA-256 of DER** (lowercase hex) and its
   `notAfter`.
2. After the handshake and **before sending any request byte**, evaluate
   against pins keyed `host:port`:
   - unknown host: pin it (`firstSeen`, `lastSeen`, `notAfter`);
   - same fingerprint: update `lastSeen`;
   - different fingerprint: raise `certificateChanged(Mismatch{stored, offered})`.
3. On a mismatch the app shows both fingerprints (`confirmNewCertificate`). If
   the user accepts, the request is retried with `trustingNewCertificateFor:
   host`. The pin is replaced and `firstSeen` restarts.
4. Pins are stored at `<Application Support>/Gemtext/gemini-trust.json`:
   pretty-printed, sorted keys, ISO dates, `{"host:port": Pin}`.

**Gemtext parse** (`Gemtext.tokenize`). Lenient on input, strict on output.
One pass, no lookahead:

1. Strip a BOM. CRLF becomes LF. A final newline ends the last line and does
   not add an empty one.
2. Inside a preformatted block, only a line starting with ` ``` ` toggles out.
   Every other line is verbatim.
3. Each line is classified by its prefix:

| Prefix | Line type |
|---|---|
| ` ``` ` | Toggle into preformatted. Alt text = the rest of the line, trimmed |
| `=>` | Link: whitespace, URL (non-whitespace), optional label. An empty URL makes it a text line |
| `#`, `##`, `###` | Heading. The space after the hashes is optional. `####` is text |
| `* ` exactly | List item |
| `>` | Quote. One leading space is dropped |
| whitespace only | Blank |
| anything else | Text |

4. A preformatted block left open at end of file is closed.

**Assembly into paragraphs** (`Gemtext.assemble`):

- One source line is one block. Ids are `gmi-L<n>`, where n is the 1-based
  line number the block starts on (the opening fence for preformatted blocks).
- Blank lines produce no block.
- List items become `* text`, quotes `> text`, links `[label](resolved URL)`.
  Relative URLs are resolved against the fetched URL or the containing folder.
- A preformatted block becomes ` ```alt\n…\n``` `.
- A leading H1 becomes the title and leaves the body.
- Digests:
  - `sourceDigest` = SHA-256 of the raw source;
  - `contentDigest` = SHA-256 of the blocks joined as `id\theading\ttext` with
    newlines (`OrigamiMath.sha256Hex`).

**Into the library** (`GemtextOpen.shelve`):

1. Identity key = canonical URL (`GemtextStore.canonical`: lowercase scheme and
   host, drop `:1965`, drop the fragment), or `sha256:<sourceDigest>` for files.
2. Reuse the registry's document id and `firstReadAt` when they exist.
   Otherwise the id is `g.gmi.<10 hex>`.
3. Build a document with `documentType = external` and `sourceURL`.
4. Export it to an EPUB, then import that EPUB with `dedupe: false`.
5. Record a `GemtextSource` in `<Application Support>/Gemtext/gemini-sources.json`
   and keep the raw bytes as `<Application Support>/Gemtext/<documentID>.gmi`.
   The source records documentID, sourceURL, both digests, title, readAt,
   firstReadAt, charset, language, tlsFingerprint and truncated.

Other cases:

- A non-gemtext `text/*` response becomes one preformatted block under a
  heading.
- EPUB responses join the shelf through `openLinkedEPUB`.
- Anything else is offered as a save to disk.

Because ids come from line numbers, **annotations on a gemtext page re-anchor
by fragment as long as the line numbering holds, and by quote after edits.**

**Export** (`Gemtext.export`):

- UTF-8, LF line endings, no BOM.
- A `# Title` line unless the body already opens with it.
- One long line per paragraph.
- Inline links unfold to `=>` lines after their paragraph, deduplicated.
- Emphasis loses its markers.
- Tables and math become preformatted blocks.
- References follow.
- The Visual-Meta appendix is the **final preformatted block**.
- Blank lines between blocks are put back from the `gmi-L` line numbers.
- An **unedited** gemtext import (`contentDigest` unchanged,
  `GemtextSource.matches`) re-exports the stored raw bytes byte for byte.

### 5.4 Letter post (Apple Mail carrier)

`LetterPost.swift`. Published letters (`.origamitext` files) travel between
community members over the user's own email, with no server.

**Carrier.** `Off` (the default) or `Apple Mail`. Stored in user defaults
`letterPostCarrier`.

**Send timing** (`letterPostSendTiming`):

- `When published` (the default)
- `Daily at a set time`
- `Weekly on a set day`
- `Monthly on a set day` (day 1–28)
- `Only manually`

The time is stored as minutes from midnight in `letterPostSendTime`, the
weekday 1–7 (Sunday = 1) in `letterPostSendWeekday`, and the day of month in
`letterPostSendMonthDay`.

**Sending** (`MailCarrier.send`):

- AppleScript builds an outgoing message:
  - the subject;
  - the body plus a blank line;
  - To = the letter's "for the attention of" names that have email addresses
    in People; everyone in the directory if there are none;
  - CC = everyone else in People who is in the letter distribution, except the
    author;
  - the `.origamitext` file attached;
  - `delay 1`, then `send`.
- The queue (`letterPostPendingSends`) holds document ids. A letter leaves the
  queue only when Mail accepts it.

**Receiving** (`MailCarrier.receiveLetters`):

- Inbox messages from the last **14** days.
- Each attachment whose name ends `.origamitext` and is not already in the
  folder is saved by **Mail itself** into the community folder.
- The folder watcher picks it up from there.

**Scheduler:**

- A 60-second tick, idle while the carrier is Off.
- The scheduled send fires when the latest scheduled moment has passed with no
  send since (`letterPostLastDailySend`), so a missed time catches up.
- The receive check runs every `letterPostReceiveInterval` minutes (default
  30; 0 = manual only).

Portable equivalent: SMTP to send and IMAP to receive with a user-supplied
account. Or any mail client automation. The data contract is only "one
message per letter, file attached, file named `*.origamitext`".

### 5.5 Fetch by DOI or URL

`FetchOnline.swift` (`OnlineFetch`, `AppModel.fetchOnlineDocument`). File ▸
Fetch by DOI or URL…

1. **Parse the input:**
   - DOI: bare, `doi.org` link, or inside a publisher URL path;
   - arXiv id;
   - or a direct `http(s)` URL.
   Anything else is `notUnderstood`.
2. **Every request** sends `User-Agent: OrigamiText/1.0 (https://futuretextlab.info; mailto:info@futuretextlab.info)`, as Crossref and OpenAlex ask.
3. **With a DOI:**
   - `GET https://api.crossref.org/works/<doi>` for title, authors
     (given + family) and year (`published.date-parts`). If Crossref fails
     and there is no arXiv id, stop with `notFound`.
   - `GET https://api.openalex.org/works/doi:<doi>` for `open_access.is_oa`
     and `oa_status`. For each `locations[]` with `is_oa`:
     - if a PMCID appears in `landing_page_url` or `pdf_url`, add Europe PMC
       JATS `https://www.ebi.ac.uk/europepmc/webservices/rest/<PMCID>/fullTextXML`;
     - add `pdf_url`, with its kind taken from the extension.
4. **With an arXiv id:**
   - add `https://arxiv.org/pdf/<id>` and mark it open;
   - read title and authors from `https://export.arxiv.org/api/query?id_list=<id>`.
5. A direct link ending `.pdf`, `.epub`, `.xml` or `.zip` is added as a source.
6. **Order:** JATS XML, then EPUB, then LaTeX zip, then PDF. Duplicate URLs are
   removed.
7. **Download:** try each source in order and accept only:
   - HTTP 200;
   - no `<!doctype html` or `<html` in the first 1 KiB, since challenge pages
     are rejected;
   - a PDF starting `%PDF`;
   - an EPUB or zip starting `PK`;
   - XML containing `<` and longer than 512 bytes.

   The file is saved to `tmp/OrigamiFetch/<doi with / → _ or UUID>.<ext>` and
   handed to the normal importer.
8. Failures give clear alerts: "Not Open Access" or "The Publisher Refused",
   with a link to the landing page. **No challenge or paywall is ever worked
   around.**

### 5.6 Calendar

`CalendarFeed.swift`, `CalendarEventsView.swift`. **Compiled out in this
release.** Both files are wrapped in `#if ORIGAMI_CALENDAR`
(`TEST-PLAN-2026-09-27.md`: "Calendar and Contacts: decided — neither for
now").

When enabled:

- One shared read-only `EKEventStore`.
- `begin()` asks for full event access once, **on first use, not at launch**.
- It loads events from one year back to one year ahead, as plain values:
  - `id` = event identifier + `@` + start time (so the occurrences of a
    repeating event are told apart);
  - title (empty becomes "New Event");
  - start and end;
  - all-day flag;
  - location;
  - calendar name and colour.
- It reloads on `EKEventStoreChanged`.
- The view lists events by day, scrolls to today and dims past days.

Portable equivalent: CalDAV, or reading `.ics` files.

### 5.7 Data series

`DataSeriesFetcher.swift`, ported from Liquid Information. Called from
`SeriesPlanner.swift`, where an on-device model plans *what* to fetch. "The
on-device model only plans what to fetch and never handles the data itself."
None of these endpoints needs a key.

| Series | Endpoint | Mapping |
|---|---|---|
| Daily weather | Geocode `https://geocoding-api.open-meteo.com/v1/search`, then `https://archive-api.open-meteo.com/v1/archive?latitude&longitude&start_date&end_date&daily=<var>&timezone=auto`. The end date is clamped to the archive's window | `temperature_2m_mean/max/min` (°C), `precipitation_sum` (mm), `snowfall_sum` (cm), `wind_speed_10m_max` (km/h) |
| Market close | `https://query1.finance.yahoo.com/v8/finance/chart/<symbol>?period1&period2=<end+86400>&interval=1d`, `User-Agent: Mozilla/5.0` | Closing price. The unit is "points" for `^` indices, else the currency. Subject-to-symbol table (`marketSymbol`): ^IXIC, ^GSPC, BTC-USD, GC=F, EURUSD=X … |
| Country statistic | `https://api.worldbank.org/v2/country/<ISO2>/indicator/<id>` | SP.POP.TOTL, NY.GDP.MKTP.CD, SP.DYN.LE00.IN, FP.CPI.TOTL.ZG |
| Solar activity | `https://services.swpc.noaa.gov/json/solar-cycle/observed-solar-cycle-indices.json` | `ssn` (sunspots), `f10.7` (sfu) |

Results are thinned to at most **90** points by `downsampled`: buckets of
`ceil(n/90)` points, mean value, the middle point's date and label. Non-200
responses → `badResponse(host)`.

Discrepancy: the type's doc comment says "Stooq for market data", but the code
calls Yahoo Finance.

### 5.8 Summary of endpoints

| Service | Host(s) | Auth | Trigger |
|---|---|---|---|
| Hypothesis | api.hypothes.is | Bearer token (Keychain) | Settings ▸ Hypermedia, Connect |
| Seed read | any space, hyper.media | none | user opens a space, link or URL |
| Seed write | the document's space, hyper.media | Ed25519 signature (seed in Keychain) | user posts a comment, shares, creates an account or follows a space |
| Gemini | any capsule:1965 | TOFU pin | user opens a gemini:// address |
| Crossref, OpenAlex, Europe PMC, arXiv | as listed | none, polite UA | File ▸ Fetch by DOI or URL |
| Open-Meteo, Yahoo, World Bank, NOAA | as listed | none | data-series planner |
| Mail | local Apple Mail | macOS Automation permission | carrier switched on |
| Calendar | local EventKit | Calendar permission | compiled out |

### 5.9 The launch rule: no network or Keychain prompts at startup

This is a standing product rule: nothing at launch may ask to join or sign in
to a network, or raise a Keychain or permission panel. How the code keeps it:

- `HypermediaSession.init` → `restoreHypothesisSession()` reads only the
  username from preferences. The token comes from the Keychain only in
  `hypothesisToken()`.
- `HypermediaSpaces.init` reads only the space list from preferences.
  `hasAccount`, `accountUID` and `accountName` come from preferences.
  `loadIdentity()` is "the only call that can raise the Keychain panel" and is
  reached only from signing, publishing or showing the key.
- `GeminiTrustStore` reads a local JSON file. No network.
- `LetterPostStore`'s first tick is 60 s after attach, and does nothing while
  the carrier is Off (the default). Apple-event permission is asked only after
  the user turns Mail on.
- `CalendarFeed.begin()` asks for access on first use, and it is compiled out
  anyway.
- Annotation sync touches only the local community folder (a
  security-scoped bookmark), not the network.

A rebuild must keep the same split: **cheap public facts (username, uid,
display name) in plain preferences; secrets fetched lazily at the moment of
use.**

---

## 6. Platform notes and portable equivalents

| Apple piece | Used for | Portable equivalent |
|---|---|---|
| `Codable` hand-written JSON-LD | `WebAnnotation` coding | Any JSON library. Keep `@context` on every item, the exact `type` strings, a lenient single-or-array selector, and skip unknown selectors and items |
| `String.range(of:options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])` and `folding(…, en_US_POSIX)` | Span matching | Unicode NFKD, strip combining marks (Mn), case-fold (ICU `ucol` at primary strength, or `unicodedata` + `casefold`) |
| Swift `Character` (grapheme) indexing | Offsets in `position` and `fuzzyMatch` | Use grapheme clusters (ICU BreakIterator, `grapheme` libraries) so offsets agree with existing files |
| `ISO8601DateFormatter` `.withInternetDateTime` | Dates | RFC 3339 with `Z` and whole seconds on write. Accept fractions on read (`LiquidDoc.parseISO8601`) |
| `FileManager` Application Support plus app sandbox container | Sidecar root | XDG data dir / `%APPDATA%` / app-private storage |
| `NSFileCoordinator` | Community-folder reads and writes | Write to a temp file then rename atomically, plus an advisory lock file. Always read, merge, write |
| `UserDefaults` | Tombstones, kind styles, spaces, settings | A local JSON or SQLite settings store. **Move tombstones into the sidecar** in a rebuild, so they travel with backups |
| `startAccessingSecurityScopedResource` | Community folder access | Not needed outside the sandbox |
| WKWebView + CSS Custom Highlight API + `webkit.messageHandlers` | Painting in the EPUB reader | Any web view. `CSS.highlights` is in Chromium and Firefox; otherwise wrap ranges in `<mark>` |
| Keychain (`SecItem…`, internet password) | Hypothesis token, Ed25519 seed | Credential Manager / libsecret / Android Keystore. Read lazily |
| CryptoKit `Curve25519.Signing`, `SHA256` | Seed identity, CIDs | libsodium / ed25519-dalek / tweetnacl, any SHA-256 |
| CommonCrypto PBKDF2 / HMAC | BIP-39 / SLIP-0010 | Any crypto library |
| Network.framework `NWConnection` + `sec_protocol_options_set_verify_block` | Gemini TLS with TOFU | OpenSSL/rustls/Go `crypto/tls` with `InsecureSkipVerify` and your own fingerprint check **before** writing the request |
| URLSession | HTTP | Any HTTP client. Keep the timeouts (20 s OPTIONS, 30 s GET/POST) |
| `NSSavePanel`/`NSOpenPanel` | Export and import | Native file dialogs |
| AppleScript to Mail | Letter post | SMTP/IMAP |
| EventKit | Calendar | CalDAV / ICS |
| ARKit world anchors, plane detection | `KnowledgeSpaceAnchoring` (visionOS) | OpenXR spatial anchors, ARCore |
| `ZipWriter`/`ZipReader` (in-repo) | `.annotations` packages | Any zip library (stored or deflated) |

---

## 7. Rebuild order and acceptance checks

### 7.1 Order

1. **Model and coding.** `WebAnnotation`, its selectors, the two extensions
   and `ReaderAnnotationKind`, with lenient decoding. Preserve unknown keys
   (an improvement over the current code).
2. **Store.** `AnnotationStore` sidecars in `<data>/EPUBs/Annotations/`.
   Delete when empty, atomic writes, fail loudly.
3. **Target builder and resolve cascade** (§2.5–2.6), with `sameElement` and
   `fuzzyMatch`. Prefer porting the package's `[AnchoredParagraph]` version
   and adding `sameElement`.
4. **Reader integration.** Selection capture (id, ≤32-character context), the
   create actions in the §2.3 table, painting, click to edit, orphan marking.
   Run the *same* cascade in every reading mode.
5. **Document identity.** Write per the OrigamiFormat rule. Read all legacy
   forms through `normalised`. Keep sidecar file names keyed by local address.
6. **Sync.** Community `_annotations/<folder>.json` with tombstones, the merge
   rule, the 4-second adopt loop, reading positions with an 8-second throttle.
7. **Exports and imports.** AnnotationCollection, EPUB Annotations
   (export and import), Markdown, Readwise CSV, BibTeX.
8. **Gemini/gemtext.** Tokenizer, assembler with `gmi-L` ids, TOFU client,
   source registry, export with verbatim pass-through.
9. **Seed.** Read path (OPTIONS, Query, Resource, ListComments). Then
   DAG-CBOR, CID, Ed25519 signing, profile, comments, Seed links and sharing.
10. **Fetch by DOI, data series, letter post, Hypothesis** (Phase 2 onwards per
    the plan), and calendar if wanted.

### 7.2 Acceptance checks

**Model and store**

| # | Check | Pass when |
|---|---|---|
| A1 | Round-trip: decode the §2.4 example, encode, decode | Every field, including `origami:placement`, is equal. Output has `@context` on the collection and each item, `type` strings exact, `format: text/plain` on bodies |
| A2 | Single-object `selector` | Decodes as a one-item list |
| A3 | Unknown selector `{"type":"CssSelector"}` among others | Skipped. The others remain |
| A4 | One corrupt item among good ones | Only that item is dropped |
| A5 | Save an empty list | The sidecar file is deleted |
| A6 | Missing `id`/`motivation`/`created` | `urn:uuid:` minted, `highlighting`, now |
| A7 | Package-written sidecar with `reader:place` and a page selector | **Current app:** both are lost or garbled on re-save (known defect). **Rebuild:** both preserved |

**Anchoring**

| # | Check | Pass when |
|---|---|---|
| B1 | Fragment present and words unchanged | `.quoteInParagraph` with the exact words |
| B2 | Fragment present, one word changed in a 40-character quote | `.quoteInParagraph` with the document's new words (fuzzy) |
| B3 | Fragment present, quote deleted | `.paragraph`, no `exact` |
| B4 | Fragment id gone, the words occur twice and the prefix matches the second | Second occurrence, `.quoteInDocument` |
| B5 | Fragment gone, the words slightly edited, progression 0.8 | Found by searching outward from 80 % |
| B6 | Quote shorter than 8 characters and edited | Not fuzzy-matched. Orphan if no fragment |
| B7 | Address `content.xhtml#P-1` against a document of bare `P-1` (one occurrence) | Resolves via `sameElement` |
| B8 | Bare `P-1` against two documents both with `…#P-1` | Not resolved by id. Falls through to the words |
| B9 | Accent and case: quote "Resume", text "résumé" | Exact match under the matching options |
| B10 | Page note (no selectors) | Never an orphan |
| B11 | `fuzzyMatch` budget | 10 chars → 2, 50 → 10, 200 → 24 |

**Sync**

| # | Check | Pass when |
|---|---|---|
| C1 | Device A edits annotation X at t2; device B holds X at t1 | After merge, both have the t2 version |
| C2 | A deletes X at t3; B edited X at t2 < t3 | X is gone on both. Tombstone kept |
| C3 | A deletes X at t3; B edits X at t4 > t3 | X survives with B's edit |
| C4 | Two devices write concurrently | Neither loses the other's new annotations (read, merge, write under coordination) |
| C5 | The local `record.id` differs between devices for the same book | Sync still joins them, because it is keyed by folder |
| C6 | Reading positions | Newer `t` wins per folder. At most one write per 8 s |

**Exports**

| # | Check | Pass when |
|---|---|---|
| D1 | EPUB Annotations round-trip: export, then import into an empty sidecar | Same count. Highlight, comment and tag kinds kept. Fragment ids and quotes (with prefix/suffix) kept. Ids kept. Document notes excluded |
| D2 | A text directive with commas and dashes in the quote | Percent-encoded on export and decoded exactly on import |
| D3 | Import the same file twice | No duplicates (matched by id) |
| D4 | Markdown | Valid YAML front matter. Quotes as `>` blocks. Links `origamitext://open/<book>#<fragment>` with an inner `#` escaped |
| D5 | Readwise CSV | Header exact. Embedded quotes doubled. Tag-only entries use the tag as the highlight |
| D6 | Thorium 3.6+ reads the `.annotations` export | Highlights land on the right passages (manual check) |

**Identity**

| # | Check | Pass when |
|---|---|---|
| E1 | `normalised("origamitext://open/f.hegla.093000k") == normalised("urn:origami:local:f.hegla.093000k")` | True |
| E2 | `normalised("https://doi.org/10.1145/X") == normalised("doi:10.1145/x")` | True |
| E3 | A 64-hex local name | Written as `urn:origami:sha256:` |

**Network**

| # | Check | Pass when |
|---|---|---|
| F1 | Gemini round-trip: import a `.gmi` and export unedited | Byte-identical to the source |
| F2 | Gemini: edit one paragraph, export | Valid gemtext. Blank-line spacing from the source kept elsewhere. Visual-Meta is the last preformatted block |
| F3 | Gemtext ids | Re-importing identical bytes gives identical `gmi-L<n>` ids and the same document id |
| F4 | TOFU | First visit pins. Same cert matches. Changed cert: **no request bytes sent** until the user accepts. Accepting resets `firstSeen` |
| F5 | Gemini redirects | 5 hops maximum. A loop is detected. Cross-scheme asks first |
| F6 | Seed address parsing | `hm://u/a/b?v=x#blk+` → uid u, path [a,b], version x, block `blk`. `https://h/hm/u/a` → origin `https://h`. `https://h/hm/api/...` → nil |
| F7 | DAG-CBOR | Map key order is length then bytes. Re-encoding a decoded blob is byte-identical. The CID matches the reference client for a known blob |
| F8 | Signature | Verify `sig` over the blob re-encoded with `sig` = 64 zero bytes, using the public key from `signer` |
| F9 | Seed share | A second share posts 0. A failure part-way leaves posted ids recorded |
| F10 | Fetch by DOI | A challenge HTML page is rejected. A JATS source is preferred over a PDF when Europe PMC has it |
| F11 | **Launch rule** | A cold launch with a Hypothesis user, a Seed account and the Mail carrier configured shows no Keychain, network or permission prompt before the user acts |

### 7.3 Known discrepancies (summary)

1. Origami Text does not link the OrigamiFormat package. It writes
   `origamitext://open/<address>`, not the DOI, `sha256` or `local` URN rule.
2. `reader:place` and page selectors from the package are lost or garbled when
   Origami Text re-saves a sidecar.
3. The package's `AnnotationAnchor` lacks Origami Text's `sameElement` bridge.
   The package README claims Origami Text links it; it does not.
4. The WebView reader's JavaScript anchoring is simpler than the Swift cascade
   (lowercase only, no fuzzy match, no context scoring).
5. The position hint is paragraph-local but is compared with global offsets in
   step 5 of resolve.
6. `_seed-links.json` is keyed by `record.id` and written without file
   coordination. The other shared files key by folder and use coordination.
7. Imported EPUB-Annotations items keep foreign `target.source` values, and
   `start…end` quotes cannot match exactly.
8. Native `addHighlight(to:)` and `addComment(_:to:)` omit `creator`; the
   other paths include it.
9. `HypothesisClient.canonicalURI` and `hypothesisPublicEnabled` exist but
   nothing uses them. No push or fetch exists.
10. The `DataSeriesFetcher` comment says Stooq; the code uses Yahoo Finance.
11. Calendar is compiled out (`ORIGAMI_CALENDAR`).
