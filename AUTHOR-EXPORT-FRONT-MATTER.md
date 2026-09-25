# Author → Origami EPUB: exporting the document's authors

*For the Author developer. 25 September 2026. How Author should write
each author's name, affiliation, email and ORCID — and the rest of the
front matter — so that the EPUB is correct under the Origami EPUB Profile
1.0 and Origami Text can render it faithfully and convert it to other
formats (the ACM two-column LaTeX/PDF today, more later).*

The normative text is `ORIGAMI-EPUB-PROFILE-1.0.md` (§4.7 Rights, §5
Scholarly front matter). This note is the practical version, checked
against Author's current export ("Origami Text (gloss)", 25 Sep 2026).

---

## 1. The rule underneath everything

**Each fact is written once, as a field, and every visible form is
generated from that field.** The same author list feeds three places —
the package (`package.opf`), the semantic record (`visual-meta.json`),
and the page a person reads (`content/paper.html`) — and all three must
come from one source in Author so they can never disagree.

---

## 2. The semantic record — `visual-meta.json` → `document.authors`

**Author already does this correctly. Keep it exactly like this:**

```json
"document": {
  "authors": [
    { "name": "Frode Hegland",
      "affiliation": "The Augmented Text Company, London, UK",
      "email": "frode@hegland.com",
      "orcid": "0000-0001-5711-1279" }
  ]
}
```

Rules:

- **One object per person, in printed order.** Never several names in
  one entry.
- **`name`** — the name as it should print, e.g. `"Cansu Cetin Er"`.
- **`orcid`** — the **bare** 16-character id, `0000-0001-5711-1279`,
  hyphenated, **not** a URL. Validate it before export (ISO 7064
  mod 11-2 check digit; the last character may be `X`). Omit the key if
  the author has none — never write an empty string.
- **`email`** — a plain address, no `mailto:`. Omit if none.
- **`affiliation`** — **one line, as printed, ending with the country**:
  `"Institution, City, Country"`, e.g.
  `"InterReality Research Group, Tampere University, Tampere, Finland"`.
  Converters read the line *from the end* (country, then city, then the
  rest is the institution), and ACM's LaTeX class **refuses to compile
  without a country**. So:
  - always include the country;
  - put the city just before it;
  - do not add a postcode or street after the country.
- Keys that have no value are **omitted**, not written as `""`.

**Do not write the old forms** (the profile forbids writers from
emitting them): `authors` as a list of strings, and the name-keyed
dictionaries `author-affiliations`, `author-emails`, `author-orcids`,
or a loose `affiliations` array. Origami Text still *reads* them for old
files, but a new export must use only the objects above.

---

## 3. The package — `package.opf`

```xml
<dc:creator>Frode Hegland</dc:creator>          <!-- one per author, printed order -->
<meta property="dcterms:isPartOf">HUMAN Hypertext '26</meta>
<dc:identifier>10.1234/example.doi</dc:identifier>  <!-- DOI, if assigned: a second identifier -->
<dc:subject>Origami Text</dc:subject>           <!-- one per keyword -->
<dc:date>2026-09-25</dc:date>
```

- One `dc:creator` per person, same order and spelling as
  `document.authors[].name`.
- Affiliation, email and ORCID have **no** EPUB property — do not invent
  one in the package. They live in the record (§2).
- Keywords: one `dc:subject` each, **trimmed** — no trailing full stop.
  (The gloss export has `structural clarity.` as its last subject.)

---

## 4. The visible page — `content/paper.html` header  ← *the main fix*

Today the page shows only `Frode Hegland · 2026-09-25`. A reader in
Apple Books, Thorium or any ordinary EPUB reader sees nothing else, and
a printed or pasted copy loses the affiliation, email and ORCID
entirely. Render them in the `<header>`, generated from the same values:

```html
<header>
  <h1>Origami Text (gloss)</h1>
  <p class="subtitle">…</p>                        <!-- only if there is one -->

  <p class="author">Frode Hegland</p>
  <p class="author-detail">The Augmented Text Company, London, UK
    · <a href="mailto:frode@hegland.com">frode@hegland.com</a>
    · <a class="orcid" href="https://orcid.org/0000-0001-5711-1279">0000-0001-5711-1279</a></p>

  <!-- repeat author + author-detail for each author, in order -->

  <p class="byline">HUMAN Hypertext '26 · 25 September 2026</p>
</header>
```

- The ORCID is **written out** as its id and linked to
  `https://orcid.org/<id>` (no "iD" icon alone — the number itself must
  be visible, per ORCID's own display guidance).
- Omit any piece an author does not have; do not leave a dangling `·`.
- These class names (`author`, `author-detail`, `orcid`, `byline`) are
  the ones Origami Text's own exporter uses and its stylesheet already
  styles, so the two apps' EPUBs look alike.

---

## 5. The rest of the front matter — fields, never body text

Write these as fields in `visual-meta.json` → `document`. **Do not also
put them in the body** (the profile says a publication MUST NOT carry
the CCS concepts as body text; the same holds in practice for the
others, or they print twice when converted):

| Field | What to write |
|---|---|
| `abstract` | The abstract's text. Do not add an "Abstract" heading in the body. |
| `keywords` | Array of strings, trimmed, no trailing punctuation. |
| `ccsConcepts` | Array, one path per entry: `"Human-centered computing → Hypertext / hypermedia"`. Use `→` between levels. |
| `publication` | The venue's full name. |
| `subtitle` | Only if there is one. |
| `doi` | Bare DOI (`10.1145/…`), only once assigned. |
| `isbn` | Only if the venue has one. |
| `acmReference` | **Only** the publisher's verbatim "ACM Reference Format" text once the publisher provides it. Never compose it yourself. |

When `acmReference` is present Origami Text reads the event's short
name, dates and place from it for the ACM layout (running head, rights
block). Without it the ACM rendering has only the venue name — which is
correct for a paper not yet accepted anywhere.

---

## 6. Rights — Author records facts, Origami Text composes the statement

Rights are a publisher's statement about an *edition*, so Origami Text
decides them when a paper is put into a publisher's format (its Format
sheet offers CC BY and variants, rights retained, licensed to ACM,
etc.). Author should therefore **not** write boilerplate such as ACM's
copyright paragraph. Only record what the writer has actually chosen:

```xml
<!-- only when the writer has chosen a licence -->
<meta property="dcterms:license">https://creativecommons.org/licenses/by/4.0/</meta>
<meta property="dcterms:rightsHolder">Frode Hegland</meta>
<meta property="cc:attributionName">Frode Hegland</meta>
```

- `dcterms:license` **must be a URI** (the Creative Commons deed URL),
  never a name like "CC BY".
- If the writer has chosen nothing, write **nothing** — no default
  licence, no `dc:rights` prose. Absence is allowed and correct; Origami
  Text will then default to CC BY 4.0 in the Format sheet and say so.

---

## 7. Checklist against the current Author export

| | Status |
|---|---|
| `document.authors[]` as objects with name/affiliation/email/orcid | ✅ correct — keep |
| ORCID bare, not a URL | ✅ correct |
| `dcterms:isPartOf` venue, `dc:subject` keywords | ✅ correct |
| Author details visible on the page (§4) | ❌ **add** — only a byline today |
| Affiliation always ends in a country (§2) | ✅ in this file — enforce it for every author |
| Keywords trimmed (§3) | ❌ last keyword ends in "." |
| Abstract / keywords / CCS as fields, not body text (§5) | ✅ abstract and keywords are fields; add `ccsConcepts` when the writer supplies them |
| Rights: facts only, no boilerplate (§6) | ✅ nothing written today — add licence URI only when chosen |
| No legacy `author-orcids` / `author-emails` / `author-affiliations` | ✅ none present — keep it that way |

With §4 and the keyword trim done, the same export reads correctly in
any EPUB reader, in Origami Text, and in the ACM two-column conversion.
