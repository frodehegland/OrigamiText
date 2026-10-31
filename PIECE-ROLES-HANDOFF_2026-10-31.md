# Handoff to Author: say what each piece of a volume is (31 October 2026)

From Origami Text, for Author Claude. This adds one field to the Binding Profile (see RELATIONS_AND_SERIES_HANDOFF_2026-10-28.md §4).

## The problem

Origami Text now shows a volume on the headset as three zones: its **Opening** pages, its **Articles**, and its **Appendices & Records**. Today the binding only says whether a piece has a byline. A piece with Contributing Authors becomes a `works[]` entry. One without becomes `matter[]`, with `role` set to `"front"` before the first work and `"back"` after it.

That test is wrong both ways in all six Future of Text volumes:

- **Articles exported as matter.** Their author line was typed as text, not as a byline.
  - Vol 4 "Textual Affordances in VR & XR" (Peter J. Wasilko)
  - Vol 4 "The Fidelity of Text" (Michael Bonfert)
- **Opening pages exported as works.** They carry a name.
  - Foreword (Serageldin, Vint Cerf), Preface, Welcome, Dedication
  - "Introduction : …"
- **Closing pages exported as works.**
  - Afterword, "In Closing : …", Colophon (Vol 3)
  - History of Text Timeline
  - most "Appendix : …" pieces
- **Part titles exported as matter.** Vol 1 "ARTICLES" (2 words) and "STUDENT COMPETITION Winner" are headings, not readings.
- **Anything mid-book becomes "back".** Vol 1 "Symbol Manipulation" and "INTRODUCTION" sit between the Preface and the Foreword.

Origami Text now infers the roles from titles, length, the line under the title and position. On these six volumes it gets them right, but it is a guess. Author knows the answer when it writes the volume.

## The ask

Write a `role` on **every** `document.binding.works[]` entry and **every** `matter[]` entry. Use EPUB's structural vocabulary, the same words as `epub:type`:

| role | for |
|---|---|
| `article` | a contribution (the default for a work) |
| `titlepage`, `dedication`, `epigraph`, `acknowledgments`, `foreword`, `preface`, `introduction`, `prologue` | opening pages |
| `part` | a part's title page: a heading with nothing under it |
| `collection` | many voices in one piece (Graffiti Wall, competition entries) |
| `afterword`, `epilogue`, `conclusion`, `contributors`, `timeline`, `transcript`, `colophon` | closing pages and records |
| `appendix` | an appendix |

For `matter[]`, `"front"` and `"back"` stay valid. A richer word replaces them, and readers that know only front and back still read the piece where it stands.

Also put the same word on the piece's own section as `epub:type` (for example `<section epub:type="foreword">`, `"appendix"`, `"part"`), so any EPUB reader knows it.

How Author could choose the role:
- **A heading menu item.** ⌘-click the heading ▸ **Role ▸ …**, beside Abstract.
- **A sensible default.** "Appendix …" gives `appendix`; Foreword, Preface, Introduction and Welcome give their own words; a heading with no text under it gives `part`; anything with Contributing Authors gives `article`.
- **A byline found in the text.** When a level 1 heading has no Contributing Authors but its first line is only names ("Peter J. Wasilko"), offer to make that line its byline.

## What Origami Text does with it

- A declared `role` always wins. Inference covers older exports only.
- The reader can still correct any piece on the headset: a selected card ▸ **Kind**. Corrections are kept beside the annotations (`piece-kinds.json`, by book folder, then piece id).
- Every article of every volume in a series (joined by `series.id`) is indexed on the device for the headset assistant, using the bge-small model from LiquidKit's KnowledgeIndex. Correct roles keep forewords and timelines out of "which articles are like this one?".
