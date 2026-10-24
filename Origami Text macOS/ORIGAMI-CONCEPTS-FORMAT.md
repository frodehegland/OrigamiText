# The Origami Concept Library format

*Specification, version origami-concepts/1.0, 23 October 2026. The
Defined Concepts library as a folder of plain JSON files, shared between
Author (macOS, iOS, visionOS), Origami Text and Liquid — and readable by
any program on any system. Nothing in it depends on Apple's frameworks,
services or archives. This document is self-contained; the Swift
reference implementation is `ConceptLibrary.swift` in Origami Text, and
Author's `ConceptLibrary` package writes the same files.*

## 1. Principles

1. **Plain files.** UTF-8 JSON, pretty-printed, keys sorted, dates in
   ISO 8601. A person with a text editor can read every concept.
2. **One concept, one file.** Two devices editing different concepts
   never touch the same file; two editing the same concept produce one
   small conflict whose two sides merge completely.
3. **Append-only.** Nothing is edited in place. Every change is an event
   added to the concept's log. A deletion is an event, so a deleted
   concept cannot be resurrected by a stale copy, and can be recovered.
4. **Merge by union.** Two copies of a log are combined by taking every
   event from both, keyed by event id. Ordering is by `sequence`, then
   `created`, then `id` — never by the clock alone.
5. **Transport is somebody else's job.** The folder may sit anywhere. A
   synced folder — iCloud Drive, Dropbox, Syncthing, a git repository —
   shares it between devices and apps. No sync service is assumed.
6. **Tolerant reading, careful writing.** Unknown keys and unknown event
   kinds are kept and re-emitted, never dropped. Writers emit only what
   this document describes.

## 2. The folder

```
<library>/
  library.json             what this is: format, created, the apps that wrote
  concepts/<id>.json       one concept — Author's record (§3)
  extensions/<id>.json     Origami's additions to that concept (§4)
  layouts/<space>.json     positions of concepts in one space (§5)
  index.json               a cache some writers keep; never the truth
```

`<id>` is the concept's identifier: a UUID string, the same in both files.
Author keeps its library at the root of its iCloud Drive container
(`iCloud Drive ▸ Author ▸ Concepts` on a Mac:
`~/Library/Mobile Documents/iCloud~com~liquid~Author/Concepts`); Origami
Text uses whatever folder the reader chooses, that one included.

`library.json`:

```json
{
  "apps": ["Origami Text", "Author"],
  "created": "2026-10-23T14:00:00Z",
  "format": "origami-concepts/1.0",
  "specification": "ORIGAMI-CONCEPTS-FORMAT.md — https://github.com/frodehegland/OrigamiText"
}
```

## 3. The concept record — `concepts/<id>.json`

Author's record, unchanged, so Author's existing libraries are already in
this format.

```json
{
  "id": "6F1C…",
  "terms": ["hypertext", "hyper-text"],
  "events": [
    {
      "id": "E1…",
      "kind": "version",
      "created": "2026-09-12T10:04:11Z",
      "device": "Frode's Mac",
      "sequence": 1,
      "term": "Hypertext",
      "definition": "Text with links, which the reader chooses among.",
      "tags": ["concept"],
      "urls": ["https://en.wikipedia.org/wiki/Hypertext"],
      "citationIDs": ["10.1145/1234567"],
      "originDocumentName": "Use Cases for Headset Work"
    },
    { "id": "E2…", "kind": "used", "created": "…", "device": "Frode's iPad", "sequence": 2,
      "originDocumentName": "Spatial Reading" }
  ]
}
```

- `terms` — every normalised term the concept has ever had (§6). Derived;
  a reader recomputes it, a writer emits it.
- `events` — the log. Each event: `id` (unique), `kind`, `created`,
  `device`, `sequence`; and for a `version`: `term`, `definition`, `tags`,
  `urls`, `citationIDs`, `originDocumentName`, `parentID` (the version it
  revised); for `merged`: `mergedInto`.
- `kind` is one of `version` (a definition, first or revised), `used`
  (another document rests on the definition unchanged), `deleted`,
  `restored`, `merged`. **Writers emit no other kind here** — Author's
  reader rejects a file with one. Anything new goes in `extensions/`.
- The definition in force (the **head**) is the newest `version`. The
  concept is **deleted** when its newest lifecycle event (`deleted` or
  `merged`) has a higher sequence than the head.
- `sequence` is one past the highest the writer had seen for that
  concept, so a device with a wrong clock still orders correctly.
- `tags` is the concept's kind in Author's vocabulary (`concept`,
  `person`, `institution`, `document`, …). Entries tagged `section`,
  `citation`, `heading`, `reference` or `lens` are a document's machinery
  and are never written to a library.

## 4. Origami's additions — `extensions/<id>.json`

Everything Origami Text knows beyond Author's record, as its own log
beside it. Kept apart so Author's writer, which re-encodes a record it
appends to, never drops them. Same discipline: append-only, union merge,
`(sequence, created, id)` order.

```json
{
  "id": "6F1C…",
  "events": [
    { "id": "X1…", "kind": "label", "created": "…", "device": "…", "app": "Origami Text", "sequence": 1,
      "value": "Hypertexte", "lang": "fr", "labelKind": "alt" },
    { "id": "X2…", "kind": "sense", "sequence": 2, "value": "the writing system, not Nelson's 1965 coinage", "created": "…", "device": "…" },
    { "id": "X3…", "kind": "kind", "sequence": 3, "value": "concept", "created": "…", "device": "…" },
    { "id": "X4…", "kind": "relation", "sequence": 4, "relation": "broader", "to": "9A2B…", "created": "…", "device": "…" },
    { "id": "X5…", "kind": "match", "sequence": 5, "matchKind": "exact", "scheme": "wikidata",
      "identifier": "Q93241", "url": "https://www.wikidata.org/wiki/Q93241", "created": "…", "device": "…" },
    { "id": "X6…", "kind": "flag", "sequence": 6, "value": "tracked", "on": true, "created": "…", "device": "…" },
    { "id": "X7…", "kind": "occurrence", "sequence": 7, "document": "10.1145/3603163.3609048",
      "title": "Spatial Reading", "fragment": "p14", "form": "hyper-text", "created": "…", "device": "…" },
    { "id": "X8…", "kind": "definitionSource", "sequence": 8, "value": "user", "created": "…", "device": "…" }
  ]
}
```

One flat event shape; each kind uses the fields it needs:

| kind | fields | meaning |
|---|---|---|
| `label` | `value`, `lang?`, `labelKind` (`pref` \| `alt` \| `hidden`), `on?` | SKOS labels: the preferred name per language, other names, misspellings for search. `on: false` removes an earlier label |
| `sense` | `value`, `lang?` | which meaning of the word (SKOS scopeNote) |
| `kind` | `value` | the concept's kind: `concept`, `person`, `institution`, `place`, `work`, `method`… — open |
| `relation` | `relation` (`broader` \| `narrower` \| `related` \| `partOf` \| `opposes` \| …), `to` (a concept id), `on?` | explicit links between concepts |
| `match` | `matchKind` (`exact` \| `close` \| `broad`), `scheme` (`wikidata`, `ccs`, `orcid`, `doi`, `url`…), `identifier`, `url?`, `on?` | the same concept in another vocabulary — a mapping, never a merge |
| `flag` | `value` (`tracked` \| `liked` \| `hidden` \| …), `on` | the reader's marks |
| `occurrence` | `document` (a stable id: Origami address, DOI, EPUB identifier), `title?`, `fragment?` (paragraph id), `form?` (the words used) | where the concept appears — the backlinks |
| `definitionSource` | `value` (`user` \| `document` \| `ai`) | who wrote the head definition |
| `note` | `value` | a remark in the history |

The newest event of a kind is the one in force, except lists (`label`,
`relation`, `match`, `occurrence`), which accumulate and are removed by a
later event with `on: false`. An unknown `kind` is kept and re-emitted.

## 5. Layouts — `layouts/<space>.json`

Positions never live on a concept. A **space** is one arrangement: a
document's Map in Author, a room's Concept Space in Origami Text, a scene
in Liquid.

```json
{
  "space": { "id": "room:kitchen", "name": "Kitchen", "kind": "conceptSpace", "app": "Origami Text" },
  "modified": "2026-10-23T14:00:00Z",
  "positions": [ { "id": "6F1C…", "x": 240.0, "y": -120.0, "z": -1.9 } ],
  "connections": [ { "from": "6F1C…", "to": "9A2B…" } ]
}
```

Units are the space's own (points for a 2D map, metres for a room); `z`
may be omitted. A layout naming an unknown concept is tolerated. Author's
`map/layout.json` is the same idea for its one Map space.

## 6. Term normalisation

Two terms name the same concept when their normalised forms are equal.
Normalise: straighten curly quotes (’ ‘ → ', “ ” → ") and dashes (– — →
-); fold case and diacritics (Unicode case folding, strip combining
marks); collapse runs of whitespace to one space; trim. **Never stem** —
"Map" and "Maps" may differ, and only the writer knows. Matching a term
in text is by whole words: a match is bounded by non-alphanumerics.

## 7. Importing from documents

- **An Author `.liquid` package**: `Contents/glossary.json`, a dictionary
  of entries by UUID. Each entry's `phrase` is "Name, other name, …"; the
  first is the term, the rest are `alt` labels. `description` (older
  files: `entry`) is the definition; `tag` the kind; `urls[].url`;
  `citationIdentifiers`; `date` (seconds since 2001, or ISO 8601). The
  entry's key or `identifier` is matched against concept ids first, then
  the term.
- **An Origami EPUB**: `visual-meta.json` `concepts[]` (Profile 1.0 §9.4):
  `id`, `name`, `description`, `tag`, `urls`, `citationIdentifiers`.
  `id` is matched first, then `name`. The document's identifier becomes an
  `occurrence`.
- **An `.origamitext` document**: its `concepts` array, the same shape.

A concept already in the library gains a `used` event (and an
`occurrence`) rather than a new version when the definition is the same.

## 8. Exporting

- **SKOS (JSON-LD)**: one `skos:ConceptScheme`; each live concept a
  `skos:Concept` with `prefLabel` (per language), `altLabel`,
  `hiddenLabel`, `definition`, `scopeNote` (the sense), `broader` /
  `narrower` / `related`, `exactMatch` / `closeMatch` / `broadMatch`,
  `dcterms:isReferencedBy` (occurrences), `dcterms:type` (kind).
- **schema.org**: a `DefinedTermSet` of `DefinedTerm`s (`name`,
  `description`, `termCode` = the id) for the web.
- **Visual-Meta** `@{glossary}` and Profile 1.0 `concepts[]` carry the
  head term, definition, kind, urls and citations as they do today; the
  library id is the entry's id.

## 9. Conflicts

A sync tool that cannot merge leaves a second copy — iCloud Drive as a
file version, Dropbox as a "conflicted copy" file. Readers resolve any
such copy by union-merging it into the concept's file and discarding the
copy. Because every event has a unique id, the union is exact and nothing
is lost; only the ordering decides which definition is the head.

## 10. What a minimal implementation must do

**A reader MUST**: read `concepts/*.json` tolerantly; order events by
`(sequence, created, id)`; take the newest `version` as the head; treat a
concept as deleted when its newest `deleted`/`merged` outranks the head;
read `extensions/*.json` the same way, keeping unknown kinds.

**A writer MUST**: append, never rewrite; set `sequence` to one past the
highest it has seen for that concept; give every event a unique id; emit
only the five kinds in `concepts/`; write `library.json`; merge by union
whenever it finds two copies of one concept.

**Nobody may**: delete a file to delete a concept; renumber sequences;
put positions on a concept record; depend on any one sync service.
