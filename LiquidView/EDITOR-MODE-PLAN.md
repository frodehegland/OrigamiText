# Editor Mode — correcting an EPUB safely

*Plan, 9 September 2026. An Admin capability for Editors (macOS only),
never shown to end users. The goal: when review finds a mistake in a
converted EPUB, an Editor can fix it, export the corrected edition as a
separate file, review it, and only then adopt it for distribution —
with the original always recoverable.*

## 1. The safety principles

1. **The shelf copy is never edited in place.** An edit session works
   on an in-memory copy of the document; nothing on disk changes until
   an explicit export or adopt.
2. **Export and adopt are different acts.** Export writes a separate
   `(edited)` file for review, touching neither the shelf nor the
   community folder. Adopt — a second, deliberate step — replaces the
   distributed copy.
3. **The identity survives; the edition is marked.** The document keeps
   its `origami-id` (so annotations, citations and Map positions keep
   resolving — the intro-guide precedent) and its DOI; Visual-Meta
   gains `revision` (2, 3, …) and `revised` (ISO date), so an edited
   edition is never mistaken for the publisher's conversion.
4. **The original is kept before it is replaced.** Adopt first files
   the outgoing .epub under `EPUBs/Editions/<id>/` with a dated name,
   beside an edit log (which blocks changed, when). Recovery is a copy
   back, not an apology.
5. **The exporter's guards gate everything.** Well-formed XML and
   zero dangling anchors are already refusal conditions at export; an
   edition that breaks either simply does not get written.
6. **Editing is invisible to end users.** A single "Editor Mode"
   toggle in Settings (macOS), default off. iOS and visionOS never see
   any of it. (The no-hidden-options rule bends here by design: this is
   the one capability that is explicitly not for readers.)

## 2. The Editor's flow

1. Settings ▸ turn on **Editor Mode**.
2. Right-click a book ▸ **Edit Document…** (present only in Editor
   Mode) → the Editor window opens on a working copy, loaded through
   the same structured import the index uses — the Editor sees exactly
   what readers see.
3. Fix the mistake:
   - **Paragraph text** (including headings, figure captions, notes):
     click a block, edit in place, the block's stable id unchanged.
   - **Heading level**: a stepper beside an editing heading.
   - **References**: each entry's BibTeX editable as text, re-parsed
     on the spot (a broken record refuses to save); order and numbers
     recompute at export by the printed-order rules.
   - **Table cells**: edit in the grid.
   - **Insert / delete a block** (conversion glitches leave both
     needs); a new block gets a fresh stable id, never a reused one.
   - Every change lands in the session's change list (visible, with
     undo); nothing else records until export.
4. **Preview** renders the working copy in the normal reading view,
   in-window — no import, no shelf entry, no duplicate.
5. **Export Edited EPUB…** writes `<name> (edited).epub` wherever the
   Editor chooses, revision bumped, both exporter guards enforced. This
   file can travel — to another reviewer, another reader, Apple Books.
6. **Adopt Edition** (in the Editor, or by re-importing the reviewed
   `(edited)` file back onto its book):
   - files the outgoing original under `EPUBs/Editions/<id>/` with the
     edit log;
   - writes the new .epub under the book's **original filename** into
     the canonical store, refreshes the unpacked copy, keeps the same
     shelf record (same id, same folder);
   - republishes to the community folder under the same name — every
     device refreshes in place through the existing newer-file rule; no
     supersession dance, no duplicate rows, annotations intact.

## 3. What the format already gives us

- `LiquidDoc` is the whole document; `OrigamiEPUBImporter` proves the
  round trip daily. The Editor is a view over a `LiquidDoc`, not a new
  format surface.
- Paragraph stable ids anchor annotations; keeping them through edits
  is what makes in-place correction safe. Purple numbers and citation
  `[n]`s recompute at export — that is their design.
- `OrigamiEPUBExporter.write` already refuses malformed XML and
  dangling anchors; adopt re-imports what it wrote, which is a free
  round-trip check.
- The refresh-by-newer-file rule in every platform's `importEPUB` is
  the distribution mechanism; nothing new to build there.

## 4. Build order (when approved)

1. `EditorSession` (@Observable, macOS): working `LiquidDoc`, source
   record, change list, undo; `beginEdit(record)` on AppModel.
2. `DocumentEditorView`: block list with in-place editing, references
   pane, tables grid, change list sidebar; Preview via the existing
   native reading view on the session's doc.
3. Export path: revision bump into Visual-Meta document info
   (`revision`, `revised` — additive keys the importer tolerates),
   `(edited)` filename, exporter guards.
4. Adopt path: backup + edit log to `EPUBs/Editions/<id>/`, canonical
   replace under the original name, unpack refresh, mirror.
5. Settings toggle + `Edit Document…` menu entry, gated.
6. Verification: edit one block of a real paper → export → re-import →
   assert one changed block, same ids elsewhere, annotations preserved
   on a book that has them, revision == 2 in Visual-Meta, both guards
   green; adopt → shelf and community byte-identical, record id
   unchanged.

## 5. Out of scope for v1

- Editing on iOS/visionOS (Editors work at a Mac).
- Multi-editor conflict handling (one editor at a time).
- Image replacement (captions yes, pixels later).
- Math editing beyond plain-text TeX in a block.
- Any change to how *readers'* annotations work — Editor Mode touches
  the book, never the reader's sidecars.
