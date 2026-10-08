# Origami EPUB Profile 1.0 — conformance corpus

The publications §20 of the [profile](../ORIGAMI-EPUB-PROFILE-1.0.md)
requires: fourteen items, 25 EPUBs, each demonstrating one thing, each
with what a conforming reader must take from it and what a conforming
validator must say about it. An implementer diffs against these rather
than guessing.

Built 8 October 2026. **Every publication passes EPUBCheck 5.2.1 with 0
errors and 0 warnings**, except `11-packaging/C-link-and-item.epub`,
whose one error (`OPF-067`) is the point of it.

## Running it

```sh
python3 -m venv /tmp/jsonenv && /tmp/jsonenv/bin/pip install jsonschema
export EPUBCHECK="java -jar /path/to/epubcheck-5.2.1/epubcheck.jar"

/tmp/jsonenv/bin/python build-corpus.py           # rebuild everything
/tmp/jsonenv/bin/python build-corpus.py --check   # rebuild in memory, diff against the files here
```

The build fails unless EPUBCheck ran and passed. It is deterministic: the
same script writes the same bytes, so `--check` is a regression test of
the corpus, the validator and the extractor together.

To test your own reader, extract each publication and compare with
`expected-extraction.json` (§20.1 defines the shape). To test your own
validator, compare its verdict with `expected-verdict.json`: `conforms`
must match, and each listed finding must be reported at the same level
against the same section. The `code`s are the reference validator's
names (`../origami-schemas/origami-validate.py`); another validator may
name its findings differently.

## What each one is for

| Item | Publications | What it tests | What a reader must do |
|---|---|---|---|
| `01-basic-addressing` | `addressing` | Two content documents both using the bare id `P-shared` (§6.1) | Address both as `chapter1.xhtml#P-shared` and `chapter2.xhtml#P-shared`, unchanged; resolve the record's `chapter2.xhtml#P-shared` to the second. A reader addressing by fragment alone fails. |
| `02-citations` | `citations` | `biblioref` placement, BibTeX as canonical with `@string`, `#` and a month macro, mirrored fields, a cited work in Chinese with its alternates, a cross-edition quote link (§7.3, §7.11, §9.5, §11) | Key each citation by its fragment less `bib-`; take bibliographic data from `references.bib`; keep the cited title in its own script. |
| `03-glossary` | `glossary` | `glossref`, the XHTML glossary governing display, a concept tied to a citation (§7.4, §8.1, §9.4) | Show the `<dt>`/`<dd>` text; take relationships from `concepts[]`. |
| `04-live-table` | `live-table` | Complete static values in the XHTML, formulas only in the interaction record (§7.6, §10.2) | Show the XHTML's numbers; formulas are an addition, never a replacement. |
| `05-equations` | `equations` | MathML governing, an index with a correct `tex-sha256`, an equation no index lists, one with no id (§7.7) | Find all addressable `math` elements by scanning; take TeX only from a checksum that matches. |
| `06-spatial-layout` | `spatial-layout` | Views referring to addresses and to concept ids, depth in `z`, a member placed in no view, no connections (§10.3) | Resolve refs against both; list the unplaced member as unplaced, never at `(0, 0)`; treat `z: 0` as "no depth set". |
| `07-3d-model` | `3d-model` | A poster carrier, a posterless carrier, a figure nobody described, figures with no units (§7.9) | Find figures by `[data-model-src]` only; never use `turbine_v3_final.usdz` as a description; use a neutral size where no units are stated. The publication withdraws `alternativeText` because one image has no description (§4.6). |
| `08-combined` | `combined` | Every feature across three content documents, with an embedded copy of the semantic record serialised differently from the sidecar (§12.2) | As above, together. The copy is canonically identical, so nothing is reported. |
| `09-version-relations` | `edition1-release1`, `edition1-release2`, `edition2` | One work; edition 1 in two releases differing by a comma; edition 2 replacing it, recording a split and a merge as lineage (§4.3, §6.4, §9.7) | Treat the two releases as the same publication; treat edition 2's lineage as claims, not identity. |
| `10-edge-cases` | `edge-cases`, `unknown-major`, `legacy-identifier` | Unknown members and attributes, an unknown record kind, a models entry naming a poster the package lacks, a canonical duplicate; separately, profile 2.0 (§16), and the profile's first `origamitext.org` identifier (§4.2) | Ignore what is unknown without error; read `unknown-major` as an ordinary EPUB and say so; read `legacy-identifier` as 1.0. |
| `11-packaging` | `A`–`E` | Record packaging, one variable each (§4.4.1, §4.4.2) | — (verdicts only) |
| `12-legacy-overlapping-records` | `legacy` | A pre-1.0 publication: no profile, records found by name, the same facts in both records under both sets of names, an empty `citations`, a prose licence, joined string authors with name-keyed dictionaries, "CCS Concepts:" in the body, a `digest` (§17.2, §17.3) | One source per fact, never a merge: concepts from the semantic record, citations from the interaction record because the semantic copy is empty, the prose licence as the rights statement and not as a licence. |
| `13-colophon` | `conforming`, `absent`, `wrong-path`, `meta-inf` | The colophon (§8.4, §19.2) | — (verdicts only) |
| `14-scholarly-front-matter` | `scholarly-front-matter` | Structured authors with affiliation, email and ORCID; an author in Chinese with transliteration and display forms; venue and journal; DOI; classification; keywords; the publisher's self-citation, verbatim — none of it as body text (§5, §5.5) | Take every part from the record, in the original script first. |

## Expected verdicts

| Publication | Conforms | Errors | Warnings |
|---|---|---|---|
| 01–09, `10/edge-cases` | yes | — | `10/edge-cases`: the missing poster (§10.5) |
| `10/unknown-major` | no — not 1.0 | §16.2 | — |
| `10/legacy-identifier` | yes | — | the first identifier (§4.2) |
| `11/B-link-only` | **yes** | — | — |
| `11/A-manifest-only` | no | §4.4 undeclared record; the colophon then names no declared record | prefix declared, unused |
| `11/C-link-and-item` | no | §4.4.1 (EPUBCheck `OPF-067` too) | — |
| `11/D-content-reference` | no | §4.4.1, §7.12 | — |
| `11/E-meta-inf` | no | §4.4.2, and the colophon names `META-INF/` | — |
| `12/legacy` | no — pre-1.0 | everything 1.0 forbids that it carries | — |
| `13/conforming` | yes | — | — |
| `13/absent` | **yes** | — | no colophon (§18.2) |
| `13/wrong-path` | no | a stated path resolves to no record | a declared record goes unmentioned |
| `13/meta-inf` | no | the record is in `META-INF/`, and the colophon names it there | — |
| `14/scholarly-front-matter` | yes | — | — |

The 2026-09-24 packaging test in `../origami-packaging-tests/` is kept
for its record of how §4.4 was settled; `11-packaging` supersedes it as
the corpus item, because each of its variants now differs from a fully
conforming publication in exactly one way.
