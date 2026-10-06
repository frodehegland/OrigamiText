# 05 — References, Citations, People and Places

> Rebuild guide, chapter 5. Paths are given from the repository root. Source files are cited as
> `Origami Text macOS/File.swift` with the type or function name.
>
> Read first, and treat as authoritative where they overlap this chapter:
>
> - [README.md](../README.md) — what the app is, how to build it.
> - [ORIGAMI-TEXT-OVERVIEW.md](../ORIGAMI-TEXT-OVERVIEW.md) — the ideas: addresses, citations, the library.
> - [Origami Text macOS/CITATION-EPUB-SPEC.md](../Origami%20Text%20macOS/CITATION-EPUB-SPEC.md) — the citation contract with Author: the clipboard payload, the BibTeX fields (`vm-id`, `origami-source-id`, `vm-source-*`), the backmatter `bib-<key>` list, and what happens on a click.
> - [ORIGAMI-EPUB-PROFILE-1.0.md](../ORIGAMI-EPUB-PROFILE-1.0.md) — normative for citations (§6.3), the citation record (§8.4) and the bibliography record (§10).
> - [USER-GUIDE.md](../USER-GUIDE.md) — points at the bundled guide `Origami Text macOS/OrigamiTextUserGuide.md`, whose sections 6 (Citations and the References page) and 16 (What goes online) describe this chapter's features from the user's side.

---

## 1. Purpose

This area of the app answers four questions about the document being read:

1. **What does it cite?** The References page lists every cited work, in the paper's own order (As Cited) or by title, author or date.
2. **Can those works be trusted?** Each work gets small marks: Retracted, Withdrawn, Expression of Concern, Corrected, Preprint, Replicated / Not Replicated, Unverified, plus importance, kind, use and access words.
3. **How do the cited works relate to each other?** The Time Map (years left to right) and the Concept Map (eight layouts) draw a line wherever one cited work cites another. To find those lines, the app reads each cited work's own reference list, from the shelf or from online services.
4. **Who and where?** A people directory (with ORCID), portraits (shared with the Author app), AI personality profiles, a gazetteer of places, a Locations list and a Map, and AI entity extraction.

Across the whole shelf, a fifth view, **Lineage**, draws every shelf book and every work their references name as one web through time. An imported **reference dataset** (the ACM Hypertext dataset) adds richer metadata to citation cards.

Design rules visible in the source:

- **No network at launch.** Retraction Watch and FORRT downloads happen only when the References page opens (`ReferencesScreen.body` `.task`), never at startup (memory note "No startup network prompts"; comment in `ReferenceStatus.swift`).
- **Everything is cached, misses included.** A failed lookup is remembered and retried only after a rest period, so nothing is asked twice in a reading.
- **Network failures are silent.** Every HTTP helper returns `nil` on any error or non-200 status. A card or mark never raises an error dialog.
- **The reader can overrule the indexes.** Any trust pill can be removed per work, and the removal holds in every document that cites that work.

---

## 2. The reference model

### 2.1 Where references come from

A document in memory is a `LiquidDoc` (see the document-model chapter). The two fields that matter here are:

| Field | Type | Meaning |
|---|---|---|
| `references` | `[LiquidDoc.Reference]` | External cited works (papers, books, web pages). |
| `links` | `[Link]` | Citations of *library* documents (Origami addresses). A link may carry its own `bibtex`. |
| `body` | `[Paragraph]` | Paragraphs. Each has `id`, `text`, optional `heading` level, optional `speaker`. |

`LiquidDoc.Reference` (`Origami Text macOS/LiquidDoc.swift`):

| Field | Type | Meaning |
|---|---|---|
| `id` | String | Stable citation key. The body's `[cite:<id>]` tokens point here. |
| `bibtex` | String | One verbatim BibTeX entry. This is the only carrier of the work's metadata. |
| `citedAs` | String? | The inline text the author wrote, e.g. "(Hegland 2025)". |
| `number` | Int? | Position in the source's numbered reference list. |
| `forms` | LanguageForms? | Title translations or transliterations (profile §9.5). |

**How references are parsed from an EPUB** (`Origami Text macOS/OrigamiEPUBImport.swift`):

- `citationPool(fromVisualMeta:)` reads the `citations` array of the package's `visual-meta.json` (properties `origami:visual-meta`). For each entry with an `id`:
  - If the entry carries an `abstract` beside its BibTeX, and the BibTeX has no `abstract` field, the abstract is folded into the BibTeX (`withAbstractField`).
  - If any `urls` entry is an Origami open URL, the citation becomes an *internal* citation (address → BibTeX). It is not added to `references`.
  - Otherwise it becomes a `Reference(id, bibtex, citedAs, number)`.
- `internalCitations(in:)` moves references that name an Origami document into links. The address is taken from, in order: `url` or `weburl` (when either is an Origami address), then `origami-source-id`, then `vm-id` (only when `vm-id` is not an ISO date).
- `citationPool(fromOrigamiJSON:)` handles Author's export (a UUID-keyed `references` dictionary) and an "academic EPUB" `blocks` array of `type: "reference"`. The result is sorted by `number`.
- **Inline citation tokens.** While converting XHTML to body text, an anchor with `data-citation-key`, or `epub:type`/`role` containing `biblioref` with an `href` ending `#bib-<key>`, becomes the token `[cite:<key>]`. An `href` of `#ref-…` is skipped, because numbered lists resolve by number. Adjacent anchors with the same key collapse into one token. The anchor's text is kept as `citedAs`, and `data-citation-number` as `number` (`citationKey(of:)`). An anchor `class="citation"` with `data-origami-ref` becomes `[<address>]`. With only `data-citation-id`, it becomes `[cite:<id>]`.
- A token may carry several keys: `[cite:a,b]`. Every consumer splits on commas and trims whitespace.

**The References page's document.** `AppModel.citationCardDoc(forBook:)` (`Origami Text macOS/AppModel.swift`) returns the structured reading doc if one exists. Otherwise it reads `visual-meta.json` (or Visual-Meta embedded in the content), builds a minimal `LiquidDoc` with an empty body, and fills only `references`. In that fallback the As Cited outline and the citation counts are empty.

### 2.2 The `ReferenceEntry` record

`ReferencesScreen.buildEntries(from:)` (`Origami Text macOS/ReferencesScreen.swift`) turns each reference into one `ReferenceEntry`:

| Field | How it is derived |
|---|---|
| `id` | `reference.id`, or `link.to` for an internal citation that has BibTeX. |
| `record` | First `BibTeXRecord` parsed from the BibTeX. |
| `title` | The record's title (TeX-cleaned). If empty, `citedAs`. If still empty, the `note` field. Else "Untitled". |
| `authors` | `BibTeXRecord.displayAuthors`: "First Last, First Last". BibTeX "Last, First" is flipped. |
| `familyKey` | First author (`author`, else `editor`, split on " and "): the text before the first comma, else the last word. Then case- and diacritic-folded. |
| `year` | The first 4 digits of the year field's digits. |
| `venue` | The first present of `journal`, `journaltitle`, `booktitle`, `publisher`. |
| `doi` | `ReferenceStatus.cleanDOI(fields["doi"])` (see 2.3). |
| `graphKey` | `CitationGraph.key(title: rawTitleField ?? citedAs ?? title, author: rawAuthorField)`. |
| `libraryID` | The shelf record matching by DOI, else by title key + year ±1 (`AppModel.libraryEPUBRecord`). Set to nil if it is the open book itself. |
| `entryType` | BibTeX entry type, e.g. "article" or "misc". |
| `isSelf` | True when any cited author key equals any of the paper's author keys (see below). |

**Deduplication.** Entries are deduplicated by `ReferenceStatus.normalizedTitle(title)`, or by `id` when the normalised title is empty. The first entry wins.

**Author keys** (`ReferencesScreen.authorKeys`). "Frode Hegland" and "Hegland, Frode" both become `"hegland f"`: the folded family name, a space, and the lowercase first initial. Family names of one character or less are skipped.

### 2.3 DOI and title normalisation

Several normalisers exist. A rebuild should unify them, but must keep each one's behaviour where it feeds a cache key:

| Function | Rule |
|---|---|
| `ReferenceStatus.cleanDOI` | Trim, lowercase. Strip the `https://doi.org/`, `http://doi.org/`, `https://dx.doi.org/`, `http://dx.doi.org/`, `doi.org/` and `doi:` prefixes. **Returns nil unless the result starts with `10.`** (Retraction Watch writes "unavailable"). |
| `ReferenceKeys.doiKey` (`ReferenceDatasets.swift`) | As above, plus the `https://dl.acm.org/doi/abs/`, `/doi/pdf/` and `/doi/` prefixes. Only the first matching prefix is stripped. Trailing `.,;)` characters are trimmed. No `10.` check. |
| `CitationLookup.normalizedDOI` | Strips `https://doi.org/`, `http://doi.org/`, `doi.org/`, `doi:` (case-insensitive), then lowercases. |
| `LineageGraph.normalizedDOI` | Same family of prefixes. No `10.` check. |
| `ReferenceStatus.normalizedTitle` | Fold case, diacritics and width (en_US_POSIX). Replace every non-letter, non-digit with a space. Collapse runs of spaces. |
| `ReferenceKeys.titleKey` | NFKD, drop combining marks, lowercase. Keep only ASCII a–z and 0–9. Any other run becomes one space. Trim. |
| `ReferenceKeys.nameKey` | Remove apostrophes and hyphens outright (O'Neill → oneill), then apply `titleKey`. |
| `LineageGraph.titleKey` | Fold case and diacritics, keep alphanumerics only, **no spaces**. |
| `CitationGraph.key(title:author:)` | `(title + "|" + author).lowercased()` with every space removed. **This is the citation graph's cache key. Keep it exact.** |

**Minimum lengths used for title matching.** A normalised title needs 12 or more characters to be used for matching at all. Substring (subtitle) matching needs 24 or more. Retraction Watch title lookups need 24 or more, because short titles such as "Editorial" or "Reply" would match anything.

### 2.4 Matching a cited work back onto the reference list

`ReferencesScreen.matcher()` builds one function: given a `CitedRef` (title, authors, year, doi), which of this paper's entries is it? The Map's lines and the citation card's "←" arrows both use it.

1. **DOI index.** Each entry is indexed under every DOI it has: its own DOI, any DOI found later by lookup (`foundDOIs`), and any DOI in the citation-graph cache. If the cited ref's cleaned DOI is in the index, return that entry.
2. Otherwise, normalise the cited title. If it is shorter than 12 characters, there is no match.
3. Try each entry whose normalised title has 12 or more characters, in entry order:
   - Skip the entry if both years are known and differ by more than 1.
   - **Match** if the titles are equal.
   - **Match** if the entry title has 24 or more characters and is contained in the cited title. This covers a subtitle on the cited side, and Crossref's "unstructured" whole-citation strings.
   - **Match** if the cited title has 24 or more characters and is contained in the entry title.
4. Otherwise, no match.

### 2.5 Counting citations in the text

`ReferencesScreen.citationCounts(in:)` applies the regex `\[cite:([^\]]+)\]` to every paragraph. Each comma-separated key adds 1. The count feeds the **Key** mark (3 or more) and the Time Map order "Cited Most in This Paper".

### 2.6 "As Cited" ordering

`ReferencesScreen.asCited(in:entries:)` builds a flat list of items. Each item is either `heading(text, level, id)` or `work(entryID, sectionID, occurrence, total)`.

```
sectionID = "start"; seenInSection = {}
for paragraph in body:
    if paragraph.heading != nil:
        emit heading(paragraph.text, level, paragraph.id)
        sectionID = paragraph.id; seenInSection = {}
        continue
    for each [cite:k1,k2,…] token, for each trimmed key in order:
        if key is a known entry id and key not in seenInSection:
            seenInSection.add(key); emit work(key, sectionID); cited.add(key)
uncited = entries not in cited (entry order)
if uncited non-empty: emit heading("Not Cited in the Text", 1, "uncited") then each uncited work
number each work's appearances: occurrence = 1,2,… in reading order; total = count
```

Rules:

- **All headings stay**, even those whose sections cite nothing, because the outline is the paper's own.
- Each work appears **once per section**, at its first mention there.
- Works cited before the first heading belong to the `start` section. The occurrence pop-up names that section "Before the First Heading".
- Display: heading size 19, 16 or 14 for levels ≤1, 2 and 3+. Headings are indented `(level-1)×16`. When `total > 1`, a bold ordinal ("1st", "2nd"…) sits left of the row. Hovering it opens a pop-up listing every section that cites the work, with this one in bold (`OccurrenceLabel`).
- **As Cited is the default listing.** It is stored under the preference key `referencesListing2`. The key was renamed so that an older stored choice would not hide the new default.

### 2.7 Other listings

`ReferencesScreen.sections`:

| Listing | Sort | Group headers shown |
|---|---|---|
| Title | `localizedStandardCompare` on title | none (the code groups by initial, but headers are drawn only for Date) |
| Author | `(familyKey, year)` | none |
| Date | year descending, then title ascending. Undated works last, as "No Date" | year headings, pinned |

**Row layout.** The title is size 16, and the byline below it is "authors · year · venue". In the Date listing the byline reads "year · authors · venue". In the Author listing the sizes swap: the names are large and primary, and the title is callout-sized and secondary. Below the byline sit the marks (section 4.2).

**Row actions.** A click opens the citation card. The context menu offers:

- Show Citation Card
- Open in Library (if `libraryID` is set)
- Open on the Web (the record's DOI URL, else its `url`)
- Read the Free Copy (Unpaywall's URL, if cached)
- Show Citation Tree
- Copy Citation (`“Title” (Authors, Year)`)

---

## 3. External services

All requests use the User-Agent `OrigamiText/1.0 (mailto:frode@hegland.com)`, except the Wikipedia, Wikimedia and ORCID calls, which have their own headers (see 5.x). Timeouts are 15–20 seconds for JSON calls, 60 seconds for FORRT and 120 seconds for Retraction Watch.

| Service | Endpoint | Purpose | Rate / caching | Failure behaviour |
|---|---|---|---|---|
| Retraction Watch (Crossref's GitLab mirror, CC0) | `GET https://gitlab.com/crossref/retraction-watch-data/-/raw/main/retraction_watch.csv` (~67 MB) | Offline retraction, concern, correction, withdrawal and reinstatement notices | Downloaded when References opens and the held copy is over 7 days old. Settings "Update Now" forces it. Folded index written to `RetractionWatch.json` | Non-200 sets `indexError` "could not be fetched". Zero records sets "could not be read". The status line shows the error. The old index stays. |
| FORRT FLoRA (replications, CC BY) | `GET https://raw.githubusercontent.com/forrtproject/FReD-data/main/output/flora.csv` | Replicated / Not Replicated / Mixed | Same weekly beat. `Replications.json` | Silent. The old index stays. |
| Crossref works | `GET https://api.crossref.org/works/{doi}` | `updated-by` notices, `type`/`subtype`, `relation.is-preprint-of`; abstracts (JATS) for cards; deposited `reference` arrays for the graph | Live status: once per DOI per 30 days. Card: cached forever, misses retried after 7 days | nil |
| Crossref search | `GET https://api.crossref.org/works?query.bibliographic={title author}&rows=3` | Card lookup when there is no DOI | as above | nil |
| DOI handle system | `GET https://doi.org/api/handles/{doi}` | Does the DOI exist? `responseCode` 1 means yes, 100 means no, anything else is unknown | Only when Crossref did not answer for the DOI | nil means unknown |
| DataCite | `GET https://api.datacite.org/dois/{doi}` | `attributes.types.resourceTypeGeneral` (Dataset, Software, Preprint…) | Only when the DOI resolves but is not a Crossref DOI | nil |
| Unpaywall | `GET https://api.unpaywall.org/v2/{doi}?email=frode@hegland.com` | `is_oa`, `best_oa_location.url_for_pdf` or `.url` | 30 days per DOI | nil |
| OpenCitations count | `GET https://api.opencitations.net/index/v2/citation-count/doi:{doi}` | "Cited N×" | 30 days per DOI | nil |
| OpenCitations references | `GET https://api.opencitations.net/index/v2/references/doi:{doi}` | DOIs the work cites (the `cited` field, its `doi:` token) | Part of the complete graph fetch | nil |
| OpenAlex percentile (**key required**) | `GET https://api.openalex.org/works/doi:{doi}?select=type,citation_normalized_percentile&api_key={key}` | Top 1% / Top 10% / type (review, dataset, preprint) | 30 days per DOI | Skipped without a key |
| OpenAlex work (key) | `GET …/works/doi:{doi}?api_key=…` or `…/works?filter=title.search:{title}&per-page=5&api_key=…` | Card abstract (inverted index), venue, OA URL | Card cache | nil |
| OpenAlex references (key) | `…/works/doi:{doi}?select=referenced_works,doi&api_key=…`, then `…/works?filter=openalex:W1|W2…&per-page=50&select=title,publication_year,doi,authorships` in batches of 50, at most 500 ids | Cited works list | Graph cache. One request per second | nil |
| Semantic Scholar | `GET https://api.semanticscholar.org/graph/v1/paper/DOI:{doi}?fields=title,abstract,tldr,venue,year,externalIds,openAccessPdf`, or `/paper/search?query=&limit=5&fields=…` | Card abstract, TL;DR, venue, OA PDF | Card cache | nil |
| Semantic Scholar references | `GET …/paper/{DOI:doi or paperId}/references?fields=title,authors,year,externalIds&limit=100&offset=n`, following `next`, at most 500 | Cited works list (also reads `citingPaperInfo.externalIds.DOI`) | Graph cache. One request per second | nil |
| ORCID public API | `GET https://pub.orcid.org/v3.0/expanded-search/?q=given-names:X AND family-name:Y&rows=10` (header `Accept: application/json`); `GET https://pub.orcid.org/v3.0/{id}/personal-details` | Person form search; name from an iD | Not cached | Thrown error shown in the form: "ORCID search failed: …" |
| Wikipedia (People photos) | `GET https://en.wikipedia.org/w/api.php?action=query&generator=search&gsrsearch={name}&gsrlimit=12&gsrnamespace=0&prop=pageimages&piprop=thumbnail&pithumbsize=600&format=json&formatversion=2` | Candidate photos | Not cached; the first 5 that download are shown | "Photograph search failed: …" |
| Wikipedia / Wikimedia Commons (Overview pictures) | `en.wikipedia.org/w/api.php` with `prop=pageimages|description|pageprops`, `ppprop=disambiguation`, `pithumbsize=120`; Commons `gsrnamespace=6`, `prop=imageinfo` | Portraits, logos, place photos | Index in the App Group (5.3). "Nothing found" retried after 30 days. Backoff on 429 or 5xx: 2, 4, 8 s (or `Retry-After`, capped at 60), 4 tries. 400 ms between lookups | A failed request records nothing, so it is retried next time |
| Apple geocoder | `CLGeocoder.geocodeAddressString` / `reverseGeocodeLocation` | Place coordinates and country | Once per place, ever. 400 ms between searches | Status `failed`, never asked again |

### 3.1 On-disk caches

All paths are under the user's Application Support folder.

| File | Writer | Shape |
|---|---|---|
| `EPUBs/RetractionWatch.json` | `ReferenceStatus` | `RetractionIndex {updated, records, byDOI: {doi: [Notice]}, byTitle: {normTitle: [{year, notice}]}}` |
| `EPUBs/Replications.json` | `ReferenceStatus` | `ReplicationIndex {updated, records, byDOI: {doi: {successful, failed, mixed}}}` |
| `EPUBs/ReferenceStatus.json` | `ReferenceStatus.persistLive` | `{doi: Live}` (2.x below) |
| `EPUBs/CitationLookups2.json` | `CitationLookup` | `{"doi:<doi>" or "title:<norm>": Enrichment}`. The "2" in the name marks the version that added the year check; the old file could hold another work's abstract. |
| `EPUBs/CitationGraph.json` | `CitationGraph` | `{graphKey: Entry}` with sorted keys. Mirrored to `<community folder>/origami-citation-graph.json` |
| `EPUBs/ReferenceDatasets/<uuid>/dataset.json` and `raw/*.json` | `ReferenceDatasetStore` | The dataset with ISO-8601 dates, plus the raw source files |
| `People.json` (+ `<community>/People.json`) | `PersonDirectory` | `[Person]`, pretty-printed, sorted keys |
| `PersonPortraits/<id>-original.png`, `<id>-portrait.png` | `PersonPortraitStore` | PNG |
| `AuthorProfiles.json` | `PersonProfileStore` | `[PersonProfile]` |
| `PlaceDirectory.json` | `PlaceDirectory` | `{key: Record}` |
| `Locations.json` | `LocationRecord` | `[Entry]` |
| `<community>/Localities.json` | the phone (read-only on the Mac) | `[Locality]` |
| `<community>/_document-extractions.json` | `AppModel.saveExtractionsFile` | `{extractions: {recordID: DocumentExtraction}}` |
| App Group `Library/Application Support/Overview Pictures/index.json` + images | `OverviewPictureStore` | `{"kind:name": OverviewPictureRecord}` |

**Preferences (key/value store)**:

| Key | Meaning |
|---|---|
| `referencesListing2` | Chosen listing |
| `referencesTimeMapOrder` | Time Map order |
| `referencesConceptView` | Concept Map view |
| `referencesMap:<bookID>` | Time Map card positions, `{entryID: [x, y]}` |
| `referencesConceptMap:<bookID>` | Concept Map card positions |
| `referenceMarksRemoved` | `{workKey: [markID]}` |
| `lookupCitedWorks` | Master switch, default true |
| `openAlexAPIKey` | OpenAlex key |
| `referencesRetractionWatch` | Toggle, default true |
| `referencesCrossrefNotices` | Toggle, default true |
| `referencesOpenAccess` | Toggle, default true |
| `referencesCitationCounts` | Toggle, default true |
| `referencesReplications` | Toggle, default true |
| `OverviewPictures*` | Overview picture settings |
| `interatlasAppPath`, `liquidAppPath` | Apps chosen to open scene links |

---

## 4. Features

### 4.1 The References page (shell)

**User-visible behaviour.** The word **References** sits at the right of the reader's foot bar (`OrigamiReadingView.swift`). It toggles `AppModel.readingReferencesOn`. Turning it on clears the other whole-page readings: Overview, analysis, find-fold and fold level. The page uses the reader's theme background and ink. A dark page is detected from the theme's own background, with luminance `0.2126R + 0.7152G + 0.0722B < 0.5`. Map lines are white on a dark page and black on a light one.

**Header.** "References", then the entry count, then a segmented picker: As Cited, Title, Author, Date, Time Map, Concept Map. The Time Map and Concept Map each add a **View** menu.

**Status line** (parts joined by " · "):

- A red count first, when any works are retracted, withdrawn or not replicated: "N cited works retracted, withdrawn or not replicated". It counts entries with any `alarm`-tone mark.
- Then one of: "Fetching the Retraction Watch database…", "Retraction Watch: N notices, updated <date>", or the index error.
- While running: "Checking i of n with Crossref, Unpaywall and OpenCitations".
- While running: "Reading the cited works' own reference lists — i of n". Otherwise, on a map: "Turn on Look up cited works online in Settings to draw the links", "None of these works is known to cite another", or "N lines: one work citing another".

**Background tasks.** These start when the page opens, keyed by book id, and are cancelled when it closes:

1. Build entries, citation counts, the As Cited outline and the citation structure. Mark the page loaded. Compute links. Load the Retraction Watch index from disk.
2. Refresh the Retraction Watch index if stale (7 days).
3. Load, then refresh if stale, the replications index.
4. **Live checks.** For each entry whose DOI `needsLive`, call `checkLive(doi)` in sequence, updating progress.
5. **Graph crawl** (only if `CitationGraph.isEnabled`). Take entries with no shelf copy and no complete graph entry. Sort DOI-bearing works first. For each entry:
   - If it has no DOI, find one through `CitationLookup.enrich(record)`.
   - Call `CitationGraph.completeReferences`.
   - Record any newly found DOI in `foundDOIs`, and run `checkLive` on it if needed.
   - Recompute links and bump `statusStamp`.

   The crawl runs whatever the listing, because the **Foundational** mark needs the same lines.

`statusStamp` is a redraw counter, bumped whenever an answer lands.

**Files.** `Origami Text macOS/ReferencesScreen.swift` (`ReferencesScreen`, `ReferencesMapView`, `ReferenceMarkView`, `OccurrenceLabel`), `Origami Text macOS/AppModel.swift` (`readingReferencesOn`, `citationCardDoc`), `Origami Text macOS/EPUBReaderView.swift` (hosts the page).

### 4.2 Marks (standing keywords)

`ReferenceStatus.marks(for: MarkInput)` (`Origami Text macOS/ReferenceStatus.swift`).

**`MarkInput` fields:**

- `doi` — resolved: the entry's own, else `foundDOIs`, else the graph cache's DOI
- `title`, `year`, `inLibrary`, `entryType`, `fields`
- `citedByNeighbours` — how many of this paper's other references cite it (inbound lines)
- `smallList` — fewer than 15 entries
- `citedInText`, `isSelfCitation`
- `notFound` — no DOI, a paper-shaped entry type (`article`, `inproceedings`, `conference`), and the card lookup's cached result has `found == false`

**Notices.** `notices(doi,title,year)` starts with the Retraction Watch index:

- By DOI first.
- Otherwise by normalised title (24 or more characters), keeping hits whose year is within ±1. A hit is also kept when either year is unknown.

Then Crossref's cached `updated-by` notices are added, unless the list already holds a notice of the same kind whose notice DOI is equal or missing on either side.

**Retraction Watch CSV folding** (`buildIndex`). Columns are found by header name:

- Required: `Title`, `OriginalPaperDOI`, `RetractionNature`.
- Optional: `RetractionDate`, `RetractionDOI`, `Reason`, `OriginalPaperDate`.

`RetractionNature` maps to kinds (case-insensitive): retraction, expression of concern, correction, reinstatement, and withdrawal/withdrawn. Rows of any other kind are dropped. Dates in the form "M/D/YYYY H:MM" become `YYYY-MM-DD`. Reasons are split on ";", stripped of "+" and rejoined with "; ". The parser follows RFC 4180 (quoted fields, doubled quotes, embedded newlines) and works on bytes for speed (`parseCSV`).

**Crossref `updated-by` kinds** (`crossrefNotices`):

| Crossref type | Kind |
|---|---|
| `retraction`, `partial_retraction`, `removal` | retraction |
| `expression_of_concern` | expression of concern |
| `withdrawal` | withdrawal |
| `correction`, `erratum`, `corrigendum`, `addendum` | correction |
| `reinstatement` | reinstatement |

A source of `retraction-watch` is labelled "Retraction Watch via Crossref".

**FORRT folding** (`buildReplications`). The required columns are `doi_o` and `outcome` (a UTF-8 BOM is stripped from header names). If a `type` column exists, only rows where `type == "replication"` count. The outcomes `successful`, `failed` and `mixed` are tallied.

**Live record (`Live`).** It holds:

- `notices`, `openAccessURL`, `isOpenAccess`, `citedBy`
- `fetched`
- `workType`, `workSubtype`, `hasPublishedVersion`
- `doiResolves`
- `inTop1Percent`, `inTop10Percent`, `openAlexType`
- `dataCiteType`
- `version`

The current `liveVersion` is 3. An entry with a different version is fetched again.

`checkLive` runs Crossref, Unpaywall, OpenCitations and OpenAlex concurrently. If Crossref answered, it sets `doiResolves = true`. Otherwise, if Crossref notices are enabled, it asks the DOI handle API, and DataCite when the DOI resolves.

**Mark order and rules.** There are five groups. Pills come first.

| # | Mark | Tone | Pill | Condition |
|---|---|---|---|---|
| 1 | Retracted / "Retracted, Reinstated" | alarm / caution if reinstated | yes | any retraction notice (reinstated if any reinstatement notice) |
| 1 | Withdrawn | alarm | yes | withdrawal notice |
| 1 | Expression of Concern | caution | yes | EoC notice |
| 1 | Corrected / "Corrected N×" | quiet | yes | correction notices |
| 1 | Replicated / Not Replicated / Replication Mixed | good / alarm / caution | yes | FORRT tally: no failed and no mixed → Replicated; no successful and no mixed → Not Replicated; else Mixed |
| 1 | Preprint | info | yes | preprint (below) and **not** `hasPublishedVersion` |
| 1 | Unverified | quiet | yes | `doiResolves == false` ("This DOI does not exist…"), else `notFound` |
| 2 | Foundational | positive | no | not discredited (no alarm mark) and (neighbours ≥3, or small list and neighbours ≥2) |
| 2 | Top 1% Cited / Top 10% Cited | positive / quiet | no | not discredited, OpenAlex flags |
| 2 | Classic | quiet | no | not discredited, age ≥25 years, and (top 10% or citedBy ≥1000) |
| 2 | Cited N× | quiet | no | counts on, citedBy > 0 (shown even when discredited) |
| 3 | kind word | quiet | no | `kind()` below |
| 4 | Key | quiet | no | citedInText ≥3 |
| 4 | Self | quiet | no | shares an author |
| 5 | In Library | positive | no | `libraryID` set |
| 5 | Open Access | quiet | no | Unpaywall `is_oa` |

**Preprint detection.** Any one of these is enough:

- Crossref subtype `preprint`, OpenAlex type `preprint`, or DataCite type `Preprint`.
- A DOI prefix in `10.48550/`, `10.1101/`, `10.31234/`, `10.31219/`, `10.31235/`, `10.21203/`, `10.20944/`, `10.2139/ssrn`.
- A `journal` containing "arxiv" or "preprint".
- `archiveprefix` or `eprinttype` equal to `arxiv`.

**Kind word** (first rule that matches):

1. A title containing "meta-analysis" or "meta analysis" → Meta-analysis.
2. OpenAlex type `review`, or a title containing "systematic review" or "literature review", or starting "a review of" or "a survey of", or containing "a survey on" → Review.
3. Crossref type:
   - `dataset` → Data
   - `book`, `monograph`, `edited-book`, `reference-book` → Book
   - `book-chapter`, `book-part`, `book-section` → Chapter
   - `dissertation` → Thesis
   - `report` → Report
   - `standard` → Standard
4. OpenAlex `dataset` → Data.
5. DataCite:
   - `Dataset` → Data
   - `Software` or `ComputationalNotebook` → Software
   - `Book` → Book
   - `BookChapter` → Chapter
   - `Dissertation` → Thesis
   - `Report` → Report
   - `Audiovisual` → Video
6. BibTeX entry type:
   - `dataset`/`data` → Data
   - `software` → Software
   - `book`/`mvbook` → Book
   - `inbook`/`incollection`/`bookinbook` → Chapter
   - `phdthesis`/`mastersthesis`/`thesis` → Thesis
   - `techreport`/`report` → Report
   - `online`/`electronic`/`www` → Web
   - `misc` with a `url` and no `journal`/`booktitle`/`publisher`/`howpublished` → Web

**Meaning and detail.** Every mark has a `detail`, the evidence shown as a tooltip ("source · date · reason"). It also has a `meaning`, a fixed explanatory sentence per mark (`meaning(of:input:)`) shown in the citation card.

**Removals.** Work keys are `[cleanDOI]` plus `"title:" + normalizedTitle` (only if 12 or more characters). Both are stored, so a removal holds whether a later document carries the DOI or only the title. A mark's id is its text, except that every "Corrected…" variant is "Corrected". The card's pill menu offers **Remove**. "Restore N removed marks" clears all removals for the work's keys. Visible marks are all marks minus the removed ids.

**Colours.** Tones map to these colours: alarm red, caution orange, info blue, good green, positive the accent colour, quiet grey. The exact colours come from `ProceedingsMapNode.color(for:)`. A pill is a capsule: text in the tone colour, fill at 12% opacity and stroke at 45%. Map cards show only the pills and positive-tone marks (`mapMarks`).

### 4.3 The Time Map

**Layout (`ReferencesMapView.seeds`).**

- Constants: margin 160, `yearColumnWidth` 172, rowHeight 64, top 150. The base canvas is 2400×1500. It grows to `maxX + 260` by `maxY + 200`.
- Each distinct year that has works gets one column. Column x starts at the margin. Each later column adds `172 + min(skippedYears, 4) × 12`, where skippedYears is the gap minus 1.
- Within a column, rows stack at `top + row × 64`. The order is the chosen ordering, else the seeded order (year, then title).
- Undated works form a last column at `lastColumnX + 172 + 30`, captioned "No Date".
- Year captions sit at `y = top − 60`.

**Orders (View menu):**

| Order | Sort within a year |
|---|---|
| As Arranged | No sort; the reader's own positions |
| Title | Title |
| First Author | (familyKey, title) |
| Most Cited | Live `citedBy`, descending |
| Cited by These References | Neighbour count, descending |
| Cited Most in This Paper | Text count, descending |
| Venue | Venue; an empty venue sorts last |
| Trust (warnings first) | Gravity: alarm 0, caution 1, any pill 2, else 3 |

Ties break by title in every order.

**Interaction.**

- Cards move **vertically only**. The stored position keeps the seeded x and the reader's y.
- Dragging while a computed order is shown switches the menu back to As Arranged. The arrangement becomes the reader's.
- A click lifts a card. Its lines brighten (opacity 0.85, width 2), other lines dim to 0.08, and unconnected cards dim. A resting line is 0.35 opacity at width 1.2. There are **no arrowheads**: the newer work always cites the older.
- A double-click opens the citation card.
- ⌘A selects all cards (except while a text view has focus). Dragging any selected card moves the others with it.
- A click on the empty plane clears the lift and the selection.
- Positions are saved per book under `referencesMap:<bookID>`. A sorted map re-sorts whenever `statusStamp` changes.

**Card.** The map reuses the journal Map's card, `ProceedingsMapNode`: title (two lines when standing), "authors · year", and marks. Its implementation is not in this chapter's files; see the Map chapter.

**Links (`recomputeLinks`).** For each entry, take its cited list from the first source that has one:

1. The shelf copy's own references (`libraryReferences`: each reference's BibTeX title or `citedAs`, display authors, year, DOI).
2. The graph cache entry, if `found`. Add its `citedDOIs` as DOI-only refs.
3. Otherwise skip the entry.

Each cited ref is passed through `matcher()`. A match that is not the entry itself gives the link `from: entry → to: match`. Links are kept as a sorted set. Neighbour counts are the inbound counts per `to`.

### 4.4 The Concept Map

This is the same plane with no year columns. Cards move freely. Positions are saved under `referencesConceptMap:<bookID>`. If the reader has not yet moved any card, the map re-gathers itself whenever the links change.

**Views and their layouts:**

| View | Layout | Input |
|---|---|---|
| As Arranged | `conceptSeeds` = force layout on the citation links, weight 1, overlaid by the stored positions | links |
| Citation Network | force | links, weight 1 |
| Shared References | force | bibliographic coupling edges (below) |
| Cited Together | force | pair counts of works cited in the same paragraph |
| By Section | groups | heading (level ≤2, with leading "2.1 " numbering stripped) over each work's first citation. Default "Before the First Heading"; uncited works "Not Cited in the Text" |
| By Author | groups | each work goes under its author who recurs most in the list (count ≥2; ties broken by name). Otherwise "Single Appearances", or "No Author". The name "others" is ignored |
| By Venue | groups | venue if it appears ≥2 times, else "Other Venues"; empty venue "No Venue" |
| Core & Periphery | radial | degree (in + out links) |

**Force layout (`forceLayout`).** It is deterministic: the same list always opens the same way.

```
centre = (1200, 750); R = 0.38 * min(2400,1500)
initial: node i at angle i/n * 2π on circle R
spring = 230; push = 60000
repeat 300 rounds, step = 0.9*(1 - round/300) + 0.05:
  for each unordered pair (a,b): d² = max(dx²+dy², 100); f = push/d²; push a away from b by f, b away by f
  for each edge (from,to,w): d = max(|pb-pa|,1); rest = spring/√max(w,1); pull = (d-rest)*0.05*min(w,4); move from toward to and to toward from by pull
  for each node: p += (move + (centre-p)*0.01) * step
                 clamp x to [160, 2240], y to [110, 1420]
```

**Bibliographic coupling (`sharedReferenceEdges`).**

1. For each entry, build its set of cited works: from the shelf copy or the graph cache, using DOIs where known and `"t:" + normalizedTitle` (12 or more characters) otherwise. Add the graph's `citedDOIs`.
2. For each pair of entries sharing **2 or more** works, compute Jaccard = shared ÷ union.
3. The edge weight is `1 + jaccard × 8`.

**Cited Together (`citationStructure`).** For each paragraph, take the distinct sorted keys of its `[cite:]` tokens. Every unordered pair of keys adds 1 to that pair's count. The count is the edge weight.

**Group layout (`groupLayout`).**

- Groups are ordered largest first. Catch-all groups always go last: "Single Appearances", "Other Venues", "No Venue", "No Author", "Not Cited in the Text", "Other". Ties break by name.
- Inside a group, works are sorted by title and laid out in columns of 8 cards (column width 185, row height 64). The caption sits at `(x + 100, y − 44)`.
- Group blocks run left to right, 70 apart. A block wraps to a new row when it would pass `2400 − 80`; the new row starts at `rowHeight + 30` below.

**Radial layout (`radialLayout`).**

- Centre `(1200, 810)`. Works are ranked by score, then by title.
- Ring 0 holds 1 work. Ring k holds `7k` works at radius `210k`.
- Angle = `(slot ÷ count + ring × 0.13) × 2π`. The x offset is stretched by ×1.25.

**After any computed layout**, the whole plane is shifted right and down so that no card sits above `top` or left of `margin`, because the plane scrolls only right and down. A hand move on a computed view switches the menu back to As Arranged.

### 4.5 The citation card's dataset and graph sections

The card itself, `CitationCardSheet` (`Origami Text macOS/OrigamiReadingView.swift`), belongs to the reader chapter. The parts this chapter feeds:

- **Abstract.** Shown from the record's own `abstract` field when it has one. Otherwise from `CitationLookup.cached`, else from `CitationLookup.enrich` (4.6).
- **Marks with meanings**, with Remove and Restore (4.2).
- **Dataset section.** It appears only when `ReferenceDatasetStore.lookup` matches; absence is silence (4.7).
- **"Cites N works"**: the `CitationGraph` entry, from the cache or from the "What does this work cite?" button (`CitationGraph.references`). Rows that match one of this paper's references (`siblingKey`) carry a "←" arrow that opens that card.
- **View as Tree**: sets `AppModel.citationTreeTarget` and switches the sidebar to the `citation-tree` view (4.9).

### 4.6 Card enrichment (`CitationLookup`)

`Origami Text macOS/CitationLookup.swift`.

**Cache key.** `"doi:" + normalizedDOI`, else `"title:" + OrigamiReading.normalize(title)`. If the record has neither, there is no lookup.

**Algorithm (`enrich`):**

1. Lookups must be enabled.
2. A cached hit is returned as is. A cached miss younger than 7 days is also returned (and not retried).
3. If an OpenAlex key exists, ask OpenAlex first.
4. If there is still no abstract, ask Crossref. Merge.
5. If there is still no abstract, ask Semantic Scholar, using the DOI or a DOI found so far. Merge.
6. Store the result, or the miss `{found: false}`, with `fetched = now`.

**Merge rule.** The first answer keeps every field it filled. The second fills only the gaps. The `source` follows whichever service supplied the abstract.

**Title search sanity checks.** The normalised titles must be equal, or one must be a prefix of the other. The years must agree within ±1. When either year is unknown, the title alone must carry the match. The year check exists because same-titled works abound, and a mismatch puts someone else's abstract on the card.

**Text repair:**

- `strippedJATS`: remove tags, decode six entities, collapse whitespace, drop a leading "Abstract " or "Summary ".
- `reconstructedAbstract`: rebuild OpenAlex's inverted index into text, ordered by word position.
- `tidiedAbstract`: fix spaces lost at line breaks. `([a-z0-9])([.!?])([A-Z])` becomes "$1$2 $3", and `([A-Za-z])([,;:])([A-Za-z])` becomes "$1$2 $3". Acronyms and numbers are left alone.

### 4.7 Reference datasets (ACM Hypertext)

`Origami Text macOS/ReferenceDatasets.swift`.

**Import.**

1. The user chooses JSON files.
2. Each file must be a top-level array of flat objects. Values are coerced to strings; numbers are allowed.
3. The format is detected **by content, never by filename**:
   - A **nodes** file's first object has `ID`, `Label` and `DOI URL`.
   - An **edges** file's first object has `SOURCE`, `TARGET` and `LINKTYPE`.
4. Edges alone throw "Import the nodes file together with the edges file."
5. A new import replaces any earlier import of the same format. The new dataset is written fully before the old one is deleted, so a failed import keeps the old data. Re-import keeps the user's renamed name, edited record-URL template and enabled toggle.
6. The version label is the first 4-digit run in a filename starting 19 or 20 (e.g. "2026"), else the current year.
7. Raw files are copied to `raw/`. When `parserVersion` is lower than the format's `currentParserVersion` (currently 1), the dataset is re-normalised from those copies on the next load.

**Node → `ReferenceRecord`:**

| Record field | Source |
|---|---|
| `id` | `ID` |
| `title` | `Label`, HTML-entity-decoded. This includes the malformed `&153;`, read as a Windows-1252 code (™) |
| `authors` | `Author Names`, split on commas. A bare `Jr.`, `Sr.`, `II`, `III` or `IV` rejoins the previous name |
| `authorsShort` | `Authors` |
| `firstAuthor` | The first parsed author |
| `firstAuthorAlternate` | `First Author`, only when it differs from the first parsed author |
| `year` | `Conference Year` |
| `venueName` | `Conference Proceedings` |
| `venueTheme` | `Conference Title` |
| `venueAbbreviation` | `Conference Abbreviation`, normalised (`ECHT94` → `ECHT '94`; anything else passes through) |
| `type` | `Article Type` |
| `isPaper` | `Is Paper == "true"` |
| `doi` | `doiKey(DOI URL)` |
| `url` | `DOI URL` |
| `pdfURL` | `DOI URL` with `/doi/` replaced by `/doi/pdf/` |
| `keywords` | `Keywords`, split on ";" |
| `abstract` | `Abstract` |
| `totalReferences` | `Total References` |
| `extra` | Unknown columns, verbatim |

The file's own in-conference counts are stale and **never imported**. `cites` and `citedBy` are recomputed from the edges:

- Only `LINKTYPE == "cites"` rows count.
- Self-loops are counted and skipped.
- A source that is not in the export counts as unresolved.
- A target that is not in the export adds 1 to the source's `unresolvedCites` and is dropped.

**Indexes** (enabled datasets only, rebuilt on every change):

- `byDOI` — first import wins.
- `byTitleKey`.
- `byShortTitleKey` — the title before its first ":", when that differs from the full key.
- `bySurnameYear` — `"surname|year"` from the first author and the alternate.
- `byYear`.

**Lookup tiers (`lookup`)** stop at the first tier that answers. There is never a match on author or year alone:

1. DOI → **exact** ("DOI").
2. Full title key with year ±1 and the first-author surname among the record's authors → **strong** ("Title + year").
3. (Tier 4 in the code's numbering) Full title key alone → **probable** ("Title (year or author differs)").
4. Short-title key, only when the query has both a year and a surname, both compatible → **strong** ("Short title + year").
5. Fuzzy match. A year is required. The candidate pool is the surname-and-year buckets for year ±1, or all works of year ±1 when there is no surname. Score by normalised Levenshtein similarity of title keys. The best score must lead the second by at least 0.05 (otherwise there is no match). A score of 0.92 or more → **probable**. A score of 0.85 or more → **possible**. The reason reads "Title (fuzzy 0.94)".

**Tie order.** `isPaper` first, then has a DOI, then earliest year. The other matches are kept as `alternates`.

**Card section (`ReferenceDatasetCardSection`).** It shows:

- A provenance chip "name · version". "Matched by title" for strong. "Probable match — check" or "Possible match — check" in orange.
- The record count when there are alternates.
- Title, authors, "abbreviation · year · type", and the theme.
- The abstract, three lines with More/Less (expanded height capped at 220).
- Keywords.
- "Cited by N Hypertext papers · Cites M (+K not in this export)".
- Buttons: Open (when the work is on the shelf), ACM Digital Library, PDF, Dataset page (the `recordURLTemplate` with `{id}` replaced), Copy Citation.
- The licence line "Data: Mark W. R. Anderson, ACM HT Proceedings dataset · CC BY-NC-SA 4.0".

**Series authors (`SeriesAuthorRank.ranked`).** This folds author spellings into people across the papers. The Map uses it to name the person behind a byline.

1. Parse each name: fold it, split it into letter tokens, and drop trailing suffixes (`jr`, `sr`, `ii`, `iii`, `iv`). The last token is the surname. Preceding particles (`de`, `van`, `von`, …) join it, with no spaces. The remaining tokens, minus particles, are the given names. A name with fewer than 2 tokens is ignored.
2. Within each surname bucket, sort the raw spellings. Each spelling joins the first cluster holding a compatible spelling; otherwise it starts a new cluster.
   - **Compatible**: the first given names match through the nickname table (sigi→siegfried, bob→robert, bill→william, ted→edward, peggy→margaret, jamie→james). Or one is an initial matching the other's first letter. Or they share their first three letters.
   - In addition, the middle-initial sets must be subset-related. "Kenneth M." and "Kenneth T." stay two people.
3. A paper counts each person once.
4. The display name is the spelling seen most often; ties go to more words, then to the longer string.
5. People are ranked by paper count, then by name.

### 4.8 "Cited here" margin marks

`Origami Text macOS/CitedHere.swift`, `AppModel.citedHere(inBook:)`.

**What it finds.** Every passage elsewhere in the library that cites a paragraph of this book.

**The book's identities.** The record's `id`, `packageIdentifier`, `doi` and `folder`, lowercased.

**The scan.** It runs off the main thread, once per book folder and library revision. For each other document (the book's own id is skipped), and for each paragraph that contains "#":

- Markdown links `](origamitext://open/…)` or `](https://origamitext.app/o/…)`. The web carrier is rewritten to the `origamitext://open/` form and parsed with `parseOrigamiURL`. Only links that have a fragment count.
- Tokens `[address#fragment]`. A leading `rel:` prefix (one of the `DocumentRelation` raw values) is taken as the relation. Any other prefix, such as `urn:uuid:`, is part of the address.

A hit whose address is one of the book's identities is filed under the bare fragment (the part after the last "#"). Its snippet is the paragraph's readable words (`readableWords`: link text kept; cite, note and address tokens and emphasis marks removed), truncated to 220 characters with "…".

**Display.** The paragraph gets a margin button labelled with a quote-bubble icon and the count. It opens a list headed "Cited in N places in your library", with each entry's title, relation (when not "cites") and four lines of snippet. A click opens the citing passage: a shelf book at its paragraph, otherwise the community document.

**Declared relationships (`declaredRelationships`).** These are gathered from:

- `visual-meta.json` `links` entries that have a `toEdition`.
- The text's typed links where `rel != "cites"`.
- The edition info: "replaces" and "is replaced by".

Duplicates are removed by `rel|target|targetAddress|fromAddress`.

**`DocumentRelation`** (`Origami Text macOS/DocumentRelation.swift`) is the discourse vocabulary: `cites`, `responds-to`, `extends`, `supports`, `questions`, `disagrees-with`, `summarizes`, `revises`, `retracts`. Each case has a menu title, a title prefix, a byline label and a Visual-Meta field. `revises` writes `supersedes`, and `cites` writes none. See ORIGAMI-TEXT-OVERVIEW.md.

### 4.9 The Citation Tree view

`Origami Text macOS/CitationTreeView.swift`. This is a library view module, `id "citation-tree"`, named "Citation Tree". It has three parts:

- **Root card**: title, then "author · year".
- **"In your library"**: every library document with a reference that matches the target. When both sides have a DOI, the lowercased DOIs must be equal. Otherwise the **lowercased raw title** must be equal. Sorted by date, newest first.
- **"What this work cites"**: the cached graph entry. If there is none and lookups are on, it is fetched with `CitationGraph.references` (first service that answers). The section says "via <source>". If the fetch returned nothing, a "Fetch references" button retries. There are also messages for a list that does not exist and for lookups switched off.

### 4.10 Figure links to Interatlas and Liquid

`Origami Text macOS/InteratlasCitation.swift`. This is a port from Knowledge Space and Augmented Library; keep the files in step.

**Recognition is by host alone.** The format's rule is never to parse deeper just to recognise a link.

- **Interatlas Link**: an https URL whose host is `link.augmentedtext.com` or `link.interatlas.example`. The path is `/v1/<realm>`, and the query holds the whole view state.
- **Liquid view link**: the same hosts, with a path starting `/liquid/`. Test for this first, because it shares the domain.

**Scheme forms.** Only the scheme is swapped, by string surgery: everything after the first ":" is untouched. The URL is never round-tripped through a URL parser, because re-encoding would break the `scene` payload.

| Link kind | Scheme forms, in order |
|---|---|
| Interatlas | `interatlas://…` |
| Liquid | `liquidinfo://…`, then `liquid://…` |

**Scene payload.**

- `scene=` in the query holds base64url text. Decoding: base64url → DEFLATE → UTF-8 JSON. The decoder tries a raw DEFLATE stream first, then skips a 2-byte zlib header. A result counts only when its first non-space character is "{". Any failure means "no scene".
- To encode: raw DEFLATE, then base64url with no padding. Append `?scene=` or `&scene=`, but only if the URL has no scene yet and the payload is **8000 characters or fewer** (`scenePayloadCeiling`).
- A scene that is too large is written to a temporary `<name>.liquidinfo` file. That file is opened with the chosen app, else with the system handler, else revealed in the Finder with a status note (`AppModel.openLiquidScene`).

**PNG citation (`PNGCitation`).** The reader walks the PNG chunks directly (signature, then length / type / body / CRC):

- The `iTXt` chunk with keyword `visual-meta` (uncompressed only), or `tEXt` with that keyword, holds BibTeX. If neither exists, the XMP packet (`XML:com.adobe.xmp`) is used as a fallback.
- The `liquid-scene` iTXt chunk holds the scene JSON.
- Anything malformed returns nil, never an error.

**Opening ladder (`AppModel.openSceneLink`).**

- **If the user chose an app** (`interatlasAppPath` / `liquidAppPath`): give it a scheme form it claims, else the https link if it claims that. Otherwise copy the link to the clipboard, bring the app forward and show a note ("Interatlas can’t receive links yet — the scene link is on the clipboard…").
- **Without a chosen app**: try each scheme form whose handler exists, then the https URL through the system. If all fail, copy to the clipboard with a note.
- `openFigureLink` tries Liquid first, then Interatlas, then the system.

**Figure citation fallback (`imageCitation(after:in:)`).**

1. The nearest `[cite:]` token in the two paragraphs after the image.
2. Otherwise, if exactly one reference has an Interatlas `url`, use it. Never guess between several.

`scene-resource` in the BibTeX, or `<sceneID>.liquidinfo.json`, names a packaged scene asset. The packaged scene takes precedence over the PNG chunk.

---

## 5. People, places and venues

### 5.1 Person record and directory

`Origami Text macOS/People.swift`.

**`Person` fields:**

| Field | Type | Notes |
|---|---|---|
| `givenName`, `middleName`, `familyName` | String | Name parts |
| `affiliation` | String | |
| `orcid` | String | Canonical identity when present |
| `creditName` | String | From ORCID |
| `otherNames` | [String] | From ORCID |
| `emails` | [String] | |
| `publicProfile` | String? | The person's bio in their own words |
| `letterDistribution` | Bool? | nil means included in the letter post |
| `aliases` | [String]? | Other spellings, e.g. a transcript's rendering |
| `localID` | String | UUID |

Derived values:

- `id` = `orcid` if it is non-empty, else `localID`.
- `displayName` = the non-empty name parts joined by spaces.
- `init(displayName:)`: the first word is the given name, the last word the family name, and the words between are the middle name.

**Directory rules (`PersonDirectory`):**

- **Two copies**: the app container's `People.json` and the community folder's `People.json`. `attach(folder:)` adds records from the folder that are missing locally (local records win any conflict), then writes the merged list to both copies. A failed write to the community folder sets `communityWriteFailed`. The user must re-choose the folder to renew write access.
- **`upsert`**: replace by ORCID, else by case-insensitive display name, else append.
- **`person(named:)`**: an exact display-name match first, so an alias can never hide a real name; then aliases.
- **`merged(absorbing:)`**: this record leads. The other record fills empty fields. Emails and other names are united case-insensitively. The other's display name and aliases become aliases.
- **`associate(alias:)`**: appends the alias, unless the person already answers to it.

**ORCID adoption (`PersonFormView.adopt(_ result:)`).** Copies given and family names when present, plus the iD, credit name, other names and emails. Takes the first institution as the affiliation, only when the affiliation is empty.

**Contacts import** (only when compiled with `ORIGAMI_CONTACTS`). Read-only. Copies name parts, merges emails, sets the affiliation if empty, and sends the card's photo to the portrait pipeline.

### 5.2 Portraits

`Origami Text macOS/PersonPortraits.swift` (`PersonPortraitStore`).

**Files.** `PersonPortraits/<localID>-original.png` holds the user's photo, kept untouched. `<localID>-portrait.png` holds the drawn cartoon. Portraits are keyed by `localID`, which never changes, even when an ORCID is adopted later. The characters "/" and ":" in ids are replaced with "_".

**Pipeline:**

1. **Adopt the photo.** Write the original. Delete any old portrait. Warm the framed rendition.
2. **Headshot framing (`headshotFrame`).**
   - Detect faces and take the largest.
   - Crop a square of side `2.6 × faceHeight`, centred at `(face.midX, face.midY + 0.15 × faceHeight)` in bottom-left coordinates.
   - Fill outside the photo with grey 0.8.
   - With no face found, use the photo as is.
3. **Stylise.** Apple Image Playground (`ImageCreator`), with concepts `[image(framed), text(concept)]`, style `animation`, `illustration` (default) or `sketch`, limit 1.
   - The default concept is "Headshot, professional portrait for publication of this academic person with a neutral grey background". It can be edited in Settings.
   - If headless creation reports `notSupported`, the form falls back to the system Image Playground sheet. Only the configured style is offered there.
4. **Restyle all.** Re-draw every portrait from its original after a style change, with progress shown.
5. **Bot portraits.** Always illustration, using the bot concept (monochrome, dark grey background). Finish: a mono filter, then the foreground mask over RGB (0.16, 0.16, 0.17). Specific errors are shown for unusable images and faces that are too small.

**Avatar (`PersonAvatarView`).** Shows the portrait, else the original, else initials (the first letters of the first and last words) on a rounded square.

**Hover card (`PersonHoverCard`).** Shows the avatar, name, affiliation, ORCID, emails, public profile and personality (5.4). Below that, up to 6 "Letters": library documents whose credited author equals the display name, newest first, then "and N more".

**Photo search (`PhotoSearchSheet`).**

1. Use the name. If the form has only an ORCID iD, get the name from ORCID's personal-details.
2. Ask Wikipedia for up to 12 pages with thumbnails, in search order.
3. Show the first 5 that download. A click adopts the photo, and processing starts once the sheet has closed.

### 5.3 Sharing pictures with the Author app (App Group)

`Origami Text macOS/OverviewPictures.swift` (`OverviewPictureStore`). This is ported from Author; keep the two in step.

**Location.**

- App Group `9Q5N4A727S.com.liquid.author.shared`, at `<group container>/Library/Application Support/Overview Pictures/`.
- If the group container is unavailable, the app uses its own Application Support `Overview Pictures`.
- An old local store is merged into the shared one record by record, then deleted (`moveLegacyStore`).

**Index.** `index.json`, keyed by `"<kind>:<lowercased name>"`, where kind is `person`, `place`, `organization` or `concept`. Each `OverviewPictureRecord` holds:

- `title` — nil means nothing safe was found
- `summary`, `file`, `fetched`, `name`, `kind`
- `source` — `wikipedia`, `commons`, `user` or `people`
- `pageURL`
- `deleted`

**Two apps, one file.**

- On every save, the app first re-reads the index on disk and merges it with `preferred(a,b)`:
  - If either record is deleted, the newer one wins.
  - A found picture beats "nothing found".
  - Otherwise the newer one wins.
- `refreshFromDisk` takes in the other app's writes, using the file's modification date.
- A miss is retried after 30 days. Images found by lookup are named by the first 10 bytes of SHA-256 of the key, as hex. Images the user chose get a fresh UUID name each time.

**People come first** (`AppModel.connectOverviewPortraits`):

- `ownPicture` returns the People photo (original, else portrait) for any person the directory knows, by name or alias. Such a person is never looked up on Wikipedia. "A namesake's face on a colleague is the one mistake to avoid."
- `onChosen`: a picture chosen in Overview's Pictures window for a known person becomes their People photo (`adoptPhoto`).

**Square framing (`framedForSquare`).** A picture more than 3% away from square is placed centred on a square of `1.1 × its long side`. The margin is filled with the average colour of the outer 2-pixel ring, or transparent if that ring averages alpha ≤0.5. EXIF orientation is applied. Square pictures are kept as they came.

**Name finding (`OverviewEntities.find`).**

- Apple NaturalLanguage name tagging with joined names: personal, place and organisation names. The book's concepts are added.
- A name is accepted only if it has 3 or more characters, starts with a capital, and is not in an ignore list ("geez", "god", "mom"…). A person also needs two or more words.
- With 4 or more sections, names appearing in more than half the sections are dropped (for example, an interview's speakers).

**Wikipedia acceptance (`OverviewMatcher.accepts`).** A result is rejected if:

- it is a disambiguation page, or has no thumbnail;
- its description names a medium ("novel", "film", "album"…), unless the entity is a concept;
- its title has a qualifier ("Portland, Oregon" or "Washington (state)") whose capitalised words are not all present in the document.

Then by kind:

- **Person**: the family names must be equal. Every other query word must match a title word exactly, or by prefix in either direction for words of 3 or more characters ("Doug" → "Douglas"). The title may have at most one extra word.
- **Place, organisation, concept**: the words must be equal. Or a query of 2–6 upper-case characters must equal the initials of the title's non-minor words ("NACA"). Or, for an organisation, the title may be the query plus one trailing word ("SRI International").

### 5.4 Personality profiles (AI, through `OrigamiLLM`)

`Origami Text macOS/PersonProfiles.swift` (`PersonProfileStore`).

**When it runs.** `digest(entries:)` runs whenever the library index changes (`AppModel.swift` around line 6410). It requires the profile setting (on by default) and an available Apple system language model.

**What it reads.**

- For each document: the body paragraphs, minus Visual-Meta appendix paragraphs and empty text.
- Paragraphs with no speaker go to the credited author. Paragraphs with a speaker go to that speaker.
- Names are unified case-insensitively, keeping the first spelling seen.
- A document is digested once per person (`digestedDocIDs`).

**The prompt.** The base prompt, which can be edited in Settings → AI. Then "THE PERSON", "EXISTING PROFILE" (or "None yet — this is the first letter."), and "THEIR NEW WRITING". The contributions are given oldest first. Each is capped at 1200 characters, with a total cap of 8000 per person.

**The answer.** `OrigamiLLM.generate(GeneratedAuthorProfile.self, …)` returns `GeneratedAuthorProfile {profile, interests}`: guided generation on Apple's model, or the type's JSON Schema on a chosen server. `digest` runs only when `OrigamiLLM.shared.canRespond`. On any error, the documents stay undigested and are retried on the next pass.

**Where it shows.** `personality(for:)` is the hook for views, for example the hover card.

### 5.5 Entity extraction (bulk, per venue)

`Origami Text macOS/EntityExtraction.swift` (`EntityExtractor`), triggered by `AppModel.extractEntities(inPublication:force:)`.

**Chunking (`chunks`).**

- Paragraphs are packed into chunks of at most 6500 characters, separated by "\n\n".
- A paragraph over the budget is cut at the last `.!?` or newline before the limit.
- If the model reports a context overflow, the chunk is split in half at a sentence seam and each half is retried once. Chunks of 800 characters or fewer are not split.

**Model choice.**

- Each chunk is one fresh request through `OrigamiLLM.generate(PassageExtraction.self, …)` (`EntityExtractor.extractChunk`). `PassageExtraction` has the fields `concepts`, `keywords`, `people`, `places`, `technologies` and `scientificTerms`, with a maximum count per field of 6 or 8.
- With an endpoint model selected, the server gets that type's JSON Schema and its reply is read back into the same type. Apple's model is used only when no endpoint is selected, or when the server or model is missing.
- A guardrail refusal skips the chunk. A half of a split chunk that still overflows, or is refused, is skipped too. Other errors are thrown.

**Merging.**

- Items are trimmed and kept if they are 2–60 characters long.
- They are counted case-insensitively, keeping the first casing seen.
- Each category is sorted by count, then by name, and capped at 20.
- People matching the paper's own byline are removed.

**Storage.** The result is stored per record id in `<community>/_document-extractions.json`, written after each document.

**Use.** The Threads venue view (5.7).

### 5.6 Places

**Gazetteer (`PlaceDirectory`).** The format stores **place names, never coordinates**. Each distinct place (keyed by trimmed, lowercased text) is geocoded once, ever. A record holds `id`, `place`, `latitude`, `longitude`, `locality`, `country` and `status`. The status is one of:

| Status | Meaning |
|---|---|
| `pending` | Found; waiting for the reader to confirm |
| `verified` | Confirmed, or self-evident from the text |
| `rejected` | The reader said the search got it wrong |
| `failed` | Nothing found; never asked again |

A found place whose text contains a comma (it names its own country) is verified automatically. Searches run one at a time, 400 ms apart.

**Map (`PlacesView`, module `id "places"`, name "Map").**

- Shows a pin for each place that has coordinates and is not rejected. The pin shows the document count, in orange while pending.
- The pin label is the Home or Work label (`AppLocations.label`), else the first comma-separated part of the place.
- A "Confirm Places" card offers **Confirm** and **Not This** for pending records, with text such as "Found in <country>, near <locality>."

**Current place (`PlaceFinder` in `LocationView.swift`).**

- Accuracy 100 m. The permission prompt appears only from a deliberate act: `promptIfNeeded` defaults to true, but quiet refreshes pass false.
- The location is reverse-geocoded to "subLocality, locality, country". If that is empty, the place name or administrative area is used.

**Locations record (`LocationRecord`).**

- Every place any document has carried, with `firstUsed` and `lastUsed` dates, sorted by most recent use.
- Kept even after the documents move on.
- The **Locations** view (module `id "location"`) lists each place with its current documents, newest first. A place with none shows "Nothing here now — the place is remembered."

**Localities (`LocalityDirectory`).**

- Read-only on the Mac. Comes from `<community>/Localities.json`, which the phone publishes.
- Each entry holds `{id, name (nickname), latitude, longitude, tail}`. Its `stamp` is "name, tail".
- Looked up by nickname, case-insensitively.

### 5.7 Venue relation views

`Origami Text macOS/VenueViews.swift`. The engine is `VenueRelations.analyze`, a pure function run off the main thread.

**Work key.** `"doi:" + DOI` (lowercased, `https://doi.org/` removed), else `"title:" + title` (lowercased, alphanumerics only).

**Couplings.** Every pair of papers sharing one or more works.

**Seriation (nearest-neighbour chain):**

1. Start with the paper of largest total coupling weight.
2. Repeatedly take the remaining paper most strongly coupled to the last one placed. Ties go to the larger total.

**Canon.** Works cited by 2 or more papers, sorted by count, then year.

**Year spectrum.** Counts per year, for years in 1401–2100.

**Picker.** The current picker offers only **Articles** and **Map**. Shared Ground, Roots and Threads are "parked": the code exists but they are not in `allCases`.

| Parked view | What it does |
|---|---|
| Shared Ground | Arc diagram. Draw threshold = the smallest of 1…6 that leaves 240 or fewer pairs, else 7 |
| Roots | Reference Publication Year Spectroscopy, plus the canon (top 40) |
| Threads | AI topics (shared by 2 or more papers), else title words longer than 3 letters and not stop words, shared by 2 or more. Also sections from entity extraction |

---

## 6. Lineage and citation-graph algorithms

### 6.1 `CitationGraph` (second-order references)

`Origami Text macOS/CitationGraph.swift`.

**`Entry` fields:**

- `doi`
- `references: [CitedRef{title, authors, year, doi}]`
- `source` — e.g. "Semantic Scholar + Crossref + OpenCitations"
- `fetched`
- `found` — false is a remembered miss
- `complete` — every service was asked
- `citedDOIs` — DOI-only refs from OpenCitations

**Politeness.** At most one request per second across all callers (`politePause`).

**`references(...)`** (first answer; used by the card and the tree):

1. A found cache entry is returned.
2. A miss younger than 7 days is returned.
3. Otherwise ask Semantic Scholar, then OpenAlex (with key), then Crossref (DOI only), and keep the first that answers.
4. Store the answer, or the miss.

**`completeReferences(...)`** (all services folded; used by the References maps):

1. Return the cache if `isComplete`: `complete == true` and fetched within 30 days (3 days if not found). Misses are asked again whatever their age, "the reader asked".
2. Ask Semantic Scholar and OpenAlex. Then ask Crossref with the DOI, or with the first DOI the earlier answers found.
3. Fold **across** services, never within one, because Crossref may list distinct "Proc. …" volumes under one name:
   - A reference with a DOI is skipped if that DOI was already seen.
   - Otherwise it is skipped if its `normalize(title)|year` key has 24 or more characters and was seen in an *earlier* service's list.
4. OpenCitations references by DOI, minus DOIs already seen, become `citedDOIs`.
5. `found` = any references or any cited DOIs.

**Provider specifics:**

- **Semantic Scholar**: by `DOI:<doi>`, else a title search (5 results; title prefix-match plus year ±1 → `paperId`). Pages of 100 up to 500. Authors: more than 4 become "first three et al.".
- **OpenAlex**: up to 500 `referenced_works`, resolved 50 per call.
- **Crossref**: the title is taken from `article-title`, else `volume-title`, else `unstructured`; `author`; year (first 4 digits); `DOI`.

**Mirror.**

- After each fetch the cache is also written to `<community>/origami-citation-graph.json`. `AppModel` sets `mirrorFolder` when a folder opens.
- `adoptMirror` folds in entries the device lacks, and fresher entries (newer `fetched`, and found-or-not-worse). It persists locally only, to avoid timestamps ping-ponging between devices.
- This is how the Vision Pro, which never fetches, sees the graph.

### 6.2 Lineage graph build

`Origami Text macOS/LineageCore.swift`. Foundation and CoreGraphics only; this file is portable as it stands.

**Input.** `LineagePaper` per shelf record: `id`, `title`, `authors`, `year` (from `dateISO` or the doc date), `doi`, `venue`, and the reference BibTeX list.

**Build (`LineageGraph.build`):**

1. **Shelf papers.** A paper with no year is dropped (and counted in `droppedReferences`). Every other paper becomes a node with `onShelf: true`, registered by DOI and by title key (first registration wins).
2. **References.** For each shelf paper, for each reference:
   - Parse the BibTeX. A failure is dropped.
   - Resolve to an existing node by DOI, then by title key.
   - Otherwise, a reference with an integer year (leading digits) and a non-empty title becomes a node with `id "cited:" + (doi ?? titleKey)`, `onShelf: false`, and venue `booktitle` ?? `journal`. A reference without one is dropped.
   - If the target is not the paper itself, add the edge `source=paper → target`. Edges form a set.
3. Fill `cites` and `citedBy`, each sorted by `(year, title)`, oldest first.
4. Group nodes by year into `byYear`.

**Weight.** A node's weight is its `citedBy.count` within the collection.

### 6.3 Lineage layout

`LineageLayout.layout(graph:size:)`. Insets: leading and trailing 48, top 110, bottom 84.

**x position.** Ordinal over the years present. A gap counts as `min(gap, 4)` units, so short gaps stay visible but one 18th-century reference cannot squeeze the modern columns. `x = left + unit/totalUnits × width`. A single year sits centred.

**Radius.**

- `r = (1.7 + 1.05·√w) · rs`.
- Start with `rs = clamp(spacing × 0.46 / (1.7 + 1.05·√maxW), 0.35, 1.35)`.

**Column order.** Sort by weight (descending), then title. Place items alternately at the front and the back (even ranks inserted at the front), so the heaviest dots end up in the middle and each column tapers toward both ends.

**Vertical gap.**

- The gap is `3·gs`. Start with `gs = 8` and lower it by 0.25, down to 0.5, until the tallest column fits 90% of the available height.
- If it still does not fit, multiply `rs` by 0.92 until the column fits 92%, or `rs` reaches 0.1.
- Each column is centred on `centerY`. The dots stack top to bottom.

**Edges.** Cubic Béziers:

```
dx = source.x - target.x; mid = (source.y+target.y)/2
dir = mid < centerY ? -1 : 1
bow = dir * min(|dx|*0.12, 90) * (|mid-centerY| < 40 ? 0.5 : 1)
c1 = (source.x - dx*0.42, source.y + bow); c2 = (target.x + dx*0.42, target.y + bow)
```

### 6.4 Lineage trace, search, drawing

**Trace (`LineageTrace.trace`).** Breadth-first, out to 3 steps.

- First backwards over `cites` ("roots", direction −1), then forwards over `citedBy` ("influence", +1).
- A node reached both ways keeps its first discovery.
- Every traversed edge is recorded with its depth and direction, in citation orientation.

**Search (`LineageSearch.matches`).** Case- and diacritic-folded substring search over "title + authors". It needs 2 or more characters.

- Return opens the match with the highest weight.
- On the Mac, a keystroke that leaves no match plays an error beep.

**Palette (`LineageStyle`).**

| Name | Light | Dark |
|---|---|---|
| paper | `F3F4F1` | `1B1C1E` |
| ink | `17181A` | `ECEDEA` |
| graphite | `3B3F46` | `9BA0A8` |
| muted | `70747A` | — |
| roots | `2743C4` (ultramarine) | — |
| influence | `C4791C` (ochre) | — |

Ramps by depth 1–3:

- edge alpha 0.90 / 0.30 / 0.11
- edge width 1.2 / 0.75 / 0.6
- node alpha 1 / 0.55 / 0.30

A resting edge has alpha 0.11 (0.16 dark). The dimmed base is 0.22.

**Drawing (`LineageView.draw`).**

1. Base layer: every edge (0.8 wide), every node (shelf nodes in ink at 0.82, cited-only nodes in graphite at 0.62). Dimmed while a trace or search is active.
2. The year axis. Labels thin out with the column spacing:
   - spacing ≥34: full years at every 5th year and the endpoints, two-digit labels elsewhere
   - spacing ≥14: majors only
   - smaller: decades and endpoints only
3. Search rings: radius `r + 3.5`, in roots blue.
4. The bloom: influence, then roots, deepest first. Then the nodes by depth. Then the root, filled at ×1.35 with a ring at `r + 4`.

**Interaction.**

- Hover blooms the hovered node. The hit radius is `r + 6`, and the nearest node wins.
- A click locks the selection and opens the detail panel (a sheet on a compact phone). Selections are kept on a back stack.
- The tooltip shows title, "authorsShort · year" and "Cites N · cited by M".

**Intro animation.** Plays once per session.

- Years start `min(0.23, 8/years)` seconds apart.
- Each dot pops with a back-out ease (c1 = 1.70158) over 0.38 s.
- Each edge draws 0.12 s after its source year, over 0.72 s, sampled as a 28-step polyline.
- A tap skips the intro.

**Wrappers.** Mac `LineageModuleView` (module `id "lineage"`, hides the document list); `PhoneLineageView`; `VisionLineageWindow`.

---

## 7. Platform notes and portable equivalents

| Apple piece | Used for | Portable equivalent |
|---|---|---|
| SwiftUI `Canvas`, `TimelineView`, `ScrollView` | Maps, Lineage | HTML canvas/SVG + requestAnimationFrame; any 2D scene graph |
| `@AppStorage` / `UserDefaults` | Preferences, map positions, mark removals | A JSON settings file or localStorage |
| `FileManager` Application Support | Caches | XDG data dir, `%APPDATA%`, IndexedDB |
| `URLSession` | HTTP | fetch / any HTTP client. Keep the User-Agent with a mailto, which Crossref's polite pool requires |
| `NSRegularExpression` | `[cite:…]` scans | Any regex engine (patterns given above) |
| `String.folding(.caseInsensitive, .diacriticInsensitive, .widthInsensitive)` | Normalisation | Unicode NFKD + strip combining marks + casefold (e.g. ICU, Python `unicodedata`) |
| `localizedStandardCompare` | Sorting | ICU collation with numeric ordering |
| `NumberFormatter .ordinal` | "1st, 2nd" | ICU / Intl.PluralRules ordinal |
| Apple `Compression` `COMPRESSION_ZLIB` | Scene payloads. This is **raw DEFLATE** (no zlib header) | zlib `inflateRaw`/`deflateRaw` (wbits −15); also accept a 2-byte-header stream |
| `CLGeocoder` | Place search | Nominatim (OpenStreetMap), with its 1-request-per-second policy |
| `CLLocationManager` | Current place | Platform geolocation API |
| `MapKit` `Map`/`Annotation` | Places map | Leaflet / MapLibre |
| `NaturalLanguage` `NLTagger .nameType` | Overview names | spaCy / Stanza NER |
| Vision `VNDetectFaceRectanglesRequest`, foreground mask | Headshot framing, bot finish | OpenCV / MediaPipe face detection; any segmentation model |
| Core Image `CIPhotoEffectMono`, `CIBlendWithMask` | Bot finish | Pillow / ImageMagick |
| Image Playground `ImageCreator` | Cartoon portraits | Any image-to-image model; keep the fixed concept text and one style for the whole community |
| FoundationModels `LanguageModelSession`, `@Generable` | Profiles, extraction | Any local LLM with JSON-schema constrained output (Ollama `format`, llama.cpp grammars) |
| App Group container | Picture store shared with Author | A shared folder both apps agree on; keep `index.json` and the `preferred` merge rule |
| `NSWorkspace` open / Launch Services | Scene-link ladder | OS URL handlers (`xdg-open`, `start`, intents); keep the clipboard fallback |
| `NSPasteboard` | Copy Citation, link fallback | System clipboard |
| `NSEvent` key monitor | ⌘A on the map | Keyboard handler scoped to the canvas |
| Swift `actor` | `ReferenceDatasetStore` | A single-threaded service or mutex-guarded store |
| Contacts framework (`ORIGAMI_CONTACTS`) | Person import | Platform contacts API (optional) |

On visionOS and iOS, `CitationGraph` and `LineageCore` are shared files. The headset does not fetch the graph; it adopts the community-folder mirror.

---

## 8. Rebuild order and acceptance checks

### 8.1 Order

1. **Normalisers and BibTeX bridge.** Implement `cleanDOI`, `normalizedTitle`, `titleKey`, `nameKey`, `doiKey` and `CitationGraph.key` exactly as specified in 2.3. Use the BibTeX parser chapter for `BibTeXRecord`.
2. **Reference extraction.** Implement visual-meta `citations` → `Reference`s, and anchors → `[cite:key]` tokens (2.1).
3. **References page, list modes.** Build entries, deduplicate, and implement As Cited, Title, Author and Date (2.2, 2.6, 2.7).
4. **ReferenceStatus.** CSV parser, Retraction Watch and FORRT indexes, live DOI checks with the 30-day cache, then marks and removals (4.2).
5. **CitationLookup** for card abstracts (4.6).
6. **CitationGraph** with politeness, the miss cache, the complete fold and the mirror (6.1).
7. **Matcher and links**, then the Time Map (4.3), then the Concept Map layouts (4.4).
8. **Reference datasets** (4.7) and the card section.
9. **Cited here** scan (4.8), and the Citation Tree (4.9).
10. **People**: directory, ORCID, portraits, App Group picture store, profiles (5.1–5.4).
11. **Places and Locations** (5.6). **Entity extraction** and venue views (5.5, 5.7).
12. **Lineage** (6.2–6.4).
13. **Scene links** (4.10).

### 8.2 Acceptance checks

| # | Check | Expected |
|---|---|---|
| 1 | `cleanDOI("https://doi.org/10.1145/ABC")` | `10.1145/abc` |
| 2 | `cleanDOI("unavailable")` | nil |
| 3 | `CitationGraph.key("A Title", "Jo Smith")` | `atitle|josmith` |
| 4 | Paragraphs: H1 "Intro"; "x [cite:a,b]"; H1 "Method"; "[cite:a]"; reference c never cited | As Cited: Intro, a (1st of 2), b; Method, a (2nd of 2); "Not Cited in the Text", c |
| 5 | Same key twice within one section | Listed once in that section |
| 6 | Reference with DOI listed in Retraction Watch as Retraction | Red "Retracted" pill; the red status count increments; no Foundational or Top-cited words even if they qualify; "Cited N×" still shown |
| 7 | Retraction plus Reinstatement notices | Orange "Retracted, Reinstated" |
| 8 | DOI `10.48550/arXiv.1234` with Crossref `is-preprint-of` non-empty | No Preprint pill |
| 9 | `doi.org/api/handles` returns responseCode 100 | Grey "Unverified" pill |
| 10 | Remove "Corrected 2×" on one card, then open another document citing the same title without a DOI | Mark hidden there too; Restore brings it back |
| 11 | Reference cited 3 times in text | "Key" word |
| 12 | Entry cited by 3 other entries' reference lists | "Foundational"; or 2 entries if the list is smaller than 15 |
| 13 | Time Map with works in 2001, 2003, 2010 | Columns at x = 160, 344, 564 (then +172+12, then +172+4×12) |
| 14 | Drag a Time Map card sideways | It moves vertically only; with a sort active, View returns to As Arranged |
| 15 | Concept Map, same list opened twice | Identical force layout (deterministic) |
| 16 | Shared References with two works sharing exactly 1 cited work | No edge (2 or more required) |
| 17 | Core & Periphery, 9 works | Ring sizes 1, 7, 1; radii 0, 210, 420 |
| 18 | Second References visit within 7 days | No Retraction Watch download |
| 19 | Card lookup miss | Not re-asked for 7 days |
| 20 | Dataset nodes file with `Conference Abbreviation` "ECHT94" | Venue shows "ECHT '94" |
| 21 | Dataset import of edges file only | Error "Import the nodes file together with the edges file." |
| 22 | Dataset fuzzy: two candidates scoring 0.93 and 0.90 | No match (lead under 0.05) |
| 23 | "Kenneth M. Anderson" vs "Kenneth T. Anderson" (no bare initial form present) | Two series authors |
| 24 | Lineage: shelf paper citing a work already on the shelf by DOI | Edge to the shelf node; no duplicate cited-only node |
| 25 | Lineage: one reference from 1750, the rest 1990–2020 | The gap counts as 4 units, so the modern columns stay wide |
| 26 | Liquid link with a 9000-character scene | Written as a `.liquidinfo` file, not added to the URL |
| 27 | Interatlas URL with a `scene` payload opened through the scheme | Bytes after ":" are identical to the https form |
| 28 | Person known in People also mentioned in a book's Overview | The People photo is used; no Wikipedia lookup |
| 29 | Place "Ytrebygda" geocoded | Pending; orange pin; Confirm card shown. "Wimbledon, London, United Kingdom" is verified at once |
| 30 | Opening References with lookups switched off | Lists and marks from the local indexes only; status says "Turn on Look up cited works online…" on the maps |

---

## Appendix: discrepancies and uncertainties found while reading

- **AI routing.** `PersonProfileStore.revise` and `EntityExtractor` now both go through `OrigamiLLM.generate`. `AppModel.extractEntities` skips a document whose extraction fails and reports the first failure's reason once, through `showNote`.
- **`isContextOverflow`** (`EntityExtraction.swift`) treats any error whose description contains "context" (case-insensitive) as an overflow. That is broader than the two error enums.
- **The Citation Tree's inbound match** (`CitationTreeView.findCitedBy`) compares raw lowercased titles. The rest of this area uses normalised titles with year checks, so the tree can miss matches the References page finds.
- **DOI normalisers differ** (table in 2.3). `ReferenceStatus.cleanDOI` rejects non-`10.` strings; the others do not. `ReferenceKeys.doiKey` strips only the first matching prefix; `CitationLookup.normalizedDOI` strips each prefix in turn.
- **`ReferenceStatus` header comment** says "All four are free and keyless". The OpenAlex percentile check needs the user's key, and the code skips it without one.
- **ORIGAMI-FIGURE-LINKS-SPEC** is cited in `AppModel.openFigureLink`, but no file of that name exists in the repository.
- **The Title listing** computes initial-letter groups (`sections`), but draws headers only for Date. This looks intended (a comment says "Title and Author run as one list"), but the grouping work is unused.
- **Series-author clustering is not order-safe**: a spelling joins a cluster if it is compatible with *any* member. Spellings are processed in sorted order, so "K. Anderson" sorts first and starts a cluster. Both "Kenneth M. Anderson" and "Kenneth T. Anderson" are then compatible with it and join it. The two people merge, against the stated intent (`SeriesAuthorRank.ranked`).
- **Venue relation views** (Shared Ground, Roots, Threads) are fully coded but hidden: `VenueViewMode.allCases` returns only Articles and Map.
- **`ProceedingsMapNode` and `MapLiveThreads`** (the map card and live line drawing) are used by the Time Map and Concept Map but defined outside this chapter's files. Their exact visuals are unclear from these sources.
- **OverviewPictures.swift** is not in this chapter's file list. It is included because it is where the App Group sharing with Author actually lives. `PersonPortraits.swift` itself writes only to the app's own container.
