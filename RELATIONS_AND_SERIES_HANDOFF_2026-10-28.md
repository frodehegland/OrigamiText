# Relations, permanent identity and series — handoff for Knowledge Space and Origami Text

28 October 2026, from the Author (Mac) session. For the Knowledge Space (Liquid App repo) and Origami Text (Mac and visionOS) sessions.

Author now writes four new kinds of metadata. This note says what they are, where each is written, and how a reader should use them. Frode's guiding decisions:

- **Relations between documents are typed** with CiTO, a published vocabulary of citation types. A document has **at most one** declared relation, to the document it answers.
- **Addressing degrades gracefully.** A document is found by its permanent **ID** first, its **DOI** where it has one, and its **name** (title, authors, date, file name) always.
- **Relations between articles across a series are not declared.** Knowledge Space works them out as it reads, for example "which earlier articles in *The Future of Text* go against this one?". This is described in §5.
- Author writes; the readers read. None of this asks a reader to change any file it reads.

Author commits: `b47c2530`, `ac8f8225`, `14964c54`, `8f99c776`, `ad7a9c38` (branch `map-node-model`). AuthorKit is pushed up to `34756a1`. The format reference is `ORIGAMI-BINDING-PROFILE.md` ▸ "Additions, 28 October 2026" in the Author repo.

---

## 1. Permanent document identity

Every Author document now has a `documentID`, a `urn:uuid:…` (lowercase). Author mints it the first time a document is saved without one, and never changes it afterwards: not on edits, moves, renames, exports or publication. Author for visionOS passes it through untouched.

| Where | How to read it |
|---|---|
| `.liquid` package | `Contents/Author.plist` → `documentID` |
| EPUB `visual-meta.json` | `document.work`. This is the work: the same in every edition and re-export. (`document.identifier` is this edition.) |
| EPUB `package.opf` | `<meta property="dcterms:isVersionOf">` |
| Visual-Meta BibTeX (PDF, Word, the EPUB appendix) | the self-citation's `document-id = {…}` |

**Fingerprint of a version.** `sha256:` plus the SHA-256 of the text, with runs of whitespace folded to one space. Author records it with a relation's target as `digest` / `vm-digest`. If a reader can compute the target's current digest and it differs, it should say "edited since this was answered", **not** "broken".

**Documents exported before today** have no `documentID`. Their EPUB work ID was derived from the file's location. Treat those as names-only (§2).

**Known gap:** a copied document keeps its ID. There is no `derivedFrom` yet.

## 2. Resolving an address

Every reference to another document, whether a relation, an article or a citation, carries as many of these as Author knew. Resolve in this order and stop at the first that resolves:

1. **ID**: `id`, `document-id`, or a work ID. Look it up in the local index of every known document's `documentID` and `document.work`, and of every article's `works[].id`.
2. **DOI**: `doi`. Look it up the same way; if needed, resolve via `https://doi.org/`.
3. **Locators**: `url`, `vm-id`, `origami-source-id`.
4. **Name**: title, plus first author's family name, plus year. Match fuzzily, show how confident the match is, and never present a name match as certain.

Keep the resolution with the reference, and show it: "found by its ID", "by DOI", or "by its name (85%)".

## 3. A document's relation to another

One per document, chosen in Author at Export ▸ EPUB ▸ **In Response To…**.

**Types.** Show the label to people and store the CiTO term:

| Label | CiTO |
|---|---|
| In response to | `repliesTo` |
| Builds on | `extends` |
| Agrees with | `agreesWith` |
| Disagrees with | `disagreesWith` |
| Corrects | `corrects` |
| Reviews | `reviews` |
| Discusses | `discusses` |

The IRI is `http://purl.org/spar/cito/<term>`.

### Where it is written

**EPUB `visual-meta.json` → `document.inResponseTo`.** This is the full reference object. Every field except `relation` and `label.title` is optional:

```json
"inResponseTo": {
  "relation": "cito:disagreesWith",
  "relationIRI": "http://purl.org/spar/cito/disagreesWith",
  "id": "urn:uuid:…",
  "doi": "10.1145/…",
  "label": { "title": { "value": "Hypertext Then and Now", "lang": "en" },
             "authors": ["Mark Anderson"], "date": "2024-09-10" },
  "digest": "sha256:…",
  "quote": "§3",
  "abstract": { "value": "Forty years of hypertext research.", "lang": "en" },
  "url": "https://…",
  "thread": ["urn:uuid:root", "urn:uuid:parent"]
}
```

- `quote` is the passage answered: a section reference or the words themselves.
- `thread` is the conversation so far: the documents the target itself answered, oldest first. It follows email's References header, so a thread survives a missing message.

**EPUB `package.opf`:**

```xml
<dc:relation id="in-response-to">urn:uuid:…</dc:relation>
<meta refines="#in-response-to" property="dcterms:type">http://purl.org/spar/cito/disagreesWith</meta>
<meta refines="#in-response-to" property="dcterms:title">Hypertext Then and Now</meta>
```

The `dc:relation` value is the best address Author had: the ID, otherwise `https://doi.org/<doi>`, otherwise the title.

**EPUB `references.bib` and Visual-Meta's references (PDF, Word, EPUB).** The target is one of the document's references, whether or not the text cites it:

```bibtex
@article{anderson2024hypertext,
 author = {Anderson, Mark}, title = {Hypertext Then and Now}, year = {2024},
 doi = {10.1145/…}, abstract = {…},
 document-id = {urn:uuid:…},
 vm-relation = {cito:disagreesWith},
 pagecited = {§3}
}
```

**Visual-Meta self-citation** (biblatex's own fields, plus ours):

```bibtex
related = {anderson2024hypertext}, relatedtype = {disagreesWith}, vm-relation = {cito:disagreesWith},
document-id = {urn:uuid:<this document>}
```

**Author `.liquid`:** `Contents/exportMeta.json` → `relation` (type, target, passage, showsInText, includesAbstract). Its citation in `Citations.plist` has `relation` and `document-id`.

**In the text, if the writer chose it:** a first paragraph, *"Disagrees with: Anderson, Mark — Hypertext Then and Now (2024), §3"*, in italics after the title. The target's abstract, if chosen, follows in a `blockquote` in EPUB or a lighter paragraph in PDF and Word. Readers may recognise it, but should rely on the metadata, not the line.

### What readers should do

- **Show it as the document's first fact:** "In response to: Anderson 2024, §3". Make it clickable, and resolve the target as in §2.
- **Build the inverse index.** It lives outside the documents, which are never edited. Keep `respondsTo` edges, by ID where there is one, in Knowledge Space's reference store, so each document can show "Responses" as well as "In response to".
- **Show the thread** (`thread` plus this document) as the conversation, in order.

## 4. Books of articles in a series (*The Future of Text*)

A **work** is a level 1 section whose heading has Contributing Authors. A **binding** is the EPUB that holds them. This is the Binding Profile from 24 October, which Origami Text's binder already reads. New today:

**The series.**

```xml
<meta property="belongs-to-collection" id="book-series">The Future of Text</meta>
<meta refines="#book-series" property="collection-type">series</meta>
<meta refines="#book-series" property="group-position">7</meta>
<meta refines="#book-series" property="dcterms:identifier">urn:uuid:3F19824A-…</meta>
```

In `visual-meta.json`: `document.binding.series = { "name": "The Future of Text", "volume": 7, "id": "urn:uuid:…" }`.

The **series ID is the same in every volume**: given, otherwise derived from the lowercased name with AuthorKit's `stableUUID("series:the future of text")`. **Join volumes by `id`**, falling back to the name, and **order them by `volume`**.

**Each work** in `document.binding.works[]`:

```json
{
  "id": "urn:uuid:22D6300C-…",
  "title": "After Documents",
  "authors": [{ "name": "David Millard" }],
  "href": "content/work-2-after-documents.html#H-…",
  "section": "H-…",
  "abstract": "Documents give way to flows.",
  "keywords": ["hypertext", "documents"],
  "source": { "binding": "urn:uuid:…", "edition": "…", "title": "The Future of Text Vol 7",
              "editors": ["…"], "year": "2026", "position": 2,
              "series": "The Future of Text", "volume": 7 },
  "resources": { "notes": [...], "references": [...], "concepts": [...], "images": [...] }
}
```

- **`id` is permanent.** It's derived from the book's `documentID` and the heading's own ID, so it's the same in every re-export, in the book, and in a single-article EPUB of it.
- `abstract` is the editor's, from Author's ⌘-click on the heading ▸ Abstract. `keywords` are the heading's Topics. Either may be missing.
- `resources.references` are the article's own citations, and `resources.concepts` its own concepts. Together with the abstract, these are what a reader can compare without opening the text.
- **Single-article EPUBs** ("Each article on its own too") carry the same work, plus the book's series, volume and position in `source`. Their `document.abstract` and `keywords` are the article's.

**Older volumes.** Frode is re-exporting volumes 1 to 6 with this build. Until then, a book with no `binding.works` can still be read for its articles: Origami Text's binder already cuts articles at headings followed by a `work-authors` byline, otherwise at `<h1>`. Give such articles a derived ID (book plus heading), and treat them as name-addressed.

## 5. Relations between articles, worked out as the reader reads

The question to serve: **"Which earlier articles in this series go against this article?"**, along with "build on it", "agree", "answer it". Nothing is declared in the books for this. The reader works it out, so it can change as better models arrive and as volumes are added.

Suggested approach for Knowledge Space:

1. **Gather the candidates.** Take works in the same series with a lower `volume`, or the same volume and a lower `position`. Use the series ID, then the name.
2. **Narrow them cheaply, without AI.** Keep the works that share concepts (by library ID or term), keywords, or references (by ID, DOI or name) with this one. Also keep any that cite it or are cited by it; those are the strongest signal. Rank them by how much they share.
3. **Judge each pair with the AI,** this article against one candidate. Give it both abstracts (or opening paragraphs when there's no abstract), the shared concepts and references, and, when needed, the relevant passages.
   - Ask for one CiTO term from the seven, or `none`.
   - Ask for a confidence, and a one-sentence reason quoting the passages that conflict or connect.
4. **Show the results as the AI's judgement**, never as the published record. For example: "AI: Disagrees with — Anderson, *Against Flows* (Vol 5), 0.8 — 'Flows lose the reader' vs 'Documents give way to flows'." Let the reader accept the judgement as a note in their own space, or dismiss it.
5. **Cache by the pair of work IDs plus both abstracts' digests,** so a judgement is reused until either article changes.
6. **The same machinery** answers the other questions: change the term asked for.

Declared relations (§3) and exact citations (by work ID) always take precedence, and should be shown as such.

## 6. Other fields worth knowing

- **Meeting Kind.** Author's document Kind "Transcript" is now called **Meeting**. Accept both tags.
- **`Contents/conceptsUsed.json`** in meeting documents: every known concept a meeting names, with counts and speakers. See `CONCEPTS_USED_HANDOFF_2026-10-27.md` in the Liquid App repo.
- **Opening in Author for visionOS.** `author://open?path=…&title=…&relative=…` now opens a document (Author `a2a57814`), resolved by Author's container, then path, then title.

## 7. Checklists

**Knowledge Space**

- [ ] Index `documentID`, `document.work`, DOIs and `works[].id` from every document and EPUB it gathers.
- [ ] Read `document.inResponseTo` and `dc:relation`. Store `respondsTo` edges with the CiTO term and resolve them as in §2.
- [ ] Show "In response to" and "Responses" on a document, and the thread.
- [ ] Read `binding.series`. Join and order volumes, and show articles as objects grouped by volume.
- [ ] Use each work's abstract, keywords, concepts and references.
- [ ] Answer the series questions as in §5, labelled as the AI's judgement.

**Origami Text (Mac and visionOS)**

- [ ] Show the "In response to" first line from the metadata, with the target resolvable and, when it's present, the quoted passage beside it.
- [ ] In a book, show series and volume. List articles with their abstracts. Open, share or extract one article, keeping its work `id`.
- [ ] Carry `document-id` and `vm-relation` when copying a citation of a document, so a reply written from it in Author keeps the exact address.
- [ ] Older books without `binding.works`: keep the existing heading and byline cutting.

## 8. Addition for Origami Text, from the Knowledge Space developer (28 Oct 2026)

**Write `binding.works` whenever Origami Text writes an EPUB.** That covers binders, selections, re-exports, and books whose articles it found by cutting at headings and bylines. In `visual-meta.json`, give each article:

- its heading ID (`section`, and `href`),
- `title` and `authors`,
- its order (`source.position`),
- the series `name` and `volume` (`source.series` and `source.volume`, and `document.binding.series` for the book).

Use the shapes in §4. Keep a work's `id` when the source already had one; otherwise derive it from the book's ID and the heading. With that, Knowledge Space's index reads the articles from the record and doesn't rely on the byline markup. Books exported from Author with this build already carry all of this.

**Handle `origami://open` on visionOS,** as Author for visionOS now handles `author://open`. Accept the same query items:

- `path` (the full path),
- `relative` (the path within the iCloud container),
- `title`,
- `id` (a document or work ID), to open one article inside a book.

Resolve in that order: the container plus `relative`, then `path`, then the title searched in the library. If it is still in iCloud only, download it and then open it. If it can't be found, show a short note saying so, rather than nothing. Then add `origami://` to `CFBundleURLTypes` and add `.onOpenURL` to the app's windows. Author's version, `AuthorMobile/AppModel/AuthorOpenLink.swift` (Author commit `a2a57814`), can be followed closely.
