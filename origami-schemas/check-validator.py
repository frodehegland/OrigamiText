#!/usr/bin/env python3
"""Test origami-validate.py: every §18.1 error and every §18.2 warning.

Each case takes the corpus's conforming 08-combined publication, changes
one thing, and asserts that the validator reports exactly the finding the
profile requires — an error that fails the publication, or a warning that
does not. The unchanged publication must pass with nothing reported.

    /tmp/jsonenv/bin/python check-validator.py
"""

import importlib.util
import io
import json
import pathlib
import re
import sys
import tempfile
import zipfile

HERE = pathlib.Path(__file__).resolve().parent
BASE = HERE.parent / "origami-corpus" / "08-combined" / "combined.epub"

spec = importlib.util.spec_from_file_location("ov", HERE / "origami-validate.py")
ov = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ov)


def load():
    with zipfile.ZipFile(BASE) as z:
        return {n: z.read(n) for n in z.namelist()}


def save(files):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as z:
        z.writestr(zipfile.ZipInfo("mimetype"), files["mimetype"])
        for name, data in files.items():
            if name != "mimetype":
                z.writestr(name, data, zipfile.ZIP_DEFLATED)
    path = pathlib.Path(tempfile.mkstemp(suffix=".epub")[1])
    path.write_bytes(buffer.getvalue())
    return path


def run(files, **options):
    report = ov.Report()
    ov.validate(ov.Publication(ov.Container(save(files)), report), report, **options)
    return report


def edit(files, name, old, new, count=1):
    text = files[name].decode()
    assert old in text, f"{old!r} not in {name}"
    files[name] = text.replace(old, new, count).encode()


def edit_json(files, name, change):
    data = json.loads(files[name])
    change(data)
    files[name] = json.dumps(data, ensure_ascii=False).encode()


OPF, INTRO, BODY, BACK = "OEBPS/content.opf", "OEBPS/introduction.xhtml", "OEBPS/body.xhtml", "OEBPS/backmatter.xhtml"
VM, OJ, BIB = "OEBPS/visual-meta.json", "OEBPS/origami.json", "OEBPS/references.bib"


def resync_embedded(files):
    """Keep the embedded copy equal to the sidecar, so a case about the
    sidecar does not also trip §12.2."""
    data = json.loads(files[VM])
    text = files[INTRO].decode()
    text = re.sub(r'(<script type="application/json" id="visual-meta-payload"[^>]*>).*?(</script>)',
                  lambda m: m.group(1) + json.dumps(data, ensure_ascii=False) + m.group(2), text, flags=re.S)
    files[INTRO] = text.encode()


def semantic(change):
    def apply(files):
        edit_json(files, VM, change)
        resync_embedded(files)
    return apply


ERRORS = [
    ("a metadata reference to an address that does not exist", "META-UNRESOLVED",
     semantic(lambda d: d["concepts"][0].update(href="backmatter.xhtml#gloss-missing"))),
    ("two elements in one document share an id", "ID-DUPLICATE",
     lambda f: edit(f, BODY, 'data-origami-address="2A"', 'data-origami-address="2A"><span id="H-33333333-3333-4333-8333-333333333333">x</span'), ),
    ("an id that is not an NCName", "ID-NCNAME",
     lambda f: edit(f, BODY, '<p id="P-66666666', '<p id="9-66666666')),
    ("a <link rel=\"record\"> naming a resource not in the package", "REC-MISSING",
     lambda f: f.pop(BIB)),
    ("a citation whose key has no BibTeX record", "CITE-NO-RECORD",
     lambda f: f.update({BIB: b"@misc{other,\n  title = {Other}\n}\n"})),
    ("a glossref naming a missing entry", "REF-UNRESOLVED",
     lambda f: edit(f, INTRO, 'href="backmatter.xhtml#gloss-', 'href="backmatter.xhtml#gloss-x')),
    ("a noteref naming a missing note", "REF-UNRESOLVED",
     lambda f: edit(f, INTRO, 'href="backmatter.xhtml#en-', 'href="backmatter.xhtml#en-x')),
    ("a data-model-src naming a missing resource", "M3D-MISSING",
     lambda f: f.pop("OEBPS/models/apple.usdz")),
    ("a foreign resource used in rendering with no fallback", "MAN-FALLBACK",
     lambda f: (f.update({"OEBPS/images/scan.tiff": b"II*\x00"}),
                edit(f, OPF, '</manifest>', '<item id="tiff" href="images/scan.tiff" media-type="image/tiff"/>\n  </manifest>'),
                edit(f, BODY, "</table>", '</table>\n<p id="P-tiff"><img src="images/scan.tiff" alt="A scan."/></p>'))),
    ("MathML without properties=\"mathml\"", "MAN-MATHML",
     lambda f: edit(f, OPF, 'media-type="application/xhtml+xml" properties="mathml"', 'media-type="application/xhtml+xml"')),
    ("a <model> element", "DOC-MODEL-ELEMENT",
     lambda f: edit(f, BODY, "</table>", '</table>\n<model xmlns="http://www.w3.org/1999/xhtml" src="models/apple.usdz"/>')),
    ("an embedded record that differs from its sidecar", "EMBED-HASH",
     lambda f: edit(f, INTRO, '"release":"corpus revision 1"', '"release":"corpus revision 2"')),
    ("a forbidden member in the interaction record", "REC-SEPARATION",
     lambda f: edit_json(f, OJ, lambda d: d.update(glossary=[{"id": "x"}]))),
    ("a forbidden member nested deep in the interaction record", "REC-SEPARATION",
     lambda f: edit_json(f, OJ, lambda d: d["tables"][0].update(extra={"deep": {"citations": []}}))),
    ("tables in the semantic record", "REC-SEPARATION",
     semantic(lambda d: d.update(tables=[]))),
    ("reader state in the interaction record", "REC-READER-STATE",
     lambda f: edit_json(f, OJ, lambda d: d.update(readingPosition={"at": "x"}))),
    ("a record that is also a manifest item", "REC-IN-MANIFEST",
     lambda f: edit(f, OPF, '</manifest>', '<item id="vm" href="visual-meta.json" media-type="application/json"/>\n  </manifest>')),
    ("a record referenced from a content document", "REC-REFERENCED",
     lambda f: edit(f, BODY, "<head>", '<head>\n  <link rel="describedby" href="visual-meta.json"/>')),
    ("a record in META-INF/", "REC-META-INF",
     lambda f: (f.update({"META-INF/origami.json": f.pop(OJ)}),
                edit(f, OPF, 'href="origami.json"', 'href="../META-INF/origami.json"'))),
    ("an encrypted content document", "ENC-CONTENT",
     lambda f: f.update({"META-INF/encryption.xml": b'<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" '
                         b'xmlns:enc="http://www.w3.org/2001/04/xmlenc#"><enc:EncryptedData><enc:CipherData>'
                         b'<enc:CipherReference URI="OEBPS/body.xhtml"/></enc:CipherData></enc:EncryptedData></encryption>'})),
    ("a colophon stating a record path that does not resolve", "COLOPHON-PATH-UNRESOLVED",
     lambda f: edit(f, BACK, "<code>origami.json</code>", "<code>data/origami.json</code>")),
    ("a colophon whose BibTeX does not parse", "COLOPHON-BIBTEX",
     lambda f: edit(f, BACK, "@misc{writer2026corpus,", "@misc{writer2026corpus")),
    ("an author entry with no name", "REC-SCHEMA",
     semantic(lambda d: d["document"]["authors"].append({"affiliation": "Nowhere"}))),
    ("data-id", "ID-DATA-ID",
     lambda f: edit(f, BODY, '<p id="P-66666666', '<p data-id="2A" id="P-66666666')),
    ("data-bibtex in the body", "DOC-BIBTEX-ATTR",
     lambda f: edit(f, BODY, '<p id="P-66666666', '<p data-bibtex="@misc{x}" id="P-66666666')),
    ("a BibTeX string inside a JSON record", "REC-BIBTEX",
     semantic(lambda d: d["citations"][0].update(note="@article{k, title = {T}}"))),
    ("document.digest", "REC-DIGEST",
     semantic(lambda d: d["document"].update(digest="sha256:00"))),
    ("a record describing another publication", "REC-DESCRIBES",
     lambda f: edit_json(f, OJ, lambda d: d["origami"].update(describes="urn:uuid:00000000-0000-4000-8000-000000000000"))),
    ("no profile declaration", "PROFILE-MISSING",
     lambda f: edit(f, OPF, '<meta property="dcterms:conformsTo">https://github.com/frodehegland/OrigamiText/tree/main/profile/1.0</meta>', "")),
    ("no work identifier", "ID-WORK",
     lambda f: edit(f, OPF, '<meta property="dcterms:isVersionOf">', '<meta property="schema:alternateName">')),
    ("a revision label in dcterms:hasVersion", "ID-HASVERSION",
     lambda f: edit(f, OPF, "</metadata>", '<meta property="dcterms:hasVersion">revision 3</meta>\n  </metadata>')),
    ("origami:profile", "PKG-FORBIDDEN-PROPERTY",
     lambda f: edit(f, OPF, "</metadata>", '<meta property="origami:profile">1.0</meta>\n  </metadata>')),
    ("an accessibility claim an undescribed image breaks", "A11Y-CLAIM",
     lambda f: edit(f, BODY, 'alt="An apple, seen from the side."', 'alt=""') or
     edit(f, BODY, "<figcaption>An apple, seen from the side.</figcaption>", "")),
    ("missing accessibility metadata", "A11Y-MISSING",
     lambda f: edit(f, OPF, '<meta property="schema:accessibilityHazard">none</meta>', "")),
    ("a 3D carrier that is a hyperlink", "M3D-HYPERLINK",
     lambda f: edit(f, BODY, '<img src="images/apple-poster.png"', '<img href="models/apple.usdz" src="images/apple-poster.png"')),
    ("units without extent", "M3D-UNITS-EXTENT",
     lambda f: edit(f, BODY, ' data-model-extent="0.3 0.2609 0.2878"', "")),
    ("an up-axis other than Y or Z", "M3D-UP",
     lambda f: edit(f, BODY, 'data-model-up="Y"', 'data-model-up="X"')),
    ("an unregistered model media type", "M3D-MEDIA-TYPE",
     lambda f: edit(f, BODY, 'data-model-media-type="model/vnd.usdz+zip"', 'data-model-media-type="model/obj"')),
    ("nested stretchtext", "ST-NESTED",
     lambda f: edit(f, INTRO, "<p>The contracted passage", '<aside class="ot-stretchtext-content" id="st-inner" hidden="hidden"><p>x</p></aside><p>The contracted passage')),
    ("a map reference that names nothing", "MAP-UNRESOLVED",
     lambda f: edit_json(f, OJ, lambda d: d["map"]["views"][0]["nodes"].append({"ref": "nothing-here", "x": 1, "y": 1}))),
    ("a formula reaching outside its table", "TABLE-FORMULA",
     lambda f: edit_json(f, OJ, lambda d: d["tables"][0]["cells"][1][2].update(formula="=Sheet2!A1"))),
    ("a biblioref without its role", "REF-SEMANTICS",
     lambda f: edit(f, INTRO, 'epub:type="biblioref" role="doc-biblioref"', 'epub:type="biblioref"')),
]

WARNINGS = [
    ("a DOI differing between the OPF and the record", "FM-DOI-DISAGREE",
     lambda f: (edit(f, OPF, "</metadata>", "<dc:identifier>10.1234/a</dc:identifier>\n  </metadata>"),
                semantic(lambda d: d["document"].update(doi="10.1234/b"))(f))),
    ("a title differing between the OPF and the record", "FM-TITLE-DISAGREE",
     semantic(lambda d: d["document"].update(title={"value": "Another title", "lang": "en"}))),
    ("an author differing between the OPF and the record", "FM-AUTHORS-DISAGREE",
     semantic(lambda d: d["document"].update(authors=[{"name": {"value": "B. Writer", "lang": "en"}}]))),
    ("data-model-up differing from the models entry", "M3D-DISAGREE",
     lambda f: edit_json(f, OJ, lambda d: d["models"][0].update(up="Z"))),
    ("extent differing from the models entry", "M3D-DISAGREE",
     lambda f: edit_json(f, OJ, lambda d: d["models"][0].update(extent=[1, 1, 1]))),
    ("a glossary definition differing from the record", "GLOSS-DISAGREE",
     semantic(lambda d: d["concepts"][0].update(description="Something else."))),
    ("a citation field differing from its BibTeX entry", "CITE-FIELD-DISAGREE",
     semantic(lambda d: d["citations"][0].update(year="1963"))),
    ("a heading list differing from the body", "HEAD-DISAGREE",
     semantic(lambda d: d["structure"]["headings"][0].update(text="Preface"))),
    ("a model over the size budget with no data-model-source", "M3D-BUDGET", None),
    ("no rights statement", "RIGHTS-NONE",
     lambda f: (edit(f, OPF, '<dc:rights>© 2026 A. Writer.</dc:rights>', ""),
                edit(f, OPF, '<meta property="dcterms:license">https://creativecommons.org/licenses/by/4.0/</meta>', ""))),
    ("a dcterms:license that is not a URI", "RIGHTS-LICENSE-URI",
     lambda f: edit(f, OPF, '<meta property="dcterms:license">https://creativecommons.org/licenses/by/4.0/</meta>',
                    '<meta property="dcterms:license">Creative Commons Attribution</meta>')),
    ("the profile's first identifier, under origamitext.org", "PROFILE-LEGACY-ID",
     lambda f: edit(f, OPF, "https://github.com/frodehegland/OrigamiText/tree/main/profile/1.0", "https://origamitext.org/profile/1.0")),
    ("no colophon", "COLOPHON-NONE",
     lambda f: edit(f, BACK, 'epub:type="colophon"', 'epub:type="appendix"')),
    ("a colophon whose rights disagree with the package", "COLOPHON-RIGHTS",
     lambda f: edit(f, OPF, "<dc:rights>© 2026 A. Writer.</dc:rights>", "<dc:rights>© 2026 Somebody Else.</dc:rights>")),
    ("several author names joined into one", "FM-JOINED-AUTHORS",
     lambda f: edit(f, OPF, "<dc:creator>A. Writer</dc:creator>", "<dc:creator>A. Writer and B. Writer</dc:creator>")),
    ("subject classification as body text", "FM-BODY-TEXT",
     lambda f: edit(f, BODY, "</table>", '</table>\n<p id="P-ccs">CCS Concepts: Human-centered computing</p>')),
]


def main():
    failures = 0
    clean = run(load())
    if clean.items:
        failures += 1
        print("FAIL the unchanged publication reports:", [(i["code"], i["message"]) for i in clean.items])
    else:
        print("ok   the unchanged publication: nothing to report")
    for title, code, change in ERRORS:
        files = load()
        change(files)
        report = run(files)
        codes = {i["code"] for i in report.errors}
        if code in codes:
            print(f"ok   error   {code:24} {title}")
        else:
            failures += 1
            print(f"FAIL error   {code:24} {title}: got {sorted(codes)} / warnings {sorted({i['code'] for i in report.warnings})}")
    for title, code, change in WARNINGS:
        files = load()
        options = {}
        if change is None:
            options = {"model_budget": 10}
        else:
            change(files)
        report = run(files, **options)
        warned = {i["code"] for i in report.warnings}
        if code in warned and not report.errors:
            print(f"ok   warning {code:24} {title}")
        else:
            failures += 1
            print(f"FAIL warning {code:24} {title}: warnings {sorted(warned)} / errors "
                  f"{sorted((i['code'], i['message']) for i in report.errors)}")
    # RFC 8785 Appendix B number vectors, and key order by UTF-16 code units.
    vectors = {0.0: "0", -0.0: "0", 1e21: "1e+21", 1e-7: "1e-7", 1e-6: "0.000001", 333333333.3333333: "333333333.3333333",
               5e-324: "5e-324", 1.7976931348623157e308: "1.7976931348623157e+308", 9007199254740992.0: "9007199254740992",
               295147905179352830000.0: "295147905179352830000", 0.000001: "0.000001", 4.5: "4.5", 2e-3: "0.002"}
    for number, expected in vectors.items():
        got = ov.jcs(number)
        if got != expected:
            failures += 1
            print(f"FAIL jcs({number!r}) = {got}, expected {expected}")
    order = ov.jcs({"\u20ac": 1, "\r": 2, "\ufb33": 3, "1": 4, "\U0001f600": 5, "\u0080": 6, "\u00f6": 7})
    expected_order = '{"\\r":2,"1":4,"\u0080":6,"\u00f6":7,"\u20ac":1,"\U0001f600":5,"\ufb33":3}'
    if order != expected_order:
        failures += 1
        print(f"FAIL jcs key order: {order}")
    else:
        print("ok   RFC 8785 numbers and key order")
    total = 1 + len(ERRORS) + len(WARNINGS) + 1
    print(f"\n{total - failures}/{total} behaved as the profile requires")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
