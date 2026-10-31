# Reply from Author: piece roles are in (31 October 2026)

This answers PIECE-ROLES-HANDOFF_2026-10-31.md. It is built in AuthorKit **42f7c6b** (pushed) and Author **7b2be71a**. An export from this build onwards has roles. Earlier exports do not, so Origami Text still needs its inference for them.

## What the record now says

Every `document.binding.works[]` entry and every `matter[]` entry has a `role` taken from your table:

- `article`, `collection`
- the opening words: `titlepage`, `dedication`, `epigraph`, `acknowledgments`, `foreword`, `preface`, `introduction`, `prologue`
- `part`
- the closing words: `afterword`, `epilogue`, `conclusion`, `contributors`, `timeline`, `transcript`, `colophon`
- `appendix`

Author picks the role by the first of these rules that applies:

1. **Declared.** The writer chose it with ⌘-click on a level 1 heading ▸ **Role**.
2. **The title.** "Appendix …", Foreword, Preface, Introduction, Welcome, In Closing, Colophon, "… Timeline" and so on.
3. **Otherwise:**
   - a work is `article`;
   - a matter heading with nothing under it is `part`;
   - any other matter is still **`front` or `back`**, by where it stands.

So `front` and `back` still appear, but only for matter Author knows nothing about. Treat those as "unknown, use inference". Don't read them as a decision the writer made.

A role does **not** move a piece between `works[]` and `matter[]`. That is still decided by whether it has Contributing Authors. A Foreword with a byline is a `works[]` entry with `role: "foreword"`. An article with no byline is a `matter[]` entry with `role: "article"`. Use `role` for the three zones, not the array it sits in.

## What the content says, and where it differs from the ask

The ask was to put "the same word" on the section as `epub:type`. Author does this, but only with standard semantics, to keep to the Origami EPUB profile §1.3 and §1.6–1.7:

- Each section gets the **nearest EPUB Structural Semantics word** as `epub:type`. Most roles map to themselves. Four have no SSV word:
  - `article` and `collection` become `chapter`;
  - `timeline` and `transcript` become `appendix`.
- Each section also gets a **DPUB-ARIA `role`** where one exists. For example, a foreword gets `doc-foreword`. `titlepage` and `contributors` get no ARIA role.
- There is **no `data-origami-role`** or any other Origami attribute for this in the text.

**The record governs.** The exact word lives only in `visual-meta.json`. `epub:type` is a lossy, standard copy of it, and the equivalence rule is the mapping above. Where the two disagree, read the record. Read the section's `epub:type` only when the record has no role, as with another tool's EPUB.

## The byline offer

Take a level 1 heading with no Contributing Authors whose first line is only names, such as "Peter J. Wasilko". Author's heading editor now shows **Make "…" the Byline** for it. Accepting it does two things:

- the names become the heading's Contributing Authors;
- the typed line is removed, so the name prints once.

After a re-export, the Vol 4 pieces you named (Wasilko, Bonfert) arrive as `works[]` entries with `role: "article"` and proper authors.

## One question back

Work sections still carry `data-origami-work="urn:uuid:…"`. The Binding Profile defines it, but the Origami EPUB profile's `data-*` registry does not list it. Should the profile register it, or should readers rely on the record's `works[].href`/`section` and Author drop it? Author will follow whatever Origami Text decides.

## Still to do on the Author side

Re-export The Future of Text Vols 1–6 with roles checked. The named pieces need Role set, or the byline accepted, wherever Automatic gets them wrong.
