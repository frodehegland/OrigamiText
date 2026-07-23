# The Origami Document Format (.origamitext)

*Specification, version origami/0.1 as implemented by Origami Text, July 2026. This document is self-contained: everything needed to build a reading, writing, or analyzing application is in this file. Feed it to an AI and start building. Format decisions are provisional pending community discussion — the format is owned by its community, not by any one implementation.*

*The Origami Text application and the document specifications are fully free and open source. The project was initiated by Frode Hegland at the Future Text Lab (https://futuretextlab.info) and belongs to its community.*

---

## 1. Principles

These are not decoration; when in doubt, they decide:

1. **Self-describing.** A document carries its own metadata, in the document, in human-readable form. Nothing essential lives in a database, a filename convention alone, or a hidden layer that can be lost.
2. **Readable in fifty years.** Plain UTF-8 text. A person with a text editor must be able to read everything without any of our software.
3. **Tolerant reading, careful writing.** Readers ignore what they don't understand; writers never emit what they can't explain.
4. **Append-only history.** Nothing rewrites a published document. New versions, corrections, and retractions are *new documents* that point at old ones.
5. **Graceful degradation.** Every convention layered on plain text (headings, links, markers) must still read acceptably as plain text.

## 2. The file

An Origami Document is one UTF-8 JSON file with the extension `.origamitext`. A complete example:

```json
{
  "format": "origami/0.1",
  "id": "f.hegla.093252x",
  "title": "Notes on Spatial Reading",
  "author": "Frode Hegland",
  "created": "2026-07-11T09:32:52Z",
  "attention": ["Mark Anderson"],
  "body": [
    { "id": "p1", "heading": 1, "text": "Spatial Reading" },
    { "id": "p2", "text": "As argued in “Use Cases for Headset Work” (Frode Hegland, 2026) [f.hegla.101500k#p3], the lateral arrangement matters." },
    { "id": "p3", "text": "---" },
    { "id": "p4", "text": "A closing thought." }
  ],
  "links": [
    {
      "to": "f.hegla.101500k",
      "fragment": "p3",
      "rel": "cites",
      "bibtex": "@article{hegland2026headset,\nauthor = {Frode Hegland},\ntitle = {Use Cases for Headset Work},\nyear = {2026},\nvm-id = {2026-07-11T10:15:00Z}\n}"
    }
  ]
}
```

**Why JSON**, when principle 2 wants text-editor readability? Because paragraphs need stable ids and structure must parse unambiguously in fifty years, and JSON is the simplest widely-frozen syntax that gives both. The trade against raw prettiness is acknowledged and deliberate: a JSON document is still plain UTF-8 a person can read unaided, and the format's human face lives in the conventions that degrade to prose — headings and citations in the body (§4, §6), metadata as a readable appendix (§7).

### Required fields

`format`, `id`, `title`, `author`, `created`, and **exactly one of** `body` (a text document) or `wraps` (a sidecar around another file, §8).

- `format` — `"origami/0.1"`. Readers must open any `origami/0.x` (flagging unfamiliar minor versions non-blockingly) and must reject other major versions.
- `created` — ISO 8601. Accept both with and without fractional seconds.
- `body` — ordered array of paragraphs: `id` (string, unique within the document), `text` (string), optional `heading` (integer 1–3; clamp out-of-range values), optional `speaker` (string — see below).
- `speaker` on a paragraph attributes it to the person who said it — meeting transcripts stay **one document** (one event, one address, read linearly), with every statement individually addressable (`#p14`) and ascribable to its speaker. Writers keep the name in the text too (`"Mark Anderson: I would add a caveat."`), so plain-text readers lose nothing; readers with the field style the name and hide the prefix — exactly as heading levels pair with `#` prefixes. Speakers are plain names, matching softly like `author` and `attention` (§3). Do **not** split a transcript into per-statement documents: turns in conversation are temporal sequence, not discourse relations.

### Optional fields

- `links` — see §5. Defaults to empty.
- `attention` — array of person names this document is addressed to, "for the attention of." Plain names, readable by anyone. Apps should visually mark documents addressed to their user (Origami Text bolds them in the library).
- `aiOnBehalf` — boolean; `true` declares the document was produced by an AI on behalf of the named `author`, who reviewed it and stands by it. `author` stays the human name — the one to cite and the one accountable — and readers should never present AI production silently (Origami Text bylines these "AI on behalf of *Name*"). Omitted when false. Also emitted as `ai-on-behalf-of = {Name}` in the Visual-Meta self-citation (§7).
- `onBehalfOf` — a name; the document carries words that are not the author's own but the named person's — a statement lifted from a meeting transcript, for example. `author` stays the person who prepared and exported the document; the named person is the one to credit for the content (Origami Text bylines these "*Author* on behalf of *Name*", and offers the export as "Exported by *Author* on behalf of *Name*"). Omitted when absent. Also emitted as `on-behalf-of = {Name}` in the Visual-Meta self-citation (§7).
- `documentType` — the kind of document the author declares this to be, chosen at export. A lowercase token with an **open vocabulary**, like `rel` (§5): the recommended values are `letter` (an authored piece in the community's correspondence — the core kind of Origami document; Origami Text assigns it by default to a new document), `note` (the author's own quick note, often captured in the moment — sometimes by voice, outside the authoring app — carrying a `location` where the capture had one; a note is always its author's own, so readers show only when and where, never who), `rfc` (request for comment — a proposal inviting response), `personal`, `project`, `meeting`, `transcript` (a meeting or interview transcript, statements attributed to speakers — letters between people in a meeting), `extract` (a statement lifted out of a transcript into a letter of its own; assigned by the act of lifting, with `onBehalfOf` naming the speaker and a span-scoped `cites` link pointing back at the statement), `article`, `bot` (an AI stand-in bearing a well-known person's name: the document defines the bot and records its judgements of the library's documents, one paragraph per judgement linking to the document judged — AI-produced from public knowledge, never the person's own words), `trail` (a sculptural reading path through the community's documents, after the sculptural hypertext of Bernstein, Millard, and Weal: the body declares a shape on a `Shape:` line — `canyon`, one path walked in strict sequence; `delta`, branching paths; or `plain`, an open field walked in any order — then, under a `Stops` heading, one paragraph per stop whose first bracketed address is the document visited, a delta stop optionally naming the stop it follows with the word `after` before a second address; readers open each stop only as the stops it follows are read, `cites` links carry the stops for the document web, and a reader's walking state is their own, never written into the shared record), `glossary` (a reader's personal glossary published for the community: terms from the community's discourse glossed in the author's own words — readable paragraphs under a `Terms` heading, and the same terms carried in `concepts` so other apps and readers can adopt them term by term; a glossary claims no authority beyond its usefulness), and `manifest` (a dated snapshot of a library's contents, produced on request; the folder of documents, not the manifest, remains the authority), and unknown values must be preserved and displayed verbatim, never dropped — this is how the community grows the vocabulary. Also emitted as `document-type` in the Visual-Meta self-citation (§7).
- `location` — where the document was made, when the producing device or app recorded it: a **free-form place name string**, human-readable per principle 2 — `"Wimbledon, London"`, `"Café Central, Vienna"` — not coordinates. Producers with GPS should reverse-geocode to the most natural short name (locality level is usually right; add a venue when it matters). Trim whitespace; omit the field rather than emit an empty string. Readers show it beside the date wherever the document is listed, and may group documents by it (Origami Text's Location view). Also emitted as `location = {...}` in the Visual-Meta self-citation (§7).
- `concepts` — the document's **glossary of Defined Concepts**: an array of nodes, each `{ "id": "<UUID string>", "name": "Visual-Meta", "description": "…", "tag": "person", "citationIdentifiers": [], "urls": [] }`. Only `id` and `name` are required (`id` stable for the document's life — layouts and citations reference it); the rest may be omitted when empty. This is the same node pool the Origami Text EPUB profile carries in its Visual-Meta (`type: "glossary"`), so the two forms round-trip.
- `references` — the document's **external citation records**: an array of `{ "id": "<stable identifier>", "bibtex": "@book{…}" }`, each a verbatim BibTeX entry. Citations of *library* documents ride on `links` (which know their address and carry `bibtex` there); `references` holds the works outside the library — books, papers, web pages. Concepts' `citationIdentifiers` and spatial layouts may reference these ids, and publication emits the records into the Visual-Meta `@{references}` block (§7) alongside the links'.
- `layouts` — named **spatial arrangements** of the concept/citation pool: `{ "index": 1, "name": "Grill", "positions": [{ "id": "<node id>", "x": -570.28, "y": -59.0, "z": -1.71 }] }`. `index` is referenced by inline `<n>` markers in body text; z carries XR depth and 2D readers may ignore it. Layouts hold position and connection only — how a node renders (size, color, open state) belongs to the reading application, never the document. A layout naming an unknown node id is tolerated; the position is simply unresolvable.
- `date` — a human-assigned date, distinct from `created`: meeting notes written the morning after carry the meeting's date; a transcription of an ancient text carries the text's own date. **When present, `date` is what the document is listed, sorted, and filtered by**; `created` remains the immutable machine timestamp (and the basis of the id, §3). The value is an ISO-style string at one of three precisions — `"2026-07-07"`, `"2026-07"`, `"2026"` — with BCE as a non-positive year per ISO 8601 (year 0 is 1 BCE, so 329 BCE is `"-0328"`; interfaces should speak "329 BCE" and hide the astronomical convention). An unparseable `date` is dropped, not fatal.

### Rules of tolerance

- **Unknown keys anywhere must be ignored without error** (forward compatibility). This is how the format grows.
- Malformed files must never crash an app: surface them greyed-out with a reason, and skip them in any index.
- A link whose `to` is not a usable address is skipped, not fatal.

## 3. Addressing

**A document's `id` is a short human-readable string that is also its filename** (`id` + `.origamitext`).

Generation, deterministic from author and creation time:

```
<initial> "." <surname≤5> "." <HHmmss UTC> <day-character>
e.g. Frode Hegland, created 2026-07-11T09:32:52Z  →  f.hegla.093252x
```

- `initial` — first letter of the first name; `surname` — up to five characters of the last name. Both are transliterated to Latin and reduced to lowercase `a–z0–9` (王 → `wang`, ö → `o`): addresses must survive filenames, URLs, and citation matching in plain ASCII text, whatever script the author writes their name in. If nothing survives transliteration, fall back to `x` / `doc`.
- `HHmmss` — creation time of day, UTC.
- `day-character` — one base-36 character: `alphabet[daysSinceUnixEpoch mod 36]` where alphabet is `a–z0–9`. Disambiguates the same time-of-day on different days.
- On collision (detected against the local library), fall back to `<initial>.<surname>.<6 random base-36 chars>`.

Determinism matters: anyone who knows a document's author and creation time can *derive* its address before the document arrives — enabling forward citation (cite now, resolves later).

**Collision honesty.** Collision detection reaches only the library the writer can see; two disconnected libraries can mint the same id (same-named authors, or the same time-of-day 36 days apart) and discover it only when their files meet. When they do, §9's duplicate handling applies: flag, never silently merge, never delete. The ground truth of attribution — `author` and `created` — lives *inside* each file, so an id collision is an inconvenience to be surfaced, not a corruption of the record.

- Ids are compared case-insensitively; canonical form is lowercase. Ids must contain no whitespace, `#`, or `/`.
- **Legacy UUID ids remain valid** as opaque strings; treat all ids as strings.
- **Files must not be renamed** (reference-manager discipline). Identity also lives inside the file, so a renamed file's content is still attributable, but links resolve by index of `id`, and the filename convention is what makes a folder browsable.

**Person addresses.** The two-segment prefix is a person: `f.hegla` is everyone-addressable shorthand for the author whose documents share that prefix. Apps should resolve a person address to an author view rather than a document.

### Person identity

In the document itself, people are always **plain names** (`author`, `attention`) — readable by anyone, forever, per principle 2. Richer identity layers on top:

- **The ORCID iD is the canonical identity for a person** where one is known (https://orcid.org — the persistent academic identifier). Two names match softly; two ORCID iDs match hard. When the author has an ORCID iD, writers should emit it as `orcid = {...}` in the Visual-Meta self-citation (§7), which lets any reader correlate the same person across libraries, name changes, and spelling variants.
- Apps should keep a **local person directory** — contact records mapping names to ORCID iD, affiliation, and whatever else is useful (Origami Text persists one as JSON, populated by hand or from ORCID's public search API at `pub.orcid.org/v3.0/expanded-search`, no key required). The directory is a *local* convenience, like muting (§9): it is never written into a document, and no document depends on it.

**Fragments.** `<id>#<paragraphID>` addresses a paragraph: `f.hegla.093252x#p3`.

### Address forms in text

Body text is scanned for addresses; each becomes a live link in a reader and a structured link on save in a writer:

| Form | Meaning |
|---|---|
| `[f.hegla.093252x#p3]` | citation (rel defaults to `cites`) |
| `[responds-to:f.hegla.093252x]` | typed citation — any lowercase hyphenated rel |
| `[f.hegla]` | a person; navigational, not a document link |
| `origamitext://open/f.hegla.093252x#p3` | URL-scheme form, pasteable between apps |
| bare UUID (with optional `#frag`) | legacy address, still recognized |

## 4. Citation text convention

Apps present citations as a readable sentence, whatever their source (copy-cite, BibTeX paste, PDF quote):

```
“Use Cases for Headset Work” (Frode Hegland, 2026) [f.hegla.101500k#p3]
```

The bracketed address is the live part. The prose is for humans; never reconstruct citations from filenames.

## 5. Links and the relation vocabulary

Each link: `to` (an address), optional `fragment` (paragraph id in the target), optional `rel`, optional `bibtex`, optional `span`.

- `bibtex` — the citation's full BibTeX record, verbatim, carried *by the link* (provenance travels with the connection). Emitted into the Visual-Meta `@{references}` block on publish (§7).
- Unknown `rel` values must be preserved and displayed verbatim.

**The scope ladder** (after Ted Nelson, whose Xanadu links connect spans, not files): a link's scope is the whole **document** (no fragment), a **paragraph** (`fragment`), or a **span** — `span` holds the exact words within the target paragraph the link points at. Writers derive spans from the citation text convention: the quotation preceding the address (§4) is the span. Readers arriving by a span-scoped link highlight those words where they occur in the target paragraph; where they do not occur (the quote was a title, or the wording drifted), the paragraph scope stands — **scope degrades one rung, it never breaks the link**. Span matching is case- and diacritic-insensitive.

The working vocabulary and the behavior a reader SHOULD derive:

| rel | Meaning | Derived behavior |
|---|---|---|
| `cites` | quotes or references | backlinks; transclusion of the cited paragraph |
| `responds-to` | replies or continues | conversation threading |
| `extends` | builds upon | — |
| `supports` | endorses | — |
| `questions` | asks for clarification | — |
| `disagrees-with` | disputes | — |
| `summarizes` | condenses or reviews | — |
| `relates-to` | unspecified connection | — |
| `revises` | this document is a new version of `to` | see below |
| `retracts` | withdraws `to` | mark the target retracted: warn readers, dim listings; never delete |

**Revision semantics** (`revises`): the link's author is the newer document; `to` is the older. Readers maintain `latestRevision(id)` by following chains forward (guard against cycles with a visited set; on a cycle return the input). **When following any link except a `revises` link, map the target through `latestRevision`** — citations automatically point at the current version. Superseded documents (any `to` of a `revises` link) are hidden by default, with a toggle. History is never rewritten — only extended.

## 6. Body text conventions

Paragraph `text` may contain, all degrading gracefully to plain text:

- Markdown-style heading prefixes `# `, `## `, `### ` — a paragraph with a literal prefix but no `heading` field should render as that heading level.
- A paragraph of only dashes (`---`, 3+) renders as a rule.
- Inline markdown (bold, italic, code, `[label](url)` links) rendered inline; web URLs auto-linked; links render in body color with a quiet underline, not browser blue.
- Addresses per §3.

Paragraph ids: writers currently regenerate `p1…pn` on save, so fragment links into *drafts under active revision* may drift; ids in *published* documents are stable because published documents never change.

## 7. The Visual-Meta appendix

On **publication** (export for sharing), an app appends a Visual-Meta appendix to the body: human-readable prose explaining the convention, then a machine block. See https://visual-meta.info. Key facts for implementers:

- **Parse end-anchored, always**: find the *last* `@{visual-meta-end}`, scan backwards to the nearest `@{visual-meta-start}`. The marker names also appear in the boilerplate prose, so first-occurrence search will land on prose.
- The machine block contains `@{visual-meta-header-start}` (version, generator), `@{visual-meta-bibtex-self-citation-start}` (one BibTeX entry: the authoritative citation for the document — use verbatim), and, where present, `@{references-start}` (the bibliography: each cited work's BibTeX, with an injected `origami-id = {address}` relating the entry to the citation text in the body).
- The self-citation carries `origami-id` (the document's address), `vm-id` (ISO 8601 creation time), day/month/year, optionally the author's `personal-title`, `orcid`, `affiliation`, an `attention = {Name and Name}` field, an `ai-on-behalf-of = {Name}` field where the document declares AI production (§2), an `on-behalf-of = {Name}` field where the document carries the named person's words (§2), a `document-type = {rfc}` field where the author declared one (§2), a `location = {Place}` field where the document carries one (§2), and relation fields (`supersedes`, `responds-to`, `extends`, `supports`, `questions`, `disagrees-with`, `summarizes`, `retracts`) naming related addresses.
- When the document has a human-assigned `date` (§2), day/month/year reflect *that* date at its precision (day and month omitted when unknown), with `era = {1}` marking BCE (`year` then counts backwards: year 329 with era 1 is 329 BCE; era absent or 0 is CE). `vm-id` always keeps the creation timestamp, so both dates survive in the record.
- BibTeX escaping: `& % $ # _ { } ~ ^` and backslash are escaped; all other characters, including accents, are UTF-8 directly.
- The boilerplate is versioned (`visual-meta-intro/2026-07`); a reader recognizing the version may skip the prose and read only the delimited blocks.
- **The appendix is metadata, not content**: renderers show it de-emphasized (Origami Text renders it at half size after a rule); analyzers (including AI) must exclude it when treating the document's text as content.
- Appendix insertion must be idempotent — never append a second appendix to a document that has one.
- **On any disagreement between the JSON fields and the appendix, the JSON fields are authoritative.** The appendix is a human-readable rendering of them, generated at publication for readers of the text alone — printed copies, PDF exports, AI ingestion — not a second source of truth.

## 8. Sidecars: non-.origamitext files as citizens

An `.origamitext` may wrap another file instead of having a body:

```json
"wraps": { "file": "paper.pdf", "sha256": "<hex>", "mediaType": "application/pdf" }
```

`file` is relative to the sidecar's location. Verify `sha256` in the background; on mismatch show a non-blocking "file has changed" notice. The wrapped file thereby gains an address, links, and a place in the web. Fragments on sidecars are ignored in v1.

PDFs from the Visual-Meta ecosystem carry an identity key in their filenames — `Title(Frode-Hegland-2026-07-11T09_32_52Z).pdf` — from which the deterministic address can be derived (§3), so citations to PDFs resolve without the PDF entering the shared folder.

## 9. Transport: the library folder

Documents travel by being files in a shared folder (any sync: iCloud, Dropbox, git). An app:

- indexes `*.origamitext` recursively (skip hidden files/packages), tolerating failures per §2;
- maintains `byID`, reverse `backlinks`, revision and retraction maps;
- on duplicate `id`s keeps the newer file by modification date and flags the duplicate;
- watches the folder for changes (debounced rescan is fine at community scale — thousands, not millions).

**Publishing** is exporting into the shared folder: the published copy (with its appendix) is the immutable record. **Muting** (hiding an author's documents) is a local reader preference and is *never* written into the format — who you decline to hear is not part of the shared record.

**Trust model.** origami/0.1 carries no signatures: `author` is a claim, not a proof, and the `sha256` in a sidecar (§8) verifies file integrity, not authorship. This is deliberate at the format's current scale — a shared folder is a space you were invited into, where impersonation is socially visible — but apps must treat authorship as asserted, and anything crossing a trust boundary needs verification outside the format. Cryptographic attestation is an open question for a future version; append-only history (§1) means signatures can be layered on later as new documents attesting to old ones, without rewriting anything.

## 10. What a minimal implementation must do

**A reader MUST:** parse per §2 with full tolerance · resolve addresses through `latestRevision` (except `revises` links) · render heading prefixes and make addresses live · show the appendix as metadata, not body · never crash on any input.

**A reader SHOULD:** backlinks · superseded-hiding · retraction marking · transclusion of cited paragraphs · person addresses · attention bolding.

**A writer MUST:** emit only the documented fields · generate ids per §3 · name the file `<id>.origamitext` · keep history append-only (new versions are new documents with `revises`) · append the Visual-Meta appendix on publication, idempotently.

**Nobody may:** rewrite a published document · emit an id that collides knowingly · move essential metadata outside the document.

## 11. Sample fixtures

`f.hegla.100000a.origamitext` — cited document:

```json
{
  "format": "origami/0.1",
  "id": "f.hegla.100000a",
  "title": "Sample A: The Cited",
  "author": "Frode Hegland",
  "created": "2026-07-01T10:00:00Z",
  "body": [
    { "id": "p1", "heading": 1, "text": "The Cited" },
    { "id": "p2", "text": "This is the paragraph that gets cited; it should flash when arrived at by link, and unfold when transcluded." }
  ]
}
```

`m.ander.110000b.origamitext` — a response, addressed for attention, with a carried record:

```json
{
  "format": "origami/0.1",
  "id": "m.ander.110000b",
  "title": "Responding to Sample A: The Cited",
  "author": "Mark Anderson",
  "created": "2026-07-02T11:00:00Z",
  "attention": ["Frode Hegland"],
  "body": [
    { "id": "p1", "text": "As Frode argues [f.hegla.100000a#p2], though I would add a caveat." }
  ],
  "links": [
    { "to": "f.hegla.100000a", "fragment": "p2", "rel": "responds-to" }
  ]
}
```

`f.hegla.081512d.origamitext` — a note captured by voice outside the authoring app, with a location. This is the complete shape an external capture application emits: generate the id per §3 from the author's name and the capture instant, name the file `<id>.origamitext`, write it into the shared folder, and it is in the library. No Visual-Meta appendix is required of a capture app — the appendix belongs to publication (§7), and a note arriving in the folder is already home:

```json
{
  "format": "origami/0.1",
  "id": "f.hegla.081512d",
  "title": "Thought on arrival cues",
  "author": "Frode Hegland",
  "created": "2026-07-19T08:15:12Z",
  "documentType": "note",
  "location": "Wimbledon, London",
  "body": [
    { "id": "p1", "text": "The arrival cue should be the same in the headset as on the Mac — the reader knows the knock before they know the room." }
  ]
}
```

A retraction notice (note: a *new* document, the old one untouched):

```json
{
  "format": "origami/0.1",
  "id": "f.hegla.120000c",
  "title": "Retraction of Sample A: The Cited",
  "author": "Frode Hegland",
  "created": "2026-07-03T12:00:00Z",
  "body": [
    { "id": "p1", "text": "This document retracts “Sample A: The Cited” [f.hegla.100000a]." }
  ],
  "links": [
    { "to": "f.hegla.100000a", "rel": "retracts" }
  ]
}
```

---

*Naming history: this format was developed as the Liquid Document format (`.lqd`, `liquid-doc/0.1`, `liquid://`) until 2026-07-13, when it was renamed Origami alongside the app's rename to Origami Text. Documents from before the rename use the old names and are not read by current implementations.*

*Reference implementation: Origami Text (macOS). Questions, and this specification's future: the Future Text Lab. The format belongs to the people who write in it.*
