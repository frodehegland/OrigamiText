# Origami EPUB Profile 1.0 — schemas and validator

The machine-checkable half of the [profile](../ORIGAMI-EPUB-PROFILE-1.0.md).
§1.8 requires every Origami JSON structure to be described by a
published, versioned schema; §19.2 requires a validator that checks the
rest; §20.1 defines the extraction a reader's behaviour is compared by.
All three are here. The conformance corpus they are tested against is in
[`../origami-corpus/`](../origami-corpus/).

Current against **Profile 1.0, revised 8 October 2026**.

| File | What it is |
|---|---|
| `origami-validate.py` | **the reference validator (§19.3)** and the reference extractor (§20.1) |
| `check-validator.py` | 60 cases: one per §18.1 error, one per §18.2 warning, and RFC 8785's vectors |
| `visual-meta-1.1.schema.json` | the semantic record (§9) |
| `origami-interaction-1.0.schema.json` | the interaction record (§10) |
| `check-schemas.py` | 76 cases: what the schemas must accept and must reject |
| `validate-records.py` | the schemas alone, for a record or an unpacked publication |
| `authorkit-sample.epub` | a conforming publication from AuthorKit's writer |

## Running them

```sh
python3 -m venv /tmp/jsonenv && /tmp/jsonenv/bin/pip install jsonschema

/tmp/jsonenv/bin/python origami-validate.py validate Publication.epub   # exit 1 on any error
/tmp/jsonenv/bin/python origami-validate.py validate Publication.epub --json
/tmp/jsonenv/bin/python origami-validate.py extract  Publication.epub
/tmp/jsonenv/bin/python check-validator.py                               # 60/60
/tmp/jsonenv/bin/python check-schemas.py                                 # 76/76
```

The validator reads an `.epub` or an unpacked directory, and nothing
else: no reading application's source, no network. It is half of §19.
The other half is EPUBCheck, which is needed as well:

```sh
mkdir -p /tmp/jdk && cd /tmp/jdk
curl -sSL -o jre.tar.gz "https://api.adoptium.net/v3/binary/latest/21/ga/mac/aarch64/jre/hotspot/normal/eclipse"
tar xzf jre.tar.gz
curl -sSL -o epubcheck.zip "https://github.com/w3c/epubcheck/releases/download/v5.2.1/epubcheck-5.2.1.zip"
unzip -q epubcheck.zip
/tmp/jdk/jdk-21.0.12.1+1-jre/Contents/Home/bin/java -jar /tmp/jdk/epubcheck-5.2.1/epubcheck.jar Publication.epub
```

## What the validator checks

Each finding names its code and the section that requires it.

**Errors** — the publication does not conform: the profile declaration
and its MAJOR (§4.2, §16.2); the work, edition and release identifiers
(§4.3); `origami:profile` and the other forbidden properties; undeclared
prefixes; every record declared, resolving, self-identifying, describing
this publication, and valid against its schema; record packaging (not a
manifest item, not referenced from a content document, not in
`META-INF/`, never an undeclared manifest item — §4.4); the record
separation at any depth and the reader-state boundary (§10.0, §15);
BibTeX strings in JSON records and `data-bibtex` in the body (§11);
`document.digest` (§13.2); id uniqueness and NCName syntax; `data-id`;
`<model>`; MathML and script declarations (§4.5); fallbacks; every
metadata reference against the addresses the content documents publish
(§17.1 step 9), including map references (§10.3); `biblioref`,
`glossref` and `noteref` semantics and targets; citation keys against the
bibliography record; 3D carriers (§7.9); stretchtext; the embedded
duplicate's RFC 8785 hash (§12.2); encryption (§4.7.4); accessibility
metadata and the claims the images support (§4.6); and the colophon —
statement, parseable self-citation, stated paths that resolve, none in
`META-INF/` (§8.4).

**Warnings** — the publication conforms, and something deserves a look:
every §18.2 case, plus value disagreements between derived copies
(§12.3) — the record against the package, a table's recorded values
against the XHTML, a models entry against its carrier.

## What the schemas enforce that prose could not

**The record separation (§10.0).** Every forbidden member is declared
`"not": {}`, so the schema itself rejects an interaction record carrying
`glossary`, `references`, `headings`, `structure`, `endnotes`,
`footnotes`, `citations`, `concepts`, `links`, `lineage`, `equations` or
`bibliography`, and rejects a semantic record carrying `tables`, `map` or
`models`. The validator walks nested members too.

**The reader-state boundary (§15).** `readingPosition`, `readerState`,
`runtimeState`, `annotations`, `highlights`, `bookmarks` and `lastRead`
are forbidden in the interaction record by name.

**And:** no `document.digest` (§13.2); no `document.hasVersion` (§4.3);
the equation index's shape (§7.7.1); no BibTeX or CSL inside a citation
entry (§9.5); `extent` and `units` together (§7.9.4); an up-axis of
exactly `Y` or `Z`; only the registered model media types (§7.9.3); no
formula reaching outside its table (§10.2); no `links` entry without a
target edition (§9.6); no address containing whitespace (§6.1); the
§5.5.2 shape of every human-language value.

Unknown members are accepted everywhere, because §16.3 requires a reader
to ignore what it does not understand, and a schema that rejected them
would make every forward-compatible addition a breaking change.
