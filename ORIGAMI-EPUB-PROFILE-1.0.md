# Origami EPUB Profile 1.0

**Profile identifier:** `https://origamitext.org/profile/1.0`
**Vocabulary:** `https://origamitext.org/vocab/`
**Date:** 24 September 2026
**Status:** normative text frozen. Changes from here are errata.

---

## About this document

This is the definitive statement of the format. It is intended to be
sufficient on its own: a developer with this document and the
conformance corpus should be able to write a conforming reader or writer
without access to the source of any existing implementation. Any point
at which a reader of this document must ask a question is a defect in
this document.

Keywords **MUST**, **MUST NOT**, **REQUIRED**, **SHOULD**,
**SHOULD NOT**, **MAY** are used as in RFC 2119. Sections marked
**[I]** are informative; everything else is normative.

Out of scope: reader annotations, highlights, notes, reading position
and reader-created spatial layouts. Those never appear inside a
publication (§14) and are governed by the W3C Web Annotation Data Model.

Appendix B states what the reference implementations currently do, which
is not the same as what this document requires.

---

## 1. Scope and principles

An Origami EPUB is a conforming EPUB 3 publication that adds structured
semantic and interaction metadata while remaining readable as an
ordinary EPUB.

> **An Origami EPUB is an ordinary EPUB whose contents are sufficiently
> self-describing for richer reading systems to act on them.**

The following are normative. Where a later section appears to permit
something these forbid, these govern.

1. **Origami EPUB is EPUB.** A publication MUST remain a conforming
   EPUB 3.3 publication.
2. **Ordinary readers remain useful.** Removing or ignoring all
   Origami-specific metadata MUST NOT make the publication
   unintelligible or substantially incomplete.
3. **Standard semantics first.** Where HTML, EPUB Structural Semantics,
   DPUB-ARIA, MathML, Dublin Core, schema.org, or an established
   bibliographic representation is adequate, Origami MUST use it rather
   than define its own.
4. **Elements have Web-addressable identities.** The canonical address
   of an element is a content-resource path plus a fragment identifier.
5. **Extension metadata is explicitly discoverable.** Origami metadata
   MUST be declared through EPUB package mechanisms. A conforming reader
   MUST NOT depend on filenames.
6. **Controlled redundancy.** Metadata MAY be duplicated for
   resilience, discovery or degradation, but every duplication MUST have
   a declared authority and a stated equivalence rule (§11).
7. **Each fact has an authoritative representation.** Where a fact may
   appear in more than one place, precedence MUST be documented (§11.4).
8. **Metadata is versioned and validatable.** Every Origami JSON
   structure MUST be described by a published, versioned schema.
9. **Unknown optional metadata is safe.** A reader MUST ignore Origami
   properties and attributes it does not understand.
10. **The publication carries authored intent.** Authorial semantics and
    authored presentations MAY be embedded.
11. **Reader activity remains external.** Personal annotations,
    highlights, notes, reading position and reader-created layouts MUST
    NOT be written into a publication.
12. **No Origami semantics depend on scripting.** Removing scripts MUST
    NOT remove information a conforming Origami reader requires.
13. **Self-identifying records.** Every standalone Origami metadata
    record MUST identify its format, its version and the publication it
    describes.
14. **Metadata is visible to people.** A publication MUST carry a
    human-readable statement of what machine-readable metadata it has
    and where, and of its rights (§7.4). Metadata that exists only in a
    hidden payload does not survive printing, copy-pasting, plain-text
    extraction, or a reading system that has never heard of this
    profile.
15. **Independent implementation is the test of openness.** A compatible
    implementation MUST be possible from this document and the
    conformance corpus alone.

---

## 2. Conformance

### 2.1 Conforming publication

A publication conforms when it is a conforming EPUB 3.3 publication
**and** satisfies every MUST in this specification that applies to
publications. Both are validated separately (§18) and both MUST pass.

### 2.2 Conforming reader

A reader conforms when it:

1. reads a conforming publication as an ordinary EPUB even if it
   implements no Origami feature;
2. discovers Origami metadata as in §16;
3. honours the precedence rules of §11.4;
4. ignores what it does not understand (§15.3);
5. never writes to the publication.

A conforming reader need not implement every feature. It MUST NOT
misrepresent a feature it does not implement — for example by showing a
figure's file name as its description.

### 2.3 Conforming writer

A writer conforms when it emits only conforming publications and applies
the export-time checks of §17.

---

## 3. Terminology

| Term | Meaning |
|---|---|
| **Work** | The intellectual publication, across editions and formats. |
| **Edition** | One citable publication of a work, identified by `dc:identifier`. |
| **Release** | One published state of an edition, identified by `dcterms:modified`. |
| **Artifact** | The exact bytes of one generated `.epub` file. |
| **Publication** | One EPUB file: one release of one edition. |
| **Element** | An addressable thing in a content document: paragraph, heading, figure, table, equation, note, glossary entry, bibliography entry. |
| **Content document** | An XHTML document in the spine. |
| **Semantic record** | The Visual-Meta JSON record (§8). |
| **Interaction record** | The Origami JSON record (§9). |
| **Bibliography record** | The BibTeX record set (§10). |
| **Carrier** | The element bearing a 3D figure's `data-model-*` attributes (§6.9). |
| **Address** | A content-resource path plus a fragment identifier (§5.1). |

---

## 4. Package structure

### 4.1 Container and package document

Ordinary EPUB. `META-INF/container.xml` names the package document,
which MUST declare `version="3.0"` — the package version retained by
EPUB 3.x — and a `unique-identifier`.

A publication using any `origami:` property MUST declare the prefix, and
likewise any other vocabulary it uses that EPUB does not predeclare —
`cc:` for the Creative Commons attribution properties of §4.8:

```xml
<package xmlns="http://www.idpf.org/2007/opf" version="3.0"
         unique-identifier="pub-id" xml:lang="en"
         prefix="origami: https://origamitext.org/vocab/
                 cc: http://creativecommons.org/ns#">
```

`dcterms:`, `schema:` and `a11y:` are predeclared by EPUB and need no
`prefix` entry.

### 4.2 Profile declaration

```xml
<meta property="dcterms:conformsTo">https://origamitext.org/profile/1.0</meta>
```

REQUIRED. The value is the profile identifier, whose last path segment
is `MAJOR.MINOR`. It SHOULD resolve to human-readable documentation, but
a reader MUST NOT require network access to interpret a publication.

A publication MUST NOT use `origami:profile`.

### 4.3 Identity

Five levels, three of which appear in the file.

```
Work  ──────────────►  urn:uuid, named by dcterms:isVersionOf
  │
  ├── Edition ──────►  dc:identifier
  │     │
  │     ├── Release ►  dcterms:modified, optionally schema:version
  │     │     │
  │     │     └── Artifact ►  SHA-256 over the .epub bytes (external)
  │     │
  └── Element ──────►  XHTML id (§5)
```

```xml
<dc:identifier id="pub-id">urn:uuid:97d7808d-d373-4ba7-a350-f6a7895c8811</dc:identifier>
<dc:title>Origami Text (gloss)</dc:title>
<dc:language>en</dc:language>
<dc:creator>Frode Alexander Hegland</dc:creator>
<meta property="dcterms:modified">2026-09-24T09:30:57Z</meta>
<meta property="dcterms:isVersionOf">urn:uuid:0f2c6a51-…</meta>
<meta property="schema:version">author revision 3</meta>
<link rel="dcterms:replaces" href="urn:uuid:5a1c…"/>
```

**Work** — `dcterms:isVersionOf`. REQUIRED. A `urn:uuid:`. Every edition
of one work MUST carry the same value; a first edition still carries it.
A writer MUST generate it once, when a document is created, and MUST NOT
regenerate it.

**Edition** — `dc:identifier`. REQUIRED. A publication MUST assign a new
`dc:identifier` when the content is **significantly** revised, and MUST
NOT change it for a minor revision — a metadata correction, a
typographical fix, an erratum. EPUB 3.3 §5.5.3.1.1: *"Significant
revision, abridgement, etc. of the content requires a new unique
identifier."* Changing it on every export makes each corrected comma a
new publication that nothing already citing it can find.

**Release** — `dcterms:modified`. REQUIRED, and MUST be updated whenever
the publication changes at all, as EPUB 3.3 §5.5.5 requires. Two
releases of one edition share a `dc:identifier` and differ here.

**Release label** — `schema:version`. OPTIONAL. A human-meaningful
string or number: `author revision 3`, `accepted manuscript`, `2`.
schema.org defines `version` as accepting Text or Number, meaning the
version of the work embodied by the resource.

**Artifact** — a SHA-256 over the `.epub` bytes, which **MUST NOT
appear inside the publication**: a file cannot contain its own hash
(§12).

**Element** — the XHTML `id` (§5).

`dcterms:replaces` / `dcterms:isReplacedBy` — OPTIONAL, naming another
**edition's** `dc:identifier`, for supersession and retraction.

A publication **MUST NOT** use `dcterms:hasVersion` to carry a revision
label. DCMI defines it as *a related resource that is a version, edition
or adaptation of the described resource* — a relation to a resource,
with non-literal values intended. A publication MAY use it for that
documented purpose.

A publication MUST NOT define `origami:work`, `origami:supersedes` or
`origami:replaces`.

#### 4.3.1 What the levels answer **[I]**

| Question | Answered by |
|---|---|
| Is this the same intellectual work? | `dcterms:isVersionOf` |
| Is this the same citable publication? | `dc:identifier` |
| Is this a newer state of that publication? | `dcterms:modified` |
| Which revision, in human terms? | `schema:version` |
| Are these the same bytes? | the artifact digest (external) |
| Is this the same passage? | the element address plus a quote selector (§5.4) |

An annotation made against one release of an edition applies to another
release of the **same** edition without inference, because the edition
is the same publication. Across editions it is an inference, and §5.4
governs.

### 4.4 Metadata discovery

Every Origami metadata record MUST be declared in the package metadata
using the EPUB `record` link relation, and the `properties` attribute is
**REQUIRED**:

```xml
<link rel="record" href="visual-meta.json"
      media-type="application/json"
      properties="origami:visual-meta"/>
<link rel="record" href="origami.json"
      media-type="application/json"
      properties="origami:interaction"/>
<link rel="record" href="references.bib"
      media-type="application/x-bibtex"
      properties="origami:bibliography"/>
```

| `properties` value | Record |
|---|---|
| `origami:visual-meta` | the semantic record (§8) |
| `origami:interaction` | the interaction record (§9) |
| `origami:bibliography` | the bibliography record (§10) |

A record's kind MUST be determined from `properties`.

**`media-type` MUST NOT determine a record's kind.** The semantic record
and the interaction record are both `application/json`, so the media
type cannot distinguish the two records it would most need to. A reader
MUST NOT determine a record's kind from its filename.

Where a reader cannot determine a kind — a pre-1.0 file, or an
unrecognised `properties` value — it MAY read the record's mandatory
self-identification block (§8.1, §9.1) and take the `format` value it
finds there. A record stating its own kind is a legitimate fallback;
guessing from the media type is not.

A reader MUST ignore a `<link rel="record">` whose `properties` it does
not recognise.

#### 4.4.1 A record is a linked resource, not a publication resource

EPUB 3.3 §1.4 defines the two kinds of resource:

> **publication resource** — "A resource that contains content or
> instructions that contribute to the logic and rendering of an EPUB
> publication."
>
> **linked resource** — "A resource that is only referenced from a
> package document link element (i.e., not also used in the rendering of
> an EPUB publication)."

and §3.1.1, of linked resources:

> "Unlike publication resources, they are not listed in the package
> document manifest."

An Origami metadata record contributes nothing to rendering. It is
therefore a linked resource:

1. A record declared by `<link rel="record">` **MUST NOT** also appear
   as a manifest `<item>`. EPUBCheck reports this as
   **`OPF-067`**: *"The resource … must not be listed both as a `link`
   element in the package metadata and as a manifest item."*
2. A record **MUST NOT** be referenced from any content document, since
   that would make it contribute to the rendering and so cease to be a
   linked resource. This forbids `<link rel="describedby">` in a content
   document's `<head>` (§6.12).
3. Linked resources do not require fallbacks (§3.1.1), so a record needs
   none despite `application/json` and `application/x-bibtex` not being
   core media types.

Rules 2 and 3 are not tool-enforced: a publication can violate them and
still pass EPUBCheck. They rest on the normative text, and §18's
validator exists partly for this reason.

#### 4.4.2 Records MUST NOT live in `META-INF/`

EPUB 3.3 reserves `META-INF` for `container.xml`, `signatures.xml`,
`encryption.xml`, `metadata.xml`, `rights.xml` and `manifest.xml`, and
states:

> "EPUB creators MUST NOT reference files in the `META-INF` directory
> from an EPUB publication."

A `<link rel="record" href="../META-INF/visual-meta.json">` is precisely
such a reference. Records therefore **MUST NOT** be placed in
`META-INF/`, and MUST live alongside the other content resources.

This is stated explicitly because `META-INF` is an inviting place for
container-level metadata, because EPUBCheck does not catch it, and
because the colophon (§7.4) states these paths in human-readable text —
so getting them wrong tells every reader of the publication to look
somewhere the files are not.

### 4.5 Manifest and fallbacks

All publication resources MUST appear in the manifest; metadata records
MUST NOT (§4.4.1).

**A fallback is required exactly where EPUB 3.3 requires one, and not
otherwise.** §3.5.1 requires a content fallback for a foreign resource
"when the elements that reference them do not have intrinsic fallback
capabilities", and §3.4 defines **exempt resources** which "[do] not
require a fallback" — among them data files that are neither referenced
from a spine `itemref` nor embedded directly in a content document.

For 3D models:

| How the model is carried | Fallback |
|---|---|
| `<img>` poster bearing `data-model-src` (§6.9) | the poster is a core-media-type image and is what renders; a `fallback` to it is RECOMMENDED |
| a carrier with no poster (§6.9.5) | the model is an exempt data file: **no fallback required** |

```xml
<item id="img1"   href="images/model1-poster.png" media-type="image/png"/>
<item id="model1" href="models/model1.usdz"
      media-type="model/vnd.usdz+zip" fallback="img1"/>
```

A writer MUST NOT be prevented from exporting a posterless figure for
want of a fallback, and a validator MUST NOT report one.

A content document containing MathML MUST declare it (§6.7).

### 4.6 Accessibility metadata

REQUIRED: `schema:accessMode`, `schema:accessModeSufficient`,
`schema:accessibilityFeature`, `schema:accessibilityHazard`,
`schema:accessibilitySummary`.

A publication MUST NOT claim `alternativeText`, or a textual-only
`accessModeSufficient`, if any image lacks an accessible description. A
writer MUST withdraw the claim rather than weaken the definition, so
that the claim is trustworthy to a reader. See §6.9.6 for what counts as
a description when a caption is adjacent.

### 4.7 Reference file layout **[I]**

Not normative. A writer MAY use any paths; a reader MUST follow the
manifest and the package links.

```
mimetype                       stored, first in the archive
META-INF/container.xml
OEBPS/content.opf
OEBPS/content.xhtml            body
OEBPS/backmatter.xhtml         glossary, bibliography, endnotes, colophon
OEBPS/nav.xhtml
OEBPS/origami.css
OEBPS/visual-meta.json         semantic record
OEBPS/origami.json             interaction record
OEBPS/references.bib           bibliography record
OEBPS/images/…
OEBPS/models/…
```

---

### 4.8 Rights

A publication SHOULD state its rights, and where it does the statement
MUST be machine-readable as well as human-readable. A scholarly document
whose licence exists only as a paragraph of prose cannot be filtered,
aggregated, or reused with confidence by anything but a person reading
it.

None of these properties is REQUIRED: a meeting note or a personal
letter genuinely has no rights statement, and a writer MUST NOT be
prevented from exporting one. Their absence is a warning, not an error
(§17.2).

#### 4.8.1 What to declare

```xml
<dc:rights>© 2026 Copyright held by the owner/author(s).</dc:rights>
<meta property="dcterms:license">https://creativecommons.org/licenses/by/4.0/</meta>
<meta property="dcterms:rightsHolder">Association for Computing Machinery</meta>
<meta property="dcterms:accessRights">open access</meta>
<meta property="cc:attributionName">Frode Alexander Hegland</meta>
<meta property="cc:attributionURL">https://doi.org/10.1234/origami.2026.1</meta>
```

| Property | Use | Value |
|---|---|---|
| `dc:rights` | RECOMMENDED | The rights statement as a person would read it. Dublin Core: *"Information about rights held in and over the resource."* |
| `dcterms:license` | RECOMMENDED | **A URI** identifying the licence. Dublin Core: *"A legal document giving official permission to do something with the resource. Recommended practice is to identify the license document with a URI."* |
| `dcterms:rightsHolder` | OPTIONAL | Who owns or manages the rights — frequently a publisher rather than the author. |
| `dcterms:accessRights` | OPTIONAL | Access or restriction status: `open access`, an embargo date, a security classification. |
| `cc:attributionName` | OPTIONAL | The name attribution must credit. |
| `cc:attributionURL` | OPTIONAL | The URL attribution should point at. |

**`dcterms:license` MUST be a URI where one exists.** This is the
property that makes rights actionable: `https://creativecommons.org/licenses/by/4.0/`
can be compared, resolved and reasoned about, where "Creative Commons
Attribution" can only be pattern-matched. A reader MUST NOT infer a
licence by searching `dc:rights` for the name of one.

`dcterms:license` is a sub-property of `dcterms:rights` in Dublin Core,
so the two compose: the prose says what a person needs to know, the URI
says what software needs to know, and neither replaces the other.

The two `cc:` properties exist because Creative Commons licences
**require** attribution, and a reader offering to copy a citation should
use the attribution the publication asks for rather than inventing one.
A writer SHOULD emit them when it declares a CC licence. A reader
building an attribution string SHOULD prefer them, and otherwise fall
back to `dc:creator`, `dc:title` and the licence URI.

#### 4.8.2 In the records

The semantic record MAY mirror the rights (§8.2), and this is a derived
representation: the package governs (§11.4).

```json
"document": {
  "rights": "© 2026 Copyright held by the owner/author(s).",
  "license": "https://creativecommons.org/licenses/by/4.0/",
  "rightsHolder": "Association for Computing Machinery",
  "accessRights": "open access"
}
```

`rights` is prose; `license` is a URI.

**Compatibility.** Pre-1.0 publications put the whole prose rights block
in `document.license`. A reader MUST treat a `license` value that is not
a URI as `rights`, and MUST NOT present it as a licence identifier.

#### 4.8.3 Resources whose rights differ

A publication frequently carries third-party material under its own
terms — a 3D model from a repository, a figure reproduced by permission.
Where a resource's rights differ from the publication's, the writer
**MUST** state that in the publication's own text: in the figure's
caption, or in the colophon.

1.0 provides no machine-readable per-resource rights vocabulary. This is
deliberate: rights per resource is a general problem — images, audio,
video and datasets all have it — and a model-only answer would be the
narrow version of it. A general mechanism is expected in a later minor
version, which §15.4 already makes a compatible addition. Until then the
obligation is discharged in prose, which is where the attribution
requirement of a CC licence is satisfied anyway.

#### 4.8.4 Encryption

> **A conforming publication MUST NOT encrypt its content documents or
> its metadata records. Font obfuscation is permitted.**

This is a statement about what the format is for. §1.2 requires that an
ordinary reader remain useful and §1.15 makes independent implementation
the test of openness; neither survives a publication whose text cannot
be read without permission. A format whose whole argument is that a
document should explain itself cannot also permit its text to be locked.

Font obfuscation is exempted because EPUB uses `META-INF/encryption.xml`
for that as well as for digital rights management, and obfuscating an
embedded font is a licensing formality of typography, not a restriction
on reading.

`META-INF/rights.xml` MAY be present. It MUST NOT be the only place the
publication's rights are stated, and a reader MUST NOT be required to
consult it in order to read the publication.

---

## 5. Addressing

### 5.1 The canonical address

The canonical address of an element is the **content-resource path
relative to the package document, plus a fragment identifier**:

```
content.xhtml#P-F93D1917-2745-431C-9667-43C3203314BF
backmatter.xhtml#gloss-97887240-D108-40BE-A12F-C022A5C2CE5B
```

**This is true whether the publication has one content document or
twenty.** An element's identity does not depend on how many other
documents happen to exist beside it:

```
content.xhtml#P-123      ← always this
P-123                    ← never this, as a canonical address
```

A form that is conditional on document count makes adding a second XHTML
resource — or merely adding a colophon — silently change the address of
everything already published.

A bare fragment identifier MUST NOT be assumed unique across the
publication and MUST NOT be used as a canonical address. It remains a
legitimate **compact representation inside a metadata record** whose
`document.defaultDocument` declares what it resolves against (§8.2):
that is a serialisation convenience within one file, not an identity.

A publication MAY contain any number of content documents. A writer MUST
NOT assume one; a reader MUST support many.

A reader **MUST NOT rewrite element ids** to disambiguate across
documents — prefixing them per chapter, for instance. A rewritten id is
not the id the publication published, so every citation, annotation and
metadata reference to it silently fails to resolve. Uniqueness across
documents is what the path is for.

### 5.2 Identifier syntax

Every element that may be cited, annotated, linked to, or referred to
from Origami metadata MUST carry an XHTML `id`.

```
id ::= prefix "-" UUID | any other NCName
```

An `id` MUST be a valid XML NCName, which in particular means it MUST
NOT begin with a digit — a bare UUID frequently does, which is what the
prefixes below are for. UUIDs are RFC 4122. Comparison of ids MUST be
case-sensitive and exact.

Registered prefixes:

| Prefix | Customary use |
|---|---|
| `P-` | a block in the reading flow: paragraph, figure, table placement, list item |
| `H-` | heading |
| `E-` | equation |
| `M-` | a 3D model's own handle (not an address) |
| `gloss-` | glossary entry |
| `bib-` | bibliography entry |
| `en-` | endnote |
| `st-` | stretchtext aside |

Two rules govern prefixes:

- **Software MUST NOT infer the semantics of an element from its id
  prefix.** Semantics come from the markup — `epub:type`, `role`, the
  tag name — never from the identifier.
- A writer MAY use other prefixes or none. The registered list is a
  convention for human legibility, not a type system.

`data-id` MUST NOT be emitted. A reader MAY accept it as an address for
pre-1.0 publications, and MUST prefer `id` where both exist.

A publication MAY additionally carry a **positional** address — `2B`,
meaning the second element of section 2 — but MUST NOT use it as an
identity, and MUST NOT put it in `id`. It renumbers whenever an element
is inserted above it, so every citation and annotation pointing at one
would silently move to a different element. Carry it as
`data-origami-address`, and in `structure.headings[].address` (§8.2).

### 5.3 Uniqueness

Ids MUST be unique within a content document, as XHTML requires. Ids
SHOULD be unique across the publication; a writer that reuses an id in
two documents MUST NOT rely on bare-fragment addressing anywhere.

### 5.4 Element identity across editions

**Keep the id** when the element remains the same logical element and
receives only typographical corrections, punctuation changes, formatting
changes, or wording changes that do not materially alter its assertion.

**Assign a new id** when the element is substantively rewritten, its
assertion changes materially, two elements merge, one element splits, or
its semantic role changes.

**Lineage is not identity.** A new element that replaces an old one does
not become it. A writer MAY record lineage in the semantic record
(§8.6). A reader MUST treat lineage as a claim rather than a fact.

**Annotation consequence.** An external annotation is attached exactly
to its original target in its original edition. Applying it to a later
edition is an *inference*. A reader that does so MUST be able to
distinguish, in its interface, an exact attachment from an inferred one.
An annotation SHOULD therefore combine the element address with textual
evidence — a quote selector with prefix and suffix, as the W3C Web
Annotation Data Model provides — rather than relying on lineage alone.

---

## 6. Content documents

### 6.1 General

Content documents are ordinary XHTML. Everything necessary to read the
publication MUST be present in them. Origami metadata adds meaning; it
never carries the text.

### 6.2 Body structure

```html
<h2 id="H-0979114B-5BB1-45B8-8E3B-736373BC80C5">Why EPUB Now?</h2>
<p id="P-68353888-1EA7-4D0B-A084-D9F8F6027523" data-origami-address="2B">
  <mark>We have long celebrated the pen…</mark> Socrates worried that…
</p>
```

- Headings are `<h1>`–`<h6>`.
- `<mark>` is authorial emphasis and part of the published text. A
  reader SHOULD render it distinctly and MUST NOT treat it as a reader
  annotation.
- Lists are `<ul>`/`<ol>` with `<li>`; a writer MAY give each `<li>` an
  id.

### 6.3 Citations

```html
<a epub:type="biblioref" role="doc-biblioref"
   href="backmatter.xhtml#bib-232A9EED-512F-40C7-AB46-AB086D49733B">[2]</a>
```

REQUIRED: `epub:type="biblioref"`, `role="doc-biblioref"`, and an `href`
resolving to a bibliography entry (§7.2). The href fragment's identifier
is the citation's key, and is the same key used in the bibliography
record (§10) and in `citations[].id` (§8.4).

`data-citation-key` and `data-citation-number` MAY be present; both
duplicate information available elsewhere and a reader MUST NOT require
either.

### 6.4 Glossary references

```html
<a epub:type="glossref" role="doc-glossref"
   href="backmatter.xhtml#gloss-97887240-D108-40BE-A12F-C022A5C2CE5B">Origami Text</a>
```

REQUIRED: `epub:type="glossref"`, `role="doc-glossref"`, resolving href.

### 6.5 Notes

```html
<a epub:type="noteref" role="doc-noteref"
   href="backmatter.xhtml#en-D16AD8DE-23E7-4FD1-9553-E8441AF49942">†</a>
```

### 6.6 Tables

The table stands in the flow as an ordinary `<table>`. It carries its own
address, points at its record, and MUST contain a complete static
rendering of its computed values, so a reader without table support
loses nothing.

```html
<table id="P-4C1E…" data-table-id="T-9A3F…">
  <caption>Papers per year, with a computed share.</caption>
  <thead><tr><th>Year</th><th>Papers</th><th>Share</th></tr></thead>
  <tbody>
    <tr><td>2024</td><td>120</td><td>0.48</td></tr>
  </tbody>
</table>
```

`data-table-id` names an entry in the interaction record's `tables`
(§9.2). Where it is absent, the element's `id` MAY be used as the key.

The XHTML is authoritative for the table's **presented values**. The
interaction record is authoritative for its **formulas**. A reader that
recomputes MUST show that values are computed and MUST be able to return
to the document's own numbers.

### 6.7 Equations

MathML in the body is authoritative:

```html
<math xmlns="http://www.w3.org/1998/Math/MathML" id="E-71B2…"
      display="block" alttext="E = mc^2">
  <mrow><mi>E</mi><mo>=</mo><mi>m</mi><msup><mi>c</mi><mn>2</mn></msup></mrow>
</math>
```

A writer MAY additionally carry `data-latex` on the element; it is
**derived** and MUST agree with the MathML.

**A content document containing MathML MUST declare it in the
manifest.** Omitting this is EPUBCheck `OPF-014`:

```xml
<item id="paper" href="content/paper.html"
      media-type="application/xhtml+xml" properties="mathml"/>
```

#### 6.7.1 The equation index

An index of the publication's equations is OPTIONAL and exists for one
purpose: citing and copying an equation as text, which MathML alone
makes awkward.

**Its home is the semantic record, as `equations[]`** (§8.8), discovered
like every other record (§4.4).

```json
"equations": [
  { "id": "E-71B2…",
    "href": "content.xhtml#E-71B2…",
    "display": "block",
    "label": "1",
    "format": "mathml",
    "tex": "E = mc^2",
    "tex-sha256": "…",
    "mathml-sha256": "…",
    "converter": "latexml",
    "section": "content.xhtml#H-0979…",
    "heading": "Why EPUB Now?" }
]
```

`display` is `block` or `inline`; `format` is `mathml` or `latex`. The
checksums let a reader detect a damaged `tex` round trip; where a
checksum fails, **the MathML in the body governs** (§11.4). `tex` is a
derived representation (§11.3), not an authority.

A reader that finds no index MUST be able to proceed: scanning the
content documents for `math` elements carrying an `id` yields the same
set, without the TeX. Being a `math` element is what makes something an
equation; the id only addresses it, and a reader MUST NOT require an id
prefix such as `eq-`.

A conforming publication MUST NOT carry the index as delimited text
inside a content document. Text delimiters are discoverable by no
package mechanism; a reader MAY accept that form for publications that
do not declare the profile (§16.2).

### 6.8 Figures

```html
<figure id="P-7AAA…">
  <img src="images/img1.png" alt="A cutaway of the turbine assembly."/>
  <figcaption>Figure 3. The turbine assembly, sectioned.</figcaption>
</figure>
```

Where the writer supplied no description, `alt` MUST be the empty string
and `<figcaption>` MUST be absent.

### 6.9 3D spatial figures

A 3D figure is a `<figure>` containing a **carrier** element that bears
every fact about the model in `data-model-*` attributes. The model file
is an ordinary publication resource.

**With a poster — the normal case:**

```html
<figure id="P-F93D1917-2745-431C-9667-43C3203314BF">
  <img src="images/model1-poster.png"
       alt="An apple, seen from the side."
       data-model-id="M-F93D1917-2745-431C-9667-43C3203314BF"
       data-model-src="models/model1.usdz"
       data-model-media-type="model/vnd.usdz+zip"
       data-model-filename="Apple_Free_USDZ.usdz"
       data-model-bytes="2940746"
       data-model-units="m"
       data-model-extent="0.3 0.2609 0.2878"
       data-model-up="Y"/>
  <figcaption>An apple, seen from the side.</figcaption>
</figure>
```

**Without a poster:**

```html
<figure id="P-…">
  <span data-model-id="M-…"
        data-model-src="models/model2.usdz"
        data-model-media-type="model/vnd.usdz+zip"
        data-model-filename="brain.usdz"
        data-model-bytes="8213004"
        data-model-up="Y">brain.usdz</span>
</figure>
```

**The carrier MUST NOT be a hyperlink to the model.** A reference from a
content document to a foreign resource is EPUBCheck `RSC-010`,
*"Reference to non-standard resource type found"*, and adding a manifest
`fallback` does not clear it. The carrier is therefore an ordinary
element bearing `data-model-src`, which is the profile's only normative
selector in any case.

The trade is worth stating: a reading system that knows nothing of this
profile cannot offer the file for download from the page. The model is
still a manifested resource, still in the package, and still
extractable — by a conforming reader (§6.9.7) or by unzipping, which the
colophon tells a person how to do (§7.4.3). An invalid publication would
be the worse bargain.

#### 6.9.1 Finding figures

**The single normative selector is `[data-model-src]`.** A reader MUST
locate 3D figures by that attribute, and MUST NOT rely on the element
being an `<img>`, on the file-name pattern, on the `<figure>` wrapper, or
on the presence of any `<model>` element. Attribute order is not
significant.

#### 6.9.2 Attributes

| Attribute | Required | Value |
|---|---|---|
| `data-model-src` | **yes** | path to the model, relative to the containing document |
| `data-model-id` | **yes** | the model's handle, `M-<UUID>`; not an address |
| `data-model-media-type` | **yes** | one of §6.9.3 |
| `data-model-filename` | **yes** | the writer's own file name, XML-escaped |
| `data-model-bytes` | **yes** | decimal integer, the size as published |
| `data-model-up` | **yes** | exactly `Y` or `Z` |
| `data-model-units` | no | when present, the literal `m` |
| `data-model-extent` | no | three numbers, space-separated, metres, `%.4g` |
| `data-model-reduced` | no | what was done, e.g. `textures:2048 quality:85` |
| `data-model-source-bytes` | no | decimal integer, size of the unreduced original |
| `data-model-source` | no | DOI or URL of the full-resolution original |

The `<figure>`'s `id` is `P-<UUID>` and `data-model-id` is `M-<UUID>`
with the same UUID. The **`P-` address** is what citations and links
resolve to; `M-` is the model's internal handle.

#### 6.9.3 Media types

| Extension | `media-type` |
|---|---|
| `usdz` | `model/vnd.usdz+zip` |
| `reality` | `application/x-reality` |
| `glb` | `model/gltf-binary` |

A reader MUST treat an unrecognised media type as "cannot display" and
fall back to the poster. `model/vnd.usdz+zip` is not IANA-registered;
match it exactly.

#### 6.9.4 Up-axis, units and extent

`data-model-up` is always emitted and a reader MUST trust it rather than
applying its own default. `Y` is USD's documented fallback where a layer
states no up axis; glTF and Reality are Y-up by definition.

`data-model-units` and `data-model-extent` appear **together or not at
all**. A reader MUST NOT infer a scale from one without the other.

When present, `data-model-extent` is the model's real-world bounding
size in metres as `x y z`. Parse by whitespace split; values are printed
with `%.4g`, so `0.02339` and `2.5e-05` are both possible. A reader
SHOULD present the model at that size.

When absent, the writer does not know the size and has not invented
one. A reader MUST use a neutral default of its own choosing and SHOULD
let the person adjust it. **Assuming metres for a model that never
stated them can build a hundredfold object; this is the one failure
worse than having no scale at all.**

#### 6.9.5 The poster

The poster is **editorial, not a thumbnail**: the writer opened the
model, turned it to the side worth showing, and captured that view.

1. A reader MUST show the poster as the figure's resting state.
2. A reader MUST NOT auto-render or auto-spin the model in its place.
3. Activation MUST be deliberate — a tap, a click, a visible
   affordance.
4. A reader SHOULD reserve the poster's box before substituting a live
   view, so the page does not jump.
5. The poster MUST be composited on the page colour with its alpha
   preserved, MUST NOT be given a frame, and MUST NOT be assumed square.

Where no poster exists the carrier is as shown above. A reader MUST
render it as an actionable figure, MUST NOT render an empty box, and
SHOULD NOT substitute a generated thumbnail without saying it is
generated.

#### 6.9.6 Description and accessibility

The `<figcaption>` is the primary description, and a reader SHOULD
prefer it.

The poster's `alt` and the `<figcaption>` MUST be **semantically
consistent** — they MUST NOT describe different things — but they need
not be identical. Repeating a visible caption verbatim in `alt` makes a
screen reader announce the same sentence twice, and W3C guidance
recognises adjacent text as a reason an image may carry `alt=""`.

A writer MAY:

- carry the same text in both, which is the simplest thing and remains
  conforming;
- write a shorter `alt` describing what the poster shows, with the
  `<figcaption>` carrying the fuller caption;
- carry `alt=""` where the immediately adjacent `<figcaption>` already
  conveys the information.

Where the writer wrote no description at all, `alt` is the empty string
and there is **no `<figcaption>`**. A reader **MUST NOT** substitute
`data-model-filename` as alternative text: `turbine_v3_final.usdz` is
not a description, and presenting it as one asserts an accessibility the
publication does not have. A reader MAY show the file name as a visible
label, which is a different act.

A publication MUST NOT claim `alternativeText` (§4.6) on the strength of
an empty `alt` unless every such image has an adjacent caption.

#### 6.9.7 Extraction

A reader MUST NOT transcode, recompress or rewrite a model when
extracting or exporting it. It MUST offer the bytes unchanged, under the
name in `data-model-filename` — which is **not** the name inside the
package.

#### 6.9.8 Reader algorithm for one figure

1. Select the elements matching `[data-model-src]`.
2. Read the attributes of §6.9.2. Optionally join to the interaction
   record's `models` entry by `data-model-id`; the carrier governs
   (§11.4).
3. Resolve `data-model-src` against the containing document and confirm
   the resource exists.
4. Check `data-model-media-type` against what can be rendered. If it
   cannot, stop and keep the poster.
5. Render the poster as the resting state (§6.9.5).
6. Show `<figcaption>`, else nothing (§6.9.6).
7. On deliberate activation, present the model: apply `data-model-up`
   always; apply `data-model-extent` in metres only with
   `data-model-units="m"` beside it, otherwise an adjustable neutral
   default.
8. Offer `data-model-source` where present; warn on
   `data-model-bytes` before a large transfer on a metered connection.
9. Offer extraction of the unmodified file under
   `data-model-filename`.

### 6.10 Stretchtext

Contracted text: a marker in the running text, and the hidden content in
an `<aside>` immediately after the enclosing block.

```html
<p id="P-…">Visible text
  <a class="ot-stretchtext" role="button" aria-expanded="false"
     aria-controls="st-ABC123" href="#st-ABC123">››</a> …
</p>
<aside class="ot-stretchtext-content" id="st-ABC123" hidden="hidden">
  <p>The contracted passage.</p>
</aside>
```

- The **presence** of the `hidden` attribute is the state; XHTML-style
  `hidden="hidden"` is the serialisation.
- A reader that toggles it MUST keep `aria-expanded` in sync and MUST
  NOT navigate.
- The aside's content is part of the publication: it MUST be included in
  full-text search and in extraction.
- Stretchtext MUST NOT nest.
- The interaction record MAY carry a `stretchtext` index (§9.4).

An unaware reader shows the visible text and, because the aside is
`hidden`, does not show the contracted passage — acceptable degradation
under §1.2, because the passage is by authorial intent secondary.

### 6.11 Cross-document quote links

A passage that quotes or transcludes another publication MUST carry the
relationship in the **semantic record** (§8.5), naming the target's
**edition identifier** and the target's **address**:

```json
{ "rel": "cites",
  "fromAddress": "content.xhtml#P-68353888",
  "toEdition": "urn:uuid:5a1c…",
  "toAddress": "content.xhtml#P-9F2A…",
  "quotedText": "the quoted words" }
```

That is the durable representation and the only one required. It
identifies the target by identity rather than by location, which is what
makes it resolvable: a reader looks the edition up in whatever library
it has.

**In the content document**, a publication MUST NOT rely on a relative
URL reaching into another EPUB. A relative URL resolves inside the
containing publication's own container; EPUB defines no such traversal.
Instead:

- where the target has a **public Web URL**, link to that;
- otherwise link the visible citation to its **own bibliography entry**,
  exactly as any other citation (§6.3) — which is what a reader without
  the target publication can act on anyway;
- either way, the writer MAY mark the relationship with
  `data-origami-rel="cites"` or `"transcludes"`.

```html
<a epub:type="biblioref" role="doc-biblioref"
   href="backmatter.xhtml#bib-232A9EED"
   data-origami-rel="cites">"the quoted words" (Author, Year)</a>
```

`origamitext://open/<edition-id>#<element-id>` MAY be carried as a
convenience action, in `data-origami-action` or in the semantic record.
It MUST NOT be the only representation: a reader that does not know the
scheme MUST still be able to determine the target from §8.5.

### 6.12 Discovery hints

A content document MAY declare the profile in its `<head>`. The href is
an external identifier rather than a package resource, so this is safe:

```html
<link rel="profile" href="https://origamitext.org/profile/1.0"/>
```

A content document **MUST NOT** reference a metadata record with an
XHTML `<link>`, `rel="describedby"` included: it would make the record
contribute to the rendering and so require a manifest entry §4.4.1
forbids, and a reading system may legitimately treat a reference to an
undeclared resource as an error.

A writer MAY instead embed a **small discovery record** — pointers only,
never a copy of the semantic graph:

```html
<script type="application/json" id="origami-metadata-discovery">
{
  "format": "origami-text",
  "profile": "https://origamitext.org/profile/1.0",
  "metadata": [
    { "kind": "visual-meta",  "href": "visual-meta.json", "mediaType": "application/json" },
    { "kind": "interaction",  "href": "origami.json",     "mediaType": "application/json" },
    { "kind": "bibliography", "href": "references.bib",   "mediaType": "application/x-bibtex" }
  ]
}
</script>
```

A pointer inside a JSON string is not an XHTML resource reference and
does not make the record contribute to the rendering, so this does not
breach §4.4.1. Both hints are **supplementary**: the package (§4.4)
remains authoritative, because many HTML-to-text pipelines discard
`<head>` and `<script>`. A writer that wants no argument about it may
omit the block; §7.4's colophon already tells a human reader that the
metadata exists.

---

## 7. Backmatter

Sections carry standard semantics. A publication MAY place them in any
content document.

### 7.1 Glossary

```html
<section epub:type="glossary" role="doc-glossary">
  <h2>Glossary</h2>
  <dl>
    <dt id="gloss-3C9BEE22-FF89-4EED-AFC5-ECD1550C06FE">3D Space Positioning</dt>
    <dd>The arrangement of document elements in a three-dimensional space…</dd>
  </dl>
</section>
```

The `<dt>` carries the address and the term; the `<dd>` carries the
definition. This is what an ordinary reader shows, and it is
authoritative for display (§11.4).

### 7.2 Bibliography

```html
<section epub:type="bibliography" role="doc-bibliography">
  <h2>References</h2>
  <ol>
    <li id="bib-232A9EED-512F-40C7-AB46-AB086D49733B">
      Halevi, Gali; Moed, Henk F.; Bar-Ilan, Judit (2015). Accessing, Reading…
    </li>
  </ol>
</section>
```

The list item carries the address and a human-readable rendering,
**derived** from the bibliography record (§10).

### 7.3 Endnotes

```html
<section epub:type="endnotes" role="doc-endnotes">
  <h2>Notes</h2>
  <aside epub:type="endnote" role="note" id="en-D16AD8DE-…">
    <p>https://www.acm.org/publications/taps/taps-instructions</p>
  </aside>
</section>
```

The note's `role` is **`note`**. `doc-endnote` MUST NOT be used: DPUB-ARIA
deprecated it, and it is not among the roles `aside` accepts, so
EPUBCheck reports `RSC-005` and warns `RSC-017`. `epub:type="endnote"`
carries the semantics.

### 7.4 The rendered Visual-Meta colophon

> Metadata that exists only in a hidden JSON payload does not survive
> the things documents actually go through. It does not survive
> printing, a copy-paste into an email, extraction to plain text,
> conversion to another format, or a reading system that knows nothing
> of this profile. Visual-Meta's founding principle is that a document
> explains its own augmentation, in words, where a person can see them.

A publication **MUST** contain a rendered Visual-Meta colophon, as a
`<section epub:type="colophon">`, SHOULD place it in the end matter, and
MUST include three components in this order — four where the
publication declares any rights (§7.4.4). A conforming reader **MUST**
be able to display it — which for most readers means not suppressing it,
since it is ordinary body text.

#### 7.4.1 The explanatory header

A short statement of what Visual-Meta is and why it is there, addressed
to a person who has never heard of it. A writer MAY use its own wording;
this is the reference text, and a writer with nothing better to say
SHOULD use it verbatim:

> "This document includes Visual-Meta to enable permanent
> self-citation, metadata preservation, and seamless reference
> management across digital, Web, and printed formats."

#### 7.4.2 The visual BibTeX self-citation

The publication's own canonical citation, as **plain-text BibTeX**, in a
monospaced block, so a person can select and paste it into a reference
manager — from the screen, or retyped from paper.

It MUST be marked up as preformatted text (`<pre>`, optionally wrapping
`<code>`) so line structure survives. The BibTeX MUST be valid and MUST
agree with the publication's own identity (§4.3). The citation key
SHOULD be a human-typable slug — `hegland2026origami` — rather than the
publication UUID, because this block exists to be read and retyped.
Unknown fields MUST be omitted rather than emitted empty.

```html
<pre>@book{hegland2026origami,
  author    = {Hegland, Frode and Reader, Alice},
  title     = {The Origami EPUB Profile: Extended Structural Specification},
  publisher = {Future Text Publishing},
  year      = {2026},
  isbn      = {978-1-234567-89-0},
  doi       = {10.1234/origami.2026.1},
  url       = {https://example.org/spec/origami-epub}
}</pre>
```

This is a **self**-citation and is not part of the bibliography record
(§10), which holds works this publication cites. A writer MAY also emit
it there; where it does, both MUST agree and this block governs what a
person sees.

#### 7.4.3 The machine metadata access map

Plain text naming where the machine-readable records are inside the
container and how software or a person can get at them.

The paths stated here **MUST** be the actual paths in this publication,
MUST match the `<link rel="record">` declarations (§4.4), and MUST NOT
name `META-INF/` (§4.4.2). A writer SHOULD generate this list from the
same data structure that generates the package declarations, so the
prose cannot drift from the packaging.

A colophon that states a path the records are not at is worse than no
colophon: it is a confident instruction to look in the wrong place, and
because it is prose nothing will ever report it as an error. §18
therefore requires a validator to check it.

#### 7.4.4 The rights statement

Where the publication declares any of the rights properties of §4.8, the
colophon **MUST** state them in human-readable form.

```html
<h3>Rights</h3>
<p>© 2026 Copyright held by the owner/author(s). Licensed under
  <a href="https://creativecommons.org/licenses/by/4.0/">Creative Commons
  Attribution 4.0 International</a>. When reusing this work, credit
  Frode Alexander Hegland.</p>
```

The values stated here **MUST** be generated from the same values as the
package declarations, so the prose and the metadata cannot drift apart —
the same constraint §7.4.3 puts on the record paths, and for the same
reason: this is prose, so nothing else will ever notice when it goes
stale.

Rights is the clearest case in the whole profile for §1.14. It is
precisely the metadata that has to survive being printed, pasted into an
email, or read in a system that has never heard of this profile — and
the one whose absence has consequences outside the software.

Where a resource inside the publication carries different terms from the
publication itself, this is one of the two places that MUST say so
(§4.8.3).

#### 7.4.5 Complete example **[I]**

```html
<section epub:type="colophon" id="origami-publication-info">
  <h2>Visual-Meta Colophon</h2>

  <p>This document includes Visual-Meta to enable permanent
    self-citation, metadata preservation, and seamless reference
    management across digital, Web, and printed formats.</p>

  <h3>Self-citation record</h3>
  <pre>@book{hegland2026origami,
  author    = {Hegland, Frode and Reader, Alice},
  title     = {The Origami EPUB Profile: Extended Structural Specification},
  publisher = {Future Text Publishing},
  year      = {2026},
  isbn      = {978-1-234567-89-0},
  doi       = {10.1234/origami.2026.1},
  url       = {https://example.org/spec/origami-epub}
}</pre>

  <h3>Embedded machine-readable metadata</h3>
  <p>Structured metadata records are declared in this publication's
    package document and stored inside the EPUB container:</p>
  <ul>
    <li>Bibliographic and structural identity: <code>visual-meta.json</code></li>
    <li>Authored interaction and layout: <code>origami.json</code></li>
    <li>Bibliography: <code>references.bib</code></li>
  </ul>
  <p>To inspect the raw records, open this publication in a
    Visual-Meta-aware reader, or change the <code>.epub</code> extension
    to <code>.zip</code> and unpack the archive.</p>

  <h3>Rights</h3>
  <p>© 2026 Copyright held by the owner/author(s). Licensed under
    <a href="https://creativecommons.org/licenses/by/4.0/">Creative
    Commons Attribution 4.0 International</a>. When reusing this work,
    credit Frode Alexander Hegland.</p>

  <p>This publication conforms to the Origami Text 1.0 profile
    (https://origamitext.org/profile/1.0).</p>
</section>
```

#### 7.4.6 Reader obligations

1. A reader **MUST NOT** withhold the colophon. A reader that omits
   backmatter because its entries come from the records (§16.3) MUST
   exempt the colophon: the glossary, bibliography and endnotes are
   withheld because they are duplicated, and the colophon is not
   duplicated anywhere.
2. A reader MAY present it as a dedicated view rather than in the flow,
   and SHOULD make the BibTeX block selectable and copyable as text.
3. A reader **MUST NOT** treat the colophon as authoritative metadata.
   It is a rendering for people. Where it disagrees with the package or
   the records, §11.4 governs and the disagreement SHOULD be reported.
4. The colophon **MUST NOT** affect element addressing. It is about the
   publication rather than part of it, so a document containing only a
   colophon and record sections does not make a publication
   multi-document for any purpose.

#### 7.4.7 The three levels of discovery **[I]**

```
OPF                           → authoritative machine discovery
JSON records                  → rich machine interpretation
Rendered Visual-Meta colophon → human, print, copy-paste and LLM discovery
```

---

## 8. The semantic record

Media type `application/json`, declared `properties="origami:visual-meta"`.

**Authoritative for:** concepts, citations and their relationships,
document-level semantic metadata, the structure index, endnote records,
cross-document relationships, lineage, the equation index.

It MUST NOT contain `tables`, `map` or `models` (§9.0).

### 8.1 Self-identification

REQUIRED. A record extracted from its publication MUST still be
identifiable.

```json
{
  "visual-meta": {
    "format": "visual-meta",
    "version": "1.1",
    "profile": "https://origamitext.org/profile/1.0",
    "describes": "urn:uuid:97d7808d-d373-4ba7-a350-f6a7895c8811",
    "generator": "Author (macOS)"
  }
}
```

`describes` MUST equal the publication's `dc:identifier`.

### 8.2 Document and structure

```json
"document": {
  "identifier": "urn:uuid:97d7808d-…",
  "work": "urn:uuid:0f2c6a51-…",
  "release": "author revision 3",
  "modified": "2026-09-24T09:30:57Z",
  "title": "Origami Text (gloss)",
  "authors": ["Frode Alexander Hegland"],
  "rights": "© 2026 Copyright held by the owner/author(s).",
  "license": "https://creativecommons.org/licenses/by/4.0/",
  "defaultDocument": "content.xhtml"
},

"structure": {
  "headings": [
    { "id": "H-0979114B-…", "level": 2,
      "text": "Why Current Scholarly Formats Fall Short",
      "href": "content.xhtml#H-0979114B-…",
      "address": "2" }
  ]
}
```

`defaultDocument` is OPTIONAL and declares the content document against
which bare-fragment references in this record resolve. A record that
omits it MUST use full path-plus-fragment addresses everywhere.

`structure.headings` is **derived** from the XHTML (§11.3) and exists for
navigation without parsing the body. `address` is the positional label,
informative only (§5.2).

`rights`, `license`, `rightsHolder` and `accessRights` are derived from
the package, which governs (§4.8.2, §11.4). `license` is a URI; a
pre-1.0 `license` holding prose MUST be read as `rights`.

A `document.digest` member MUST NOT be present (§12.2). A
`document.hasVersion` member MUST NOT be present (§4.3).

### 8.3 Concepts

```json
"concepts": [
  {
    "id": "97887240-D108-40BE-A12F-C022A5C2CE5B",
    "name": "Cognitive Accessibility",
    "description": "The design of digital content and interfaces to accommodate…",
    "tag": "concept",
    "urls": ["https://…"],
    "citationIdentifiers": ["A6CBF363-1C82-4415-B41F-4F4B7FBB4560"],
    "href": "backmatter.xhtml#gloss-97887240-D108-40BE-A12F-C022A5C2CE5B"
  }
]
```

`id` MUST be the identifier used in the glossary entry's address. `name`
and `description` MUST agree with the XHTML glossary, which governs
display (§11.4). `tag` is an open vocabulary.

### 8.4 Citations

```json
"citations": [
  { "id": "232A9EED-512F-40C7-AB46-AB086D49733B",
    "number": 2,
    "href": "backmatter.xhtml#bib-232A9EED-…",
    "concepts": ["97887240-…"] }
]
```

`id` is the BibTeX key in the bibliography record (§10). A citation entry
**MUST NOT** carry a `bibtex` or `csl` member: the bibliography record
is canonical (§11.4).

### 8.5 Relationships

```json
"links": [
  { "rel": "cites",
    "fromAddress": "content.xhtml#P-68353888-…",
    "toEdition": "urn:uuid:5a1c…",
    "toAddress": "content.xhtml#P-9F2A…",
    "quotedText": "the quoted words",
    "action": "origamitext://open/5a1c…#P-9F2A…" }
]
```

`rel` is `cites` or `transcludes`. `toEdition` and `toAddress` are
REQUIRED; `action` is OPTIONAL and MUST NOT be the only representation
(§6.11).

### 8.6 Lineage

```json
"lineage": [
  { "id": "P-NEW1…", "replaces": ["P-OLD1…", "P-OLD2…"],
    "inEdition": "urn:uuid:5a1c…" }
]
```

A claim, not a fact (§5.4).

### 8.7 Endnotes

```json
"endnotes": [
  { "id": "en-D16AD8DE-…",
    "href": "content.xhtml#en-D16AD8DE-…",
    "anchor": "content.xhtml#P-F9868FD4-…",
    "text": "https://www.acm.org/publications/taps/taps-instructions" }
]
```

`href` is the note's own address; `anchor` is where its reference sits.

### 8.8 Equations

The equation index (§6.7.1). OPTIONAL; MathML in the body is
authoritative.

```json
"equations": [
  { "id": "E-71B2…", "href": "content.xhtml#E-71B2…",
    "display": "block", "label": "1", "format": "mathml",
    "tex": "E = mc^2", "tex-sha256": "…", "mathml-sha256": "…",
    "converter": "latexml", "section": "content.xhtml#H-0979…",
    "heading": "Why EPUB Now?" }
]
```

---

## 9. The interaction record

Media type `application/json`, declared `properties="origami:interaction"`.

**Authoritative for:** table formulas, authored layouts, interaction
declarations, and the 3D model convenience index.

> **This record holds authored interaction, not reader state.** The
> distinction is easy to lose, because "interaction" and "runtime" sound
> adjacent, and losing it would undo §1.11 and §14. **No reader state of
> any kind may be written into a publication** — not reading position,
> not the chosen view, not where a person left a 3D model in their room,
> not a highlight. What lives here is what the *writer* authored: the
> formulas behind a table, the arrangement the writer composed, the
> figures' declared facts.

### 9.0 The separation, and how it is enforced

Carrying the same semantic content in both records under different field
names is the defect this section exists to prevent: two copies, no
declared authority, and readers that discard one of them arbitrarily.

**The interaction record MUST NOT contain any of these members, at the
top level or nested at any depth:**

| Forbidden member | Its only home |
|---|---|
| `concepts`, `glossary` | semantic record `concepts` (§8.3) |
| `citations`, `references` | semantic record `citations` (§8.4) + bibliography record (§10) |
| `headings`, `structure` | semantic record `structure.headings` (§8.2) |
| `endnotes`, `footnotes` | semantic record `endnotes` (§8.7) |
| `links` | semantic record `links` (§8.5) |
| `lineage` | semantic record `lineage` (§8.6) |
| `equations` | semantic record `equations` (§8.8) |
| `bibliography`, or any BibTeX string under any name | bibliography record (§10) |

Symmetrically, the semantic record MUST NOT contain `tables`, `map` or
`models`.

Reader-state members are likewise forbidden here: `readingPosition`,
`readerState`, `runtimeState`, `annotations`, `highlights`, `bookmarks`,
`lastRead`.

`document` appears in both records — as `describes` plus a small
identity block — and that is deliberate and permitted: each record must
be identifiable on its own (§1.13). It is governed by §11.

**Four enforcements:**

1. **Deletion, not translation.** A writer migrating to 1.0 removes
   these members rather than renaming them. A renamed member is a second
   copy waiting to diverge; a deleted one cannot.
2. **Export-blocking error.** A writer MUST refuse to export a
   publication whose interaction record contains a forbidden member
   (§17.1). Unlike the value disagreements of §17.2, a duplicated
   semantic member is not a fact two sources disagree about; it is a
   fact with no owner.
3. **Schema rejection.** The published schemas declare every forbidden
   member, so a record carrying one is rejected by the schema itself
   (§18).
4. **A deterministic rule for files that already have them.** §16.3
   tells readers exactly what to do — single-source with fallback, never
   merge — so no reader has to invent a policy and no two readers invent
   different ones.

### 9.1 Self-identification

```json
{
  "origami": {
    "format": "origami-text",
    "version": "1.0",
    "profile": "https://origamitext.org/profile/1.0",
    "describes": "urn:uuid:97d7808d-…",
    "created": "2026-09-24T09:30:57Z",
    "generator": "Author (macOS)"
  }
}
```

### 9.2 Tables

```json
"tables": [
  {
    "identifier": "T-9A3F…",
    "href": "content.xhtml#P-4C1E…",
    "rowCount": 2,
    "columnCount": 3,
    "cells": [
      [ { "value": "Year" }, { "value": "Papers" }, { "value": "Share" } ],
      [ { "value": "2024" }, { "value": "120" },
        { "value": "0.48", "formula": "=B2/250" } ]
    ]
  }
]
```

`identifier` matches the body's `data-table-id`; `href` is the address of
the element that places it. `cells` is row-major. A cell has a `value` —
the computed value as published — and an optional `formula`. A reader
that does not evaluate formulas MUST show `value`.

**Formula syntax:** a leading `=`, A1-style cell references (column
letters, 1-based rows) **within this table only**, the operators
`+ - * / ^`, parentheses, and functions a writer MUST document if it
uses any beyond `SUM`, `AVERAGE`, `MIN`, `MAX`, `COUNT`, `ROUND`. A
formula **MUST NOT** reference another table, another document, or any
external resource. A reader that cannot evaluate a formula MUST fall
back to `value`.

### 9.3 Authored layouts

An authored arrangement of elements in a normalised space, and declared
relationships between them.

```json
"map": {
  "views": [
    { "id": "V-1", "name": "The argument",
      "space": { "units": "points", "convention": "right-handed-y-up" },
      "nodes": [ { "ref": "content.xhtml#P-68353888-…",
                   "x": 0.24, "y": -0.10, "z": 0.0 } ] }
  ],
  "connections": [
    { "from": "content.xhtml#P-68353888-…", "to": "content.xhtml#P-7AAA…" }
  ]
}
```

`ref`, `from` and `to` are element addresses (§5.1). Coordinates are
writer-defined and unitless unless `space.units` says otherwise; a
reader MUST NOT interpret them as metres by default.

**A reader MUST NOT write reader-created positions into this
structure** (§1.11, §14).

### 9.4 Interaction declarations

```json
"stretchtext": [ { "id": "st-ABC123", "anchor": "content.xhtml#P-…" } ],
"views":       [ { "name": "Headings only", "fold": "headings" } ]
```

Both OPTIONAL and both derived conveniences: the body is authoritative
for stretchtext, and a reader MAY offer any folding it likes.

### 9.5 3D models

```json
"models": [
  { "id": "M-F93D1917-…", "href": "models/model1.usdz",
    "media-type": "model/vnd.usdz+zip",
    "filename": "Apple_Free_USDZ.usdz", "bytes": 2940746,
    "up": "Y", "units": "m", "extent": [0.3, 0.2609, 0.2878],
    "poster": "images/model1-poster.png",
    "description": "An apple, seen from the side.",
    "reduced": "textures:2048 quality:85",
    "source-bytes": 25724928,
    "source": "https://doi.org/10.5281/zenodo.1234567" }
]
```

A **convenience copy** of §6.9's carrier attributes, joined by
`id` ↔ `data-model-id`. `extent` is an array of three numbers here and a
space-separated string in the attribute; the two MUST agree, and the
carrier governs (§11.4). `units` and `extent` MUST appear together or
not at all.

---

## 10. The bibliography record

Media type `application/x-bibtex`, declared
`properties="origami:bibliography"`. **Canonical for bibliographic
data.**

```bibtex
@inproceedings{232A9EED-512F-40C7-AB46-AB086D49733B,
  author = {Halevi, Gali and Moed, Henk F. and Bar-Ilan, Judit},
  title = {Accessing, Reading and Reusing Scholarly Content},
  year = {2015},
  abstract = {…},
  doi = {10.1234/…}
}
```

The BibTeX key MUST be the identifier used in the bibliography entry's
address and in `citations[].id` (§8.4).

BibTeX strings MUST NOT be duplicated into the semantic or interaction
records, nor into `data-bibtex` or `data-csl-json` attributes in the
body. A writer MAY emit CSL JSON as an additional, clearly-marked
derived record (`properties="origami:bibliography-csl"`); where it does,
the BibTeX remains canonical.

---

## 11. Controlled redundancy

Redundancy is permitted and sometimes desirable — for graceful
degradation, human inspection, machine discovery, standalone export, and
recovery if one representation is lost. It is not permitted as an
accident of two implementations wanting different shapes.

### 11.1 Two kinds of redundancy

| | **Exact duplicate** | **Derived representation** |
|---|---|---|
| What it is | The same data, serialised twice in the same model | The same fact expressed in a different representation |
| Example | `visual-meta.json` ↔ the embedded `<script>` copy | `<figcaption>` ↔ `models[].description`; `data-model-extent="0.3 0.2 0.2"` ↔ `[0.3, 0.2, 0.2]`; XHTML glossary ↔ `concepts[]` |
| Field names | Identical | Necessarily different |
| Equivalence test | **Canonical (JCS) hash equality** | Semantic agreement, per field |
| A mismatch is | an **error** | a **warning**, resolved by precedence |

An exact duplicate has no excuse for differing: it is one payload
written twice by one writer in one pass. A derived representation cannot
be compared by hash at all.

Both kinds share three requirements:

1. One representation MUST be declared **authoritative** (§11.4).
2. The redundancy MUST have a stated reason.
3. A reader MUST NOT silently **merge** two representations of the same
   fact. It takes one, by precedence.

### 11.2 Exact duplicates

Where a publication serialises the same record twice, both copies MUST
use the same model and MUST be **canonically equivalent**. Byte equality
is too brittle — whitespace, member order and escaping vary without
changing meaning — so the test is that their **RFC 8785 (JCS) canonical
forms are identical**:

```
canonicalize with RFC 8785  →  SHA-256  →  compare
```

The one case in 1.0 is the embedded copy of the semantic record:

```html
<script type="application/json" id="visual-meta-payload"
        data-origami-derived-from="visual-meta.json">…</script>
```

Both copies MUST declare the same `visual-meta.version`, MUST describe
the same publication, and MUST produce the same canonical hash. Where
they differ: the record declared in the package is authoritative, a
validator MUST report an **error**, a writer MUST refuse to export
(§17.1), and a reader MUST NOT merge them.

`data-origami-derived-from` names the record the copy was made from, so
the relationship is stated rather than inferred from the element's id.

### 11.3 Derived representations

Where the same fact is expressed in two representations that cannot
share a serialisation:

1. They **SHOULD** agree semantically.
2. Where they disagree, **precedence decides** (§11.4) — deterministically,
   with no reference to which looks more plausible.
3. A disagreement is a **warning**: a validator MUST report it, and a
   writer MUST NOT refuse to export for it (§17.2).
4. A reader MUST use the authoritative representation and MUST NOT blend
   the two. Where it surfaces the disagreement at all, it does so to a
   log, not to the person reading.

A disagreement here is not an error for a practical reason: a writer that
refuses to export a finished paper because a caption and an `alt`
attribute were worded differently teaches its user to fight it. The
publication remains unambiguous regardless, because precedence is
declared in advance.

### 11.4 Precedence

| Information | Authoritative | Derived copies permitted in |
|---|---|---|
| Text, structure, reading order | content documents | — |
| Element address | content document `id` | records may repeat it |
| Edition identity | OPF `dc:identifier` | both records' `describes` |
| Work identity | OPF `dcterms:isVersionOf` | semantic record `document.work` |
| Release | OPF `dcterms:modified` | semantic record `document.modified` |
| Resources and media types | OPF manifest | carrier attributes |
| Heading list | content documents | semantic record `structure.headings` |
| Glossary term and definition | content document glossary | semantic record `concepts` |
| Concept relationships | semantic record | — |
| Citation placement | content document `biblioref` | — |
| Bibliographic record | bibliography record (BibTeX) | XHTML rendering; CSL |
| Table presented values | content document `<table>` | interaction record `cells[].value` |
| Table formulas | interaction record | — |
| Equation | MathML in the body | `data-latex`; `equations[].tex` |
| 3D figure facts | the `[data-model-src]` carrier | interaction record `models` |
| Figure description | `<figcaption>` | `alt`; `models[].description` |
| Authored layouts | interaction record | — |
| Anything else generated | non-authoritative | — |

---

## 12. Digests

### 12.1 Artifact digest

The integrity of a publication is a SHA-256 over the **exact `.epub`
bytes**. It MUST NOT appear inside the publication. It belongs in a
catalogue, a signature, or a distribution manifest.

### 12.2 No text fingerprint

1.0 defines **no** text fingerprint. A publication MUST NOT carry a
`digest` member; a validator MUST report one as an error; a reader MUST
ignore one in a pre-1.0 file.

A later profile **SHOULD NOT** define a whole-document text fingerprint.
The reasoning is recorded so the field is not reintroduced by someone
who assumes it was merely unfinished. A digest answers "are these the
same?", and a document-level hash answers none of the questions the
format has:

- **"Have these bytes been tampered with?"** — the artifact digest
  (§12.1), which covers text, models, records and package together. A
  text-only hash is strictly weaker.
- **"Is this the same edition?"** — `dc:identifier`, which is cheaper,
  stable, and does not change when a typo is fixed.
- **"Is this the same work?"** — `dcterms:isVersionOf`.
- **"Is this passage the same passage as the one I annotated, in this
  later edition or in the PDF of it?"** — the real question, and the one
  a document-level hash is least able to answer: **any** change anywhere
  changes it, so it reports "different" for a corrected comma, and it is
  unusable across formats.

That last question is per-element, and the format answers it
per-element: the address (§5.1) plus textual evidence in the annotation
itself (§5.4). That mechanism degrades usefully where a hash cannot, by
finding the passage when it has moved and reporting a near-match when it
has been edited.

---

## 13. Scripting

> **No Origami-defined semantics or required Origami-reader behaviour may
> depend on scripting. Removing scripts MUST NOT remove information that
> a conforming Origami reader requires.**

- A reader MUST NOT execute publication scripts to obtain Origami
  semantics.
- A writer that includes a script MUST declare `properties="scripted"`
  on the content document, as EPUB requires.
- A writer SHOULD be able to emit a script-free variant of any
  publication.
- A browser enhancement MAY legitimately be absent when its script is.

A `<model>` element MUST NOT appear in a conforming publication: it is
not in EPUB's content model and EPUBCheck rejects it (`RSC-005`).

---

## 14. Authored intent and reader activity

> The publication carries assertions and authored presentations.
> External state carries reader activity and reader-created
> presentations.

| MAY be in the publication | MUST NOT be |
|---|---|
| authored concept maps and spatial arrangements | a reader moving an element |
| an authored 3D figure presentation (poster, extent, up-axis) | where a reader left a model in their room |
| authored reading views and timelines | personal desk layout, pose, focus |
| the writer's own notes as published text | highlights, notes, comments |
| glossary, references, endnotes | reading position, chosen view |

Reader state belongs in external W3C Web Annotation documents and
application storage. A conforming reader MUST NOT modify a publication.

---

## 15. Versioning and forward compatibility

### 15.1 Declaring the profile

`dcterms:conformsTo` (§4.2). The last path segment is `MAJOR.MINOR`.

### 15.2 Reader behaviour

- Unknown **MINOR**: a reader MUST read the publication.
- Unknown **MAJOR**: a reader MUST fall back to reading it as an
  ordinary EPUB rather than refusing it, and SHOULD say plainly that it
  is reading a newer profile.
- Absent: the publication is pre-1.0; §16.2 applies.

### 15.3 Unknown properties

A reader MUST ignore, without error:

- unknown members in any Origami JSON object;
- unknown `data-model-*` and `data-origami-*` attributes;
- unknown `<link rel="record">` `properties` values;
- unknown `epub:type` or `role` values.

A publication MUST NOT declare that a feature is required. §2.2 already
covers the case: a reader MUST NOT misrepresent a feature it does not
implement, and a publication is always presentable (§1.2). A future
minor version MAY introduce such a property once a real feature needs
it, which §15.4 makes a compatible addition.

### 15.4 Anticipated additions

These MUST NOT break a 1.0 reader: additional `data-model-*` attributes;
several model representations per figure (a reader SHOULD take the first
it supports); an `@context` member added to either record; additional
`<link rel="record">` records; and a general **per-resource rights**
mechanism, which 1.0 deliberately leaves to prose (§4.8.3).

---

## 16. Reader algorithm

### 16.1 Current-profile publication

1. Read `META-INF/container.xml`; locate the package document.
2. Read `dcterms:conformsTo`. Apply §15.2.
3. Read `dc:identifier`, `dcterms:isVersionOf`, `dcterms:modified`, any
   `schema:version`, and any `dcterms:replaces` / `isReplacedBy`.
4. Enumerate `<link rel="record">`; classify each by `properties`;
   ignore unknown kinds.
5. Read the semantic record. Verify `describes` against `dc:identifier`;
   on mismatch, treat the record as untrusted and report it.
6. Read the interaction record; same verification.
7. Read the bibliography record.
8. Parse **every** content document in spine order. Keep each element's
   `id` **unchanged**, and form addresses as `<document path>#<id>`
   (§5.1).
9. Resolve every metadata reference against those addresses. Report
   unresolved references; do not repair them silently.
10. Apply precedence (§11.4) wherever a fact appears twice.
11. Ignore what is not understood (§15.3).

### 16.2 Pre-1.0 publication (compatibility) **[I]**

Where `dcterms:conformsTo` is absent, a reader MAY:

1. look for a resource named `visual-meta.json`, else one whose path
   ends with it, else an embedded `<script id="visual-meta-payload">`;
2. look for `origami.json` the same way;
3. accept `data-id` as an address where `id` is absent;
4. accept the delimited equation block inside a content document
   (§6.7.1);
5. ignore `document.digest`;
6. preserve whatever address form existing annotations were written
   against, including bare ids for a single-document publication.

Item 6 is a property of the implementation's migration, not of the
format. Filename discovery MUST NOT be used in a publication that
declares the profile.

Reading **both** records where both exist is a MUST, not a MAY, and
§16.3 governs it.

### 16.3 Reading a publication whose records overlap

Pre-1.0 files carry the semantic members in both records (§9.0). This
rule is normative because two readers inventing their own policies is
how one document comes to mean two things.

**A reader MUST NOT merge two representations of the same fact.**
Concatenating two copies of a reference list is the specific failure to
avoid.

For each fact, a reader MUST take **one** source, in this order, and
stop at the first that yields anything:

| Fact | First | Then |
|---|---|---|
| concepts / glossary | semantic record `concepts` | interaction record `glossary` |
| citations | semantic record `citations` | interaction record `references` |
| bibliographic data | bibliography record | whichever JSON carries BibTeX |
| headings | content documents | semantic `structure.headings`, then interaction `headings` |
| endnotes | semantic record `endnotes` | interaction record `endnotes` |
| equations | semantic record `equations` | the delimited block, then a `math[id]` scan |
| tables | interaction record `tables` | semantic record `tables` |
| authored layouts | interaction record `map` | semantic record `map` |
| 3D figure facts | the `[data-model-src]` carrier | interaction record `models` |

"Yields anything" means the member is present and non-empty. A present
but empty member MUST be treated as absent, so that a writer emitting
`"citations": []` does not silently suppress the other copy.

Note that tables and layouts resolve in the opposite direction from the
semantic members: 1.0 gives them to the interaction record, while
pre-1.0 files put them in the semantic record. Reading them
interaction-first satisfies both and needs no profile check.

Where both sources are present and **disagree**, a reader SHOULD report
it — to a log, not to the person reading — and MUST NOT let the
disagreement change which source it used.

---

## 17. Writer requirements

### 17.1 Refuse to export

Referential integrity. These publications are broken, not merely
inconsistent:

- metadata references an element address that does not exist;
- two elements in one document share an `id`;
- a `<link rel="record">` names a resource that is not in the package;
- a citation references a BibTeX key with no record;
- a `glossref` or `noteref` href names a missing entry;
- a `[data-model-src]` names a missing resource;
- a foreign resource that EPUB 3.3 requires a fallback for has none
  (§4.5 — **not** a posterless 3D figure, whose model is exempt);
- a `<model>` element is present (§13);
- an embedded record's canonical hash differs from its sidecar (§11.2);
- the interaction record contains a member §9.0 forbids, or the semantic
  record contains `tables`, `map` or `models`;
- a record appears both as a manifest `<item>` and as a
  `<link rel="record">`, is referenced from a content document, or sits
  in `META-INF/` (§4.4.1, §4.4.2);
- there is no `epub:type="colophon"` section, or one whose stated record
  paths do not resolve, or whose BibTeX self-citation does not parse
  (§7.4);
- a content document or a metadata record is encrypted (§4.8.4).

### 17.2 Warn, but export anyway

Value disagreements. Precedence (§11.4) keeps the publication
deterministic in every one of these cases:

- a DOI, title or author differing between the OPF and a record;
- `data-model-up` or `extent` differing from the `models` entry;
- a glossary definition differing between XHTML and the semantic record;
- a heading list differing from the content documents;
- a 3D figure over a size budget whose `data-model-source` is absent;
- no rights statement at all, or a `dcterms:license` that is not a URI
  (§4.8);
- a colophon whose rights statement disagrees with the package.

Refusing to export a finished publication over a metadata disagreement
teaches a writer to fight the tool.

---

## 18. Validation

Two independent levels; both MUST pass.

```
EPUB validation (EPUBCheck, 3.3)   +   Origami profile validation
```

### 18.1 The published schemas

Every Origami JSON structure MUST be described by a published, versioned
JSON Schema (§1.8):

| Schema | Describes |
|---|---|
| `visual-meta-1.1.schema.json` | the semantic record (§8) |
| `origami-interaction-1.0.schema.json` | the interaction record (§9) |

Both are JSON Schema 2020-12. §9.0's separation and §14's reader-state
boundary are expressed **structurally**: every forbidden member is
declared so that a record carrying one is rejected by the schema itself,
not by a validator remembering to look. The schemas also enforce: no
`document.digest`; no `document.hasVersion`; no BibTeX or CSL inside a
citation; `extent` and `units` required together; an up-axis of exactly
`Y` or `Z`; only the registered model media types; no formula reaching
outside its table; no `links` entry without a target edition; no address
containing whitespace.

Unknown members are accepted throughout, because §15.3 requires a reader
to ignore what it does not understand and a schema that rejected them
would make every forward-compatible addition a breaking change.

### 18.2 The profile validator

The validator MUST check: the profile declaration is present and its
MAJOR understood; work, edition and release identifiers are present and
well-formed; every declared record resolves; every record
self-identifies and `describes` the publication; every record validates
against its schema; `id` uniqueness per document; `id` is a valid
NCName; every metadata reference resolves to an existing address; no
`data-id`; no `<model>`; every §17.1 error; every §17.2 warning; 3D
integrity (§6.9); citation and glossary integrity; canonical-hash
equality of any embedded duplicate; accessibility claims consistent with
the content.

Three checks are called out because they are cheap, unambiguous, and the
ones this profile exists to prevent regressing:

- **Record separation (§9.0).** Walk each record to any depth for the
  forbidden member names. **Error.**
- **Record packaging (§4.4.1, §4.4.2).** For each `<link rel="record">`,
  assert the href is not a manifest item, is not under `META-INF/`, and
  is not referenced from any content document. **Error.**
- **Colophon (§7.4).** Assert the section exists; that it carries an
  explanatory statement, a `<pre>` BibTeX block that parses, and at
  least one stated record path; and that **every path it states resolves
  to a declared record**. This is the reason the colophon is
  machine-validated at all: it is prose, so nothing else will ever
  notice when it goes stale. **Error.**
- **Encryption (§4.8.4).** Where `META-INF/encryption.xml` is present,
  assert that nothing it encrypts is a content document or a metadata
  record. **Error.** An encrypted font is permitted.
- **Rights (§4.8).** Where rights are declared, assert that
  `dcterms:license` is a URI and that the colophon's rights statement
  agrees with the package. **Warning**, since a publication may
  legitimately have no rights statement at all.

It MUST be runnable as a command-line tool independent of any reading
application, and MUST exit non-zero on any error.

---

## 19. Conformance corpus

Published with this specification: thirteen minimal publications, each
demonstrating one feature, each accompanied by its **expected extraction
as JSON** — or, for `11` and `13`, its expected validator verdicts — so
an implementer can diff rather than guess.

```
01-basic-addressing    08-combined
02-citations           09-version-relations
03-glossary            10-edge-cases
04-live-table          11-packaging
05-equations           12-legacy-overlapping-records
06-spatial-layout      13-colophon
07-3d-model
```

- `01` MUST include more than one content document, including the same
  bare `id` in two of them — so that a reader which addresses by
  fragment alone fails the corpus rather than shipping.
- `07` MUST include a poster carrier, a posterless carrier, a figure with
  no description, and a figure with `units` absent.
- `09` MUST include two editions of one work sharing
  `dcterms:isVersionOf`, plus two releases of one edition sharing a
  `dc:identifier` and differing in `dcterms:modified`, with ids
  preserved for unchanged elements and a split and a merge recorded as
  lineage.
- `10` MUST include an unknown Origami property, an unknown MAJOR
  profile, an unknown `<link rel="record">` kind, a missing poster, and a
  duplicated record whose canonical hash matches.
- `11` MUST be five publications testing §4.4.1 and §4.4.2: link-only
  (**conforming**), manifest-only, both, a content document referencing
  a record, and a record under `META-INF/`.
- `12` MUST be a pre-1.0 publication with no `dcterms:conformsTo`, both
  records carrying the same concepts, citations and headings under both
  sets of field names, one present-but-empty member, and a
  `document.digest`. Its expected extraction fixes §16.3's outcome.
- `13` MUST test the colophon: one conforming publication, and three
  non-conforming — no colophon, a colophon naming a path that does not
  resolve, and a colophon whose records sit in `META-INF/`.

**Every publication in the corpus MUST additionally pass EPUBCheck, and
the corpus build MUST run it.** The corpus is where these rules stop
being prose: a reader that merges duplicated records passes every prose
reading of §11.1 and fails `12`.

---

## Appendix A — a complete minimal publication **[I]**

Every file of a conforming publication with one paragraph, one citation,
one glossary term and one 3D figure.

**`mimetype`** (stored, first in the archive, no trailing newline)

```
application/epub+zip
```

**`META-INF/container.xml`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf"
              media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
```

**`OEBPS/content.opf`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0"
         unique-identifier="pub-id" xml:lang="en"
         prefix="origami: https://origamitext.org/vocab/
                 cc: http://creativecommons.org/ns#">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="pub-id">urn:uuid:11111111-2222-3333-4444-555555555555</dc:identifier>
    <dc:title>A minimal Origami publication</dc:title>
    <dc:language>en</dc:language>
    <dc:creator>A. Writer</dc:creator>
    <meta property="dcterms:modified">2026-09-24T12:00:00Z</meta>
    <meta property="dcterms:conformsTo">https://origamitext.org/profile/1.0</meta>
    <meta property="dcterms:isVersionOf">urn:uuid:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee</meta>
    <meta property="schema:version">1</meta>
    <dc:rights>© 2026 A. Writer.</dc:rights>
    <meta property="dcterms:license">https://creativecommons.org/licenses/by/4.0/</meta>
    <meta property="cc:attributionName">A. Writer</meta>
    <meta property="schema:accessMode">textual</meta>
    <meta property="schema:accessMode">visual</meta>
    <meta property="schema:accessModeSufficient">textual,visual</meta>
    <meta property="schema:accessibilityFeature">tableOfContents</meta>
    <meta property="schema:accessibilityFeature">structuralNavigation</meta>
    <meta property="schema:accessibilityFeature">ARIA</meta>
    <meta property="schema:accessibilityFeature">alternativeText</meta>
    <meta property="schema:accessibilityHazard">none</meta>
    <meta property="schema:accessibilitySummary">Reflowable text with full
      structural navigation. All images have alternative text.</meta>
    <link rel="record" href="visual-meta.json"
          media-type="application/json" properties="origami:visual-meta"/>
    <link rel="record" href="origami.json"
          media-type="application/json" properties="origami:interaction"/>
    <link rel="record" href="references.bib"
          media-type="application/x-bibtex" properties="origami:bibliography"/>
  </metadata>
  <manifest>
    <item id="nav"        href="nav.xhtml"        media-type="application/xhtml+xml" properties="nav"/>
    <item id="content"    href="content.xhtml"    media-type="application/xhtml+xml"/>
    <item id="backmatter" href="backmatter.xhtml" media-type="application/xhtml+xml"/>
    <item id="poster"     href="images/apple-poster.png" media-type="image/png"/>
    <item id="model1"     href="models/apple.usdz"
          media-type="model/vnd.usdz+zip" fallback="poster"/>
  </manifest>
  <spine>
    <itemref idref="content"/>
    <itemref idref="backmatter"/>
  </spine>
</package>
```

**`OEBPS/content.xhtml`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en" lang="en">
<head>
  <title>A minimal Origami publication</title>
  <link rel="profile" href="https://origamitext.org/profile/1.0"/>
</head>
<body>
  <h1 id="P-title">A minimal Origami publication</h1>
  <h2 id="H-11111111-1111-1111-1111-111111111111">One section</h2>
  <p id="P-22222222-2222-2222-2222-222222222222" data-origami-address="1B">
    A paragraph that uses
    <a epub:type="glossref" role="doc-glossref"
       href="backmatter.xhtml#gloss-44444444-4444-4444-4444-444444444444">hypertext</a>
    and cites a source
    <a epub:type="biblioref" role="doc-biblioref"
       href="backmatter.xhtml#bib-55555555-5555-5555-5555-555555555555">[1]</a>.
  </p>
  <figure id="P-33333333-3333-3333-3333-333333333333">
    <img src="images/apple-poster.png" alt="An apple, seen from the side."
         data-model-id="M-33333333-3333-3333-3333-333333333333"
         data-model-src="models/apple.usdz"
         data-model-media-type="model/vnd.usdz+zip"
         data-model-filename="Apple_Free_USDZ.usdz"
         data-model-bytes="2940746"
         data-model-units="m"
         data-model-extent="0.3 0.2609 0.2878"
         data-model-up="Y"/>
    <figcaption>An apple, seen from the side.</figcaption>
  </figure>
</body>
</html>
```

**`OEBPS/backmatter.xhtml`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en" lang="en">
<head><title>Back matter</title></head>
<body>
  <section epub:type="glossary" role="doc-glossary">
    <h2>Glossary</h2>
    <dl>
      <dt id="gloss-44444444-4444-4444-4444-444444444444">hypertext</dt>
      <dd>Text with machine-followable links between its parts.</dd>
    </dl>
  </section>
  <section epub:type="bibliography" role="doc-bibliography">
    <h2>References</h2>
    <ol>
      <li id="bib-55555555-5555-5555-5555-555555555555">
        Nelson, Theodor H. (1965). A File Structure for the Complex.
      </li>
    </ol>
  </section>
  <section epub:type="colophon" id="origami-publication-info">
    <h2>Visual-Meta Colophon</h2>
    <p>This document includes Visual-Meta to enable permanent
      self-citation, metadata preservation, and seamless reference
      management across digital, Web, and printed formats.</p>
    <h3>Self-citation record</h3>
    <pre>@article{writer2026minimal,
  author = {Writer, A.},
  title  = {A minimal Origami publication},
  year   = {2026}
}</pre>
    <h3>Embedded machine-readable metadata</h3>
    <p>Structured metadata records are declared in this publication's
      package document and stored inside the EPUB container:</p>
    <ul>
      <li>Bibliographic and structural identity: <code>visual-meta.json</code></li>
      <li>Authored interaction and layout: <code>origami.json</code></li>
      <li>Bibliography: <code>references.bib</code></li>
    </ul>
    <p>To inspect the raw records, open this publication in a
      Visual-Meta-aware reader, or change the <code>.epub</code>
      extension to <code>.zip</code> and unpack the archive.</p>
    <h3>Rights</h3>
    <p>© 2026 A. Writer. Licensed under
      <a href="https://creativecommons.org/licenses/by/4.0/">Creative
      Commons Attribution 4.0 International</a>. When reusing this work,
      credit A. Writer.</p>
    <p>This publication conforms to the Origami Text 1.0 profile
      (https://origamitext.org/profile/1.0).</p>
  </section>
</body>
</html>
```

**`OEBPS/nav.xhtml`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en" lang="en">
<head><title>Contents</title></head>
<body>
  <nav epub:type="toc" role="doc-toc">
    <h1>Contents</h1>
    <ol>
      <li><a href="content.xhtml#H-11111111-1111-1111-1111-111111111111">One section</a></li>
      <li><a href="backmatter.xhtml">Back matter</a></li>
    </ol>
  </nav>
</body>
</html>
```

**`OEBPS/visual-meta.json`**

```json
{
  "visual-meta": {
    "format": "visual-meta", "version": "1.1",
    "profile": "https://origamitext.org/profile/1.0",
    "describes": "urn:uuid:11111111-2222-3333-4444-555555555555",
    "generator": "Example writer 1.0"
  },
  "document": {
    "identifier": "urn:uuid:11111111-2222-3333-4444-555555555555",
    "work": "urn:uuid:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    "release": "1",
    "title": "A minimal Origami publication",
    "authors": ["A. Writer"],
    "rights": "© 2026 A. Writer.",
    "license": "https://creativecommons.org/licenses/by/4.0/",
    "defaultDocument": "content.xhtml"
  },
  "structure": {
    "headings": [
      { "id": "H-11111111-1111-1111-1111-111111111111", "level": 2,
        "text": "One section",
        "href": "content.xhtml#H-11111111-1111-1111-1111-111111111111" }
    ]
  },
  "concepts": [
    { "id": "44444444-4444-4444-4444-444444444444",
      "name": "hypertext",
      "description": "Text with machine-followable links between its parts.",
      "tag": "concept",
      "href": "backmatter.xhtml#gloss-44444444-4444-4444-4444-444444444444" }
  ],
  "citations": [
    { "id": "55555555-5555-5555-5555-555555555555", "number": 1,
      "href": "backmatter.xhtml#bib-55555555-5555-5555-5555-555555555555" }
  ]
}
```

**`OEBPS/origami.json`**

```json
{
  "origami": {
    "format": "origami-text", "version": "1.0",
    "profile": "https://origamitext.org/profile/1.0",
    "describes": "urn:uuid:11111111-2222-3333-4444-555555555555",
    "created": "2026-09-24T12:00:00Z",
    "generator": "Example writer 1.0"
  },
  "models": [
    { "id": "M-33333333-3333-3333-3333-333333333333",
      "href": "models/apple.usdz",
      "media-type": "model/vnd.usdz+zip",
      "filename": "Apple_Free_USDZ.usdz",
      "bytes": 2940746, "up": "Y", "units": "m",
      "extent": [0.3, 0.2609, 0.2878],
      "poster": "images/apple-poster.png",
      "description": "An apple, seen from the side." }
  ]
}
```

**`OEBPS/references.bib`**

```bibtex
@article{55555555-5555-5555-5555-555555555555,
  author = {Nelson, Theodor H.},
  title = {A File Structure for the Complex, the Changing and the Indeterminate},
  year = {1965}
}
```

---

## Appendix B — implementation status **[I]**

As of 24 September 2026. This specification describes the format; the
implementations are catching up to it, and this appendix says where they
are so nobody mistakes the two.

**AuthorKit** is the shared writer used by every Author app. It
**conforms**: 28 tests, EPUBCheck 5.2.1 reporting 0 errors and 0
warnings on a publication carrying one of every feature in this
document, both records validating against the schemas of §18.1.

**Author for macOS** has its own legacy exporter which does not conform
— duplicated semantic members across both records, BibTeX in four
places, a `document.digest`, no profile or work declaration, no
colophon. Its path forward is adopting AuthorKit.

**Origami Text** is the reference reader. It implements §4.4 discovery,
§5.1 addressing across every spine document, §16.3 precedence, the
colophon, live tables, MathML, stretchtext and 3D figures. It does not
yet read the work identifier or the equation index, and it writes
equation hrefs container-relative where §5.1 wants them
package-relative — a coordinated writer-and-reader fix, since that value
round-trips.

**Owed:** the §18.2 validator beyond the schemas, and twelve of the
thirteen corpus publications with their expected extractions.

### B.1 Three errata this specification has already absorbed **[I]**

Implementing the profile's own features and running EPUBCheck over the
result found three places where earlier drafts described an **invalid**
EPUB. They are corrected in the text above, and recorded here because
none was findable by reading — which is the argument for finishing the
corpus.

| Earlier drafts said | Error | Correct |
|---|---|---|
| `<aside epub:type="endnote" role="doc-endnote">` | `RSC-005`, `RSC-017` | `role="note"` (§7.3) |
| A posterless 3D carrier as `<a href="…usdz">` | `RSC-010`; a manifest fallback does **not** clear it | any element bearing `data-model-src`, no `href` (§6.9) |
| Nothing about declaring MathML | `OPF-014` | `properties="mathml"` (§6.7) |

---

## Appendix C — one open question **[I]**

**Citing a specific release.** §4.3 makes the edition the citable unit.
If someone needs to cite *a specific release* of an edition — not the
edition, and not the exact bytes — then `dcterms:modified` is the only
machine-stable handle on it, and a timestamp is a weak identifier for
citation.

1.0 takes the position that this is rare enough to leave alone: the
edition is what is cited, and the artifact digest identifies exact bytes
when that is what matters. Adding a release identifier later is a
compatible change; retrofitting citations is not.

---

## Appendix D — quick reference **[I]**

### Package metadata

| Property | Required | Meaning |
|---|---|---|
| `dcterms:conformsTo` | yes | the profile identifier |
| `dc:identifier` | yes | the edition |
| `dcterms:isVersionOf` | yes | the work |
| `dcterms:modified` | yes | the release |
| `schema:version` | no | human-readable release label |
| `dcterms:replaces` / `isReplacedBy` | no | supersession, retraction |
| `schema:access*` | yes | accessibility (§4.6) |
| `dc:rights` | recommended | the rights statement, as prose (§4.8) |
| `dcterms:license` | recommended | the licence, **as a URI** (§4.8) |
| `dcterms:rightsHolder` | no | who owns or manages the rights |
| `dcterms:accessRights` | no | access or embargo status |
| `cc:attributionName` / `cc:attributionURL` | no | the attribution a CC licence requires |

### `data-*` attributes

| Attribute | On | §|
|---|---|---|
| `data-model-src` and the other `data-model-*` | a 3D figure's carrier | 6.9.2 |
| `data-table-id` | `<table>` | 6.6 |
| `data-origami-address` | any block | 5.2 |
| `data-origami-rel` | a citation anchor | 6.11 |
| `data-origami-action` | a citation anchor | 6.11 |
| `data-origami-derived-from` | an embedded duplicate | 11.2 |
| `data-latex` | `<math>` | 6.7 |
| `data-id` | **forbidden** | 5.2 |

### EPUB semantics used

| `epub:type` | `role` | On |
|---|---|---|
| `biblioref` | `doc-biblioref` | a citation anchor |
| `glossref` | `doc-glossref` | a glossary reference |
| `noteref` | `doc-noteref` | a note reference |
| `glossary` | `doc-glossary` | the glossary section |
| `bibliography` | `doc-bibliography` | the bibliography section |
| `endnotes` | `doc-endnotes` | the endnotes section |
| `endnote` | `note` | one endnote (**not** `doc-endnote`) |
| `colophon` | — | the Visual-Meta colophon |

### Where each fact lives

| Fact | Home |
|---|---|
| text, structure, reading order | content documents |
| concepts, citations, structure index, endnotes, relationships, lineage, equation index | semantic record |
| table formulas, authored layouts, model index, interaction declarations | interaction record |
| bibliographic records | bibliography record |
| rights and licence | the package, mirrored in the semantic record and stated in the colophon |
| a resource's own differing rights | the publication's prose — a caption or the colophon (§4.8.3) |
| the artifact digest | outside the publication |
| reader annotations and state | outside the publication |

---

## Standards referenced

- EPUB 3.3 — https://www.w3.org/TR/epub-33/
- EPUB Structural Semantics Vocabulary — https://www.w3.org/TR/epub-ssv/
- DPUB-ARIA — https://www.w3.org/TR/dpub-aria/
- W3C Web Annotation Data Model — https://www.w3.org/TR/annotation-model/
- W3C WAI, Decorative Images — https://www.w3.org/WAI/tutorials/images/decorative/
- RFC 8785, JSON Canonicalization Scheme — https://www.rfc-editor.org/rfc/rfc8785.html
- RFC 4122, UUID — https://www.rfc-editor.org/rfc/rfc4122.html
- RFC 2119, requirement levels — https://www.rfc-editor.org/rfc/rfc2119.html
- Dublin Core Metadata Terms — https://www.dublincore.org/specifications/dublin-core/dcmi-terms/
- schema.org `version` — https://schema.org/version
- Creative Commons Rights Expression Language — https://wiki.creativecommons.org/wiki/CC_REL
- IANA Link Relations — https://www.iana.org/assignments/link-relations/
- MathML — https://www.w3.org/TR/MathML3/
- JSON Schema 2020-12 — https://json-schema.org/draft/2020-12/schema
