#!/usr/bin/env python3
"""Build the Origami EPUB Profile 1.0 conformance corpus (§20).

    python3 build-corpus.py            # write every publication
    python3 build-corpus.py --check    # rebuild in memory and diff against what is committed

Each publication is written as NN-name/<file>.epub beside its expected
results:

    expected-extraction.json   what a conforming reader takes from it (§20.1)
    expected-verdict.json      what a conforming validator says about it (§19.2)

This script is the corpus's readable source: every file of every
publication is spelled out below, so a reviewer can see exactly what each
one contains without unzipping anything. The archives are deterministic —
the same script always writes the same bytes.

The expected results are produced by ../origami-schemas/origami-validate.py
and were then checked by hand against the profile; README.md records what
each publication is for and what a reader must make of it. Where the two
ever disagree, the profile governs and the corpus has a defect.

The corpus build MUST run EPUBCheck (§20). Set EPUBCHECK to a command that
runs it, for instance

    EPUBCHECK="/tmp/jdk/jdk-21.0.12.1+1-jre/Contents/Home/bin/java -jar /tmp/jdk/epubcheck-5.2.1/epubcheck.jar"

and the build fails unless every publication reports 0 errors and 0
warnings. Without it the build says that EPUBCheck was not run.
"""

import hashlib
import json
import os
import pathlib
import shlex
import struct
import subprocess
import sys
import tempfile
import zipfile
import zlib

HERE = pathlib.Path(__file__).resolve().parent
VALIDATOR = HERE.parent / "origami-schemas" / "origami-validate.py"
PROFILE = "https://github.com/frodehegland/OrigamiText/tree/main/profile/1.0"
VOCAB = "https://github.com/frodehegland/OrigamiText/blob/main/profile/vocab.md#"
CC_BY = "https://creativecommons.org/licenses/by/4.0/"
STAMP = (2026, 10, 8, 12, 0, 0)
GENERATOR = "Origami conformance corpus 1.0"


def uuid(n, tail=None):
    """Readable fixed UUIDs: uuid(3) → 33333333-3333-4333-8333-333333333333."""
    d = format(n % 16, "x")
    return f"{d * 8}-{d * 4}-4{d * 3}-8{d * 3}-{(tail or d * 12)}"


# ---------------------------------------------------------------------------
# Small binary resources

def png(width=4, height=3, rgba=(200, 60, 40, 255)):
    """A valid PNG of one colour, written without any imaging library."""
    raw = b"".join(b"\x00" + bytes(rgba) * width for _ in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + \
            struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


USDA = """#usda 1.0
(
    defaultPrim = "Box"
    metersPerUnit = 1
    upAxis = "Y"
)

def Cube "Box"
{
    double size = 0.1
}
"""


def usdz(text=USDA, name="model.usda"):
    """A USDZ package: an uncompressed zip whose file data is 64-byte
    aligned, as the USDZ specification requires."""
    data = text.encode("utf-8")
    header_without_extra = 30 + len(name)
    pad = (-header_without_extra - 4) % 64
    extra = struct.pack("<HH", 0x1986, pad) + b"\x00" * pad
    crc = zlib.crc32(data) & 0xFFFFFFFF
    local = struct.pack("<IHHHHHIIIHH", 0x04034B50, 20, 0, 0, 0, 0x21, crc, len(data), len(data),
                        len(name), len(extra)) + name.encode() + extra
    central = struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, 20, 20, 0, 0, 0, 0x21, crc, len(data), len(data),
                          len(name), 0, 0, 0, 0, 0, 0) + name.encode()
    end = struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, 1, 1, len(central), len(local) + len(data), 0)
    return local + data + central + end


POSTER = png(8, 6, (180, 40, 30, 255))
APPLE = usdz()
BRAIN = usdz(USDA.replace('"Box"', '"Brain"').replace("0.1", "0.2"), "brain.usda")
BOLT = usdz(USDA.replace('"Box"', '"Bolt"').replace('upAxis = "Y"', 'upAxis = "Z"'), "bolt.usda")


# ---------------------------------------------------------------------------
# Package pieces

CONTAINER = """<?xml version="1.0" encoding="UTF-8"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"""

A11Y_FULL = """    <meta property="schema:accessMode">textual</meta>
    <meta property="schema:accessMode">visual</meta>
    <meta property="schema:accessModeSufficient">textual,visual</meta>
    <meta property="schema:accessModeSufficient">textual</meta>
    <meta property="schema:accessibilityFeature">tableOfContents</meta>
    <meta property="schema:accessibilityFeature">structuralNavigation</meta>
    <meta property="schema:accessibilityFeature">ARIA</meta>
    <meta property="schema:accessibilityFeature">alternativeText</meta>
    <meta property="schema:accessibilityHazard">none</meta>
    <meta property="schema:accessibilitySummary">Reflowable text with full structural navigation. Every image has a description.</meta>
"""

# For a publication with an image nobody described: alternativeText and a
# textual-only sufficiency are withdrawn (§4.6, §7.9.6).
A11Y_UNDESCRIBED = """    <meta property="schema:accessMode">textual</meta>
    <meta property="schema:accessMode">visual</meta>
    <meta property="schema:accessModeSufficient">textual,visual</meta>
    <meta property="schema:accessibilityFeature">tableOfContents</meta>
    <meta property="schema:accessibilityFeature">structuralNavigation</meta>
    <meta property="schema:accessibilityFeature">ARIA</meta>
    <meta property="schema:accessibilityHazard">none</meta>
    <meta property="schema:accessibilitySummary">Reflowable text with full structural navigation. One figure has no description.</meta>
"""

RECORD_LINKS = {
    "visual-meta": '<link rel="record" href="{href}" media-type="application/json" properties="origami:visual-meta"/>',
    "interaction": '<link rel="record" href="{href}" media-type="application/json" properties="origami:interaction"/>',
    "bibliography": '<link rel="record" href="{href}" media-type="application/x-bibtex" properties="origami:bibliography"/>',
}
RECORD_LABELS = {
    "visual-meta": "Bibliographic and structural identity",
    "interaction": "Authored interaction and layout",
    "bibliography": "Bibliography",
}


def esc(text):
    return (str(text).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace('"', "&quot;"))


class Pub:
    """One publication under construction. Defaults give a conforming
    publication with one content document, a back matter document holding
    the colophon, and a semantic record; each corpus item changes what it
    is about and nothing else."""

    def __init__(self, n, title, edition=None, work=None, modified="2026-10-08T12:00:00Z"):
        self.title = title
        self.edition = edition or f"urn:uuid:{uuid(n, format(n, '012d'))}"
        self.work = work or f"urn:uuid:{uuid(n + 1, 'a' * 8 + format(n, '04d'))}"
        self.modified = modified
        self.release = None
        self.language = "en"
        self.creators = ["A. Writer"]
        self.extra_meta = []           # raw lines inside <metadata>
        self.extra_links = []          # raw <link> lines
        self.a11y = A11Y_FULL
        self.rights = "© 2026 A. Writer."
        self.license = CC_BY
        self.attribution = "A. Writer"
        self.prefix_cc = True
        self.conforms_to = PROFILE
        self.vocabulary = VOCAB
        self.documents = []            # (id, href, body, properties, head_extra)
        self.items = []                # (id, href, media-type, extra attrs)
        self.files = {}                # path in OEBPS -> bytes
        self.records = {}              # kind -> (href, content bytes)
        self.record_dirs = {}          # kind -> path override relative to container root
        self.semantic = None
        self.interaction = None
        self.bibtex = None
        self.colophon = True
        self.colophon_paths = None     # override what the colophon states
        self.selfcite = None
        self.colophon_extra = ""       # e.g. the publisher's self-citation (§8.4.2)
        self.backmatter_body = ""
        self.nav_entries = []
        self.unique_identifier = "pub-id"
        self.opf_override = None

    # -- the records -------------------------------------------------------

    def semantic_head(self):
        return {"format": "visual-meta", "version": "1.1", "profile": PROFILE,
                "describes": self.edition, "generator": GENERATOR}

    def interaction_head(self):
        return {"format": "origami-text", "version": "1.0", "profile": PROFILE,
                "describes": self.edition, "created": self.modified, "generator": GENERATOR}

    def document_block(self, **extra):
        block = {"identifier": self.edition, "work": self.work, "modified": self.modified,
                 "language": self.language,
                 "title": {"value": self.title, "lang": self.language},
                 "authors": [{"name": {"value": c, "lang": self.language}} for c in self.creators]}
        if self.release is not None:
            block["release"] = self.release
        if self.rights:
            block["rights"] = self.rights
        if self.license:
            block["license"] = self.license
        block.update(extra)
        return block

    # -- assembling --------------------------------------------------------

    def add_document(self, ident, href, body, properties=None, head_extra="", lang=None):
        self.documents.append((ident, href, body, properties, head_extra, lang))

    def build(self):
        files = {"mimetype": b"application/epub+zip", "META-INF/container.xml": CONTAINER.encode()}
        records_kinds = []
        if self.semantic is not None:
            data = self.semantic if isinstance(self.semantic, (bytes, str)) else \
                json.dumps(self.semantic, indent=2, ensure_ascii=False) + "\n"
            self.records.setdefault("visual-meta", ("visual-meta.json", data))
        if self.interaction is not None:
            data = self.interaction if isinstance(self.interaction, (bytes, str)) else \
                json.dumps(self.interaction, indent=2, ensure_ascii=False) + "\n"
            self.records.setdefault("interaction", ("origami.json", data))
        if self.bibtex is not None:
            self.records.setdefault("bibliography", ("references.bib", self.bibtex))
        links = []
        for kind in ("visual-meta", "interaction", "bibliography"):
            if kind not in self.records:
                continue
            href, data = self.records[kind]
            path = self.record_dirs.get(kind) or f"OEBPS/{href}"
            files[path] = data.encode() if isinstance(data, str) else data
            link_href = href if kind not in self.record_dirs else os.path.relpath(path, "OEBPS")
            links.append("    " + RECORD_LINKS[kind].format(href=link_href))
            records_kinds.append((kind, link_href))
        if self.colophon:
            self.backmatter_body += self.colophon_html(records_kinds)
        if self.backmatter_body:
            self.add_document("backmatter", "backmatter.xhtml", self.backmatter_body)
        manifest = ['    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>']
        spine = []
        for ident, href, body, properties, head_extra, lang in self.documents:
            props = f' properties="{properties}"' if properties else ""
            manifest.append(f'    <item id="{ident}" href="{href}" media-type="application/xhtml+xml"{props}/>')
            spine.append(f'    <itemref idref="{ident}"/>')
            files[f"OEBPS/{href}"] = self.xhtml(self.title, body, head_extra, lang).encode()
        for ident, href, media, extra in self.items:
            manifest.append(f'    <item id="{ident}" href="{href}" media-type="{media}"{extra}/>')
        for path, data in self.files.items():
            files[f"OEBPS/{path}" if not path.startswith("META-INF/") else path] = data
        files["OEBPS/nav.xhtml"] = self.nav().encode()
        files["OEBPS/content.opf"] = (self.opf_override or self.opf(links, manifest, spine)).encode()
        return files

    def opf(self, links, manifest, spine):
        prefix = f"origami: {self.vocabulary}"
        if self.prefix_cc:
            prefix += "\n                 cc: http://creativecommons.org/ns#"
        meta = [f'    <dc:identifier id="{self.unique_identifier}">{esc(self.edition)}</dc:identifier>',
                f"    <dc:title>{esc(self.title)}</dc:title>",
                f"    <dc:language>{self.language}</dc:language>"]
        meta += [f"    <dc:creator>{esc(c)}</dc:creator>" for c in self.creators]
        meta.append(f'    <meta property="dcterms:modified">{self.modified}</meta>')
        if self.conforms_to:
            meta.append(f'    <meta property="dcterms:conformsTo">{self.conforms_to}</meta>')
        if self.work:
            meta.append(f'    <meta property="dcterms:isVersionOf">{self.work}</meta>')
        if self.release is not None:
            meta.append(f'    <meta property="schema:version">{esc(self.release)}</meta>')
        if self.rights:
            meta.append(f"    <dc:rights>{esc(self.rights)}</dc:rights>")
        if self.license:
            meta.append(f'    <meta property="dcterms:license">{self.license}</meta>')
        if self.attribution and self.prefix_cc:
            meta.append(f'    <meta property="cc:attributionName">{esc(self.attribution)}</meta>')
        meta += ["    " + line for line in self.extra_meta]
        return f"""<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0"
         unique-identifier="pub-id" xml:lang="{self.language}"
         prefix="{prefix}">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
{chr(10).join(meta)}
{self.a11y.rstrip()}
{chr(10).join(links + ["    " + l for l in self.extra_links])}
  </metadata>
  <manifest>
{chr(10).join(manifest)}
  </manifest>
  <spine>
{chr(10).join(spine)}
  </spine>
</package>
"""

    def xhtml(self, title, body, head_extra="", lang=None):
        lang = lang or self.language
        return f"""<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="{lang}" lang="{lang}">
<head>
  <title>{esc(title)}</title>
  <link rel="profile" href="{PROFILE}"/>{head_extra}
</head>
<body>
{body.strip()}
</body>
</html>
"""

    def nav(self):
        entries = self.nav_entries or [(self.documents[0][1], self.title)]
        items = "\n".join(f'      <li><a href="{href}">{esc(label)}</a></li>' for href, label in entries)
        return f"""<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="{self.language}" lang="{self.language}">
<head><title>Contents</title></head>
<body>
  <nav epub:type="toc" role="doc-toc">
    <h1>Contents</h1>
    <ol>
{items}
    </ol>
  </nav>
</body>
</html>
"""

    def colophon_html(self, records_kinds):
        paths = self.colophon_paths if self.colophon_paths is not None else \
            [(RECORD_LABELS[k], href) for k, href in records_kinds]
        listed = "\n".join(f"      <li>{label}: <code>{esc(href)}</code></li>" for label, href in paths)
        selfcite = self.selfcite or f"""@misc{{writer2026corpus,
  author = {{{', '.join(reversed(self.creators[0].split(' ', 1))) if ' ' in self.creators[0] else self.creators[0]}}},
  title  = {{{self.title}}},
  year   = {{2026}}
}}"""
        rights = ""
        if self.rights or self.license:
            licence = (f' Licensed under <a href="{self.license}">Creative Commons Attribution 4.0 '
                       f'International</a>.' if self.license == CC_BY else "")
            credit = f" When reusing this work, credit {esc(self.attribution)}." if self.attribution else ""
            rights = f"""
    <h3>Rights</h3>
    <p>{esc(self.rights or '')}{licence}{credit}</p>"""
        return f"""
  <section epub:type="colophon" id="origami-publication-info">
    <h2>Visual-Meta Colophon</h2>
    <p>This document includes Visual-Meta to enable permanent self-citation, metadata
      preservation, and seamless reference management across digital, Web, and printed formats.</p>
    <h3>Self-citation record</h3>
    <pre>{esc(selfcite)}</pre>{self.colophon_extra}
    <h3>Embedded machine-readable metadata</h3>
    <p>Structured metadata records are declared in this publication's package document and
      stored inside the EPUB container:</p>
    <ul>
{listed}
    </ul>
    <p>To inspect the raw records, open this publication in a Visual-Meta-aware reader, or
      change the <code>.epub</code> extension to <code>.zip</code> and unpack the archive.</p>{rights}
    <p>This publication conforms to the Origami Text 1.0 profile ({PROFILE}).</p>
  </section>
"""


def write_epub(files):
    """Deterministic EPUB bytes: mimetype stored first, fixed timestamps."""
    import io
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as z:
        info = zipfile.ZipInfo("mimetype", STAMP)
        info.compress_type = zipfile.ZIP_STORED
        z.writestr(info, files["mimetype"])
        for name in sorted(n for n in files if n != "mimetype"):
            info = zipfile.ZipInfo(name, STAMP)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            z.writestr(info, files[name])
    return buffer.getvalue()


# ---------------------------------------------------------------------------
# The corpus

def p01():
    """01 — addressing across documents. Two chapters both use the bare id
    P-shared; only path-plus-fragment tells them apart (§6.1)."""
    pub = Pub(1, "Addressing across documents")
    pub.add_document("ch1", "chapter1.xhtml", """
<h1 id="H-title-1">Addressing across documents</h1>
<h2 id="H-11111111-1111-4111-8111-111111111111">Chapter one</h2>
<p id="P-shared" data-origami-address="1A">The first chapter's paragraph. Its id is also used in chapter two.</p>
<p id="P-11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa" data-origami-address="1B">A paragraph only chapter one has.</p>
""")
    pub.add_document("ch2", "chapter2.xhtml", """
<h2 id="H-22222222-2222-4222-8222-222222222222">Chapter two</h2>
<p id="P-shared" data-origami-address="2A">The second chapter's paragraph, with the same bare id as chapter one's.</p>
<p id="P-22222222-bbbb-4bbb-8bbb-bbbbbbbbbbbb" data-origami-address="2B">A paragraph only chapter two has.</p>
""")
    pub.nav_entries = [("chapter1.xhtml#H-11111111-1111-4111-8111-111111111111", "Chapter one"),
                       ("chapter2.xhtml#H-22222222-2222-4222-8222-222222222222", "Chapter two")]
    pub.semantic = {
        "visual-meta": pub.semantic_head(),
        "document": pub.document_block(),
        "structure": {"headings": [
            {"id": "H-11111111-1111-4111-8111-111111111111", "level": 2, "text": "Chapter one",
             "href": "chapter1.xhtml#H-11111111-1111-4111-8111-111111111111", "address": "1"},
            {"id": "H-22222222-2222-4222-8222-222222222222", "level": 2, "text": "Chapter two",
             "href": "chapter2.xhtml#H-22222222-2222-4222-8222-222222222222", "address": "2"}]},
        "links": [{"rel": "transcludes", "fromAddress": "chapter2.xhtml#P-shared",
                   "toEdition": "urn:uuid:5a1c0000-0000-4000-8000-000000000001",
                   "toAddress": "content.xhtml#P-9f2a0000-0000-4000-8000-000000000001",
                   "quotedText": "the same bare id"}],
    }
    return {"addressing.epub": pub}


BIB_02 = r"""@string{ht = {ACM Conference on Hypertext and Social Media}}

@article{55555555-5555-4555-8555-555555555555,
  author = {Nelson, Theodor H.},
  title = {A File Structure for the Complex, the Changing and the Indeterminate},
  booktitle = {Proceedings of the 1965 20th National Conference},
  year = {1965},
  pages = {84--100},
  doi = {10.1145/800197.806036}
}

@inproceedings{66666666-6666-4666-8666-666666666666,
  author = {Hegland, Frode and Writer, A.},
  title = {Visual-{Meta} in Practice},
  booktitle = ht # " (HT '26)",
  year = 2026,
  month = sep,
  abstract = {How a document can carry its own metadata where a person can see it.}
}

@book{77777777-7777-4777-8777-777777777777,
  author = {{王小明}},
  title = {数字文本与知识组织},
  publisher = {Example Press},
  year = {2024},
  langid = {chinese}
}
"""


def p02():
    """02 — citations: biblioref placement, the BibTeX record as canonical
    (macros, # concatenation, a month macro), fields mirrored on the
    citation entry, a cited work in another language, and a cross-edition
    quote link carried in the semantic record (§7.3, §7.11, §9.5, §11)."""
    pub = Pub(2, "Citations")
    k1, k2, k3 = uuid(5), uuid(6), uuid(7)
    other = "urn:uuid:5a1c0000-0000-4000-8000-000000000001"
    pub.add_document("content", "content.xhtml", f"""
<h1 id="H-title">Citations</h1>
<h2 id="H-{uuid(1)}">Sources</h2>
<p id="P-{uuid(2)}" data-origami-address="1A">The idea of a docuverse is old
  <a epub:type="biblioref" role="doc-biblioref" href="backmatter.xhtml#bib-{k1}">[1]</a>, and
  documents that describe themselves are newer
  <a epub:type="biblioref" role="doc-biblioref" href="backmatter.xhtml#bib-{k2}">[2]</a>.</p>
<p id="P-{uuid(3)}" data-origami-address="1B">Nelson again
  <a epub:type="biblioref" role="doc-biblioref" href="backmatter.xhtml#bib-{k1}">[1]</a>, and a
  quotation from another publication:
  <a epub:type="biblioref" role="doc-biblioref" href="backmatter.xhtml#bib-{k2}"
     data-origami-rel="cites">"the document explains itself" (Hegland and Writer, 2026)</a>.
  A work in Chinese <a epub:type="biblioref" role="doc-biblioref" href="backmatter.xhtml#bib-{k3}">[3]</a>.</p>
""")
    pub.backmatter_body = f"""
  <section epub:type="bibliography" role="doc-bibliography">
    <h2>References</h2>
    <ol>
      <li id="bib-{k1}">Nelson, Theodor H. (1965). A File Structure for the Complex, the Changing and the Indeterminate.</li>
      <li id="bib-{k2}">Hegland, Frode and Writer, A. (2026). Visual-Meta in Practice. ACM Conference on Hypertext and Social Media (HT '26).</li>
      <li id="bib-{k3}">王小明 (2024). <span lang="zh-Hans" xml:lang="zh-Hans">数字文本与知识组织</span> [Digital Text and Knowledge Organization]. Example Press.</li>
    </ol>
  </section>
"""
    pub.bibtex = BIB_02
    pub.semantic = {
        "visual-meta": pub.semantic_head(),
        "document": pub.document_block(defaultDocument="content.xhtml"),
        "citations": [
            {"id": k1, "number": 1, "href": f"backmatter.xhtml#bib-{k1}", "year": "1965"},
            {"id": k2, "number": 2, "href": f"backmatter.xhtml#bib-{k2}",
             "abstract": "How a document can carry its own metadata where a person can see it."},
            {"id": k3, "number": 3, "href": f"backmatter.xhtml#bib-{k3}", "lang": "zh-Hans",
             "alternate": [{"value": "Shuzi Wenben yu Zhishi Zuzhi", "lang": "zh-Latn", "relation": "transliteration"},
                           {"value": "Digital Text and Knowledge Organization", "lang": "en", "relation": "translation"}]},
        ],
        "links": [{"rel": "cites", "fromAddress": f"content.xhtml#P-{uuid(3)}", "toEdition": other,
                   "toAddress": "content.xhtml#P-9f2a0000-0000-4000-8000-000000000001",
                   "quotedText": "the document explains itself",
                   "action": "origamitext://open/5a1c0000-0000-4000-8000-000000000001#P-9f2a0000-0000-4000-8000-000000000001"}],
        "bibliography": {"href": "references.bib", "conventions": {
            "dialect": "bibtex", "encoding": "utf-8", "nameOrder": "family-given",
            "nameSeparator": " and ", "dateFields": "year-month", "monthFormat": "macro",
            "pageRange": "--", "keys": "uuid", "titleCase": "as-published", "source": "declared-and-inspected"}},
    }
    return {"citations.epub": pub}


def p03():
    """03 — the glossary: glossrefs, the XHTML glossary as display authority,
    concepts[] for the relationships only it carries (§7.4, §8.1, §9.4)."""
    pub = Pub(3, "Glossary")
    g1, g2, g3, c1 = uuid(10, "a1" * 6), uuid(11, "b1" * 6), uuid(12, "c1" * 6), uuid(13)
    pub.add_document("content", "content.xhtml", f"""
<h1 id="H-title">Glossary</h1>
<p id="P-{uuid(2)}" data-origami-address="1A">A
  <a epub:type="glossref" role="doc-glossref" href="backmatter.xhtml#gloss-{g1}">hypertext</a> is made of
  <a epub:type="glossref" role="doc-glossref" href="backmatter.xhtml#gloss-{g2}">links</a>; a
  <a epub:type="glossref" role="doc-glossref" href="backmatter.xhtml#gloss-{g3}">transclusion</a>
  is a link that shows what it points at
  <a epub:type="biblioref" role="doc-biblioref" href="backmatter.xhtml#bib-{c1}">[1]</a>.</p>
""")
    pub.backmatter_body = f"""
  <section epub:type="glossary" role="doc-glossary">
    <h2>Glossary</h2>
    <dl>
      <dt id="gloss-{g1}">hypertext</dt>
      <dd>Text with machine-followable links between its parts.</dd>
      <dt id="gloss-{g2}">link</dt>
      <dd>A connection from one place in a text to another.</dd>
      <dt id="gloss-{g3}">transclusion</dt>
      <dd>The inclusion of part of one document in another by reference, so that it shows what it points at.</dd>
    </dl>
  </section>
  <section epub:type="bibliography" role="doc-bibliography">
    <h2>References</h2>
    <ol>
      <li id="bib-{c1}">Nelson, Theodor H. (1981). Literary Machines.</li>
    </ol>
  </section>
"""
    pub.bibtex = f"@book{{{c1},\n  author = {{Nelson, Theodor H.}},\n  title = {{Literary Machines}},\n  year = {{1981}}\n}}\n"
    pub.semantic = {
        "visual-meta": pub.semantic_head(),
        "document": pub.document_block(defaultDocument="content.xhtml"),
        "concepts": [
            {"id": g1, "name": "hypertext", "description": "Text with machine-followable links between its parts.",
             "tag": "concept", "href": f"backmatter.xhtml#gloss-{g1}"},
            {"id": g2, "name": "link", "description": "A connection from one place in a text to another.",
             "tag": "concept", "href": f"backmatter.xhtml#gloss-{g2}"},
            {"id": g3, "name": "transclusion",
             "description": "The inclusion of part of one document in another by reference, so that it shows what it points at.",
             "tag": "technique", "urls": ["https://en.wikipedia.org/wiki/Transclusion"],
             "citationIdentifiers": [c1], "href": f"backmatter.xhtml#gloss-{g3}"},
        ],
        "citations": [{"id": c1, "number": 1, "href": f"backmatter.xhtml#bib-{c1}", "concepts": [g3]}],
    }
    return {"glossary.epub": pub}


def p04():
    """04 — a live table: complete static values in the XHTML, formulas in
    the interaction record only (§7.6, §10.2)."""
    pub = Pub(4, "A live table")
    table = f"P-{uuid(4)}"
    pub.add_document("content", "content.xhtml", f"""
<h1 id="H-title">A live table</h1>
<p id="P-{uuid(2)}" data-origami-address="1A">Papers per year, with each year's share of the total.</p>
<table id="{table}" data-table-id="T-{uuid(9)}">
  <caption>Papers per year, with a computed share.</caption>
  <thead><tr><th>Year</th><th>Papers</th><th>Share</th></tr></thead>
  <tbody>
    <tr><td>2024</td><td>120</td><td>0.48</td></tr>
    <tr><td>2025</td><td>130</td><td>0.52</td></tr>
    <tr><td>Total</td><td>250</td><td>1</td></tr>
  </tbody>
</table>
""")
    pub.semantic = {"visual-meta": pub.semantic_head(),
                    "document": pub.document_block(defaultDocument="content.xhtml")}
    pub.interaction = {
        "origami": pub.interaction_head(),
        "tables": [{"identifier": f"T-{uuid(9)}", "href": f"content.xhtml#{table}", "rowCount": 4, "columnCount": 3,
                    "cells": [[{"value": "Year"}, {"value": "Papers"}, {"value": "Share"}],
                              [{"value": "2024"}, {"value": "120"}, {"value": "0.48", "formula": "=B2/B4"}],
                              [{"value": "2025"}, {"value": "130"}, {"value": "0.52", "formula": "=B3/B4"}],
                              [{"value": "Total"}, {"value": "250", "formula": "=SUM(B2:B3)"},
                               {"value": "1", "formula": "=ROUND(C2+C3, 2)"}]]}],
    }
    return {"live-table.epub": pub}


MATH_BLOCK = """<math xmlns="http://www.w3.org/1998/Math/MathML" id="E-{id}" display="block" alttext="E = mc^2" data-latex="E = mc^2">
  <mrow><mi>E</mi><mo>=</mo><mi>m</mi><msup><mi>c</mi><mn>2</mn></msup></mrow>
</math>"""
MATH_INLINE = """<math xmlns="http://www.w3.org/1998/Math/MathML" id="E-{id}" display="inline" alttext="a^2 + b^2 = c^2"><mrow><msup><mi>a</mi><mn>2</mn></msup><mo>+</mo><msup><mi>b</mi><mn>2</mn></msup><mo>=</mo><msup><mi>c</mi><mn>2</mn></msup></mrow></math>"""


def sha(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def p05():
    """05 — equations: MathML governs, the index in the semantic record
    carries TeX with checksums, and one equation is in no index (§7.7)."""
    pub = Pub(5, "Equations")
    e1, e2, e3 = uuid(1), uuid(2), uuid(3)
    pub.add_document("content", "content.xhtml", f"""
<h1 id="H-title">Equations</h1>
<h2 id="H-{uuid(7)}">Energy</h2>
<p id="P-{uuid(8)}" data-origami-address="1A">Mass and energy are related by</p>
{MATH_BLOCK.format(id=e1)}
<p id="P-{uuid(9)}" data-origami-address="1B">and the sides of a right triangle by {MATH_INLINE.format(id=e2)}, which
  no index lists: a reader finds it by scanning for <code>math</code>.</p>
<p id="P-{uuid(10)}" data-origami-address="1C">An equation with no id is not addressable:
  <math xmlns="http://www.w3.org/1998/Math/MathML" display="inline" alttext="x"><mi>x</mi></math>.</p>
""", properties="mathml")
    del e3
    pub.semantic = {
        "visual-meta": pub.semantic_head(),
        "document": pub.document_block(defaultDocument="content.xhtml"),
        "equations": [{"id": f"E-{e1}", "href": f"content.xhtml#E-{e1}", "display": "block", "label": "1",
                       "format": "mathml", "tex": "E = mc^2", "tex-sha256": sha("E = mc^2"),
                       "converter": "hand", "section": f"content.xhtml#H-{uuid(7)}", "heading": "Energy"}],
    }
    return {"equations.epub": pub}


def p06():
    """06 — an authored spatial layout: views of addresses and concept ids,
    a member placed in no view, z as depth, and no connections (§10.3)."""
    pub = Pub(6, "A spatial layout")
    g1, g2 = uuid(10, "a6" * 6), uuid(11, "b6" * 6)
    p1, p2 = f"P-{uuid(2)}", f"P-{uuid(3)}"
    pub.add_document("content", "content.xhtml", f"""
<h1 id="H-title">A spatial layout</h1>
<p id="{p1}" data-origami-address="1A">The first claim, about
  <a epub:type="glossref" role="doc-glossref" href="backmatter.xhtml#gloss-{g1}">space</a>.</p>
<p id="{p2}" data-origami-address="1B">The second claim, which rests on
  <a epub:type="glossref" role="doc-glossref" href="backmatter.xhtml#gloss-{g2}">time</a>.</p>
""")
    pub.backmatter_body = f"""
  <section epub:type="glossary" role="doc-glossary">
    <h2>Glossary</h2>
    <dl>
      <dt id="gloss-{g1}">space</dt>
      <dd>Where things are, as distinct from time.</dd>
      <dt id="gloss-{g2}">time</dt>
      <dd>When things are, as distinct from space.</dd>
    </dl>
  </section>
"""
    pub.semantic = {
        "visual-meta": pub.semantic_head(),
        "document": pub.document_block(defaultDocument="content.xhtml"),
        "concepts": [{"id": g1, "name": "space", "description": "Where things are, as distinct from time.",
                      "tag": "concept", "href": f"backmatter.xhtml#gloss-{g1}"},
                     {"id": g2, "name": "time", "description": "When things are, as distinct from space.",
                      "tag": "concept", "href": f"backmatter.xhtml#gloss-{g2}"}],
    }
    pub.interaction = {
        "origami": pub.interaction_head(),
        "map": {
            "nodes": [{"id": g1, "label": "space", "kind": "concept"},
                      {"id": g2, "label": "time", "kind": "concept"},
                      {"id": f"content.xhtml#{p2}", "label": "The second claim", "kind": "paragraph"}],
            "views": [{"id": "V-1", "name": "The argument",
                       "space": {"units": "points", "convention": "right-handed-y-up"},
                       "nodes": [{"ref": f"content.xhtml#{p1}", "x": 0.24, "y": -0.10, "z": 0.0},
                                 {"ref": g1, "x": 120, "y": 40, "z": 0.35},
                                 {"ref": g2, "x": -80, "y": 40, "z": 0}]}],
            "connections": [],
        },
        "views": [{"name": "Headings only", "fold": "headings"}],
    }
    return {"spatial-layout.epub": pub}


def model_figure(n, carrier):
    return f'<figure id="P-{uuid(n)}">\n  {carrier}\n</figure>'


def p07():
    """07 — 3D figures: a poster carrier, a posterless carrier, a figure
    nobody described, and a figure whose units are absent (§7.9)."""
    pub = Pub(7, "Three-dimensional figures")
    pub.a11y = A11Y_UNDESCRIBED
    pub.files.update({"images/apple-poster.png": POSTER, "images/bolt-poster.png": POSTER,
                      "models/apple.usdz": APPLE, "models/brain.usdz": BRAIN, "models/bolt.usdz": BOLT})
    pub.items += [("poster1", "images/apple-poster.png", "image/png", ""),
                  ("poster3", "images/bolt-poster.png", "image/png", ""),
                  ("model1", "models/apple.usdz", "model/vnd.usdz+zip", ' fallback="poster1"'),
                  ("model2", "models/brain.usdz", "model/vnd.usdz+zip", ""),
                  ("model3", "models/bolt.usdz", "model/vnd.usdz+zip", ' fallback="poster3"')]
    with_poster = model_figure(1, f"""<img src="images/apple-poster.png" alt="An apple, seen from the side."
       data-model-id="M-{uuid(1)}" data-model-src="models/apple.usdz"
       data-model-media-type="model/vnd.usdz+zip" data-model-filename="Apple_Free_USDZ.usdz"
       data-model-bytes="{len(APPLE)}" data-model-units="m" data-model-extent="0.3 0.2609 0.2878"
       data-model-up="Y" data-model-source="https://doi.org/10.5281/zenodo.0000001"/>
  <figcaption>An apple, seen from the side. Model by A. Modeller under CC BY 4.0, which differs from this publication's terms only in its attribution.</figcaption>""")
    posterless = model_figure(2, f"""<span data-model-id="M-{uuid(2)}" data-model-src="models/brain.usdz"
        data-model-media-type="model/vnd.usdz+zip" data-model-filename="brain.usdz"
        data-model-bytes="{len(BRAIN)}" data-model-up="Y">brain.usdz</span>
  <figcaption>A brain, with no poster: a reader shows an actionable figure, not an empty box.</figcaption>""")
    undescribed = model_figure(3, f"""<img src="images/bolt-poster.png" alt=""
       data-model-id="M-{uuid(3)}" data-model-src="models/bolt.usdz"
       data-model-media-type="model/vnd.usdz+zip" data-model-filename="turbine_v3_final.usdz"
       data-model-bytes="{len(BOLT)}" data-model-up="Z"/>""")
    pub.add_document("content", "content.xhtml", f"""
<h1 id="H-title">Three-dimensional figures</h1>
<p id="P-{uuid(9)}" data-origami-address="1A">Three figures. The first has a poster and a stated size; the second
  has no poster; the third has a poster and no description, and states no units, so a reader uses a neutral
  default size of its own.</p>
{with_poster}
{posterless}
{undescribed}
""")
    pub.semantic = {"visual-meta": pub.semantic_head(),
                    "document": pub.document_block(defaultDocument="content.xhtml")}
    pub.interaction = {
        "origami": pub.interaction_head(),
        "models": [
            {"id": f"M-{uuid(1)}", "href": "models/apple.usdz", "media-type": "model/vnd.usdz+zip",
             "filename": "Apple_Free_USDZ.usdz", "bytes": len(APPLE), "up": "Y", "units": "m",
             "extent": [0.3, 0.2609, 0.2878], "poster": "images/apple-poster.png",
             "description": "An apple, seen from the side.", "source": "https://doi.org/10.5281/zenodo.0000001"},
            {"id": f"M-{uuid(2)}", "href": "models/brain.usdz", "media-type": "model/vnd.usdz+zip",
             "filename": "brain.usdz", "bytes": len(BRAIN), "up": "Y"},
            {"id": f"M-{uuid(3)}", "href": "models/bolt.usdz", "media-type": "model/vnd.usdz+zip",
             "filename": "turbine_v3_final.usdz", "bytes": len(BOLT), "up": "Z",
             "poster": "images/bolt-poster.png"},
        ],
    }
    return {"3d-model.epub": pub}


def p08():
    """08 — combined: every feature in one publication across three content
    documents, with an embedded copy of the semantic record (§12.2)."""
    pub = Pub(8, "Everything at once")
    pub.release = "corpus revision 1"
    k1, g1 = uuid(5), uuid(10, "a8" * 6)
    note = f"en-{uuid(12)}"
    table = f"P-{uuid(4)}"
    pub.files.update({"images/apple-poster.png": POSTER, "models/apple.usdz": APPLE})
    pub.items += [("poster1", "images/apple-poster.png", "image/png", ""),
                  ("model1", "models/apple.usdz", "model/vnd.usdz+zip", ' fallback="poster1"')]
    pub.add_document("intro", "introduction.xhtml", f"""
<h1 id="H-title">Everything at once</h1>
<h2 id="H-{uuid(1)}">Introduction</h2>
<p id="P-{uuid(2)}" data-origami-address="1A">A paragraph with a
  <a epub:type="glossref" role="doc-glossref" href="backmatter.xhtml#gloss-{g1}">concept</a>, a citation
  <a epub:type="biblioref" role="doc-biblioref" href="backmatter.xhtml#bib-{k1}">[1]</a> and a note
  <a epub:type="noteref" role="doc-noteref" href="backmatter.xhtml#{note}">†</a>.
  <a class="ot-stretchtext" role="button" aria-expanded="false" aria-controls="st-{uuid(13)[:8]}" href="#st-{uuid(13)[:8]}">››</a></p>
<aside class="ot-stretchtext-content" id="st-{uuid(13)[:8]}" hidden="hidden">
  <p>The contracted passage, which is part of the publication and of its full text.</p>
</aside>
""")
    pub.add_document("body", "body.xhtml", f"""
<h2 id="H-{uuid(3)}">Results</h2>
<p id="P-{uuid(6)}" data-origami-address="2A">An equation, a table and a model.</p>
{MATH_BLOCK.format(id=uuid(7))}
<table id="{table}" data-table-id="T-{uuid(9)}">
  <caption>Two numbers and their sum.</caption>
  <thead><tr><th>A</th><th>B</th><th>Sum</th></tr></thead>
  <tbody><tr><td>2</td><td>3</td><td>5</td></tr></tbody>
</table>
{model_figure(8, f'''<img src="images/apple-poster.png" alt="An apple, seen from the side."
       data-model-id="M-{uuid(8)}" data-model-src="models/apple.usdz"
       data-model-media-type="model/vnd.usdz+zip" data-model-filename="Apple_Free_USDZ.usdz"
       data-model-bytes="{len(APPLE)}" data-model-units="m" data-model-extent="0.3 0.2609 0.2878"
       data-model-up="Y"/>
  <figcaption>An apple, seen from the side.</figcaption>''')}
""", properties="mathml")
    pub.backmatter_body = f"""
  <section epub:type="glossary" role="doc-glossary">
    <h2>Glossary</h2>
    <dl>
      <dt id="gloss-{g1}">concept</dt>
      <dd>An idea the writer defines once and refers to throughout.</dd>
    </dl>
  </section>
  <section epub:type="endnotes" role="doc-endnotes">
    <h2>Notes</h2>
    <aside epub:type="endnote" role="note" id="{note}">
      <p>A note, filed under its own address.</p>
    </aside>
  </section>
  <section epub:type="bibliography" role="doc-bibliography">
    <h2>References</h2>
    <ol>
      <li id="bib-{k1}">Engelbart, Douglas C. (1962). Augmenting Human Intellect: A Conceptual Framework.</li>
    </ol>
  </section>
"""
    pub.bibtex = (f"@techreport{{{k1},\n  author = {{Engelbart, Douglas C.}},\n"
                  f"  title = {{Augmenting Human Intellect: A Conceptual Framework}},\n"
                  f"  institution = {{Stanford Research Institute}},\n  year = {{1962}}\n}}\n")
    semantic = {
        "visual-meta": pub.semantic_head(),
        "document": pub.document_block(),
        "structure": {"headings": [
            {"id": f"H-{uuid(1)}", "level": 2, "text": "Introduction", "href": f"introduction.xhtml#H-{uuid(1)}", "address": "1"},
            {"id": f"H-{uuid(3)}", "level": 2, "text": "Results", "href": f"body.xhtml#H-{uuid(3)}", "address": "2"}]},
        "concepts": [{"id": g1, "name": "concept", "description": "An idea the writer defines once and refers to throughout.",
                      "tag": "concept", "citationIdentifiers": [k1], "href": f"backmatter.xhtml#gloss-{g1}"}],
        "citations": [{"id": k1, "number": 1, "href": f"backmatter.xhtml#bib-{k1}", "concepts": [g1]}],
        "endnotes": [{"id": note, "href": f"backmatter.xhtml#{note}", "anchor": f"introduction.xhtml#P-{uuid(2)}",
                      "text": "A note, filed under its own address."}],
        "equations": [{"id": f"E-{uuid(7)}", "href": f"body.xhtml#E-{uuid(7)}", "display": "block", "label": "1",
                       "format": "mathml", "tex": "E = mc^2", "tex-sha256": sha("E = mc^2")}],
        "bibliography": {"href": "references.bib", "conventions": {"dialect": "bibtex", "encoding": "utf-8",
                                                                 "nameOrder": "family-given", "keys": "uuid"}},
    }
    pub.semantic = semantic
    # The embedded copy, serialised differently on purpose: other member
    # order and no indentation. Its RFC 8785 form is identical (§12.2).
    embedded = json.dumps(dict(reversed(list(semantic.items()))), ensure_ascii=False, separators=(",", ":"))
    pub.documents[0] = (pub.documents[0][0], pub.documents[0][1],
                        pub.documents[0][2] + f'\n<script type="application/json" id="visual-meta-payload" '
                        f'data-origami-derived-from="visual-meta.json">{embedded}</script>\n',
                        None, "", None)
    pub.interaction = {
        "origami": pub.interaction_head(),
        "tables": [{"identifier": f"T-{uuid(9)}", "href": f"body.xhtml#{table}", "rowCount": 2, "columnCount": 3,
                    "cells": [[{"value": "A"}, {"value": "B"}, {"value": "Sum"}],
                              [{"value": "2"}, {"value": "3"}, {"value": "5", "formula": "=A2+B2"}]]}],
        "map": {"nodes": [{"id": g1, "label": "concept", "kind": "concept"}],
                "views": [{"id": "V-1", "name": "One concept", "space": {"units": "points", "convention": "right-handed-y-up"},
                           "nodes": [{"ref": g1, "x": 0, "y": 0, "z": 0}]}],
                "connections": []},
        "stretchtext": [{"id": f"st-{uuid(13)[:8]}", "anchor": f"introduction.xhtml#P-{uuid(2)}"}],
        "models": [{"id": f"M-{uuid(8)}", "href": "models/apple.usdz", "media-type": "model/vnd.usdz+zip",
                    "filename": "Apple_Free_USDZ.usdz", "bytes": len(APPLE), "up": "Y", "units": "m",
                    "extent": [0.3, 0.2609, 0.2878], "poster": "images/apple-poster.png",
                    "description": "An apple, seen from the side."}],
    }
    pub.nav_entries = [(f"introduction.xhtml#H-{uuid(1)}", "Introduction"), (f"body.xhtml#H-{uuid(3)}", "Results")]
    return {"combined.epub": pub}


def p09():
    """09 — version relations: one work, two editions; the first edition in
    two releases. Unchanged elements keep their ids; edition 2 records a
    split and a merge as lineage (§4.3, §6.4, §9.7)."""
    work = "urn:uuid:09090909-0909-4909-8909-090909090909"
    ed1 = "urn:uuid:09000001-0000-4000-8000-000000000001"
    ed2 = "urn:uuid:09000002-0000-4000-8000-000000000002"
    keep, a, b, c = f"P-{uuid(1)}", f"P-{uuid(2)}", f"P-{uuid(3)}", f"P-{uuid(4)}"
    a1, a2, bc = f"P-{uuid(5)}", f"P-{uuid(6)}", f"P-{uuid(7)}"

    def edition(edition_id, modified, release, body, lineage=None, replaces=None):
        pub = Pub(9, "Version relations", edition=edition_id, work=work, modified=modified)
        pub.release = release
        if replaces:
            pub.extra_links.append(f'<link rel="dcterms:replaces" href="{replaces}"/>')
        pub.add_document("content", "content.xhtml", body)
        pub.semantic = {"visual-meta": pub.semantic_head(),
                        "document": pub.document_block(defaultDocument="content.xhtml")}
        if lineage:
            pub.semantic["lineage"] = lineage
        return pub

    first = f"""
<h1 id="H-title">Version relations</h1>
<p id="{keep}" data-origami-address="1A">A paragraph no edition changes.</p>
<p id="{a}" data-origami-address="1B">A long paragraph that the second edition splits in two. It has two halves.</p>
<p id="{b}" data-origami-address="1C">One of two paragraphs the second edition merges.</p>
<p id="{c}" data-origami-address="1D">The other of the two.</p>
"""
    corrected = first.replace("It has two halves.", "It has two halves, and a corrected comma.")
    second = f"""
<h1 id="H-title">Version relations</h1>
<p id="{keep}" data-origami-address="1A">A paragraph no edition changes.</p>
<p id="{a1}" data-origami-address="1B">The first half of the split paragraph.</p>
<p id="{a2}" data-origami-address="1C">The second half of the split paragraph.</p>
<p id="{bc}" data-origami-address="1D">The merged paragraph, which replaces two.</p>
"""
    return {
        "edition1-release1.epub": edition(ed1, "2026-09-01T09:00:00Z", "1", first),
        "edition1-release2.epub": edition(ed1, "2026-09-15T09:00:00Z", "1.1 (erratum)", corrected),
        "edition2.epub": edition(ed2, "2026-10-01T09:00:00Z", "2", second, lineage=[
            {"id": a1, "replaces": [a], "inEdition": ed1},
            {"id": a2, "replaces": [a], "inEdition": ed1},
            {"id": bc, "replaces": [b, c], "inEdition": ed1}], replaces=ed1),
    }


def p10():
    """10 — edge cases a reader must survive: unknown Origami members and
    attributes, an unknown record kind, a model entry whose poster is not
    in the package, an embedded record that is a canonical duplicate, and
    (separately) a publication declaring an unknown MAJOR (§16)."""
    pub = Pub(10, "Edge cases")
    pub.files.update({"models/brain.usdz": BRAIN, "future.json": b'{"future": true}\n'})
    pub.items += [("model1", "models/brain.usdz", "model/vnd.usdz+zip", "")]
    pub.extra_links.append('<link rel="record" href="future.json" media-type="application/json" properties="origami:future-kind"/>')
    semantic = {"visual-meta": pub.semantic_head(),
                "document": pub.document_block(defaultDocument="content.xhtml", futureMember={"nested": [1, 2.5, 1e-07]}),
                "futureTopLevel": "ignored"}
    body = f"""
<h1 id="H-title">Edge cases</h1>
<p id="P-{uuid(1)}" data-origami-address="1A" data-origami-future="ignored">A paragraph carrying an attribute no 1.0 reader knows.</p>
<figure id="P-{uuid(2)}">
  <span data-model-id="M-{uuid(2)}" data-model-src="models/brain.usdz"
        data-model-media-type="model/vnd.usdz+zip" data-model-filename="brain.usdz"
        data-model-bytes="{len(BRAIN)}" data-model-up="Y" data-model-lod="3">brain.usdz</span>
  <figcaption>A brain whose model entry names a poster the package does not have.</figcaption>
</figure>
<script type="application/json" id="visual-meta-payload" data-origami-derived-from="visual-meta.json">{json.dumps(semantic, ensure_ascii=False, sort_keys=True)}</script>
"""
    pub.add_document("content", "content.xhtml", body)
    pub.semantic = semantic
    pub.interaction = {"origami": pub.interaction_head(),
                       "models": [{"id": f"M-{uuid(2)}", "href": "models/brain.usdz", "media-type": "model/vnd.usdz+zip",
                                   "filename": "brain.usdz", "bytes": len(BRAIN), "up": "Y",
                                   "poster": "images/missing-poster.png", "futureModelMember": True}],
                       "futureInteraction": {"x": 1}}

    newer = Pub(10, "A newer profile", edition="urn:uuid:10200000-0000-4000-8000-000000000002")
    newer.conforms_to = "https://github.com/frodehegland/OrigamiText/tree/main/profile/2.0"
    newer.add_document("content", "content.xhtml", f"""
<h1 id="H-title">A newer profile</h1>
<h2 id="H-{uuid(3)}">Read as an ordinary EPUB</h2>
<p id="P-{uuid(4)}">A 1.0 reader reads this as an ordinary EPUB and says it is reading a newer profile.</p>
""")
    newer.semantic = {"visual-meta": dict(newer.semantic_head(), version="2.0", profile=newer.conforms_to),
                      "document": newer.document_block(), "somethingNew": {"shape": "unknown"}}
    # Written before 8 October 2026: the profile under its first identifier,
    # a domain never registered. Still 1.0, read as such, with a warning.
    legacy = Pub(10, "The first identifier", edition="urn:uuid:10300000-0000-4000-8000-000000000003")
    legacy.conforms_to = "https://origamitext.org/profile/1.0"
    legacy.vocabulary = "https://origamitext.org/vocab/"
    legacy.add_document("content", "content.xhtml", f"""
<h1 id="H-title">The first identifier</h1>
<p id="P-{uuid(5)}" data-origami-address="1A">This publication declares https://origamitext.org/profile/1.0,
  which names the same profile.</p>
""")
    legacy.semantic = {"visual-meta": dict(legacy.semantic_head(), profile=legacy.conforms_to),
                       "document": legacy.document_block(defaultDocument="content.xhtml")}
    return {"edge-cases.epub": pub, "unknown-major.epub": newer, "legacy-identifier.epub": legacy}


def packaging(letter, title):
    pub = Pub(11, f"Packaging {letter}", edition=f"urn:uuid:11{ord(letter):06d}-0000-4000-8000-000000000011")
    pub.add_document("content", "content.xhtml", f"""
<h1 id="H-title">Packaging {letter}</h1>
<p id="P-{uuid(1)}" data-origami-address="1A">{title}</p>
""")
    pub.semantic = {"visual-meta": pub.semantic_head(),
                    "document": pub.document_block(defaultDocument="content.xhtml")}
    return pub


def p11():
    """11 — record packaging, one variable each (§4.4.1, §4.4.2)."""
    b = packaging("B", "The record is declared by &lt;link rel=\"record\"&gt; only. Conforming.")
    a = packaging("A", "The record is a manifest item with no &lt;link&gt;: undiscoverable by the profile.")
    a.items.append(("vm", "visual-meta.json", "application/json", ""))
    a.records["visual-meta"] = ("visual-meta.json", json.dumps(a.semantic, indent=2) + "\n")
    a.semantic = None
    a._manifest_only = True
    c = packaging("C", "The record is both declared and a manifest item (EPUBCheck OPF-067).")
    c.items.append(("vm", "visual-meta.json", "application/json", ""))
    d = packaging("D", "A content document references the record.")
    d.documents[0] = d.documents[0][:4] + ('\n  <link rel="describedby" href="visual-meta.json" type="application/json"/>',) \
        + d.documents[0][5:]
    e = packaging("E", "The record lives in META-INF/.")
    e.record_dirs["visual-meta"] = "META-INF/visual-meta.json"
    e.colophon_paths = [("Bibliographic and structural identity", "../META-INF/visual-meta.json")]
    return {"B-link-only.epub": b, "A-manifest-only.epub": a, "C-link-and-item.epub": c,
            "D-content-reference.epub": d, "E-meta-inf.epub": e}


def p12():
    """12 — a pre-1.0 publication whose records overlap (§17.2, §17.3)."""
    pub = Pub(12, "A legacy publication")
    pub.conforms_to = None
    pub.work = None
    pub.colophon = False
    pub.rights = None
    pub.license = None
    pub.attribution = None
    pub.prefix_cc = False
    pub.creators = ["Frode Hegland, Alice Reader and Bob Writer"]
    g1, g2, k1, k2 = uuid(10, "a2" * 6), uuid(11, "b2" * 6), uuid(5), uuid(6)
    h1, h2 = f"H-{uuid(1)}", f"H-{uuid(3)}"
    pub.add_document("content", "content.xhtml", f"""
<h1 id="H-title">A legacy publication</h1>
<p id="P-{uuid(9)}">CCS Concepts: Human-centered computing → Hypertext / hypermedia; Information systems → Digital libraries and archives</p>
<h2 id="{h1}">Before the profile</h2>
<p id="P-{uuid(2)}">Glossary terms
  <a epub:type="glossref" role="doc-glossref" href="backmatter.xhtml#gloss-{g1}">record</a> and
  <a epub:type="glossref" role="doc-glossref" href="backmatter.xhtml#gloss-{g2}">sidecar</a>, and citations
  <a epub:type="biblioref" role="doc-biblioref" href="backmatter.xhtml#bib-{k1}">[1]</a>
  <a epub:type="biblioref" role="doc-biblioref" href="backmatter.xhtml#bib-{k2}">[2]</a>.</p>
<h2 id="{h2}">What a reader must do</h2>
<p id="P-{uuid(4)}">Take one source per fact, and never merge two.</p>
""")
    pub.backmatter_body = f"""
  <section epub:type="glossary" role="doc-glossary">
    <h2>Glossary</h2>
    <dl>
      <dt id="gloss-{g1}">record</dt>
      <dd>A file of metadata carried inside the publication.</dd>
      <dt id="gloss-{g2}">sidecar</dt>
      <dd>A file of metadata carried beside a publication rather than inside it.</dd>
    </dl>
  </section>
  <section epub:type="bibliography" role="doc-bibliography">
    <h2>References</h2>
    <ol>
      <li id="bib-{k1}">Bush, Vannevar (1945). As We May Think.</li>
      <li id="bib-{k2}">Licklider, J. C. R. (1960). Man-Computer Symbiosis.</li>
    </ol>
  </section>
"""
    names = ["Frode Hegland", "Alice Reader", "Bob Writer"]
    semantic = {
        "visual-meta": {"format": "visual-meta", "version": "1.0", "generator": "Author (macOS) 2025"},
        "document": {"identifier": pub.edition, "title": "A legacy publication",
                     "authors": ["Frode Hegland, Alice Reader and Bob Writer"],
                     "author-affiliations": {"Frode Hegland": "Future Text Lab, London, UK",
                                             "Alice Reader": "University of Example, Oxford, UK"},
                     "author-emails": {"Frode Hegland": "frode@example.org"},
                     "author-orcids": {"Bob Writer": "0000-0002-1825-0097"},
                     "affiliations": ["Future Text Lab", "University of Example"],
                     "license": "© 2025 the authors. Creative Commons Attribution 4.0 International.",
                     "digest": "sha256:" + "0" * 64},
        "structure": {"headings": [{"id": h1, "level": 2, "text": "Before the profile"},
                                   {"id": h2, "level": 2, "text": "What a reader must do"}]},
        "concepts": [{"id": g1, "name": "record", "description": "A file of metadata carried inside the publication.",
                      "href": f"backmatter.xhtml#gloss-{g1}"},
                     {"id": g2, "name": "sidecar", "description": "A file of metadata carried beside a publication rather than inside it.",
                      "href": f"backmatter.xhtml#gloss-{g2}"}],
        "citations": [],
    }
    interaction = {
        "origami": {"format": "origami-text", "version": "0.9"},
        "glossary": [{"id": g1, "term": "record (interaction copy)", "definition": "Must not be read: the semantic record has concepts."}],
        "references": [
            {"id": k1, "number": 1, "href": f"backmatter.xhtml#bib-{k1}",
             "bibtex": f"@article{{{k1},\n  author = {{Bush, Vannevar}},\n  title = {{As We May Think}},\n  journal = {{The Atlantic}},\n  year = {{1945}}\n}}"},
            {"id": k2, "number": 2, "href": f"backmatter.xhtml#bib-{k2}",
             "bibtex": f"@article{{{k2},\n  author = {{Licklider, J. C. R.}},\n  title = {{Man-Computer Symbiosis}},\n  journal = {{IRE Transactions on Human Factors in Electronics}},\n  year = {{1960}}\n}}"}],
        "headings": [{"id": h1, "level": 2, "text": "Before the profile (interaction copy)"}],
        "tables": [],
    }
    del names
    pub.items += [("vm", "visual-meta.json", "application/json", ""), ("oj", "origami.json", "application/json", "")]
    pub.records["visual-meta"] = ("visual-meta.json", json.dumps(semantic, indent=2, ensure_ascii=False) + "\n")
    pub.records["interaction"] = ("origami.json", json.dumps(interaction, indent=2, ensure_ascii=False) + "\n")
    pub._manifest_only = True
    return {"legacy.epub": pub}


def p13():
    """13 — the colophon (§8.4): present and right; absent (a warning, not
    an error); naming a path that does not resolve; naming META-INF/."""
    def base(name, sentence):
        number = ["conforming", "absent", "wrong path", "META-INF"].index(name) + 1
        pub = Pub(13, f"Colophon: {name}", edition=f"urn:uuid:130000{number:02d}-0000-4000-8000-000000000013")
        pub.add_document("content", "content.xhtml", f"""
<h1 id="H-title">Colophon: {name}</h1>
<p id="P-{uuid(1)}" data-origami-address="1A">{sentence}</p>
""")
        pub.semantic = {"visual-meta": pub.semantic_head(),
                        "document": pub.document_block(defaultDocument="content.xhtml")}
        pub.bibtex = ""
        return pub
    good = base("conforming", "The colophon states the records where they are.")
    absent = base("absent", "No colophon. Conforming, with a warning: the package and records carry everything.")
    absent.colophon = False
    wrong = base("wrong path", "The colophon names a record that is not where it says.")
    wrong.colophon_paths = [("Bibliographic and structural identity", "metadata/visual-meta.json"),
                            ("Bibliography", "references.bib")]
    metainf = base("META-INF", "The records sit in META-INF/ and the colophon says so.")
    metainf.record_dirs["visual-meta"] = "META-INF/visual-meta.json"
    metainf.colophon_paths = [("Bibliographic and structural identity", "META-INF/visual-meta.json"),
                              ("Bibliography", "references.bib")]
    return {"conforming.epub": good, "absent.epub": absent, "wrong-path.epub": wrong, "meta-inf.epub": metainf}


def p14():
    """14 — full scholarly front matter as metadata, none of it as body text
    (§5), including a title and author in another script (§5.5)."""
    pub = Pub(14, "Linked Locative Ludonarrative")
    pub.creators = ["Bob Rimington", "王小明", "Charlie Hargood"]
    pub.rights = "© 2026 Copyright held by the owner/author(s)."
    pub.attribution = "Bob Rimington, 王小明 and Charlie Hargood"
    doi = "10.1145/3800935.3830844"
    venue = "37th ACM Conference on Hypertext and Social Media"
    journal = "New Review of Hypermedia and Multimedia"
    pub.extra_meta += [f'<meta property="dcterms:isPartOf">{venue}</meta>',
                       f'<meta property="dcterms:isPartOf">{journal}</meta>',
                       f"<dc:identifier>{doi}</dc:identifier>",
                       "<dc:subject>Locative Hypertext</dc:subject>",
                       "<dc:subject>Ludonarrative</dc:subject>",
                       '<meta property="dcterms:rightsHolder">Association for Computing Machinery</meta>',
                       '<meta property="dcterms:accessRights">open access</meta>',
                       f'<meta property="cc:attributionURL">https://doi.org/{doi}</meta>']
    acm = ("Bob Rimington, Xiaoming Wang, and Charlie Hargood. 2026. Linked Locative Ludonarrative. In "
           "Proceedings of the 37th ACM Conference on Hypertext and Social Media (HT ’26). ACM, New York, NY, "
           f"USA, 10 pages. https://doi.org/{doi}")
    pub.selfcite = (f"@article{{rimington2026linked,\n  author  = {{Rimington, Bob and 王, 小明 and Hargood, Charlie}},\n"
                    f"  title   = {{Linked Locative Ludonarrative}},\n  journal = {{{journal}}},\n"
                    f"  year    = {{2026}},\n  doi     = {{{doi}}}\n}}")
    pub.add_document("content", "content.xhtml", f"""
<h1 id="H-title">Linked Locative Ludonarrative</h1>
<p class="subtitle" id="P-subtitle">A study in locative hypertext</p>
<p class="authors" id="P-authors">Bob Rimington, 王小明 <span lang="zh-Latn" xml:lang="zh-Latn" data-origami-relation="transliteration">(Wang Xiaoming)</span> and Charlie Hargood</p>
<section role="doc-abstract" id="S-abstract">
  <h2 id="H-abstract">Abstract</h2>
  <p id="P-{uuid(2)}">Hypertext narrative has found itself in new ludic domains.</p>
</section>
<h2 id="H-{uuid(3)}">Introduction</h2>
<p id="P-{uuid(4)}" data-origami-address="1A">The front matter of this paper is metadata. Nothing above the
  introduction is a paragraph a renderer has to recognise.</p>
""")
    pub.semantic = {
        "visual-meta": pub.semantic_head(),
        "document": pub.document_block(
            defaultDocument="content.xhtml",
            authors=[{"name": {"value": "Bob Rimington", "lang": "en"},
                      "affiliation": "University of Southampton, Southampton, UK",
                      "email": "e.m.rimington@soton.ac.uk", "orcid": "0000-0002-1825-0097"},
                     {"name": {"value": "王小明", "lang": "zh-Hans",
                               "alternate": [{"value": "Wang Xiaoming", "lang": "zh-Latn", "relation": "transliteration"},
                                             {"value": "Xiaoming Wang", "lang": "en", "relation": "display"}]},
                      "affiliation": "Peking University, Beijing, China", "orcid": "0000-0001-5109-3700"},
                     {"name": {"value": "Charlie Hargood", "lang": "en"},
                      "affiliation": "Bournemouth University, Poole, UK"}],
            subtitle={"value": "A study in locative hypertext", "lang": "en"},
            abstract={"value": "Hypertext narrative has found itself in new ludic domains.", "lang": "en"},
            publication={"value": venue, "lang": "en"},
            journal={"value": journal, "lang": "en"},
            doi=doi, keywords=["Locative Hypertext", "Ludonarrative"],
            ccsConcepts=["Human-centered computing → User studies",
                         "Human-centered computing → Mixed / augmented reality"],
            acmReference=acm, rightsHolder="Association for Computing Machinery", accessRights="open access"),
        "bibliography": {"conventions": {"dialect": "bibtex", "encoding": "utf-8", "nameOrder": "family-given"}},
    }
    pub.colophon_extra = f"""
    <h3>Publisher's reference</h3>
    <p>{esc(acm)}</p>"""
    return {"scholarly-front-matter.epub": pub}


CORPUS = [
    ("01-basic-addressing", p01, "extraction"),
    ("02-citations", p02, "extraction"),
    ("03-glossary", p03, "extraction"),
    ("04-live-table", p04, "extraction"),
    ("05-equations", p05, "extraction"),
    ("06-spatial-layout", p06, "extraction"),
    ("07-3d-model", p07, "extraction"),
    ("08-combined", p08, "extraction"),
    ("09-version-relations", p09, "extraction"),
    ("10-edge-cases", p10, "extraction"),
    ("11-packaging", p11, "verdict"),
    ("12-legacy-overlapping-records", p12, "extraction"),
    ("13-colophon", p13, "verdict"),
    ("14-scholarly-front-matter", p14, "both"),
]


def finish(pub):
    """Records carried only as manifest items (11 A, 12) leave the package's
    <link> list; everything else is built normally."""
    files = pub.build()
    if getattr(pub, "_manifest_only", False):
        opf = files["OEBPS/content.opf"].decode()
        opf = "\n".join(l for l in opf.split("\n") if 'rel="record"' not in l)
        files["OEBPS/content.opf"] = opf.encode()
    return files


def run_validator(command, epub):
    result = subprocess.run([sys.executable, str(VALIDATOR), command, str(epub)] + (["--json"] if command == "validate" else []),
                            capture_output=True, text=True)
    if command == "extract" and result.returncode != 0:
        raise RuntimeError(result.stderr)
    return json.loads(result.stdout)


def verdict_of(report):
    def dedupe(level):
        seen = []
        for item in report["items"]:
            if item["level"] == level:
                entry = {"code": item["code"], "section": item["section"]}
                if entry not in seen:
                    seen.append(entry)
        return seen
    return {"conforms": report["verdict"]["conforms"], "errors": dedupe("error"), "warnings": dedupe("warning")}


def main(argv):
    check = "--check" in argv
    epubcheck = shlex.split(os.environ.get("EPUBCHECK", "")) if os.environ.get("EPUBCHECK") else None
    target_root = pathlib.Path(tempfile.mkdtemp()) if check else HERE
    failures, ran_epubcheck = [], 0
    for folder, build, kind in CORPUS:
        out = target_root / folder
        out.mkdir(parents=True, exist_ok=True)
        extractions, verdicts = {}, {}
        for name, pub in build().items():
            epub = out / name
            epub.write_bytes(write_epub(finish(pub)))
            if kind in ("extraction", "both"):
                extractions[name] = run_validator("extract", epub)
            verdicts[name] = verdict_of(run_validator("validate", epub))
            if epubcheck:
                result = subprocess.run(epubcheck + [str(epub)], capture_output=True, text=True)
                ran_epubcheck += 1
                summary = [l for l in result.stdout.splitlines() + result.stderr.splitlines() if l.startswith("Messages:")]
                if not summary or "0 fatals / 0 errors / 0 warnings" not in summary[0]:
                    expected_opf067 = name == "C-link-and-item.epub"
                    if not (expected_opf067 and "OPF-067" in result.stdout + result.stderr):
                        failures.append(f"{folder}/{name}: EPUBCheck {summary[0] if summary else result.stderr[-300:]}")
        files = {}
        if extractions:
            files["expected-extraction.json"] = extractions
        files["expected-verdict.json"] = verdicts
        for filename, value in files.items():
            text = json.dumps(value, indent=2, ensure_ascii=False, sort_keys=True) + "\n"
            if check:
                committed = HERE / folder / filename
                if not committed.exists() or committed.read_text() != text:
                    failures.append(f"{folder}/{filename} differs from what the corpus produces")
                for name in (extractions or verdicts):
                    if (HERE / folder / name).read_bytes() != (out / name).read_bytes():
                        failures.append(f"{folder}/{name} differs from what the corpus produces")
            else:
                (out / filename).write_text(text)
        print(f"{folder}: {', '.join(sorted(verdicts))}")
    if epubcheck:
        print(f"\nEPUBCheck ran on {ran_epubcheck} publications")
    else:
        print("\nEPUBCheck was NOT run: set EPUBCHECK (see the header of this file). §20 requires it.")
    for failure in failures:
        print("FAIL", failure)
    return 1 if failures or not epubcheck else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
