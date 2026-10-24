# Writing Tools — Author's basic writing in Origami Text

*Plan, 23 October 2026. Status: built the same day — every phase in code,
the macOS scheme building; round trips and EPUB export verified in
snippets (own documents, and an Author-made golden archive read back);
the on-screen pass and the Author hand-off are Frode's to check. Origami Text
macOS gains the basic writing tools of Author macOS — formatted text,
images, tables, paste-a-DOI-or-BibTeX to cite — with Author's `.liquid`
package as the draft's file on disk. Author-only tools (margins, outline,
map, find, fold, focus, cuttings, glossary, AI) are not ported.*

## 1. What exists on each side

**Origami Text today.** A draft is a `LiquidDoc` saved as JSON
(`.origamitext`, `origami/0.1`) in Application Support/Drafts, edited as
plain markdown in `MarkdownTextEditor` (TextKit 1, `# ` headings and
`*emphasis*` styled live, markers hidden). Images are base64 `assets`
with `![alt](asset:id)` marker paragraphs. Tables exist in the model
(`LiquidDoc.Table`, bridged to `LATable`) but `DraftEditor.buildDocument`
drops them and the one-line-per-paragraph parser splits their pipe text.
Pasting BibTeX inserts a sentence but records nothing unless the entry
carries a `vm-id`. There is no Format menu. Export is EPUB 3 through
`OrigamiEPUBExporter`, with the Visual-Meta appendix added to the
published copy. The whole app — index, reader, Map, publish — consumes
`LiquidDoc`.

**Author today** (`~/Documents/author_mac_forxcode`, branch
`map-node-model`; `~/Documents/Author 26` is an empty stub). A `.liquid`
is a package:

```
Name.liquid/
  Contents/
    Content.liquidstore   NSKeyedArchiver of the body NSAttributedString
    Content.rtfd/         RTFD backup of the same text
    Version.plist         FormatVersion 8.11, Type, FontSizeModifier, …
    Author.plist          author, title — round-trips unknown keys
    Citations.plist       [citationID: LACitation plist]
    exportMeta.json, glossary.json, DynamicView.json, … (Author-only)
```

Structure lives in attributes on the text, not in a paragraph model:
`LATextStyleIdentifierAttribute` per paragraph (`body`, `header1`–`6`,
`bulletList`, `dashList`, `code`, `citation`, `attachment`), bold/italic
as font traits, `.link` for web links, `LACitationIdentifierAttributeName`
+ `LACitationFormatAttributeName` on a citation run, images as
`NSTextAttachment` with a fileWrapper, tables as `LATableAttachment`
whose fileWrapper is `AuthorTable-<id>.json` (an `LATable`). Citation
records are `LACitation` plists; the references list is built at export,
never stored. Paste order: Origami quote → self-citing PNG → COinS/CSL →
Author clipboard → BibTeX → DOI (Crossref `works/<doi>`) → tab-separated
(becomes a table) → plain.

## 2. The design

1. **A draft is a real `.liquid`.** Drafts/ holds `<id>.liquid` packages
   written in Author's layout, so Author opens them unchanged and
   Origami reads what Author saves. No Author code is linked; the
   attribute names, style ids, plist keys and class names are mirrored.
2. **Origami's fields ride in `Author.plist`** under one `origami` key:
   `id`, `created`, `attention`, `onBehalfOf`, `date`, `documentType`,
   `links`, `aiOnBehalf`. Author preserves the dictionary it read, so a
   round trip through Author keeps them. (`customJSON.json` is the
   fallback if a field turns out not to survive.)
3. **One bridge, both ways** — `LiquidRichText`: `NSAttributedString`
   (Author conventions) ⇄ `LiquidDoc`. Everything downstream — library
   index, reading view, EPUB export, Visual-Meta publish, Map — keeps
   consuming the derived `LiquidDoc`; nothing else in the app changes
   its input type. Rules:
   - `header1–3` ⇄ `heading` 1–3; `header4–6` → heading 3 (format clamps).
   - `bulletList` / `dashList` ⇄ `• ` / `- ` lines (the EPUB exporter
     already renders these); `code` ⇄ fenced block.
   - bold / italic traits ⇄ `**` / `*` (reuse `WordImporter.markdownText`,
     made internal); `.link` ⇄ `[text](url)`.
   - image attachment ⇄ `Asset` + `![alt](asset:id)` paragraph; a
     following `attachmentDetails`-styled paragraph is the caption.
   - table attachment ⇄ `LiquidDoc.Table` + paragraph with `tableID`
     and pipe fallback (bridge at `LiquidDoc.swift:1168` exists).
   - citation run ⇄ `Reference { id, bibtex }` + `[cite:id]` token after
     the run (the exporter already numbers `[cite:]`); library addresses
     keep their `[address#p]` form and `links`.
   - Paragraph ids: `p1…pN` as today; the format already says draft
     fragments may drift.
4. **Rich editor replaces the markdown editor for drafts.**
   `RichTextEditor` (NSViewRepresentable, TextKit 1, `allowsUndo`) edits
   the attributed string directly; styling is data, not re-derived per
   keystroke. Transcript hooks (speaker prefixes, Lift to New, reveal
   paragraph, shared context menu) carry over so one editor remains.
5. **Format menu with Author's shortcuts** (always present, never
   conditional): Heading 1–3 ⌘1–⌘3, Body ⌘0, Bold ⌘B, Italic ⌘I, Bullet
   List ⌘8, Dash List ⌘9, Code, Weblink… ⌘K, Citation… ⌘T, Insert
   Image…, Insert Table…. Dispatched by `@FocusedValue` to the editor's
   coordinator. Not included: align, highlight, strikethrough, endnotes,
   inline notes, page break, contract, mark, comment.
6. **Citations.** `AuthorCitation` mirrors `LACitation`'s plist (identifier,
   title, author/authors, year/month/day, doi, webAddress, journal/
   publication, volume, issue, pageRange, publisher, isbn, bibTeXType,
   originalText) with `bibTeX` both ways via `BibTeXParser`/`BibTeXWriter`.
   Paste cascade in the editor: Origami `CitationClipboard` → Reader quote
   → BibTeX → DOI (regex as Author's, lookup via `CrossrefVerifier`
   extended with `fetch(doi:)`) → tab-separated → plain. Inserted form as
   Author: `(Surname, Year)` with no selection, `“selected words” (Surname,
   Year)` with one, tagged with the citation id and `nameAndDate` /
   `textWithNameAndYear`. ⌘T opens a sheet accepting a DOI or BibTeX by
   hand. Preflight keeps working on the derived references.
7. **Images.** Insert Image…, drag-and-drop, paste. Bytes normalised to
   ≤2048 px JPEG/PNG and kept as the attachment's fileWrapper (so they
   live in the liquidstore and the RTFD, as Author's do). The image
   strip under the editor goes; images are inline.
8. **Tables.** `TableAttachment: NSTextAttachment` holding an `LATable`
   (already in the project, shared with iOS/vision), fileWrapper
   `AuthorTable-<id>.json`, archived under the class name
   `LATableAttachment` (`NSKeyedArchiver.setClassName`) so Author
   unarchives its own class; on read we map `LATableAttachment` and
   `InlineImageAttachment` back to ours. A cell draws the grid inline;
   click opens a popover grid lifted from `DocumentEditorView.TableEditor`
   (today DEBUG-only) into a shared `TableGridEditor`, with add/remove
   row and column. Insert Table… asks rows × columns; pasting
   tab-separated text makes a table, as in Author.
9. **Storage and migration.** `DraftStore` lists `.liquid` packages. An
   existing `.origamitext` draft converts to `.liquid` the first time it
   is opened; the original moves to `Drafts/Migrated/` (nothing deleted).
   Archived/ moves packages whole, as now. Published/ stays
   `.origamitext` with its appendix — the published record is the JSON
   format, unchanged.
10. **Export unchanged, plus Open in Author.** Export… still makes the
    EPUB from the derived `LiquidDoc`; Export as .origamitext still
    works. A new "Open in Author" (NSWorkspace, Author's bundle id)
    hands the package over — the cheapest proof of interoperability.

## 2b. The export's settings (added the same day)

Frode's ask: Export to Origami EPUB with every setting Author's own
export carries. Author's effective settings (its Export dialog, read
from `author_mac_forxcode`): header style Plain / Basic / ACM, the ACM
Details (author name, email, ORCID, institution, city, country,
conference, DOI, ISBN, CCS concepts, keywords), abstract and keywords
(`exportMeta.json`), tags and meeting details for dialogue documents.
Its Version.plist citation and heading formats are not read by its
Origami export, so none were ported. Built as `ExportSettings` +
`ExportEPUBSheet`: ⇧⌘E on a draft asks these first; abstract, keywords
and acknowledgements are written into Author's `exportMeta.json` (its
edits win on read), the rest under `Author.plist["origamiExport"]`;
`OrigamiEPUBExporter.frontMatterStyle` gates the header (plain = title
alone, basic = title and names, full = the paper's front matter).
Meeting details stay with Origami's own dialogue path.

## 3. Fixes this path needs anyway

- `DraftEditor.buildDocument` must pass `tables:` (dropped today).
- `VisualMeta.appendingAppendix` must carry `tables`, `assets`,
  `sourceURL`, `publication` into the published copy (dropped today).
- Export button help text says `.origamitext` while ⇧⌘E exports EPUB.
- BibTeX paste without a `vm-id` records nothing (replaced by §2.6).

## 4. Files

New, macOS target only:

| File | Holds |
|---|---|
| `LiquidPackage.swift` | read/write the `.liquid` package: Version/Author/Citations plists, liquidstore archive with class-name maps, RTFD backup |
| `AuthorAttributes.swift` | the mirrored attribute keys, style ids, format names |
| `AuthorCitation.swift` | `LACitation` plist shape ⇄ BibTeX |
| `LiquidRichText.swift` | attributed string ⇄ `LiquidDoc` bridge |
| `RichTextEditor.swift` | the editor view, coordinator, paste cascade, drag-and-drop |
| `TableAttachment.swift` | attachment, drawing cell, `TableGridEditor` popover |
| `CitationPaste.swift` | DOI/BibTeX detection, Crossref fetch, citation sheet |
| `FormatCommands.swift` | the Format `CommandMenu` and focused-value key |

Changed: `DraftStore.swift` (packages, migration, attributed body),
`DraftEditorView.swift` (swap editor, footer), `AppModel.swift` (Open in
Author, export from derived doc), `OrigamiTextMacApp.swift` (menu),
`VisualMeta.swift` (§3), `WordImporter.swift` (expose markdownText),
`DocumentEditorView.swift` (use shared grid). Shared files
(`LiquidDoc.swift`, `LiquidDocWriting.swift`, `LATable.swift`) are not
expected to change; if they do they must still compile on iOS/visionOS.
Target membership of new files is Frode's in Xcode (never the pbxproj by
hand). Rebuild guide chapter and the bundled user guide get a Writing
section.

## 5. Build order

0. **Spike (first, half a day).** Write one `.liquid` from Origami with a
   heading, bold, a bullet list, an image, a table and a citation; open
   it in Author, check it renders and re-saves; read an
   `~/Documents/AuthorGoldenCorpus` document back through the same code
   and derive a `LiquidDoc`. This settles the class-name mapping and
   the `Author.plist` round trip before any UI exists.
1. `LiquidPackage` + `AuthorAttributes` + `AuthorCitation` +
   `LiquidRichText`, with `DraftStore` on packages and migration.
2. `RichTextEditor` + Format menu + images; `DraftEditorView` swapped;
   transcript hooks carried over; `MarkdownTextEditor` retired once
   parity is confirmed.
3. Tables: attachment, cell, grid popover, Insert Table…, TSV paste.
4. Citations: paste cascade, DOI fetch, ⌘T sheet, Preflight on the
   derived doc.
5. Open in Author; §3 fixes; guide chapters; verification.

## 6. Verification

Unit tests cannot see the macOS files, so checks run as `RunCodeSnippet`
on the Origami Text macOS scheme: package round trip (write → read →
same text, same styles, same citation ids, same table cells); golden
corpus `.liquid` → `LiquidDoc` → EPUB with both exporter guards green;
an Origami-written `.liquid` saved by Author and read back keeps its
`origami` fields. By eye: ⌘B/⌘1/⌘8 in the editor, an image dropped in,
a table edited in the popover, a DOI pasted becoming `(Surname, Year)`
with a reference in Preflight, and Open in Author showing the same
document.

## 7. Out of scope

Margins, outline, map, find, fold, focus, cuttings, comments, endnotes,
inline notes, glossary/Defined Concepts editing, AI writing aids,
alignment, highlight, strikethrough, page breaks, Word/LaTeX/HTML
export, iOS and visionOS editing, multi-editor conflict handling.
