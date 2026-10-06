# Chapter 6 — Maps, Library Views and AI

This chapter is part of the Origami Text rebuild guide. It covers four parts of the app:

- the spatial **Maps**;
- the **AI** layer;
- the pluggable **Library Views** ("view modules");
- the **visionOS-only** spatial code that sits in the macOS source folder.

Source paths are relative to the repository root. Unless a path says otherwise, files are in `Origami Text macOS/`.

Related documents, which you should read alongside this chapter:

- [VIEW-MODULES.md](../VIEW-MODULES.md) — how a view module is declared and registered, and the rule that a new view must state the cognitive work it does.
- [ORIGAMI-TEXT-OVERVIEW.md](../ORIGAMI-TEXT-OVERVIEW.md) — the product as a whole: the library, the AI views, extensibility.
- [ORIGAMI-3D-MODELS-PLAN.md](../ORIGAMI-3D-MODELS-PLAN.md) — the reasoning behind 3D figures. It is superseded as a specification by `ORIGAMI-EPUB-PROFILE-1.0.md` §6.9. It matters here because the visionOS reader pulls 3D models off the page.
- [PHILOSOPHY-REVIEW-2026-07-14.md](../PHILOSOPHY-REVIEW-2026-07-14.md) — the principle that information which is recorded but hidden is a failure. It explains why AI output is always grounded in visible addresses and why AI-written documents carry `aiOnBehalf`.

(Links assume this chapter sits one folder below the repository root, for example in `rebuild/`. Adjust the `../` prefix if it is placed elsewhere.)

---

## 1. Purpose

Origami Text is a reader for a community's documents: EPUBs carrying Visual-Meta, and `.origamitext`/`LiquidDoc` letters. On top of the reader it offers many **ways of seeing the whole library at once**. This chapter specifies them well enough that a rebuild on any platform reproduces the same behaviour and reads and writes the same files.

1. **Maps**
   - The *venue Map*: a flat plane of paper cards for one journal or proceedings volume. It offers several computed arrangements, saved views, and topic "magnets".
   - The *Author's Map*: the writer's own node layout, embedded in a book.
   - Several relationship diagrams: rings, ego webs, a rotating weave, and a 3D sphere.
2. **AI** — a single routing object, `OrigamiLLM`, chooses between Apple's on-device model and any OpenAI-compatible server such as Ollama or LM Studio. Every AI feature produces something that can be checked against the library: addresses, quotations or sentence numbers. Anything unverifiable is dropped before display.
3. **Library Views** — 26 registered modules, each a self-contained screen over the same index, chosen in the sidebar. Only a few are shown on a fresh install.
4. **visionOS** — the same Map as a walk-in RealityKit "hallway", an arm-mounted chip menu, and a generic node engine.

Design rules that cut across all four (from the source comments and the project memory):

- **Never hide an option conditionally.** If something is unavailable, say why; do not remove the control.
- **Summaries are linked documents, not caches.** An AI summary that should last is written as a real document that links to its source, with `aiOnBehalf: true`. Examples: transcript summaries, the Stranger's record, a published glossary, a laid trail.
- **AI claims are grounded.** Model output is accepted only when it refers to things that exist: document addresses in the index, quotations found word-for-word, sentence numbers that exist. Everything else is discarded silently, or counted as "dropped".
- **AI goes through `OrigamiLLM`, and refusals are surfaced, not swallowed.** This is the intended rule. Section 3.6 lists where the current code departs from it.

---

## 2. Maps

### 2.1 Which file is which (important)

| Map | Platform | File and type | Notes |
|---|---|---|---|
| Venue Map (flat plane of paper cards) | macOS, iOS/iPadOS | `EPUBShelf.swift` → `ProceedingsMapView` (around lines 939–2083) | The Mac's "Map" for a venue. Hosted by `DocumentListView.venueMap` and `pinnedMap`. Also reused by `ReferencesScreen.swift` for the References map. |
| Hallway Map (walk-in 3D room) | visionOS only | `EPUBMapView.swift` → `EPUBMapView`, `EPUBMapItem` | The whole file is inside `#if os(visionOS)`. Built on `NodeImmersiveView`. See section 5. |
| Shared map data and algorithms | all | `EPUBShelf.swift` → `EPUBMapSharedLayout`, `EPUBMapViews`, `MapTopics`, `SpatialNotes`, `EPUBStanding` | One algorithm and one set of files, so both rooms show the same layout and topics. |
| Author's Map (writer's own layout) | macOS | `ReaderMapView.swift` → `ReaderMapView`, `ReaderMapStore`, `ReaderMapShortcut`; `ReaderMapLogic.swift` (links, layouts); `AuthoredMapView.swift` → `AuthoredMapExtras` | Behaves as Author's Map; the reader's arrangements are kept apart from the book. |
| Places map (geography) | all | `PlacesView.swift` (module id `places`, name "Map") | A MapKit map of `doc.location`. |
| Connections (ego web) | all | `DocumentWebView.swift` (module `connections`) | Two rings around the current document. |
| Author's Circle | all | `AuthorsCircleView.swift` | A ring of authors with citation lines. |
| Knowledge Space / Concept Space | visionOS only | `KnowledgeSpaceView.swift` | The whole file is inside `#if os(visionOS)`. |
| K. Nav | all | `KNavView.swift` | An embedding-based paragraph map. Uses AI for keyword stances. |

> **Discrepancy:** the brief for this chapter (and the project memory, "Map views state") describes `EPUBMapView` as holding the Default/Topics/Authors/People views. In the source, those views are in `ProceedingsMapView` in `EPUBShelf.swift`. `EPUBMapView.swift` is the visionOS hallway.

**There is no force-directed physics in any Map.** Every Map layout is a closed-form placement: a grid, ring, golden-angle spiral, centroid or ladder. The only iterative spring layout in the app is in the Glossary Space view (section 4).

### 2.2 The venue Map data model

**Item** (`ProceedingsMapView.Item`, `EPUBShelf.swift`):

| Field | Type | Source |
|---|---|---|
| `id` | String | The EPUB record id. |
| `key` | String | `EPUBRecord.folder`. This is the **shared layout key**: positions are stored by folder name, never by record id. The project memory "EPUB standing sync" says the same. |
| `title`, `author` | String | From the record. `author` is a comma-separated byline. |
| `isPinned` | Bool | `!isSetAside && model.isTopOfPile(record)`. |
| `isSetAside` | Bool | Standing. |
| `topics` | [String] | `extraction.concepts + extraction.keywords + publicationAnalyses[venue].paperTopics[record.id]`. |
| `people` | [String] | `extraction.people`. |
| `entities` | [String] | `extraction.technologies + extraction.places`. |
| `seriesName`, `seriesCount` | String?, Int | From `AppModel.seriesStanding(forAuthors:)`: the byline is split on ",", and the author with the highest count in the series wins. |

The items are built in `DocumentListView.swift` (`venueMap`, around lines 921–995).

- The venue Map shows only standing records: `pinnedFirst(epubRecords(inPublication:))` with set-aside books excluded from the plane. Set-aside items still arrive in `items`, but they are placed on a "floor" row.
- The Pinned map is the same view with `venue: "Pinned"`.
- On `.task(id:)` the host calls `AppModel.extractEntities(inPublication:)` if any record lacks an extraction. So opening a Map triggers AI extraction in the background (section 3).

**Where the AI labels come from** (details in section 3.5):

- `DocumentExtraction` (`EntityExtraction.swift`) has the fields `concepts`, `keywords`, `people`, `places`, `technologies`, `scientificTerms`, `model`, `date` and `chunkCount`. It is stored in `_document-extractions.json` in the community folder, keyed by record id.
- `PublicationAnalysis.paperTopics[recordID]` holds 3–5 short topics per paper. `topicCategories` maps each topic to an umbrella category. Both are stored in `_publication-analyses.json` in the community folder.

### 2.3 Canvas and coordinates

- The canvas is a fixed **2600 × 1800 pt** plane (`canvasSize`) inside a two-axis scroll view, centred on open (`.defaultScrollAnchor(.center)`). There is no zoom. On iOS, panning takes two fingers (`TwoFingerScrollConfigurator`).
- The plane shares coordinates with the visionOS hallway, which is measured in metres. **`pointsPerMeter = 620`**, and the canvas centre corresponds to hallway point (x 0, y 1.2 m):
  - metres → points: `x_pt = cx + x_m·620`, `y_pt = cy + (1.2 − y_m)·620` (`canvasPoint`)
  - points → metres: `x_m = (x_pt − cx)/620`, `y_m = 1.2 − (y_pt − cy)/620` (`sharedPoint`)
- The stored layout is therefore in metres, with y pointing up. A rebuild on any platform must keep this conversion so that layouts round-trip with the headset.

### 2.4 Views (arrangements)

`ProceedingsMapView.MapViewChoice` has these cases: `standard` ("Default"), `topics` ("Topics"), `authors` ("Authors"), `people` ("People"), `rank` ("Author Rank") and `saved(name)`.

**Persistence rule.** Only **Default** reads and writes the shared layout file. Every other view writes to an in-memory `overlayPositions` map. You can drag cards in those views, but the drags are never saved. Saved views are written only through "Save Current View…".

#### 2.4.1 Default (`seeds(for:)` plus stored positions)

A card with a stored position in the shared layout file is placed there. Every other card is seeded:

- Standing cards (in the given order):
  - `columns = max(1, Int(sqrt(n·7)/2))`
  - `x_m = (col − (columns−1)/2) · 0.28`
  - `y_m = 1.55 − row · 0.18`
- Set-aside cards go in a quiet block beneath:
  - `asideTop = 1.55 − gridRows·0.18 − 0.10`
  - `asideColumns = max(1, min(count, 5))`
  - x step 0.24 m, y step −0.08 m.

These numbers must match the hallway's article grid. The code comment says: "Keep the numbers in step with EPUBMapView's article grid."

#### 2.4.2 Topics / Authors / People (`applyComputed(_ facet:)`)

The three views run the same algorithm on different label sets ("facets"):

| View | Facet (labels per item) |
|---|---|
| Topics | `item.topics` |
| Authors | `item.author` split on ",", each trimmed |
| People | `item.people + item.entities` |

The algorithm:

1. Take the standing (not set-aside) items. For each item, collect its labels: trim each one, keep it only if it is longer than 1 character, lowercase it to form the key, and drop duplicates within the item. The first spelling seen becomes the display form.
2. Count how many items carry each key. A **magnet** is a key carried by **at least 2** items. Sort by count descending, then key ascending, and keep the first **14**.
3. Place the magnets on an ellipse round the canvas centre:
   - `angle_i = i/count · 2π − π/2`
   - `radius = 430` if there are 8 or fewer magnets, otherwise `580`
   - `x = cx + cos·radius`, `y = cy + sin·radius·0.62`
4. Place each item according to how many magnets it belongs to:
   - **Exactly one magnet:** a golden-angle spiral round it. For member `k`, `angle = k·2.399963`, `r = 62 + k·30`, `x = ax + cos·r`, `y = ay + sin·r·0.8 + 34`.
   - **Several magnets:** the centroid of those magnets, plus `stableJitter(id)`, plus 34 in y. `stableJitter` is a djb2 hash (start 5381, `hash = hash·33 + byte`), with `jx = hash % 97 − 48` and `jy = (hash/97) % 61 − 30`.
   - **No magnet:** a foot row. `columns = max(1, min(n, 8))`, `x = cx + col·190 − (columns−1)·95`, `y = H − 240 + row·92`.
   - **Set aside:** `asideFloorPoint(i)`: `x = 150 + (i%16)·150`, `y = H − 60 − (i/16)·70`.
5. Run `planeFit` (2.4.5) and apply the result to all positions.
6. Draw each magnet's caption at its (fitted) point, under the cards: 15 pt semibold, secondary colour at 0.55 opacity.

The computed view is recomputed whenever the label fingerprint (`tagsFingerprint`) changes. That happens, for example, when extractions arrive.

#### 2.4.3 Author Rank (`applyRankLadder`)

- Group papers by `seriesName` (only where `seriesCount > 0`). Sort the groups by count descending, then name.
- The first **12** groups each get their own rung. The remaining series papers are pooled as "More of the series". Papers with no series author go to "New to the series".
- Each rung label reads `"<count> × <name>"` and is captioned at `labelX = 340`.
- Cards start at `firstCard = 680`, with `perRow = 9`, x step 185 and y step 96. The first rung is at y = 180. After each rung, `y += subRows·96 + 28`. Cards within a rung are sorted by title.

#### 2.4.4 Saved views (`applySaved`)

- For each item, use the local saved view's `stored[item.key]` if present, otherwise the shared saved view's. Convert it with `canvasPoint`. Items not in the saved view fall back to the Default seeds. Then run `planeFit`.
- The View menu lists: the built-in views, then the saved names, then "Save Current View…" (which asks for a name in an alert), then a "Share View" submenu. Sharing copies a local view into the community file.

#### 2.4.5 `planeFit`

This keeps a computed arrangement inside the plane.

- `margin = 120`.
- Compute the bounding box of all points. Scale about the plane centre by `scale = min(1, planeW/spanX, planeH/spanY)`, where `planeW/H` is the canvas less the margins. Then slide by the smallest amount that brings the box back inside.
- Return nil (no change) if the box already fits.

### 2.5 Topic magnets bar

The magnet bar is a second, user-editable magnet system. It is separate from the computed views and can be shown over any view.

- It is toggled by the foot bar's "Topics" button and stored in `@AppStorage("mapMagnetBar")` (default `false`). It is a 30 pt bar of **12 editable slots** (`magnetNames`).
- **Naming** (`MapTopics.names(standing:kept:slots: 12)`, `EPUBShelf.swift`):
  1. **Kept names.** Names the user typed are stored in UserDefaults under `"mapMagnets:<venue>"` as `[String]`. They fill their own slots first. Every paper that a kept name "pulls" counts as already covered.
  2. **Candidates** (`MapTopics.candidates`):
     - every AI topic label longer than 1 character (keyed in lowercase); plus
     - every title word that is either longer than 3 characters or in `shortWords`, and is not in `stopWords`.
     - Each candidate carries the set of papers it covers.
  3. **Filter.** Remove any candidate that is a substring or superstring of a name already taken.
  4. **Greedy cover.** For each empty slot, pick the candidate that covers the most papers not yet covered. Break ties by total coverage, then alphabetically. Add the chosen candidate's papers to the covered set, then remove all candidates that are substrings or superstrings of it. Stop when no candidates remain.
  5. Return the non-empty names. There is no minimum frequency: a candidate covering one paper can be chosen.
- `stopWords`: the, and, for, with, from, into, through, towards, toward, using, under, over, between, across, about, study, case, paper, papers, approach, based, beyond, when, what, where, how, why, does, their, your.
- `shortWords` (allowed initialisms): ai, xr, vr, ar, llm, llms, web, html. These display in upper case, except "web". Other title words display capitalised.
- **`words(text)`:** lowercase the text, split on anything that is not a letter or digit, and drop empty strings.
- **`speaks(pole, textWords)`:** true when *every* word of the pole appears in the text, either exactly or as a prefix of a longer text word when the pole word has at least 4 characters. So "hyper" pulls "hypertextual", but "AI" never pulls "maintain".
- **`pull(pole, topics, title)`:** 1 for each topic label the pole speaks for, plus 1 if the pole speaks for the title.
- **Focus.** Clicking a magnet chip focuses it. Threads are drawn from the chip to every standing paper with pull > 0. With `share = pull/strongest`, thread opacity is `0.3 + 0.3·share` and line width is `0.5 + 1.5·share`. Papers it does not pull fade to 0.25. A lifted card draws threads up to every magnet that pulls it.
- **Rename.** Edit a slot and press Return (`magnetsEdited`). The names are saved to `"mapMagnets:<venue>"`. If every slot is cleared, the key is removed and the slots are named automatically again.
- **Arrange** (context menu on a chip → `arrangeColumn(under:)`). The papers the magnet pulls form a column under the chip, strongest pull first, ties broken by title:
  - `x = clamp(anchor.x, 90, W−90)`
  - `top = clamp(anchor.y + 90, 40, H−40)`
  - `step = n>1 ? min(96, (H − 80 − top)/(n−1)) : 96`
  - This is saved only when the Default view is showing.
- Magnets cannot be dragged on the Mac. In the hallway they are draggable cards.

### 2.6 Interactions (venue Map, macOS/iOS)

| Gesture | Effect |
|---|---|
| Single click on a card | Lift or unlift it (`liftedID`). A lifted card widens to 168/260 pt (210/330 when there is room). It shows the full title, author and abstract (up to 12 lines), gets a shadow (radius 5, offset 3,4) and shifts −2,−2. Animation `easeOut(0.15 s)`. |
| Double click | Open the book. This switches `venueViewMode = .documents` and calls `openEPUB`. One recognizer counts clicks using the system double-click interval (0.35 s on iOS). A click within 0.5 s of a drag is ignored. |
| Drag a card | `DragGesture(minimumDistance: 2)`, clamped to x ∈ [90, W−90] and y ∈ [40, H−40]. While dragging, only the dragged card redraws (`livePosition`). On release in Default, only that card is saved (`persist(item)`). |
| ⌘A | Select all cards (an NSEvent monitor; ignored while a text field has focus). Dragging any selected card moves the whole group, saved in one write. |
| Click empty plane | Clear the selection, the lift and the magnet focus. |
| Context menu (macOS) | Pin/Unpin (Top of Pile) and Set Aside/Bring Back. On iOS these are buttons on the lifted card. |
| Set Aside | `setAsideDroppingToFloor`: the card first animates to its floor point, then the standing is toggled. |
| Find (foot bar) | Matches title or author. Matching cards get a 2 pt accent border and all others dim to 0.25. If nothing matches, nothing dims and the Mac beeps on each keystroke. |
| Left-edge hover | A 16 pt strip reveals a 300 pt article list (`easeOut 0.2`). It hides 400 ms after the pointer leaves (`DocumentListView`). |
| Back chevron | Return to the article list. |

Card styling:

- Standing card width is 159 (macOS) or 195 (iOS). Title/author fonts are 10/8 pt (macOS) or 14/10 pt (iOS). Corner radius 10.
- Pinned cards have a 0.7 accent border and a pin badge. Set-aside cards are at 0.45 opacity.

Spatial notes (`SpatialNotes`, `SpatialNoteCard`, 150 × 184) are notes placed in the headset. They appear on the flat plane too, can be dragged (the position syncs back), and open for editing on double click.

**Sync beat.** Every **4 s** the Map adopts the standing again (`tick` → adopt standing) and reloads the layout off the main thread. This keeps the Mac, iPad and headset in step through the community folder.

"Re-Generate AI Analysis" is not part of the Map. It is a button in the venue list (`DocumentListView.swift`, around line 775) that reruns tasks 8–10 (section 3.5).

### 2.7 Persistence (all Map files)

| What | Where | Format |
|---|---|---|
| Shared X/Y layout (Default; both platforms) | `origami-map-layout.json` in the community folder, **and** a mirror in Application Support | `{"positions": {folderKey: {"x": m, "y": m, "t": date?}}, "modified": date}`, pretty-printed with sorted keys, written atomically. |
| Saved views (local) | Application Support `origami-map-views.json` | `{"venues": {venue: {viewName: {folderKey: {x, y, t?}}}}}` |
| Saved views (shared) | `_map-views.json` in the community folder | Same structure. Merged per view when shared. |
| Magnet names | UserDefaults `"mapMagnets:<venue>"` | `[String]` |
| Magnet bar shown | `@AppStorage("mapMagnetBar")` | Bool |
| Pile standing | UserDefaults `"epubTopOfPile"` and `"epubSetAside"`; `origami-standing.json` in the community folder (`EPUBStanding`: `pinned`, `setAside`, `concepts?`, `modified`) | See the EPUB chapter. |
| Spatial notes | `origami-spatial-notes.json` | Per note: `id`, `venue`, `text`, `x`, `y`, `z`, `created`, `modified`, `deleted`. Dates are ISO with milliseconds. Deleted notes stay as tombstones. |
| visionOS 3D positions | Application Support `EPUBMapLayout.json` | `{"nodes": [{id, x, y, z}]}`. X/Y are also pushed to the shared file. |
| visionOS saved slots | UserDefaults `"mapSavedViews:<venue>"` | `{"1".."5": {itemID: [x,y,z] minus spaceShift}}`. Five slots, plus five read-only shared slots. |

**Merge algorithm** (`EPUBMapSharedLayout`), which must be reproduced exactly:

- **Load:** read the mirror and the community file, then merge them **entry by entry**. For each key, the entry with the newer `t` wins. A missing `t` counts as the oldest possible date. A key present on only one side is kept. `modified` is the later of the two.
- **Save:** load and merge, stamp only the updated keys with `t = now`, set `modified = now`, and write the result to both the mirror and the community folder. All other entries, including other venues', are kept.
- **Refresh:** on each shelf scan, merge the community file into the mirror (`refreshMirror`).
- **Cloud lag:** if the community file is a cloud placeholder that is not yet current, the code asks for a download and waits up to 6 × 0.15 s. When offline, it uses whatever is on disk.

The positions are therefore a last-writer-wins map keyed by card, safe under concurrent writes from several devices. Use the same rule on any sync medium.

### 2.8 Author's Map in the reader (`ReaderMapView.swift`, `ReaderMapLogic.swift`)

The **writer's own map** of a book, made in the Author app, behaving as Author's Map does (`CanvasViewController` / `CanvasView` in `~/Documents/author_mac_forxcode`). macOS only. It is a central mode: the **Map** word stands among the foot bar's mode words right after References, with a `|` between (`ReadingFootBar.onMap` / `mapWord`, shown only when `LiquidDoc.hasAuthoredMap`). It is opened by that word, by ⌘M (`ReaderMapShortcut`, which takes ⌘M from Minimize in a window whose book has a Map), or by Show Author's Map in the page's context menu. It replaces the whole reading, foot bar included (an `.overlay` on `EPUBReaderScreen` and on `OrigamiReadingView`); ⌘M or the Map word in its own bar returns. While it is up, `AppModel.isReaderMapShown` makes the reading's key, scroll and pinch monitors stand down.

**Inputs:** `doc.layouts` (positions), `doc.concepts` (names, definitions), `doc.body`, `doc.references`, `AuthoredMapExtras{labels, yUpViews}`.

**Where the data comes from:**

1. **EPUB.** The `map` object in `origami.json` (properties `origami:interaction`). For pre-1.0 books it falls back to `visual-meta.json`. Import is in `OrigamiEPUBImport.swift`.
   - `map.views[] = {id, name, nodes:[{ref,x,y,z}]}`. A view with no name is called `"View n"`.
   - `map.connections[] = {from,to}`.
   - `map.nodes[] = {id,label}` gives the labels (`AppModel.authoredMapExtras(for:)`).
   - A view whose `space.convention` contains `"y-up"` has its y values negated.
2. **Author `.liquid` package** (`AuthorImporter.swift`), file `Contents/DynamicView.json`:
   - `layout.nodePositions` becomes the layout "Current Layout".
   - each `customLayouts[]` entry becomes a further layout;
   - `connections[{startNodeIdentifier, endingNodeIdentifier}]` become connections, with duplicates removed;
   - concepts come from `glossary.json` and references from `Citations.plist`.

**Canvas.** Positions are node centres from the canvas centre, y down (Author's canvas). A y-up view is flipped once; pre-1.0 maps in 0–1 fractions are spread ×900. Opens at scale 1, centred on the arrangement. Scroll pans; pinch zooms about the pointer (0.25–3); **Z** fits everything shown (40 pt padding, never below 0.25, never in) and **Z** again returns (`ReaderMapLayouts.fitScale`).

**Nodes.** Bare text at rest in the reading's body face at 17 pt (Author's default node size), 5/3 pt insets, corner radius 4. Selected: grey fill (#747474 light, #191919 with white border dark), white text. Linked: light fill with a border, text #595959. Headings bold, references italic.

**Lines.** None until something is selected (`ReaderMapLinks.links(forSelection:among:)`, ported from `glossaryNodeLinksFrom/To`): **solid** where the selected concept's definition mentions another as a whole word, case-insensitive, sentence by sentence; **light** where another's definition contains the selected name (Author's plain-substring rule); a light line is dropped where the pair already has a solid one. Straight, centre to centre, 0.5 pt, no arrows. Within 12 pt of a solid line the first mentioning sentence shows at its midpoint. A linked concept off screen shows as a 120×24 pill 10 pt inside the edge where its line leaves; a click scrolls it into view. Stored `map.connections` are drawn as Author never draws them — not at all (the old sheet's derived-lines rule is gone with it).

**Interaction.** Press selects (Shift adds, ⌘ toggles); drag moves the selection; drag on empty space draws a marquee; click on empty space clears; ⌘A all. Double-click reads the definition (with "Mentions …"). **Show in Text** appears only when the body uses the name (`appearsInText`); it closes the Map and runs `AppModel.showFindFold(term:)` — the reading folded to its headings with every use highlighted, as Find does. For a heading or passage member it opens the reading at that paragraph instead. Space = Focus (selection and linked only), Tab = select connected, G = Gather, ⌘F = find over name and definition (selects matches; Esc clears), Esc otherwise toggles full screen. Context menu: Read Definition, Show in Text, Focus, Select Connected, Layout (for a multiple selection), Hide.

**Bar.** The reading's own `ReadingFootBar` in Map mode, laid out as Author's Map bar: `leadingContent` = **Ask AI | Views** (and "Find: term" while a find stands), the mode words in the middle with **Map** bold (`mapActive`; every other word shows inactive, and any of them leaves the Map — References opens rather than toggles), `trailingContent` = **Select | Show | Layout** in place of Contents and Aa. The host builds the bar and hands it to `ReaderMapView.footBar`. Menus: Select (All, Find…, Connected, None) · Show (All, Focus, Only Concepts in the Text, Hide Selection, Reveal Hidden) · Layout (Author's Layout; Magnetic Center, Islands, Spine, Orbits — `ReaderMapLayouts.analysis`; Gather, Align, Distribute, Sort) · Views (the book's views; the reader's saved views; Save View…, Delete View) · Ask AI (every concept as "definition : phrase" plus the question, through `OrigamiLLM.respond`). Timeline and Neighborhoods are ported but not offered: an EPUB map carries no dates or categories.

**What the reader keeps.** Moves and arrangements, per book (`bookKey`: the record folder in Scroll, `doc.id` in the native reader) and per view, in UserDefaults (`ReaderMapStore`, keys `readerMap.positions.<book>.<view>` and `readerMap.views.<book>`), undoable. The book's map is never written (§10.3, §15). Authoring is left out: no new concepts, no edited definitions, no deletions, no drawn connections.

**What Author writes** (Profile 1.0 §10.3): one view, `MAP-1`, whose `ref`s are bare concept UUIDs (the same as `visual-meta.json` `concepts[].id`), x/y in canvas points with an arbitrary origin, `right-handed-y-up`. `z` is depth in metres with 0 meaning unset; the 2D sheet ignores it. Concepts listed in `map.nodes` but placed in no view are left out. Older exports with no map show "No Map in This Document" and need re-exporting from Author; very old ones kept the map in `visual-meta.json` with heading refs and 0–1 coordinates, which the fallback and the fit-to-view still draw.

**Layout (`fit`).** Scale the coordinates uniformly to fit the sheet with `margin 110`: `scale = min(w/spanX, h/spanY)` (1 if the span is zero), then centre the result. Connections are lines at secondary 0.6 opacity, width 1.2.

**Cards:**

- maximum width 180, corner radius 8;
- concepts are tinted with accent at 0.14; headings are bold; references are italic;
- the selected card has a 2 pt accent border.

**Behaviour:**

- If there is more than one layout, a picker chooses between them.
- Tapping a passage card closes the sheet and opens the reader at that paragraph (`onOpen(paragraphID)`).
- If the layout is empty, the sheet shows "No Map in This Document".
- The minimum size is 720 × 520.
### 2.9 Other relationship maps

**Connections (`DocumentWebView.swift`; built by `WebBuilder.web` in `DocumentWeb.swift`).** An ego web centred on the current document.

- Ring one holds up to 12 neighbours (outgoing links plus backlinks). Ring two holds up to 16.
- Radii are `r1 = 0.30·min(w,h)` and `r2 = 0.46·min(w,h)`. Ring-one slots are at `−π/2 + i·2π/slots`. Ring two fans round its parent's angle in steps of 0.34 rad.
- Edges:
  - coloured by relation (`RelStyle.color(rel)`), at 0.55 opacity and width 1.8;
  - shortened by 54 pt at each end, and drawn only if longer than 116 pt;
  - arrowhead 7 pt at ±0.5 rad;
  - unresolved targets are dashed `[4,3]` "ghosts".
- Clicking a card re-centres on it; double-clicking opens it.
- An "Open" toggle shows the centre plus up to 4 neighbours as 340 pt columns, joined by Bézier "beams" (`bend = max(24, dx·0.4)`).

**Author's Circle (`AuthorsCircleView.swift`).**

- Authors (`creditedAuthor`, sorted by document count) sit on a still ring: `radius = min(w,h)/2 − 70`, `angle = −π/2 + 2π·i/n`.
- Directed edges run from author A to author B when A's documents link to B's. Each edge is drawn as a segment pulled back 30 pt at each end and offset ±3 pt sideways, so the two directions sit side by side. Width is `1 + min(docs,7)`, plus 1.5 while hovered.
- Hovering within 7 pt of a segment shows a card listing up to 10 documents, then "and N more".
- Clicking an author selects them and highlights their lines; ⌘A selects all.
- AttentionsView (section 4) uses the same geometry.

**Places (`PlacesView.swift`).**

- Uses `doc.location` strings, geocoded through `PlaceDirectory` (Apple's `CLGeocoder`). The cache is in `PlaceDirectory.json`, with a community `Localities.json`.
- Pins are 26 pt circles showing a note count; they are orange while the place is unconfirmed.
- A "Confirm Places" card offers Confirm and Not This for each place.

**K. Nav (`KNavView.swift`).** An embedding map of paragraphs.

- **Corpus:** `filteredEntries` that have a body, excluding bot, trail and glossary documents, Visual-Meta paragraphs and headings. Only paragraphs of at least 60 characters, at most 30 per document and 400 in total. At least 3 are required.
- **Embedding:** `NLEmbedding.sentenceEmbedding(.english)`, falling back to averaged word vectors. A portable rebuild can use any sentence-embedding model.
- **Clusters:** connected components (union-find) over pairs with cosine ≥ `threshold`. The default threshold is 0.6, adjustable with a slider from 0.35 to 0.85. Only components of 2 or more count. At most 1200 cluster edges are drawn.
- **Sketch** (optional): a random sign projection down to `max(dim/4, 8)` dimensions, using SplitMix64 with a seed (default 42, adjustable 1–999).
- **Bridges** (`findBridges`):
  - Consider pairs from different documents and different clusters whose similarity is below the threshold.
  - The mediator is the unit that maximises `min(sim[a][m], sim[b][m])`; that minimum is the "mediated" similarity.
  - `score = mediated − direct`. A pair is kept if `score > 0.12` and `mediated > 0.35`. It is "strong" if `score > 0.25` and `mediated > 0.5`.
  - Keep the best bridge per document pair, and the top 12 overall.
- **Probe:**
  - Embed the typed keyword. Keep paragraphs with similarity of at least 0.3, top 12, with `strength = clamp((sim−0.3)/0.4, 0, 1)`.
  - If the model is available, ask it for stances (task 25 in section 3.5) and colour each thread: positive = green, negative = red, questions = blue, neutral = orange.
- **Presentation:** a List, or a Weave (`WeaveCanvas`; see The Weave in section 4). Knot weight is +4 per bridge end, +2 per mediator and +1 per cluster edge.

**Knowledge Space and Concept Space** are visionOS only (`KnowledgeSpaceView.swift`). They are generic draggable card planes (`SpatialCardPlane`).

- Seeding: a grid (`ceil(sqrt n)` columns, 220 × 120 spacing) or a circle (`radius = min/2 − 130`).
- Layouts are saved as Visual-Meta-shaped `map` JSON in Application Support `<name>.json`: `{map:{views:[{id:"view-<name>", name, space:{units:"points"}, nodes:[{ref,x,y,z}]}]}}`.
- Layout names are `"KnowledgeSpaceLayout"` and `"ConceptSpace-<room>"`.

---

## 3. AI

### 3.1 The routing object: `OrigamiLLM` (`OrigamiLLM.swift`)

`OrigamiLLM` is a main-actor, observable singleton, `OrigamiLLM.shared`.

**Choosing a model.** There is no provider enum. The choice is a single string, `selectedID`:

- `"apple"` (the default) means Apple's on-device model (FoundationModels `SystemLanguageModel.default`).
- `"endpoint|<base>|<model>"` means a model on an OpenAI-compatible server. The string is built by `endpointID(base:model:)`.
- `selectedEndpointModel()` splits the string on `|` (at most 3 parts) and looks the base up in `endpoints`. If it is not found, the result is nil, which means Apple.

**Configuration:**

| Setting | Storage | Default |
|---|---|---|
| Selected model | UserDefaults `"selectedModelID"` | `"apple"` |
| Servers | UserDefaults `"llmEndpoints"`: JSON `[OrigamiEndpoint{base, models:[String], modelSizes:[String:Int64], hasKey}]` | `[]` |
| API keys | Keychain service `"info.futuretextlab.origamitext.llm"`, account = base URL | none |

Keys are read only when a request is sent, never at launch. This follows the project rule "No startup network prompts".

**Server protocol** (`ChatCompletionsClient`). No host names are hard-coded.

- `normalizedBase`: strip trailing "/" and a trailing "/v1".
- List models: `GET {base}/v1/models` → `data[].id`, sorted. Timeout 2 s.
- Model sizes (Ollama only): `GET {base}/api/tags` → `models[].{name,size}`. Errors are ignored silently.
- Chat: `POST {base}/v1/chat/completions` with the body `{"model": m, "messages": [{"role":"system","content":instructions}?, {"role":"user","content":prompt}], "stream": true}`.
  - `ChatCompletionsClient.respond` takes two optional extras. `temperature` is added to the body only when given. `jsonSchema` (a name and a schema) adds `"response_format": {"type": "json_schema", "json_schema": {"name": …, "schema": …}}`. No max-tokens is sent. Timeout 300 s.
  - Status 401/403 → `.authRequired`. Status 404 → `.modelNotFound(model)`. Status 400 or 422 while a schema was sent → the request is sent once more without `response_format` (the schema is still in the instructions). Any other non-200 → `.generationFailed`.
  - If a key exists, it is sent as `Authorization: Bearer <key>`.
  - The reply is read as Server-Sent Events: each `data:` line until `[DONE]`, concatenating `choices[0].delta.content`. Each partial result goes to `onPartial(textSoFar)`.
- **Local detection** (`detectLocalServers`, run only when the settings pane opens): probe `http://localhost:11434` (Ollama) and `http://localhost:1234` (LM Studio) with a 0.8 s timeout.
- `isLocal` counts localhost, 127.0.0.1, ::1 and `*.local`. Adding any other server asks for confirmation ("Add Anyway").
- **Pasting a server address** (`classify(_:)` → `PasteOutcome`):
  - `.endpoint(base, models)` — the server answered;
  - `.needsKey(base)` — it replied 401/403;
  - `.huggingFace(repo)` — a Hugging Face repo was pasted;
  - `.invalid(message)`.
- `OllamaModelCatalog` is a Mac-only list of recommended models, from phi4-mini up to llama4:scout, filtered by installed RAM.

**Apple path** (`appleRespond`):

- Requires `SystemLanguageModel.default.availability == .available`; otherwise it throws `.appleUnavailable`.
- Builds its session with `appleSession(instructions:transformingContent:)`. It streams with `streamResponse(to:)` only when `onPartial` is given; otherwise it calls `respond(to:)`.
- Uses the default guardrails, unless the caller passed `transformingContent: true`. Then the model is `SystemLanguageModel(guardrails: .permissiveContentTransformations)`. Servers ignore the flag.

**Public API:**

```swift
func respond(instructions: String?, to prompt: String,
             transformingContent: Bool = false,
             onPartial: (@MainActor (String) -> Void)? = nil)
    async throws -> (text: String, modelName: String)
func generate<T: Generable>(_: T.Type, instructions: String?, prompt: String,
                            options: GenerationOptions = GenerationOptions(),
                            transformingContent: Bool = false)
    async throws -> (content: T, modelName: String)   // structured answer from either model
var canRespond: Bool          // a server is chosen, or Apple's model is .available
func respondJSON<T: Decodable>(_: T.Type, instructions: String, prompt: String)
    async throws -> T?         // older helper; nil when no server is chosen. No caller left.
var fallbackNotice: String?    // set when a server was missing and Apple answered
func addOrUpdateEndpoint(base:models:sizes:key:), removeEndpoint(_:), refreshModels(for:)
static func classify(_ pasted: String) async -> PasteOutcome
func detectLocalServers() async -> [(base: String, models: [String])]
```

**`respond` algorithm:**

1. If a server model is chosen, call it. On success, return `(text, "<hostLabel> · <model>")`.
2. Only when the server error's `OrigamiLLMError.allowsFallback` is true (`.serverUnreachable` or `.modelNotFound`), set `fallbackNotice = "<model> wasn't available — used Apple's built-in model instead."` (`noteFallback(from:)`) and continue to Apple.
3. Every other error is thrown to the caller: cancellation, a missing API key (`.authRequired`), a refusal, a bad status, a malformed answer.
4. Call Apple and return `(text, "Apple's built-in model")`. Apple's errors propagate to the caller.

**`generate` algorithm** (the one door for structured answers):

1. If a server model is chosen, turn `T.generationSchema` into a JSON Schema object (`jsonSchema(for:)`: `JSONEncoder` on the schema, then `JSONSerialization`).
2. Send it twice over: in the system instructions, after the caller's instructions, as "Reply with one JSON object only — no prose, no code fence — matching this JSON Schema:" plus the schema text; and as `response_format` through `ChatCompletionsClient.respond(jsonSchema:temperature:)`, with the temperature from `options`.
3. Read the reply with `decode(_:from:host:)`: take the outermost `{…}` (first `{` to last `}`), and build `T` through `GeneratedContent(json:)`. No braces, or content that does not fit `T`, throws `.generationFailed` ("…did not answer in the form asked for").
4. The fallback rule is the same as `respond`'s: only `.serverUnreachable` and `.modelNotFound` go on to Apple.
5. Apple: guided generation, `session.respond(to:generating:options:)`, with the session from `appleSession` (so `transformingContent` applies). Throws `.appleUnavailable` if the model is not `.available`.

The feature gets the same `T` whichever model answered.

**`respondJSON`** (kept, but no feature calls it now):

- Appends to the instructions: "Reply with one JSON object only — no prose, no code fence."
- Decodes the text from the first `{` to the last `}`. If that fails, it throws `.generationFailed`.

**`ContextAI`** (same file) holds the grounded helpers for the Context panel: `folded`, `verifies(_:in:)`, `explain(...)` and `checkClaim(...)`. See tasks 6 and 7.

### 3.2 Error classification

`OrigamiLLMError` is described in the code as "the canonical copy". Its cases:

- `serverUnreachable(host)` — any transport error;
- `modelNotFound(model)` — HTTP 404;
- `authRequired(host)` — HTTP 401 or 403;
- `appleUnavailable`;
- `generationFailed(String)` — a non-200 status, an empty reply, or JSON that does not decode.

`ReadingAI.reason(_ error:)` (`ReadingAI.swift`) turns an error into a sentence for the reader:

| Condition | Message gist |
|---|---|
| `String(describing: error)` contains `"ModelManagerError"` (1026 = model asset missing) | Apple's model is not on this Mac; choose a server model. |
| `GenerationError.exceededContextWindowSize` | Too long. |
| `.assetsUnavailable` | The model is not ready. |
| `.guardrailViolation` | The model declined. |
| `.unsupportedLanguageOrLocale` | The language is not supported. |
| `.rateLimited` | Try again shortly. |
| anything else | `localizedDescription` |

**Refusals in the newer SDK.** The newer error type `LanguageModelError` does not exist in the macOS 26 SDK, so it is matched by name. A refusal is `GenerationError.guardrailViolation`, or `.refusal`, or any error whose `String(reflecting:)` contains `"LanguageModelError"` and the case name. Context overflow is `.exceededContextWindowSize` or `"contextSizeExceeded"`. Implementations:

- `TranscriptSummarizer.isRefusal` and `isContextOverflow`;
- `AIInsightsView.isModelRefusal`;
- `EntityExtractor.isContextOverflow` and `isGuardrail`. These are looser: any error text containing "context" counts as overflow.

The project memory rule "classify FoundationModels errors against both enums" refers to this.

**Recovery strategies:**

- `ReadingAnalyzer`, on overflow: halve the cap (9000 → 4500 → 2250) and stop below 2000, then throw "would not fit".
- `EntityExtractor`, on overflow: split the chunk in half. A guarded chunk is skipped.
- `TranscriptSummarizer`: retry once on refusal, and split on overflow.
- `AIInsightsView`: retry once on refusal, then show "Apple Intelligence declined…".

**Guardrails.** The permissive content-transformation guardrails are asked for by passing `transformingContent: true` to `OrigamiLLM.respond` or `generate`. `ReadingAnalyzer`, `TranscriptSummarizer` and `AIInsightsView` do this. Everything else uses the default.

**Availability UI.** The availability gates ask `OrigamiLLM.shared.canRespond` (a server is chosen, or Apple's model is available). This covers the Library AI views, Bots, the draft title, paragraph emotions, K. Nav stances, person profiles, `TranscriptSummarizer.isAvailable`, `SeriesPlanner.unavailabilityReason` and `ReadingAI.isAvailable` on macOS and visionOS. When nothing can answer, the Library AI views show "No AI Model Available" with Apple's reason: `deviceNotEligible`, `modelNotReady`, or otherwise "Enable Apple Intelligence…". `SeriesPlanner` also handles `appleIntelligenceNotEnabled`. Following the "never hide options" rule, the view stays in the sidebar and explains why it cannot run.

### 3.3 Grounding techniques (reuse these in any rebuild)

1. **Addresses.** The corpus labels each document `== "title" by author (date, address <id>)`. The model must copy addresses exactly. Every returned address is canonicalised (`LiquidAddress.canonical`) and **kept only if it exists in `index.byID`**. Items left with too few documents are dropped.
2. **Sentence numbers.** For paragraph breaks and key sentences, the model returns only numbers. The app rebuilds the output from the original sentences, so the model never changes the author's words.
3. **Verified quotations.** For Explain in Context and Check This Claim, every quotation must be found word-for-word in the material. Text is first normalised with `ContextAI.folded`, and a quotation must be at least 8 characters. Sentences with unverified quotations are dropped and counted.
4. **Term verification.** In the summary, names, keywords and glossary terms are kept only if they occur in the text (`ReadingAnalyzer.verified`). Names are re-spelled as the paper spells them, matched on surname.
5. **Links and citations.** In Ask and AI Insights, bracketed `[n]` or `[address]` references become live links. References that do not resolve are removed.

### 3.4 The shared library corpus (`AIInsights.corpus`, `AIInsightsView.swift`)

`corpus(from entries: [IndexEntry], characterBudget: 14_000) -> (text, includedCount, omittedCount)`:

- Sort by `listedDate`, newest first, and skip documents with no body.
- Each block is:
  - a header line `== "<title>" by <displayAuthor> (<listedDateText>, address <id>)`;
  - if the document links to other books in `entries` (compared by canonical address), a line `Relations: <rel ?? "links-to"> [<to>#<fragment>] · …` — links to works off the shelf are left out;
  - the body's `displayText` joined with "\n", excluding Visual-Meta paragraphs.
- Each block is cut to a share of the budget, `max(1500, budget / min(textDocuments, 8))`, with " …" appended. A whole book is longer than the budget; without the share the first block overran it and nothing was sent.
- Add blocks until the next one would exceed the budget, then stop. Blocks are joined with "\n\n".
- Addresses the model returns are grounded through `AIInsights.canonicalIndex(byID)`, the index keyed by lowercased id (Themes, Open Questions, Agreements, Disagreements), since a book shelved under its file name keeps its case.
- The request is: `prompt + "\n\nTHE DOCUMENTS (N included[, M older omitted for space]):\n\n" + corpus`.
- If no documents are included, the view shows "No text documents in the library yet."

### 3.5 Every AI task

Routing key:

- **LLM** = goes through `OrigamiLLM` (chosen model; Apple only when the server or model is missing).
- **LLM/APPLE** = goes through `OrigamiLLM` on macOS and visionOS and calls Apple directly on other platforms.

"Guided" means a `@Generable` type sent through `OrigamiLLM.generate`: Apple's guided generation, or the type's JSON Schema on a server (3.1). A portable rebuild should use JSON-schema output for these.

| # | Task | Input | Prompt location | Output | Used by |
|---|---|---|---|---|---|
| 1 | Selection rewrite ("Simplify Text" and user presets); LLM/APPLE | Selected text | `ReadingAI.rewrite`, prompt = `preset.prompt + "\n\n" + text`. Defaults in `AIPromptPreset.defaultPresets` (id `simplify`: "Rewrite the following text in simpler, clearer language… Return only the rewritten text"). Presets stored as JSON in `@AppStorage("readingAIPrompts")`. | Plain text, trimmed | `OrigamiReadingView.runAI` (selection AI result) |
| 2 | Paragraph breaks; LLM/APPLE | One paragraph over 350 characters with at least 6 sentences, split by `ReadingAI.flowLines` and numbered | `ReadingAI.paragraphBreaks` ("…Answer with only the numbers of the sentences that START a new paragraph… Never include 1… answer: none.") | Numbers, parsed with `\d+` by `breakStarts`. Each break must leave at least 3 sentences (`minimumRun`) on each side. Segments are rebuilt from the original sentences. | `OrigamiReadingView.computeParagraphSplits`. Cached in memory only. |
| 3 | Key sentence; LLM/APPLE | Paragraph of at least 3 sentences, numbered | `ReadingAI.keySentence` ("Choose the single sentence with the most to say… Answer with only that sentence's number") | First integer → that sentence, or nil | `computeKeySentences` (Key Statement colouring). Refusals are not cached. |
| 4 | Reading summary; LLM, guided on Apple, permissive guardrails | `ReadingAnalyzer.summaryCorpus`: ABSTRACT, INTRODUCTION, CONCLUSION, SECTIONS (headings), THE REST. Cap 9000 characters (Apple) or 24000 (server). | `ReadingAnalysisKind.summary.defaultPrompt` in `ReadingAnalysisView.swift`. Override in UserDefaults `"aiReadingSummaryPrompt"`. A relevance sentence is added from `"aiRelevanceTopic"` (default "Hypertext"). | Apple: `GeneratedReadingSummary{aim, conclusion, restOfPaper, summary, names≤10, keywords≤10, glossary:[{term, meaning, introduced}]}`. Server: the same as JSON, parsed leniently with one retry, falling back to prose. Then `verified`. | `ReadingAnalysisScreen` ("AI" tab). Saved, see note A. |
| 5 | Reading issues; LLM, streamed, permissive guardrails | Body text minus Visual-Meta (`corpus(of:cap:)`) | `ReadingAnalysisKind.issues.defaultPrompt` (critical reading in three parts: Logic, Factual correctness, Structure). Override `"aiReadingIssuesPrompt"`. | Markdown prose; each block can be dismissed | `ReadingAnalysisScreen`. Saved, see note A. |
| 6 | Explain in Context; LLM | Selected words, their sentence, and numbered sources (the paragraph, first and last use, glossary, the reader's notes, library hits) | `ContextAI.explain` in `OrigamiLLM.swift` ("…using ONLY the numbered material… Every sentence must contain at least one exact quotation…") | Plain text, split into sentences (`NLTokenizer`). A sentence is kept only if all its quotations verify. | `ContextAISection` (Mac `SelectionContext.swift`; visionOS `OrigamiVision.swift`) |
| 7 | Check This Claim; LLM | Claim plus up to 8 passages: library passages, and Semantic Scholar passages when `"contextOnlineSemanticScholar"` is on | `ContextAI.checkClaim`, one call per passage | JSON `{"stance": "supports"\|"contradicts"\|"refines"\|"unrelated", "quote": "..."}`. Kept only if the stance is valid and the quote is found in the passage. | Context panel, grouped by stance |
| 8 | Paper topics ("AI Analyse"); LLM | Title and author | `AppModel.analysePublication(_:)`. Instructions: "Extract topic keywords from academic paper titles. Be concise and specific." Prompt: "List 3 to 5 short topic keywords… Reply with only a comma-separated list" | Comma list → `[String]`, each under 60 characters | `PublicationAnalysis.paperTopics` in `_publication-analyses.json`. Used by Map magnets, the sidebar and `VenueViews`. |
| 9 | Topic categories; LLM | Unique topics in chunks of 40, plus the categories already coined (seeded with "AI") | `AppModel.categoriseTopics` ("Group academic topic keywords under broad umbrella categories…"; reply lines `topic :: category`) | Lines split on `::`. AI-sounding categories fold into "AI" (`readsAsAI`). Case variants merge. | `PublicationAnalysis.topicCategories` |
| 10 | Entity and concept extraction; LLM guided | Paragraphs packed into chunks of about 6500 characters (`EntityExtractor.chunks`) | `EntityExtractor.instructions` in `EntityExtraction.swift`. `extractChunk` calls `OrigamiLLM.generate(PassageExtraction.self, …)`, a fresh request per chunk. | `PassageExtraction` (maxima 6/6/8/6/8/8): guided on Apple, its JSON Schema on a server. Merged across chunks by frequency, top 20 per category, the paper's own authors removed. | `DocumentExtraction` in `_document-extractions.json`. Map facets and magnets. |
| 11 | Ask the Library; LLM, streamed | Top 12 keyword-scored passages (section 4, Ask) | `AskLibraryView.ask` ("You are the librarian of a personal research library. Answer only from the numbered passages… cite… like [3]. If the passages do not answer the question, say so plainly.") | Plain text; `[n]` becomes a link | Ask view; not saved |
| 12 | Themes; LLM guided | Library corpus (3.4) | `Themes.defaultPrompt` in `ThemesView.swift`; key `"aiThemesPrompt"` | `GeneratedThemeList{themes:[{name, summary, addresses}]}`, 4–10 themes | Themes view |
| 13 | Open Questions; LLM guided | Corpus | `OpenQuestions.defaultPrompt`; key `"aiOpenQuestionsPrompt"` | `GeneratedQuestionList{questions:[{question, status, addresses}]}`, 3–8 questions | Open Questions view |
| 14 | Agreements; LLM guided | Corpus | `Agreements.defaultPrompt`; key `"aiAgreementsPrompt"` | `GeneratedAgreementList{agreements:[{topic, consensus, addresses}]}`, at most 6, each with at least 2 real documents | Agreements view |
| 15 | Disagreements; LLM guided | Corpus | `Disagreements.defaultPrompt`; key `"aiDisagreementsPrompt"` | `GeneratedDisagreementList{disagreements:[{topic, dispute, firstPosition, firstAddresses, secondPosition, secondAddresses}]}`, at most 6 | Disagreements view |
| 16 | The Stranger (Challenge/Support); LLM guided | Corpus, plus (Challenge only) `"SUPPORTED BY LINKS, NEVER CHALLENGED: [id]…"` (up to 8) | `Stranger.defaultChallengePrompt` / `defaultSupportPrompt`; keys `"aiStrangerChallengePrompt"` / `"aiStrangerSupportPrompt"` | `GeneratedStrangerReading{findings≤5:[{topic, position, addresses, answer}], question, suggestsOtherMode, modeSwitchReason}` | Stranger view; optionally saved as a document |
| 17 | AI Insights; LLM, permissive guardrails | Corpus passed as the request, prompt as instructions | `AIInsights.defaultPrompt`; key `"aiInsightsPrompt"` | Markdown with five `##` sections; `[address]` links | AI Insights view |
| 18 | Suggest title; LLM | First 4000 characters of a draft | `DraftEditorView.suggestTitle` ("Generate a title for this text. Reply with the title alone.") | First non-empty line, quotes stripped | Draft editor |
| 19 | Paragraph emotions; LLM guided | Lines `id: text` | `DocumentDetailView.judgeEmotions` ("You judge the emotional tone of the paragraphs…") | `GeneratedEmotionJudgement{positive:[id], negative:[id]}`, intersected with real ids; ids on both sides dropped | Green and red paragraph tints; not saved |
| 20 | Transcript summary and notes; LLM guided (notes) and LLM (overview), permissive guardrails | Transcript in 9000-character chunks | `TranscriptSummarizer` in `TranscriptSummary.swift`: notes instructions ("…two to five notes… ids…") and `condense` ("Write a two to three sentence summary… Reply with the summary alone.") | `TranscriptGeneratedNotes{notes:[{text, sources}]}` (sources validated: `p12`, `12`, `[p12]`) plus an overview. If the overview fails, `TranscriptSummary.overviewError` carries the reason; it is shown, never saved, and the notes stand. | Saved as a linked document, see note B |
| 21 | Person profiles; LLM guided | Up to 1200 characters per document, 8000 per person | `AuthorProfiles.defaultPrompt` in `PersonProfiles.swift`; key `"aiPersonProfilePrompt"`; enabled by `"aiPersonProfilesEnabled"` (on by default) | `GeneratedAuthorProfile{profile, interests}` | Application Support `AuthorProfiles.json` (with `digestedDocIDs`); shown on `AuthorPageView` "Personality" |
| 22 | Bot identify; LLM guided (Mac) | Typed name | `Bots.identificationPrompt` (`BotsView.swift`) | `GeneratedBotIdentification{isConfident, candidates≤5:[{name, years, summary}]}` | `BotStore` |
| 23 | Bot stance; LLM guided (Mac) | Person, plus a document digest (1500 characters) | `Bots.stancePrompt` | `GeneratedBotStance{verdict: agree\|disagree\|neutral, reason}` | Bot documents |
| 24 | Bot question; LLM | Person, library digests (500 characters each, 8000 total), question | `Bots.questionPrompt` | Plain text | Bots view (ctrl-click) |
| 25 | K. Nav keyword stances; LLM guided | Keyword plus up to 12 paragraphs of 400 characters, each labelled `== [address]` | `KNavView.computeProbe` | `GeneratedKeywordStances{stances:[{address, stance: positive\|negative\|neutral\|questions}]}` | K. Nav probe colours |
| 26 | Data-series plan; LLM guided | Natural-language request plus precomputed dates (today, −30, −183, −365 days) | `SeriesPlanner.plan(for:category:)` ("You translate a user's natural-language request for data lines into a structured fetch plan…") | `SeriesPlan{requests:[{kind, subject, metric, region, startDate, endDate, rangeWasStated, label}], command, commandTarget}` | Time Flows (Graphs) |
| 27 | Clarifying question; LLM guided | Request plus the problem | `SeriesPlanner.clarifyingQuestion` | `FollowUpQuestion{question}` | Time Flows, at most 3 rounds |
| 28 | Portraits (images, not a language model) | Name plus a style concept | `PortraitStyle.defaultConcept` / `botConcept`; keys `"portraitStyle"`, `"portraitPrompt"` | PNG in Application Support `PersonPortraits/` | People, Bots, Overview |
| 29 | visionOS "Summarize This Reading"; LLM, streamed | Title plus the first 12000 characters | `OrigamiVision.swift` ("You summarize academic and literary documents faithfully and plainly…") | Plain text; not saved | Vision reader |
| 30 | visionOS bots; LLM guided | As tasks 22–23 | `VisionBotStore` | `generate` with `VisionBotIdentification` and `VisionBotStanceReply` | Vision bots |

**Note A — reading analyses.**

- `ReadingAnalysisStore` writes `<annotationAddress>.analyses.json` in `AppModel.analysesRoot` (`epubsRoot/Analyses/`).
- The file is a map keyed by `"summary"` or `"issues"`. Each value is `StoredReadingAnalysis{text, names, keywords, created, dismissed?, glossary?}`.
- Regenerate replaces the entry; Remove deletes it.
- In the summary display, each glossary term shows the paper's own first and last sentence that uses it (`firstAndLastUse`).

**Note B — transcript summaries are documents.** `AppModel.saveTranscriptSummary` → `TranscriptSummary.makeDocument` writes a real document:

- titled "Summary — <title>", of type letter, with `aiOnBehalf: true`;
- with a link `summarizes` → the transcript;
- each paragraph ends with `[transcriptID#pN]` citations;
- written to the community folder with a Visual-Meta appendix, or to Drafts for a draft transcript;
- the author's earlier summaries of the same transcript go to the Trash.

**Where prompts are edited.**

- Settings ▸ AI ▸ "AI Prompts" covers Summary, Issues and Person Profiles, plus the Relevance field.
- The other prompts (Themes, Open Questions, Agreements, Disagreements, Stranger, Insights) are edited in their own views through `EditPromptButton`. They are stored under the `@AppStorage` keys listed above.
- `AIPrivacy.statement` (`SettingsView.swift`) tells the reader where text is sent.

### 3.6 Discrepancies against the stated AI rules

The project rule (memory "AI model routing") is to route all AI through `OrigamiLLM` and never use `try?` on a refusal. Every feature that used to call FoundationModels directly now goes through `OrigamiLLM.respond` or `generate`. Failures that used to be swallowed now say why:

- `AppModel.analysePublication` (paper topics) still skips a paper that fails, but keeps the last reason and shows it with `showNote` ("N of M papers could not be analysed: …", or "…no AI model answered: <reason>…" when none did).
- `AppModel.categoriseTopics` leaves a failed chunk's topics under Other and says so once, with the reason.
- Time Flows (`TimeFlowRequestView`) reports both errors when the clarifying question also fails.
- `TranscriptSummarizer` reports a failed overview through `TranscriptSummary.overviewError`.
- `AppModel.extractEntities` skips a book whose extraction fails and reports the first reason once.

The current source still departs from the rule in these ways:

1. **`ReadingAI` on iOS calls `LanguageModelSession` directly.** macOS and visionOS go through `OrigamiLLM`. (ReadingAI is not in the iOS target today, so this branch is not compiled.)
2. **Privacy wording is not conditional on the model.** Several tooltips still say the work happens "on this Mac — nothing leaves this Mac" or "nothing leaves it" (paragraph emotions and transcript summary in `DocumentDetailView`, the title suggestion in `DraftEditorView`, the person-profile caption in `AuthorViews`), even when a server model is chosen. `ORIGAMI-TEXT-OVERVIEW.md` likewise says "No text ever leaves the Mac" and calls the AI "entirely on your Mac". This holds only while the chosen model is Apple's or a local server. Remote endpoints can be added after an "Add Anyway" confirmation, and Check This Claim can query Semantic Scholar.

A rebuild should implement the intended rule:

- one `LLM.respond` / `LLM.respondStructured` entry point;
- structured output via JSON schema where the provider supports it;
- errors classified into unreachable / auth / unavailable / refused / overflow / failed, and shown to the user.

---

## 4. Library Views catalogue

### 4.1 The module mechanism

`LibraryViewModule` (`LibraryViewModule.swift`) has these fields:

- `id: String` — stable, lowercase, hyphenated;
- `name: String` — the sidebar label;
- `systemImage: String`;
- `makeContent: () -> AnyView` — the middle pane;
- `makeDetail: ((AppModel) -> AnyView?)?` — the detail pane; nil keeps the standard reader;
- `hidesDocumentList: Bool` (default false);
- `showInAppetite: .text | .note` (default `.note`).

How modules are listed and shown:

- `LibraryViewRegistry.modules` is the ordered list. `module(id:)` looks a module up; in debug builds it asserts that ids are unique.
- The sidebar lists modules through `SidebarCatalog.views`, which filters out the id `"authors"`.
- **Theme.** Every view wears the app theme (`ReaderTheme`, key `"readerTheme"`, plus edited colours). A view that paints its own background uses `.themedSurface()` (the theme's page behind, its ink in front). Chips, legends and labels that sit over lines use `.themedFill(in: shape)`, floating panels use `.readingThemeCard(...)`, and lines use the hierarchical `.secondary` style or a Canvas's `.foreground` shading, never `Color.primary`/`Color.secondary`, system materials or window colours. Both modifiers live in `LibraryViewModule.swift` and observe the theme themselves, so they repaint live. Lineage, which also builds for iOS and visionOS, reads the theme directly. Its paper and ink follow the theme, and the bloom keeps its ultramarine and ochre. These keep palettes of their own by design: The Weave's night canvas, K. Nav's weave mode, the Sphere Weave scene, ZigZag's and zzStructure's cell canvases, and The Deal's felt and cards.
- **Shown and hidden.** Only hidden ids are stored, in UserDefaults `"hiddenViewIDs"` (`AppModel.swift`, around lines 476–494). If the key is absent, every module not in `defaultShownIDs` is hidden. `setView(_:hidden:)` writes the whole array. Hiding the selected view moves the selection to `.epubsTimeline`. "Edit Views" opens Settings on the `.modules` tab. Once the user has made a choice in Edit Views, it always overrides the defaults.
- **Show In.** `showIn(viewID:selectedText:docID:)` builds a `ShowInPayload{viewID, text, docID}`. The selected text is passed only if the module's appetite is `.text`. The payload is consumed once through `takeShowInPayload(for:)`.

**`defaultShownIDs` as it is in the source** (`LibraryViewModule.swift`, around line 159):

```swift
static let defaultShownIDs: Set<String> = [
    // The dependable three for a new library; the experiments (The
    // Weave, The Deal, the AI reports) are one click away in Edit
    // Views.
    AskLibraryView.module.id,      // "ask-library"
    GlossaryView.module.id,        // "glossary"
    LineageModuleView.module.id,   // "lineage"
]
```

> Views are modules: which ones a fresh install shows is a choice, not part of the format. A rebuild may ship any set; the code currently shows three.

**Registry order** (21 modules):

| # | id | Name | Type |
|---|---|---|---|
| 1 | `ask-library` | Ask | `AskLibraryView` |
| 2 | `sphere-weave` | Sphere Weave | `SphereWeaveView` |
| 3 | `connections` | Connections | `DocumentWebView` |
| 4 | `weave` | The Weave | `WeaveView` |
| 5 | `authors-circle` | Author's Circle | `AuthorsCircleView` |
| 6 | `the-stranger` | The Stranger | `StrangerView` |
| 7 | `geometries` | Geometries | `GeometriesView` |
| 8 | `glossary` | Glossary | `GlossaryView` |
| 9 | `glossary-space` | Glossary Space | `GlossarySpaceView` |
| 10 | `k-nav` | K. Nav | `KNavView` |
| 11 | `ai-insights` | AI Insights | `AIInsightsView` |
| 12 | `themes` | Themes | `ThemesView` |
| 13 | `open-questions` | Open Questions | `OpenQuestionsView` |
| 14 | `agreements` | Agreements | `AgreementsView` |
| 15 | `disagreements` | Disagreements | `DisagreementsView` |
| 16 | `the-deal` | The Deal | `TheDealView` |
| 17 | `z` | Z | `ZView` |
| 18 | `zigzag` | ZigZag | `ZigZagView` |
| 19 | `zz-structure` | zzStructure | `ZZNavigatorView` |
| 20 | `citation-tree` | Citation Tree | `CitationTreeView` |
| 21 | `lineage` | Lineage | `LineageModuleView` (in `LineageView.swift`) |

Defined but **not registered**:

- `BotsView` (id `bots`) and `LiftWeaveView` (id `lift-weave`) each define a `.module` that nothing registers.
- `CalendarEventsView` is commented out behind `ORIGAMI_CALENDAR`.
- `PlacesView` (`places`), `AttentionsView` (`attentions`), `TrailsView` (`trails`), `HotParagraphsView` (`hot-paragraphs`) and `HealthDashboardView` (`health`) were taken out of the registry on 6 Oct 2026. They read what only Knowledge Space's notes carry — a location, addressees, trail documents and discourse links, links into paragraphs, the community folder's housekeeping — so on a shelf of EPUBs each could show only its empty state. Their files stay, in step with Knowledge Space, and their descriptions below still apply if a line is restored.

Not modules at all:

- `TimeFlows` provides the fixed sidebar items Graphs and Timelines.
- `LinksInspectorView` is the trailing inspector (⌥⌘L).
- `SankeySpace`, `SeriesPlanner` and `LibraryInsights` are helpers.

**Common inputs.** Unless noted, views read `model.index.byID`, `model.filteredEntries` (`IndexEntry` → `LiquidDoc`), `index.backlinks`, `latestRevision` and `supersededIDs`. None of the library views reads annotations or the Map's AI labels.

**Common AI view pattern** (Themes, Open Questions, Agreements, Disagreements, Stranger):

- The request is built from the corpus (3.4) and sent with `OrigamiLLM.generate` (guided generation on Apple, JSON Schema on a server).
- Addresses are grounded as in 3.3; results are held in memory only.
- The prompt is editable and persisted. An "Edit Prompt" button appears before the first run.
- Layout: a list at most 620 pt wide; rows expand, keyed by topic; each document row shows the title and "author · date" and opens on click.
- The module uses `makeContent = DocumentListView()`, `makeDetail = the view`, and `hidesDocumentList: true`.

### 4.2 Entries

**Agreements** (`AgreementsView.swift`)

- *Shows:* up to 6 points on which several documents genuinely converge. Each has a topic, a consensus statement and the documents, with an "N documents" capsule.
- *Inputs:* the corpus.
- *Algorithm:* the prompt rejects "merely sharing a subject" or citing without adopting, treats a `supports` link as a strong signal, and allows an empty list. After grounding, an agreement must keep at least 2 real documents.

**Disagreements** (`DisagreementsView.swift`)

- *Shows:* up to 6 disputes, "sharpest first". Each has a topic, the dispute, and two named positions with their documents, under an "N v M" capsule. Expanding a row shows the positions in italic, indented 36 pt, with their documents indented 54 pt.
- *Inputs:* the corpus.
- *Algorithm:* the prompt treats a `disagrees-with` link as a strong signal. During grounding, one shared `seen` set is used across both sides, so a document lands only on the first side it appears on. Each side needs at least one document.

**Attentions** (`AttentionsView.swift`)

- *Shows:* a still ring of people, with lines from each sender to the people a document is addressed "for the attention of".
- *Inputs:* `filteredEntries`; `doc.creditedAuthor` and `doc.attention: [String]`.
- *Algorithm:*
  - Names are unified case-insensitively, preferring the byline spelling. Self-addressed documents are skipped. A document counts once per pair.
  - People are sorted by `sent + received`, then by name.
  - The geometry is the same as Author's Circle: radius `min/2 − 70`, segments pulled back 30 pt and offset ±3 pt, width `1 + min(docs,7)`, hover distance 7 pt.
  - The hover card lists up to 10 documents. It is clamped to `x ∈ [150, w−150]`, `y = max(p.y − 60, 70)`.
  - If there are fewer than 2 people, it shows "No Attentions".
- *AI:* none.

**Open Questions** (`OpenQuestionsView.swift`)

- *Shows:* 3–8 unresolved questions, "most alive first". Each has a status sentence and its documents.
- *Algorithm:* the prompt notes that "A question one document has already settled is not open." Each question needs at least one grounded document.

**Hot Paragraphs** (`HotParagraphsView.swift`, using `LibraryInsights.hotParagraphs`)

- *Shows:* the paragraphs other documents cite most. Each row has a count badge, the text (3 lines), "title · author · ¶id" and "Cited in: …".
- *Algorithm:*
  - For each backlink target, group the references that have a fragment, and match each fragment to a body paragraph id.
  - Sort by citation count, descending, then by `listedDate`, descending.
  - The search field filters by text, title or author. Clicking opens the document at that paragraph.
- *AI:* none.

**Themes** (`ThemesView.swift`)

- *Shows:* 4–10 named themes (1–4 words each), "strongest first". Each has a one-sentence summary and its documents.
- *Algorithm:* the prompt says "Themes, not keywords" and "a theme that connects three documents is worth more than three themes with one document each". Grounding drops unknown addresses and any theme left with no documents.

**Time Flows** (`TimeFlows.swift`; macOS sidebar items Graphs and Timelines; data in `SankeySpace.swift`)

- *Shows:* yearly data series, drawn on the visionOS walls and floor and listed on the Mac.
  - "Graphs": the user's series plus 11 samples covering the last 150 years.
  - "Timelines": Wikidata event themes plus the user's own.
- *Inputs:* the community folder.
- *Algorithm — series:*
  - Points are averaged per UTC year; at least 2 years are required.
  - The pair key is the lowercased label with spaces replaced by "-". It replaces any existing series with the same key.
  - The natural-language flow is `SeriesPlanner.plan` (task 26) → `makeFetched`. A weather or market request with no stated range gets one range question ("The last five years", "Since 1960", "Since 1940"). Up to 3 clarifying rounds (task 27) follow; each answer is appended as "(The user clarified: …)".
- *Data sources:*
  - Open-Meteo geocoding and archive (daily max/min temperature since 1940, yearly extremes);
  - Our World in Data CSVs `https://ourworldindata.org/grapher/<slug>.csv`, rows where `Code == "OWID_WRL"`;
  - SILSO sunspots;
  - Wikidata SPARQL for floor themes (world, hypertext, hypertextPeople, environmental, space, computing, discoveries — each with its own link threshold and LIMIT);
  - `draftFloorQuery` drafts a query from a phrase via `wbsearchentities`.
- *Ink colours* (`inkChoices`): Ochre #967538, Sienna #6B4533, Wine #6E1A45, Rose #A3525E, Sand #B0A35E, Slate #4A5E6B, Olive #4C5736, Teal #36877A, Green #0D5E29, Indigo #291C6E.
- *Persistence:* in the community folder: `origami-sankey.json` (`Dataset{series:[Series{id, pair, name, role max|min, unit, values:[{year,value}], wall?, colorHex?}], modified}`), `origami-floor-history.json`, `origami-floor-<theme>.json` and `origami-floor-user-<slug>.json`.

**Trails** (`TrailsView.swift`)

- *Shows:* reading paths drawn as cards on a canvas, joined by curved threads, with "X of Y walked".
- *Inputs:* `index.byID`, `latestRevision`, `model.authorName`.
- *Algorithm:*
  - **Built-in trail "The Whole Library".** Text documents only (no bots or trails), ordered by `created`. A document's parents are its links with rel in {responds-to, extends, supports, questions, disagrees-with, revises}, resolved to the latest revision, restricted to older documents in the set and never itself. Shape `delta`.
  - **Shapes:** `canyon` (linear; each stop's parent is the one before), `delta` (branching), `plain` (unordered).
  - **Open rule:** a stop is open when every parent has been read or is not in the library.
  - **Layout:** column spacing 230, row spacing 92, card width 170, origin `(cardWidth/2 + 40, 70)`. Plain trails use a grid of `ceil(sqrt n)` columns. Other shapes put x by depth (the longest chain of parents, memoised; cycles count as roots) and y by row within that depth.
  - **Threads:** quadratic curves with control point `(mid.x, from.y)`. Opacity 0.5 and width 1.5 when the parent has been read, otherwise 0.2 and 1.
  - **Gestures:** click marks a stop read; double-click marks it read and opens it.
- *Persistence:*
  - UserDefaults `"trailProgress"` = `{trailID: [docID]}`.
  - A new trail is written as a document of type `trail`: p1 an explainer; p2 "Shape: x — explanation"; a level-2 "Stops" heading; lines `1. “Title” [id]` or `— “T” [id] after “P” [pid]`; and `cites` links to each stop.
  - On parsing, the first address on a line is the stop and an address after " after " is its parent.

**The Weave** (`WeaveView.swift`; `WeaveCanvas` is shared with K. Nav and Lift Weave)

- *Shows:* a dark wheel that rotates slowly. Document "knots" sit on the rim, grouped by author, with threads for links. The centre reads "THE WEAVE" and "N knots · M threads", or the hovered document.
- *Algorithm:*
  - Authors are sorted by document count, descending; author `i` gets hue `i/authors` (saturation 0.62). Documents within an author are ordered by `created`.
  - Knot weight is the backlink count. Knot radius is `(2 + min(6, sqrt(weight)·2))`, ×1.6 when hovered.
  - Edges are the document's links (canonical targets, no self-links), capped at 1200.
  - Rotation is `2π/240` rad/s plus accumulated drag. The view redraws at 30 fps. Ring radius `min/2 − 64`; hover hit 18 pt.
  - Threads are quadratic curves with control point `center + (mid − center)·0.35`, filled with a gradient between the two authors' hues. Idle opacity is `0.30 + 0.14·sin(0.7t + 1.3i)`.
  - On hover, unlit threads drop to 0.05; lit threads get a blurred pass (width 3.5) under a crisp one (width 1.4).
  - Probe threads (K. Nav): opacity `0.35 + 0.55·strength`, width `1 + 2·strength`.
  - Author labels sit at radius `ring + 30`.
  - Clicking a knot opens the document.

**Sphere Weave** (`SphereWeaveView.swift`, SceneKit)

- *Shows:* a 3D scene with a centre node and three shells — documents at r = 7, people at r = 11, places at r = 15 — with lines from the centre to everything connected to it. Clicking a node re-centres on it.
- *Inputs:* `index.timeline` (excluding digests, last 500), `libraryAuthorNames`, `backlinks`, `doc.location`, body text.
- *The centre*, in order: the Show-In payload (text or document), else the selected document, else the keyword "hypertext".
- *What counts as connected:*
  - keyword → documents whose title or body contains it;
  - document → its links, backlinks, author and place;
  - person → their documents and those documents' places;
  - place → the documents at that place.
- *Document magnets:* up to 12, chosen by a greedy set cover over title words. This is the same rule as `MapTopics` (the same stop words and short words).
  - A document joins the first magnet whose name equals one of its title words, or prefixes one when the name has at least 4 characters. Otherwise it joins the least-loaded magnet.
  - Magnet anchors are Fibonacci-lattice points (golden angle `π(3−√5)`, `y = 1 − (i+0.5)·2/n`), scaled to radius 8.3.
  - Members spiral inside a cap of `min(0.55, 0.12 + 0.08·sqrt n)` rad, with `rho = cap·sqrt((i+0.5)/n)` and `theta = i·2.399963`.
- *Scene:* camera at z = 34; background grey 235/255; lines black at 0.35 opacity. Colours: documents (0.32, 0.42, 0.62), people (0.29, 0.58, 0.42), places (0.74, 0.49, 0.24).

**Lift Weave** (`LiftWeaveView.swift`; not registered)

- *Shows:* a `WeaveCanvas` of extracts and their source transcripts.
- *Algorithm:*
  - A document is an extract if its `documentType` is extract, or if it has `onBehalfOf` and a `cites` link with a fragment.
  - The source is its first `cites` link, resolved to the latest revision.
  - A transcript's weight is the number of extracts lifted from it.

**Sankey Space** (`SankeySpace.swift`): a data store with no view of its own. It is described under Time Flows.

**Geometries** (`GeometriesView.swift`)

- *Shows:* the same library in five 200 pt-tall panes, two per row: The Line, The Hierarchy, The Sets, The Graph and The Canvas. The page cites Millard's "The Geometry of Thought". Selecting a dot in any pane selects it everywhere, and each pane rings its own neighbours.
- *Inputs:* `filteredEntries` with a body, excluding bots and trails, ordered by `listedDate`.
- *Neighbours in each pane:*
  - Line: index ±1.
  - Hierarchy: the same author.
  - Sets: the same `documentType` (default "letter"), plus a "for your attention" set.
  - Graph: on a circle; neighbours are in- and out-links.
  - Canvas: positions seeded by an FNV-1a hash of the id (offset 14695981039346656037, prime 1099511628211; `x = 20 + (h%1000)/1000·(w−40)`, `y = 20 + ((h/1000)%1000)/1000·(h−40)`). Dots can be dragged. Neighbours are the 2 nearest, measured against a fixed 400 × 200 reference.
- *Persistence:* none; canvas positions are held in memory.

**The Stranger** (`StrangerView.swift`)

- *Shows:* up to 5 findings (topic, position, answer, documents) and "the question the community writes around" (Challenge) or "is close to answering" (Support). If the model suggests switching modes, a panel offers to read again in the other mode.
- *Inputs:* the corpus. In Challenge mode, add the documents that receive `supports`/`extends` links but no `disagrees-with`/`questions` link (up to 8).
- *Algorithm:* the Challenge prompt looks for "what this community believes together but has never had to defend". The Support prompt looks for what the community "has genuinely right but undervalues".
- *Persistence:* "Put It on the Record" writes a document:
  - author "The Stranger", `aiOnBehalf = true`;
  - titled "A Stranger's Challenge" or "A Stranger's Support";
  - links (rel `questions` or `supports`) to every cited document;
  - a Visual-Meta appendix; file name `<slug>--<id>.<ext>`.

**The Deal** (`TheDealView.swift`)

- *Shows:* a hand of 5 random documents as playing cards (190 × 264) on green felt.
- *Inputs:* `index.byID`, minus superseded and retracted documents.
- *Algorithm:*
  - The hand is `shuffled().prefix(5)`.
  - Fan: `offset = i − (n−1)/2`, `x = mid + offset·190·0.82`, `y = mid + offset²·9`, tilt `offset·4°`.
  - Suit by document type: letter = heart, transcript = club, extract = diamond, rfc = spade.
  - The face shows the year, title, author and opening words (140 characters). The back shows metadata and link counts.
- *Gestures:* click flips a card; double-click opens it; dropping a card within `190·0.55` pt of another opens both side by side (`openTranspointing`).

**Health** (`HealthDashboardView.swift`, using `LibraryInsights.healthReport`)

- *Shows:* an overview (Documents, Superseded, Issues), then Unresolved Links, Duplicate IDs, Missing Wrapped Files, Unreadable Files and Unlinked Documents.
- *Algorithm:*
  - A link is unresolved if there is no `byID[link.to]`.
  - A document is unlinked if it has no out-links and no backlinks.
  - A file is "missing" if `wraps.file` does not exist relative to the document.
  - The issue count is unresolved + duplicates + missing + unreadable. Unlinked documents are not counted.

**Series Planner** (`SeriesPlanner.swift`; a helper, not a view)

- Turns natural language into `SeriesPlan` (task 26).
- Kinds: weather, market, statistic, space, unknown. Commands: none, lockTime, unlockTime, arrange.
- Statistic and space requests default to 1960-01-01 → today.
- `textMentionsRange` is true for any digit or for range words (last, past, since, year, month, …, month names, seasons).
- Series palette: 4A90D9, E2984A, 50B86C, D95757, 7B61FF, 39B8C4; space FFD60A; market 34C759.

**Z** (`ZView.swift`)

- *Shows:* a slip-box (Zettelkasten). The current slip appears with three shelves of up to 6 slips each: "← Cited by", "Folgezettel" and "Cites →". A breadcrumb trail runs along the top.
- *Algorithm:*
  - "Pull a Slip" picks a random non-superseded document.
  - Each step resolves to the latest revision. If the slip is already on the trail, the trail is cut back to it; otherwise it is appended.
  - Folgezettel are the documents by the same author immediately before and after this one in `created` order.

**Links Inspector** (`LinksInspectorView.swift`; the trailing panel, not a module)

- *For an EPUB:* "Relationships", "Links from This Book" (rel `cites`; nil counts as cites) and "Cited in Your Library" (passage citations merged with whole-book backlinks under the record id, `packageIdentifier` and DOI).
- *For a letter:* "Links from This Document" and "Backlinks".
- An unresolved link gets an "unresolved" capsule.

Further AI and Library entries from part (b):

- **AI Insights** (`AIInsightsView.swift`): a five-section report — "The live questions", "Agreement and dispute", "The unargued", "Missing connections", "The next document". Sections start collapsed, showing their first paragraph. Bracketed addresses are links. Uses task 17.
- **Ask** (`AskLibraryView.swift`):
  - Query terms are lowercased, split on non-alphanumerics, and kept if longer than 2 characters and not a stop word (the, and, for, with, what, does, about, that, this, from, have, how, why, who, are, was, were, which, into, their, there, they, say, says, library, my).
  - Each non-heading paragraph of more than 60 characters scores the number of terms it contains as substrings. Keep the top 3 per document, then the top 12 overall, each truncated to 700 characters.
  - The answer streams (task 11). `[n]` citations are parsed with `\[(\d+(?:\s*,\s*\d+)*)\]`; unknown numbers are removed.
  - Below the answer: a Sources list and "Answered by <model>, from your library's passages."
- **Bots** (`BotsView.swift`; not registered on the Mac):
  - Personas of named people. Each bot judges every document (agree / disagree / neutral), shown as coloured card borders, and answers questions.
  - Creating a bot: identify the person (task 22), pick a photo (Wikipedia lead images), then make an illustrated portrait.
  - Each bot is saved as its own `.origamitext` document in the community folder, holding its identity, its judgements and Visual-Meta.
- **Glossary** (`GlossaryView.swift`):
  - The user's own terms and glosses, with "Where the community speaks it". Occurrences are found with `\b<term>` (case-insensitive, word boundary on the left only, so "link" matches "links").
  - Terms can be adopted from `doc.concepts`.
  - Persistence: UserDefaults `"personalGlossary"` (`[{id, term, gloss}]`). Publish writes a document of type `glossary` with `concepts`.
- **Glossary Space** (`GlossarySpaceView.swift`): a spring layout of glossary terms.
  - Edge weight = `3·paragraphs + documents + (glossed ? 4 : 0)`.
  - `arrange()`: seed with FNV-1a; `ideal = min(w,h)/sqrt(max(n,2))·0.9`; **120 iterations**; repulsion `ideal²/d`; attraction `d²/ideal·(0.4 + 0.6·w/maxW)`; step capped at 12; clamped to x ∈ [70, w−70], y ∈ [50, h−90].
  - Font size `12 + min(count,24)/3`.
- **Library Insights** (`LibraryInsights.swift`): helpers for hot paragraphs, author summaries, health, and `RevisionDelta`. `RevisionDelta` pairs edited paragraphs greedily by Jaccard word similarity of at least 0.4; `percentChanged = round((edited+added+removed)/total·100)`.
- **Reading Analysis** (`ReadingAnalysisView.swift`): the per-document "AI" screen. Uses tasks 4 and 5 and note A. Clicking a term opens a Find column (`@AppStorage("aiColumnView")`).

---

## 5. visionOS note (visionOS only)

These files are in `Origami Text macOS/`, but each is wrapped in `#if os(visionOS)`, so they compile to nothing on the Mac. A Mac-only rebuild can skip this section.

**`OrigamiVision.swift`** (around 7500 lines) is the visionOS app (`OrigamiVisionApp`, state in `VisionModel`). Its scenes:

- windows: `library`, `documents`, `lineage`, `settings`, `graphdata`, `reader` (per docID), `figure`, `context`;
- volumes: `space`, `concepts`, `authors`, `weave`, `bots`, `zz`;
- one mixed **immersive space**, `arms`, which hosts `EPUBMapView`. It opens at launch so the arm menus are always present.

The reader pulls 3D figures off the page: drag 40 pt (`pullThreshold`), or double-tap. This follows ORIGAMI-3D-MODELS-PLAN.md and Profile §6.9. The reader also offers read aloud, the Context panel and a summary (task 29).

**`EPUBMapView.swift`, the hallway.** The venue Map as a room, built on `NodeImmersiveView`.

- **Article wall:** `wallColumns = max(1, Int(sqrt(n·7)/2))`, the same as the Mac seed. Card size is 0.116 × 0.045 m × 1.15, with a 0.05 m gap. The wall top is clamped between 1.55 and 2.15 m. Article z is set by publication year.
- **Citation walls:** selecting an article raises a wall of its references at origin (0, 1.95, −1.6); depth runs from 0.4 to 12 m by year. Selecting a cited work raises its own references, up to 48.
- **Other elements:** a concept "galaxy" (radius 1.9 m), a topic-magnet row (the same `MapTopics.names`), floor timelines and Sankey walls from Time Flows, spatial notes, and 3D models.
- **Arrangements:** Wall, Magnetic Center, Islands, Orbits and Neighborhoods. Spine falls back to Magnetic Center.
- **Pile gestures:**
  - drop a card below y 0.15 m → Set Aside;
  - lift it above 2.0 m → Pin;
  - lift a set-aside card to 0.9–2.0 m → Bring Back.
- **Fist grab** carries the whole space: the hand closes within 0.055 m and re-opens beyond 0.075 m; the pose must be held 0.2 s; carry gain 2.5.
- **Persistence:** `EPUBMapLayout.json`, plus X/Y pushed to the shared `origami-map-layout.json`, so the Mac sees the same arrangement (section 2.7).

**`ArmMenu.swift`** is a wrist-mounted chip menu, ported from the Author app.

- It uses one hand-tracking session (a second one breaks the device), with predicted anchors on the wrist, forearm, index knuckle and little knuckle.
- Every frame:
  - **Fade:** the menu fades in or out at a rate of `dt·5`.
  - **`alongArm`:** the normalised direction from wrist to forearm. If the forearm is not tracked, ±X by the sign of the index knuckle.
  - **`lift` (the back of the hand):** `cross(index − wrist, little − wrist)`, negated for the right hand. The part along the arm is removed and the result normalised.
- Chip positions:
  - top row: `alongArm·(rowStart + 0.05·i) + lift·0.05`, where rowStart is 0.10 with a watch, otherwise 0.02 (right) or 0.04 (left);
  - underside: `alongArm·(0.04 + 0.05·i) − lift·0.12`;
  - watch face: `alongArm·0.045 + lift·0.045`;
  - sub-chips form a ladder with 0.026 m steps, or a fan (reach 0.05, step 0.05, lane 0.026), eased with time constant 0.07 s.
- Chip collision box 0.06 × 0.035 × 0.03 m. "Swap Arms" is stored in `@AppStorage("armMenuInverted")`.
- The project memory flags the back-of-hand sign as still needing a check on the device.

**`NodeImmersiveView*.swift`** is a generic RealityKit node canvas, also ported from Author.

- Each item's SwiftUI view is rasterised onto a textured plane at 1 pt = 1 mm.
- Nodes are diffed by id; an entity is rebuilt only when it changes visually.
- Gestures: taps (1, 2 or 3), long press (0.8 s), drag with an optional `constrainMovedNode` hook, pinch (in at ≤ 0.8, out at ≥ 1.2).
- `MovableConnectionsSystem` stretches line entities between connected nodes and hides any shorter than 0.01 m.
- Six 10 m invisible boxes catch pinches made anywhere.

**`KnowledgeSpaceAnchoring.swift`** provides world anchors and snapping cards to surfaces: `snapDistance 0.5`, `surfaceOffset 0.005`, anchors saved in UserDefaults `"knowledgeSpace.anchors"`. A search of the code found **no references to it**, so it is inactive.

**Portable equivalent:** WebXR with three.js or Babylon.js, using hand-tracking joints `wrist`, `index-finger-metacarpal` and `pinky-finger-metacarpal`, or OpenXR on Quest or Android XR. Keep the metre coordinates and the shared layout file so a headset and a desktop see the same arrangement.

---

## 6. Platform notes and portable equivalents

| Apple piece | Where | Portable equivalent |
|---|---|---|
| SwiftUI `Canvas`, `Path`, `TimelineView` (30 fps) | Weave, Attentions, Author's Circle, Geometries, Trails, the Map's threads | HTML `<canvas>` 2D with `requestAnimationFrame`, or SVG for the static diagrams. Use D3 for scales only; the layouts here are closed-form and need no D3 force. |
| `ScrollView([.horizontal,.vertical])` over a 2600 × 1800 ZStack | Venue Map | A fixed-size absolutely-positioned `<div>` inside an `overflow: scroll` container, or a pan-only canvas. Keep the size and `pointsPerMeter = 620`. |
| SceneKit `SCNView`, `SCNText`, billboard constraints | Sphere Weave | three.js with a `PerspectiveCamera` at z = 34, `OrbitControls`, and `CSS2DRenderer` or sprite labels. |
| RealityKit, `ImmersiveSpace`, `AnchorEntity(.hand)`, `SpatialTrackingSession` | visionOS hallway, ArmMenu, NodeImmersiveView | WebXR (three.js, Babylon.js), Unity or Godot with OpenXR. Hand joints are available in WebXR Hand Input. |
| MapKit `Map`, `CLGeocoder` | Places | Leaflet or MapLibre with OpenStreetMap tiles, and Nominatim or Photon geocoding. Cache in the same `PlaceDirectory.json` shape. |
| FoundationModels `LanguageModelSession`, `@Generable` guided generation | 3.5 | Any local LLM through the Ollama API or an OpenAI-compatible `/v1/chat/completions` endpoint. For guided output, send a JSON Schema: Ollama `format: <schema>`, or OpenAI `response_format: {type:"json_schema"}`. Then validate and ground as in 3.3. |
| `NLEmbedding.sentenceEmbedding` | K. Nav | Ollama `/api/embeddings` (for example `nomic-embed-text`), or sentence-transformers. The cosine thresholds (0.6, 0.35, 0.12, 0.25, 0.5) were tuned for Apple's embedding and should be re-tuned for a different model. |
| `NLTokenizer` (sentences) | Explain in Context, paragraph breaks | ICU `BreakIterator` or `Intl.Segmenter('en', {granularity:'sentence'})`. Note that `ReadingAI.flowLines` has its own abbreviation rules (`endsInAbbreviation`); port those as well. |
| Keychain | API keys | The OS credential store (libsecret, Windows Credential Manager) or an encrypted file. Read keys only when sending a request. |
| UserDefaults / `@AppStorage` | Keys listed throughout | A JSON settings file. Keep the key names so exported settings stay meaningful. |
| Security-scoped bookmarks, iCloud placeholder download | Community folder files | Plain file access. Keep the per-entry newest-`t`-wins merge (2.7), because sync tools such as Dropbox and Syncthing can deliver stale copies. |
| ImagePlayground `ImageCreator` | Portraits | Any local image model (for example Stable Diffusion via ComfyUI). This feature is optional. |
| NSEvent monitor for ⌘A, `NSSound.beep` | Map | A keydown listener on the canvas (skipped while an input has focus), and an audio cue or a short shake. |

---

## 7. Rebuild order and acceptance checks

### 7.1 Order

1. **Shared map data:** `EPUBMapSharedLayout` (merge), `EPUBMapViews`, `MapTopics`. These are pure functions with file I/O, and should be unit-tested first.
2. **Venue Map, Default:** the canvas, metre conversion, seeds, drag and persist, lift, the double-click rule, the pin and set-aside floor, and the 4 s sync beat.
3. **Computed views** (Topics/Authors/People via `applyComputed`), `planeFit`, Author Rank, then saved views.
4. **Magnet bar:** naming, pull, focus threads, rename, Arrange.
5. **`OrigamiLLM` equivalent:** settings, server detection, streaming chat, fallback notice, error classes, and a structured-output helper.
6. **Extraction and topics** (tasks 8–10), writing `_document-extractions.json` and `_publication-analyses.json`, so the Map's facets fill in.
7. **Module registry** with `hiddenViewIDs` and `defaultShownIDs`, and Show In.
8. **Non-AI views:** Hot Paragraphs, Health, Attentions/Author's Circle, Connections, The Weave, Trails, Z, The Deal, Geometries, Glossary and Glossary Space.
9. **Grounded AI views:** Ask, then the corpus builder and Themes/Open Questions/Agreements/Disagreements/Stranger/Insights.
10. **Reading AI:** paragraph breaks, key sentence, summary and issues with note A storage, and the Context panel's Explain and Check.
11. **Optional:** Time Flows, Bots, Sphere Weave, K. Nav, the Author's Map, and the headset hallway.

### 7.2 Acceptance checks

**Map layout and persistence**

- [ ] With 20 papers and no stored layout, Default places them in `max(1, Int(sqrt(140)/2)) = 5` columns, at 0.28 m (173.6 pt) column pitch and 0.18 m (111.6 pt) row pitch, with the first row at y = 1.55 m (canvas y = cy − 217).
- [ ] Dragging one card in Default rewrites only that card's entry in `origami-map-layout.json`, with a fresh `t`. Every other entry, including other venues', is byte-for-byte unchanged in value.
- [ ] Merging two layout files where key K has `t` = 10:00 in one and 10:05 in the other keeps the 10:05 position, whichever file it came from. An entry with no `t` loses to any stamped entry.
- [ ] In the Topics view, a label carried by exactly one paper never becomes a magnet. At most 14 magnets are shown. With 9 or more magnets the ring radius is 580; with 8 or fewer it is 430.
- [ ] Dragging in Topics/Authors/People/Rank never changes the shared layout file.

**Magnet bar**

- [ ] With titles "Hypertext Systems", "Hypertextual Writing" and "AI Maintenance", the pole "Hyper" pulls the first two, and the pole "AI" pulls only the third (not "maintenance").
- [ ] The magnet bar never shows two names where one contains the other (for example "Hypertext" and "Hypertext Systems").
- [ ] Clearing every magnet slot and pressing Return removes `mapMagnets:<venue>` and the names are generated again.

**Card gestures**

- [ ] A click within 0.5 s after a drag does not lift the card. A double click opens the book.
- [ ] Set Aside first moves the card to its floor point, then dims it to 0.45.

**AI routing and grounding**

- [ ] With an Ollama server chosen but not running, Ask still answers (from Apple, or fails with Apple's reason) and shows "<model> wasn't available — used Apple's built-in model instead."
- [ ] With a server chosen that needs a key and has none (HTTP 401), Ask shows the "needs an API key" error. It does not fall back to Apple.
- [ ] With a server model chosen, Themes sends `response_format: {type: "json_schema"}` and reads the reply into the same `GeneratedThemeList` as Apple's guided generation.
- [ ] With no Apple model and no server, every AI view stays in the sidebar and explains why it cannot run. No control is hidden.
- [ ] Themes, Agreements and the others never display a document address that is not in the index. An agreement that grounds to only one document is not shown.
- [ ] Explain in Context drops any sentence whose quotation is not in the material, and reports how many sentences it dropped.
- [ ] Paragraph-break output never changes a word of the original paragraph, and never produces a segment shorter than 3 sentences.
- [ ] Summary and Issues for an EPUB are saved in `Analyses/<annotationAddress>.analyses.json` under the keys `summary` and `issues`, and survive a relaunch.
- [ ] A transcript summary appears as its own document titled "Summary — <title>", with a `summarizes` link and `aiOnBehalf: true`.

**Library Views registry**

- [ ] On a fresh install (no `hiddenViewIDs` key), the sidebar shows exactly the modules in `defaultShownIDs`: currently Ask, Glossary and Lineage. Showing a view in Edit Views survives relaunch.
- [ ] Hiding the currently selected view moves the selection to the EPUB timeline.

**Other views**

- [ ] In Ask, citation `[99]` (no such passage) is removed from the answer text. `[2, 99]` becomes a link for 2 only.
- [ ] Trails: on the built-in library trail, a reply is locked until its parent document is marked read, and a parent that is not in the library never locks.
- [ ] The Weave completes one rotation every 240 s when idle.

**Author's Map**

- [ ] For a book with `space.convention: "y-up"`, nodes are mirrored vertically compared with a book without it.
- [ ] Tapping a passage card opens the reader at that paragraph.
- [ ] With nothing selected no lines show; selecting a concept draws a solid line to each concept its definition names (whole word) and a light line from each concept whose definition contains its name.
- [ ] Moving a concept, then reopening the book, keeps the move; Layout ▸ Author's Layout restores the book's positions, and the EPUB is unchanged.
- [ ] ⌘M opens and closes the Map in a book that has one, and still minimizes in one that doesn't.
- [ ] A concept in `map.nodes` with no view position is not drawn at (0, 0).

### 7.3 Open items (unclear from source or not verified)

- **Default Views count:** 3 in code, 8 in the docs (see 4.1).
- Whether the Mac Map should eventually get zoom. It has none in the current code.
- The `KnowledgeSpaceAnchoring` surface snapping is not referenced anywhere. Unclear whether it is planned or abandoned.
- `WatchViewOption.timeline` is defined in the hallway but not offered.
- Many headset behaviours are listed in project memory as built but not yet checked on the device: fist grab, Map performance, the arm menu's back-of-hand sign, figure pull. Treat their constants as provisional.
