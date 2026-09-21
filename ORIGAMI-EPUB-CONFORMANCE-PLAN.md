# Making the Origami EPUB match what we say about it

**Written 21 September 2026, from an audit of `Origami text Sept 26 (for
Communications).epub` against the article's own claims and against the three
codebases (Origami Text, Reader, Author).**

The article is right about the approach. The exemplar file does not yet
demonstrate it, and two of its claims describe things no codebase implements.
This is the list, with the evidence, split by who fixes what.

Companion document for the Author work: `~/Documents/author_mac_forxcode/ORIGAMI-EPUB-EXPORT-FIXES.md`.

---

## What the audit found

Measured in `OEBPS/content.xhtml` of the exported article:

| Claim in the article | What the file contains |
|---|---|
| "a unique, immutable ID attribute to every structural unit (paragraphs, headings, lists)" | **14 `<p>` elements for 4,605 words** — one per section, 300–556 words each. The finest addressable unit is a section. |
| …"lists" | **0 `<ul>`, 0 `<ol>`, 0 `<li>`.** The bullet lists are 14 literal `•` characters in running text. |
| (implicit: the document reads as written) | Paragraph breaks inside each `<p>` are a literal newline + tab — **87 newlines, 18 tabs, 0 `<br/>`**. HTML collapses these to single spaces and `origami.css` sets no `white-space`, so **every section renders as one unbroken block** in any conforming reading system. |
| "each MathML block is accompanied by a plain-text LaTeX string embedded directly within a standardized `data-latex` attribute" | **`data-latex` exists in no Swift file in any of the three projects.** |
| "`<pre><code class="language-xyz">` Semantic Containers" | Origami Text emits `<pre data-language="x"><code>` — the right idea, a different attribute. Author emits no code blocks at all. |
| "The Reader's Job: … the local reader application applies that visual syntax highlighting on the fly" | Neither Reader nor Origami Text highlights code. |
| "the reader is open source" | Origami Text has an MIT `LICENSE`. **Reader has no licence file.** |
| "Origami Text can also carry spatial layouts" | True of the format and of Origami Text's exporter (`map.views`), but this file carries none: `origami.json` has `"extensions": {}` and no `map` key. |

Also: **no `<h1>` in the content document** (the title lives only in the OPF
and the nav), and the working title "Origami Text (gloss)" and source
filename are still in the metadata.

What already holds up, and should not be disturbed: 18 `data-citation-id`
/`biblioref` citation anchors, 80 `glossref` links resolving into the
backmatter, a complete `nav.xhtml`, full `schema:access*` accessibility
metadata, and the document's own BibTeX entry in `origami.json`.

---

## Principle for all three apps

**A claim in the article must be demonstrable in a file we ship.** Where a
capability is a plan rather than a shipping feature, the prose says so — and
where the prose says it ships, one of these codebases makes it true.

The division of labour follows the article's own words: the substrate's job is
to keep the structure; the reader's job is presentation.

---

## Origami Text (this repo)

Export lives in `LiquidView/OrigamiEPUB.swift`; import in
`LiquidView/OrigamiEPUBImport.swift`.

**OT-1 — Lists become lists. ✅ done.** `element(for:…)` has cases for figures,
tables, rules, fenced code, headings, endnotes, speakers and paragraphs, but
none for list items. A run of paragraphs beginning `• `, `- `, `* ` or `1. `
should export as one `<ul>`/`<ol>` whose `<li>` elements each keep the
paragraph's own `id` and `data-id`, so every item stays individually
addressable. The import must fold them back to the same paragraphs, so the
round trip is unchanged.
*Done when:* a document with a bullet run exports with `<ul>` and per-item
ids, re-imports identically, and the addresses resolve.

**OT-2 — Code blocks say their language the way the article does. ✅ done.** Keep
`data-language` for the round trip and **add `class="language-<lang>"` to the
`<code>`**, which is the convention the article names and every highlighter
expects.
*Done when:* `<pre id=… data-language="swift"><code class="language-swift">`.

**OT-3 — Carry `data-latex` through. ⛔️ blocked.** `LiquidDoc` keeps no
LaTeX source for a math block (nothing in it mentions latex), so the export
side has nothing honest to write. Needs a field on the model first, filled by
the LaTeX importer at import time — then this is a one-line emit. Until then
Reader reads `data-latex` from books that carry it (R-3), which is the half
that can be true today.

*(Original brief)* **Carry `data-latex` through.** When a math block has a LaTeX source
(the LaTeX importer has it at import time), keep it on the model and emit it
as `data-latex` on the `<math>` element; the importer reads it back. Where no
LaTeX source exists, emit MathML alone — never a fabricated string.
*Done when:* a LaTeX-imported equation exports as MathML **plus**
`data-latex`, and `OrigamiEPUBImport` recovers both.

**OT-4 — Export-time conformance check. ✅ done.**
`OrigamiEPUBExporter.profileWarnings(in:)` runs beside the existing
`assertWellFormed` / `assertAnchorsResolve` self-checks and reports — without
blocking — a `<p>` over 150 words containing collapsing line breaks, a
paragraph with no id, bullets that are characters rather than list items
(whether opening a paragraph or buried inside a run-on one), a content
document with no `<h1>`, and a `<pre>` that names no language.

Run against the real September article it reports exactly the audit's
findings:

```
⚠︎ 13 paragraphs over 150 words contain line breaks written as whitespace
⚠︎ 10 bullets are characters rather than list items
⚠︎ The content document has no <h1>
```

and is silent on a conforming document. Note for whoever does AU-1: the
bullet count rises once paragraphs are split, because bullets currently
buried mid-paragraph become paragraph-initial — that is the rule working,
not a regression.

**OT-5 — The test target cannot see `LiquidView`.** Profile tests were
written and then withdrawn: `Origami TextTests` does not link the framework,
and its existing `CitationClipboardTests.swift` **already fails to compile**
for the same reason ("cannot find 'CitationClipboard' in scope" — the type
lives in `LiquidView/ReaderQuote.swift`). This predates the present work. Fix
the target membership, then add the tests, which are parked in this repo as
`OrigamiEPUBProfileTests.swift.pending` (8 cases covering the warnings above and
the list-marker reader; change the import to whatever module ends up
exporting `OrigamiEPUBExporter`).

---

## Reader (`~/Documents/Reader macOS and visionOS`)

Reader is the consumer side — "the reader's job" in the article's division.

**R-1 — A licence. ✅ done.** The article calls the readers open source; Reader ships
no `LICENSE`. Add MIT, matching Origami Text.

**R-2 — Syntax highlighting on the fly. ✅ done.** The EPUB reading applies
highlighting to `<pre><code>`, reading the language from **either**
`class="language-x"` (the spec) or `data-language="x"` (what Origami Text
emits today). Presentation only: the DOM's text is never rewritten, so a
copy still yields the source exactly.

**R-3 — Honour `data-latex`. ✅ done.** Where a `<math>` carries one, Reader offers
its LaTeX for copying, so the fallback the article describes is useful and
not merely declared.

**R-4 — Do *not* paper over collapsed paragraphs.** Setting
`white-space: pre-line` on `<p>` would restore the September article's breaks
and wreck every normally-formatted EPUB, whose source newlines are meaningless.
The fix belongs in the exporters. Recorded here so nobody is tempted.

**R-5 — Addressable-unit anchoring. ✅ done.** A selection in a book now
reports the addressable unit it sits in (`EPUBReadingStyle.selectionBridgeScript`
walks to the nearest ancestor carrying `data-id` or `id`), and **Annotate
Passage…** writes a W3C `commenting` annotation whose target carries the
ladder: the stable id as a FragmentSelector conforming to Origami's own
`data-id` space, the exact words as a TextQuoteSelector with 32 characters of
context either side, and the chapter. **Copy as Citation** produces the block
the article describes — the book's own BibTeX entry with one added
`origami-anchor` field, which a reference manager ingests as an ordinary
entry. 7 tests.

---

## Author — see the hand-over document

`~/Documents/author_mac_forxcode/ORIGAMI-EPUB-EXPORT-FIXES.md` holds the full
brief. In summary, and in priority order:

1. **Soft line breaks must become paragraphs** (`AU-1`). This single fix
   turns 14 addressable units into ~90 and makes the article's central claim
   true of its own file.
2. **Never emit collapsing whitespace inside `<p>`** (`AU-2`).
3. **Bullet and numbered runs become real lists** (`AU-3`).
4. `<h1>` for the title (`AU-4`), code blocks (`AU-5`), MathML + `data-latex`
   (`AU-6`), metadata precedence (`AU-7`), export validation (`AU-8`),
   spatial layouts when present (`AU-9`), title hygiene (`AU-10`).

---

## Prose changes for the article (Frode)

Not code, but the audit's findings that belong in the text:

- "each MathML block is accompanied by a … `data-latex` attribute" — present
  tense for something unbuilt. Move to the same evaluating/plan voice as the
  sentences around it, or wait until OT-3 and AU-6 ship.
- "the local reader application applies that visual syntax highlighting on the
  fly" — true once R-2 ships; today it is a plan.
- "Author … **is being extended** to export transparently to Origami EPUB" —
  it already does; this article is its output.
- "EPUB has existed as an open standard for decades" — EPUB is 2007; "for
  nearly two decades" is safe, or cite OEBPS 1.0 (1999) for "over two".
- Glossary: "Accessibility for Ontarians with Disabilities Act — A Canadian
  law" — it is an Ontario provincial statute.
- "the machine-readable record resides at a fixed path within the container,
  so no discovery step is required" — it is at `OEBPS/origami.json`, which
  depends on where the package document sits; a reader still reads
  `META-INF/container.xml`. Either fix the spec (mandate a container-root
  path) or soften the sentence.
- "Where metadata appears in both the package document and the visible
  appendix, the appendix is canonical" — this file has five copies (OPF,
  inline `<script>` in `content.xhtml`, `origami.json`, `visual-meta.json`,
  `references.bib`). State the precedence across all of them.
- Taylor & Francis figures (360,000 articles; one million EPUB3 files) need a
  citation.
