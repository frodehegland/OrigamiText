# Context Panel — Plan

*Origami Text, 4 October 2026. A plan only: nothing here is built. The
icon that appears on a selection and the pop-around menu (Context,
Annotate, …) are Frode's design; this plan supplies what sits behind them.*

## Status, 5 October 2026

- **Decided:** results are kept as an **annotation** on the selection;
  the **one-line quick answer** shows at the top of the dot's menu; on
  **Vision Pro** the same chrome dot stands on the page and Context opens
  a **floating window**.
- **Built (stage A, plus G's dot on Mac and Vision Pro):** `ContextQuery`
  and its classifier, `ContextPaperFindings` (uses, first/last, the
  paper's glossary, the cited reference, figure captions and mentions,
  symbol definitions, identifiers) and the quick answer, all in
  `OrigamiReading.swift`, shared by every platform. Mac panel: kind
  label, the new sections, Keep. Vision Pro: dot over the selection
  (`VisionSelectableParagraph.onSelection`), menu (Context, Highlight,
  Note…, Cite, Lift), `VisionContextPanel` hung beside the dot on the
  reading itself (a separate window cannot be placed by the dot), with paper, notes, library,
  Keep. The provider protocol (§7) is not yet split out; rings 2 to 4
  follow the plan below.

## 1. What it is for

A reader selects anything in a paper — a word, a name, a claim, a number,
a citation — and gets, without leaving the page, what is known about it:

1. **in this paper**,
2. **in their own library**,
3. **in the scholarly record**,
4. (later) **in downloaded corpora**.

Nearest first, sources always named, nothing invented. It is Liquid's
"select, then act" idea applied to research reading.

## 2. Four layers, kept apart

| Layer | Owner | What it does |
| --- | --- | --- |
| **Trigger** | Frode's design | The icon that appears on a selection; the pop-around menu (Context, Annotate, Cite, Find…). |
| **Query** | Engine | Turns the selection into a `ContextQuery`: the words, where they are, and what kind of thing they look like. |
| **Providers** | Engine | Answer the query, each from one source, as a stream of `ContextResult`s. |
| **Panel** | Shared | Shows the results, grouped by ring, as they arrive. |

The trigger never talks to providers directly: it asks for a query, then
opens the panel with it. So the icon and menu can change freely without
touching the engine, and the same engine serves the Mac, iPhone and
Vision Pro.

### What the trigger needs from the engine

- `ContextQuery.make(from: selection, in: document)`: cheap and offline,
  ready by the time the icon appears.
- `query.kind` and `query.hints`, so the icon or menu can show what the
  selection is (a name, a citation, a claim…) before anything is
  fetched.
- `ContextActions.actions(for: .selection(…))`, the existing shared action
  list. "Context" becomes one more action in it. The pop-around menu
  renders that list, as the ctrl-click menus already do.
- `query.quickAnswer`: the one-line answer Ring 1 can give instantly (a
  glossary definition, "cited 3 times in this paper"). It can appear on or
  beside the icon, if the design wants it.

## 3. The query

Built from the selection both readers already produce (`ReaderSelection`:
text, paragraph fragment, prefix, suffix, glossary target, page).

```
ContextQuery
  text            the selected words
  document        the open paper (LiquidDoc)
  paragraphID     where it is
  sentence        the full sentence around it
  kind            term | name | citation | claim | number | identifier |
                  symbol | figureOrTable | passage
  hints           e.g. glossary entry id, citation key, DOI found, unit
```

How `kind` is decided, offline and in order:

1. **Citation:** the selection covers a `[cite:]` token.
2. **Identifier:** the words are a DOI, URL, arXiv id or ISBN.
3. **Figure or table:** the words read "Figure 3", "Table 2", "Eq. 4".
4. **Name:** a person, place or organisation the library or the paper's
   extraction knows.
5. **Number:** a number with or without a unit ("N ≈ 20,000", "3.2 ms").
6. **Symbol:** a short token inside or near maths ("α", "k").
7. **Term:** one to five words; a glossary or keyword match strengthens it.
8. **Claim:** a whole sentence, or one with claim words ("we show",
   "results indicate", "significantly").
9. **Passage:** anything longer.

## 4. The rings and their providers

Each provider answers some query kinds; the panel asks only the ones that
apply. Everything named "exists" is already in the app and needs only
wiring.

### Ring 1: this paper (offline, instant)

| Provider | Answers | Source |
| --- | --- | --- |
| Definition | term | Paper's glossary (exists: Show Definition) |
| Uses | term, name | First and last use, every place in the paper (exists: `firstAndLastUse`, book search) |
| Citation | citation | The citation card: abstract, marks, Acquire (exists) |
| Referenced item | figure/table | The figure or table itself, and every place it is discussed |
| Symbol | symbol | Where the paper defines it (the first "where k is…") |
| AI reading | any | What the paper's AI summary says about it, quoted (exists: summary results) |

### Ring 2: your library (offline)

| Provider | Answers | Source |
| --- | --- | --- |
| Library passages | term, claim, passage | Other papers that discuss it (exists: Ask the Library's search; meaning-based search later) |
| Cited Here | citation, passage | Other library papers citing this passage (exists) |
| Your notes | any | Your highlights and comments on the same words, in any book (exists: annotation sidecars) |
| People | name | The person's profile, their papers on the shelf (exists: People) |
| Personal glossary | term | Your own definition, if you've written one (exists) |
| Reference standing | citation | The work's pills: Retracted, Preprint, Foundational… (exists: ReferenceStatus) |

### Ring 3: the scholarly record (online, only when asked)

| Provider | Answers | Source | Cost |
| --- | --- | --- | --- |
| Who else says this | claim, passage | Semantic Scholar snippet search: passages from 12M+ open-access papers | Free; unreliable on the shared tier |
| Related works | term, claim | OpenAlex semantic and full-text search | Needs a key; about $1 per 1,000 searches |
| Work lookup | identifier, citation | Crossref, DataCite, OpenAlex record (exists: CitationLookup) | Free |
| Concept | term | Wikidata and Wikipedia summary | Free |
| Person | name | ORCID, OpenAlex author, Wikipedia (exists in part: People) | Free |
| Number check | number | Units and constants (CODATA); the value in the cited source, when the sentence cites one | Free |

### Ring 4: downloaded corpora (offline, later)

Field packs cut from the OpenAlex snapshot (section 9), loaded through the
Reference Datasets layer, so Ring 3's "related works" can answer offline
for the reader's own field.

### The AI layer (across rings)

One optional row: **"Explain in context"**. The model (via OrigamiLLM, so
your Ollama setup applies) is given the sentence, the paragraph, and the
Ring 1 and Ring 2 results, and asked what the selection means here.

The rule, as in the AI summary: every claim it makes must quote a source
from the results, the quote is checked verbatim, and anything that can't
be is dropped.

## 5. Claim Check (a mode of the panel)

When `kind` is `claim`, the panel offers **Check this claim**:

1. **Gather:** library passages (Ring 2), plus Semantic Scholar snippets
   and OpenAlex searches (Ring 3).
2. **Classify each passage:** the model sorts it into *supports*,
   *contradicts*, *refines* or *unrelated*, and must quote the words that
   decide it.
3. **Verify:** quotes are checked against the source text; anything that
   fails is dropped.
4. **Show** the passages in three columns, each with source, year and its
   reference pills, so a retracted source is visible as such.

The result can be kept as a linked document, never a hidden cache, in
keeping with how summaries work.

## 6. The panel

- **Where:** a side column beside the reading. It's the same pattern as
  Column View, and keeps the paper visible. Whether it's a column, a
  popover by the selection, or both is a design question (section 11).
- **Order:** Ring 1 first; then rings 2, 3 and 4 as they answer. Local
  results within about 100 ms; online ones stream in with their source
  shown while waiting.
- **Each result row:** title or words; a two-line excerpt with the match
  in bold; source and date; its pills when it's a work; actions (Open,
  Cite, Keep, Annotate).
- **Keyboard:** each section and row can be reached by single letters,
  the Liquid way; Return opens, ⌘-Return keeps.
- **Keep:** any result, or the whole panel, can be kept as a linked
  document or attached to the selection as an annotation. That joins the
  pop-around menu's Annotate.
- **Empty rings say so** ("Nothing in your library"), rather than hiding,
  so the reader knows what was searched.

## 7. Data model

```
ContextQuery     as section 3
ContextResult
  ring           paper | library | record | corpus | ai
  provider       id and display name
  kind           definition | use | work | passage | person | note | concept | number
  title, excerpt, matchRanges
  source, date, url or library address
  quote          the verbatim words, for anything the AI says
  marks          reference pills, when a work
ContextProvider  protocol
  answers(kind) -> Bool
  results(for: query) -> AsyncStream<ContextResult>
  isLocal, needsKey, sendsText (what leaves the Mac)
```

- **Cache:** per query (text plus document) for the session; online
  answers kept on disk as the citation lookups are, misses included.
- **Cancellation:** a new selection cancels the old query's streams.

## 8. Rules

- **Nothing goes online at launch, and nothing prompts.** Online providers
  run only when the panel is opened.
- **What leaves the Mac is visible:** each online provider says it will
  send the selected words. Settings has a switch for each provider, and
  "Local only" turns off rings 3 and 4.
- **Keys are read from the Keychain only when used.**
- **Sources always named:** no result appears without its source and date.
- **The AI never stands alone:** every AI line carries its verified quote.

## 9. Building it, in stages

| Stage | Contents | Depends on |
| --- | --- | --- |
| A | `ContextQuery` and classification; the provider protocol; the panel; Ring 1 providers. Wired to a plain "Context" item in the existing context menu, so it can be tried before the icon exists. | Nothing |
| B | Ring 2 providers (library passages, Cited Here, notes, people, standing). Keep as document or annotation. | A |
| C | Ring 3 providers (Wikidata/Wikipedia, Crossref/DataCite, OpenAlex, S2 snippets), each with its switch. | A |
| D | Claim Check. "Explain in context" with verified quotes. | B, C |
| E | Meaning-based library search (Ollama or on-device embeddings), replacing keyword overlap in Ring 2 and in Ask the Library. | B |
| F | Field packs from the OpenAlex snapshot (Ring 4). | C |
| G | Frode's icon and pop-around menu, connected to the hooks in section 2. iPhone and Vision Pro versions. | Design |

Stage A stands alone and is the place to start. Stages B and C can be
built side by side.

## 10. What exists to reuse

- **Selection:** both readers produce a selection (`ReaderSelection`)
  with text, paragraph, prefix and suffix.
- **Action list:** `ContextActions` is the shared list every menu renders.
- **This paper:** the glossary, the AI summary, `firstAndLastUse` and the
  book search.
- **Works:** `CitationCardSheet`, `CitationLookup`, `CitationGraph` and
  `ReferenceStatus` with its pills.
- **Library:** Ask the Library's passage search, Cited Here, the
  annotation sidecars, People, the personal glossary.
- **AI and reading:** OrigamiLLM for every model call; Column View's side
  column and its Scroll reader for landing on a passage.

## 11. Questions for the design

1. **When does the icon appear:** on every selection, after a pause, or
   only with a modifier key?
2. **The menu's order:** Context first? Is Annotate one item or a group
   (highlight, comment, link)?
3. **Panel form:** a side column, a popover by the selection, or both
   (popover for the quick answer, column for everything)?
4. **The quick answer:** should the one-line Ring 1 answer show on the
   icon or menu before anything is opened?
5. **Keeping results:** as a linked document, an annotation on the
   selection, or both?
6. **Vision Pro:** the wrist chips, or a spatial card beside the page?
