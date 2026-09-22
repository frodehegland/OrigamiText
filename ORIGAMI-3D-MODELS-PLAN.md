# Spatial figures: 3D models in Origami Text

**A format proposal and implementation plan, 22 September 2026.** Written
from the format side, so it can be compared against the Author write-up of
the same feature and the two reconciled before either is built.

The goal, in the user's words: drop a 3D model onto a document in Author,
have it embedded; on export to Origami EPUB it shows as a preview until the
reader extracts it — double-click on macOS, the way you'd pull out an image
or a table; a pinch in visionOS.

---

## 1. What kind of object

**Required: USDZ. Encouraged and declared: glTF 2.0 binary (`.glb`).
Required always: a rendered poster image.**

| | Carry it? | Why |
|---|---|---|
| **USDZ** (`model/vnd.usdz+zip`) | **required** | One file with its textures inside — the only Apple-native form that can be embedded without dragging companion files along. It is what QuickLook, AR Quick Look, RealityKit, Reality Composer and the `<model>` element all consume with no conversion, so every Apple-platform reader renders it for free. Published format (Pixar USD plus Apple's zip profile), not a private one. |
| **glTF 2.0 binary** (`model/gltf-binary`) | **encouraged; always declared** | The Khronos open standard: what `<model-viewer>`, three.js, Babylon, Blender and every non-Apple engine read. Without it a spatial figure is a figure only Apple users can open, which is the same failure as a PDF only Acrobat can read — and this format's whole argument is against that. |
| **Poster** (PNG or JPEG) | **required** | Not a nicety. See §3: in most reading systems the poster *is* the figure. |
| `.reality` | no | Proprietary, compiled, version-locked to a toolchain. Not interchange. |
| bare `.usd` / `.usda` / `.usdc` | no | They reference textures as separate files. An embedded figure must be one file. |
| `.obj`, `.fbx`, `.dae`, `.stl` | no | OBJ has no scene graph and no PBR materials; FBX is proprietary; all of them want companion files. Convert to USDZ on import. |
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

**Budgets, so a document stays a document.** A spatial figure above ~25 MB
should warn at export, and above ~100 MB should be refused with a message
naming the figure. An EPUB that is 90% turbine is not a paper.

---

## 2. The element

A model is a figure, so it is a `<figure>` — the same element, the same id,
the same caption machinery Origami already emits for images. Only the inside
differs.

```html
<figure id="P-9F2A1C40-…" data-id="P-9F2A1C40-…" class="origami-model">
  <model src="models/turbine.usdz"
         data-model-glb="models/turbine.glb"
         data-model-poster="images/turbine-poster.png"
         data-model-units="m"
         data-model-extent="0.42 1.10 0.42"
         data-model-up="Y"
         data-model-extract="usdz glb"
         data-model-filename="Turbine assembly"
         aria-describedby="P-9F2A1C40-…-desc">
    <img src="images/turbine-poster.png"
         alt="Cutaway of the turbine assembly, blades foreground, housing
              sectioned to show the bearing race." />
  </model>
  <figcaption>Figure 3. The turbine assembly, sectioned.</figcaption>
</figure>
```

**The id stays on the `<figure>`.** That is where Origami puts it today, so
every existing anchor, citation, backlink and `origami-anchor` keeps
resolving with no change to the addressing rules. A spatial figure is
addressable in exactly the way a paragraph is — which is the claim the
format makes, now extended to something that is not text.

**We depend on almost nothing from `<model>` itself.** The element is very
young; its attribute surface is still moving, and Apple's developer
documentation does not describe it at all (it is a WebKit implementation of
a W3C Immersive Web draft). So the design leans on only the two parts that
are stable by construction — `src`, and the fact that unknown elements
render their children — and puts everything of ours in `data-*`, which is
our namespace and cannot be broken by the spec changing under us. If
`<model>` gains a standard poster or scale attribute later, we emit that
*as well*; nothing has to be rewritten.

### Attributes

| Attribute | Required | Meaning |
|---|---|---|
| `src` | yes | The USDZ, relative to the content document |
| `data-model-glb` | when present | The glTF sibling. Absent means there isn't one |
| `data-model-poster` | yes | The rendered still. Same file the fallback `<img>` uses |
| `data-model-units` | yes | `m`, `cm`, or `mm` — the unit the extent is in |
| `data-model-extent` | yes | Real-world bounding box, `x y z`, in those units |
| `data-model-up` | yes | `Y` or `Z` — USD and glTF disagree, and a model that arrives on its side is the commonest bug in this whole area |
| `data-model-extract` | yes | Space-separated list of what the reader may pull out: `usdz`, `glb`, `poster` |
| `data-model-filename` | yes | The name to give the extracted file, without extension |
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

- The poster is **rendered at export**, by the authoring app, from a
  sensible camera. It is never left for the reading system to generate,
  because the reading system may have no 3D engine at all.
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

`data-model-extract` exists so an author can publish a figure that may be
looked at but not taken — a licensed dataset, an unreleased design. It is a
declaration, not enforcement; the bytes are in the file either way, and the
format should not pretend otherwise. Say so in the spec text rather than
implying a protection we are not providing.

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

Recommendation: **a size threshold, and sidecar files above it.** Under
~2 MB, base64 in the document as now. Above it, the bytes live beside the
draft and the asset carries a relative path and a `sha256` — machinery §8 of
the format document already defines for wrapped files, reused rather than
reinvented. On export both paths produce the same EPUB. This needs to be the
same decision in Author, or a document will round-trip through the two apps
and change shape.

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
2. **Render the poster at import**, not at export, so the author sees the
   still that readers will see and can re-frame it.
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
