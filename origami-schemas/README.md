# Origami EPUB Profile 1.0 — JSON schemas

The machine-checkable half of the profile. §1.8 requires every Origami
JSON structure to be described by a published, versioned schema, and §18
requires the validator to check records against it. Until 24 September
2026 no such file existed, so both requirements were prose.

Current against **draft 5** of the profile.

| File | What it is |
|---|---|
| `visual-meta-1.1.schema.json` | the semantic record (profile §8) |
| `origami-interaction-1.0.schema.json` | the interaction record (profile §9) |
| `check-schemas.py` | 58 cases: what the schemas must accept and must reject |
| `validate-records.py` | validate a publication's records |
| `authorkit-sample.epub` | a conforming publication from the refactored writer — 0 EPUBCheck errors, both records valid |

Both schemas are JSON Schema **2020-12** and both pass
`Draft202012Validator.check_schema`.

## Running them

```sh
python3 -m venv /tmp/jsonenv && /tmp/jsonenv/bin/pip install jsonschema

/tmp/jsonenv/bin/python check-schemas.py                      # 51/51
/tmp/jsonenv/bin/python validate-records.py path/to/unpacked-epub
/tmp/jsonenv/bin/python validate-records.py visual-meta.json origami.json
```

`validate-records.py` decides which schema applies from the record's own
self-identification (§8.1, §9.1), **not** from its filename — the same
rule the profile imposes on readers.

## What they enforce that prose could not

**The record separation (§9.0).** Every forbidden member is declared
`"not": {}`, so the schema itself rejects an interaction record carrying
`glossary`, `references`, `headings`, `structure`, `endnotes`,
`footnotes`, `citations`, `concepts`, `links`, `lineage`, `equations` or
`bibliography`, and rejects a semantic record carrying `tables`, `map` or
`models`. This is the duplication that had one real export shipping the
same 101 concepts and 18 citations twice under different names, with a
reader that discarded one of them positionally. A validator no longer has
to go looking.

**The reader-state boundary (§14).** `readingPosition`, `readerState`,
`runtimeState`, `annotations`, `highlights`, `bookmarks` and `lastRead`
are forbidden in the interaction record by name. This is the rule most
likely to be broken in good faith — "interaction" and "runtime" sound
adjacent — and a publication is immutable: reader activity belongs in
external W3C Web Annotation documents. So the schema refuses it outright
rather than trusting anyone to remember.

**Draft 5's identity correction.** `document.hasVersion` is forbidden —
DCMI defines `dcterms:hasVersion` as a relation to another resource, not
a revision label — and the label lives in `document.release`, accepting a
string or a number to match `schema:version` (§4.3, §4.3.1).

**Draft 5's equation index.** `equations[]` now has a stated shape
(§6.7.1, §8.8): `display` of `block`/`inline`, `format` of
`mathml`/`latex`, and 64-hex checksums. It is the index's only home in a
conforming publication; the pre-1.0 delimited text block inside a
content document is discoverable by no package mechanism and is
forbidden.

**And:** no `document.digest` (§12.2); no BibTeX or CSL inside a citation
entry (§10); `extent` and `units` required together via
`dependentRequired`, because assuming metres for a model that never
stated them can build a hundredfold object (§6.9.4); an up-axis of
exactly `Y` or `Z`; only the three registered model media types (§6.9.3);
no formula reaching outside its own table (§9.2); no `links` entry
without a target edition (§6.11); no address containing whitespace
(§5.1).

Unknown members are accepted everywhere, because §15.3 requires a reader
to ignore what it does not understand, and a schema that rejected them
would make every forward-compatible addition a breaking change.

## What is still owed

These schemas are the record half of §18's validator. The rest — the
packaging checks (§4.4.1, §4.4.3), the colophon check (§7.4, including
that every path it names resolves), and the referential-integrity checks
(§17.1) — has still to be written around them. The five packaging
variants in `../origami-packaging-tests/` are its first test cases.
