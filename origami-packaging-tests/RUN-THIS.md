# Packaging test — §4.4 settled, and confirmed against EPUBCheck

**Run and resolved on 24 September 2026.** Results in full below; the
short version is that **variant B is the shape Author should move to**,
and EPUBCheck has a dedicated error, `OPF-067`, for the mistake of doing
both.

The question was answered twice over: first by the normative text of
EPUB 3.3, which EPUBCheck implements rather than supplements, and then
empirically.

EPUB 3.3 §1.4:

> **linked resource** — "A resource that is only referenced from a
> package document link element (i.e., not also used in the rendering of
> an EPUB publication)."

EPUB 3.3 §3.1.1, of linked resources:

> "Unlike publication resources, they are not listed in the package
> document manifest."

An Origami metadata record contributes nothing to rendering, so it is a
linked resource: declared **only** by `<link rel="record">`, and **not**
manifested. That is profile §4.4.1.

## The five variants

Rebuilt 24 September so that each isolates exactly one variable.
Otherwise identical: mimetype stored first, container, OPF, nav, one
content document, one paragraph, `dcterms:conformsTo`, and an `origami:`
prefix declaration.

| Variant | `<link rel="record">` | manifest `<item>` | content-doc reference | Profile verdict |
|---|---|---|---|---|
| **A** `variant-A-manifest-only` | — | yes | — | **Non-conforming** — §4.4 requires the link; the record is undiscoverable by the profile's own mechanism. This is what Author writes today. |
| **B** `variant-B-link-only` | yes | — | — | **Conforming.** The target. |
| **C** `variant-C-link-and-item` | yes | yes | — | **Non-conforming** — §4.4.1 rule 1. |
| **D** `variant-D-content-reference` | yes | — | `<link rel="describedby">` in `<head>` | **Non-conforming** — §4.4.1 rule 2. |
| **E** `variant-E-meta-inf` | yes | — | — (record under `META-INF/`) | **Non-conforming** — §4.4.3. |

**D is the variant this test set was missing.** Until today all three
EPUBs carried a `rel="describedby"` hint in the content document, which
draft 3 of the profile recommended and draft 4 forbids. That hint made
the record a referenced resource, so it would have confounded the whole
test: B could have failed for the reference rather than for the
link-only declaration, and the result would have been read as
"link-only is invalid". A/B/C no longer carry it; D carries it alone.

**E tests where the records live.** A review proposed stating
`META-INF/visual-meta.json` in the human-readable colophon, so the
placement needed checking rather than assuming.

## Results — run 24 September 2026

EPUBCheck **5.2.1**, Temurin JRE **21.0.12.1** (downloaded to `/tmp/jdk`,
nothing installed system-wide).

```sh
JAVA=/tmp/jdk/jdk-21.0.12.1+1-jre/Contents/Home/bin/java
JAR=/tmp/jdk/epubcheck-5.2.1/epubcheck.jar
for f in *.epub; do echo "=== $f"; $JAVA -jar "$JAR" "$f"; done
```

| Variant | EPUBCheck | Profile verdict |
|---|---|---|
| **A** manifest item only | 0 errors | Non-conforming — §4.4 requires the link |
| **B** `<link rel="record">` only | **0 errors** | **Conforming. This is the target.** |
| **C** both | **ERROR `OPF-067`** | Non-conforming — confirmed by the tool |
| **D** link only + content-doc `describedby` | 0 errors | Non-conforming — §4.4.1 rule 2 |
| **E** link only, record in `META-INF/` | 0 errors | Non-conforming — §4.4.3 |

`OPF-067`, in full:

> The resource "OEBPS/visual-meta.json" must not be listed both as a
> `link` element in the package metadata and as a manifest item.

## What this settles

**Author's migration is unblocked, and the shape is B.** Move each
record out of the manifest and declare it only as
`<link rel="record" properties="origami:…">`. Do not do both: `OPF-067`
makes that an EPUBCheck error, so it would fail validation outright.

**A passing today.** The current export — records as manifest items with
no `<link>` — is *valid EPUB*. It is not profile-conforming, but nothing
already shipped is broken, so the migration is not urgent in the sense
of repairing damage. It is only needed for discovery.

**Two rules the tool does not enforce.** D and E both pass EPUBCheck
while being non-conforming:

- **D** — a content document may not reference a record at all
  (§4.4.1 rule 2). EPUBCheck does not flag it, but a record referenced
  from the rendering is by EPUB's own definition no longer a *linked*
  resource, which would then require the manifest entry `OPF-067`
  forbids. The publication is in a contradictory state that simply has
  no error code.
- **E** — records may not live in `META-INF/` (§4.4.3). OCF: *"EPUB
  creators MUST NOT reference files in the `META-INF` directory from an
  EPUB publication."* A package `<link>` is such a reference.

Both are why §18's profile validator exists. EPUBCheck answers "is this
an EPUB?"; it cannot answer "is this an Origami EPUB?"

## Re-running later

The five files are corpus item `11-packaging` (§19). Expected verdicts
are recorded above, so a future run is a regression check.
