# Origami Text ↔ Author Citation Contract

**Status:** Normative  
**Applies to:** Author (implementer), Origami Text (source of truth for metadata)  
**Principle:** Origami Text dictates the metadata shape. Author is responsible for preserving every field faithfully and embedding it into the exported EPUB. Origami Text reads it back and drives the citation panel UI.

---

## 1. What Origami Text puts on the clipboard

When a user selects text and chooses **Copy to Cite**, Origami Text writes four pasteboard representations in priority order. Author MUST read the richest one it finds.

### 1a. Private JSON (`info.futuretextlab.origami-citation`)

A UTF-8 JSON object conforming to `OrigamiCitation`. Author reads this type first.

```json
{
  "to":               "<doc-id>",
  "fragment":         "<paragraph-id>",
  "rel":              "cites",
  "quotedText":       "The exact words the user selected.",
  "author":           "Author Name(s)",
  "year":             "2026",
  "bibtex":           "@misc{ot1a2b3c4d5e,\n author = {...},\n ...}",
  "documentTitle":    "Title of the Cited Work",
  "documentFilename": "My Paper.epub",
  "annotation":       "Reader's margin note, if any."
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `to` | string | yes | The cited document's `dc:identifier` from its OPF. Never a filesystem path. |
| `fragment` | string | no | The paragraph `id` attribute the user was reading. |
| `rel` | string | yes | Always `"cites"` for a Copy to Cite action. |
| `quotedText` | string | yes | The verbatim selected words. Author stores this as the citation's display text. |
| `author` | string | yes | Author name(s) as written in the source document. |
| `year` | string | yes | Four-digit publication year. |
| `bibtex` | string | no | Full BibTeX entry (see §2 for required fields). When present, Author MUST use this verbatim — never regenerate it. |
| `documentTitle` | string | no | `<dc:title>` of the source EPUB. Author stores as `citation.title`. |
| `documentFilename` | string | no | Leaf filename of the source EPUB, e.g. `My Paper.epub`. Used as a fallback locator. |
| `annotation` | string | no | The reader's margin note. Author stores in the BibTeX `annotation` field and displays in the citation panel. |

### 1b. Author's native pasteboard type (`Liquid Author Citation pasteboard type`)

An NSKeyedArchiver-encoded dictionary. Author reads this when the JSON type is absent.

```
{
  "Content":    <string>  // Same as quotedText — the selected words
  "BibTeX":     <string>  // Same bibtex string as above — use verbatim
  "Annotation": <string>  // Optional — the reader's margin note
}
```

### 1c. HTML (`public.html`)

A complete HTML document containing one `<a>` element:

```html
<!DOCTYPE html><html><head><meta charset="utf-8"></head><body>
<a href="origamitext://open/<to>?q=<encoded-quote>#<fragment>">(Author, Year)</a>
</body></html>
```

Author may fall through to this if neither JSON nor the native type is available.

### 1d. Plain text (`public.utf8-plain-text`)

The verbatim selected words — usable as a last resort paste into any editor.

---

## 2. What Author must embed in the citation EPUB

### 2a. Citation link in the document body

Every inline citation span that references an Origami Text document MUST carry a hyperlink with one of these href forms (in preference order):

**Primary (in-app):**
```
origamitext://open/<origami-source-id>?q=<url-encoded-quote>#<paragraph-id>
```

**Carrier (web-safe, for Pages/Word compatibility):**
```
https://origamitext.app/o/<origami-source-id>?q=<url-encoded-quote>#<paragraph-id>
```

Rules:
- `<origami-source-id>` is the `to` field from the JSON — the base document id with NO `#fragment`.
- `?q=` carries the `quotedText`, percent-encoded. Omit `&`, `=`, `+`, `#`, `?` from the allowed set.
- `#<paragraph-id>` is the `fragment` from the JSON. Omit the `#` entirely if `fragment` is null/empty.
- The link text SHOULD be `(Author, Year)` or equivalent citation marker.

### 2b. BibTeX entry in `references.bib`

Author MUST include one `@misc` entry per citation. The BibTeX key is opaque — use whatever key is in the `bibtex` field from the clipboard JSON. If no key exists, generate one prefixed `ot` followed by a hash of the `vm-id`.

**Required fields** (must all be present; omit only if the value is empty):

```bibtex
@misc{<key>,
 author             = {Author Name(s)},
 title              = {Title of the Cited Work},
 year               = {2026},
 journal            = {Venue / Publication},      % omit if unknown
 quote              = {The exact selected words.},
 annotation         = {Reader's margin note.},    % omit if absent
 vm-id              = {<doc-id>#<paragraph-id>},  % full address incl. fragment
 origami-source-id  = {<doc-id>},                 % base id, NO fragment
 origami-source-file = {My Paper.epub},           % omit if unknown
 url                = {origamitext://open/<doc-id>},
 weburl             = {https://origamitext.app/o/<doc-id>},
}
```

**Critical rules:**
- `vm-id` = `<doc-id>#<paragraph-id>` when a fragment exists; `<doc-id>` alone otherwise.
- `origami-source-id` = always the base `doc-id` with NO fragment.
- `url` and `weburl` use `origami-source-id` (no fragment) — they open the document, not the paragraph.
- `quote` and `annotation` are freeform text; do not strip quotes or escape beyond standard BibTeX bracing.
- **Never regenerate BibTeX when the clipboard provides it.** Use the `bibtex` string verbatim. Only generate from scratch when the clipboard delivered only HTML or plain text.

### 2c. Backmatter reference list entry

Each reference in the `<section epub:type="bibliography">` MUST:

1. Have `id="bib-<bibtex-key>"` — used by inline citation markers as fragment targets.
2. Have `data-citation-number="<n>"` — the 1-based display number.
3. Include human-readable text: `Author (Year). Title. Venue.`
4. Carry an anchor that opens the original in Origami Text:

```html
<li id="bib-<key>" data-citation-number="1">
  Author Name(s) (2026). Title of the Cited Work. Venue.
  <a href="origamitext://open/<origami-source-id>">Open in Origami Text</a>
</li>
```

The `href` on the anchor is always `origamitext://open/<origami-source-id>` — no `?q=` or fragment. Origami Text will open the document at its start when activated from the reference list.

---

## 3. What Origami Text does when the user clicks a citation

This is the contract Author's output must satisfy. Origami Text performs these steps in order:

1. **Parse the href** — extract `origami-source-id` (the path component after `/open/` or `/o/`), the `?q=` quote, and the `#fragment` paragraph id.

2. **Look up by id** — search the library for a document whose `dc:identifier` equals `origami-source-id`. If found, open it at `#fragment`, highlight the `?q=` text. **Done.**

3. **Look up by filename** — if id lookup fails, read `origami-source-file` from the BibTeX entry and search the library folder for an EPUB with that leaf filename. If found, open it. **Done.**

4. **Show citation panel without the source** — if both lookups fail, display:
   - Title (from `title` BibTeX field)
   - Author and year (from `author`, `year`)
   - The quoted passage (from `quote` BibTeX field)
   - The reader's annotation (from `annotation` BibTeX field), if present
   - "Open in Origami Text" button — greyed out, with tooltip "Not in your library"
   - The `weburl` shown as a plain link

5. **Citation panel when source IS found** — display all of the above plus:
   - "Open in Origami Text" button — active, navigates to `origami-source-id#fragment`

---

## 4. Field mapping summary

| Clipboard JSON field | BibTeX field | Backmatter | Citation panel |
|---|---|---|---|
| `to` | `origami-source-id` | `href` base | id lookup key |
| `fragment` | appended to `vm-id` | — | scroll target |
| `quotedText` | `quote` | — | quoted passage |
| `author` | `author` | display text | author line |
| `year` | `year` | display text | year |
| `documentTitle` | `title` | display text | title |
| `documentFilename` | `origami-source-file` | — | filename fallback |
| `annotation` | `annotation` | — | annotation block |
| `bibtex` (whole) | verbatim | — | — |

---

## 5. What Author must NOT do

- **Do not transform the `bibtex` string.** Use it as-is when the clipboard supplies it. Reformatting loses the key, the `vm-id`, and the `origami-source-*` fields.
- **Do not use the EPUB filename as the citation locator.** The `origami-source-id` (`dc:identifier`) is the locator. Files move; identities don't.
- **Do not omit `origami-source-id` and `origami-source-file`.** Without both, Origami Text cannot open the source document.
- **Do not percent-encode the `?q=` value twice.** Encode exactly once before writing the href.
- **Do not put the `#fragment` in `origami-source-id` or in `url`/`weburl`.** The fragment belongs only in `vm-id` and in inline body hrefs.
