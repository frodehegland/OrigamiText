#!/usr/bin/env python3
"""The Origami EPUB Profile 1.0 validator (§19.2) and reference extractor (§20.1).

    origami-validate.py validate PUBLICATION [--json] [--model-budget BYTES]
    origami-validate.py extract  PUBLICATION

PUBLICATION is an .epub file or an unpacked EPUB directory.

`validate` checks everything §19.2 lists — every §18.1 error and every
§18.2 warning — and exits 1 when any error is found, 0 otherwise. It is
the profile half of §19; run EPUBCheck for the EPUB half. Both must pass.

`extract` runs the reader algorithm of §17 and prints the extraction
§20.1 defines: what a conforming reader takes from the publication, in a
form two implementations can diff. The conformance corpus's expected
extractions are this output, reviewed by hand.

Needs Python 3.9+ and, for the record schemas, `jsonschema`:

    python3 -m venv /tmp/jsonenv && /tmp/jsonenv/bin/pip install jsonschema

Nothing here reads the source of any reading application. Where the
profile leaves a choice to the validator, the choice is stated where it
is made.
"""

import argparse
import hashlib
import json
import pathlib
import posixpath
import re
import sys
import urllib.parse
import xml.etree.ElementTree as ET
import zipfile
from decimal import Decimal

HERE = pathlib.Path(__file__).resolve().parent
PROFILE_BASE = "https://github.com/frodehegland/OrigamiText/tree/main/profile/"
VOCABULARY = "https://github.com/frodehegland/OrigamiText/blob/main/profile/vocab.md#"
# §4.2: what publications written before 8 October 2026 declare, under a
# domain that was never registered. Still this profile; reported, not refused.
LEGACY_PROFILE_BASE = "https://origamitext.org/profile/"
LEGACY_VOCABULARY = "https://origamitext.org/vocab/"
IMPLEMENTED_MAJOR = 1
EXTRACTION_VERSION = "1.0"

NS = {
    "opf": "http://www.idpf.org/2007/opf",
    "dc": "http://purl.org/dc/elements/1.1/",
    "xhtml": "http://www.w3.org/1999/xhtml",
    "epub": "http://www.idpf.org/2007/ops",
    "math": "http://www.w3.org/1998/Math/MathML",
    "container": "urn:oasis:names:tc:opendocument:xmlns:container",
    "enc": "http://www.w3.org/2001/04/xmlenc#",
}
X = "{%s}" % NS["xhtml"]
EPUB_TYPE = "{%s}type" % NS["epub"]
MATH = "{%s}math" % NS["math"]

RECORD_KINDS = {
    "origami:visual-meta": "visual-meta",
    "origami:interaction": "interaction",
    "origami:bibliography": "bibliography",
}
SELF_ID = {"visual-meta": "visual-meta", "origami-text": "interaction"}

# §10.0: members the interaction record may not carry, at any depth.
FORBIDDEN_IN_INTERACTION = {
    "concepts", "glossary", "citations", "references", "headings",
    "structure", "endnotes", "footnotes", "links", "lineage", "equations",
    "bibliography",
}
READER_STATE = {
    "readingPosition", "readerState", "runtimeState", "annotations",
    "highlights", "bookmarks", "lastRead",
}
FORBIDDEN_IN_SEMANTIC = {"tables", "map", "models"}

REQUIRED_A11Y = [
    "schema:accessMode", "schema:accessModeSufficient",
    "schema:accessibilityFeature", "schema:accessibilityHazard",
    "schema:accessibilitySummary",
]
MODEL_MEDIA_TYPES = {"model/vnd.usdz+zip", "application/x-reality", "model/gltf-binary"}
REQUIRED_MODEL_ATTRIBUTES = [
    "data-model-src", "data-model-id", "data-model-media-type",
    "data-model-filename", "data-model-bytes", "data-model-up",
]
# EPUB 3.3 §3.2 core media types, and the exempt kinds of §3.4 the checks
# below can meet. Anything else referenced from a content document or the
# spine needs a manifest fallback.
CORE_MEDIA_TYPES = {
    "image/gif", "image/jpeg", "image/png", "image/svg+xml", "image/webp",
    "audio/mpeg", "audio/mp4", "audio/ogg", "audio/opus", "text/css",
    "font/ttf", "font/otf", "font/woff", "font/woff2", "application/font-sfnt",
    "application/font-woff", "application/vnd.ms-opentype",
    "application/xhtml+xml", "application/javascript", "text/javascript",
    "application/ecmascript", "application/x-dtbncx+xml",
    "application/smil+xml", "application/pls+xml",
}
REGISTERED_PREFIXES = {"origami", "cc"}
PREDECLARED_PREFIXES = {
    "dcterms", "schema", "a11y", "marc", "media", "onix", "rendition",
    "xsd", "msv", "prism",
}
NCNAME = re.compile(r"^[^\W\d][\w.\-·̀-ͯ‿⁀]*$")
MODIFIED = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
URN_UUID = re.compile(
    r"^urn:uuid:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
UUID_TAIL = re.compile(
    r"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$")
BIBTEX_STRING = re.compile(r"@\s*[A-Za-z]+\s*[{(]\s*[^\s,]+\s*,\s*[A-Za-z]+\s*=")
URI = re.compile(r"^[A-Za-z][A-Za-z0-9+.\-]*:\S+$")
RECORD_PATH = re.compile(r"\.(json|jsonld|bib|bibtex|csl|xml|ttl)$", re.IGNORECASE)
DEFAULT_MODEL_BUDGET = 50 * 1024 * 1024


# ---------------------------------------------------------------------------
# Reporting

class Report:
    def __init__(self):
        self.items = []

    def error(self, code, section, message, where=None):
        self.items.append({"level": "error", "code": code, "section": section,
                           "message": message, "where": where})

    def warning(self, code, section, message, where=None):
        self.items.append({"level": "warning", "code": code, "section": section,
                           "message": message, "where": where})

    def note(self, code, section, message, where=None):
        self.items.append({"level": "note", "code": code, "section": section,
                           "message": message, "where": where})

    @property
    def errors(self):
        return [i for i in self.items if i["level"] == "error"]

    @property
    def warnings(self):
        return [i for i in self.items if i["level"] == "warning"]

    def verdict(self):
        return {
            "conforms": not self.errors,
            "errors": sorted({i["code"] for i in self.errors}),
            "warnings": sorted({i["code"] for i in self.warnings}),
        }


# ---------------------------------------------------------------------------
# The container

class Container:
    """An EPUB, zipped or unpacked, addressed by container-root paths."""

    def __init__(self, path):
        self.path = pathlib.Path(path)
        if self.path.is_dir():
            self.names = sorted(
                str(p.relative_to(self.path)).replace("\\", "/")
                for p in self.path.rglob("*") if p.is_file())
            self._zip = None
        else:
            self._zip = zipfile.ZipFile(self.path)
            self.names = [n for n in self._zip.namelist() if not n.endswith("/")]
        self.name_set = set(self.names)

    def exists(self, name):
        return name in self.name_set

    def read(self, name):
        if name not in self.name_set:
            return None
        if self._zip is not None:
            return self._zip.read(name)
        return (self.path / name).read_bytes()

    def size(self, name):
        if name not in self.name_set:
            return None
        if self._zip is not None:
            return self._zip.getinfo(name).file_size
        return (self.path / name).stat().st_size

    def text(self, name):
        data = self.read(name)
        return None if data is None else data.decode("utf-8", errors="replace")


def resolve(base_file, href):
    """Resolve a relative reference against the file it appears in, giving a
    container path and a fragment. External references give (None, None)."""
    if href is None:
        return None, None
    href = href.strip()
    parsed = urllib.parse.urlsplit(href)
    if parsed.scheme or href.startswith("//"):
        return None, None
    path = urllib.parse.unquote(parsed.path)
    fragment = urllib.parse.unquote(parsed.fragment) if parsed.fragment or "#" in href else None
    if path == "":
        target = base_file
    else:
        target = posixpath.normpath(posixpath.join(posixpath.dirname(base_file), path))
    return target, fragment


def text_of(element):
    return " ".join("".join(element.itertext()).split())


def local(tag):
    return tag.rsplit("}", 1)[-1] if isinstance(tag, str) else ""


def classes(element):
    return (element.get("class") or "").split()


def tokens(value):
    return (value or "").split()


# ---------------------------------------------------------------------------
# JSON canonicalisation (RFC 8785) — for §12.2's exact-duplicate test

def jcs(value):
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return _es_number(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        return "[" + ",".join(jcs(v) for v in value) + "]"
    if isinstance(value, dict):
        keys = sorted(value, key=lambda k: k.encode("utf-16-be"))
        return "{" + ",".join(json.dumps(k, ensure_ascii=False) + ":" + jcs(value[k])
                              for k in keys) + "}"
    raise TypeError(type(value))


def _es_number(number):
    """ECMAScript Number.prototype.toString, as RFC 8785 §3.2.2.3 requires."""
    if number != number or number in (float("inf"), float("-inf")):
        raise ValueError("JCS cannot represent NaN or Infinity")
    if number == 0:
        return "0"
    # Shortest round-tripping digits, then ECMAScript's placement rules —
    # never int(number), whose exact binary value ES does not print.
    digits, exponent = _shortest(number)
    n = exponent + 1          # position of the decimal point, ES style
    k = len(digits)
    sign = "-" if number < 0 else ""
    if k <= n <= 21:
        return sign + digits + "0" * (n - k)
    if 0 < n <= 21:
        return sign + digits[:n] + "." + digits[n:]
    if -6 < n <= 0:
        return sign + "0." + "0" * (-n) + digits
    e = n - 1
    mantissa = digits[0] + ("." + digits[1:] if k > 1 else "")
    return sign + mantissa + "e" + ("+" if e > 0 else "-") + str(abs(e))


def _shortest(number):
    text = repr(abs(number))
    d = Decimal(text).normalize()
    sign, digit_tuple, exp = d.as_tuple()
    digits = "".join(map(str, digit_tuple)).rstrip("0") or "0"
    exponent = len(digit_tuple) + exp - 1
    return digits, exponent


def canonical_hash(value):
    return hashlib.sha256(jcs(value).encode("utf-8")).hexdigest()


# ---------------------------------------------------------------------------
# BibTeX

class BibTeXError(Exception):
    pass


# BibTeX's predefined month macros, expanded as the standard styles do.
MONTHS = {name[:3].lower(): name for name in [
    "January", "February", "March", "April", "May", "June", "July",
    "August", "September", "October", "November", "December"]}


def parse_bibtex(text):
    """Entries in order: [{'type', 'key', 'fields': {name: value}}]. Raises
    BibTeXError on anything a BibTeX tool would refuse. Values keep their
    inner braces; macros and `#` concatenation are expanded."""
    entries, strings, i, n = [], dict(MONTHS), 0, len(text)

    def skip_ws(j):
        while j < n and text[j].isspace():
            j += 1
        return j

    def read_braced(j):
        depth, start = 1, j + 1
        j += 1
        while j < n and depth:
            if text[j] == "\\":
                j += 2
                continue
            if text[j] == "{":
                depth += 1
            elif text[j] == "}":
                depth -= 1
            j += 1
        if depth:
            raise BibTeXError("unbalanced braces")
        return text[start:j - 1], j

    def read_quoted(j):
        depth, start = 0, j + 1
        j += 1
        while j < n:
            c = text[j]
            if c == "\\":
                j += 2
                continue
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
            elif c == '"' and depth == 0:
                return text[start:j], j + 1
            j += 1
        raise BibTeXError("unterminated quoted value")

    def read_value(j):
        parts = []
        while True:
            j = skip_ws(j)
            if j >= n:
                raise BibTeXError("value runs off the end")
            c = text[j]
            if c == "{":
                part, j = read_braced(j)
            elif c == '"':
                part, j = read_quoted(j)
            else:
                m = re.match(r"[A-Za-z0-9_\-:.+/']+", text[j:])
                if not m:
                    raise BibTeXError(f"unexpected {c!r} in a value")
                word = m.group(0)
                j += len(word)
                part = word if word.isdigit() else strings.get(word.lower())
                if part is None:
                    raise BibTeXError(f"undefined macro {word!r}")
            parts.append(part)
            j = skip_ws(j)
            if j < n and text[j] == "#":
                j += 1
                continue
            return "".join(parts), j

    while True:
        at = text.find("@", i)
        if at < 0:
            break
        m = re.match(r"@\s*([A-Za-z]+)\s*([{(])", text[at:])
        if not m:
            raise BibTeXError("an @ that does not open an entry")
        kind = m.group(1).lower()
        close = "}" if m.group(2) == "{" else ")"
        j = at + m.end()
        if kind == "comment":
            if m.group(2) == "{":
                _, j = read_braced(at + m.end() - 1)
            i = j
            continue
        if kind == "preamble":
            _, j = read_value(j)
            j = skip_ws(j)
            if j >= n or text[j] != close:
                raise BibTeXError("unterminated @preamble")
            i = j + 1
            continue
        if kind == "string":
            km = re.match(r"\s*([A-Za-z][A-Za-z0-9_\-:.]*)\s*=", text[j:])
            if not km:
                raise BibTeXError("malformed @string")
            value, j = read_value(j + km.end())
            strings[km.group(1).lower()] = value
            j = skip_ws(j)
            if j >= n or text[j] != close:
                raise BibTeXError("unterminated @string")
            i = j + 1
            continue
        km = re.match(r"\s*([^\s,{}()=\"#]+)\s*,", text[j:])
        if not km:
            raise BibTeXError(f"@{kind} entry with no key")
        key = km.group(1)
        j += km.end()
        fields = {}
        while True:
            j = skip_ws(j)
            if j < n and text[j] == close:
                j += 1
                break
            fm = re.match(r"([A-Za-z][A-Za-z0-9_\-:.+]*)\s*=", text[j:])
            if not fm:
                raise BibTeXError(f"malformed field in {key}")
            name = fm.group(1).lower()
            value, j = read_value(j + fm.end())
            fields[name] = value
            j = skip_ws(j)
            if j < n and text[j] == ",":
                j += 1
                continue
            j = skip_ws(j)
            if j < n and text[j] == close:
                j += 1
                break
            raise BibTeXError(f"expected , or {close} after a field in {key}")
        entries.append({"type": kind, "key": key, "fields": fields})
        i = j
    return entries


def bib_plain(value):
    """A field value compared as text: braces and runs of space removed."""
    return " ".join(str(value).replace("{", "").replace("}", "").split())


# ---------------------------------------------------------------------------
# Reading the publication

class Publication:
    """Everything the checks and the extraction need, read once."""

    def __init__(self, container, report):
        self.c = container
        self.r = report
        self.opf_path = None
        self.opf = None
        self.package_dir = ""
        self.manifest = {}          # id -> item dict
        self.by_path = {}           # container path -> item dict
        self.spine = []             # container paths of content documents
        self.meta = {}              # property -> [values]
        self.meta_elements = []
        self.dc = {}                # local name -> [values]
        self.links = []             # package <link> dicts
        self.records = []           # declared record dicts
        self.docs = {}              # container path -> ElementTree root
        self.ids = {}               # container path -> {id: element}
        self.parents = {}           # container path -> {element: parent}
        self.semantic = None
        self.interaction = None
        self.bibliography = None    # list of entries, or None
        self.bib_by_key = {}
        self.profile = None
        self.major = None
        self.minor = None
        self.edition = None
        self.default_document = None
        self.legacy_identifier = False

    # -- paths -------------------------------------------------------------

    def rel(self, container_path):
        """A container path written relative to the package document, which
        is how §6.1 writes an address."""
        if container_path is None:
            return None
        return posixpath.relpath(container_path, self.package_dir or ".")

    def address(self, container_path, fragment):
        return f"{self.rel(container_path)}#{fragment}"

    def from_package(self, href):
        return resolve(self.opf_path, href)

    # -- loading -----------------------------------------------------------

    def load(self):
        c, r = self.c, self.r
        if c.read("mimetype") is None:
            r.error("OCF-MIMETYPE", "§4.1", "no mimetype file")
        container = c.read("META-INF/container.xml")
        if container is None:
            r.error("OCF-CONTAINER", "§4.1", "no META-INF/container.xml")
            return False
        try:
            root = ET.fromstring(container)
        except ET.ParseError as e:
            r.error("OCF-CONTAINER", "§4.1", f"container.xml is not well-formed: {e}")
            return False
        rootfile = root.find(".//container:rootfile", NS)
        if rootfile is None or not rootfile.get("full-path"):
            r.error("OCF-CONTAINER", "§4.1", "container.xml names no package document")
            return False
        self.opf_path = rootfile.get("full-path")
        self.package_dir = posixpath.dirname(self.opf_path)
        data = c.read(self.opf_path)
        if data is None:
            r.error("OCF-CONTAINER", "§4.1", f"package document {self.opf_path} is missing")
            return False
        try:
            self.opf = ET.fromstring(data)
        except ET.ParseError as e:
            r.error("OPF-XML", "§4.1", f"package document is not well-formed: {e}")
            return False
        self._read_package()
        self._read_documents()
        return True

    def _read_package(self):
        opf, r = self.opf, self.r
        metadata = opf.find("opf:metadata", NS)
        if metadata is None:
            metadata = ET.Element("metadata")
        for element in metadata:
            name = local(element.tag)
            if element.tag.startswith("{%s}" % NS["dc"]):
                self.dc.setdefault(name, []).append(
                    {"value": text_of(element), "id": element.get("id"), "element": element})
            elif name == "meta" and element.get("property"):
                prop = element.get("property")
                self.meta.setdefault(prop, []).append(text_of(element))
                self.meta_elements.append(element)
            elif name == "link":
                self.links.append(dict(element.attrib))
        manifest = opf.find("opf:manifest", NS)
        for item in (manifest if manifest is not None else []):
            if local(item.tag) != "item":
                continue
            entry = dict(item.attrib)
            path, _ = self.from_package(entry.get("href", ""))
            entry["path"] = path
            entry["properties-list"] = tokens(entry.get("properties"))
            self.manifest[entry.get("id")] = entry
            if path:
                self.by_path[path] = entry
        spine = opf.find("opf:spine", NS)
        for itemref in (spine if spine is not None else []):
            item = self.manifest.get(itemref.get("idref"))
            if item and item.get("path"):
                self.spine.append(item["path"])

        identifier_id = opf.get("unique-identifier")
        for entry in self.dc.get("identifier", []):
            if entry["id"] == identifier_id:
                self.edition = entry["value"]
        conforms = self.meta.get("dcterms:conformsTo", [])
        for value in conforms:
            base = next((b for b in (PROFILE_BASE, LEGACY_PROFILE_BASE) if value.startswith(b)), None)
            if base:
                self.profile = value
                self.legacy_identifier = base == LEGACY_PROFILE_BASE
                m = re.match(r"^(\d+)\.(\d+)$", value[len(base):].strip("/"))
                if m:
                    self.major, self.minor = int(m.group(1)), int(m.group(2))

    def _read_documents(self):
        for path in self.spine:
            item = self.by_path.get(path, {})
            if item.get("media-type") != "application/xhtml+xml":
                continue
            data = self.c.read(path)
            if data is None:
                continue
            try:
                root = ET.fromstring(data)
            except ET.ParseError as e:
                self.r.error("XHTML-XML", "§7.1", f"{self.rel(path)} is not well-formed XML: {e}")
                continue
            self.docs[path] = root
            self.parents[path] = {child: parent for parent in root.iter() for child in parent}
            ids = {}
            for element in root.iter():
                value = element.get("id")
                if value is not None and value not in ids:
                    ids[value] = element
            self.ids[path] = ids

    def load_records(self, mode):
        """Declared records (§4.4); in pre-1.0 mode, also the §17.2 fallbacks."""
        r = self.r
        for link in self.links:
            if "record" not in tokens(link.get("rel")):
                continue
            path, _ = self.from_package(link.get("href"))
            props = tokens(link.get("properties"))
            kind = next((RECORD_KINDS[p] for p in props if p in RECORD_KINDS), None)
            self.records.append({"href": link.get("href"), "path": path, "kind": kind,
                                 "properties": link.get("properties"),
                                 "media-type": link.get("media-type"), "declared": True})
        if mode == "pre-1.0":
            self._discover_by_name()
        for record in self.records:
            if record["kind"] is None and not record["properties"]:
                record["kind"] = self._self_identified(record["path"])
        for record in self.records:
            if record["kind"] in ("visual-meta", "interaction") and record.get("data") is None:
                record["data"] = self._json(record["path"])
            if record["kind"] == "visual-meta" and self.semantic is None:
                self.semantic = record.get("data")
                record["used"] = True
            elif record["kind"] == "interaction" and self.interaction is None:
                self.interaction = record.get("data")
                record["used"] = True
            elif record["kind"] == "bibliography" and self.bibliography is None:
                text = self.c.text(record["path"]) if record["path"] else None
                if text is not None:
                    try:
                        self.bibliography = parse_bibtex(text)
                        record["used"] = True
                    except BibTeXError as e:
                        r.error("BIB-PARSE", "§11", f"the bibliography record does not parse: {e}",
                                self.rel(record["path"]))
                        self.bibliography = []
        for entry in self.bibliography or []:
            self.bib_by_key.setdefault(entry["key"], entry)
        if isinstance(self.semantic, dict):
            document = self.semantic.get("document")
            if isinstance(document, dict) and isinstance(document.get("defaultDocument"), str):
                self.default_document = document["defaultDocument"]

    def _json(self, path):
        text = self.c.text(path) if path else None
        if text is None:
            return None
        try:
            return json.loads(text)
        except json.JSONDecodeError as e:
            self.r.error("RECORD-JSON", "§9", f"{self.rel(path)} is not JSON: {e}")
            return None

    def _self_identified(self, path):
        data = self._json(path) if path and path.lower().endswith(".json") else None
        if isinstance(data, dict):
            for key in ("visual-meta", "origami"):
                head = data.get(key)
                if isinstance(head, dict) and head.get("format") in SELF_ID:
                    return SELF_ID[head["format"]]
        return None

    def _discover_by_name(self):
        """§17.2 items 1–2: by name, else by path ending, else embedded."""
        have = {rec["kind"] for rec in self.records}
        for kind, name in (("visual-meta", "visual-meta.json"), ("interaction", "origami.json")):
            if kind in have:
                continue
            candidates = [p for p in self.c.names if posixpath.basename(p) == name]
            if not candidates:
                candidates = [p for p in self.c.names if p.endswith(name)]
            if candidates:
                self.records.append({"href": self.rel(candidates[0]), "path": candidates[0],
                                     "kind": kind, "properties": None, "declared": False})
            elif kind == "visual-meta":
                for path, root in self.docs.items():
                    for script in root.iter(X + "script"):
                        if script.get("id") == "visual-meta-payload":
                            try:
                                data = json.loads("".join(script.itertext()))
                            except json.JSONDecodeError:
                                continue
                            self.records.append({"href": self.rel(path) + "#visual-meta-payload",
                                                 "path": None, "kind": kind, "data": data,
                                                 "properties": None, "declared": False,
                                                 "embedded": True})
                            break

    # -- addressing --------------------------------------------------------

    def find(self, path, fragment):
        if path is None or fragment is None:
            return None
        return self.ids.get(path, {}).get(fragment)

    def resolve_record_address(self, value, allow_bare=True):
        """A record's address: path-plus-fragment relative to the package
        document (§6.1), or a bare fragment against document.defaultDocument
        (§9.2). Returns (container path, fragment, element)."""
        if not isinstance(value, str) or not value:
            return None, None, None
        if "#" not in value:
            if not allow_bare or not self.default_document:
                return None, value, None
            path, _ = self.from_package(self.default_document)
            return path, value, self.find(path, value)
        path, fragment = self.from_package(value)
        return path, fragment, self.find(path, fragment)

    def elements_with_ids(self):
        for path in self.docs:
            for element in self.docs[path].iter():
                if element.get("id") is not None:
                    yield path, element

    def nearest_id(self, path, element):
        parents = self.parents.get(path, {})
        node = element
        while node is not None:
            if node.get("id") is not None:
                return node.get("id")
            node = parents.get(node)
        return None

    def in_section(self, path, element, kind):
        parents = self.parents.get(path, {})
        node = parents.get(element)
        while node is not None:
            if kind in tokens(node.get(EPUB_TYPE)) or f"doc-{kind}" in tokens(node.get("role")):
                return True
            node = parents.get(node)
        return False

    def colophon_documents(self):
        """Documents that hold only a colophon and record sections, which
        §8.4.6 rule 4 excludes from making a publication multi-document."""
        return [p for p in self.docs
                if any("colophon" in tokens(s.get(EPUB_TYPE)) for s in self.docs[p].iter())]


# ---------------------------------------------------------------------------
# Validation

def validate(pub, report, model_budget=DEFAULT_MODEL_BUDGET, schemas=True):
    if not pub.load():
        return
    mode = check_profile(pub, report)
    pub.load_records(mode if mode != "ordinary-epub" else "profile")
    if mode == "ordinary-epub":
        return
    check_identity(pub, report)
    check_prefixes(pub, report)
    check_accessibility(pub, report)
    check_rights(pub, report)
    check_encryption(pub, report)
    check_records(pub, report, schemas)
    check_manifest(pub, report)
    check_documents(pub, report)
    check_references(pub, report)
    check_models(pub, report, model_budget)
    check_tables(pub, report)
    check_equations(pub, report)
    check_glossary(pub, report)
    check_citations(pub, report)
    check_headings(pub, report)
    check_front_matter(pub, report)
    check_embedded(pub, report)
    check_colophon(pub, report)


def check_profile(pub, r):
    opf = pub.opf
    if opf.get("version") != "3.0":
        r.error("PKG-VERSION", "§4.1", f"package version is {opf.get('version')!r}, not \"3.0\"")
    if not opf.get("unique-identifier"):
        r.error("PKG-UNIQUE-ID", "§4.1", "package declares no unique-identifier")
    for element in pub.meta_elements:
        prop = element.get("property")
        if prop in ("origami:profile", "origami:work", "origami:supersedes", "origami:replaces"):
            r.error("PKG-FORBIDDEN-PROPERTY", "§4.2–4.3",
                    f"{prop} must not be used; the profile uses Dublin Core for this")
    if pub.profile is None:
        r.error("PROFILE-MISSING", "§4.2",
                f"no dcterms:conformsTo naming {PROFILE_BASE}MAJOR.MINOR")
        return "pre-1.0"
    if pub.major is None:
        r.error("PROFILE-MALFORMED", "§4.2", f"profile identifier {pub.profile!r} does not end in MAJOR.MINOR")
        return "pre-1.0"
    if pub.major != IMPLEMENTED_MAJOR:
        r.error("PROFILE-MAJOR", "§16.2",
                f"declares profile {pub.major}.{pub.minor}; this validator implements "
                f"{IMPLEMENTED_MAJOR}.x and checks it as an ordinary EPUB only")
        return "ordinary-epub"
    if pub.legacy_identifier:
        r.warning("PROFILE-LEGACY-ID", "§4.2", f"declares the pre-8-October-2026 identifier {pub.profile!r}; "
                  f"a writer now declares {PROFILE_BASE}{pub.major}.{pub.minor}")
    return "profile"


def check_identity(pub, r):
    if not pub.edition:
        r.error("ID-EDITION", "§4.3", "no dc:identifier carries the package's unique-identifier")
    works = pub.meta.get("dcterms:isVersionOf", [])
    if not works:
        r.error("ID-WORK", "§4.3", "no dcterms:isVersionOf names the work")
    for work in works:
        if not URN_UUID.match(work):
            r.error("ID-WORK", "§4.3", f"dcterms:isVersionOf {work!r} is not a urn:uuid:")
    modified = pub.meta.get("dcterms:modified", [])
    if len(modified) != 1:
        r.error("ID-RELEASE", "§4.3", "exactly one dcterms:modified is required")
    elif not MODIFIED.match(modified[0]):
        r.error("ID-RELEASE", "§4.3", f"dcterms:modified {modified[0]!r} is not CCYY-MM-DDThh:mm:ssZ")
    for value in pub.meta.get("dcterms:hasVersion", []):
        if not URI.match(value):
            r.error("ID-HASVERSION", "§4.3",
                    f"dcterms:hasVersion carries the literal {value!r}; a revision label is schema:version")


def check_prefixes(pub, r):
    declared = {}
    parts = (pub.opf.get("prefix") or "").split()
    for i in range(0, len(parts) - 1, 2):
        declared[parts[i].rstrip(":")] = parts[i + 1]
    used = set()
    for element in pub.meta_elements:
        for attr in ("property", "scheme"):
            if ":" in (element.get(attr) or ""):
                used.add(element.get(attr).split(":")[0])
    for link in pub.links:
        for value in tokens(link.get("properties")) + tokens(link.get("rel")):
            if ":" in value and not value.startswith("http"):
                used.add(value.split(":")[0])
    for item in pub.manifest.values():
        for value in item["properties-list"]:
            if ":" in value:
                used.add(value.split(":")[0])
    for prefix in sorted(used - PREDECLARED_PREFIXES - set(declared)):
        r.error("PKG-PREFIX", "§4.1", f"prefix {prefix!r} is used but not declared")
    if declared.get("origami") == LEGACY_VOCABULARY:
        r.warning("PKG-PREFIX-LEGACY", "§4.1", f"origami: is bound to the pre-8-October-2026 {LEGACY_VOCABULARY}")
    elif declared.get("origami") not in (None, VOCABULARY):
        r.error("PKG-PREFIX", "§4.1", f"origami: is bound to {declared['origami']!r}")
    for prefix in sorted(set(declared) - used):
        r.warning("PKG-PREFIX-UNUSED", "§4.1", f"prefix {prefix!r} is declared but not used")


def images(pub):
    for path, root in pub.docs.items():
        for img in root.iter(X + "img"):
            yield path, img


def has_adjacent_caption(pub, path, img):
    parents = pub.parents[path]
    node = parents.get(img)
    while node is not None and local(node.tag) != "figure":
        node = parents.get(node)
    return node is not None and node.find(X + "figcaption") is not None \
        and text_of(node.find(X + "figcaption")) != ""


def check_accessibility(pub, r):
    for prop in REQUIRED_A11Y:
        if not pub.meta.get(prop):
            r.error("A11Y-MISSING", "§4.6", f"{prop} is required")
    features = set(pub.meta.get("schema:accessibilityFeature", []))
    sufficient = pub.meta.get("schema:accessModeSufficient", [])
    textual_only = any(set(v.replace(" ", "").split(",")) == {"textual"} for v in sufficient)
    undescribed = []
    for path, img in images(pub):
        alt = img.get("alt")
        if alt is None:
            undescribed.append((path, img, "has no alt"))
        elif alt.strip() == "" and not has_adjacent_caption(pub, path, img):
            undescribed.append((path, img, "has alt=\"\" and no adjacent caption"))
    if undescribed and ("alternativeText" in features or textual_only):
        for path, img, why in undescribed:
            r.error("A11Y-CLAIM", "§4.6, §7.9.6",
                    f"claims {'alternativeText' if 'alternativeText' in features else 'textual accessModeSufficient'}"
                    f" but an image {why}", f"{pub.rel(path)} img[src={img.get('src')}]")
    for path, img in images(pub):
        if img.get("alt") is None:
            r.error("FIG-ALT", "§7.8", "an <img> has no alt attribute",
                    f"{pub.rel(path)} img[src={img.get('src')}]")


def check_rights(pub, r):
    rights = [e["value"] for e in pub.dc.get("rights", [])]
    licenses = pub.meta.get("dcterms:license", [])
    if not rights and not licenses:
        r.warning("RIGHTS-NONE", "§4.7", "no rights statement (dc:rights or dcterms:license)")
        if pub.c.exists("META-INF/rights.xml"):
            r.error("RIGHTS-ONLY-XML", "§4.7.4", "META-INF/rights.xml is the only rights statement")
    for value in licenses:
        if not URI.match(value):
            r.warning("RIGHTS-LICENSE-URI", "§4.7.1", f"dcterms:license {value!r} is not a URI")


def check_encryption(pub, r):
    data = pub.c.read("META-INF/encryption.xml")
    if data is None:
        return
    try:
        root = ET.fromstring(data)
    except ET.ParseError as e:
        r.error("ENC-XML", "§4.7.4", f"encryption.xml is not well-formed: {e}")
        return
    records = {rec["path"] for rec in pub.records if rec.get("path")}
    for ref in root.iter("{%s}CipherReference" % NS["enc"]):
        target = posixpath.normpath(urllib.parse.unquote(ref.get("URI", "")))
        item = pub.by_path.get(target, {})
        if target in records or item.get("media-type") in ("application/xhtml+xml", "image/svg+xml") \
                or target in pub.spine:
            r.error("ENC-CONTENT", "§4.7.4", f"{target} is encrypted; only fonts may be", target)


def check_records(pub, r, schemas):
    validators = load_schemas() if schemas else None
    if schemas and validators is None:
        r.error("SCHEMA-UNAVAILABLE", "§19.1",
                "the jsonschema package is not installed, so records were not checked "
                "against their schemas; install it (see the header of this file)")
    kinds_seen = {}
    for record in pub.records:
        where = record["href"]
        if record["path"] and not record.get("embedded"):
            if record["path"].startswith("META-INF/"):
                r.error("REC-META-INF", "§4.4.2", "a record lives in META-INF/", where)
            if not pub.c.exists(record["path"]):
                r.error("REC-MISSING", "§18.1", "a <link rel=\"record\"> names a resource not in the package", where)
            if record["path"] in pub.by_path and record.get("declared"):
                r.error("REC-IN-MANIFEST", "§4.4.1", "a record is also a manifest item (EPUBCheck OPF-067)", where)
        if record.get("declared") and not record["properties"]:
            r.error("REC-PROPERTIES", "§4.4", "a <link rel=\"record\"> has no properties attribute", where)
        if record["kind"] is None:
            r.note("REC-UNKNOWN-KIND", "§4.4", f"record kind {record['properties']!r} is not 1.0's; ignored", where)
            continue
        kinds_seen.setdefault(record["kind"], []).append(record)
        if record["kind"] == "bibliography":
            continue
        data = record.get("data")
        if data is None:
            continue
        head_key = "visual-meta" if record["kind"] == "visual-meta" else "origami"
        head = data.get(head_key) if isinstance(data, dict) else None
        if not isinstance(head, dict) or not head.get("format") or not head.get("version"):
            r.error("REC-SELF-ID", "§9.1, §10.1", "the record does not identify its format and version", where)
        elif head.get("describes") != pub.edition:
            r.error("REC-DESCRIBES", "§9.1, §17.1",
                    f"describes {head.get('describes')!r}, not the publication's {pub.edition!r}", where)
        if validators is not None:
            schema_kind = "visual-meta" if record["kind"] == "visual-meta" else "origami-text"
            for e in sorted(validators[schema_kind].iter_errors(data), key=lambda e: list(e.path))[:20]:
                at = "/".join(str(p) for p in e.path) or "(root)"
                r.error("REC-SCHEMA", "§19.1", f"{at}: {e.message}", where)
        forbidden = FORBIDDEN_IN_SEMANTIC if record["kind"] == "visual-meta" \
            else FORBIDDEN_IN_INTERACTION | READER_STATE
        for found, at in walk_members(data, forbidden, skip_root=head_key):
            code = "REC-READER-STATE" if found in READER_STATE else "REC-SEPARATION"
            r.error(code, "§10.0, §15", f"member {found!r} at {at} is forbidden in this record", where)
        for at in walk_bibtex(data):
            if record["kind"] == "visual-meta" and at.endswith("/conventions"):
                continue
            r.error("REC-BIBTEX", "§11", f"a BibTeX string at {at}; BibTeX lives only in the bibliography record", where)
        if record["kind"] == "visual-meta" and isinstance(data.get("document"), dict):
            if "digest" in data["document"]:
                r.error("REC-DIGEST", "§13.2", "document.digest must not be present", where)
    # §4.4: a record nothing declares is undiscoverable by the profile's
    # own mechanism. Found by what it says it is, never by its name.
    declared = {rec["path"] for rec in pub.records if rec.get("declared")}
    for item in pub.manifest.values():
        path = item.get("path")
        if path in declared or item.get("media-type") not in ("application/json", "application/x-bibtex"):
            continue
        kind = pub._self_identified(path) if item.get("media-type") == "application/json" else None
        if kind:
            r.error("REC-UNDECLARED", "§4.4", f"{item.get('href')} is a {kind} record carried as a manifest "
                    "item with no <link rel=\"record\">", item.get("href"))
    for kind, records in kinds_seen.items():
        if len(records) > 1:
            r.warning("REC-DUPLICATE-KIND", "§4.4",
                      f"{len(records)} records declare kind {kind}; the first is read", records[1]["href"])


def load_schemas():
    try:
        from jsonschema import Draft202012Validator
    except ImportError:
        return None
    return {
        "visual-meta": Draft202012Validator(json.loads((HERE / "visual-meta-1.1.schema.json").read_text())),
        "origami-text": Draft202012Validator(json.loads((HERE / "origami-interaction-1.0.schema.json").read_text())),
    }


def walk_members(value, names, at="", skip_root=None):
    if isinstance(value, dict):
        for key, child in value.items():
            if at == "" and key == skip_root:
                continue
            here = f"{at}/{key}"
            if key in names:
                yield key, here
            yield from walk_members(child, names, here)
    elif isinstance(value, list):
        for i, child in enumerate(value):
            yield from walk_members(child, names, f"{at}/{i}")


def walk_bibtex(value, at=""):
    if isinstance(value, dict):
        for key, child in value.items():
            yield from walk_bibtex(child, f"{at}/{key}")
    elif isinstance(value, list):
        for i, child in enumerate(value):
            yield from walk_bibtex(child, f"{at}/{i}")
    elif isinstance(value, str) and BIBTEX_STRING.search(value):
        yield at


def check_manifest(pub, r):
    referenced = content_references(pub)
    exempt_models = {path for path, _, _ in model_carriers(pub)}
    for item in pub.manifest.values():
        path, media = item.get("path"), item.get("media-type", "")
        if path and not pub.c.exists(path):
            r.error("MAN-MISSING", "§4.5", f"manifest item {item.get('href')} is not in the container")
        foreign = media not in CORE_MEDIA_TYPES and not media.startswith("video/")
        used = path in pub.spine or path in referenced
        if foreign and used and not item.get("fallback") and media not in ("image/svg+xml",):
            r.error("MAN-FALLBACK", "§4.5, §18.1",
                    f"{item.get('href')} ({media}) is used in rendering and has no fallback")
        if path in pub.docs:
            root = pub.docs[path]
            has_math = any(True for _ in root.iter(MATH))
            if has_math and "mathml" not in item["properties-list"]:
                r.error("MAN-MATHML", "§4.5", f"{item.get('href')} contains MathML without properties=\"mathml\"")
            scripted = any(is_script(s) for s in root.iter(X + "script"))
            if scripted and "scripted" not in item["properties-list"]:
                r.error("MAN-SCRIPTED", "§4.5, §14", f"{item.get('href')} contains script without properties=\"scripted\"")
    del exempt_models


def is_script(element):
    kind = (element.get("type") or "").strip().lower()
    return kind in ("", "text/javascript", "application/javascript", "module", "application/ecmascript")


def content_references(pub):
    """Every resource a content document refers to, as container paths."""
    found = set()
    for path, root in pub.docs.items():
        for element in root.iter():
            for attr in ("href", "src", "data", "poster", "{http://www.w3.org/1999/xlink}href"):
                target, _ = resolve(path, element.get(attr))
                if target and target != path:
                    found.add(target)
    return found


def check_documents(pub, r):
    records = {rec["path"]: rec["href"] for rec in pub.records if rec.get("path")}
    for path, root in pub.docs.items():
        doc = pub.rel(path)
        seen = {}
        for element in root.iter():
            value = element.get("id")
            if value is not None:
                if value in seen:
                    r.error("ID-DUPLICATE", "§6.3, §18.1", f"id {value!r} appears twice", doc)
                seen[value] = True
                if not NCNAME.match(value):
                    r.error("ID-NCNAME", "§6.2, §18.1", f"id {value!r} is not an XML NCName", doc)
            if element.get("data-id") is not None:
                r.error("ID-DATA-ID", "§6.2", f"data-id={element.get('data-id')!r} must not be emitted", doc)
            if local(element.tag) == "model":
                r.error("DOC-MODEL-ELEMENT", "§14", "a <model> element is present", doc)
            for attr in ("data-bibtex", "data-csl-json"):
                if element.get(attr) is not None:
                    r.error("DOC-BIBTEX-ATTR", "§11", f"{attr} must not be present", doc)
            for attr in ("href", "src", "data"):
                target, _ = resolve(path, element.get(attr))
                if target in records:
                    r.error("REC-REFERENCED", "§4.4.1, §7.12",
                            f"<{local(element.tag)} {attr}> refers to record {records[target]}", doc)
            if "data-origami-address" in element.attrib and element.get("id") == element.get("data-origami-address"):
                r.error("ID-POSITIONAL", "§6.2", f"a positional address {element.get('id')!r} is used as the id", doc)
        # Stretchtext (§7.10)
        asides = {a.get("id"): a for a in root.iter(X + "aside") if "ot-stretchtext-content" in classes(a)}
        for aside in asides.values():
            if aside.get("hidden") is None:
                r.warning("ST-HIDDEN", "§7.10", f"stretchtext {aside.get('id')} is not hidden", doc)
            for inner in aside.iter(X + "aside"):
                if inner is not aside and "ot-stretchtext-content" in classes(inner):
                    r.error("ST-NESTED", "§7.10", f"stretchtext {inner.get('id')} is nested", doc)
        for marker in root.iter(X + "a"):
            if "ot-stretchtext" not in classes(marker):
                continue
            controls = marker.get("aria-controls")
            if controls not in asides:
                r.error("ST-TARGET", "§7.10", f"stretchtext marker controls {controls!r}, which is not a stretchtext aside", doc)
            if marker.get("aria-expanded") not in ("true", "false"):
                r.warning("ST-EXPANDED", "§7.10", "a stretchtext marker has no aria-expanded", doc)
        if not any(True for _ in root.iter(X + "body")):
            r.error("XHTML-BODY", "§7.1", "no <body>", doc)
        lang = root.get("{http://www.w3.org/XML/1998/namespace}lang") or root.get("lang")
        languages = [e["value"] for e in pub.dc.get("language", [])]
        if languages and lang and lang != languages[0]:
            r.warning("LANG-ROOT", "§5.5.1", f"root language {lang!r} differs from dc:language {languages[0]!r}", doc)


def check_references(pub, r):
    """§7.3–7.5 in the body, and every metadata reference against the
    addresses the content documents publish (§17.1 step 9)."""
    for path, root in pub.docs.items():
        doc = pub.rel(path)
        for a in root.iter(X + "a"):
            types, roles = tokens(a.get(EPUB_TYPE)), tokens(a.get("role"))
            for kind in ("biblioref", "glossref", "noteref"):
                if kind in types or f"doc-{kind}" in roles:
                    if kind != "noteref" and (kind not in types or f"doc-{kind}" not in roles):
                        r.error("REF-SEMANTICS", f"§7.{3 if kind == 'biblioref' else 4}",
                                f"a {kind} needs both epub:type=\"{kind}\" and role=\"doc-{kind}\"", doc)
                    target, fragment = resolve(path, a.get("href"))
                    if target is None or pub.find(target, fragment) is None:
                        r.error("REF-UNRESOLVED", "§18.1", f"{kind} href {a.get('href')!r} names no element", doc)
    v = pub.semantic if isinstance(pub.semantic, dict) else {}
    i = pub.interaction if isinstance(pub.interaction, dict) else {}

    def must(value, what, bare=True):
        if value is None:
            return
        path, fragment, element = pub.resolve_record_address(value, allow_bare=bare)
        if element is None:
            hint = "" if "#" in str(value) or pub.default_document else " (a bare fragment, and no document.defaultDocument)"
            r.error("META-UNRESOLVED", "§17.1, §18.1", f"{what} {value!r} resolves to no element{hint}")

    for h in (v.get("structure") or {}).get("headings", []) if isinstance(v.get("structure"), dict) else []:
        if isinstance(h, dict):
            must(h.get("href") or h.get("id"), "structure.headings[].href")
    for c in v.get("concepts", []) if isinstance(v.get("concepts"), list) else []:
        if isinstance(c, dict):
            must(c.get("href"), "concepts[].href")
    for c in v.get("citations", []) if isinstance(v.get("citations"), list) else []:
        if isinstance(c, dict):
            must(c.get("href"), "citations[].href")
    for kind in ("endnotes", "footnotes"):
        for n in v.get(kind, []) if isinstance(v.get(kind), list) else []:
            if isinstance(n, dict):
                must(n.get("href") or n.get("id"), f"{kind}[].href")
                must(n.get("anchor"), f"{kind}[].anchor")
    for e in v.get("equations", []) if isinstance(v.get("equations"), list) else []:
        if isinstance(e, dict):
            must(e.get("href") or e.get("id"), "equations[].href")
            must(e.get("section"), "equations[].section")
    for link in v.get("links", []) if isinstance(v.get("links"), list) else []:
        if isinstance(link, dict):
            must(link.get("fromAddress"), "links[].fromAddress")
    for entry in v.get("lineage", []) if isinstance(v.get("lineage"), list) else []:
        if isinstance(entry, dict):
            must(entry.get("id"), "lineage[].id")
    for s in i.get("stretchtext", []) if isinstance(i.get("stretchtext"), list) else []:
        if isinstance(s, dict):
            must(s.get("anchor"), "stretchtext[].anchor")
            if s.get("id") and not any(pub.find(p, s["id"]) is not None for p in pub.docs):
                r.error("META-UNRESOLVED", "§10.4", f"stretchtext id {s['id']!r} names no aside")
    check_map(pub, r, v, i)


def semantic_ids(v):
    ids = set()
    for member in ("concepts", "citations", "endnotes", "footnotes"):
        for entry in v.get(member, []) if isinstance(v.get(member), list) else []:
            if isinstance(entry, dict) and isinstance(entry.get("id"), str):
                ids.add(entry["id"])
    structure = v.get("structure") if isinstance(v.get("structure"), dict) else {}
    for h in structure.get("headings", []) or []:
        if isinstance(h, dict) and isinstance(h.get("id"), str):
            ids.add(h["id"])
    return ids


def check_map(pub, r, v, i):
    layout = i.get("map")
    if not isinstance(layout, dict):
        return
    known = semantic_ids(v)

    def resolves(ref):
        if not isinstance(ref, str):
            return False
        if ref in known:
            return True
        _, _, element = pub.resolve_record_address(ref, allow_bare=False)
        return element is not None

    for node in layout.get("nodes", []) or []:
        if isinstance(node, dict) and not resolves(node.get("id")):
            r.error("MAP-UNRESOLVED", "§10.3", f"map node {node.get('id')!r} names nothing in the publication")
    for view in layout.get("views", []) or []:
        for node in (view.get("nodes", []) if isinstance(view, dict) else []) or []:
            if isinstance(node, dict) and not resolves(node.get("ref")):
                r.error("MAP-UNRESOLVED", "§10.3", f"map ref {node.get('ref')!r} names nothing in the publication")
    for connection in layout.get("connections", []) or []:
        if isinstance(connection, dict):
            for end in ("from", "to"):
                if not resolves(connection.get(end)):
                    r.error("MAP-UNRESOLVED", "§10.3", f"map connection {end} {connection.get(end)!r} names nothing")


def model_carriers(pub):
    for path, root in pub.docs.items():
        for element in root.iter():
            if element.get("data-model-src") is not None:
                yield path, element, pub.parents[path]


def check_models(pub, r, budget):
    i = pub.interaction if isinstance(pub.interaction, dict) else {}
    entries = {m.get("id"): m for m in i.get("models", []) or [] if isinstance(m, dict)}
    seen = set()
    model_paths = set()
    for path, carrier, parents in model_carriers(pub):
        doc = pub.rel(path)
        mid = carrier.get("data-model-id")
        where = f"{doc} [data-model-id={mid}]"
        for attr in REQUIRED_MODEL_ATTRIBUTES:
            if carrier.get(attr) is None:
                r.error("M3D-ATTRIBUTE", "§7.9.2", f"{attr} is required", where)
        if local(carrier.tag) == "a" or carrier.get("href") is not None:
            r.error("M3D-HYPERLINK", "§7.9", "the carrier is a hyperlink to the model (EPUBCheck RSC-010)", where)
        up = carrier.get("data-model-up")
        if up is not None and up not in ("Y", "Z"):
            r.error("M3D-UP", "§7.9.2", f"data-model-up is {up!r}, not Y or Z", where)
        units, extent = carrier.get("data-model-units"), carrier.get("data-model-extent")
        if (units is None) != (extent is None):
            r.error("M3D-UNITS-EXTENT", "§7.9.4", "data-model-units and data-model-extent must appear together", where)
        if units is not None and units != "m":
            r.error("M3D-UNITS", "§7.9.2", f"data-model-units is {units!r}, not m", where)
        parsed_extent = None
        if extent is not None:
            try:
                parsed_extent = [float(x) for x in extent.split()]
                if len(parsed_extent) != 3:
                    raise ValueError
            except ValueError:
                r.error("M3D-EXTENT", "§7.9.4", f"data-model-extent {extent!r} is not three numbers", where)
                parsed_extent = None
        media = carrier.get("data-model-media-type")
        if media is not None and media not in MODEL_MEDIA_TYPES:
            r.error("M3D-MEDIA-TYPE", "§7.9.3", f"{media!r} is not a registered model media type", where)
        src, _ = resolve(path, carrier.get("data-model-src"))
        if src is not None:
            model_paths.add(src)
            if not pub.c.exists(src) or src not in pub.by_path:
                r.error("M3D-MISSING", "§18.1", f"data-model-src {carrier.get('data-model-src')!r} names no manifested resource", where)
            else:
                manifest_type = pub.by_path[src].get("media-type")
                if media and manifest_type != media:
                    r.warning("M3D-MEDIA-DISAGREE", "§12.4", f"carrier says {media}, manifest says {manifest_type}", where)
                stated = carrier.get("data-model-bytes")
                if stated is not None and stated.isdigit() and int(stated) != pub.c.size(src):
                    r.warning("M3D-BYTES", "§7.9.2", f"data-model-bytes {stated} but the file is {pub.c.size(src)} bytes", where)
                if (pub.c.size(src) or 0) > budget and not carrier.get("data-model-source"):
                    r.warning("M3D-BUDGET", "§18.2", f"model exceeds {budget} bytes and has no data-model-source", where)
        figure = parents.get(carrier)
        while figure is not None and local(figure.tag) != "figure":
            figure = parents.get(figure)
        if figure is not None and mid:
            fig_tail, model_tail = UUID_TAIL.search(figure.get("id") or ""), UUID_TAIL.search(mid)
            if fig_tail and model_tail and fig_tail.group(1) != model_tail.group(1):
                r.warning("M3D-HANDLE", "§7.9.2", "the figure's P- id and the M- handle carry different UUIDs", where)
        if local(carrier.tag) == "img" and (carrier.get("alt") or "") == "" and figure is not None \
                and figure.find(X + "figcaption") is not None and text_of(figure.find(X + "figcaption")) == "":
            r.error("M3D-EMPTY-CAPTION", "§7.9.6", "an empty <figcaption>; with no description there is none", where)
        entry = entries.get(mid)
        if mid:
            seen.add(mid)
        if entry:
            if entry.get("up") is not None and entry.get("up") != up:
                r.warning("M3D-DISAGREE", "§18.2", f"models[].up {entry.get('up')!r} differs from the carrier's {up!r}", where)
            if entry.get("extent") is not None or parsed_extent is not None:
                if not floats_agree(entry.get("extent"), parsed_extent):
                    r.warning("M3D-DISAGREE", "§18.2", "models[].extent differs from data-model-extent", where)
            if ("units" in entry) != ("extent" in entry):
                r.error("M3D-UNITS-EXTENT", "§10.5", "models[] has units or extent without the other", where)
    for mid, entry in entries.items():
        if mid not in seen:
            r.error("META-UNRESOLVED", "§18.1", f"models[] entry {mid!r} has no carrier in the body")
        poster, _ = pub.from_package(entry.get("poster")) if isinstance(entry.get("poster"), str) else (None, None)
        if poster is not None and not pub.c.exists(poster):
            # The carrier governs (§12.4), and its poster is what renders;
            # a convenience copy naming a missing file is a disagreement.
            r.warning("M3D-POSTER-MISSING", "§10.5, §12.4", f"models[] {mid!r} names poster {entry['poster']!r}, which is not in the package")
    for path, root in pub.docs.items():
        for element in root.iter():
            for attr in ("href", "src"):
                target, _ = resolve(path, element.get(attr))
                if target in model_paths:
                    r.error("M3D-REFERENCED", "§7.9", f"<{local(element.tag)} {attr}> refers to a model file (EPUBCheck RSC-010)", pub.rel(path))


def floats_agree(a, b):
    if not isinstance(a, list) or not isinstance(b, list) or len(a) != len(b):
        return False
    try:
        return all(abs(float(x) - float(y)) <= 1e-9 + 5e-4 * abs(float(y)) for x, y in zip(a, b))
    except (TypeError, ValueError):
        return False


def table_values(table):
    rows = []
    for tr in table.iter(X + "tr"):
        rows.append([text_of(cell) for cell in tr if local(cell.tag) in ("td", "th")])
    return rows


def check_tables(pub, r):
    i = pub.interaction if isinstance(pub.interaction, dict) else {}
    for entry in i.get("tables", []) or []:
        if not isinstance(entry, dict):
            continue
        path, fragment, element = pub.resolve_record_address(entry.get("href"), allow_bare=False)
        if element is None:
            r.error("META-UNRESOLVED", "§10.2, §18.1", f"tables[].href {entry.get('href')!r} resolves to no element")
            continue
        table = element if local(element.tag) == "table" else element.find(".//" + X + "table")
        if table is None:
            r.error("TABLE-TARGET", "§7.6", f"tables[].href {entry.get('href')!r} is not a table")
            continue
        key = table.get("data-table-id") or table.get("id")
        if entry.get("identifier") not in (key, table.get("id")):
            r.error("TABLE-ID", "§7.6, §10.2", f"tables[].identifier {entry.get('identifier')!r} is not the table's data-table-id {key!r}")
        presented = table_values(table)
        cells = entry.get("cells") or []
        recorded = [[str((c or {}).get("value", "")) for c in row] for row in cells if isinstance(row, list)]
        if recorded and [[" ".join(v.split()) for v in row] for row in recorded] != presented:
            r.warning("TABLE-DISAGREE", "§7.6, §12.3", f"table {entry.get('identifier')}: cells[].value differs from the XHTML")
        for row in cells:
            for cell in row if isinstance(row, list) else []:
                formula = (cell or {}).get("formula") if isinstance(cell, dict) else None
                if isinstance(formula, str) and re.search(r"[!\[\]]|https?:|\.xhtml|\.html", formula):
                    r.error("TABLE-FORMULA", "§10.2", f"formula {formula!r} reaches outside its table")


def check_equations(pub, r):
    v = pub.semantic if isinstance(pub.semantic, dict) else {}
    for entry in v.get("equations", []) or []:
        if not isinstance(entry, dict):
            continue
        _, _, element = pub.resolve_record_address(entry.get("href") or entry.get("id"))
        if element is not None and element.tag != MATH:
            r.warning("EQ-TARGET", "§7.7.1", f"equations[] {entry.get('id')!r} addresses a <{local(element.tag)}>, not <math>")
        tex, digest = entry.get("tex"), entry.get("tex-sha256")
        if isinstance(tex, str) and isinstance(digest, str) and \
                hashlib.sha256(tex.encode("utf-8")).hexdigest() != digest.lower():
            r.warning("EQ-CHECKSUM", "§7.7.1", f"equations[] {entry.get('id')!r}: tex-sha256 does not match tex; the MathML governs")


def glossary_entries(pub):
    """(path, dt, dd) for every glossary entry in the body (§8.1)."""
    for path, root in pub.docs.items():
        for section in root.iter():
            if "glossary" in tokens(section.get(EPUB_TYPE)) or "doc-glossary" in tokens(section.get("role")):
                for dl in section.iter(X + "dl"):
                    children = list(dl)
                    for k, child in enumerate(children):
                        if local(child.tag) == "dt":
                            dd = next((c for c in children[k + 1:] if local(c.tag) == "dd"), None)
                            yield path, child, dd


def strip_prefix(fragment, prefix):
    return fragment[len(prefix):] if fragment and fragment.startswith(prefix) else fragment


def check_glossary(pub, r):
    v = pub.semantic if isinstance(pub.semantic, dict) else {}
    for concept in v.get("concepts", []) or []:
        if not isinstance(concept, dict) or not concept.get("href"):
            continue
        path, fragment, element = pub.resolve_record_address(concept["href"])
        if element is None:
            continue
        if concept.get("id") not in (fragment, strip_prefix(fragment, "gloss-")):
            r.error("GLOSS-ID", "§9.4", f"concept id {concept.get('id')!r} is not the identifier in its address {fragment!r}")
        if local(element.tag) == "dt":
            dd = None
            siblings = list(pub.parents[path].get(element, []))
            for k, child in enumerate(siblings):
                if child is element:
                    dd = next((c for c in siblings[k + 1:] if local(c.tag) == "dd"), None)
            if isinstance(concept.get("name"), str) and concept["name"].strip() != text_of(element):
                r.warning("GLOSS-DISAGREE", "§18.2", f"concept {concept.get('id')}: name differs from the glossary term")
            if dd is not None and isinstance(concept.get("description"), str) and \
                    " ".join(concept["description"].split()) != text_of(dd):
                r.warning("GLOSS-DISAGREE", "§18.2", f"concept {concept.get('id')}: description differs from the glossary definition")


def citation_key(fragment):
    """The citation's key from its bibliography entry's fragment: the
    fragment without a leading `bib-` (§7.3)."""
    return strip_prefix(fragment, "bib-")


# §9.5: a citation entry's own members. They are never mirrored BibTeX
# fields, even where BibTeX has a field of the same name (`number`).
CITATION_OWN_MEMBERS = {"id", "number", "href", "concepts", "lang", "alternate"}


def check_citations(pub, r):
    v = pub.semantic if isinstance(pub.semantic, dict) else {}
    have_bib = pub.bibliography is not None
    for path, root in pub.docs.items():
        for a in root.iter(X + "a"):
            if "biblioref" not in tokens(a.get(EPUB_TYPE)):
                continue
            target, fragment = resolve(path, a.get("href"))
            element = pub.find(target, fragment)
            if element is None:
                continue
            if not pub.in_section(target, element, "bibliography"):
                r.warning("CITE-TARGET", "§7.3", f"biblioref {a.get('href')!r} does not point into a bibliography section", pub.rel(path))
            key = citation_key(fragment)
            if have_bib and key not in pub.bib_by_key and fragment not in pub.bib_by_key:
                r.error("CITE-NO-RECORD", "§18.1", f"citation key {key!r} has no entry in the bibliography record", pub.rel(path))
    for citation in v.get("citations", []) or []:
        if not isinstance(citation, dict):
            continue
        key = citation.get("id")
        if have_bib and key not in pub.bib_by_key:
            r.error("CITE-NO-RECORD", "§9.5, §18.1", f"citations[].id {key!r} has no entry in the bibliography record")
            continue
        if citation.get("href"):
            _, fragment, _ = pub.resolve_record_address(citation["href"])
            if fragment is not None and key not in (fragment, citation_key(fragment)):
                r.error("CITE-KEY", "§7.3, §11", f"citations[].id {key!r} is not the key in its address {fragment!r}")
        entry = pub.bib_by_key.get(key)
        if entry:
            for name, value in citation.items():
                if name in CITATION_OWN_MEMBERS:
                    continue
                if name in entry["fields"] and isinstance(value, (str, int, float)):
                    if bib_plain(value) != bib_plain(entry["fields"][name]):
                        r.warning("CITE-FIELD-DISAGREE", "§11, §18.2", f"citation {key}: {name} differs from its BibTeX entry")


def content_headings(pub):
    out = []
    for path in pub.spine:
        root = pub.docs.get(path)
        if root is None:
            continue
        for element in root.iter():
            if local(element.tag) in ("h1", "h2", "h3", "h4", "h5", "h6") and element.tag.startswith(X):
                if pub.in_section(path, element, "colophon") or \
                        element.get("id") is None:
                    continue
                out.append({"address": pub.address(path, element.get("id")),
                            "level": int(local(element.tag)[1]), "text": text_of(element)})
    return out


def check_headings(pub, r):
    v = pub.semantic if isinstance(pub.semantic, dict) else {}
    structure = v.get("structure") if isinstance(v.get("structure"), dict) else None
    if not structure or not isinstance(structure.get("headings"), list):
        return
    body = {h["address"]: h for h in content_headings(pub)}
    offsets = set()
    for h in structure["headings"]:
        if not isinstance(h, dict):
            continue
        path, fragment, element = pub.resolve_record_address(h.get("href") or h.get("id"))
        if element is None:
            continue
        actual = body.get(pub.address(path, fragment))
        if actual is None:
            r.warning("HEAD-DISAGREE", "§9.3, §18.2", f"structure.headings {fragment!r} is not a heading in the body")
            continue
        if " ".join(str(h.get("text", "")).split()) != actual["text"]:
            r.warning("HEAD-DISAGREE", "§9.3, §18.2", f"structure.headings {fragment!r}: text differs from the body's heading")
        if isinstance(h.get("level"), int):
            offsets.add(actual["level"] - h["level"])
    # §9.3: level is the rank less one constant for the whole record.
    if len(offsets) > 1 or any(o < 0 for o in offsets):
        r.warning("HEAD-LEVELS", "§9.3, §18.2",
                  "structure.headings levels are not the body's heading ranks less one constant")


def value_text(value):
    if isinstance(value, dict):
        return value.get("value")
    return value


def check_front_matter(pub, r):
    v = pub.semantic if isinstance(pub.semantic, dict) else {}
    document = v.get("document") if isinstance(v.get("document"), dict) else {}
    creators = [e["value"] for e in pub.dc.get("creator", [])]
    for name in creators:
        if joined(name):
            r.warning("FM-JOINED-AUTHORS", "§5.2, §18.2", f"dc:creator {name!r} looks like several names in one")
    authors = document.get("authors") if isinstance(document.get("authors"), list) else []
    names = [value_text(a.get("name")) if isinstance(a, dict) else a for a in authors]
    for name in names:
        if isinstance(name, str) and joined(name):
            r.warning("FM-JOINED-AUTHORS", "§5.2, §18.2", f"author {name!r} looks like several names in one")
    if names and creators and [str(n) for n in names] != creators:
        r.warning("FM-AUTHORS-DISAGREE", "§12.4, §18.2", "dc:creator and document.authors[].name differ")
    title = [e["value"] for e in pub.dc.get("title", [])]
    if title and value_text(document.get("title")) not in (None, title[0]):
        r.warning("FM-TITLE-DISAGREE", "§18.2", "dc:title and document.title differ")
    dois = [e["value"] for e in pub.dc.get("identifier", []) if e["value"].startswith("10.")]
    if document.get("doi") and dois and document["doi"] not in dois:
        r.warning("FM-DOI-DISAGREE", "§18.2", "the package DOI and document.doi differ")
    if pub.edition and document.get("identifier") not in (None, pub.edition):
        r.warning("ID-DISAGREE", "§12.4", "document.identifier differs from dc:identifier")
    works = pub.meta.get("dcterms:isVersionOf", [])
    if works and document.get("work") not in (None, works[0]):
        r.warning("ID-DISAGREE", "§12.4", "document.work differs from dcterms:isVersionOf")
    modified = pub.meta.get("dcterms:modified", [])
    if modified and document.get("modified") not in (None, modified[0]):
        r.warning("ID-DISAGREE", "§12.4", "document.modified differs from dcterms:modified")
    languages = [e["value"] for e in pub.dc.get("language", [])]
    if languages and document.get("language") not in (None, languages[0]):
        r.warning("LANG-DISAGREE", "§5.5.1", "document.language differs from dc:language")
    for path, root in pub.docs.items():
        for p in root.iter(X + "p"):
            text = text_of(p)
            if re.match(r"^(CCS Concepts|Keywords)\s*:", text) and not pub.in_section(path, p, "colophon"):
                r.warning("FM-BODY-TEXT", "§5.3, §18.2", f"{text.split(':')[0]} carried as body text", pub.rel(path))


def joined(name):
    return bool(re.search(r"\s(and|&)\s|;", name)) or name.count(",") >= 2


def check_embedded(pub, r):
    """§12.2: an embedded copy of a record must be canonically identical."""
    by_href = {rec["path"]: rec for rec in pub.records if rec.get("path")}
    for path, root in pub.docs.items():
        for script in root.iter(X + "script"):
            if script.get("id") == "origami-metadata-discovery":
                try:
                    data = json.loads("".join(script.itertext()))
                except json.JSONDecodeError:
                    r.warning("DISCOVERY-JSON", "§7.12", "the discovery record is not JSON", pub.rel(path))
                    continue
                extra = set(data) - {"format", "profile", "metadata"} if isinstance(data, dict) else set()
                if extra:
                    r.warning("DISCOVERY-GRAPH", "§7.12", f"the discovery record carries {sorted(extra)}; pointers only", pub.rel(path))
                for pointer in (data.get("metadata") or []) if isinstance(data, dict) else []:
                    target, _ = pub.from_package(pointer.get("href") if isinstance(pointer, dict) else None)
                    if target not in by_href:
                        r.warning("DISCOVERY-POINTER", "§7.12", f"discovery points at {pointer!r}, not a declared record", pub.rel(path))
                continue
            derived = script.get("data-origami-derived-from")
            if script.get("id") != "visual-meta-payload" and derived is None:
                continue
            try:
                copy = json.loads("".join(script.itertext()))
            except json.JSONDecodeError:
                r.error("EMBED-JSON", "§12.2", "the embedded record is not JSON", pub.rel(path))
                continue
            source = None
            if derived:
                target, _ = pub.from_package(derived)
                source = by_href.get(target)
            if source is None:
                source = next((rec for rec in pub.records if rec["kind"] == "visual-meta"), None)
            if source is None or source.get("data") is None:
                r.warning("EMBED-ORPHAN", "§12.2", "an embedded record copy has no declared record to match", pub.rel(path))
                continue
            if canonical_hash(copy) != canonical_hash(source["data"]):
                r.error("EMBED-HASH", "§12.2, §18.1",
                        f"the embedded copy differs canonically from {source['href']}", pub.rel(path))


def colophons(pub):
    for path, root in pub.docs.items():
        for section in root.iter():
            if "colophon" in tokens(section.get(EPUB_TYPE)) and local(section.tag) == "section":
                yield path, section


def check_colophon(pub, r):
    found = list(colophons(pub))
    if not found:
        r.warning("COLOPHON-NONE", "§8.4, §18.2", "no epub:type=\"colophon\" section")
        return
    records = {rec["path"]: rec for rec in pub.records if rec.get("path") and rec["kind"]}
    for path, section in found:
        doc = pub.rel(path)
        children = list(section.iter())
        pres = [e for e in children if local(e.tag) == "pre"]
        statement = None
        for e in children:
            if local(e.tag) == "pre":
                break
            if local(e.tag) == "p" and text_of(e):
                statement = e
                break
        if statement is None:
            r.error("COLOPHON-STATEMENT", "§8.4.1", "the colophon has no explanatory statement before its BibTeX", doc)
        if not pres:
            r.error("COLOPHON-BIBTEX", "§8.4.2", "the colophon has no <pre> BibTeX self-citation", doc)
        selfcite = None
        for pre in pres[:1]:
            try:
                entries = parse_bibtex("".join(pre.itertext()))
                if len(entries) != 1:
                    raise BibTeXError(f"{len(entries)} entries, not one")
                selfcite = entries[0]
            except BibTeXError as e:
                r.error("COLOPHON-BIBTEX", "§8.4.2", f"the self-citation does not parse: {e}", doc)
        if selfcite:
            for name, value in selfcite["fields"].items():
                if bib_plain(value) == "":
                    r.warning("COLOPHON-EMPTY-FIELD", "§8.4.2", f"self-citation field {name} is empty", doc)
            dois = [e["value"] for e in pub.dc.get("identifier", []) if e["value"].startswith("10.")]
            if "doi" in selfcite["fields"] and dois and bib_plain(selfcite["fields"]["doi"]) not in dois:
                r.warning("COLOPHON-IDENTITY", "§8.4.2", "the self-citation's DOI is not the publication's", doc)
        stated = []
        for code in section.iter(X + "code"):
            text = text_of(code)
            if RECORD_PATH.search(text) and " " not in text:
                stated.append(text)
        if not stated:
            r.error("COLOPHON-PATHS", "§8.4.3", "the colophon states no record path", doc)
        named = set()
        for text in stated:
            if text.startswith("META-INF/") or "/META-INF/" in text:
                r.error("COLOPHON-META-INF", "§8.4.3", f"the colophon names {text!r} in META-INF/", doc)
            candidates = {posixpath.normpath(posixpath.join(pub.package_dir, text)), posixpath.normpath(text)}
            hit = candidates & set(records)
            if not hit:
                r.error("COLOPHON-PATH-UNRESOLVED", "§8.4.3, §18.1", f"the colophon states {text!r}, which is no declared record", doc)
            named |= hit
        for missing in sorted(set(records) - named):
            r.warning("COLOPHON-PATH-MISSING", "§8.4.3", f"the colophon does not mention record {records[missing]['href']}", doc)
        rights = [e["value"] for e in pub.dc.get("rights", [])]
        licenses = pub.meta.get("dcterms:license", [])
        prose = text_of(section)
        hrefs = {a.get("href") for a in section.iter(X + "a")}
        for value in rights:
            if " ".join(value.split()) not in prose:
                r.warning("COLOPHON-RIGHTS", "§8.4.4, §18.2", "the colophon does not state dc:rights as the package does", doc)
        for value in licenses:
            if value not in hrefs and value not in prose:
                r.warning("COLOPHON-RIGHTS", "§8.4.4, §18.2", "the colophon does not name the dcterms:license URI", doc)


# ---------------------------------------------------------------------------
# Extraction (§20.1)

def extract(pub):
    report = Report()
    pub.r = report
    out = {"extraction": EXTRACTION_VERSION}
    if not pub.load():
        out["mode"] = "unreadable"
        return out
    if pub.profile is None:
        mode = "pre-1.0"
    elif pub.major != IMPLEMENTED_MAJOR:
        mode = "ordinary-epub"
    else:
        mode = "profile"
    out["mode"] = mode
    out["profile"] = pub.profile
    if mode == "ordinary-epub":
        out["notice"] = f"newer profile {pub.major}.{pub.minor}; read as an ordinary EPUB"
    out["identity"] = {
        "edition": pub.edition,
        "work": first(pub.meta.get("dcterms:isVersionOf")),
        "modified": first(pub.meta.get("dcterms:modified")),
        "release": first(pub.meta.get("schema:version")),
        "replaces": [l.get("href") for l in pub.links if "dcterms:replaces" in tokens(l.get("rel"))]
        + pub.meta.get("dcterms:replaces", []),
        "isReplacedBy": [l.get("href") for l in pub.links if "dcterms:isReplacedBy" in tokens(l.get("rel"))]
        + pub.meta.get("dcterms:isReplacedBy", []),
    }
    out["documents"] = [pub.rel(p) for p in pub.spine if p in pub.docs]
    out["elements"] = [pub.address(p, e.get("id")) for p, e in pub.elements_with_ids()]
    out["headings"] = content_headings(pub)
    if mode == "ordinary-epub":
        out["metadata"] = package_metadata(pub, {})
        return out
    out["unresolved"] = []
    out["disagreements"] = []

    pub.load_records(mode)
    trusted = {}
    out["records"] = []
    for record in pub.records:
        entry = {"kind": record["kind"], "href": record["href"],
                 "declared": bool(record.get("declared"))}
        if record["kind"] in ("visual-meta", "interaction") and record.get("data") is not None:
            head = record["data"].get("visual-meta" if record["kind"] == "visual-meta" else "origami") \
                if isinstance(record["data"], dict) else None
            entry["trusted"] = isinstance(head, dict) and (mode == "pre-1.0" and head.get("describes") is None
                                                           or head.get("describes") == pub.edition)
            trusted[record["kind"]] = entry["trusted"] or mode == "pre-1.0" and not isinstance(head, dict)
        if record["kind"] is None:
            entry["ignored"] = True
        out["records"].append(entry)
    v = pub.semantic if isinstance(pub.semantic, dict) and trusted.get("visual-meta", True) else {}
    i = pub.interaction if isinstance(pub.interaction, dict) and trusted.get("interaction", True) else {}
    if pub.semantic is not None and not v:
        out["disagreements"].append("the semantic record does not describe this publication; not used")
    if pub.interaction is not None and not i:
        out["disagreements"].append("the interaction record does not describe this publication; not used")
    sources = {}
    out["metadata"] = package_metadata(pub, v.get("document") if isinstance(v.get("document"), dict) else {})
    out["frontMatter"] = front_matter(pub, v, mode)
    out["concepts"] = extract_concepts(pub, v, i, sources, out)
    out["citations"] = extract_citations(pub, v, i, sources, out)
    out["bibliography"] = extract_bibliography(pub, v, i, sources)
    out["endnotes"] = extract_notes(pub, v, i, sources, out)
    out["equations"] = extract_equations(pub, v, sources, mode)
    out["tables"] = extract_tables(pub, v, i, sources, out)
    out["models"] = extract_models(pub, i, out)
    out["layouts"] = extract_layouts(pub, v, pick(i.get("map"), v.get("map"), sources, "layouts",
                                                  "interaction.map", "semantic.map"), out)
    out["links"] = [l for l in (v.get("links") or []) if isinstance(l, dict)]
    out["lineage"] = [{"claim": True, **l} for l in (v.get("lineage") or []) if isinstance(l, dict)]
    out["stretchtext"] = extract_stretchtext(pub)
    out["colophon"] = extract_colophon(pub)
    sources["headings"] = "content"
    out["sources"] = dict(sorted(sources.items()))
    for item in report.errors:
        if item["code"] in ("BIB-PARSE", "RECORD-JSON"):
            out["disagreements"].append(item["message"])
    return out


def first(values):
    return values[0] if values else None


def nonempty(value):
    return value not in (None, "", [], {})


def pick(first_value, second_value, sources, fact, first_name, second_name):
    """§17.3: one source, the first that yields anything; never a merge."""
    if nonempty(first_value):
        sources[fact] = first_name
        return first_value
    if nonempty(second_value):
        sources[fact] = second_name
        return second_value
    sources[fact] = None
    return None


def package_metadata(pub, document):
    rights = [e["value"] for e in pub.dc.get("rights", [])]
    licenses = [l for l in pub.meta.get("dcterms:license", []) if URI.match(l)]
    record_license = document.get("license") if isinstance(document, dict) else None
    if not rights and isinstance(document.get("rights"), str):
        rights = [document["rights"]]
    if isinstance(record_license, str):
        if not URI.match(record_license):
            # §4.7.2: a prose licence is the rights statement, never a licence id.
            if not rights:
                rights = [record_license]
        elif not licenses:
            licenses = [record_license]
    return {
        "title": first([e["value"] for e in pub.dc.get("title", [])]),
        "language": first([e["value"] for e in pub.dc.get("language", [])]),
        "creators": [e["value"] for e in pub.dc.get("creator", [])],
        "identifiers": [e["value"] for e in pub.dc.get("identifier", [])],
        "isPartOf": pub.meta.get("dcterms:isPartOf", []),
        "subjects": [e["value"] for e in pub.dc.get("subject", [])],
        "rights": first(rights),
        "license": first(licenses),
        "rightsHolder": first(pub.meta.get("dcterms:rightsHolder")) or document.get("rightsHolder"),
        "accessRights": first(pub.meta.get("dcterms:accessRights")) or document.get("accessRights"),
        "attributionName": first(pub.meta.get("cc:attributionName")),
        "attributionURL": first(pub.meta.get("cc:attributionURL")),
    }


def language_value(value, default):
    if isinstance(value, dict) and "value" in value:
        out = {"value": value.get("value"), "lang": value.get("lang") or default}
        if value.get("alternate"):
            out["alternate"] = value["alternate"]
        return out
    if isinstance(value, str):
        return {"value": value, "lang": default}
    return None


def front_matter(pub, v, mode):
    document = v.get("document") if isinstance(v.get("document"), dict) else {}
    default = document.get("language") or first([e["value"] for e in pub.dc.get("language", [])])
    authors = []
    raw = document.get("authors") if isinstance(document.get("authors"), list) else []
    affiliations = document.get("author-affiliations") or {}
    emails = document.get("author-emails") or {}
    orcids = document.get("author-orcids") or {}
    for author in raw:
        if isinstance(author, dict):
            entry = {"name": language_value(author.get("name"), default)}
            for key in ("affiliation", "email", "orcid"):
                if author.get(key):
                    entry[key] = author[key]
            authors.append(entry)
        elif isinstance(author, str):
            # §5.2 compatibility: strings, with name-keyed dictionaries beside them.
            for name in split_joined(author) if mode == "pre-1.0" else [author]:
                entry = {"name": {"value": name, "lang": default}}
                for key, table in (("affiliation", affiliations), ("email", emails), ("orcid", orcids)):
                    if isinstance(table, dict) and table.get(name):
                        entry[key] = table[name]
                authors.append(entry)
    if not authors:
        authors = [{"name": {"value": c, "lang": default}} for c in [e["value"] for e in pub.dc.get("creator", [])]]
    out = {"authors": authors}
    for key in ("title", "subtitle", "abstract", "publication", "journal"):
        value = language_value(document.get(key), default)
        if value is not None:
            out[key] = value
    for key in ("doi", "isbn", "keywords", "ccsConcepts", "acmReference"):
        if nonempty(document.get(key)):
            out[key] = document[key]
    if mode == "pre-1.0":
        for path, root in pub.docs.items():
            for p in root.iter(X + "p"):
                text = text_of(p)
                m = re.match(r"^(CCS Concepts|Keywords)\s*:\s*(.*)$", text)
                if m:
                    key = "ccsConcepts" if m.group(1) == "CCS Concepts" else "keywords"
                    if key not in out:
                        sep = ";" if key == "ccsConcepts" else r"[;,]"
                        out[key] = [t.strip().rstrip(".") for t in re.split(sep, m.group(2)) if t.strip()]
    return out


def split_joined(name):
    parts = re.split(r",\s*and\s+|\s+and\s+|\s*&\s*|;\s*|,\s*(?=[A-Z][^,]*\s[A-Z])", name)
    return [p.strip() for p in parts if p.strip()]


def extract_concepts(pub, v, i, sources, out):
    body = {}
    for path, dt, dd in glossary_entries(pub):
        if dt.get("id"):
            body[pub.address(path, dt.get("id"))] = (text_of(dt), text_of(dd) if dd is not None else None)
    chosen = pick(v.get("concepts"), i.get("glossary"), sources, "concepts",
                  "semantic.concepts", "interaction.glossary")
    result = []
    for concept in chosen or []:
        if not isinstance(concept, dict):
            continue
        href = concept.get("href")
        path, fragment, element = pub.resolve_record_address(href) if href else (None, None, None)
        if element is None and concept.get("id"):
            for candidate in (f"gloss-{concept['id']}", concept["id"]):
                hit = next(((p, candidate) for p in pub.docs if pub.find(p, candidate) is not None), None)
                if hit:
                    path, fragment = hit
                    element = pub.find(*hit)
                    break
        address = pub.address(path, fragment) if element is not None else None
        if href and element is None:
            out["unresolved"].append({"from": "concepts", "ref": href})
        term, definition = body.get(address, (None, None)) if address else (None, None)
        name = concept.get("name") if isinstance(concept.get("name"), str) else value_text(concept.get("name"))
        if term is not None and name is not None and term != " ".join(str(name).split()):
            out["disagreements"].append(f"concept {concept.get('id')}: name differs from the glossary; the glossary governs")
        result.append({
            "id": concept.get("id"), "address": address,
            "term": term if term is not None else name,
            "definition": definition if definition is not None else concept.get("description"),
            "tag": concept.get("tag"),
            "citations": concept.get("citationIdentifiers") or [],
        })
    if not result and body:
        sources["concepts"] = "content"
        for address, (term, definition) in body.items():
            fragment = address.split("#", 1)[1]
            result.append({"id": strip_prefix(fragment, "gloss-"), "address": address, "term": term,
                           "definition": definition, "tag": None, "citations": []})
    return result


def biblioref_placements(pub):
    placements = {}
    for path in pub.spine:
        root = pub.docs.get(path)
        if root is None:
            continue
        for a in root.iter(X + "a"):
            if "biblioref" not in tokens(a.get(EPUB_TYPE)) and "doc-biblioref" not in tokens(a.get("role")):
                continue
            target, fragment = resolve(path, a.get("href"))
            if target is None or fragment is None:
                continue
            key = pub.address(target, fragment)
            holder = pub.nearest_id(path, a)
            where = pub.address(path, holder) if holder else pub.rel(path)
            placements.setdefault(key, [])
            if where not in placements[key]:
                placements[key].append(where)
    return placements


def extract_citations(pub, v, i, sources, out):
    placements = biblioref_placements(pub)
    chosen = pick(v.get("citations"), i.get("references"), sources, "citations",
                  "semantic.citations", "interaction.references")
    result = []
    for citation in chosen or []:
        if not isinstance(citation, dict):
            continue
        key = citation.get("id") or citation.get("key")
        href = citation.get("href")
        path, fragment, element = pub.resolve_record_address(href) if href else (None, None, None)
        if element is None and key:
            for candidate in (f"bib-{key}", key):
                hit = next(((p, candidate) for p in pub.docs if pub.find(p, candidate) is not None), None)
                if hit:
                    path, fragment = hit
                    element = pub.find(*hit)
                    break
        address = pub.address(path, fragment) if element is not None else None
        if href and element is None:
            out["unresolved"].append({"from": "citations", "ref": href})
        entry = {"key": key, "number": citation.get("number"), "address": address,
                 "citedFrom": placements.get(address, []),
                 "concepts": citation.get("concepts") or []}
        for member in ("lang", "alternate"):
            if citation.get(member):
                entry[member] = citation[member]
        result.append(entry)
    if not result and placements:
        sources["citations"] = "content"
        for address, where in placements.items():
            fragment = address.split("#", 1)[1]
            result.append({"key": citation_key(fragment), "number": None, "address": address,
                           "citedFrom": where, "concepts": []})
    return result


def extract_bibliography(pub, v, i, sources):
    if pub.bibliography:
        sources["bibliography"] = "bibliography"
        return [{"key": e["key"], "type": e["type"],
                 "fields": {k: bib_plain(val) for k, val in e["fields"].items()}}
                for e in pub.bibliography]
    mirrored = []
    for citation in v.get("citations") or []:
        if isinstance(citation, dict):
            fields = {k: bib_plain(val) for k, val in citation.items()
                      if k not in CITATION_OWN_MEMBERS | {"bibtex", "csl"}
                      and isinstance(val, (str, int, float))}
            if fields:
                mirrored.append({"key": citation.get("id"), "type": None, "fields": fields})
    if mirrored:
        sources["bibliography"] = "semantic.citations"
        return mirrored
    embedded = []
    for container in (v.get("citations") or [], i.get("references") or []):
        for citation in container:
            if isinstance(citation, dict) and isinstance(citation.get("bibtex"), str):
                try:
                    for e in parse_bibtex(citation["bibtex"]):
                        embedded.append({"key": e["key"], "type": e["type"],
                                         "fields": {k: bib_plain(val) for k, val in e["fields"].items()}})
                except BibTeXError:
                    continue
        if embedded:
            sources["bibliography"] = "semantic.citations[].bibtex" if container is v.get("citations") \
                else "interaction.references[].bibtex"
            return embedded
    sources["bibliography"] = None
    return []


def extract_notes(pub, v, i, sources, out):
    chosen = pick(v.get("endnotes"), i.get("endnotes"), sources, "endnotes",
                  "semantic.endnotes", "interaction.endnotes")
    result = []
    for note in chosen or []:
        if not isinstance(note, dict):
            continue
        address = None
        for candidate in (note.get("href"), note.get("id")):
            if not candidate:
                continue
            path, fragment, element = pub.resolve_record_address(candidate)
            if element is None and fragment:
                hit = next((p for p in pub.docs if pub.find(p, fragment) is not None), None)
                if hit:
                    path, element = hit, pub.find(hit, fragment)
            if element is not None:
                address = pub.address(path, fragment)
                break
        if address is None:
            out["unresolved"].append({"from": "endnotes", "ref": note.get("href") or note.get("id")})
        anchor = None
        if note.get("anchor"):
            path, fragment, element = pub.resolve_record_address(note["anchor"])
            anchor = pub.address(path, fragment) if element is not None else None
            if element is None:
                out["unresolved"].append({"from": "endnotes.anchor", "ref": note["anchor"]})
        text = None
        if address:
            path, fragment = address.split("#", 1)
            element = pub.find(posixpath.normpath(posixpath.join(pub.package_dir, path)), fragment)
            text = text_of(element) if element is not None else None
        result.append({"address": address, "anchor": anchor, "text": text if text else note.get("text")})
    if not result:
        for path in pub.spine:
            root = pub.docs.get(path)
            for aside in (root.iter(X + "aside") if root is not None else []):
                if "endnote" in tokens(aside.get(EPUB_TYPE)) or "footnote" in tokens(aside.get(EPUB_TYPE)):
                    if aside.get("id"):
                        sources["endnotes"] = "content"
                        result.append({"address": pub.address(path, aside.get("id")), "anchor": None,
                                       "text": text_of(aside)})
    return result


def extract_equations(pub, v, sources, mode):
    index = {}
    if nonempty(v.get("equations")):
        sources["equations"] = "semantic.equations"
        for entry in v["equations"]:
            if isinstance(entry, dict):
                path, fragment, element = pub.resolve_record_address(entry.get("href") or entry.get("id"))
                if element is not None:
                    tex = entry.get("tex")
                    if isinstance(tex, str) and isinstance(entry.get("tex-sha256"), str) and \
                            hashlib.sha256(tex.encode("utf-8")).hexdigest() != entry["tex-sha256"].lower():
                        tex = None      # §7.7.1: a failed checksum leaves the MathML alone governing
                    index[pub.address(path, fragment)] = {"tex": tex, "label": entry.get("label")}
    else:
        sources["equations"] = "content"
    result = []
    for path in pub.spine:
        root = pub.docs.get(path)
        if root is None:
            continue
        for math in root.iter(MATH):
            if math.get("id") is None:
                continue
            address = pub.address(path, math.get("id"))
            known = index.get(address, {})
            result.append({"address": address, "display": math.get("display") or "inline",
                           "alttext": math.get("alttext"), "tex": known.get("tex"),
                           "label": known.get("label")})
    return result


def extract_tables(pub, v, i, sources, out):
    chosen = pick(i.get("tables"), v.get("tables"), sources, "tables",
                  "interaction.tables", "semantic.tables")
    by_address = {}
    for entry in chosen or []:
        if isinstance(entry, dict):
            path, fragment, element = pub.resolve_record_address(entry.get("href"), allow_bare=False)
            if element is None:
                out["unresolved"].append({"from": "tables", "ref": entry.get("href")})
                continue
            by_address[pub.address(path, fragment)] = entry
    result = []
    for path in pub.spine:
        root = pub.docs.get(path)
        if root is None:
            continue
        for table in root.iter(X + "table"):
            holder = table.get("id") or pub.nearest_id(path, table)
            if holder is None:
                continue
            address = pub.address(path, holder)
            entry = by_address.get(address, {})
            formulas = {}
            for r_index, row in enumerate(entry.get("cells") or []):
                for c_index, cell in enumerate(row if isinstance(row, list) else []):
                    if isinstance(cell, dict) and cell.get("formula"):
                        formulas[column_name(c_index) + str(r_index + 1)] = cell["formula"]
            result.append({"address": address, "identifier": table.get("data-table-id") or entry.get("identifier"),
                           "values": table_values(table), "formulas": formulas})
    return result


def column_name(index):
    name = ""
    index += 1
    while index:
        index, rem = divmod(index - 1, 26)
        name = chr(65 + rem) + name
    return name


def extract_models(pub, i, out):
    entries = {m.get("id"): m for m in i.get("models") or [] if isinstance(m, dict)}
    result = []
    for path, carrier, parents in model_carriers(pub):
        figure = parents.get(carrier)
        while figure is not None and local(figure.tag) != "figure":
            figure = parents.get(figure)
        holder = figure.get("id") if figure is not None and figure.get("id") else pub.nearest_id(path, carrier)
        src, _ = resolve(path, carrier.get("data-model-src"))
        units, extent = carrier.get("data-model-units"), carrier.get("data-model-extent")
        scale = None
        if units == "m" and extent:
            try:
                scale = [float(x) for x in extent.split()]
            except ValueError:
                scale = None
        caption = figure.find(X + "figcaption") if figure is not None else None
        description = text_of(caption) if caption is not None and text_of(caption) else None
        if description is None and local(carrier.tag) == "img" and (carrier.get("alt") or "").strip():
            description = carrier.get("alt").strip()
        media = carrier.get("data-model-media-type")
        exists = src is not None and pub.c.exists(src)
        if not exists:
            out["unresolved"].append({"from": "data-model-src", "ref": carrier.get("data-model-src")})
        result.append({
            "address": pub.address(path, holder) if holder else None,
            "id": carrier.get("data-model-id"),
            "src": pub.rel(src) if src else None,
            "mediaType": media,
            "displayable": media in MODEL_MEDIA_TYPES and exists,
            "filename": carrier.get("data-model-filename"),
            "bytes": int(carrier.get("data-model-bytes")) if (carrier.get("data-model-bytes") or "").isdigit() else None,
            "up": carrier.get("data-model-up"),
            "extentMetres": scale,
            "poster": pub.rel(resolve(path, carrier.get("src"))[0]) if local(carrier.tag) == "img" else None,
            "description": description,
            "source": carrier.get("data-model-source"),
            "joined": carrier.get("data-model-id") in entries,
        })
    return result


def extract_layouts(pub, v, layout, out):
    """§10.3 as a reader holds it: every reference resolved to an address or
    a semantic-record id, members placed in no view listed as unplaced
    rather than put at the origin, and no derived lines added."""
    if not isinstance(layout, dict):
        return None
    known = semantic_ids(v)

    def target(ref):
        if not isinstance(ref, str):
            return None
        if ref in known:
            return {"id": ref}
        path, fragment, element = pub.resolve_record_address(ref, allow_bare=False)
        if element is not None:
            return {"address": pub.address(path, fragment)}
        out["unresolved"].append({"from": "map", "ref": ref})
        return None

    views, placed = [], set()
    for view in layout.get("views") or []:
        if not isinstance(view, dict):
            continue
        space = view.get("space") if isinstance(view.get("space"), dict) else {}
        placements = []
        for node in view.get("nodes") or []:
            if isinstance(node, dict):
                placed.add(node.get("ref"))
                placements.append({"ref": node.get("ref"), "target": target(node.get("ref")),
                                   "x": node.get("x"), "y": node.get("y"),
                                   "depthMetres": node.get("z") if node.get("z") not in (None, 0, 0.0) else None})
        views.append({"id": view.get("id"), "name": view.get("name"),
                      "units": space.get("units"), "yUp": space.get("convention") == "right-handed-y-up",
                      "placements": placements})
    members = [{"id": n.get("id"), "label": n.get("label"), "kind": n.get("kind"), "target": target(n.get("id"))}
               for n in layout.get("nodes") or [] if isinstance(n, dict)]
    return {"views": views, "members": members,
            "unplaced": [m["id"] for m in members if m["id"] not in placed],
            "connections": [{"from": target(c.get("from")), "to": target(c.get("to"))}
                            for c in layout.get("connections") or [] if isinstance(c, dict)]}


def extract_stretchtext(pub):
    result = []
    for path in pub.spine:
        root = pub.docs.get(path)
        if root is None:
            continue
        for aside in root.iter(X + "aside"):
            if "ot-stretchtext-content" in classes(aside) and aside.get("id"):
                result.append({"address": pub.address(path, aside.get("id")), "text": text_of(aside)})
    return result


def extract_colophon(pub):
    found = list(colophons(pub))
    if not found:
        return {"present": False}
    path, section = found[0]
    stated = [text_of(c) for c in section.iter(X + "code") if RECORD_PATH.search(text_of(c))]
    pre = next(section.iter(X + "pre"), None)
    selfcite = None
    if pre is not None:
        try:
            entries = parse_bibtex("".join(pre.itertext()))
            if entries:
                selfcite = {"key": entries[0]["key"], "type": entries[0]["type"],
                            "fields": {k: bib_plain(val) for k, val in entries[0]["fields"].items()}}
        except BibTeXError:
            selfcite = None
    return {"present": True, "address": pub.address(path, section.get("id")) if section.get("id") else pub.rel(path),
            "recordPaths": stated, "selfCitation": selfcite}


# ---------------------------------------------------------------------------

def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    v = sub.add_parser("validate", help="check a publication against the profile")
    v.add_argument("publication")
    v.add_argument("--json", action="store_true", help="print the report as JSON")
    v.add_argument("--model-budget", type=int, default=DEFAULT_MODEL_BUDGET,
                   help="bytes above which a 3D model without data-model-source is warned about "
                        f"(§18.2; default {DEFAULT_MODEL_BUDGET})")
    e = sub.add_parser("extract", help="print what a conforming reader takes from it (§20.1)")
    e.add_argument("publication")
    args = parser.parse_args(argv)

    try:
        container = Container(args.publication)
    except (OSError, zipfile.BadZipFile) as error:
        print(f"cannot open {args.publication}: {error}", file=sys.stderr)
        return 2
    report = Report()
    pub = Publication(container, report)
    if args.command == "extract":
        print(json.dumps(extract(pub), indent=2, ensure_ascii=False, sort_keys=True))
        return 0
    validate(pub, report, args.model_budget)
    if args.json:
        print(json.dumps({"verdict": report.verdict(), "items": report.items}, indent=2, ensure_ascii=False))
    else:
        for item in report.items:
            where = f" [{item['where']}]" if item.get("where") else ""
            print(f"{item['level'].upper():7} {item['code']:26} {item['section']:14} {item['message']}{where}")
        errors, warnings = len(report.errors), len(report.warnings)
        print(f"\n{errors} error(s), {warnings} warning(s): "
              f"{'conforms' if not errors else 'does not conform'} to the Origami EPUB Profile 1.0"
              " (run EPUBCheck as well; §19)")
    return 1 if report.errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
