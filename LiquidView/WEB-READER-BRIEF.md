# Origami Text Web Reader — build brief

*A brief for Claude (or any builder) starting a NEW web-based reader
for Origami Text EPUBs, written 10 September 2026 from the state of
the native apps (macOS, iPadOS, visionOS) in this repository. The
EPUBs are the contract; the native readers are the behavior to match.
Where this brief and the code disagree, the code wins — ground truth
is `OrigamiEPUB.swift` (the exporter), `EPUBReaderView.swift` (the
Mac's faithful WebView reader and its injected scripts), and
`EPUBShelf.swift` (the shared shelf, standing, and map-layout stores).
See also `CITATION-EPUB-SPEC.md` and `ORIGAMI-DOCUMENT-FORMAT.md`.*

## 1. What it is

A reader for a folder of Origami Text EPUBs — a journal or conference
proceedings (the first real corpus: HT '26, 59 papers) — that runs in
a browser. Two faces, like the apps:

1. **Articles** — the venue's list: title, authors, date; pinned books
   first; Set Aside books tucked behind a pill at the foot.
2. **Map** — every article a draggable card on a flat plane (see §5).

Plus the reading view itself (§3–4). No accounts, no server-side
smarts required for v1: static hosting over a folder of `.epub` files
(unzipped or fetched and unzipped client-side) is enough.

## 2. The document format (what the exporter writes)

Each book is a standard EPUB: one content document `paper.html`
(XHTML — parse strictly), `style.css`, `images/`, and `visual-meta.json`
at the package root.

### Front matter (in document order)
- `<h1>` title, centered.
- Per author: `<p class="author">Name</p>` then
  `<p class="author-detail">` holding a live `mailto:` link and the
  ORCID **written out** (`https://orcid.org/…`, text = the id, live).
- Affiliations, then a byline (venue · date).
- License block `<p class="license">`: `<img class="cc-badge"
  src="images/cc-by.png"/>` then the CC BY boilerplate lines, the DOI
  linked. Render as shipped.
- `<div class="acm-reference">` — the verbatim ACM Reference Format
  paragraph, DOI linked.
- CCS Concepts and Keywords: plain paragraphs opening with bold
  `CCS Concepts:` / `Keywords:` — full width, no heading.

### Body
- Every block carries a stable id (`id`/`data-id`) — these anchor
  fragments, jumps, and annotations. Never regenerate them.
- Figures: `<figure>` with `<img>` and `<figcaption>` carrying the
  printed label (`Figure N: …`). Tables likewise (`Table N: …` above
  the grid), styled booktabs-fashion (rules above/below head, no
  vertical rules).
- Fenced code: `<pre data-language="…"><code>…</code></pre>` —
  monospace block.
- Stretchtext: a `»»` trigger with its expansion in
  `<aside class="ot-stretchtext-content" hidden>` — click reveals.

### Links (the interaction surface)
- **Citations**: `<a class="origami-cite" href="#ref-…">`, rendered as
  `[n]` in numbered style. Numbered/raised citation marks take **no
  underline**; other in-text links get a quiet underline
  (~0.35 opacity). Clicking opens the citation card (§4).
- **In-document jumps**: `<a class="ot-jump" data-target-id="…">` — an
  active link to a figure, table, or section. A jump whose target is a
  figure shows the image (lightbox), not just a scroll.
- **Notes**: superscript marks `<sup>` wrapped in anchors with `fnref`
  ids; the note at the foot carries a numbered back-link. Mark style
  is a *reader preference* with four choices — superscript `n`
  (default), bracketed `[n]`, dagger `‡`, fold `[ ]` — with one rule:
  citations and notes are never both superscript; if citations are
  superscript, notes yield to brackets.

### Visual-Meta
`<section id="visual-meta" hidden="hidden">` at the document's end: a
heading, one explanatory sentence, `@visual-meta-start` /
`@visual-meta-end` markers, and the JSON payload inside
`<script type="application/json">` (CDATA). Keep it hidden; inject a
small centered **Metadata** button just before it that toggles the
section (button reads "Hide Metadata" while open). The payload is the
machine-readable document record — references as BibTeX, structure,
identity — and doubles as the reader's data source if you prefer
parsing it over scraping the HTML.

## 3. Reading behavior

- **A book opens at the top.** Fragment links (`#id`) land on their
  paragraph; a fragment inside a hidden stretchtext unfolds it first.
- **Find** over the text.
- **Light and dark themes**; in dark, surfaces sit a shade above
  black, never pure black cards on pure black ground.
- `mailto:` and external links open normally (new tab).
- Double-click (or double-tap) **any image** → the image alone,
  proportion-fitted (lightbox in a browser).
- Optional v2: a Horizontal mode — the text in 2–3 columns, one column
  per swipe, with the rule that a heading followed only by another
  heading shares its column with the next content.

## 4. The citation card

Clicking a citation opens a card (wide — the Mac uses 680–900 pt):

- Title, authors, year, venue; abstract when the metadata holds one.
- **Online** — plain text button (no icon): opens a web search for
  `"Title" FirstAuthor Year`.
- **Copy to Cite** — copies the reference for pasting into a writing
  tool. Match the Mac's clipboard contract (see the tests protecting
  it in this repo — commit `6d7146c`): the BibTeX entry is the payload.
- **Acquire** — that exact word — for fetching the cited work when a
  DOI/URL is present.

## 5. The Map

The venue as a flat plane — Author's Map for a proceedings. This was
built natively across all three platforms in September 2026; match it.

### Presentation
- Every article is a card: title (3 lines max, semibold), authors
  (caption, secondary), ~168 pt wide, rounded corners, opaque fill
  (dark mode: a shade above black, e.g. `#2b2b2b`), 1 pt secondary
  stroke; pinned cards take an accent stroke and a small pin glyph;
  Set Aside cards sit faded (~0.45) in their own row beneath the grid.
- **Default layout** (no saved positions) mirrors the Vision Pro's
  hallway grid exactly: `columns = max(1, floor(sqrt(count*7)/2))`,
  x = `(col − (cols−1)/2) × 0.28`, y = `1.55 − row × 0.18` (meters —
  see below); the Set Aside row beneath at x-spacing 0.24, y-step
  0.08, starting `0.10` under the grid.
- A slim **foot bar**: `‹` at the left (back to Articles), a **Find**
  field centered — matching cards stand forward with an accent ring,
  the rest recede to ~0.25 opacity; clear evens the plane.
- No tab row above the map: the map fills the pane; the way back is
  the foot bar.

### Interaction
- **Click/tap lifts** the card: slight drop shadow (down-right) and a
  2 px nudge up-left, eased ~150 ms; click again or lift another to
  set it down. The shadow belongs to the card's frame only — never
  per-glyph.
- **Drag moves** a card (clamped to the canvas); the card in hand
  rides lifted. Performance rule learned natively: the dragged card's
  live position must be local state — do not re-render the whole
  plane per pointer move.
- **Double-click opens** the article.
- Context menu (long-press / right-click): Pin / Unpin, Set Aside /
  Bring Back.
- On touch devices: **two fingers pan the plane, one finger moves a
  card**.

### The shared layout file — interoperate, don't invent
Positions sync with the native apps through one JSON file in the
community folder, `origami-map-layout.json`:

```json
{
  "positions": {
    "<file-identity>": { "x": -0.42, "y": 1.01, "t": 810719515.26 }
  },
  "modified": 810719515.26
}
```

- **Keys are the book's file identity**: the community `.epub` file's
  base name (e.g. `3800935.3830833`), sanitized (`/`→`_`, `:`→`_`).
  NEVER an internal document id — those differ per device/import.
- **Units are the hallway's meters**: x right of center, y up from
  the floor. The 2-D canvas maps them at ~620 px/meter with the
  canvas center at (0, 1.2); y flips (screen y grows downward).
- **Dates are Apple epoch** (seconds since 2001-01-01 UTC) — that is
  what `JSONEncoder` writes by default and what the apps read.
- **Merging is per entry**: on read, merge sources per key, the entry
  with the newest `t` wins (missing `t` = oldest). On write, stamp
  only the entries you moved and re-write the merged whole. Never
  last-writer-wins the whole file — that rolls other devices back.
- Refresh while visible (the apps poll every ~4 s) so two open maps
  converge.

### Pin / Set Aside travel separately
`origami-standing.json` in the same folder:
`{ "pinned": [ids], "setAside": [ids], "concepts": [..]?, "modified": date }`
— whole-file last-writer-wins (by `modified`). NOTE: standing uses
the books' *internal* ids (`origami-id` from the Visual-Meta), not
file identities — a historical asymmetry; read both files accordingly.

## 6. What NOT to build

- No editing, no export, no publisher tools of any kind — readers
  read. (The native Release builds are audited to contain none of it.)
- No annotation sync in v1 (native sidecars are out of scope).
- Don't render the Visual-Meta section by default, don't strip it
  either — it is the document's memory.

## 7. Suggested shape

Plain modern web: no heavy framework needed. Client-side unzip
(e.g. fflate) of `.epub`, parse `paper.html` as XML, inject the same
kind of behavior scripts the Mac's WebView reader uses (endnote
handling, figure lightbox, metadata toggle — see
`EPUBReaderView.swift` for the working JS to adapt). The Map is one
absolutely-positioned `<div>` per card inside a pannable canvas;
pointer events for drag; the layout file fetched/PUT wherever the
community folder is served. Serve the whole thing statically beside
the EPUBs and it should work from any web server — including one
pointed at the community folder itself.
