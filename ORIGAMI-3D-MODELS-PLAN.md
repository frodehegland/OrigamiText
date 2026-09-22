# Spatial figures: 3D models in Origami Text

**A format proposal and implementation plan, 22 September 2026.** Written
from the format side, so it can be compared against the Author write-up of
the same feature and the two reconciled before either is built.

The goal, in the user's words: drop a 3D model onto a document in Author,
have it embedded; on export to Origami EPUB it shows as a preview until the
reader extracts it — double-click on macOS, the way you'd pull out an image
or a table; a pinch in visionOS.

> **Reconciled with Author, same day.** This was written before reading
> Author's code, which turned out to implement most of it already —
> `LAModelAttachment` and `OrigamiTextExporter` emit `<model>` elements,
> posters, `OEBPS/models/` and conformant manifest fallbacks today. Three
> things below have been **corrected to match Author**, which was right and
> this document was not: `<source>` children instead of a `src` attribute
> (§2), no separate `data-model-poster` (§2), and reduction at **export**
> rather than import (§11), because Author's "carrier, not converter"
> principle is correct and the `.liquid` must keep the writer's bytes.
> The remaining gaps are in `~/Documents/author_mac_forxcode/ORIGAMI-3D-MODELS.md`
> as AU-M1…AU-M8.

---

## 1. What kind of object

**Required: USDZ. Encouraged and declared: glTF 2.0 binary (`.glb`).
Required always: a rendered poster image.**

| | Carry it? | Why |
|---|---|---|
| **USDZ** (`model/vnd.usdz+zip`) | **required** | One file with its textures inside — the only Apple-native form that can be embedded without dragging companion files along. It is what QuickLook, AR Quick Look, RealityKit, Reality Composer and the `<model>` element all consume with no conversion, so every Apple-platform reader renders it for free. Published format (Pixar USD plus Apple's zip profile), not a private one. |
| **glTF 2.0 binary** (`model/gltf-binary`) | **encouraged; always declared** | The Khronos open standard: what `<model-viewer>`, three.js, Babylon, Blender and every non-Apple engine read. Without it a spatial figure is a figure only Apple users can open, which is the same failure as a PDF only Acrobat can read — and this format's whole argument is against that. |
| **Poster** (PNG or JPEG) | **required** | Not a nicety. See §3: in most reading systems the poster *is* the figure. |
| `.reality` | not published | Proprietary, compiled, version-locked to a toolchain. Fine to drop in; warn, and convert or refuse at export. |
| bare `.usd` / `.usda` / `.usdc` | not published as-is | They reference textures as separate files, so embedding one alone ships a model with no textures. Package to USDZ at export with `usdzip` — the same scene, wrapped, not a re-encode. |
| `.gltf` (JSON) | not published as-is | Same problem: external buffers and textures. Package to `.glb` at export. |
| `.obj`, `.fbx`, `.dae`, `.stl` | no | OBJ has no scene graph and no PBR materials; FBX is proprietary; all want companion files. Convert at drop, where the writer can see the result. |
| point clouds (`.ply`, `.e57`) | not v1 | A different rendering problem. Worth its own element later, not this one. |

**The pattern this follows is the format's own.** Origami already says
things twice, once in the standard way and once in the way that actually
renders: MathML *plus* `data-latex`; `data-language` *plus*
`class="language-…"`. A spatial figure is the same shape — USDZ for what
renders on the reader's likely device, glTF for what the rest of the world
can open, a poster for everything else.

**Never fabricate the sibling.** If there is no glTF, say so and ship
USDZ alone. Do not auto-convert USDZ → glTF at export and present the
result as the author's: a silently lossy conversion (materials, animation,
variants) is worse than an honest absence. This is the same rule the format
already applies to `data-latex`.

**Budgets warn; they never refuse.** A spatial figure above ~25 MB warns at
export and above ~100 MB warns louder, naming the figure and saying what a
further reduction would buy — and then does as it is told. An EPUB that is
90% turbine is not a paper, but it is the author's document, and a tool that
refuses to export it teaches people to fight the tool. §11 is about
how to stay under that, and it turns out to be easy — but only if you do the
right thing, which is not the obvious one.

---

## 2. The element

A model is a figure, so it is a `<figure>` — the same element, the same id,
the same caption machinery Origami already emits for images. Only the inside
differs.

```html
<figure id="P-9F2A1C40-…" data-id="P-9F2A1C40-…" class="origami-model">
  <model id="M-9F2A1C40-…"
         data-filename="Turbine assembly"
         data-model-units="m"
         data-model-extent="0.42 1.10 0.42"
         data-model-up="Y"
         aria-describedby="P-9F2A1C40-…-desc"
         interactive="">
    <source src="models/turbine.usdz" type="model/vnd.usdz+zip"/>
    <source src="models/turbine.glb"  type="model/gltf-binary"/>
    <img src="images/turbine-poster.png"
         alt="Cutaway of the turbine assembly, blades foreground, housing
              sectioned to show the bearing race." />
  </model>
  <figcaption>Figure 3. The turbine assembly, sectioned.</figcaption>
</figure>
```

**`<source>` children, not a `src` attribute** — Author already emits this
and it is the better shape: it is how `<video>` and `<picture>` offer
alternatives, it needs no `data-` invention, and the USDZ and its glTF
sibling sit side by side with no new vocabulary. There is likewise **no
`data-model-poster`**: the poster is the fallback `<img>`, and naming it
twice invites the two to disagree.

Author puts `M-<uuid>` on the `<model>` and `P-<uuid>` on the `<figure>`.
Both are useful, but the spec must say which one is cited: **the figure's
`P-` id**, because that is the id space `origami.json`, the endnote and
glossary back-links, and Reader's `origami-anchor` citation blocks already
use. `M-` is an internal handle, not an address.

**We depend on almost nothing from `<model>` itself.** The element is very
young; its attribute surface is still moving, and Apple's developer
documentation does not describe it at all (it is a WebKit implementation of
a W3C Immersive Web draft). So the design leans on only the two parts that
are stable by construction — `<source>` children, and the fact that an
unknown element renders its children — and puts everything of ours in
`data-*`, which is
our namespace and cannot be broken by the spec changing under us. If
`<model>` gains a standard poster or scale attribute later, we emit that
*as well*; nothing has to be rewritten.

### Attributes

| Attribute | Required | Meaning |
|---|---|---|
| `<source src type>` | yes, one or more | The USDZ first, the glTF sibling after it when there is one |
| `data-model-units` | yes | `m`, `cm`, or `mm` — the unit the extent is in |
| `data-model-extent` | yes | Real-world bounding box, `x y z`, in those units |
| `data-model-up` | yes | `Y` or `Z` — USD and glTF disagree, and a model that arrives on its side is the commonest bug in this whole area |
| `data-model-license` | when terms exist | A URL naming the terms the model is offered under |
| `data-filename` | yes | The name to give the extracted file (Author's spelling; keep it) |
| `aria-describedby` | when a long description exists | Points at a `<details>` after the figure |

`data-model-extent` and `data-model-units` exist because of the pinch. A
model pulled into a visionOS room at the wrong scale — a turbine that
arrives the size of a building, a molecule the size of a grain of sand — is
not a small cosmetic problem; it is the feature not working. The author
knows the real size at the moment of authoring. The format should carry it
rather than make every reader guess from the mesh.

---

## 3. The poster is the primary rendering, not the fallback

This is the part most likely to be got wrong, and it is the same mistake the
September article's own EPUB made with paragraphs: shipping a file whose
claims only hold in the authoring tool.

**Nearly every EPUB reading system will ignore `<model>` entirely.** Reading
systems implement a subset of HTML, they lag browsers by years, and this
element is new even in browsers. An unknown element renders its children —
so what the overwhelming majority of readers will see is the `<img>` inside.
That is not a degraded experience to be apologised for; for now it is the
*normal* experience, and the poster must be good enough to carry the figure
on its own.

Consequences for the exporter:

- The poster is **rendered once, at authoring time** — when the model is
  dropped, by Quick Look — and that image is what ships. Never left for the
  reading system to generate, because the reading system may have no 3D
  engine at all; and at authoring rather than export so the writer sees the
  still the reader will see, and can re-frame it if the camera is wrong.
  (This document said "export" here and "import" in §8; Author does it at
  drop, and the spec now says one thing.)
- The poster carries **real alt text**, and joins the existing accessibility
  rule: `OrigamiEPUB.AccessibilityFacts.allImagesHaveAltText` already
  withdraws `schema:alternativeText` and `accessModeSufficient=textual`
  when one `<img>` lacks alt. A model's poster is an `<img>`; it must be
  counted the same way. A spatial figure with no alt withdraws the claim
  for the whole document, exactly as an image does.
- Anything the caption cannot carry goes in a **long description** — a
  `<details>` after the figure, pointed at by `aria-describedby`. This is
  the standard pattern for complex images and a 3D model is a complex image
  by definition.

---

## 4. Package and manifest

```
OEBPS/
  content/models/turbine.usdz
  content/models/turbine.glb
  content/images/turbine-poster.png
```

```xml
<item id="model3-poster" href="content/images/turbine-poster.png"
      media-type="image/png"/>
<item id="model3-usdz"   href="content/models/turbine.usdz"
      media-type="model/vnd.usdz+zip" fallback="model3-poster"/>
<item id="model3-glb"    href="content/models/turbine.glb"
      media-type="model/gltf-binary"  fallback="model3-poster"/>
```

**The `fallback` attribute is not optional.** Neither media type is an EPUB
core media type, so both are *foreign resources*, and EPUB 3 requires a
foreign resource in the manifest to declare a fallback chain ending in a
core type. Without it EPUBCheck flags the book. Pointing the fallback at the
poster is both conformant and true: the poster is what a reader that cannot
handle the model should use.

Models go in `content/models/`, not `content/images/`. The exporter
currently hardcodes the images path (`OrigamiEPUB.swift`, around the
`zip.add("content/images/…")` calls); that needs a second bucket keyed off
the asset's media type.

---

## 5. Extraction

The interaction the user asked for, said in the format so every reader
implements the same thing.

| Platform | Gesture | Result |
|---|---|---|
| macOS | double-click the figure | the USDZ opens in QuickLook; ⌥-drag, or the context menu, writes `<data-model-filename>.usdz` to the Desktop |
| visionOS | pinch and pull | the model leaves the page into a volume at the size `data-model-extent` says, and stays where it is put |
| iOS / iPadOS | long press | AR Quick Look |
| anything else | — | the poster, and a download link if `data-model-extract` allows it |

Context menu, everywhere: **Extract Model…**, **Copy as Citation** (the
figure is addressable, so its `origami-anchor` is the figure's id — this
falls out of work already shipped), and **Open in…** where a handler exists.

**There is no permitted-actions list.** An earlier draft had
`data-model-extract`, naming what a reader "may" pull out. The Author work
rightly killed it: the bytes are in the file, the plan itself conceded it was
"a declaration, not enforcement", and publishing it invites an implementer to
build a permission system that does not exist and a reader to believe in one.
Where the intent is licensing, `data-model-license` pointing at real terms is
honest — a reader can show it beside the extract command without pretending
to police it.

---

## 6. The document side (`.origamitext` / `LiquidDoc`)

**Marker syntax**, parallel to images, one scheme change:

```
![alt](asset:<id>)     an image, today
![alt](model:<id>)     a spatial figure
```

`LiquidDoc.imageReference(in:)` is one regex
(`^!\[(.*)\]\(asset:([^)]+)\)$`); this needs a sibling `modelReference(in:)`
with the same shape and the same greedy-alt behaviour. It degrades to plain
text identically, which is the rule for every marker in §6 of the format
document.

**`LiquidDoc.Asset` needs almost nothing.** It already carries `id`,
`filename`, `mediaType`, `dataBase64` and `alt`. It gains one optional
sub-record:

```swift
struct ModelDetail: Hashable, Sendable, Codable {
    var posterAssetID: String       // the rendered still
    var glbAssetID: String?         // the open sibling, when there is one
    var units: String               // "m" | "cm" | "mm"
    var extent: [Double]            // [x, y, z]
    var upAxis: String              // "Y" | "Z"
    var extractable: [String]       // ["usdz", "glb", "poster"]
    var suggestedFilename: String
    var longDescription: String?
}
var model: ModelDetail?             // nil for every existing asset
```

Optional and absent by default, so every document already in the wild
decodes unchanged — the §2 rule of tolerance holds.

**One real problem to name rather than discover later: base64.** Assets live
in the draft JSON base64-encoded. A 20 MB USDZ becomes ~27 MB of base64
inside a file that is opened, parsed and re-saved on every edit. That is
fine for a 200 KB screenshot and not fine for a model.

Recommendation, simplified after the Author review: **sidecar every model,
with no threshold.** An earlier draft proposed base64 under 2 MB and a
sidecar above it; essentially every model crosses 2 MB, so the threshold
only adds a branch that is never taken and a second format to keep working.
So: model bytes always live beside the draft, with the asset carrying a
relative path and a `sha256` — machinery §8 of the format document already
defines for wrapped files, reused rather than reinvented.

Author has no equivalent decision: its model bytes ride binary inside the
`.liquid` attachment's `fileWrapper`, not base64 in JSON.

---

## 7. Reader's side

Reader renders EPUBs in a `WKWebView`. **Whether that web view renders
`<model>` at all is unverified** — the element ships in Safari, and an
embedded `WKWebView` is not always the same thing; Apple's documentation
here describes neither. This needs twenty minutes with a real book before
any of it is designed around, and the design below is deliberately arranged
so the answer does not matter much:

1. A page script finds every `figure.origami-model` and reports its
   `data-*` to the app — the same bridge `selectionBridgeScript` already
   uses, so no new machinery.
2. If the web view rendered the model, leave it alone.
3. If it did not, the poster is already showing (it is the fallback), and
   Reader overlays a small affordance on it.
4. Either way the native side owns extraction: QuickLook on macOS, a
   RealityKit volume on visionOS, using the USDZ pulled out of the unpacked
   book — which `EPUBPackage` can already reach, since it unpacks to
   `Caches/EPUBs/<hash>/`.

So the feature works whether or not `<model>` renders, and gets better for
free if it does.

---

## 8. What Author must do

The contract half, in the shape of `CITATION-EPUB-SPEC.md`, for comparison
with the Author write-up.

1. **Accept a drop** of `.usdz`, `.glb`/`.gltf`, `.obj`, `.dae`, `.stl` onto
   the document. Convert everything that is not USDZ to USDZ on import and
   keep the original bytes where the original was already an open
   interchange format (glTF), so the sibling is the author's file and not a
   round-trip.
2. **Render the poster at drop**, so the author sees the still that readers
   will see and can re-frame it. Already done — Quick Look.
3. **Ask for, or derive, the real-world extent and up-axis**, and let the
   author correct them. USD scenes carry `metersPerUnit` and `upAxis`; read
   them, and treat them as a default the author may override, not as truth.
4. **Require alt text** on the poster with the same insistence as for an
   image — the document's accessibility claims depend on it.
5. **Emit exactly the element in §2**, the manifest items in §4 with their
   `fallback`, and files under `content/models/`.
6. **Extend the export conformance check** (`AU-8`, and Origami Text's
   `profileWarnings`) with: a `<model>` with no fallback `<img>`; a poster
   with no alt; a missing `data-model-extent` or `data-model-up`; a foreign
   resource in the manifest with no `fallback`; a spatial figure over the
   size budget.
7. **Do not invent a glTF** by converting USDZ at export (§1).
8. **Agree the base64 threshold** in §6 with Origami Text before shipping.
9. **Reduce textures at export, visibly** (§11): 2048² cap at quality 85 by
   default, never upscaling, higher quality for normal maps, constant-value
   maps turned back into scalars — with a preflight sheet showing each
   figure's size before and after and a per-figure override. Export, not
   import: the `.liquid` keeps the writer's bytes byte for byte, which is
   Author's own principle and the right one.
10. **Ask once for the original's URL or DOI** at drop time, and write it as
    `data-model-source`. It is the only moment the author reliably knows it.

---

## 9. Spec text

This wants to land in two places.

**`ORIGAMI-DOCUMENT-FORMAT.md`** — extend §6 (body text conventions) with
the `![alt](model:<id>)` marker, and add the `ModelDetail` fields to the
asset description. Small.

**A new section of the EPUB profile** — the element, the manifest rules, the
poster requirement, the extraction declaration. This is the substantial
half, and it is also the half the article's Spatial Reasoning section can
finally point at: the format currently *claims* it can carry spatial layouts
and the exemplar file carries none (`"extensions": {}`, no `map` key). A
spatial figure is a smaller, more demonstrable version of that claim, and
one worked example in the next article is worth more than the paragraph
describing it.

---

## 10. Order of work

1. **§6 model side** — marker, `ModelDetail`, the base64 threshold decision.
   Nothing renders yet; both apps agree on what a document says.
2. **Export** — `content/models/`, manifest items with fallbacks, the
   element, the poster. A file exists that other people's readers can open.
3. **Import** — round-trip, so Origami Text reading its own export gets the
   same document back. The §1 round-trip rule.
4. **Origami Text rendering** — poster inline; extraction on macOS.
5. **Reader** — the bridge in §7, QuickLook, the visionOS volume.
6. **visionOS pinch-to-pull**, which is the one that needs a device and a
   real book, and should be scheduled as an experiment rather than a task.

Steps 1–3 are the format. They are also the only steps that are expensive to
get wrong, because they are the ones that end up in files other people hold.

---

## 11. Compression: what actually works

Measured on 22 September 2026 against real models from Frode's Downloads
folder, using the USD tools macOS now ships at `/usr/bin` (`usdzip`,
`usdcat`, `usdchecker`) — not estimated.

### The fact that decides everything

**A USDZ is an uncompressed zip.** The format requires every entry be
*stored*, not deflated, so the file can be memory-mapped and read without
inflation. Checked on four models: 5, 16, 10 and 5 entries, **every one
stored**. So the container does nothing for you, and anything you want
compressed has to be compressed before it goes in.

### Where the bytes actually are

| Model | Size | Textures | Geometry (`.usdc`) |
|---|---|---|---|
| `3d_brain_anatomy` | 24.54 MB | **90%** | 9% |
| `neuron_cell_structure` | 32.78 MB | **81%** | 18% |
| `chameleon_anim_mtl_variant` | 14.90 MB | **78%** | 20% |

Geometry is a rounding error. **Textures are the file.** Every instinct
that says "decimate the mesh" is aimed at the 9–20%.

The brain model's textures are **8192 × 8192**. Its normal map alone is
14.5 MB — over half the document-sized file — for a figure that will be
looked at in a column perhaps 600 pixels wide.

### The levers, in order of what they are worth

**How, not just what: this must be in-process.** The measurements below were
taken by shelling out to `usdzip`, which I can do and **Author cannot** —
it is sandboxed (`com.apple.security.app-sandbox`), and so is any App Store
build of Origami Text or Reader. A sandboxed app cannot execute `/usr/bin/usdzip`.
So the pipeline is: read the USDZ as a zip, resize the texture entries with
ImageIO in memory, and write a new archive **keeping every entry name
unchanged** so the `.usdc`'s relative references still resolve — no scene
rewriting at all. (Correction contributed by the Author work, 22 September;
the earlier draft of this section assumed the command-line tools.)

**And the one thing that will bite you: USDZ requires 64-byte alignment.**
Every entry's *data* must begin on a 64-byte boundary so the archive can be
memory-mapped and the `.usdc` read in place. Measured on real files: every
entry aligned, achieved by padding the zip `extra` field by 12–66 bytes.
`usdzip` does this for you; `Foundation`, `ZIPFoundation` and Python's
`zipfile` do not. A naive rewrite — same names, stored, no padding — fails
validation outright:

```
$ usdchecker --arkit brain-naive.usdz
Error: (usdUtilsValidators:UsdzPackageValidator.ByteMisalignment)
File '3d-brain-anatomy.usdc' in package 'brain-naive.usdz' has an invalid offset 51.
```

Note `--arkit`: the plain `usdchecker` run passes this file happily, so the
alignment bug is invisible unless you ask for the package rules. Whatever
writes the archive must emit the padding, and the export check should run
`--arkit`'s equivalent — or simply assert `dataOffset % 64 == 0` for every
entry, which is three lines and needs no USD dependency at all.

**1. Cap texture resolution — 90 to 97%.** The only lever that matters.

| | Textures |
|---|---|
| as shipped (8192²) | 22.0 MB |
| capped at 2048² | **2.1 MB** (−90%) |
| capped at 1024² | **0.68 MB** (−97%) |

Rebuilt with `usdzip` at the 2048 cap, the whole model goes **24.54 MB →
4.3 MB, an 82% reduction**, and still loads and validates. (`usdchecker`
reports two complaints on the rebuild — a shader property typed `token`
instead of `string`, and a constant occlusion value — and both are present
in the *original* too. They are the source model's, not the reduction's. I
checked.)

Recommended default: **2048² cap, JPEG quality 85**, with 4096² available
for a figure whose whole point is surface detail, and 1024² offered when
the author wants the document small. Normal maps are the exception that
needs watching: they carry direction, not colour, so JPEG artefacts become
visible lighting errors. Cap them at the same resolution but keep quality
higher (92+), or leave them PNG if the model is small enough to afford it.

**2. Let the EPUB zip deflate the USDZ — 8 to 11%, free.** The EPUB
container *is* deflate, and a USDZ is stored, so simply not setting
`ZIP_STORED` when adding the model recovers 8–11%: 24.54 → 22.67 MB, 32.78
→ 29.22 MB, 14.90 → 13.33 MB. Every byte of that saving comes from the
`.usdc` geometry — the textures are already JPEG and incompressible. This
costs nothing and needs no decision, but note it only helps a reader who
unpacks the book (Reader does, to `Caches/EPUBs/<hash>/`); a reader
memory-mapping straight out of the container would rather have it stored.
Small enough either way that unpacking wins.

**3. Channel-pack the material maps — up to 3×.** Roughness, metallic and
ambient occlusion are each a single greyscale channel usually shipped as
three separate full-colour images. Packed into the R, G and B of one
texture (the ORM convention, which `UsdPreviewSurface` and glTF both
understand) that is three files down to one.

**4. Drop constant-value textures.** The brain model ships a **1 × 1 pixel**
JPEG for metallic. It is a scalar wearing a texture's clothes. A material
whose map is a single uniform value should be a number in the shader.

**5. Geometry, last.** Decimation and LOD are aimed at 9–20% of the bytes,
and they are the lossy operation an author is most likely to object to,
because it changes the object rather than its picture. For glTF the real
tools are Draco (`KHR_draco_mesh_compression`) and meshopt; USDZ supports
neither, so on the Apple side `.usdc` is already as good as it gets. Do
this only when a genuinely huge scan blows the budget after steps 1–4.

### One trap, found the hard way

A naive resize pass **upscales**. `sips -Z 2048` applied to that 1 × 1
metallic texture produced a 2048 × 2048 image and grew the file from 4 KB
to 51 KB. Whatever does the capping must clamp, never stretch: skip any
image already at or below the cap.

### What the format should say about it

Compression is not only an engineering question here — it is a
**provenance** question, and that is the part a format can address that a
build script cannot.

A reduced model in a paper is like a downsampled photograph in a figure:
expected, fine, and something the record should state rather than hide. So
where the exporter has reduced a model, the figure says so:

```html
data-model-reduced="textures:2048 quality:85"
data-model-source-bytes="25724928"
data-model-source="https://doi.org/10.5281/zenodo.1234567"
```

- `data-model-reduced` — what was done, in terms a reader can evaluate.
- `data-model-source-bytes` — what it was, so the reduction is visible.
- `data-model-source` — **where the full-resolution original lives**, when
  it lives anywhere. This is the scholarly move, and the one that makes the
  budget in §1 defensible rather than merely restrictive: a paper does not
  carry the dataset, it cites it. A spatial figure should be allowed to be
  a figure, with the real thing one resolvable identifier away.

The exporter check (§8.6) gains: a spatial figure over budget whose
`data-model-source` is absent should warn — not because the reduction is
wrong, but because the original then has nowhere to be found.

### What this means for Author

All of this belongs in **export**, not import. `LAModelAttachment`'s header
states Author's principle — "this app is a carrier, not a converter, and a
re-encoded model is a changed model" — and it is right: the `.liquid` is the
writer's working copy and must keep what they gave it. But publication is a
different act. The exported EPUB is already a rendering: it renders posters,
flattens to XHTML, drops the editing model. A reduced texture set belongs
there, with the original intact behind it.

(An earlier draft of this section said "reduce at import so the author can
see it". Reading Author's design showed that to be wrong.) The "so the
author can see it" requirement is real and is met instead by a **preflight
sheet at export**: one row per spatial figure, size before and after, the
cap applied, and a per-figure override — 4096² where surface detail is the
point, 1024² where small matters, *Original* to opt out. Nothing silent.

Step 5 (geometry) should be offered, never automatic. And the author should
be asked once, at drop time, for the URL or DOI of the full-resolution
original — the moment they are most likely to know it.

---

## Two things I could not verify, flagged rather than assumed

- **The `<model>` attribute surface.** Apple's developer documentation does
  not describe the element; it is a WebKit implementation of a W3C
  Immersive Web draft, documented on webkit.org and in the spec repository.
  The design above uses only `src` and child-element fallback for that
  reason. Before building, read the current WebKit source or the draft and
  add any standard attributes we should be emitting alongside our `data-*`.
- **Whether an embedded `WKWebView` renders `<model>`** on macOS and
  visionOS, and what it does with a `usdz` served from an unpacked book
  directory. §7 is arranged not to depend on the answer, but the answer
  changes how good this feels.
