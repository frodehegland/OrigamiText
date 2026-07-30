# Origami Text Reader — Feature Roadmap

**Status:** planning · **Scope:** the macOS reader (`LiquidView` target) · **Date:** 2026‑07‑30

This orders the candidate reading interactions by leverage, grounded in what the
Origami Text format carries and what the codebase already has. The test applied to
every candidate: *does this interaction become possible only because the document now
carries its own semantics?* Anything a good PDF reader already does is table stakes,
not a priority.

## The reframe that sets the order

Origami Text now reads EPUBs by rendering the EPUB's own `paper.html` in a
`WKWebView` (`EPUBReaderView`/`EPUBReaderScreen`). It is **not** re‑rendering the body
through a native, element‑addressed model. Almost every feature below assumes a surface
where the app owns each element by id — so in a WebView the app owns nothing until we
build a bridge.

The good news: the addressing those features need is already in the page. Author writes
`id="1B"` and `data-id="<uuid>"` on every element, and `OrigamiEPUBImport` already parses
the Visual‑Meta into typed Swift — paragraphs with ids, `links` (rel/fragment/**span**/
bibtex), `concepts` (glossary), `layouts`+`mapConnections` (xyz map), `references`
(CSL/BibTeX), `tables` (live `LATable`), and `equations` (`OrigamiMath`). The semantics
exist on both sides; they are simply not wired to each other.

## Step 0 — The semantic bridge (enabler, not on the original list)

Inject the parsed element‑id/type map into the page and add a `WKScriptMessageHandler`,
so selection, tap, and detail‑level round‑trip between the WebView and Swift. Nothing
below can happen in the current EPUB reader until this exists. It is the precondition for
steps 1, 2, 3, the live‑figures work, and the AI‑operating‑controls end state.

## Ordered features

**1. View specification (furl/unfurl) — start here.** A continuous, always‑live control
over how much document shows: headings only → first sentence per paragraph → full text →
full text plus annotations. Highest leverage and cheap in a WebView — toggle CSS classes
per element id; `structure.headings` already gives the outline. The only new logic is
"first sentence per paragraph" (sentence segmentation). Everything else rides on this.
*Lineage: Engelbart's ViewSpecs, NLS 1968; the furl/unfurl primitive.*

**2. Stretchtext for citations — second.** One gesture, four depths: marker → full
reference → abstract/your note → the cited passage itself, expanding **in place** so the
reader never leaves the sentence. `links` already carry BibTeX plus the fragment and the
exact quoted **span** for internal citations; `references` carry CSL/abstract for external
ones — the four depths map almost one‑to‑one onto what the format gives us. *Lineage:
Nelson.*

**3. Select‑and‑act, made semantic — the signature.** Selection is the universal noun;
now the verbs can be correct because the document says what each element is. Select an
equation → solve/plot/vary; a citation → retrieve/cite/show‑every‑other‑use; a name →
their other work. We already have `ContextActions` natively; the new piece is routing a
WebView selection to its id + type, then showing the right verbs. *Lineage: the Liquid/
Flow move, with a document that finally knows what it is.*

**Early differentiator — No dead figures (start with tables).** Equations already render
live (WebKit MathML); tables are already backed by `LATable` with a working formula
evaluator, so an editable table / table‑to‑chart is most of the way there. Equation
solve/plot/vary needs a math engine (large); "figure carries its underlying data" needs a
**format addition** (no home in the spec yet) — both come later. *Lineage: Kay's dynamic
medium; Victor's explorable explanations.*

**In parallel — Trails, by retargeting what exists.** `TrailsView` already captures and
persists paths, but against the library rather than element‑anchored EPUB reading. The
work is retargeting capture to element ids and adding export‑as‑a‑trail (a `.epub` you
send a colleague — the path you took, not a reading list). *Lineage: Bush, 1945.*

## Later (kept in leverage order, deferred by dependency or cost)

- **Reference view — the citation graph inside the document.** Feasible from parsed
  `links`/CSL. Note `DocumentWebView` already does this *across the library*; this is the
  *within‑document* variant. *Lineage: Victor; Nelson's parallel pages.*
- **Annotations that survive revision.** New storage keyed to the stable `data-id`
  UUIDs; "survive revision" means re‑anchoring by `data-id` across two EPUB versions.
  Precondition for the document as external cognition. *Lineage: Clark & Chalmers.*
- **Reading as making — extraction into the spatial surround.** We have
  `KnowledgeSpaceView`/`GlossarySpaceView` and `liftExtract`; the new piece is a live
  provenance link from a pulled‑out node back to its source element id. This is the
  Reader↔Author seam. *Lineage: Marshall & Shipman; Kirsh & Maglio.*
- **Dimensional views (zzStructure).** `ZZStructure`/`ZigZagView`/`ZView` exist but are
  library‑scoped; "only what I marked disagree" depends on annotations. *Lineage: Eric's
  zzStructure.*
- **The AI operating the document's own controls.** The co‑agent furls/selects/expands/
  places through the same Command type, visibly and undoably, every claim anchored to an
  element id. Strictly downstream of 1–3. On‑device `FoundationModels` is already used
  elsewhere. *Lineage: Millard's "same view and controls."*

## Two cautions

- Several features are **built but disconnected**: Weave, the citation graph, glossary‑
  space, trails, and zzStructure were built for the JSON library/community index, which
  the EPUB‑only pivot switched off. The task is usually *reconnecting them to per‑EPUB
  Visual‑Meta*, not greenfield.
- "Figure carries its underlying data" has **no home in the format yet** — it is an
  Author‑side spec addition, not a reader feature we can ship today.
