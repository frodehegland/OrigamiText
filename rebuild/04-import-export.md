# Chapter 4: Import and export

This chapter covers how Origami Text gets documents in and how it writes them out. It describes behaviour, data and algorithms without tying them to a platform, so the app (or a compatible one) can be rebuilt anywhere. Apple-specific pieces are named, and Section 6 suggests portable replacements.

Source paths are relative to the repository root. Unless another path is given, code lives in `Origami Text macOS/`. Line numbers are approximate and will drift.

**Read these first.** This chapter links to them and does not repeat them.

| Document | What it governs |
|---|---|
| [`ORIGAMI-EPUB-PROFILE-1.0.md`](../ORIGAMI-EPUB-PROFILE-1.0.md) (repo root; an identical copy sits in `Origami Text macOS/`) | The normative EPUB profile the writer targets. Where this chapter and the profile disagree about what the format *requires*, the profile governs. |
| [`ORIGAMI-EPUB-CONFORMANCE-PLAN.md`](../ORIGAMI-EPUB-CONFORMANCE-PLAN.md) | The September 2026 audit, plus the OT-1 to OT-5 fix list. It is partly superseded by the profile. |
| [`AUTHOR-EXPORT-FRONT-MATTER.md`](../AUTHOR-EXPORT-FRONT-MATTER.md) | How Author (the sibling writing app) should write authors, affiliations, rights and references, so that this app can render them. |
| [`Origami Text macOS/LATEX-IMPORT-PIPELINE.md`](../Origami%20Text%20macOS/LATEX-IMPORT-PIPELINE.md) | Why the LaTeX importer's stage order is what it is, plus the verification layers and the backlog. |
| [`Origami Text macOS/CITATION-EPUB-SPEC.md`](../Origami%20Text%20macOS/CITATION-EPUB-SPEC.md) | The contract for Copy to Cite on the clipboard, and what Author must embed for citations. |
| [`origami-schemas/README.md`](../origami-schemas/README.md) | The JSON Schemas for `visual-meta.json` and `origami.json`, the reference validator and extractor (`origami-validate.py`, profile §19.3), their test suites, and how to run them. |
| [`origami-corpus/README.md`](../origami-corpus/README.md) | The conformance corpus (profile §20): 25 publications in fourteen items, each with its expected extraction and verdict. `11-packaging/B-link-only` (records declared only with `<link rel="record">`) is the conforming packaging shape. |
| [`origami-packaging-tests/RUN-THIS.md`](../origami-packaging-tests/RUN-THIS.md) | The 24 September packaging test that settled §4.4, kept for its record. Superseded by `origami-corpus/11-packaging`. |

---

## 1. Purpose

Origami Text is a reader. It is also a **converter**: every scholarly input becomes an Origami EPUB (Profile 1.0), and that EPUB is "the document". As `AppModel.importConverted` puts it: "the .xml/.docx was only ever a carrier". Two families of output exist:

1. **The Origami EPUB.** It is written by `OrigamiEPUBExporter` (`OrigamiEPUB.swift`) from the internal model `LiquidDoc`. This is how the library stores imported papers, and how papers are published (the 61 HT '26 proceedings EPUBs were made this way).
2. **Publisher formats ("Import to Format").** These are written by `ACMLaTeX` (`LiquidDocWriting.swift`). There are six publisher targets: ACM `acmart` (11 styles), IEEE, Springer LNCS, Elsevier (two layouts), and an arXiv-style preprint. Each produces LaTeX source plus BibTeX, and the app optionally compiles it to PDF with the user's TeX installation. An EPUB in the same house style can be written beside it. For ACM, a TAPS upload ZIP is also made.

A third, smaller set of outputs is covered briefly:
- the `.origamitext` JSON draft (`LiquidDoc.jsonData()`);
- an XR export into an Author `.liquid` package (`AuthorMapExport.swift`);
- transcript summaries (`TranscriptSummary.swift`).

Every importer converges on one model, so a rebuild needs only **N readers + 1 EPUB writer + 1 LaTeX writer**, not N×M converters.

### 1.1 The internal model in one paragraph

`LiquidDoc` (`LiquidDoc.swift` ~417) is a flat document. It has no tree and no HTML stage.

- **Body:** an array of `Paragraph {id, heading: Int?, text, speaker?, tableID?, stretchID?, boxID?, provenance?}`.
- **Side arrays:** `references: [Reference {id, bibtex, citedAs?, number?, forms?}]`, `tables: [Table {identifier, rowCount, columnCount, cells[[Cell{value, formula?, columnSpan?}]]}]`, `assets: [Asset {id, filename, mediaType, dataBase64, alt?, link?, citationKey?}]`, `concepts`, `layouts`, `mapConnections` and `links`.
- **Front matter:** `title`, `subtitle`, `authors: [String]`, name-keyed `authorAffiliations` / `authorEmails` / `authorORCIDs`, `affiliations`, `abstract`, `keywords`, `ccsConcepts`, `doi`, `isbn`, `publication`, `journal`, `acmReference`, `license`, `licenseURI` and `date`.
- **Language:** `language` (BCP 47), and `forms` / `authorForms`, which hold `LanguageForms {lang?, alternate:[{value, lang?, relation}]}` for title, subtitle, abstract, publication, journal and author names.

Paragraph text uses a small markup convention, shared by every importer and both writers:

| Token in `Paragraph.text` | Meaning |
|---|---|
| `**strong**`, `*em*`, `` `code` ``, `==mark==` | Emphasis, code, and authorial highlight (`<mark>`) |
| `[cite:key]` | A citation of `references[].id == key` |
| `[note:id]`, `[inote:id]` | A footnote or endnote mark, and an inline note mark. The note itself is a paragraph with that `id`, usually under a final level-1 heading "Notes". |
| `![caption](asset:imgN)` | A figure. `![…](model:…)` is a 3D model figure. |
| `$$\n<TeX>\n$$` (a whole paragraph) | A display equation, kept as TeX |
| `$…$` | Inline maths (Pandoc rules: `OrigamiMath.inlineMath`) |
| ```` ```lang ```` fenced block | Code |
| `• item`, `- item`, `1. item` | List items (one paragraph per item, or one item per line) |
| `> text` | A block quote |
| `---` | A thematic break |
| `\| a \| b \|` lines + `tableID` | Pipe-table fallback text. The grid itself is `tables[tableID]`. |
| `[words](origami-jump:pN)` | An internal cross-reference |
| `[words](https://…)` | An external link |
| `[rel:address#frag]` | A typed link to another Origami document |
| `Name: statement` + `speaker` | A transcript statement |

Maths is **never** converted at import. It stays TeX until a writer turns it into MathML (EPUB) or passes it through (LaTeX).

---

## 2. Pipeline overview

```
 input file ──► detection (extension, a few sniffs) ──► importer ──► LiquidDoc
                                                                      │
          ┌───────────────────────────────────────────────────────────┼──────────────────────┐
          ▼                                                           ▼                      ▼
 OrigamiEPUBExporter.write ──► library EPUB          ACMLaTeX.bundle ──► paper.tex/refs.bib   LiquidDoc.jsonData
 (Profile 1.0)                 (re-imported as an    + images/ + README ──► pdflatex ──► PDF  (.origamitext draft)
                               EPUBRecord)           + optional house-style EPUB + ACM ZIP
```

Detection is done in two places:
- `AppModel.openFile(at:)` / `importFile(at:companions:)` / `importFolder` (`AppModel.swift` ~870–1316 and ~7100–7780) for library import;
- `FormatSources.load(_:fallbackAuthor:)` (`FormatSources.swift` ~55) for Import to Format.

Detection is **by file extension**, with only a few content sniffs. Those are listed in the Detection column below.

| Input | Detection | Importer | Output | Notes |
|---|---|---|---|---|
| EPUB 2/3 | `.epub` | `OrigamiEPUBImporter.importDocument(at:)` (`OrigamiEPUBImport.swift`) then `AppModel.structuredDoc` | Library record (the EPUB itself); a `LiquidDoc` for Format | Reads Profile 1.0 records, pre-1.0 exports and plain EPUBs |
| ZIP of EPUBs | `.zip` containing `.epub` entries (not `__MACOSX`, not `._`) | `AppModel.importEPUBBundle` (~1113) | Each EPUB filed | Checked before treating a zip as LaTeX |
| LaTeX project | `.zip` (other), `.tex`, folder | `LaTeXImporter.importArchive` / `importTeXFile` / `importFolder` | EPUB (`importLaTeX`) | Main-file heuristics in §3.2 |
| arXiv source | `.tar.gz`, `.tgz`, `.tar`, `.gz` | `FormatSources.loadTarball` → `LaTeXImporter.importFolder` | EPUB | Uses the system `tar` / `gunzip` |
| Markdown / plain text | `.md`, `.markdown`, `.txt` | `TranscriptImporter.looksLikeTranscript` first; then `MarkupImport.importFile` → `MarkdownImporter` | Transcript draft, plain draft, or EPUB if `isPaper` | `isPaper` = has references or notes |
| Typst | `.typ` | `TypstBridge` → Markdown → `MarkdownImporter` | Draft or EPUB | `MarkupBridges.swift` |
| AsciiDoc | `.adoc`, `.asciidoc` | `AsciiDocBridge` → Markdown | Draft or EPUB | |
| reStructuredText | `.rst` | `RSTBridge` → Markdown | Draft or EPUB | |
| Word (ACM template) | `.docx` whose `word/document.xml` contains `w:val="Titledocument"` | `ACMWordPaper.importPaper(at:tapsHTML:)` (`WordImporter.swift`) | EPUB (`importWordPaper`) | A same-stem `.html` beside it (TAPS rendering) fills print-side gaps |
| Word / RTF / ODT (other) | `.docx`, `.doc`, `.rtf`, `.rtfd`, `.odt` | `WordImporter.importFile` (system rich-text reader + OOXML recovery) | Draft (library); `LiquidDoc` (Format) | RTF/RTFD are transcript-sniffed first |
| HTML | `.html`, `.htm`, `.xhtml` | `WordImporter`, then `FormatSources.applyScholarMeta` | EPUB (`importConverted`) | Reads `citation_*`, `DC.*`, `og:title` meta tags |
| JATS / BITS XML | `.xml`, root `article` or `book-part-wrapper` | `BITSImporter` + `LiquidDoc.applyingJATSFrontMatter` | EPUB (`importBITS`) | |
| EndNote XML | `.xml` whose first 4096 bytes contain `<records` and `<record` | `ReferenceFormats.bibtexText` | Reference-list EPUB | |
| RIS / EndNote tagged | `.ris`, `.enw` | `ReferenceFormats.bibtexText` | Reference-list EPUB | |
| BibTeX | `.bib` | `FormatSources.referenceList(fromBibTeX:)` | Reference-list EPUB (`documentType = "bibliography"`) | |
| CSL-JSON | `.json` passing `FormatSources.isCSLJSON` | `FormatSources.referenceList(fromCSLJSON:)` | Reference-list EPUB | Any other JSON is a reference dataset (another chapter) |
| PDF | `.pdf` | `PDFImporter.importFile` + `PDFStructure.read` | Draft | No OCR; reads an embedded Visual-Meta appendix |
| Author document | `.liquid` package | `AuthorImporter.importDocument` | Draft, `documentType = book` | Reverse-engineered package layout |
| Gemtext | `.gmi`, `.gemini` | `importGemtext` (`GemtextOpen.swift`, `Gemtext.swift`) | Library item | Outside this chapter |
| CSV / TSV | Opened from Time Flows, not library import | `TabularDataImporter.parse` | Chart series | Not a document import |
| Companion bibliography | `.bib`/`.ris`/`.enw`/CSL `.json`/EndNote `.xml` dropped **together with** a `.tex`/`.md`/`.typ`/`.adoc`/`.rst` | `AppModel.isBibliographyFile` (~7115) + the citing importer | Merged into that paper | Not filed on its own |

Every "EPUB" output follows the same steps:
1. Build a `LiquidDoc` with `documentType = book`.
2. Check for duplicates with `existingConversion(title:author:)`.
3. Call `OrigamiEPUBExporter.write` to a temporary file.
4. Call `importEPUB(at:)`, which files it as an `EPUBRecord`.

A "Draft" is saved with `drafts.save` as an editable `LiquidDoc`.

**Batch folder import** (`AppModel.importFolder`, ~1175–1316) files EPUBs only, using these rules:
- A `.html` next to a same-name `.docx` is skipped (it is that paper's TAPS rendering).
- Bibliography files are skipped when a citing document is present.
- A `.docx` is taken only if it is an ACM paper.
- Markdown-family files are taken only if they are papers. Plain notes are reported as "left for Import on their own".

---

## 3. The importers

### 3.1 EPUB: `OrigamiEPUBImporter` (`OrigamiEPUBImport.swift`, ~3.7k lines)

This is the importer the reader and Import to Format both use. A paper is therefore rendered from exactly what a person would read.

**Entry points.**
- `importDocument(at:)` (~129) reads from a ZIP.
- `importDocument(inUnpackedFolder:)` (~141) reads from an unpacked folder.
- Both build a `PackageSource` of two closures (`entry`, `entryWithSuffix`) and call the private `importDocument(from:)` (~159–740).
- `unpack(at:into:)` (~753) writes the package out for web-view rendering, and checks for DRM.

**ZIP and DRM.**
- The ZIP reader (`ZipReader`, ~3688) supports method 0 (stored) and method 8 (deflate). Anything else throws `.unsupportedCompression`.
- Errors are `notAnEPUB`, `unsupportedCompression`, `corruptContainer`, `missingContent` and `protected(String)`.
- DRM is checked only in `unpack`:
  - `META-INF/license.lcpl` means Readium LCP; `sinf.xml` means FairPlay; `rights.xml` means Adobe.
  - In `encryption.xml`, only font obfuscation is allowed. The IDPF algorithm XORs the first 1040 bytes with SHA-1 of the unique id. The Adobe algorithm XORs the first 1024 bytes with the 16-byte UUID.

**Read order.** Everything is parsed by regular expression, not with an XML parser.
1. `META-INF/container.xml`: the `full-path` gives the OPF path (default `package.opf`).
2. The OPF supplies:
   - `dc:title`, every `dc:creator`, `dc:date`, `dc:identifier`, `dc:language`, `dc:subject` (fallback keywords), `dc:rights` and `dcterms:license`;
   - the venue, from `belongs-to-collection`, then `dcterms:isPartOf`, then `calibre:series`;
   - the DOI (`extractDOI` ~1323), from `scheme="doi"`, `opf:scheme`, `prism:doi`, `schema:doi`, or any `10.NNNN/` identifier;
   - the profile, from `dcterms:conformsTo` starting `https://github.com/frodehegland/OrigamiText/tree/main/profile/`. A major version above 1 is read as a plain EPUB (~210).
3. The spine: every spine document is read, with `linear="no"` items placed last (`spineContentHrefs` ~1351).
4. The semantic record:
   - First, `<link rel="record" properties="origami:visual-meta">` (`recordHref` ~1475).
   - Then a file named `visual-meta.json`, then any file ending in `visual-meta.json`.
   - Last, the copy embedded in the HTML between `id="visual-meta-payload">` and `</script>`, with any CDATA wrapper removed (`embeddedVisualMeta` ~1862).
5. The interaction record: `properties="origami:interaction"`, then `origami.json`, then any file ending in `origami.json`.
6. The bibliography record: `origami:bibliography`, then `references.bib`, then any file ending in `references.bib`. It is read only when there is no citation pool yet. `referencesFromBibliography` (~3021) works like this:
   - BibTeX keys are matched to `citations[].id`.
   - If no keys match, entries are matched to the visible `<li id="bib-…">` text by title or first author, never by position.
   - Each entry is re-keyed to the citation id.

**Which source wins** (this follows profile §17.3):

| Fact | First choice | Fallback |
|---|---|---|
| Citations | Visual-Meta `citations[]` | `origami.json` `references` / `blocks[type=reference]` |
| Tables and Map layouts | `origami.json` | Visual-Meta |
| Concepts, notes, links, equations, front matter | Visual-Meta | Body scan |

This is deliberate: pre-1.0 exports duplicated data across both records, and the code comments record "32 references into 63" from merging them.

**Body parsing** (`bodyParagraphs` ~2274).

Before parsing:
- `<script>` is stripped.
- HTML named entities are converted to numeric ones (`xmlSafeEntities` ~821).
- The XML declaration is dropped.

The document is then parsed with `XMLTree` (~3485, a SAX delegate). If that fails, a tidy-HTML parse is used, on macOS only. The root is `<main>`, or `<body>` if there is no `<main>`.

- **Heading levels.** If an `h1` exists, h1/h2/h3 map to 1/2/3, and anything deeper maps to 3. If there is no `h1`, h2 becomes level 1 (~2373).
- **Element id.** `data-id`, then `id`, then a generated `pN`. The order is reversed (`id` first) when the profile is declared.

| Element | Becomes |
|---|---|
| `p`, `blockquote` | Paragraph(s), split on blank lines. `strong.speaker` sets `speaker`. |
| `li` | A paragraph prefixed `• ` or `N. ` |
| `pre` | A fenced block, with `data-language` as the info string |
| `hr` | `---` |
| `math` | `$$tex$$` from `data-latex`, else `` `alttext` `` |
| `figure`/`img` | An asset (base64) plus `![alt](asset:id)`. The figcaption wins over `alt`. An `<a href>` wrapper sets `Asset.link` and `data-citation-key`. |
| `[data-model-src]` | A 3D model figure (`spatialFigureFacts` ~3452) |
| `table` | Pipe-text plus `tableID`. A table with no `data-table-id` is captured as a static grid. |
| `audio`/`video` | `[▶ Play …](origami-media:path)` |
| `svg` | Its `<image>` becomes an asset |
| `aside.ot-box` / `aside.ot-stretchtext-content` / `aside[epub:type~=footnote]` | `boxID`, `stretchID`, a captured footnote |

- **Back matter.** Glossary, bibliography and endnotes sections are skipped when records exist. The colophon is always kept, even one placed after `</main>`.
- **Image budget.** Multi-document books may embed at most 12,000,000 bytes of images (~386).

**Inline conventions** (`inlineText` ~3209):
- `strong` becomes `**`, `em` becomes `*`, `mark` becomes `==`, `code` becomes backticks.
- `data-latex` becomes `$…$`.
- Ruby becomes `base（reading）`.
- `data-citation-key`, or a biblioref to `#bib-<id>`, becomes `[cite:key]`.
- A noteref becomes `[note:id]`; `ot-inline-note` becomes `[inote:id]`.
- An `a.citation` carrying `data-origami-ref` becomes `[address]`.
- A `#fragment` link becomes `[t](origami-jump:id)`. These are resolved in a second pass (`resolveJumpAnchors` ~2825).

**After the body is read** (~456–611):
- `applyingQuoteLinks` runs.
- `conceptsFollowingGlossaryLinks` runs. A plain EPUB's `<dt>/<dd>` becomes concepts.
- Equations are taken from the `equations[]` index (`EquationIndex.build`), or else from a `math[id]` scan.
- References are enriched with `citedAs` and `number`. A cited key that is not in the bibliography gets a synthesised `@misc` (`anchorBibTeX` ~3143): "Names YEAR" gives author and year, text of 120 characters or fewer becomes the title, and longer text becomes a note.
- Notes are appended under a level-1 heading "Notes" with id `notes`.

**Intermediate model.** `ImportResult` (~40–117) mirrors the `LiquidDoc` front matter, plus `body`, `references`, `tables`, `equations`, `assets`, `language`, `forms`, `authorForms`, `bibliographyConventions` and `unreadableDocuments`. `AuthorDetails` (~1042) unpacks author objects `{name | family/given, affiliation(s), email, orcid}`, stripping the ORCID URL prefix and `mailto:`. `AppModel.structuredDoc(from:record:fallbackID:base:)` (`AppModel.swift` ~4222) copies `ImportResult` into a `LiquidDoc` field by field.

**Known gaps.**
- The tidy-HTML fallback is macOS-only.
- DRM is checked only on `unpack`.
- The legacy `<model>` element is accepted only for files already on disk.

### 3.2 LaTeX: `LaTeXImporter` (`LaTeXImporter.swift`, ~2.6k lines)

The rationale is in [`LATEX-IMPORT-PIPELINE.md`](../Origami%20Text%20macOS/LATEX-IMPORT-PIPELINE.md). Its main principle is that **stage order is the architecture**. What follows is the algorithm.

**Inputs.**
- `importArchive(at:)` reads a ZIP (`ZipReader`); `importFolder(at:)` reads a folder (`FolderArchive` ~2625). Both conform to `LaTeXSourceArchive {entryNames; entry(_:)}`.
- `importTeXFile(at:extraBibliography:)` (~269) reads a bare `.tex`.

**Choosing the main file** (`importArchive(from:fallbackTitle:)` ~85). Candidates are `.tex` entries outside `__MACOSX`. The rules are tried in order:
1. Any file named `main.tex`.
2. Among files containing both `\documentclass` and `\begin{document}`, the shallowest path, with larger size breaking ties.
3. The largest `.tex`.

Text is decoded as lossy UTF-8.

**Bibliography sources.**
- **In an archive:** every `.bib` is concatenated (a known gap: `\bibliography{}` scoping is not applied), and every `.bbl` is concatenated as `printedBibliography`.
- **For a bare `.tex`:** the importer reads `\bibliography{a,b}` and `\addbibresource{…}`, adding `.bib` where missing. If neither is present, it uses every `.bib` in the folder, plus any companions.
- Every file goes through `ReferenceFormats.bibtexText`, so RIS, EndNote and CSL-JSON companions work too.
- `needsBibliography(ofTeXAt:)` (~323) decides whether the sandbox must ask for folder access. It is true when the source cites, has no `thebibliography`, and its named `.bib` files are unreadable.

**Figure resolver** (~144–165). It tries, in order:
1. `mainDir/path`;
2. `path`;
3. any entry ending in `/basename`;
4. entries inside nested `.zip` files, opened lazily.

A path with no extension is tried with `jpg, jpeg, png, pdf, tiff`, in lower case and then upper case. A PDF figure (by extension or `%PDF` magic bytes) is rasterised by `rasterizedPDF` (~1657): page 1, scale `min(2, 2200/maxSide)`, on a white background, saved as PNG.

**ACM Reference Format from the camera PDF** (`acmReference(inArchive:)` ~180):
1. Open the PDFs in the archive, largest first.
2. Accept the first whose page-1 text contains the title's first 48 alphanumerics.
3. On pages 0–2, take the text from `ACM Reference Format:` to `https://doi.org/`.
4. Rejoin hyphenation (`-\n(?=[a-z])`) and append `\acmDOI`.

**Stages of `importTeX(...)` (~335), in order.**
1. **Author live tables.** JSON between two `<<<VISUALMETA:TABLES>>>` marker lines (leading `%` removed), as an array or as `{tables:[…]}`. Each table has `identifier`, `rowCount`, `columnCount` and `cells[[{value, formula}]]`. This runs **before** comments are stripped, because the block is commented out.
2. **`\input` / `\include` inlining** (`inlinedInputs` ~2044). At most 4 passes. It tries `x` and `x.tex`, relative to the main file, then the archive root. Unresolved inputs become empty.
3. **`strippingComments`** (~2154).
   - An unescaped `%` removes the rest of the line, the newline, and the next line's leading blanks.
   - It also removes `\begin{comment}…\end{comment}` and `\iffalse…\fi` (not nested).
4. **`\aptLtoX[opt]{A}{B}`** → `A`.
5. **Macro expansion** (`expandingSimpleMacros` ~2067).
   - `\newcommand`/`\renewcommand`/`\providecommand` and argument-less `\def` are recognised.
   - Macros with no arguments are substituted twice.
   - Macros with 1–3 arguments get `#n` substitution, capped at 400 hits per macro.
   - Self-referential macros, default optional arguments, `\def` with parameters and `\let` are skipped.
6. **Preamble metadata.** A hand-written brace matcher (`firstBalancedArgument`, `balancedArguments` ~2485–2590) reads:
   - `\title[short]{…}` and `\subtitle`;
   - every `\author{}`;
   - `\orcid`, `\email` and `\affiliation`, each paired with the preceding author (one regex walk, ~391). An affiliation becomes the line `institution, city, state, country`.
   - The venue, from `\acmJournal` / `\acmConference` / `\acmBooktitle`, last declaration winning. Template placeholders ("make sure to enter", "conference acronym", "woodstock") are rejected.
   - `\acmDOI`, which must contain `/`.
   - The body: the text between `\begin{document}` and `\end{document}`.
7. **Cross-references** (`resolvingCrossReferences` ~1456). This runs before the body scan.
   - **Sections:** counters run c1.c2.c3; starred sections are unnumbered; `\appendix` switches to letters. The number is inserted into the heading text.
   - **Figures and tables:** counted by counted `\caption`. `\caption*` and captions inside sub-floats are not counted.
   - **Labels:** each `\label` binds to its enclosing float, listing or equation, otherwise to the current section. A listing's `label=` option counts as a label.
   - **References:** `\ref`/`\pageref` become the number; `\cref` becomes a lower-case phrase; `\autoref`/`\Cref` become "Figure 4", "Section 3.2", "Appendix A". Each becomes the token `[jump:key|words]`. An unknown key prints `?`.
8. **Body scan** (nested `scan()` ~774). It is hand-written and walks from backslash to backslash.

   | Construct | Result |
   |---|---|
   | `\section`, `\chapter` | heading level 1 |
   | `\subsection` | heading level 2 |
   | `\subsubsection`, `\paragraph`, `\subparagraph` | run-in `*label.* ` at the start of the next paragraph |
   | `abstract` | heading "Abstract" (level 1) + body |
   | `acks` | heading "Acknowledgments" (level 1) |
   | `figure`, `figure*`, `teaserfigure` | figures, "Figure N: caption" |
   | `table`, `table*` | numbered tables; `tabular`/`tabularx` alone are unnumbered |
   | `itemize`/`enumerate` | one paragraph per `\item`, prefixed `• ` / `1. `; nested lists are flattened |
   | `tcolorbox`, `mdframed`, `promptbox`, `shaded`, … | `**title**` + paragraphs sharing `boxID = boxN` |
   | `verbatim`, `lstlisting`, `minted` | fenced code (no language); a `caption=` option becomes a paragraph |
   | `equation`, `align`, `eqnarray`, `displaymath`, `\[…\]` | `$$…$$`; `align`/`eqnarray` are wrapped in `aligned` |
   | `CCSXML`, `thebibliography`, `titlepage` | dropped |
   | ~45 front-matter commands (`\maketitle`, `\keywords`, `\ccsdesc`, `\thanks`, …) | dropped with their arguments |

9. **Figures** (`appendFigure` ~614). The float is split into (images, caption) segments, and a caption written before its images takes the images that follow it. Only the first image of each segment is emitted (a known gap). A missing file keeps the caption plus "(The source archive does not include this figure's image.)".
10. **Tables** (`appendTable` ~688, `tabularRows` ~2267, `expandingSpans` ~2359).
    - If live tables from stage 1 remain, the next one is used. Otherwise the first `tabular` in the float is parsed.
    - Up to 3 leading column-spec groups are removed. So are the rules (`\toprule`, `\midrule`, `\cmidrule`, `\hline`).
    - Rows split on `\\` and cells on unescaped `&`.
    - Cell decorations are removed (`rotatebox`, `makecell`, …).
    - `\multicolumn{n}` becomes the words plus n−1 empty cells. `\multirow` becomes just its words.
    - The table id is `tex-table-N`, and the caption paragraph "Table N: …" goes **above** the grid.
11. **CCS and keywords.** Each `\ccsdesc[…]{Root~Leaf}` becomes `• Root → Leaf`, and they are joined as `**CCS Concepts:** a; b.`. `\keywords{}` becomes `**Keywords:** …`. Both are inserted after the abstract. Here they are body text; `ACMLaTeX.withFrontMatterFromBody` lifts them back into fields at export.
12. **Footnotes.** `\footnote{}` becomes `[note:fnN]`, with one counter for the whole document. The notes are appended under a level-1 heading "Notes".
13. **Jumps.** `[jump:key|w]` becomes `[w](origami-jump:pN)` when the label is bound to a text paragraph. Otherwise only the words remain.
14. **Bibliography** (~1268–1413).
    - Parsed with `BibTeXParser.parse`. Cite keys are matched case-insensitively, then "folded" (lower-case alphanumerics).
    - **If `\bibitem` keys exist** (from the `.bbl` or an inline `thebibliography`): exactly those entries are kept, in that order.
    - **Otherwise:** cited keys only (everything if nothing is cited), sorted to imitate ACM style: first author "Surname, Given" (folded, case-insensitive), then year, then title.
    - `number` is the position + 1.
    - Known gap: a `.bbl` without a `.bib` gives order only, so the reference data is lost.

**Inline conversion** (`inline(convert:noteCounter:)` ~1700). Applied in this order:
1. TeX symbol table (Greek, T2A Cyrillic).
2. `\char`, `\foreignlanguage`.
3. `\(…\)` → `$…$`.
4. Single-line inline maths is shielded from the later steps.
5. `\texorpdfstring{tex}{plain}` → plain.
6. The escape table (`\%`, `\&`, `\_`, `\ldots`, `\\` → newline, …).
7. `\footnote` → a note token.
8. `\cite`, `\citep`, `\citet`, `\parencite`, `\autocite`, `\textcite` → one `[cite:k]` per key.
9. `\href{u}{w}` → `[w](u)`; `\url{u}` → u.
10. `\textbf` → `**`; `\emph`/`\textit` → `*`; `\texttt` → backticks.
11. Accents and ligatures composed to Unicode.
12. Generic unwrap of any remaining `\cmd{x}` → x.
13. Typography: ` `` `→“, `''`→”, `---`→—, `--`→–, `~`→NBSP.
14. Simple maths is rendered as Unicode (`BibTeXParser.readableMath`, e.g. `x²`, `λ_δ`). Anything else is left as `$…$`.

**Known gaps** (from the code and the pipeline doc's §7 backlog):
- Not handled: `\eqref`, `\citeauthor`/`\citeyear`/`\citealp`/`\nocite`, natbib's two-option `\citep[see][p. 3]{k}`, `gather`, `multline`, `description`, and `\input file` without braces. In each case the key text leaks into the prose.
- `\input` is resolved relative to the main file only.
- An `align` gets one equation number for all its rows.
- Heading levels are 1–2 only; level 3 is run-in.
- `\hyperref[k]{w}` keeps the words but makes no link.

**`LATable.swift`** is not a parser. It is the spreadsheet model shared with Author (`LATableCell {value, formula?}`, `LATable`). Its formula engine:
- `LAFormulaParser` (~358) is recursive descent over A1 references (bijective base-26 columns), with `+ - * /`, unary minus, parentheses and `A1:B3` ranges.
- Functions are `SUM, AVERAGE, MIN, MAX, COUNT`.
- Errors are `#SYNTAX! #REF! #CYCLE! #NAME! #DIV/0! #N/A #NUM!`.
- `LATableCalculator` (~191) memoises results and detects cycles.

LaTeX `tabular` never yields formulas; only the Visual-Meta tables block does.

### 3.3 Markdown: `MarkdownImporter` (`MarkdownImporter.swift`)

**Entry points.**
- `importFile(at:companions:)` (~65) and `importText(_:directory:stem:extraBibliography:)` (~95).
- The result is `ImportResult` (~28), with `isPaper` true when there are references or notes. A paper becomes an EPUB; anything else becomes a draft.
- Parsing has two passes: a line scanner that produces blocks, then inline regular expressions.

**Front matter** (`frontMatter` ~614). A YAML subset between `---` and `---`/`...`:
- scalars, `[a, b]` lists, `- item` lists (a mapping item yields its `name:`), and `|` / `>` blocks;
- keys used: `title`, `subtitle`, `author`, `date` (the first 10 characters as ISO), `abstract`, `keywords` (split on `,;`), `bibliography` and `nocite`.

**Blocks.**

| Construct | Result |
|---|---|
| HTML comments | skipped |
| Fenced code (``` / ~~~, 3+; `{.lang}` accepted) | code with a language |
| `$$ … $$` (`{#eq:id}` removed) | display maths |
| Indented code (4 spaces / tab after a blank line, not continuing a list) | code |
| `[^x]:` definitions with indented continuation | notes |
| Reference-link definitions | used by inline links |
| Pipe tables, caption `Table: …` or `: …` | `md-table-N` with a "Table N: …" paragraph above; alignment ignored |
| ATX headings (`{#id}` removed) and setext headings (`=` → 1, `-` → 2) | headings |
| `---` | `---` |
| A line that is only an image | a figure |
| `>` | `> text`, not nested |
| Lists | one paragraph per item, not nested; task boxes removed; an ordered item interrupts a paragraph only if it starts at 1 |

**Title and heading levels.**
- With no front-matter title, a leading level-1 heading becomes the title and is removed from the body.
- Heading levels are then shifted so the minimum is 1, and clamped to 1–3 (~448).

**Bibliography** (`loadBibliography` ~694).
- The front-matter `bibliography` list is used if present.
- Otherwise the first file that yields entries, from `stem.bib, stem.json, stem.ris, references.bib, bibliography.bib, refs.bib, references.ris`.
- `@String` macros are expanded (`FormatSources.expandingStringMacros`).
- Companion entries win over these.

**Inline rules** (~411). Code spans are protected first. Then, in order:
1. autolinks;
2. reference links;
3. Pandoc inline notes `^[…]`;
4. `[^label]`;
5. bracket citations `[see @a, p. 3; @b]` → `[cite:a]`, with locators kept as words;
6. narrative `@key`, only for known keys → "Name / A and B / A et al." + `[cite:key]`;
7. `_em_` / `__strong__` → asterisk forms.

The key pattern is `-?@(\{[^}]+\}|[A-Za-z0-9_][A-Za-z0-9_:.#$%&+?<>~/-]*)`.

**Figures, notes and references.**
- Remote images are never fetched; they become links.
- Local images are read relative to the file, and PDFs are rasterised as in LaTeX.
- Notes are numbered `fnN` in order of first reference and appended under "Notes".
- References are listed in first-citation order, plus `nocite` keys (`@*` means all).
- `notices` report unknown keys, missing bibliographies and unreadable companions.

**Gaps.** No cross-references or labels; no nested lists or quotes; table alignment ignored.

### 3.4 Typst, AsciiDoc, reStructuredText: `MarkupBridges.swift`

`MarkupImport.importFile` (~20) routes `.typ`, `.adoc`/`.asciidoc` and `.rst` to a **bridge that writes Markdown**. The bridge returns `Bridged {markdown, bibliography: [BibTeXEntry]}`, and the result goes through `MarkdownImporter.importText`. LaTeX is never an intermediate.

Shared helpers:
- `BridgeFrontMatter.yaml` (~48) writes the YAML front matter.
- `BridgeStash` (~89) protects spans with private-use placeholders `U+E100 n U+E101`.
- `BridgeText.closing` / `arguments` / `namedArguments` parse bracketed calls, aware of strings and nesting.
- `BridgeText.pipeTable` (~220).

**Typst** (`TypstBridge` ~246).
- Comments are stripped and `<labels>` collected.
- `#` lines are joined until their brackets balance, then handled by `block()` (~336):
  - `#set document(...)` and `#show: x.with(...)` give front matter: `title, subtitle, abstract, author(s)` (string, tuple, or `(name:…)`), `keywords`/`index-terms`, `date` (`datetime(year:…)`) and `bibliography`.
  - `#bibliography("a.bib")` accepts `.bib/.json/.ris`; Hayagriva `.yml` is ignored (a gap).
  - `#figure(image(…), caption:)` becomes a figure; `#figure(table(…))` and `#table(columns: n, …)` become tables (cells grouped n per row, `table.header` included).
  - `#quote(attribution:)` becomes a quote.
  - `import`, `include`, `let`, `pagebreak`, `outline`, `counter`, `state`, `context`, `place` and `metadata` are dropped.
- Headings `=`… become `#`…. `/ T: d` becomes `- **T**: d`. `+ ` becomes `1. `.
- Inline (~523), in order:
  1. raw text is stashed;
  2. maths;
  3. `#footnote[]` → `^[]`; `#link`; `#cite(<k>, supplement:)` → `[@k, supp]`; `#strong`/`#emph`;
  4. `@key[supp]` becomes words if `key` is a label, otherwise a citation;
  5. `*x*` → `**x**`, `_x_` → `*x*`.
- Maths (~612): `$ x $` (with spaces just inside the dollars) is display maths; otherwise inline. `TypstMath.tex(from:)` (~649) is a recursive-descent translator to TeX: a symbol table, `a/b` → `\frac`, `frac, binom, root, abs, norm, floor, ceil, lr, op, vec, mat, cases`, braces, accents, and `&` → `aligned`. An unknown name returns nil, and the Typst source is kept as code.

**AsciiDoc** (`AsciiDocBridge` ~959).
- **Header:** `= Title`, then an author line (`;`-separated, `<email>` removed), then the revision date, then `:attr:` values substituted as `{attr}`.
- **Delimited blocks:**
  - `----`/`....` → code (`[source,lang]`);
  - `____` → quote with attribution;
  - `++++` with `latexmath`/`stem` → `$$`;
  - example, sidebar and admonition blocks → converted recursively with a bold lead.
- **Tables (`|===`):** the column count comes from `cols`, else the first row. The header comes from the `header` option or a blank line after the first row; otherwise an empty header row is added. Spans and `a|` cells are not parsed.
- **Images and skips:** `image::p[alt]` with `.Title` becomes a figure. `include::`, `toc::` and `bibliography::` are skipped.
- **Inline:** `stem:[…]`, `footnote:[…]`, `cite:[k1,k2(p)]` (asciidoctor-bibtex), `<<id,text>>`, URL macros, `kbd`/`btn`/`pass`, and constrained `*b*` / `_i_` / `#mark#`.
- **Front matter:** `:bibtex-file:`, `:description:` (the abstract), `:keywords:`, `:author:`, `:revdate:`.

**reStructuredText** (`RSTBridge` ~1237).
- **Definitions first** (`collectDefinitions` ~1276): targets, `|s| replace::`, footnotes (`#`, `*`, numeric, `#name`) and citations (any other label). Citations become `@misc{key, title = {whole text}}`.
- **Sections:** the adornment regex is ``^([=\-`:'"~^_*+#<>.])\1{2,}\s*$``. Level follows the order in which each style first appears. A first style used only once is the title.
- **Docinfo:** `:author(s):`, `:date:`, `:abstract:`, `:keywords:`; any other field becomes `**Field:** value`.
- **Directives** (~1576):
  - `code-block`, `math`, `image`, `figure` (first paragraph is the caption), admonitions, `topic`/`sidebar`/`rubric`, `epigraph`/`pull-quote`;
  - `bibliography` (sphinxcontrib-bibtex);
  - `list-table`, `csv-table`, and grid/simple tables (no spans);
  - `toctree`, `include`, `raw`, `autodoc*`, … are dropped; unknown directives are converted recursively.
- **Inline:**
  - code spans and `:math:` → TeX;
  - `:cite:`/`:footcite:` → citations;
  - `:ref:`/`:numref:` → display text only (no numbering);
  - hyperlinks, footnote references, `[KEY]_` → a citation, `|subst|`;
  - the default role `` `x` `` → `*x*`.

### 3.5 Word: `WordImporter` and `ACMWordPaper` (`WordImporter.swift`, ~2.3k lines)

There are two paths. `ACMWordPaper.isPaper(at:)` (~580) chooses between them: it unzips `word/document.xml` and checks for the ACM template's title style `w:val="Titledocument"`. Only `.docx` qualifies.

**(a) General path: `WordImporter.importFile`** (~30–237). It produces a draft.
- **Base text.** The platform's rich-text reader (AppKit `NSAttributedString(url:)`, which handles `.docx`, `.doc`, `.rtf`, `.odt`).
- **Body size.** The point size with the most characters (~44–51).
- **Headings** (`headingLevel` ~388):
  - the paragraph style's header level, capped at 3;
  - otherwise, by size for paragraphs of 120 characters or fewer: at least +8 pt → 1, at least +4 pt → 2, at least +2 pt → 3.
- **Emphasis** (`markdownText` ~406). Runs are **coalesced by (bold, italic, link)** first, so emphasis split across runs survives. Then `*` / `**` / `***` are applied, with whitespace kept outside the markers.
- **Links.** A link to an Origami address becomes `text [address]`; any other link becomes `[text](url)`.
- **Lists:** `- item`.
- **Tables.** Platform table blocks become `word-table-N` (no captions or spans on this path).
- **Images.** Inline images are recovered from the OOXML (`WordImageRecovery.insertImages` ~1579): `r:embed` ids in each `<w:p>` are mapped through `word/_rels/document.xml.rels` to `media/`. Floating images are not handled. Assets are named `imgN`, with the type sniffed from magic bytes.
- **Footnotes** (`placingFootnotes` ~248). `word/footnotes.xml` is read by regex. `DocxScanner` finds where each `w:footnoteReference` sits, and the importer inserts `[note:fnN]` at the same character offset, matched by normalised paragraph text. The notes go under "Notes".
- **HYPERLINK fields** (`WordFieldLinks` ~1687). Both `fldChar` and `fldSimple` fields are read; only Origami addresses are re-injected.
- **Reference-manager fields** (`WordCitationFields` ~1749–2186). A field state machine (`FieldScanner` ~2108) handles nesting and split `instrText` across document, footnote and endnote XML.
  - `ADDIN … CSL_CITATION` (Zotero/Mendeley): the first balanced JSON object is read, and `citationItems[].itemData` is taken as CSL-JSON.
  - `ZOTERO_BIBL`/`CSL_BIBLIOGRAPHY`: the bibliography lines are removed from the body.
  - EndNote `EN.CITE` and Citavi: a "not yet supported" notice.
  - Keys are `FamilyYearFirstword`, ASCII-folded, with a/b/c added on collision.
  - CSL→BibTeX (`CSLItem.bibtex` ~2046) writes raw, unescaped values.
  - The visible "(Author, Year)" is replaced in document order by `prefix [cite:key] (p. loc) suffix`.
  - `looksFlattened` (~1800) warns when there are at least 3 author-year parentheses, or a "References" line, but no fields.
- **Metadata.** The title is the document Title property, else a leading H1 (removed from the body), else the filename. The author comes from the document properties.

**(b) ACM paper path: `ACMWordPaper.importPaper(at:tapsHTML:)`** (~631–970). It produces an EPUB.
- **Reading.** It never uses the platform reader. It has its own ZIP reader (`DocxZip` ~2191, stored/deflate) and `DocxScanner` (~1168–1353), a SAX pass over `word/document.xml`. The scanner records:
  - `w:pStyle` and run traits (`w:b`/`w:i`/`…Cs`, honouring `val`);
  - `w:hyperlink@w:anchor`, `w:footnoteReference`, `o:OLEObject` and `a:blip r:embed`;
  - top-level tables, with `w:gridSpan` → `columnSpan`.
- **Style mapping** (~754–851):

| Word style | Model |
|---|---|
| `Titledocument` | `title` |
| `Authors` | `authors` |
| `Affiliation` | `affiliations` / `authorAffiliations`; a trailing email goes to `authorEmails` |
| `Abstract` | H1 "Abstract" + paragraph |
| `CCSDescription` | `**CCS Concepts:** • Root → Leaf; …`. Source order: TAPS HTML, then `docProps/core.xml` `dc:description` CCSXML (`ccsFromProperties` ~594), then the printed line (`ccsFromPrintedLine` ~618). |
| `KeyWords` | `**Keywords:** …` |
| `Head1`/`Head2` | H1 "N Title" / H2 "N.M Title", numbered by the importer |
| `Image` + `FigureCaption` | one `![alt](asset:)` per image, with the caption on the last; registers `fig{N}` as a jump target |
| `TableCaption` | caption paragraph registering `tb{N}`; the *next* table becomes a `LiquidDoc.Table`; a table holding images is a multi-image figure layout |
| `Bibentry` | reference lines |

- **Inline** (`flowedText` ~667):
  - equal-trait runs are coalesced (the "split italics" fix);
  - a `bib*` anchor → `[cite:bibN]`;
  - `fig*` / `tb*` anchors → `origami-jump` links, resolved later or reduced to words;
  - template brackets around citations are absorbed (`absorbingCitationBrackets` ~975).
- **Equations.** Only OLE objects. Each is replaced by the Nth `<span class="tex">$…$</span>` from the TAPS HTML, else `⟨equationN⟩`. **OMML (`m:oMath`) is not read**, because the scanner collects only `w:t`. WMF/EMF previews are dropped.
- **`TAPSHTML`** (~1363–1568) is a regex scrape of ACM's HTML rendering. It yields:
  - the ACM Reference Format block, DOI and venue;
  - the printed author names (used if the count matches);
  - the licence block, ORCIDs, the CCS line and equation TeX;
  - references from `<li id="bibN">` (venue from `<em>`, DOI/URL from hrefs).
- **References** (~1067). TAPS entries are preferred, else `Bibentry` lines. Each becomes `Reference(id:"bibN", number:N)`, with BibTeX parsed from the printed line: authors up to the year, then the title sentence, then the venue. The type is `inproceedings` if the venue matches Proceedings/Conference, `article` otherwise, and `misc` if there is no venue.
- **Notices.** The importer reports: no TAPS HTML; notes outside the body; equations without TeX; reference counts that disagree.

### 3.6 JATS / BITS XML: `BITSImporter` (`BITSImporter.swift`)

- **Detection.** The root must be `book-part-wrapper` (BITS) or `article` (JATS); otherwise `notBITS`.
- **Parsing.** A small DOM over a SAX parser, with external entities disabled and CDATA kept as text.
- **Metadata** (~76–167). Read from `book-part/book-part-meta` or `front/article-meta`:
  - the title;
  - authors from `contrib[contrib-type=author]`, using `given-names`/`surname` or `string-name`;
  - affiliations, inline `aff` or pooled `aff[@id]` via `xref[ref-type=aff]@rid`, joined as institution/addr-line/city/state/country;
  - `email`, and ORCID from `contrib-id`;
  - the DOI, from `article-id`/`book-part-id` with `pub-id-type=doi`;
  - the date, from `pub-date` (epub/ppub/pub);
  - keywords, from `kwd-group` except type `ccs`;
  - the publication: the book or journal title.
- **Body walk** (`walk` ~304):
  - `sec` becomes a heading at its nesting depth (clamped 1–3), with id `x-<id>`.
  - `p` is emitted with any nested `fig`/`table-wrap`/`disp-formula` lifted out after it.
  - `fig` becomes an asset from the file beside the XML (jpg/jpeg/png/gif/tiff probed when there is no extension), or `![caption](href)` if the file is missing.
  - `table-wrap` becomes `xml-table-N` from `tr > td|th` (no spans), with the caption after it.
  - `disp-formula/tex-math` becomes `$$…$$`, with `\(…\)`, `\[…\]` and `equation` removed. MathML is not read.
  - `list` becomes `1. ` / `• ` paragraphs.
- **Inline** (~464):
  - `bold`/`italic`/`monospace` → `**`, `*`, backticks;
  - `xref ref-type=bibr` → `[cite:rid]`; `fn` → `[note:x-rid]`; other xref types → `origami-jump`;
  - `ext-link` → a link; `inline-formula` → `$…$`.
- **Notes and abstract.** The abstract comes first under H1 "Abstract". Every `fn` goes under "Notes".
- **References.** `ref-list/ref` → `mixed-citation` or `element-citation` → BibTeX (`bibtex(from:)` ~585).
  - Type: journal → `article`, confproc → `inproceedings`, book → `book`, else `misc`.
  - `{}` in values are replaced with `()`; nothing else is escaped.
- **Gaps.** No MathML; no table spans; graphics only next to the XML; `applyingJATSFrontMatter` (~778) sets authors only when there is more than one.

### 3.7 PDF: `PDFImporter` and `PDFStructure`

- **Text.** `PDFImporter.importFile` (~32) joins each page's text layer, using the platform PDF library (PDFKit). Fewer than 20 characters throws `noTextLayer`. There is no OCR.
- **Visual-Meta.** The text is searched backwards for `@{visual-meta-end}` and the start marker. Inside, the `@{visual-meta-bibtex-self-citation-start/end}` BibTeX gives the title, author and date. The appendix is then cut from the body.
- **Flat paragraphs** (`paragraphs(from:)` ~101). A blank line breaks a paragraph. So does a sentence-ending line shorter than 0.75 × the median line length.
- **`PDFStructure.read`** (~62) replaces the flat result when it finds at least one heading and keeps at least half as many paragraphs.
  - **Paper test** (`looksLikeAPaper` ~177): more than 40 lines, plus one of these marks: "abstract" in the first 400 lines; references/bibliography; at least 2 numbered sections; keywords / CCS / index terms / introduction.
  - **Running heads** (`withoutRunningHeads` ~332, at least 3 pages): repeated first-line prefixes are stripped, and digit-only lines are dropped.
  - **Headings** (`headingLevel` ~410):
    1. Numbered `^\d+(\.\d+)*\.?\s+[A-Z]`, with section number 1–30, under 80 characters unless at depth 3 or more. Depth = dots + 1, at most 3.
    2. No heading if it ends with `.` or contains `@`, `http`, `isbn` or `://`.
    3. Known section words (~462) → level 1.
    4. Short ALL-CAPS lines → level 1.
    - Font size **does not** vote (~450).
  - **Line handling.** All-caps continuation lines join the heading above. A line ending in `-` followed by a lower-case start is de-hyphenated. A paragraph ends at a sentence end on a line narrower than 0.92 × the 75th-percentile width.
- **Not done.** No column detection (the PDF library's reading order is trusted). No references, figures, tables or maths. `headingCandidates` are collected for a future model pass but not used.

### 3.8 Author documents: `AuthorImporter` (`AuthorImporter.swift`)

- **Input.** A `.liquid` package (directory). Its layout is "not publicly documented", so it is sniffed.
- **iCloud.** `.icloud` placeholders trigger a download request and then `notDownloadedFromICloud`.
- **Metadata** (`scanMetadata` ~509). Every JSON or plist member under 5 MB is searched for title/author keys, exact matches first. Numeric values are rejected.
- **Text**, in priority order:
  1. RTFD, or, if it exists, `Contents/Content.liquidstore`.
     - The store is a keyed archive decoded with an allow-list of classes. Author's attachment classes are swapped for an inert placeholder (`AttachmentSubstitution`).
     - Citation runs carry `LACitationIdentifierAttributeName` / `LACitationFormatAttributeName`. `markingCitations` (~368) replaces "(Author Year)" with `[cite:id]` and keeps the label as `citedAs`.
     - Pictures are not carried on this path.
  2. Any member that sniffs as RTF (`{\rtf`), flat RTFD, or a `bplist00` archived attributed string; or `.html` / `.txt` / `.md` files.
  3. JSON text fields (`text`/`string`/`content`/`body`/`characters`).
- **Headings** (`paragraphs(from:)` ~235). The most common size is the body; the three largest sizes above it become H1–H3. A literal `#` prefix also counts.
- **Knowledge layer** (`knowledgeLayer` ~562):
  - `Contents/glossary.json` `entries` → `Concept {id, name, description, tag, citationIdentifiers, urls}`. A "section" tag means a heading anchor whose depth is the dot count of "1.1.1." (`applyingSectionLevels` ~683).
  - `Contents/DynamicView.json`:
    - `layout.nodePositions` → layout "Current Layout";
    - `customLayouts[]` → further layouts (`sourceID`);
    - `connections[]` (`startNodeIdentifier`/`endingNodeIdentifier`) → `MapConnection`.
  - `Contents/Citations.plist` → `Reference`.
    - A raw `BibTeX`/`bibtex` value is used verbatim.
    - Otherwise BibTeX is built from `citationAuthors`, `yearComponent`, journal, publisher, doi, isbn, issn, volume, issue→number, editor, series, location→address, pageRange→pages (except "0"), webAddress→url, `vm-id` and `bibTeXType` (default `misc`).
    - When citedness is known, references are filtered to those cited or used by concepts and layouts.

### 3.9 Author XR export: `AuthorMapExporter` (`AuthorMapExport.swift`)

"Export to XR" (`AuthorMapExporter.export(nodes:connections:from:to:)` ~51; UI `ExportToXRSheet` ~201; driver `AppModel.exportToXR` ~6909). It **copies a user-chosen real `.liquid`** to a new path and merges into the copy. It never writes a package from scratch, and it requires `glossary.json` and `DynamicView.json`.

- **`glossary.json`** gets new `entries[uuid] = {identifier, phrase, description, isLiked:false, isContext:false, citationIdentifiers, urls:[{url}], documentPath:"", date: <seconds since 2001-01-01>, tag?}`. An entry whose phrase matches case-insensitively is reused. The file is written pretty-printed with sorted keys.
- **`Citations.plist`** (XML plist, merged) gets, per document node: `{identifier, title, authors, yearComponent, bibTeXType:"misc", vm-id, webAddress: <web carrier prefix + id>, bibtex}`.
- **`DynamicView.json`** gets the new `connections`, plus a new custom layout "Origami Web". It holds the last layout's positions, plus new nodes on a ring of radius 1300 (z = 0 for documents, 0.4 for people).
- **Nodes** are documents (`origamitext://open/<id>`) and people (tag "person"). **Edges** are document links, author→document and speaker→document.

### 3.10 Transcripts: `TranscriptImporter`, `TranscriptSummary`, `TranscriptsView`

- **Formats.** Plain text (UTF-8) and RTF/RTFD (converted to a string first). **VTT and SRT are not supported.**
- **Speaker line** (`speakerLinePattern` ~49). An optional `[hh:mm:ss]`, then a name of 1–4 words (at most 40 characters), then an optional `(hh:mm:ss)`, then `:` and the statement. A statement starting with `//` is rejected (it is a URL). Timestamps are discarded.
- **Sniff** (`looksLikeTranscript` ~75). At least 4 non-empty lines, at least 60% of them speaker lines, and at least 2 speakers who each appear at least twice.
- **Parse** (`importText` ~92).
  - A line with no speaker continues the previous statement.
  - The date comes from a leading date-only line, else from the filename. Accepted forms: "6 July 26", "6 July 2026", "July 6, 2026", "d MMM yy", "yyyy-MM-dd". A two-digit year of 49 or less means 20xx.
  - Each statement becomes `Paragraph(text:"Name: statement", speaker:"Name")`, and the document gets `documentType = transcript`.
- **Summary** (`TranscriptSummarizer.summarize` ~203).
  1. Statements are formatted `[pN] text` and chunked greedily at 9000 characters.
  2. Each chunk is one fresh request with fixed instructions through `OrigamiLLM.generate(TranscriptGeneratedNotes.self, …, transformingContent: true)`, asking for 2–5 notes `{text, sources[]}`. On Apple's model that is guided generation with the permissive content-transformation guardrails; on a chosen server it is the type's JSON Schema.
  3. On context overflow the chunk is halved recursively. A refusal is retried once, then that part is skipped.
  4. Grounding (`validated` ~375): source ids are normalised and must exist, a note with no valid source is dropped, and each note keeps at most 4 sources.
  5. Notes are sorted by earliest source and de-duplicated. `condense` (~404) writes a 2–3 sentence overview through `OrigamiLLM.respond`. If the overview fails, the notes still stand and the reason goes to `TranscriptSummary.overviewError`, which the document view shows (it is not saved).

  `makeDocument` (~35) produces a new `LiquidDoc`: title "Summary — …", `documentType = letter`, `aiOnBehalf = true`, a `summarizes` link to the transcript, and notes citing `[transcriptID#pN]`.

  `TranscriptSummarizer.isAvailable` is `OrigamiLLM.shared.canRespond`: a chosen server, or Apple's model.
- **`TranscriptsView.swift`** is UI only: transcripts list, extracts list and letters list.

### 3.11 Tabular data: `TabularDataImporter` (`TabularDataImporter.swift`)

This feeds Time Flows charts, not the library.
- **Delimiter.** The most frequent of `,` `;` and tab in the first line, else whitespace. The quote-aware split toggles on `"`, with no `""` escape. There is no xlsx support.
- **Header.** The first row is a header if any cell is neither a number nor a date.
- **Column detection.**
  - A date column needs at least 80% of rows to parse as dates.
  - A value column needs at least 60% numeric values.
  - Day/month order is inferred from values above 12.
- **Ambiguity** returns a `Question` (`dateColumn`, `dateOrder`, `valueColumns`), answered with `Choices`.
- **Dates.** `yyyy-MM(-dd)`, `dd/MM/yyyy` or `MM/dd/yyyy`, dotted forms, and bare years 1000–2500, all in UTC.
- **Numbers.** A decimal comma is accepted.
- **No date column.** The result is a "timeless" series using the row index as the day.
- **Output.** `FetchedSeries`, downsampled.

### 3.12 Bibliographic formats: `BibTeX.swift`, `ReferenceFormats.swift`, `FormatSources.swift`

**BibTeX parser** (`BibTeXParser.parse` ~72).
- A character scanner: `@type{`, then brace counting to the matching close, then the key up to the first comma. Values may be `{…}` (nested), `"…"` or bare.
- Any `@type` is accepted. An entry needs a title or an author.
- Field names are lower-cased. `raw` keeps the verbatim entry.
- `@string`, `@preamble`, `@comment` and `#` concatenation are **not** handled here. `FormatSources.expandingStringMacros` (~386) does that beforehand for `.bib` imports.

**Helpers.**
- `authorNames(inRaw:field:)` (~195) splits on top-level ` and `, and marks fully braced names as literal (corporate).
- `displayText` (~423) turns TeX into Unicode: accents, ligatures, `\i`/`\j`, unwrapping, typography.
- `readableMath` (~698) renders simple maths as Unicode sub/superscripts and returns nil if any command remains.

**BibTeX writer** (`BibTeXWriter.write` ~285).
- Field order: `title, author, year, journal, booktitle, container-title, publisher, volume, number, pages, doi, url`, then the rest alphabetically. Empty fields are dropped.
- It escapes `\` (as `\textbackslash{}`), then `& % # $ _`. **It does not escape `{ } ~ ^`.**

**Crossref.** `CrossrefVerifier` (~323) queries by DOI or `query.bibliographic`. It is on by default (`verifyReferencesCrossref`).

**RIS** (`records(fromRIS:)` ~68).
- Lines match `^([A-Z][A-Z0-9])  -\s?(.*)$`. Continuation lines are joined, and `ER` or a new `TY` ends the record.
- Types: JOUR/JFULL/MGZN/NEWS/EJOUR → `article`; CONF/CPAPER → `inproceedings`; BOOK/EBOOK/EDBOOK → `book`; CHAP/ECHAP → `incollection`; THES → `phdthesis`; RPRT → `techreport`; else `misc`.
- Fields:
  - AU/A1 → author; ED/A2 → editor (books and chapters only)
  - TI/T1/CT → title
  - T2/JO/JF/JA/BT/J2 → journal or booktitle
  - PY/Y1/DA → year
  - VL → volume; IS/CP → number; SP–EP → pages
  - PB → publisher; CY/PP → address
  - DO → doi (made bare); UR/L2 → url; SN → isbn
  - AB/N2 → abstract; KW → keywords (comma-joined)
  - ID → key

**EndNote tagged** (~149). `%X value` lines; a blank line or `%0` starts a new record. `%0` gives the type, then %A, %E, %T, %J/%B, %D, %V, %N, %P (`-` → `--`), %I, %C, %R (doi), %U, %@, %X, %K, %F (key).

**EndNote XML** (~219). Text is gathered through `<style>` runs from `ref-type@name`, `contributors/authors/author`, `secondary-authors`, `titles/*`, `periodical/full-title`, `dates/year`, volume, number, pages, publisher, `pub-location`, `electronic-resource-num`, `urls/related-urls/url`, isbn, abstract, keywords and label.

**Keys** (`uniqueKey` ~316). The stated key is sanitised. Otherwise the key is slug(family) + year + slug(first title word longer than 3 characters), for example `nelson1965complex`, with a/b/c added on collision. All three formats then go through `BibTeXWriter`. There are **no RIS, EndNote or CSL writers.**

**CSL-JSON → BibTeX** (`FormatSources.bibtex(fromCSL:key:)` ~505).
- Types: `article-*` → `article`; `paper-conference` → `inproceedings`; `chapter` → `incollection`; `report` → `techreport`; `thesis` → `phdthesis`; else `misc`.
- Accepts an array or `{items:[…]}`.

**Reference-list documents.** A `.bib` / CSL / RIS / EndNote file becomes a `LiquidDoc` with a one-paragraph body and `documentType = "bibliography"` (`ACMLaTeX.referenceListType`). The writers then emit `\nocite{*}`, so every entry prints.

**`FormatSources`** is not a catalogue of sources. It is the **router** for Import to Format.
- `extensions` (~17): `epub, docx, doc, odt, rtf, rtfd, tex, zip, gz, tgz, tar, md, markdown, txt, html, htm, xhtml, xml, pdf, liquid, bib, json, ris, enw, typ, adoc, asciidoc, rst`.
- `load` returns `Loaded {doc, notices}` and never files anything into the library.
- `applyScholarMeta` (~283) reads HTML `citation_*` / `DC.*` / `og:title` meta tags, turning "Family, Given" into "Given Family".
- `loadTarball` (~232–275) runs `tar -xf` into a temporary folder `origami-source-<UUID>`. If that fails it runs `gunzip -c` into `main.tex`. The folder is removed afterwards.

---

## 4. The EPUB writer: `OrigamiEPUBExporter` (`OrigamiEPUB.swift`, ~3.1k lines)

The writer is one file. `LiquidDocWriting.swift` writes the `.origamitext` JSON and LaTeX, not EPUB. `VisualMeta.swift` builds the older BibTeX-style appendix for non-EPUB exports; the EPUB writer does not use it. MathML comes from `TeXMathML.mathElement` (`OrigamiMath.swift` ~471).

### 4.1 Entry points and context

- `write(doc:resolve:to:)` (~669) sets the publication language and calls `writePackage` (~689).
- `write(doc:resolve:to:houseStyle:colophon:)` (~655) sets two context values (Swift `@TaskLocal`): `HouseStyle.current` (`.acm/.ieee/.lncs/.elsevier/.preprint`; this sets the reference-list style and, for ACM, the fonts) and `writesColophon` (default true).
- A third value, `writesTitleOnly`, gives a header with only the title (used for the bundled introduction).
- `resolve: (String) -> LiquidDoc?` looks up internal citations. Most callers pass `{ _ in nil }`.

**Publication language** (`publicationLanguage` ~680). `doc.language` is normalised. Otherwise the language is detected from the title, the abstract and up to 40 body paragraphs, falling back to `und`. **English is never assumed.** The tag goes into the OPF `xml:lang`, `dc:language` and the root `lang`/`xml:lang`, and sets the language of the writer's own headings (`LanguageTag.heading("references" | "abstract" | "keywords" | "contents", in:)`).

### 4.2 Package tree

```
mimetype                         "application/epub+zip", stored, first
META-INF/container.xml           rootfile full-path="package.opf"
package.opf                      at the archive root (not OEBPS/)
content/paper.html               the single XHTML content document (.html extension)
content/nav.html                 navigation document
content/style.css                base CSS (+ @font-face + family CSS when fonts ride) + house-style CSS last
content/fonts/LibertinusSans-Bold.woff2      \
content/fonts/LibertinusSerif-Regular.woff2   | ACM house style only, and only when
content/fonts/LibertinusSerif-Italic.woff2    | the app bundle carries them
content/fonts/LibertinusSerif-Bold.woff2     /
content/images/<asset.filename>  only assets the body actually references, de-duplicated
content/images/cc-by.png         when doc.license contains "Creative Commons"
visual-meta.json                 semantic record      — beside the OPF, NOT in META-INF, NOT in manifest
origami.json                     interaction record   — likewise
references.bib                   bibliography record  — only when there are citations
```

This differs from the profile's informative layout in §4.8 (`OEBPS/content.opf`, `content.xhtml`, `backmatter.xhtml`). §4.8 says a writer MAY use any paths, so this is conforming.

**ZIP** (`struct ZipWriter` ~3014). Hand-written, with no library.
- Every entry is **stored** (method 0), `mimetype` included and first.
- DOS time is 0 and DOS date is 0x21 (1980-01-01).
- No extra fields, no ZIP64, and a table-driven CRC-32 per entry.
- The file is written atomically.

`pack(unpackedFolder:)` (~2985) re-zips a folder with `mimetype` first and every other file sorted by relative path.

### 4.3 Identity

- **Edition:** `dc:identifier` = `urn:uuid:` + `stableUUID(doc.id)`.
- **Work:** `dcterms:isVersionOf` = `urn:uuid:` + `stableUUID(doc.id + ":work")`.
- **`stableUUID`** (~1298) takes SHA-256 of `"origami-text:" + seed` and keeps the first 16 bytes. It sets version nibble 5 and the RFC 4122 variant bits, and formats them as **uppercase** hex. Any implementation must reproduce this exactly so re-exports keep their identity.
- **Release:** `dcterms:modified` = now, as ISO 8601 internet date-time.
- **Date:** `dc:date` = the document's date, else the first 10 characters of its creation time.
- The library address (`doc.id`) travels as `document.origami-id`.

### 4.4 OPF (`packageOPF` ~2844, `packageFrontMatterXML` ~2805, `accessibilityMetadataXML` ~2756)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id"
         xml:lang="en" prefix="origami: https://github.com/frodehegland/OrigamiText/blob/main/profile/vocab.md# cc: http://creativecommons.org/ns#">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="pub-id">urn:uuid:3F2A…</dc:identifier>
    <dc:title>Paper title</dc:title>
    <dc:creator>Ada Lovelace</dc:creator>              <!-- one per doc.authors, in order -->
    <dc:creator>Charles Babbage</dc:creator>
    <meta property="dcterms:isPartOf">Proceedings of …</meta>   <!-- each distinct publication/journal -->
    <dc:identifier>10.1145/3720553.3746000</dc:identifier>      <!-- bare DOI, no id/scheme -->
    <dc:subject>hypertext</dc:subject>                          <!-- one per keyword -->
    <dc:rights>This work is licensed under … (newlines → spaces)</dc:rights>
    <meta property="dcterms:license">https://creativecommons.org/licenses/by/4.0/</meta>
    <meta property="cc:attributionName">Ada Lovelace and Charles Babbage</meta>
    <meta property="cc:attributionURL">https://doi.org/10.1145/…</meta>
    <dc:language>en</dc:language>
    <dc:date>2026-09-14</dc:date>
    <meta property="dcterms:modified">2026-10-06T09:30:57Z</meta>
    <meta property="dcterms:conformsTo">https://github.com/frodehegland/OrigamiText/tree/main/profile/1.0</meta>
    <meta property="dcterms:isVersionOf">urn:uuid:9C1D…</meta>
    <meta property="schema:accessMode">textual</meta>
    <meta property="schema:accessMode">visual</meta>                 <!-- when images -->
    <meta property="schema:accessModeSufficient">textual</meta>
    <meta property="schema:accessibilityFeature">tableOfContents</meta>
    <meta property="schema:accessibilityFeature">readingOrder</meta>
    <meta property="schema:accessibilityFeature">structuralNavigation</meta>
    <meta property="schema:accessibilityFeature">MathML</meta>       <!-- when <math> present -->
    <meta property="schema:accessibilityHazard">none</meta>
    <meta property="schema:accessibilitySummary">Reflowable text with …</meta>
    <link rel="record" href="visual-meta.json" media-type="application/json" properties="origami:visual-meta"/>
    <link rel="record" href="origami.json" media-type="application/json" properties="origami:interaction"/>
    <link rel="record" href="references.bib" media-type="application/x-bibtex" properties="origami:bibliography"/>
  </metadata>
  <manifest>
    <item id="paper" href="content/paper.html" media-type="application/xhtml+xml" properties="mathml"/>
    <item id="nav" href="content/nav.html" media-type="application/xhtml+xml" properties="nav"/>
    <item id="css" href="content/style.css" media-type="text/css"/>
    <item id="img1" href="content/images/fig1.png" media-type="image/png"/>
    <item id="ccby" href="content/images/cc-by.png" media-type="image/png"/>
    <item id="font1" href="content/fonts/LibertinusSans-Bold.woff2" media-type="font/woff2"/>
  </manifest>
  <spine><itemref idref="paper"/></spine>
</package>
```

Emission rules:
- **`cc:` prefix:** declared only when an attribution name exists.
- **`dcterms:license`:** emitted only if the value contains `://` or starts with `urn:`. Otherwise the problem is logged and the element is left out.
- **`cc:attributionName`:** emitted only when the licence URI contains `creativecommons.org`. The authors are joined ACM-style ("A, B, and C").
- **`properties="mathml"`:** set only when the content contains MathML.
- **`dc:creator`:** has no `refines`, `role` or `file-as`.
- **Not written:** `rendition:*`, a cover, `dc:publisher`, `dc:description` (the abstract is not in the OPF), and `belongs-to-collection`.
- **Accessibility features:**
  - `ARIA` and `alternativeText` (when every image has alt text) are added as the facts allow.
  - `accessModeSufficient` "textual,visual" is added when there are images.
  - The summary is chosen from the facts.

### 4.5 Multilingual values (profile §5.5)

In `visual-meta.json`, `document.title`, `subtitle`, `abstract`, `publication`, `journal` and each `authors[].name` are **always** objects (`DocumentInfo.Value` ~168):

```json
"title": {
  "value": "数字文本与知识组织",
  "lang": "zh-Hans",
  "alternate": [
    { "value": "Shuzi Wenben yu Zhishi Zuzhi", "lang": "zh-Latn", "relation": "transliteration" },
    { "value": "Digital Text and Knowledge Organization", "lang": "en", "relation": "translation" }
  ]
}
```

- `lang` is always present. It falls back to the publication language, which may be `und`.
- `alternate` is omitted when empty.
- `relation` is an open vocabulary (`transliteration`, `translation`, `display`).
- `keywords` and `ccsConcepts` are plain string arrays.
- `citations[]` entries carry only `lang` and `alternate` for the cited work's title (`Forms` ~187). The title itself stays in BibTeX. The language comes from `reference.forms`, else from BibTeX `langid`/`language`.

**In the OPF:** only the primary value is written. There is no per-element `xml:lang` and no alternate-script `refines`.

**In the XHTML** (`languageAttributes` ~1837): `lang`/`xml:lang` are written only where a value's language differs from the publication's, and always on alternates.
- `<p class="title-alternate" lang xml:lang data-origami-relation>` (and `subtitle-alternate`).
- `<span class="name-alternate" …>`.
- Translated abstracts become separate `<section class="abstract abstract-alternate" lang …>` blocks with a localised `<h2>`.
- Reference titles become `<span lang>title</span> [<span lang>translation</span>]` (`titleMarkup` ~1857).

### 4.6 Navigation document (`navHTML` ~2688)

```xml
<nav epub:type="toc" role="doc-toc">
  <h1>Contents</h1>                       <!-- localised -->
  <ol>
    <li><a href="paper.html#H-…">Introduction</a></li>
    …
    <li><a href="paper.html#references">References</a></li>
    <li><a href="paper.html#origami-publication-info">Visual-Meta Colophon</a></li>
  </ol>
</nav>
```

- The list is **flat** (not nested by level), and `*` is stripped from heading text.
- With no headings, the nav has a single entry: the title, linking to `paper.html`.
- **References:** appended when `doc.references` is non-empty.
- **Colophon:** appended when `writesColophon` is on.
- There are no landmarks and no page-list.

### 4.7 Content document conventions (`paperHTML` ~1448, `element(for:)` ~1959, `inlineHTML` ~2127)

**Skeleton.**
- `<?xml?>`, then `<!DOCTYPE html>`, then `<html xmlns xmlns:epub xml:lang lang>`.
- `<head>` holds `charset`, `title` and `style.css`.
- `<body>` holds `<header>`, then `<main>` with one **flat** `<section>` per heading of level 1–3.
- After `</main>` come the references section, the colophon and the hidden Visual-Meta section.

**Addressing and ids** (`addressedBody` ~547). Only heading levels 1–3 count.
- Each heading opens section N, with address `N` (the heading itself is implicitly `NA`). The following elements get `NB`, `NC`, …, continuing bijectively (`Z`, `AA`, …).
- Content before the first heading belongs to section 1.
- Every element gets `id` = its **stable id** and `data-origami-address` = its positional address. There is no `data-id`.
- A bare UUID gets a prefix: `H-` (heading), `E-` (display equation), `P-` (other), `st-` (stretchtext).
- Ids are made NCName-safe (`publishedID` ~519), and duplicates get `-2`, `-3` (`PublishedIDs` ~532).
- Reserved ids: `references`, `origami-publication-info`, `visual-meta`, `visual-meta-payload` and `bib-<key>`.
- A heading's stable id is the id of the concept with `tag == "heading"` and the same name, else the paragraph id. This keeps Author's Map node UUIDs.

**Header** (`headerHTML` ~1702).
- `<h1>` holds the title, followed by its alternates.
- `<p class="subtitle">`.
- `<div class="authors authors-N">` (N = 1, 2 or 3; four authors use 2). Each `author-block` has `p.author`, `p.affiliation` and `p.author-detail` (a `mailto:` link and the full ORCID URL).
- Affiliations no author claims come next, then `p.byline` (only when there is no `acmReference`).
- When there is an abstract and the body has no "Abstract" heading:
  - `<section class="abstract" epub:type="abstract" role="doc-abstract">`;
  - `p.ccs`, `p.keywords`, `p.acm-reference`;
  - `p.license` with `img.cc-badge`.

**Body elements.**

| Model | XHTML |
|---|---|
| heading level L (1–3) | `<hL+1 id data-origami-address>` (h2–h4; the title is the only h1) |
| paragraph | `<p id data-origami-address>`; a speaker line is `<p><strong class="speaker">X:</strong> …` |
| list run | `<ul>`/`<ol>` with `<li id data-origami-address>` |
| code | `<pre id data-language="x"><code class="language-x">` |
| quote / rule | `<blockquote>` / `<hr/>` |
| box | `<aside class="ot-box" data-box-id>` |
| stretchtext | `<a class="ot-stretchtext" href="#st-…" role="button" aria-controls aria-expanded="false">»»</a>` + `<aside class="ot-stretchtext-content" id hidden="hidden">` |
| figure | `<figure id data-origami-address><img src="images/f" alt="…"/><figcaption>…</figcaption></figure>`; `Asset.link` wraps the img in `<a href data-citation-key>` |
| table | `<table id data-origami-address data-table-id>` of `<tr>`; the first row is `<th>` when there is more than one row; `colspan` for spans (covered cells skipped); a preceding "Table N…" paragraph gets `class="table-caption"`; no `<caption>`/`<thead>` |
| display equation | `<math xmlns=MathML id="E-…" data-origami-address display="block" alttext="TeX" data-latex="TeX">…</math>`; if conversion fails, `<p class="equation">` with readable TeX |
| inline maths | `<math display="inline" …>`, protected during inline passes by `U+E000 n U+E001` |
| citation | `<a class="citation" epub:type="biblioref" role="doc-biblioref" href="#bib-KEY" data-citation-id="KEY" [data-origami-ref="rel:address#frag"]>[n]</a>`; an unknown key prints `[k]` |
| note mark | `<a [id="fnref-…"] role="doc-noteref" data-note-id="id" href="#<published id>"><sup>N</sup></a>` (N = the id's trailing digits, else order of first use); `[inote:]` uses `class="ot-inline-note"` and ‡ |
| note | `<p id epub:type="endnote" role="note"><a class="ot-note-back" role="doc-backlink" href="#fnref-…">N.</a> …</p>`, left in the body flow |
| jump | `<a class="ot-jump" data-target-id="id" href="#published">` |
| concept | first occurrence (outside tags and `<math>`) wrapped in `<dfn data-concept="name">` |
| bare URL | https/http/gemini/hm URLs become anchors (`OrigamiEPUBLinks.anchorSchemes`) |

**Reference list.**
- `<section id="references" epub:type="bibliography" role="doc-bibliography"><h2>…</h2><ol><li id="bib-KEY">…</li></ol></section>`.
- The entry text is ACM style (`referenceHTML` ~2604) or the house style (~2544).
- DOI links use `https://doi.org/…`, except that the `10.5555/` prefix links to `dl.acm.org/doi/…`.
- BibTeX is never put in attributes.

**Colophon** (`colophonHTML` ~1250, profile §8.4). The profile makes the colophon SHOULD; a writer may leave it out. Written only when `writesColophon` is on.

```html
<section epub:type="colophon" id="origami-publication-info">
  <h2>Visual-Meta Colophon</h2>
  <p>This document includes Visual-Meta to enable permanent self-citation, metadata preservation, and seamless reference management across digital, Web, and printed formats.</p>
  <h3>Self-citation record</h3>
  <pre>@inproceedings{lovelace2026analytical,
  author    = {Ada Lovelace and Charles Babbage},
  title     = {…},
  booktitle = {…},
  year      = {2026},
  doi       = {…},
  url       = {https://doi.org/…}
}</pre>
  <h3>Embedded machine-readable metadata</h3>
  <p>…</p>
  <ul><li>Bibliographic and structural identity: <code>visual-meta.json</code></li>
      <li>Authored interaction and layout: <code>origami.json</code></li>
      <li>Bibliography: <code>references.bib</code></li></ul>
  <p>To inspect the raw records, … change the <code>.epub</code> extension to <code>.zip</code> …</p>
  <h3>Rights</h3><p>… Licensed under <a href="…">…</a>. When reusing this work, credit ….</p>
  <p>This publication is <code>urn:uuid:…</code> and conforms to the Origami Text 1.0 profile (https://github.com/frodehegland/OrigamiText/tree/main/profile/1.0).</p>
</section>
```

- **Self-citation** (`selfCitationBibTeX` ~1171). The type is `@article` with a journal, `@inproceedings` with a publication, else `@misc`. The key is surname + year + first significant title word, and the `=` signs are aligned.
- **On re-export,** a body heading "Visual-Meta Colophon" and everything under it is removed first (`withoutImportedColophon` ~1053), so the colophon never prints twice.

**Hidden copy of the semantic record** (~1671):

```html
<section id="visual-meta" hidden="hidden"><h2>Visual-Meta</h2><p>…</p><p>@visual-meta-start</p>
<script type="application/json" data-origami-derived-from="visual-meta.json" id="visual-meta-payload">
<![CDATA[ …exact visual-meta.json text… ]]>
</script><p>@visual-meta-end</p></section>
```

Any `]]>` inside the JSON is split as `]]]]><![CDATA[>`. The JSON escapes `/`, so `</script>` cannot appear.

### 4.8 The records

Both JSON records are encoded with sorted keys, pretty-printed, slashes escaped, and nil members omitted. The float form is the shortest that round-trips.

**`visual-meta.json`** (`VisualMetaDocument` ~96). Schema: [`origami-schemas/visual-meta-1.1.schema.json`](../origami-schemas/visual-meta-1.1.schema.json).

```json
{
  "visual-meta": { "format": "visual-meta", "version": "1.1",
                   "profile": "https://github.com/frodehegland/OrigamiText/tree/main/profile/1.0",
                   "describes": "urn:uuid:3F2A…", "generator": "Origami Text for macOS",
                   "introduction": "This is Visual-Meta: … See https://visual-meta.info." },
  "document": {
    "title": {"value": "…", "lang": "en"}, "subtitle": {…},
    "authors": [ {"name": {"value": "Ada Lovelace", "lang": "en"},
                  "affiliation": "Analytical Society, London, UK",
                  "email": "ada@example.org", "orcid": "0000-0001-5711-1279"} ],
    "date": "2026-09-14", "identifier": "urn:uuid:3F2A…", "work": "urn:uuid:9C1D…",
    "modified": "2026-10-06T09:30:57Z", "origami-id": "<library address>",
    "abstract": {…}, "keywords": ["…"], "ccsConcepts": ["Human-centered computing → Hypertext / hypermedia"],
    "isbn": "…", "doi": "…", "publication": {…}, "journal": {…}, "acmReference": "…",
    "rights": "…", "license": "https://creativecommons.org/licenses/by/4.0/",
    "defaultDocument": "content/paper.html", "language": "en"
  },
  "structure": { "headings": [ {"address": "1", "id": "H-…", "href": "content/paper.html#H-…", "level": 1, "text": "Introduction"} ] },
  "concepts": [ {"id": "…", "name": "…", "description": "…", "tag": "…", "urls": [], "citationIdentifiers": ["KEY"], "address": "…"} ],
  "citations": [ {"id": "KEY", "number": 1, "href": "content/paper.html#bib-KEY", "lang": "de", "alternate": [ … ]} ],
  "equations": [ {"id": "E-…", "href": "content/paper.html#E-…", "display": "block", "format": "mathml",
                  "tex": "E = mc^2", "tex-sha256": "<64 lowercase hex>"} ],
  "bibliography": { "href": "references.bib",
                    "conventions": {"dialect": "…", "encoding": "…", "nameOrder": "…", "nameSeparator": "…",
                                    "dateFields": "…", "dateFormat": "…", "monthFormat": "…", "pageRange": "…",
                                    "keys": "…", "titleCase": "…", "nonStandardFields": ["…"], "source": "…"} }
}
```

- `equations` is omitted when there are none, and `bibliography` when there are no conventions.
- The concept `address` is set for headings only.
- The equation index omits the profile's optional `label`, `mathml-sha256`, `converter`, `section` and `heading`. It indexes display equations only.

**`origami.json`** (`InteractionDocument` ~320). Schema: [`origami-schemas/origami-interaction-1.0.schema.json`](../origami-schemas/origami-interaction-1.0.schema.json).

```json
{
  "origami": { "format": "origami-text", "version": "1.0", "profile": "https://github.com/frodehegland/OrigamiText/tree/main/profile/1.0",
               "describes": "urn:uuid:3F2A…", "created": "<modified>", "generator": "Origami Text for macOS" },
  "tables": [ {"identifier": "tex-table-1", "href": "content/paper.html#P-…", "rowCount": 3, "columnCount": 2,
               "cells": [[{"value": "Year"}, {"value": "Total"}],
                         [{"value": "2024"}, {"value": "120", "formula": "=SUM(B3:B4)"}]]} ],
  "map": { "nodes": [ {"id": "…", "label": "…", "kind": "heading|concept|citation"} ],
           "connections": [ {"from": "…", "to": "…"} ],
           "views": [ {"id": "<layout.sourceID or stableUUID(doc.id:view:index)>", "name": "Current Layout",
                       "space": {"units": "points", "convention": "right-handed-y-up"},
                       "nodes": [ {"ref": "…", "x": -570.28, "y": 12, "z": 0} ]} ] }
}
```

- `formula` and `columnSpan` are omitted when nil (the encoders are synthesised; there are no custom `encode(to:)` methods in `OrigamiEPUB.swift`).
- `tables` and `map` are each omitted when empty.
- Citation nodes are referred to by their citation key.
- Neither record carries a schema-id string. A record identifies itself by `format` + `version` + `profile`.

**`references.bib`** (`Citation.bibliographyEntry` ~441).
- Entries are separated by a blank line, and the file ends with a newline.
- Each entry is the source BibTeX **verbatim, re-keyed** to the citation key.
- A citation to an Origami address gains `origami-source-id = {address}`.
- A citation with no BibTeX gets a synthesised `@misc` with title, author, year, publisher, doi and url.
- **Keys** (~714) are the reference id made NCName-safe (else `ref<n>`), with `-2`, `-3` added for duplicates. The same key is the `#bib-` fragment and `citations[].id`. That three-way equality is the profile's §7.3/§9.5/§11 contract.

### 4.9 Validation at export (profile §18)

**The writer refuses to export** (`OrigamiEPUBExportError` ~51: `malformedContent`, `danglingAnchor`, `profileViolation`) in these cases:
- a citation's `references.bib` entry does not parse, or its key differs from the citation key (~887);
- the self-citation does not parse (~914);
- `paper.html` or `nav.html` is not well-formed XML (`assertWellFormed` ~2486, external entities off);
- a `href="#x"` in `paper.html` has no `id="x"` (`assertAnchorsResolve` ~2642). The id regex needs whitespace or `<` before `id=`, so that `data-note-id` cannot hide a dead anchor (see the pipeline doc §7.1);
- a nav `paper.html#x` does not resolve (~959).

All of these checks run before the ZIP is assembled.

**The writer warns but still exports** (logged; `profileWarnings` ~2417):
- paragraphs over 150 words containing newlines or tabs;
- a `<p>` with no id;
- bullet characters instead of lists;
- no `<h1>`;
- `<pre>` without a language;
- a licence that is not a URI;
- the BibTeX-conventions `notes` (shown on the Format sheet).

**§18.1 checks the writer does not make itself:**
- **Duplicate ids:** avoided by construction (de-duplication), not checked.
- **Record placement:** guaranteed by construction.
- **No `<model>`; MathML declared:** both by construction.
- **Colophon present:** since the 6 October 2026 revision of the profile the colophon is SHOULD, not MUST, and its absence moved from §18.1 (refuse) to §18.2 (warn). A publisher-edition EPUB written with the colophon off is therefore conforming. The writer does not add the §18.2 warning for a missing colophon to `profileWarnings`. When a colophon is written, every §8.4 rule applies to it.

### 4.10 Conformance summary

| Profile requirement | Writer behaviour |
|---|---|
| §4.1 `version="3.0"`, `unique-identifier`, prefixes | Yes; `cc:` only when used |
| §4.2 `dcterms:conformsTo` | `https://github.com/frodehegland/OrigamiText/tree/main/profile/1.0` |
| §4.3 work / edition / release | `isVersionOf` / `dc:identifier` / `modified`; no `schema:version`, no `dcterms:replaces` |
| §4.4 records via `<link rel="record">`, not manifest, not META-INF | Yes (packaging variant B) |
| §4.6 accessibility | `schema:` access mode, features, hazard, summary |
| §4.7 rights | `dc:rights`, `dcterms:license` (URI only), `cc:attribution*` |
| §5.5 languages | JSON value objects + XHTML `lang`; OPF primary only |
| §6 NCName ids + `data-origami-address`, no `data-id` | Yes |
| §7.3 biblioref, `#bib-KEY` | Yes |
| §7.4 glossref | **Not emitted**: concepts become `<dfn data-concept>`, with no glossary `<dl>` |
| §7.6 tables | Static values + `data-table-id`; no `<caption>`/`<thead>` |
| §7.7 MathML authoritative, `data-latex` derived, index | Yes; display equations indexed |
| §8.2 bibliography `<section>` | Yes |
| §8.3 endnotes | `<p epub:type="endnote" role="note">` in the flow, not `<aside>` in an endnotes section |
| §8.4 colophon (SHOULD) | Yes when `writesColophon`; off by default for publisher editions, which the profile allows |
| §9–§11 records | Yes |
| §13 digests | Only `tex-sha256` |

On 8 October 2026 five of this writer's exports (four Author golden documents and the HT '26 paper `ht26-8` from LaTeX) passed EPUBCheck 5.2.1 with 0 errors and 0 warnings, and the profile validator with 0 errors (profile Appendix B).

---

## 5. Publisher formats ("Import to Format")

### 5.1 The flow (`AppModel.swift` ~7194–7463)

1. **Choose a file.** `importEPUBToFormat()` (~7223) opens a panel limited to `FormatSources.contentTypes`. It holds the security-scoped resource, calls `FormatSources.load`, and stores `FormatConversion {url, doc}`. The sheet shows `missing`, the list of front-matter fields the paper lacks: authors, affiliations, abstract, subject classification, keywords, venue, references.
2. **Options** (`FormatOptions` ~7262):

   | Option | Default |
   |---|---|
   | `publisher` | `.acm` |
   | `style` | `.sigconf` |
   | `rights` | nil, meaning "as the paper says" (`Rights.stated(by:)`), else CC BY |
   | `event` | nil, meaning parsed from the ACM Reference Format (`conferenceFromReference`) |
   | `alsoEPUB` | true |
   | `colophon` | false |
   | `compile` | true |
   | `uploadName` | empty |

   The output folder's suffix is the acmart style for ACM, else the publisher's raw value.
3. **Choose where to write.** `writeFormat` (~7297) shows a **save panel** beside the source, named `<source>.<suffix>`. This is what grants the sandbox permission to write there. It then applies `withoutFigureCreditLines`.
4. **Write the bundle.** `writeFormatBundle(_:sourceName:options:to:)` (~7339) has no UI and is usable from tests:
   - **Folder:** the folder is replaced, then filled with `paper.tex`, `refs.bib` (if non-empty), `images/<name>` and `README.txt`.
   - **EPUB:** if `alsoEPUB`, the importer:
     - lifts front matter out of the body (`movingFrontMatterOutOfBody`);
     - drops the colophon unless kept;
     - sets `license` from `rightsStatement` and `licenseURI` to `https://creativecommons.org/licenses/<cc>/4.0/`;
     - writes `"<source> (<label>).epub"` with the publisher's house style.
   - **PDF:** if `compile`, for ACM it first runs `ACMartVersion.prepareCurrent()` and `supply(into:)`. Then `ACMLaTeX.makePDF`, then (for ACM) `recordInstalled(fromLogIn:)` and the CTAN freshness check.
   - **Upload ZIP:** for ACM, if a PDF exists, `writeACMUpload` (~7443) writes `<name>.zip` containing `pdf/<name>.pdf`, `Source/<name>.tex`, `Source/refs.bib` and `Source/images/*`. It contains no README, EPUB, TeX by-products or acmart files.
   - **Outcome:** `FormatOutcome` reports each output and error separately, so a failed EPUB never costs the PDF.

### 5.2 Templates (`ACMLaTeX`, `LiquidDocWriting.swift` ~636–3070)

LaTeX is **generated as text**, line by line. There are no template files.

| Publisher | Class line | `.bst` | Front matter function | EPUB house style |
|---|---|---|---|---|
| ACM | `\documentclass[<style>,language=…]{acmart}` | `ACM-Reference-Format` | `preamble` + `frontMatter` (~1169, ~1300) | `.acm` (Libertinus fonts) |
| IEEE | `\documentclass[conference]{IEEEtran}` | `IEEEtran` | `ieeeFrontMatter` (~2850) | `.ieee` |
| LNCS | `\documentclass[runningheads]{llncs}` | `splncs04` | `lncsFrontMatter` (~2878) | `.lncs` |
| Elsevier preprint | `\documentclass[preprint,12pt]{elsarticle}` | `elsarticle-num` | `elsevierFrontMatter` (~2931) | `.elsevier` |
| Elsevier two-column | `\documentclass[final,5p,times,twocolumn]{elsarticle}` | `elsarticle-num` | same | `.elsevier` |
| Preprint | `\documentclass[11pt]{article}` | `unsrt` | `preprintFrontMatter` (~2979) | `.preprint` |

**ACM styles** (`Style` ~1031): `sigconf, sigplan, sigchi, siggraph, acmtog, acmsmall, acmlarge, manuscript, sigchi-a, acmengage, acmcp`. Only `sigconf` is `supported` ("verified by compiling"); the rest are "offered on the class's word". Two-column styles: sigconf, sigplan, sigchi, siggraph, acmtog, acmengage.

**ACM preamble** (~1169):
- `\providecommand\BibTeX` at begin-document; `placeins`.
- `newunicodechar` mappings for → ← ≈ ≤ ≥ × − •.
- A patch to `\@printtopmatter` that draws a full-width rule under the title block.
- `\setcopyright{cc|rightsretained|acmlicensed|acmcopyright|none}`; `\setcctype[4.0]{by…}`; `\copyrightyear` / `\acmYear`; `\acmDOI`; `\acmISBN` (also read from the licence text).
- `\acmConference[short]{name}{date}{place}` + `\acmBooktitle` from the event; or, with only a venue name, `\acmConference[shortVenue]{venue}{}{}`.
- An `eventJoinPatch` so that an empty date or place does not print "HT, ,".

The class's own packages (hyperref, graphicx, booktabs, amsmath) are deliberately **not** loaded again.

**ACM front matter** (~1300):
- **Title:** `\title[short]{full}`. The short title (`runningTitle` ~1684) is used when the title is over 100 characters: the part before a colon (12–100 characters), else a cut at a word with "…".
- **Translations:** `\subtitle`; `\translatedtitle{babel}{…}`; translated abstracts via `translatedabstract`. `language=` class options list the translations' babel names, then the paper's own last (`acmLanguageOptions` ~1293).
- **Authors:** one `\author{}` per person, then `\orcid`, `\email` and `\affiliation{\institution \city \country}`.
  - The affiliation is read **from the end** (`affiliationLines` ~1397): 2 parts are institution + country; 3 or more are institution(s) + city + country.
  - The country is always written, even when empty, so acmart reports a missing country rather than the converter inventing one.
- **Abstract.**
- **CCS:** `\ccsdesc[500]{A~B}`. `→` becomes a literal `~` and each segment is escaped separately.
- **Keywords:** `\keywords{a, b}`.

**Other front matter.**
- **IEEE:** `\IEEEauthorblockN` / `\IEEEauthorblockA` (italic institution, town, mailto, ORCID URL), joined with `\and`; `IEEEkeywords`. The subtitle is a `\\[0.3em]{\large …}` line.
- **LNCS:**
  - institutes are numbered in order of first appearance, with `\inst{n}` and `\orcidID`;
  - `\authorrunning` is "A. Name and B. Name", or "et al." for more than two;
  - `\institute{… \\ \email{…}}`;
  - the keywords go inside `abstract`, separated by `\and`.
- **Elsevier:** `\journal{}`; `frontmatter` with `\author[affN]{Name\,\orcidlink{…}}`, `\ead{}` and `\affiliation[affN]{organization=, city=, country=}`; `keyword` separated by `\sep`.
- **Preprint:** `\author` blocks with `\small` place/mail/ORCID lines; `\date{venue \\ date}`; and "**Keywords:** …".
- **Rights (non-ACM):** written as an unmarked footnote (`{\renewcommand\thefootnote{}\footnotetext{…}}`) from `rightsStatement` (~3011). Example: "This work is licensed under a Creative Commons Attribution 4.0 International License, https://…", "© YEAR Copyright held by the owner/author(s).", then the event and the DOI line.

**Common preamble for non-ACM classes** (`commonPreamble` ~2749):
- `fontenc[T1]`, `inputenc[utf8]`, `graphicx`, `placeins`, `booktabs`, `amsmath,amssymb`, `url`, and the unicode mappings.
- `lmodern` for LNCS and preprint; `geometry[margin=1in]` for preprint.
- `orcidlink` + `\hypersetup{hidelinks}` for Elsevier (to avoid a hyperref option clash); `hyperref[hidelinks]` for the others.
- Shims: `\providecommand\Description[2][]{}` and `\newenvironment{acks}{\section*{Acknowledgments}}{}`.

**The body** (`body(of:)` ~1425), shared by all publishers.
- **Front matter in the body is skipped** (`isFrontMatter` ~1595). `withFrontMatterFromBody` (~2061) first lifts "Abstract", "CCS Concepts:", "Keywords:" and the ACM reference out of body paragraphs into fields.
- **Note paragraphs are skipped** (`noteIDs` ~1100): everything under a level-1 "Notes" heading, and ids starting `en-` or `fn`. Their text is inlined as `\footnote{}` where they are cited, so notes never print twice.
- **Headings:**
  - The level offset comes from the **first** heading.
  - Levels map to `\section` / `\subsection` / `\subsubsection`, each with `\label{ot:<id>}`.
  - Printed numbers (`^\d+(\.\d+)*\.?\s+`) are removed, because the class numbers sections itself.
  - An "Acknowledgments" heading opens `\begin{acks}`.
- **Tables** (`tableLines` ~1787):
  - The caption is found in the neighbouring "Table N:" paragraph, above first, then below (`tableCaption` ~1705, label removed), and placed above the table with its own label.
  - The grid is `tabular{l…}` with `\toprule`, `\midrule` after the first row, `\bottomrule`, and `\multicolumn{n}{c}` for spans.
  - It is boxed and scaled down to `\columnwidth` only if wider: `\sbox0{…}\ifdim\wd0>\columnwidth\resizebox…`.
- **Figures** (`figureLines` ~1646, `groupedFigureLines` ~1764):
  - A single figure is `figure[htbp]` with `\includegraphics[width=\columnwidth]{images/<id>.<ext>}`, `\caption`, `\Description` and `\label`.
  - The printed "Figure N:" is removed from the caption (`withoutFigureLabel`).
  - Citation-only paragraphs right after a figure move into its caption as `\cite{}`.
  - Consecutive uncaptioned images ending in a captioned one form **one** figure: up to 3 side by side, else 2 per row, each width `0.98/n − 0.01` of `\columnwidth`, with every member's label.
  - Image file names are the asset id made safe, with the image's own extension (`imageFileName` ~2016).
- **Code:** `verbatim`.
- **Display maths:** `\[ … \]` if `TeXMathML` can convert it (so it needs no paper-specific macros), else readable words.
- **Lists:** `• ` / `1. ` lines become `itemize` / `enumerate`. A paragraph holding several item lines is split.
- **Final lines:** `\FloatBarrier` before the bibliography, then `\nocite{*}` for reference-list documents, then `\bibliographystyle{…}` and `\bibliography{refs}`. An optional generated colophon follows.

**Inline conversion** (`inline(_:in:)` ~1837):
1. Inline maths that `TeXMathML` accepts is held out.
2. Everything else is escaped (`escaped` ~1940: the ten specials; `\` becomes `\textbackslash{}`, `^` and `~` become `\text…{}`).
3. `[cite:k]` → `\cite{k}`; `[cites:…]` is removed.
4. `[note:id]` → `\footnote{<note text without its leading number/backlink>}`.
5. `[w](origami-jump:t)` → `\ref` if the target is a heading, table or figure. Words that are only a number become `\ref{}`; "Figure 1" becomes `Figure~\ref{}`. Any other target keeps its words.
6. Links → `\href`.
7. `==x==` → x; `**` → `\textbf`; `*` → `\emph`; backticks → `\texttt`.
8. Maths is restored.

**`refs.bib`** (`bibliography(for:)` ~1966). Each reference's stored BibTeX (or a minimal `@misc`) passes through `bibtexDialect` (~1984): biblatex `journaltitle` → `journal`, `location` → `address`, and `date` → `year` when there is no year.
- For **non-ACM** publishers only, `@online|webpage|software|dataset|electronic` are rewritten to `@misc`.
- The ACM path keeps them, relying on `ACM-Reference-Format.bst` understanding them. That reliance is unclear from source.

### 5.3 External tools and the sandbox

| Item | Detail |
|---|---|
| Tools | `pdflatex`, `bibtex`, and `latex` (for docstrip). There is no latexmk, xelatex, lualatex, biber or tectonic. |
| Recipe | `pdflatex paper && bibtex paper && pdflatex paper && pdflatex paper` (`Bundle.recipe` ~647), each run as `-interaction=nonstopmode` |
| Search | `/Library/TeX/texbin/pdflatex`, `/usr/local/texlive/bin/pdflatex`, `/opt/homebrew/bin/pdflatex`, `/usr/bin/pdflatex` (`texCandidates` ~693). `bibtex` and `latex` are taken from the same folder. |
| States (`enum TeX`) | `runnable(path)` (executable); `unreachable` (the file exists but is not executable: the normal sandbox case); `absent` |
| Direct run | `compile(in:)` (~892) runs a child process with the bundle as working directory and output discarded. **No timeout; exit codes ignored.** Success means `paper.pdf` exists. |
| Sandbox route | `compile-acm-paper.sh` in the per-user Application Scripts folder, run via `NSUserUnixTask` (outside the sandbox). The user installs it once with a save panel aimed at that folder (`installHelper` ~801), mode 0755. The script sets `PATH` to the TeX folders plus the usual system paths. With `$2 = acmart` it runs `latex acmart.ins` instead. The version marker `# origami-helper 2` (`helperMarker` ~770) lets the sheet offer "Update Compile Helper…". |
| Fallback | Without TeX, the bundle (tex, bib, images, README) is still written, with the four-pass recipe in the README. The PDF and the ACM ZIP are reported as not made. There is no HTML-to-PDF fallback. |
| Non-macOS | `makePDF` / `compile` return nil (`#if os(macOS)`). |

### 5.4 Current acmart from CTAN (`ACMartVersion.swift`)

- **Installed version** (`recordInstalled(fromLogIn:)` ~40). `paper.log` is read as Latin-1 with `Document Class: acmart (\d{4})/(\d{2})/(\d{2}) v([\d.]+)`.
- **Latest version** (`refreshLatest(force:)` ~52):
  - `GET https://ctan.org/json/2.0/pkg/acmart` with a 20 s timeout;
  - reads `version.number` and `version.date`;
  - cached for 24 h.
  - The User-Agent contains the developer's contact email. A rebuild should use its own.
- **Build** (`prepareCurrent(force:)` ~175). Skipped if the already supplied release is at least as new.
  1. Download `https://mirrors.ctan.org/macros/latex/contrib/acmart.zip`.
  2. Extract `acmart/acmart.dtx`, `acmart.ins` and `ACM-Reference-Format.bst`.
  3. Write them to `~/Library/Application Support/ACMart/<version>/` (a temporary folder as fallback).
  4. Run `buildACMartClass` (`latex -interaction=nonstopmode acmart.ins`).
  5. Confirm with `\ProvidesClass{acmart}[YYYY/MM/DD vX]`.
  - The cache is valid only if `acmart.cls` exists.
- **Supply** (`supply(into:)` ~239). Copies `acmart.cls` and `ACM-Reference-Format.bst` beside `paper.tex`, since TeX prefers local files. They are not part of the upload.
- **State.** Stored in user defaults: `acmartInstalledRelease`, `acmartLatestRelease`, `acmartLatestChecked`, `acmartSuppliedRelease`, `acmartSupplyProblem`.
- **UI.** `ACMartStatusLine` (~254, shown in `ContentView.swift` ~1452).

---

## 6. Platform notes and portable equivalents

| Apple piece | Used for | Portable equivalent |
|---|---|---|
| `NSAttributedString(url:)` (AppKit) for docx/doc/rtf/odt | `WordImporter` general path | python-docx / docx4j / mammoth.js / Pandoc for docx; LibreOffice headless for .doc/.odt; an RTF parser (e.g. `striprtf`, `rtf.js`). Port the style-to-heading and run-coalescing rules. |
| `NSTextTable` blocks | Word tables | Read `w:tbl` directly (as `DocxScanner` already does on the ACM path) |
| `XMLParser` (SAX) | EPUB body, docx, JATS, EndNote XML, well-formedness checks | expat, libxml2 SAX, sax-js; **disable external entities** |
| `XMLDocument(.documentTidyHTML)` | malformed EPUB HTML fallback (macOS only) | html5lib / parse5 / gumbo, which also make it cross-platform |
| `PDFKit` (`PDFDocument`, `page.string`, `characterBounds`) | PDF import, camera-PDF ACM block, PDF figure checks | pdfium, pdf.js (`getTextContent` gives items with transforms), Poppler (`pdftotext -layout`, `pdftoppm`), PyMuPDF |
| CoreGraphics PDF raster | PDF figures → PNG (`rasterizedPDF`) | pdfium / Poppler `pdftoppm -png -r …` / MuPDF; keep the `min(2, 2200/maxSide)` scale and white background |
| `compression_decode_buffer` (ZLIB) | `DocxZip`, `ZipReader` | zlib raw inflate, minizip, yauzl, Python `zipfile` |
| Custom `ZipWriter` | EPUB writing | Any ZIP library that can **store `mimetype` first, uncompressed**. The source stores every entry; deflating others is allowed by EPUB, but reproduce "all stored" for byte-identical output. |
| CryptoKit SHA-256 / CRC | `stableUUID`, `tex-sha256` | Any SHA-256; the UUID derivation in §4.3 must match bit for bit |
| `JSONEncoder` with sorted keys + pretty printing | records | A canonical-ish JSON writer: sorted keys, `/` escaped, nil omitted, shortest float form |
| `Process` / `NSTask` | TeX, `tar`, `gunzip` | Child-process APIs; prefer a built-in tar/gzip library. Add the timeout and exit-code checks the source lacks. |
| App Sandbox + `NSUserUnixTask` + Application Scripts | Running TeX from a sandboxed app | Not needed on most platforms. In a browser or sandboxed store app: ship Tectonic or a WASM TeX (SwiftLaTeX / texlive.js), or a server compile, or produce the bundle only. |
| Security-scoped URLs, `NSOpenPanel`/`NSSavePanel` | Permission to read companions and write beside the source | The platform file picker; Web File System Access API; Android SAF |
| FoundationModels (on-device LLM) | Transcript summary | Any LLM behind the app's router (the app routes through `OrigamiLLM`, e.g. local Ollama, with JSON Schema output for the notes). Keep the chunk budget, grounding validation and refusal handling. |
| `NSKeyedUnarchiver` | Author `.liquidstore` | No portable decoder. Treat `.liquid` as Apple-only, or read only its JSON/plist members (glossary, DynamicView, Citations) with a plist library (plistlib, plist.js). |
| NaturalLanguage-style language detection (`LanguageTag.detect`) | `dc:language` when unstated | CLD3, fastText lid.176, franc; return `und` when unsure |
| System translation / transliteration | Import to Format translated title and abstract (profile App. B) | ICU transliterator; any MT service, marked `relation: "translation"` |
| UTType / `UTType(filenameExtension:)` | Open-panel filters | MIME types + extension lists (§2 table) |
| `UserDefaults` | acmart cache state | Any key-value settings store |

---

## 7. Rebuild order and acceptance checks

### 7.1 Order

1. **The model and its text conventions** (§1.1), plus the BibTeX parser and writer (§3.12). Everything depends on them.
2. **The EPUB writer** (§4), with all of §4.9's refusal checks. Validate it against the profile's Appendix A minimal publication, the JSON Schemas and EPUBCheck before writing any importer, because every importer is tested by writing and re-reading an EPUB.
3. **The EPUB importer** (§3.1). Round-trip what step 2 writes, then pre-1.0 and plain EPUBs.
4. **Markdown** (§3.3), then the three bridges (§3.4). They are the cheapest way to exercise citations, notes, tables and maths end to end.
5. **LaTeX** (§3.2), following the stage order exactly. Then tarballs (§3.12 `loadTarball`).
6. **Reference formats** (RIS / EndNote / CSL-JSON) and companion-bibliography routing.
7. **Word:** the ACM path first (deterministic OOXML), then the general path.
8. **JATS/BITS**, then **PDF**.
9. **The LaTeX writer and publisher formats** (§5): ACM sigconf first (the only verified style), then IEEE, LNCS, Elsevier and preprint; then the compile route and the acmart supply.
10. **Peripheral:** Author `.liquid` import and XR export, transcripts and summaries, tabular series.

### 7.2 Acceptance checks

| Check | How | Bar |
|---|---|---|
| Record schemas | `origami-schemas/check-schemas.py` (the schema self-test) and `validate-records.py <unpacked epub>` (README: venv + `jsonschema`) | All pass. Validation picks the schema by the record's own `format`, not its filename. |
| Profile validator | `origami-schemas/origami-validate.py validate <epub>` on the writer's output; `check-validator.py` for the validator itself | 0 errors (exit 0). Warnings are read, not ignored. 60/60. |
| Conformance corpus | `origami-corpus/build-corpus.py --check` with `EPUBCHECK` set; then the rebuilt reader's own extraction of each publication against `expected-extraction.json` | Identical. `11-packaging/B-link-only` is the shape the writer's output must have. |
| EPUBCheck | Run on the writer's output | 0 errors, 0 warnings. Passed on five exports, 8 Oct 2026 (profile App. B). |
| Writer self-checks | §4.9 refusals | No false refusals on the corpus; a fabricated dead note is refused (pipeline doc §7.1) |
| Structural digest | Pipeline doc §5.1: leaked label keys (`sec:\|fig:\|tab:` shapes), duplicate ids, orphan `[cite:]`, unresolved figure markers, PDF assets, raw-TeX residue | Zero on every paper |
| Anchor integrity | Unzip; every `href="#X"` has `id="X"` | Zero broken anchors |
| Round trip | Write → `OrigamiEPUBImporter` → compare: every `[note:fnN]` finds its note, plus heading and reference counts | Identical |
| Print comparison | Sample extremes (most notes, tables or maths, PDF figures, `\input`-structured) against the camera PDF: heading numbers, reference count, table digits, cross-reference words | Pipeline doc §5.4 (e.g. ht26-18: 159 references) |
| HT '26 corpus | 59 LaTeX/Word sources → 61 published EPUBs (memory: `ht26-proceedings-conversion-state`) | All convert; zero dangling anchors |
| Format self-test (debug builds) | Create `.check/RUN-FORMAT-SELFTEST` in the community folder. At launch every importable file in `.check/` goes through **every publisher** (`runFormatSelfTestIfRequested`, `AppModel.swift` ~7472), writing `.check/out/<file>.<suffix>/` and `.check/report.txt` | Each line `pdf=true epub=true` with no errors |
| ACM compile | `sigconf` bundle compiles with the four-pass recipe and current acmart; ACM upload ZIP layout as in §5.1 | `paper.pdf` exists; no missing-country error |
| Parked unit tests | `OrigamiEPUBProfileTests.swift.pending` (repo root): 8 cases for the profile warnings and list markers | Blocked by test-target membership (conformance plan OT-5) |

### 7.3 Discrepancies found while writing this chapter

These are differences between documents and code, or within the code. The rebuild should resolve each one deliberately.

1. **No warning for a missing colophon.** `FormatOptions.colophon` defaults to false, and `writeFormatBundle` passes it as `writesColophon`, so the "(label).epub" has no `epub:type="colophon"` section. That is conforming under the revised profile (§8.4 SHOULD), but §18.2 asks for a warning, and the writer gives none.
2. **Nav vs references condition.** The nav adds "References" when `doc.references` is non-empty, but the section is written only when gathered citations are non-empty. If those differ, the nav anchor dangles and export is refused.
3. **Accessibility summary overclaims.** It says "nested section headings, and ARIA landmarks", but sections are flat, the nav is flat, and there is no landmarks nav.
4. **§7.4 glossref and §8.1 glossary are not emitted.** Concepts appear only as `<dfn data-concept>` and in the records.
5. **§8.3 endnotes shape.** Notes are `<p epub:type="endnote" role="note">` in the body, not `<aside>` inside `<section epub:type="endnotes">`.
6. **§7.6 tables** have no `<caption>`/`<thead>`. The caption is a sibling `p.table-caption`.
7. **[`LATEX-IMPORT-PIPELINE.md`](../Origami%20Text%20macOS/LATEX-IMPORT-PIPELINE.md) §4 is stale.** It describes `id` = positional "purple number" with the stable id in `data-id`, and citations linking `#ref-<n>`. The 1.0 writer does the reverse: `id` = stable id, `data-origami-address` = position, no `data-id`, citations to `#bib-<key>`.
8. **[`ORIGAMI-EPUB-CONFORMANCE-PLAN.md`](../ORIGAMI-EPUB-CONFORMANCE-PLAN.md) OT-3 is stale.** It says `data-latex` is blocked, but the writer now emits `data-latex` on `<math>` and the importer reads it.
9. **[`AUTHOR-EXPORT-FRONT-MATTER.md`](../AUTHOR-EXPORT-FRONT-MATTER.md) §2 shows `authors[].name` as a plain string.** Profile §5.5.2 (and this writer) require the `{value, lang, alternate}` object. The note predates §5.5.
10. *(Resolved 8 Oct 2026: `origami-schemas/README.md` now cites the 1.0 section numbers and the current case counts.)*
15. **The LaTeX import keeps "CCS Concepts:" and "Keywords:" as body paragraphs** and writes neither `document.ccsConcepts` nor `document.keywords`; the validator warns `FM-BODY-TEXT` (profile §5.3).
16. **`bibliographyConventions` misreads `#` concatenation.** For `lastaccessed = sep # " 04, 2020"` it lists `2020",\n    year` among `nonStandardFields`.
11. **BibTeX escaping is inconsistent.** `BibTeXWriter` does not escape `{ } ~ ^`; `BITSImporter` replaces braces with parentheses; Word's CSL→BibTeX writes raw values. Only the LaTeX writer's `escaped` covers all ten specials.
12. **TeX runs have no timeout and ignore exit codes.** A hung `pdflatex` would block the Format run indefinitely.
13. **Hard-coded contact email** in the User-Agent of CTAN and Crossref requests (`ACMartVersion.swift`, `BibTeX.swift`).
14. **`stableUUID` emits uppercase hex,** while the profile's examples are lowercase. Both are valid UUID text, but a byte-compatible rebuild must match the uppercase form.
