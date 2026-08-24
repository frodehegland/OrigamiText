# Contributing to Origami Text

Origami Text is a Future Text Lab project: a reader for EPUB books and
academic papers, built on one conviction — the book belongs to its
author, and the reading belongs to you. Everything a reader does
(highlights, notes, judgments, AI readings, spatial arrangements) lives
*beside* the books in open formats, never inside them. MIT licensed.

The two documents that define the project live in `LiquidView/`:

- **ORIGAMI-DOCUMENT-FORMAT.md** — the complete `.origamitext` / Origami
  EPUB specification, self-contained.
- **ORIGAMI-TEXT-OVERVIEW.md** — what the app does and why.

Read those first; this file covers the things that trip people up.

## Toolchain

Any **Xcode 26** should build the project; 26.5 is the version it is
verified against (if an older Xcode fails, report it — that is a bug
here, not on your machine). The deployment target is macOS 26.0 and the
app runs there. House rule that keeps this true: never *name* an API
newer than the macOS 26.0 SDK — `@available` only gates running code,
not compiling it, so a newer symbol still breaks older SDKs at compile
time. Match newer types by reflection instead (see
`TranscriptSummary.swift`) or skip the newer path (see the note in
`PersonPortraits.swift`).

## Targets and schemes (the first confusion)

One Xcode project, three app targets, all sharing the `LiquidView`
source folder:

| Scheme | Platform | What it is |
| --- | --- | --- |
| **LiquidView** | macOS | The macOS app — the main reader. Yes, the macOS app is the scheme named LiquidView. |
| **Origami Text Vision** | visionOS | The Vision Pro app (`OrigamiVision.swift` is its `@main`). |
| **Origami Text** | iOS | The iOS target. Dormant — not currently supported. |

`LiquidView/` is a *synchronized* folder (Xcode 16+ buildable folder):

- A **new file automatically joins the macOS target** and nothing else.
- The **iOS and visionOS targets opt in per-file** via membership
  exception lists in the project. If the vision build fails with
  "cannot find X in scope" for a type that plainly exists, the file
  defining it almost certainly needs ticking into the vision target
  (File Inspector ▸ Target Membership).
- visionOS-only files are wrapped in `#if os(visionOS)` so their
  automatic macOS membership compiles to nothing.

Never hand-edit `project.pbxproj`; change membership through Xcode.

## The vendored Author engine (do not refactor)

The visionOS Map is built on the node engine from the **Author** app
(the Lab's word processor), ported **verbatim**:

- `NodeImmersiveView*.swift` (9 files) — the generic engine: items via
  `ItemProtocol`, gestures, selection, connections, an ECS system.
- `NodeImmersiveView+Tools.swift` — the rasterizer and node-box
  builders (Author's `Extensions.swift`).
- `ArmMenu.swift` — the forearm chip menu.
- `KnowledgeSpaceAnchoring.swift` — ARKit world/head anchoring.

Each carries a provenance header. Treat them as vendored third-party
code: fixes flow *from* Author, local refactors don't. Origami-specific
behavior belongs in the host, `EPUBMapView.swift`.

**How nodes render, and why:** the engine rasterizes each node's SwiftUI
face to a `UIImage`, textures a plane with it, and mounts that in a
RealityKit box (`ModelEntity.box`). This textured-plane pipeline is the
one that reliably renders on the Vision Pro. Free-floating mesh or
view-attachment approaches inside stacked RealityViews have burned us
before — which leads to the standing rule:

> **The visionOS simulator renders RealityKit content that the device
> does not.** Simulator screenshots are never proof for spatial work.
> Every spatial change is verified on a physical Vision Pro before it
> is built upon or merged.

## Architecture in one paragraph per platform

**macOS** — `AppModel` (one `@MainActor @Observable` model) owns the
EPUB shelf: books unpack once into the app container, are remembered as
`EPUBRecord`s, and are re-imported as structured `LiquidDoc`s into
`LibraryIndex`, which every view and view module reads. The reader has
a faithful WebView mode and native reading styles; annotations are W3C
Web Annotations in JSON-LD sidecars (`AnnotationStore`), anchored by a
Hypothesis-style fuzzy cascade; every copy-to-cite puts pure BibTeX on
the clipboard. Sidebar "Views" are single-file **view modules**
(`LibraryViewModule.swift` documents the contract) shared with the
Knowledge Space app.

**visionOS** — `VisionModel` mirrors the shelf: it imports EPUBs from
the shared iCloud community folder (the Mac publishes its whole shelf
there — `mirrorShelfToCommunityFolder`), so both platforms show the
same journals and articles. The opening panel lists Journals and
Articles; tapping a journal fills the room with its articles as cards
on the **Map** (`EPUBMapView`), cited works standing a level behind,
ember citation lines on selection. Double-tap opens the reader (which
carries the Mac's core reading controls); the card leaves the Map while
its window is open. Settings and Documents ride the right forearm.

## Formats (the real API surface)

- **Origami EPUB**: a standard EPUB 3 plus `visual-meta.json` — the
  document's structure, concepts, citations (verbatim BibTeX), spatial
  map views, and live tables. See the format spec.
- **Annotations**: W3C Web Annotation Data Model, JSON-LD sidecars, one
  per book, in the app container's `Annotations/` — never inside the
  book. Fragment/TextQuote/TextPosition/Progression selectors.
- **Spatial arrangements**: persisted as Visual-Meta `map` views
  (`SpatialLayoutStore`) — byte-compatible with what the EPUB exporter
  writes and Author reads.

Changes to any of these formats need the spec document updated in the
same commit.

## Working rules

1. **Build both platforms before pushing** — scheme LiquidView (My Mac)
   and Origami Text Vision. Shared files break the other platform more
   often than you'd think.
2. **Never replace a working interaction with a rewrite; layer beside
   it.** Keep the old path one line away until the new one is proven.
3. **Verify spatial work on the device**, not the simulator (see above).
4. Comment in the codebase's voice: full sentences explaining *why*,
   not what. Keep the existing style — 4-space indents, one type system,
   no Combine (async/await instead).
5. UI text follows the app's register: quiet, concrete, no jargon.
6. New reader-facing options are never hidden conditionally.

## Getting a change in

Small fixes: branch, build both platforms, push, PR against `main`.
New library views: write a view module (see the recipe in
`LibraryViewModule.swift` or Settings ▸ View Modules ▸ Create Your Own
View) — one file, one registry line. Anything spatial: talk first,
device-verify always.

Questions: frode@hegland.com — or open an issue.
