# Rebuilding Origami Text

This folder describes Origami Text closely enough for a person, or a large
language model, to build the app again on another platform: the web,
Windows, Linux, Android, or a fresh Apple codebase. It covers what the app
does, the data it reads and writes, and the rules and algorithms behind each
feature. Each point is tied to the Swift source that implements it, so the
source is always the final word and these pages explain it.

The code in this repository is the macOS app, about 131,000 lines of Swift in
`Origami Text macOS/`. The guide was written by reading that code in October
2026. Where the code and the older documents disagree, the chapters say so.

## If you are an LLM asked to rebuild the app

1. Read the format documents first (next section). They are the contract. A
   rebuild that reads and writes these files correctly can work with any
   other Origami reader, whatever it looks like.
2. Then read the chapters in the order below, building as you go. Every layer
   is usable without the ones after it, so stop wherever the job ends.
3. Keep what is listed as **behaviour, data and rules**. Treat what is listed
   as **Apple-specific** as one way of doing it. Each chapter has a "Platform
   notes" section with portable equivalents.
4. Run each chapter's acceptance checks before moving on.
5. When a chapter says "unclear from source", read the cited Swift file
   rather than guessing.

## The format — normative documents

Read in this order. Paths are from the repository root.

| Document | What it defines |
|---|---|
| [ORIGAMI-EPUB-PROFILE-1.0.md](../ORIGAMI-EPUB-PROFILE-1.0.md) | **The main format.** How an Origami document travels as a conforming EPUB 3: package, metadata, records, citations, identifiers. Normative. |
| [origami-schemas/](../origami-schemas/) | JSON Schemas for the profile's records (`visual-meta-1.1`, `origami-interaction-1.0`), their validators, and a conforming sample EPUB. |
| [origami-packaging-tests/](../origami-packaging-tests/) | The first conformance corpus item: five packaging variants and their EPUBCheck results. |
| [ORIGAMI-DOCUMENT-FORMAT.md](../ORIGAMI-DOCUMENT-FORMAT.md) | The native `.origamitext` JSON document: blocks, addresses, relations, Visual-Meta. |
| [Origami Text macOS/CITATION-EPUB-SPEC.md](../Origami%20Text%20macOS/CITATION-EPUB-SPEC.md) | The citation contract shared with the Author app: clipboard payload, BibTeX fields, back-matter list. |
| [ORIGAMI-EPUB-CONFORMANCE-PLAN.md](../ORIGAMI-EPUB-CONFORMANCE-PLAN.md) | What the reader supports of EPUB 3 itself, and what is still planned. |
| [AUTHOR-EXPORT-FRONT-MATTER.md](../AUTHOR-EXPORT-FRONT-MATTER.md) | Front matter as the Author app exports it. |
| [LIQUID-DOCUMENT-FORMAT.md](../LIQUID-DOCUMENT-FORMAT.md) | A rename notice: "Liquid" is the older name of the Origami document format. |
| [OrigamiFormat](https://github.com/frodehegland/OrigamiFormat) | A Swift package holding the annotation model, document identity, EPUB container reader and reading styles that the Reader app uses. Origami Text has its own copies of this code and does not yet link the package. Chapter 3 §4 compares the two. |

Some of these documents also have a copy inside `Origami Text macOS/`. Those
copies are bundled into the app and can be older or newer than the
root-level ones; the root-level copy is the one to read.

## The chapters

| Layer | Chapter | Covers |
|---|---|---|
| 1. Frame and library | [01 — Shell, library, documents](01-shell-library-documents.md) | Window and navigation, the library index, the `.origamitext` model and addresses, drafts and writing, every setting, everything on disk. |
| 2. Core reader | [02 — EPUB reading](02-epub-reading.md) | From file to rendered page, the injected CSS and scripts in order, the page↔app message bridge, reading modes, themes, Find, Read Aloud, the selection dot and context panel, Overview. |
| 2. Core reader | [03 — Annotations, identity, network](03-annotations-identity-network.md) | The W3C Web Annotation model, sidecars, re-anchoring, device sync, document identity, and the network integrations (Hypothesis, Seed Hypermedia, Gemini and others). |
| 3. Writing and import | [04 — Import and export](04-import-export.md) | Every importer (EPUB, LaTeX, Markdown, Typst, AsciiDoc, rST, Word, JATS/BITS, PDF, Author, BibTeX/RIS/EndNote), the Profile 1.0 EPUB writer, and the publisher formats (ACM, IEEE, LNCS, Elsevier, preprint). |
| 4. Features | [05 — References, citations, people](05-references-citations-people.md) | The References page, retraction and DOI checks, external scholarly services, citation graphs and Lineage, people, places and venues. |
| 4. Features | [06 — Maps, views, AI](06-maps-views-ai.md) | The Map views, AI routing through `OrigamiLLM` and every AI task, the Library Views catalogue, and a short note on the visionOS spatial code. |

A minimal compatible reader is layers 1 and 2: a library, an EPUB reader with
themes, and annotations that round-trip through the sidecar format. Layer 3
makes it a writer. Layer 4 is what makes it Origami Text.

## Building the existing app

Open `OrigamiText.xcodeproj` in Xcode and build the **Origami Text macOS**
scheme (macOS 26 or later). The iOS and visionOS schemes share some of the
same files; they are experimental. Swift packages are fetched by Xcode on
first open.

## Known differences between documents and code

Each chapter ends with a list of places where the code does something the
documents don't say, or the other way round. Read these before trusting
either side:

- Chapter 1 §9 — file naming, fields missing from the spec, default views, module sources
- Chapter 2 §10 — reading-mode names, citation class names, reading-position keys
- Chapter 3 §3.6, §4 and §7.3 — sync-file keys, the identity scheme, how the OrigamiFormat package and the app differ
- Chapter 4 §7.3 — the writer against Profile 1.0, stale pipeline documents
- Chapter 5 appendix — DOI cleaners, AI routing exceptions
- Chapter 6 §3.6 and §7.3 — AI calls that bypass `OrigamiLLM`, where the Map code lives

These lists describe the code as it was when the guide was written. They are
not a to-do list: some differences may be deliberate.

## Keeping this guide current

This guide is only useful if it stays true. When the app changes:

- **A feature is added or changed:** update the matching chapter's feature
  section, its data-on-disk table if files or settings changed, and its
  acceptance checks.
- **The format changes:** update the normative document first, then the
  chapter that implements it.
- **A difference listed above is resolved:** remove it from that chapter's
  list.
- **Before each App Store build:** the release checklist asks for a pass
  over this folder, alongside the user guide.

Cite source by file and type or function name, not by line number, so
references survive edits.

## Licence

MIT, as for the rest of the repository. See [LICENSE](../LICENSE).
