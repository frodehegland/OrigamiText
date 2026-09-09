# The LaTeX Import Pipeline

*How a publisher's source archive becomes an Origami Text EPUB — what is
taken from the ZIP, what each piece is used for, and how the result is
asserted against the printed paper. Written 8 September 2026, after the
HT '26 proceedings conversion (59 papers), incorporating everything that
conversion taught us. Code: `LaTeXImporter.swift` (parse),
`OrigamiEPUB.swift` (export), `OrigamiEPUBImport.swift` (round-trip).*

---

## 1. The one principle everything else follows

**The camera-ready PDF is the ground truth.** The LaTeX source is only a
carrier; wherever the source and the print can disagree — reference
numbering, section numbers, footnote marks — the import must reproduce
what the *print* shows, and verification means comparing against the
PDF, not against the source. The trust hierarchy, in order:

1. The camera-ready PDF (what the reader of record sees).
2. The archive's own typeset bibliography (`.bbl` / `thebibliography`)
   — the printed numbering, machine-readable.
3. The `.tex` source (structure and words).
4. The `.bib` files (reference data — but *not* reference order, and
   often a whole personal library beside the paper's own citations).
5. Mark Anderson's ACM Hypertext dataset (DOIs the source lacks).
6. **Never** an external registry queried blind (Crossref etc.) — we
   cannot audit its answer.

## 2. What the ZIP contains, and what we take

A TAPS post-acceptance archive typically holds `Source/` (or `source/`)
and `pdf/`. Contents and their uses:

| In the ZIP | What we extract | What it becomes |
|---|---|---|
| `*.tex` (one with `\documentclass`) | the manuscript | body, headings, structure |
| other `*.tex` | pulled in via `\input`/`\include` | body (12 of 59 HT papers keep their whole body in inputs) |
| `*.bib` | BibTeX entries | reference *data* (never order) |
| `*.bbl`, embedded `thebibliography` | `\bibitem` key sequence | reference *order and inclusion* — the printed numbering |
| figure files (png/jpg/pdf, any case) | bytes | image assets; PDFs rasterised to PNG |
| nested `*.zip` | its entries | last-resort figure resolution (ht26-2 ships images only inside its preview bundle) |
| `pdf/*.pdf` | never imported | verification ground truth only |
| `\acmDOI` in the preamble | the paper's DOI | Visual-Meta `doi`, DOI-named file |
| `\title`, `\author`, `\acmConference`/`\acmJournal`/`\acmBooktitle` | metadata | title (one line, `\texorpdfstring` resolved to its plain arm), byline, venue |

Selection rule for the manuscript when several `.tex` declare a
document: `main.tex` by name, else the shallowest path (a stray arXiv
draft often hides in a subfolder — ht26-17), larger file on a tie.

## 3. The pipeline, in order — and why the order is the point

The HT '26 failures were almost all **sequencing** failures: a later
stage overwriting or missing what an earlier stage established. The
stages now run strictly in this order, each one operating on the
output of the last:

1. **Inline the inputs.** `\input`/`\include` resolve up to four levels,
   so every later stage sees one document.
2. **Strip comments.** Before anything pattern-matches — a commented-out
   `\acmConference` template line must not become the venue, and `%`
   line-continuations inside `.bbl` must not hide `\bibitem` keys.
3. **Expand private macros.** Argument-less macros substitute textually;
   parameterised ones (`\secLink{key}{words}` → `\hyperref[key]{words}`)
   expand by `#n` substitution, stepping over their own definition site.
   Without this, a private macro's arguments leak into prose as raw keys.
4. **Read the preamble metadata** (title, authors, venue, DOI) from the
   stripped, expanded source.
5. **Resolve cross-references** — the pre-pass that walks the body once,
   in document order, replicating LaTeX's own counters:
   - sections/subsections/subsubsections (starred = unnumbered;
     `\appendix` switches to letters; a subsubsection directly under a
     section prints `6.0.1`, zero included, exactly as LaTeX does);
   - figures (`figure`, `figure*`, `teaserfigure`), tables, equations
     (unstarred environments), listings (whose labels ride in
     `[caption=…, label={lst:x}]` options, not `\label`);
   - every `\label` binds to the environment span it sits inside, else
     to the current section;
   - then every `\ref`/`\autoref`/`\cref`/`\Cref` is replaced by the
     printed words — "3.2", "Figure 4", "Appendix A", "Listing 2" — and
     headings gain their printed numbers so the words a reference names
     are the words the outline shows. An unresolvable key renders "?",
     as LaTeX itself prints `??` (ht26-2 cites a table its source no
     longer contains; we stay honest about it).
   This *must* precede the body scan: the scan destroys the `\label`s
   the resolution needs.
6. **Scan the body** into paragraphs: known environments handled
   (abstract → heading, acks → "Acknowledgments", figures, tables,
   lists, quotes, verbatim/listings, display math made readable when
   simple — see below — else kept as verbatim TeX);
   unknown environments unwrap — markup drops, words stay.
7. **Convert inline text**, in an order that is itself load-bearing:
   TeX symbol commands become their characters (\lambda is λ in prose
   and mathematics alike — the shared table in BibTeXParser.texSymbols)
   → `\(…\)` normalises to `$…$` → math shields behind placeholders
   (returning readable when nothing structural remains:
   $\lambda_\delta$ → λ_δ, x^2 → x², \sum_{i=1}^{n} → ∑ᵢ₌₁ⁿ,
   \mathcal{L} → ℒ; fractions and matrices stay verbatim TeX — 23
   paragraphs corpus-wide; direct UTF-8 Greek/Cyrillic/CJK always
   passed through untouched) →
   `\texorpdfstring` takes its plain arm → escapes → `\label` strip
   (a label inside a heading's own braces is invisible to the scanner)
   → **footnotes out** (one document-wide counter — per-paragraph
   counters gave ht26-18's 33 notes the same id 33 times) → citations
   to `[cite:key]` tokens → hyperlink plumbing (`\hypertarget` drops
   whole, `\hyperlink` keeps its words) → links → emphasis → accents
   (composed onto the last *letter* of the match, never the closing
   brace of `{\'e}`) → generic unwrap of what remains.
8. **Assemble the bibliography:**
   - *Inclusion:* with a printed bibliography, exactly its entries — the
     print can cite from places body tokens cannot reach (ht26-26 cites
     a proceedings from a note inside another reference). Without one,
     the works the body cites (a source archive often carries a
     1,800-entry personal `.bib`; the paper cites 30).
   - *Order:* the `\bibitem` sequence when present (exact print — and
     genuinely necessary: the HT '26 archives' printed bibliographies
     are not all alphabetical; several are citation-ordered or carry
     organisation/no-year quirks, so no emulation could reproduce them),
     else ACM-Reference-Format emulated — the author label
     (surname, then given name: Canyu Chen stands before Emily Chen
     regardless of year, ht26-47's lesson), then year, then title.
     Validated by PDF spot-checks of emulator-path papers (ht26-41,
     -47, -57: every checked position matches print).
   - *Key reconciliation:* case-insensitive first, then punctuation-blind
     — a body citing `ca-nurnberg-99` finds the bib's `ca-nurnberg+99`.
   - Each reference carries its printed number explicitly
     (`Reference.number`), so every platform shows the `[n]` the PDF shows.
9. **Resolve figures:** exact path → extension probing (both cases) →
   any-folder suffix match → nested-zip entries. A resolved PDF figure
   is rasterised to PNG (the native readers cannot show a PDF in an
   image). A figure whose file truly is not in the archive keeps its
   caption with a quiet note — never a broken marker.
10. **Parse tables:** leading braced groups that hold no cell separators
    are chrome (`tabularx` has *two* — width then spec), `\\[.5ex]` row
    options are geometry, `\multicolumn`/`\multirow` spread their words,
    cell decorations (`\rotatebox` and kin) shed their geometry.

### 3b. Rendering the reference list — display is its own layer

The visible reference line is built from TeX-cleaned display fields —
the raw BibTeX travels untouched in `data-bibtex`, but the words a
reader sees pass through `BibTeXParser.displayText`: accents composed
(both `\'{e}` and the brace-stripped `\'\i` dotless forms), escapes
resolved, emphasis unwrapped, braces shed, quotes and dashes
typographic. An accent mark that never finds its letter — an author's
typo, which LaTeX prints as a floating accent — degrades to the
spacing accent character, never a raw backslash. The line itself is
ACM-shaped: authors, year, title roman, the venue in `<em>` italic,
and the way out live as a real `<a>` link — DOI first, else URL.
One routing rule: ACM's `10.5555` prefix is a Digital Library internal
identifier, not a registered DOI (doi.org answers 404), so those link
to `dl.acm.org/doi/…` instead. Cleaning happens where the `Citation`
is built, so the Visual-Meta pool and CSL-JSON carry clean text too.

Verified across the corpus: 2,145 references, zero TeX residue in
visible text, 1,853 italic venues (the rest genuinely have no venue),
1,135 live links; every sampled DOI resolves at doi.org (publisher
sites may 403 a non-browser client — that is a bot wall, not a dead
link; registration is checked at doi.org without following).

## 4. The identity contract at export — the footnote lesson

The exported HTML carries **two identity systems** (per the EPUB spec):
the element `id` is the human-speakable *purple number* (`3`, `3B`,
`60B`…) assigned at export, and the *stable id* (`p14`, `fn1`) rides in
`data-id`, which is how Map views and re-imports keep pointing at the
right things across re-exports.

The rule the footnote bug taught us: **anything a standard reader must
resolve goes through `id`; anything only Origami must recover goes
through a `data-` attribute.** The note daggers used to link `#fn1` —
a data-id that no ordinary EPUB reader can find, so the anchors were
dead everywhere except our own apps (which resolve data-ids and so
never noticed). Now:

- the dagger's `href` targets the note's **purple number** (`#60B`) —
  resolvable by any reader;
- the token's stable id travels in `data-note-id="fn1"`, and the
  importer prefers that attribute (falling back to the href fragment
  for older exports), so a round-trip recovers `fn1`, never `60B`.

Citations follow the same contract: visible `[n]` linked to
`#ref-<n>`, the BibTeX key in `data-citation-id`.

## 5. How we assert the result matches the print

Four layers, cheapest first; the batch runs all of them:

1. **Structural digest, every paper, no PDF needed.** Counts and red
   flags straight off the imported model: leaked label keys in prose
   (regex for `sec:|fig:|tab:…` shapes), duplicate paragraph ids,
   `[cite:]` tokens with no matching reference, unresolved figure
   markers, PDF-format assets, raw-TeX residue outside math. The HT '26
   baseline had 543 leaked keys and 80+ duplicate note ids; the bar is
   zero.
2. **Anchor integrity, every paper.** Unzip the produced EPUB and assert
   every internal `href="#X"` has a matching `id="X"` in the same
   document. This single check would have caught the footnote bug the
   day it was written. Current bar: **zero broken anchors across the
   set.**
3. **Round-trip.** Re-import the produced EPUB through
   `OrigamiEPUBImporter` and assert the tokens survive: every
   `[note:fnN]` finds a note paragraph with that stable id (33/33 on
   the worst paper), headings and reference counts intact.
4. **Print comparison, sampled adversarially.** Pick the extremes —
   most footnotes, most tables, most math, PDF-figure-heavy, deepest
   nesting, `\input`-structured — render their camera PDFs (PDFKit)
   and compare by category: heading tree and numbering, first/last
   reference and the count (ht26-18: 159 = the PDF's `[159]`), table
   values digit-for-digit, xref words, equation content. Papers that
   ship a `.bbl` double as ground truth for the alphabetical emulator.

DOI assertion is its own rule: a DOI is written only when the source
declares a well-formed one or the dataset names it; placeholders
(`XXXXXXX`, `NNNNNN`) are *detected*, never shipped, and a paper with
no trusted DOI ships DOI-less under its TAPS name, flagged in the
report. (ht26-30's camera PDF prints its neighbour's DOI — sources lie;
the dataset caught it.)

## 6. What this process taught us

1. **Sequencing is the architecture.** Almost every bug was a stage
   consuming something a different stage had already destroyed
   (labels stripped before refs resolved; ids re-assigned after anchors
   were written; escapes run before `\texorpdfstring` could read its
   braces). The fix each time was not cleverness but ordering — and the
   order is now explicit, documented, and enforced by the pipeline shape.
2. **Verify against the artefact readers see, not the input.** Checking
   the source told us the conversion was "complete"; checking the PDF
   told us the numbers were wrong and the anchors dead.
3. **Archives are dirty in every way archives can be dirty.** Missing
   images, images only inside a nested zip, a cited table that no longer
   exists, `.bib` and `.bbl` keys that drifted apart, wrong DOI printed
   on the paper itself, draft copies of the manuscript in subfolders,
   1,800-entry personal bib files, `%`-broken lines inside `.bbl`,
   uppercase extensions. Every one appeared in a set of just 59 papers.
   Tolerance with honesty — keep the words, note the gap, never crash —
   is the only viable posture.
4. **Mechanical sweeps scale; eyeballs don't.** Nobody can check 59
   papers by hand, but a digest that says "zero leaked keys, zero broken
   anchors, zero orphan cites" certifies the 54 nobody read, and the
   five that were read validate the digest.
5. **The two-identity contract must be stated, not implied.** The
   footnote bug existed because "who resolves this id?" had never been
   asked explicitly. §4 is that answer, written down.

## 7. Making it more robust — the backlog

In rough order of value:

1. **Move the anchor-integrity check into the exporter.** *Done, same
   day:* `OrigamiEPUBExporter.write` now refuses a dangling internal
   anchor (`danglingAnchor`) exactly as it refuses malformed XML — in
   the content document and from the navigation document into it. One
   subtlety the guard itself taught: `data-note-id="fn9"` contains the
   characters `id="fn9"`, so id collection requires a real attribute
   boundary or a dead anchor masks itself behind the very attribute
   that names it. Proven against a fabricated dead note (refused) and
   the full 59-paper corpus (0 false refusals).
2. **A per-paper conversion note.** The importer already knows what it
   dropped (references without a parsable year, figures without files,
   unresolvable labels). Emit those counts into the conversion report
   (or a quiet `conversion-notes` field in Visual-Meta) so a silent
   degradation is never silent.
3. **Equation numbering fidelity.** An `align` with three rows prints
   three numbers; we count one per environment. Corpus exposure today:
   five `eq:` refs in 59 papers. Worth doing when a math-heavy corpus
   arrives, together with the MathML phase of the mathematics profile
   (simple formulae now ship as Unicode; only structural TeX —
   fractions, matrices, alignments — remains verbatim).
4. **`\bibliography{…}` scoping in archives.** We currently concatenate
   every `.bib` in the zip; the named-files rule (already used for bare
   `.tex` imports) would avoid ever parsing a stray second library with
   colliding keys.
5. **Table row/col assertions.** The digest prints dimensions; it could
   assert rectangularity and flag suspiciously empty header rows —
   the two table bugs found this round would both have tripped it.
6. **Caption/heading token audit.** Tokens are stripped from captions
   (cite, note) by special-casing; a general rule — "which token kinds
   may survive in which contexts" — would close the class rather than
   the instances.
7. **Word (.docx) ingestion** for the odd paper that ships without TAPS
   source (ht26-3), through `WordImporter` with this same verification
   harness around it.
