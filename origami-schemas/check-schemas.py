#!/usr/bin/env python3
"""Test the Origami JSON schemas against records that must pass and records
that must fail.

The schemas exist so that §1.8 and §18 of the profile are mechanically
enforceable rather than aspirational. A schema nobody has tested is no
better than prose, so every rule the schemas are supposed to carry has a
case here — especially §9.0's separation and §14's reader-state boundary,
which are the two rules most likely to be violated by a writer that means
well.

    /tmp/jsonenv/bin/python check-schemas.py
"""

import json
import pathlib
import sys

from jsonschema import Draft202012Validator

HERE = pathlib.Path(__file__).parent
SEMANTIC = json.loads((HERE / "visual-meta-1.1.schema.json").read_text())
INTERACTION = json.loads((HERE / "origami-interaction-1.0.schema.json").read_text())

UUID = "urn:uuid:97d7808d-d373-4ba7-a350-f6a7895c8811"
WORK = "urn:uuid:0f2c6a51-1111-2222-3333-444455556666"
PROFILE = "https://origamitext.org/profile/1.0"


def semantic(**overrides):
    record = {
        "visual-meta": {"format": "visual-meta", "version": "1.1",
                        "profile": PROFILE, "describes": UUID,
                        "generator": "AuthorKit"},
        "document": {"identifier": UUID, "work": WORK, "title": "A paper",
                     "authors": ["Hegland, Frode"],
                     "defaultDocument": "content.xhtml"},
    }
    record.update(overrides)
    return record


def interaction(**overrides):
    record = {
        "origami": {"format": "origami-text", "version": "1.0",
                    "profile": PROFILE, "describes": UUID,
                    "generator": "AuthorKit"},
    }
    record.update(overrides)
    return record


# (name, schema, instance, must_be_valid)
CASES = [
    # ---- the semantic record -------------------------------------------
    ("semantic: minimal", SEMANTIC, semantic(), True),
    ("semantic: full", SEMANTIC, semantic(
        structure={"headings": [{"id": "H-0979114B", "level": 2,
                                 "text": "Why EPUB Now?",
                                 "href": "content.xhtml#H-0979114B",
                                 "address": "2"}]},
        concepts=[{"id": "97887240", "name": "Cognitive Accessibility",
                   "description": "The design of digital content…",
                   "tag": "concept", "urls": [],
                   "citationIdentifiers": ["A6CBF363"],
                   "href": "backmatter.xhtml#gloss-97887240"}],
        citations=[{"id": "232A9EED", "number": 2,
                    "href": "backmatter.xhtml#bib-232A9EED",
                    "concepts": ["97887240"]}],
        endnotes=[{"id": "en-D16AD8DE", "anchor": "content.xhtml#P-F9868FD4",
                   "text": "https://www.acm.org/publications/taps"}],
        links=[{"rel": "cites", "fromAddress": "content.xhtml#P-683",
                "toEdition": WORK, "toAddress": "content.xhtml#P-9F2A",
                "quotedText": "the quoted words"}],
        lineage=[{"id": "P-NEW1", "replaces": ["P-OLD1", "P-OLD2"],
                  "inEdition": WORK}],
    ), True),
    ("semantic: unknown member is ignored (§15.3)", SEMANTIC,
     semantic(somethingNobodyKnows={"a": 1}), True),
    ("semantic: bare fragment address with defaultDocument", SEMANTIC,
     semantic(concepts=[{"id": "C1", "name": "x", "href": "gloss-C1"}]), True),

    ("semantic: no self-identification", SEMANTIC,
     {"document": {"title": "x"}}, False),
    ("semantic: wrong format value", SEMANTIC,
     semantic(**{"visual-meta": {"format": "origami-text", "version": "1.1",
                                 "describes": UUID}}), False),
    ("semantic: describes is not an identifier", SEMANTIC,
     semantic(**{"visual-meta": {"format": "visual-meta", "version": "1.1",
                                 "describes": "my-document"}}), False),
    ("semantic: version not MAJOR.MINOR", SEMANTIC,
     semantic(**{"visual-meta": {"format": "visual-meta", "version": "1",
                                 "describes": UUID}}), False),
    ("semantic: document.digest is forbidden (§12.2)", SEMANTIC,
     semantic(document={"identifier": UUID, "digest": "deadbeef"}), False),
    ("semantic: citation carrying BibTeX (§10)", SEMANTIC,
     semantic(citations=[{"id": "C", "bibtex": "@book{C, title={T}}"}]), False),
    ("semantic: citation carrying CSL (§10)", SEMANTIC,
     semantic(citations=[{"id": "C", "csl": {"title": "T"}}]), False),
    ("semantic: carrying tables (§9.0)", SEMANTIC,
     semantic(tables=[{"identifier": "T-1", "cells": []}]), False),
    ("semantic: carrying map (§9.0)", SEMANTIC,
     semantic(map={"views": []}), False),
    ("semantic: carrying models (§9.0)", SEMANTIC,
     semantic(models=[{"id": "M-1"}]), False),
    ("semantic: concept with no name", SEMANTIC,
     semantic(concepts=[{"id": "C1"}]), False),
    ("semantic: address containing whitespace", SEMANTIC,
     semantic(concepts=[{"id": "C1", "name": "x",
                         "href": "content.xhtml#P 1"}]), False),
    ("semantic: link without a target edition (§6.11)", SEMANTIC,
     semantic(links=[{"rel": "cites", "toAddress": "content.xhtml#P-1"}]), False),
    ("semantic: link with an unknown rel", SEMANTIC,
     semantic(links=[{"rel": "mentions", "toEdition": WORK,
                      "toAddress": "content.xhtml#P-1"}]), False),

    # ---- draft 5: the identity corrections -----------------------------
    ("semantic: a release label and timestamp", SEMANTIC, semantic(
        document={"identifier": UUID, "work": WORK, "release": "author revision 3",
                  "modified": "2026-09-24T09:30:57Z"}), True),
    ("semantic: a numeric release label", SEMANTIC,
     semantic(document={"identifier": UUID, "release": 2}), True),
    ("semantic: hasVersion as a revision label (§4.3.1)", SEMANTIC,
     semantic(document={"identifier": UUID, "hasVersion": "corrected version"}), False),

    # ---- draft 5: the equation index has a home ------------------------
    ("semantic: equation index (§6.7.1)", SEMANTIC, semantic(
        equations=[{"id": "E-71B2", "href": "content.xhtml#E-71B2",
                    "display": "block", "label": "1", "format": "mathml",
                    "tex": "E = mc^2",
                    "tex-sha256": "a" * 64, "mathml-sha256": "b" * 64,
                    "converter": "latexml",
                    "section": "content.xhtml#H-0979",
                    "heading": "Why EPUB Now?"}]), True),
    ("semantic: equation with a bad display value", SEMANTIC,
     semantic(equations=[{"id": "E-1", "display": "floating"}]), False),
    ("semantic: equation with a bad format value", SEMANTIC,
     semantic(equations=[{"id": "E-1", "format": "asciimath"}]), False),
    ("semantic: equation with a malformed checksum", SEMANTIC,
     semantic(equations=[{"id": "E-1", "tex-sha256": "nothex"}]), False),

    # ---- the interaction record ----------------------------------------
    ("interaction: minimal", INTERACTION, interaction(), True),
    ("interaction: full", INTERACTION, interaction(
        tables=[{"identifier": "T-9A3F", "href": "content.xhtml#P-4C1E",
                 "rowCount": 2, "columnCount": 3,
                 "cells": [[{"value": "Year"}, {"value": "Papers"},
                            {"value": "Share"}],
                           [{"value": "2024"}, {"value": "120"},
                            {"value": "0.48", "formula": "=B2/250"}]]}],
        map={"views": [{"id": "V-1", "name": "The argument",
                        "nodes": [{"ref": "content.xhtml#P-683",
                                   "x": 0.24, "y": -0.1, "z": 0.0}]}],
             "connections": [{"from": "content.xhtml#P-683",
                              "to": "content.xhtml#P-7AAA"}]},
        models=[{"id": "M-F93D1917", "href": "models/model1.usdz",
                 "media-type": "model/vnd.usdz+zip",
                 "filename": "Apple_Free_USDZ.usdz", "bytes": 2940746,
                 "up": "Y", "units": "m", "extent": [0.3, 0.2609, 0.2878],
                 "poster": "images/model1-poster.png",
                 "description": "Apple"}],
        stretchtext=[{"id": "st-ABC123", "anchor": "content.xhtml#P-1"}],
    ), True),
    ("interaction: model with neither units nor extent (§6.9.4)", INTERACTION,
     interaction(models=[{"id": "M-1", "href": "m.usdz",
                          "media-type": "model/vnd.usdz+zip", "up": "Y"}]), True),
    ("interaction: unknown member is ignored (§15.3)", INTERACTION,
     interaction(futureFeature=[1, 2, 3]), True),

    ("interaction: no self-identification", INTERACTION, {"tables": []}, False),
    ("interaction: carrying glossary (§9.0)", INTERACTION,
     interaction(glossary=[{"id": "C1", "name": "hypertext"}]), False),
    ("interaction: carrying concepts (§9.0)", INTERACTION,
     interaction(concepts=[{"id": "C1", "name": "hypertext"}]), False),
    ("interaction: carrying references (§9.0)", INTERACTION,
     interaction(references=[{"id": "K", "number": 1}]), False),
    ("interaction: carrying citations (§9.0)", INTERACTION,
     interaction(citations=[{"id": "K"}]), False),
    ("interaction: carrying headings (§9.0)", INTERACTION,
     interaction(headings=[{"id": "H-1"}]), False),
    ("interaction: carrying structure (§9.0)", INTERACTION,
     interaction(structure={"headings": []}), False),
    ("interaction: carrying endnotes (§9.0)", INTERACTION,
     interaction(endnotes=[{"id": "en-1"}]), False),
    ("interaction: carrying footnotes (§9.0)", INTERACTION,
     interaction(footnotes=[{"id": "fn-1"}]), False),
    ("interaction: carrying links (§9.0)", INTERACTION,
     interaction(links=[{"rel": "cites"}]), False),
    ("interaction: carrying lineage (§9.0)", INTERACTION,
     interaction(lineage=[{"id": "P-1"}]), False),
    ("interaction: carrying equations (§9.0)", INTERACTION,
     interaction(equations=[{"id": "E-1"}]), False),
    ("interaction: carrying a bibliography (§10)", INTERACTION,
     interaction(bibliography=[{"id": "K"}]), False),

    ("interaction: reading position (§14)", INTERACTION,
     interaction(readingPosition={"href": "content.xhtml#P-1"}), False),
    ("interaction: reader state (§14)", INTERACTION,
     interaction(readerState={"view": "horizontal"}), False),
    ("interaction: runtime state (§14)", INTERACTION,
     interaction(runtimeState={"zoom": 1.5}), False),
    ("interaction: reader annotations (§14)", INTERACTION,
     interaction(annotations=[{"quote": "…"}]), False),
    ("interaction: highlights (§14)", INTERACTION,
     interaction(highlights=[{"id": "h1"}]), False),
    ("interaction: bookmarks (§14)", INTERACTION,
     interaction(bookmarks=[{"id": "b1"}]), False),
    ("interaction: lastRead (§14)", INTERACTION,
     interaction(lastRead="2026-09-24T12:00:00Z"), False),

    ("interaction: extent without units (§6.9.4)", INTERACTION,
     interaction(models=[{"id": "M-1", "href": "m.usdz",
                          "media-type": "model/vnd.usdz+zip", "up": "Y",
                          "extent": [0.3, 0.2, 0.2]}]), False),
    ("interaction: units without extent (§6.9.4)", INTERACTION,
     interaction(models=[{"id": "M-1", "href": "m.usdz",
                          "media-type": "model/vnd.usdz+zip", "up": "Y",
                          "units": "m"}]), False),
    ("interaction: up axis that is not Y or Z (§6.9.4)", INTERACTION,
     interaction(models=[{"id": "M-1", "href": "m.usdz",
                          "media-type": "model/vnd.usdz+zip", "up": "X"}]), False),
    ("interaction: unregistered model media type (§6.9.3)", INTERACTION,
     interaction(models=[{"id": "M-1", "href": "m.obj",
                          "media-type": "model/obj", "up": "Y"}]), False),
    ("interaction: extent of two numbers", INTERACTION,
     interaction(models=[{"id": "M-1", "href": "m.usdz",
                          "media-type": "model/vnd.usdz+zip", "up": "Y",
                          "units": "m", "extent": [0.3, 0.2]}]), False),
    ("interaction: formula reaching outside its table (§9.2)", INTERACTION,
     interaction(tables=[{"identifier": "T-1",
                          "cells": [[{"value": "1",
                                      "formula": "=[Book1]Sheet2!A1"}]]}]), False),
    ("interaction: formula without a leading = (§9.2)", INTERACTION,
     interaction(tables=[{"identifier": "T-1",
                          "cells": [[{"value": "1",
                                      "formula": "B2/250"}]]}]), False),
    ("interaction: table with no cells", INTERACTION,
     interaction(tables=[{"identifier": "T-1"}]), False),
    ("interaction: map node without a ref", INTERACTION,
     interaction(map={"views": [{"nodes": [{"x": 1, "y": 2}]}]}), False),
]


def main():
    for schema in (SEMANTIC, INTERACTION):
        Draft202012Validator.check_schema(schema)
    print("both schemas are themselves valid JSON Schema 2020-12\n")

    failures = 0
    for name, schema, instance, should_pass in CASES:
        errors = sorted(Draft202012Validator(schema).iter_errors(instance),
                        key=lambda e: e.path)
        passed = not errors
        ok = passed == should_pass
        if not ok:
            failures += 1
        mark = "ok  " if ok else "FAIL"
        want = "accept" if should_pass else "reject"
        print(f"{mark} [{want}] {name}")
        if not ok:
            if errors:
                print(f"       unexpectedly rejected: {errors[0].message}")
            else:
                print("       unexpectedly accepted")
        elif errors and not should_pass:
            reason = errors[0].message
            if len(reason) > 96:
                reason = reason[:93] + "…"
            print(f"       → {reason}")

    total = len(CASES)
    print(f"\n{total - failures}/{total} cases behaved as specified")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
