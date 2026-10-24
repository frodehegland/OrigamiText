# Defined Concepts across Author, Origami Text and Liquid

*Plan, 23 October 2026. Status: Origami Text's side built the same day
(`ConceptLibrary.swift`, `ConceptLibraryModel.swift`,
`ConceptLibraryView.swift`, Settings ▸ Concepts, Views ▸ Defined
Concepts; the open format in `ORIGAMI-CONCEPTS-FORMAT.md`) — a folder of
plain JSON in Author's record shape, Origami's additions in
`extensions/`, imports from the library's books, Author documents and
Author's library folder, SKOS export; no Apple service in the format.
Later the same day, the rest: Origami's drafts carry their concepts in
Author's `glossary.json`, Define Concept… on any selection (reading or
writing), a document takes the library concepts its text mentions at
export, Concept Space and Tracked Concepts read the library; Author's
package gained tolerant decoding, `extensions/` records (occurrences,
flags, alt names), `library.json`, both `GlossaryEntry`s the
`conceptID`/`versionID` pointer (set after sharing) plus the citations
and `lens` fixes, and the Mac and iOS entitlements name
`iCloud.com.liquid.Author`. Author macOS, Core (iOS) and Author Mobile
(visionOS) build. Liquid followed the same day, twice over. First into
`~/Documents/Liquid Information` (the older spatial-hypertext app), which took
`ConceptLibrary.swift` verbatim (both copies gained `ConceptLayout` and
the store's layout read/write), a `ConceptLibraryModel` that adopts the
Author container by itself, the library as a "Defined Concepts"
structure (`InfoNode.conceptID`, arrows for relations, hairlines where a
definition names another concept, positions from and written back to
`layouts/`), Define Concept from any node, a Defined Concepts window
reachable from the library, the editor panel, the arm menu and ⌘⇧D, and
the container in its entitlements. See its `Docs/ConceptLibrary.md`. Then,
Frode calling that the old app, the new **Liquid** at
`~/Documents/Liquid App`: Author's own base — the `ConceptLibrary` package
copied whole, Author macOS's library window and Map (`ConceptsWindow.swift`)
on the Mac, the concept half of Author visionOS's Liquid surface (the Wall:
pills on the curve, sticking to surfaces, Sphere/Cylinder/Orbits, the
bars, the arm chips) on Vision Pro, Wall positions in
`layouts/liquid-wall.json`. Sources type-checked for both platforms; the
Xcode project itself is Frode's to create. See its `Docs/README.md`. One
library of Defined Concepts, shared by iCloud, read and written by Author
(macOS, iOS, visionOS), Origami Text (macOS, iOS, visionOS) and the new
visionOS app Liquid — in one form, with one data model, learning from
knowledge-graph practice without becoming a knowledge graph.*

## 1. What exists today

**Author** (`~/Documents/author_mac_forxcode`) already has two layers:

- **Per document**: `Contents/glossary.json`, a dictionary of
  `GlossaryEntry` by UUID — `phrase` (comma-separated: name, then
  alternative names), `description` (the definition), `type`, `tag`
  (Person, Note, Label, Title, Section, Document, Citation, Map…),
  `urls [{description, url}]`, `citationIdentifiers` (that document's
  citation UUIDs), `documentPath`/`documentName`, `internalLinkId`,
  `headingNote`, `date`, `isLiked`, `isContext`, `isWorking`, `isHidden`,
  `position {x,y,z}`, `sense`, `lens`. Entries tagged `section`,
  `citation`, `heading`, `reference`, `lens`, `note`, `label`, `document`
  are Author's own machinery, never concepts.
- **Across documents**: the **ConceptLibrary** package
  (`Dependencies/ConceptLibrary`), called the Knowledge Space in the UI.
  Files in the iCloud Drive container, at its root: `Concepts/concepts/
  <conceptID>.json` (one concept per file, an **append-only event log**:
  `version`, `used`, `deleted`, `restored`, `merged`, ordered by
  `(sequence, created, id)`), `index.json` (rebuildable cache),
  `map/layout.json`. Terms normalised (case, accents, quotes, dashes,
  whitespace). Edges are implicit: a concept's definition naming another.
  Document entries publish to it on save (`shareWithKnowledgeSpace`);
  seeding reads every document's `glossary.json`. **The pointer from a
  document entry to its library concept was never built** — matching is
  by name only. Known faults: the Mac is entitled only to
  `iCloud.com.liquid.auhor.osx`, visionOS to `iCloud.com.liquid.Author`,
  so **Mac and headset likely keep separate libraries**; the Mac
  `GlossaryEntry.init` drops `citationIdentifiers`; iOS/visionOS `Core`
  has no `lens` field; the editor matches substrings while exports match
  whole words.

**Origami Text** has no library of its own. Concepts arrive per document
from EPUB Visual-Meta (`LiquidDoc.Concept`: `id`, `name`, `description`,
`userDefinition`, `tag`, `citationIdentifiers`, `urls`, `markedForms`),
are merged by lowercased name into `MergedConcept` for the library views,
with personal definitions and categories in
`origami-concept-overrides.json` (unsynced), Tracked Concepts as names in
`origami-standing.json` (synced through the community folder), and Concept
Space layouts per physical room (ARKit anchors). Profile 1.0 §9.4 fixes
the EPUB record: `concepts[] {id, name, description, tag, urls[],
citationIdentifiers[], href}`, open to extra properties.

**Knowledge Space** carries the same `GlossaryTerm`; **Liquid Information**
and **Interatlas** have no concept model. **Liquid (visionOS)** does not
exist yet.

## 2. What the field teaches

- **SKOS** ([Reference](https://www.w3.org/TR/skos-reference/),
  [Primer](https://www.w3.org/TR/skos-primer/)): one `prefLabel` per
  language, any number of `altLabel`s (synonyms, acronyms), `hiddenLabel`s
  (misspellings, for search only), `definition`, `scopeNote`, the
  relations `broader` / `narrower` / `related`, and the **mapping**
  relations `exactMatch` / `closeMatch` / `broadMatch` to concepts in
  *other* schemes — deliberately not `owl:sameAs`, so linking to Wikidata
  never merges our record into theirs. Author's comma-separated
  alternatives are altLabels; its `sense` is a scopeNote.
- **Topic Maps, ISO 13250** ([XTM](https://www.topicmaps.org/xtm/),
  [ISO text](https://xml.coverpages.org/TM-iso13250-2nd-ed-v2.pdf)): a
  topic has names, **occurrences** (where it appears) and roles in
  associations; **subject identifiers** (URIs) decide when two topics are
  the same thing; **scope** says in which context a name or occurrence
  holds. This is the exact shape of a Defined Concept with its
  appearances across documents, and the reason the library must record
  occurrences, not only definitions.
- **Personal Knowledge Graphs** ([Balog & Kenter
  2019](https://dblp.org/rec/conf/ictir/BalogK19.html), [Skjæveland et
  al. 2024](https://www.researchgate.net/publication/370127315_An_Ecosystem_for_Personal_Knowledge_Graphs_A_Survey_and_Research_Roadmap)):
  a PKG holds only what matters to its one user, including things no
  public graph knows; owned by that person; entities and relations may be
  short-lived. The lesson: do not build Wikidata — build the reader's
  own vocabulary and *point* at Wikidata where it helps.
- **Local-first software** ([Ink & Switch
  2019](https://www.inkandswitch.com/essay/local-first/)): data lives on
  the device, servers only sync; CRDTs merge concurrent edits. Author's
  append-only per-concept event log **is** a CRDT (a grow-only set of
  events with a total order), which is why union-merge of two file
  versions is always safe. Keep it.
- **Apple's sync choices**: `NSUbiquitousKeyValueStore` is capped at 1 MB
  and 1024 keys ([Apple](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForDocumentsIniCloud.html)) —
  far too small. CloudKit's `CKSyncEngine` ([WWDC23](https://developer.apple.com/videos/play/wwdc2023/10188/),
  [docs](https://developer.apple.com/documentation/cloudkit/cksyncengine))
  handles scheduling and retries but leaves `serverRecordChanged`
  conflicts to the app, needs a deployed schema, and keeps the data in
  records no text editor can read. iCloud Drive files with
  `NSFileCoordinator` and `NSFileVersion` conflict handling
  ([TN2336](https://developer.apple.com/library/archive/technotes/tn2336/_index.html))
  fit a per-concept JSON log, and fit the lab's principle that a person
  with a text editor can read everything.
- **PKM tools** (Obsidian, Logseq, Tana): what people now expect of a
  concept — **aliases** that resolve on click, **backlinks** (occurrences)
  on every concept, typed **properties**, and plain-text portability
  (Logseq's lesson: syntax no other tool reads is a trap).
- **schema.org `DefinedTerm` / `DefinedTermSet`**
  ([schema.org](https://schema.org/DefinedTerm)) and the **Wikidata
  reconciliation API** ([OpenRefine
  docs](https://openrefine.org/docs/manual/wikibase/reconciling)) give a
  web-facing export and a way to attach a QID as `exactMatch`.

## 3. The decision

**One library, as files, in one iCloud Drive container, read and written
by every app through one Swift package.** Keep Author's ConceptLibrary
design — one JSON event log per concept — extend its record, and give the
other apps the same code.

### 3.1 How it is shared

- **Transport: iCloud Drive, the ubiquity container
  `iCloud.com.liquid.Author`**, which Author for visionOS already uses.
  Every app adds it to its entitlements (Frode, in Xcode): Author macOS
  (fixing the split from `iCloud.com.liquid.auhor.osx`), Author iOS,
  Origami Text macOS/iOS/visionOS, Liquid. Apps of one team may share a
  container. The data stays private to the Apple ID; nothing of it enters
  the community folder (concepts are the reader's own, like muting).
- **Layout inside the container**, as today plus two folders:

  ```
  Concepts/
    concepts/<conceptID>.json     the record: an append-only event log
    layouts/<spaceID>.json        positions per space (see 3.3)
    index.json                    cache, rebuildable from concepts/
    library.json                  the library's own id, created, format version
  ```

- **Discipline**: every read and write through `NSFileCoordinator`;
  `NSMetadataQuery` to see files arrive and `startDownloadingUbiquitousItem`
  for evicted ones; an `NSFilePresenter` for each app's change
  notifications; **conflict versions resolved by union of events**, then
  marked resolved and removed. A file is only ever appended to, so two
  devices editing the same concept offline lose nothing. Author's rule
  that conflicts stay small because one concept is one file stands.
- **The code**: lift `Dependencies/ConceptLibrary` out of Author into its
  own repository (as AuthorKit was), pinned by every app — Author ×3,
  Origami ×3, Liquid. Pure Foundation, no AppKit/UIKit, so it builds
  everywhere. Readers are **tolerant**: unknown event kinds and fields are
  kept and re-emitted, never dropped (the format rule the Origami document
  format already has).

### 3.2 The record — one Defined Concept

The event log's `version` event grows from Author's `term, definition,
tags, urls, citationIDs, originDocumentName` to this; `head` is the
newest version, as now.

| Field | Type | From / for |
|---|---|---|
| `id` | UUID string | Author `identifier`; Profile `concepts[].id`; `gloss-<id>` in EPUBs |
| `labels` | `[{value, lang?, kind: pref \| alt \| hidden}]` | SKOS labels; Author's comma alternatives become `alt`; Origami `markedForms` become `alt`; misspellings `hidden`. One `pref` per language (§5.5 multilingual rule) |
| `sense` | string? | Author `sense`; SKOS scopeNote — "model (statistics)" |
| `definition` | `{text, lang?, source: user \| document(<docID>) \| ai(<model>)}` | Author `description`; Origami `userDefinition` vs AI `description`, kept apart by `source` |
| `kind` | string, open vocabulary | Author `tag` / Origami `category`: `concept`, `person`, `institution`, `place`, `work`, `method`… ; `concept` default |
| `urls` | `[{description?, url}]` | as Author |
| `citations` | `[{bibtex?, doi?, address?, label}]` | **stable** citation identity (DOI, ISBN, Origami address) instead of per-document citation UUIDs, so a concept's sources survive the document |
| `relations` | `[{kind: broader \| narrower \| related \| partOf \| opposes…, to: conceptID}]` | SKOS semantic relations, explicit; Author's implicit "definition names it" edges stay derived |
| `matches` | `[{kind: exact \| close \| broad, scheme, identifier, url}]` | SKOS mapping: Wikidata QID, ACM CCS node, ORCID for a person, a DOI for a work-concept |
| `extensions` | `{appID: JSON}` | app-private data: Author's `lens`, `isContext`/`isWorking`, Origami's tracked flag — carried by every app, understood by one |

Separate event kinds, as today, carry the rest:

- **`used`** — an **occurrence**: `{document: <stable id>, title, fragment?,
  form?, app, device, created}`. The stable document id is the Origami
  address / DOI / EPUB `dc:identifier` from Visual-Meta, with Author's
  `documentName` kept as a fallback. This is the backlink list every app
  shows, and what Liquid walks.
- **`deleted`, `restored`, `merged(into)`** — unchanged.
- **`flagged`** — `{flag: liked \| tracked \| hidden, on: Bool}`, replacing
  Author's per-entry `isLiked`/`isHidden` and Origami's Tracked Concepts
  list at library level (documents keep their own copies).

### 3.3 Spatial layouts

Positions never live on the concept (the Visual-Meta rule: layouts hold
position and connection only). `layouts/<spaceID>.json` holds
`{space: {id, name, kind: authorMap(<docID>) \| conceptSpace(<room>) \|
liquid(<scene>)}, positions: [{id, x, y, z}], connections: [{from, to}]}`.
Author's per-document Map positions, Origami's per-room Concept Space
(ARKit anchor ids) and Liquid's scenes are each a space; a concept can sit
in many. The Origami EPUB `map` record and Author's `DynamicView.json`
are exports of a space, as they are now.

### 3.4 The three layers, and who is authoritative

1. **The library** (container) is the master copy of a concept's
   definition, labels, relations, matches and occurrences.
2. **Documents stand alone**: `glossary.json` in a `.liquid`,
   `concepts[]` in an EPUB's Visual-Meta, `concepts` in an `.origamitext`
   keep a full copy, as today — and gain the pointer: `conceptID` (the
   library id) and `versionID` (the event they copied). A document opened
   where the library has moved on shows the difference and offers to take
   the newer definition or push its own. This is the pointer Author's
   header comment promised; it is built in both the Mac `GlossaryEntry`
   and `Core`'s.
3. **App caches** are rebuildable: Origami's `origami-concept-overrides.json`
   folds into library `definition`/`kind` events and is retired; Tracked
   Concepts become `flagged tracked` events, still mirrored into
   `origami-standing.json` for the headset until it reads the library.

### 3.5 Interchange

- **EPUB (Profile 1.0 §9.4)**: `concepts[]` gains optional `altNames[]`,
  `sense`, `matches[]`, `conceptVersion` — all allowed as extra
  properties; `id` is the library id. `@{glossary}` in Visual-Meta gains
  `alt-name` lines it already has and a `match = {wikidata:Q…}` field.
- **SKOS / JSON-LD export** of the whole library or one concept: a
  `skos:ConceptScheme` with `prefLabel`/`altLabel`/`hiddenLabel`,
  `definition`, `scopeNote`, `broader`/`related`, `exactMatch` — the
  lingua franca for anyone else's tools; and a `schema.org/DefinedTermSet`
  rendering for the web.
- **Wikidata reconciliation**, user-invoked only (never at launch, per
  the no-startup-network rule): offer QID candidates for a concept, store
  the choice as `matches[exact]`, fetch and cache the English label.

### 3.6 Liquid (visionOS)

A spatial reader of the library: concepts as cards, occurrences as the
documents behind them (opened in Origami Text for visionOS by address),
relations and matches as lines, spaces as rooms. It writes `layouts/`,
`flagged` and `version` events through the same package; it never edits
documents. It is the first consumer with no legacy, so the package's API
is designed from its needs: `library.concepts`, `concept(id)`,
`occurrences(of:)`, `related(to:)`, `space(id)`, `append(event)`.

## 4. Build order

0. **Container and entitlements** (Frode, Xcode): `iCloud.com.liquid.Author`
   on Author macOS and the three Origami targets. Verify one library from
   Mac and headset. This alone fixes the Mac/visionOS split.
1. **The package**: ConceptLibrary into its own repo; tolerant decoding;
   the record above, written as new event fields while old events still
   read; `used` with stable document ids; `flagged`; `layouts/`;
   `library.json`; SKOS/JSON-LD export. Tests: merge of divergent logs,
   conflict-version union, old-file round trip.
2. **Author**: adopt the package in Mac and Core; build `conceptID`/
   `versionID` on both `GlossaryEntry`s; fix the Mac init dropping
   citations and Core's missing `lens` (moved to `extensions.author`);
   publish occurrences with the document's stable id; one matching rule
   (whole words) for editor, export and library.
3. **Origami Text**: adopt the package on all three targets; `MergedConcept`
   joins the library by id (then by normalised term); overrides migrate;
   Tracked Concepts become flags; Concept Space rooms become spaces; EPUB
   import resolves `concepts[].id` against the library; export writes
   library ids and matches; the Concepts views show occurrences across
   the library (the backlinks people expect).
4. **Liquid**: the new app on the package.
5. **Reconciliation and web export**: Wikidata matching, DefinedTermSet.

## 5. Not in this plan

Sharing concepts with *other people* (that is the community folder's
job, later, as documents carrying their glossaries already do); AI
extraction becoming library concepts without a person's say; replacing
Author's or Origami's document formats.

## Sources

- SKOS Reference — https://www.w3.org/TR/skos-reference/ ; Primer — https://www.w3.org/TR/skos-primer/
- Topic Maps: XTM 1.0 — https://www.topicmaps.org/xtm/ ; ISO/IEC 13250 — https://xml.coverpages.org/TM-iso13250-2nd-ed-v2.pdf
- Balog & Kenter, Personal Knowledge Graphs: A Research Agenda (ICTIR 2019) — https://dblp.org/rec/conf/ictir/BalogK19.html
- Skjæveland et al., An Ecosystem for Personal Knowledge Graphs (2024) — https://www.researchgate.net/publication/370127315_An_Ecosystem_for_Personal_Knowledge_Graphs_A_Survey_and_Research_Roadmap
- Kleppmann et al., Local-first software (Ink & Switch, 2019) — https://www.inkandswitch.com/essay/local-first/
- Apple, CKSyncEngine — https://developer.apple.com/documentation/cloudkit/cksyncengine ; WWDC23 — https://developer.apple.com/videos/play/wwdc2023/10188/
- Apple, TN2336 Handling version conflicts in iCloud — https://developer.apple.com/library/archive/technotes/tn2336/_index.html
- Apple, Designing for Documents in iCloud (key-value store limits) — https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForDocumentsIniCloud.html
- schema.org DefinedTerm — https://schema.org/DefinedTerm
- OpenRefine, Reconciling with Wikibase — https://openrefine.org/docs/manual/wikibase/reconciling
