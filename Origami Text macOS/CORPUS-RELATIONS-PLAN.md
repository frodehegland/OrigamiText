# Corpus Relations — pre-baked connections for a published corpus

1 Nov 2026. **Part 1 is built:** the facts (rows 1–5 and 13), the bake's steps 1–3, the Mac window, and the headset's citation cards. See rebuild guide §5.19. Parts 2 onward (embeddings, themes, claims, stance, review) are still to come.

**What part 1 found in the books:**
- Each volume carries every endnote of the volume before.
- Vol 3 repeats Vol 2's bibliography.
- About 500 of the volumes' own endnotes have no call site in any article.
- So 692 of the 1,156 citations can only stand for their volume, not an article.
- Part 2 could attribute those by similarity, marked AI. The first corpus is The Future of Text, Vols 1–6. It has 383 pieces, 735 bibliography entries (209 with DOIs), and the cited-works master list already holds 1,133 works.

## Why pre-bake

The corpus is published and does not change, so everything worth knowing about it can be worked out once, on the Mac, with time and a local model. The headset then only reads a file. That is better for three reasons:

- **Quality.** It allows slow, careful passes: Crossref and OpenAlex lookups, a real embedding model, and LLM stance checks with quoted evidence.
- **The render budget.** The headset does no analysis at all, and the relations decide which few cards to raise. It never has to raise all of them; the series room has already shown it has no headroom.
- **Review.** Frode can check an inferred relation before it is published.

## What an academic reader wants to see

These are ordered from fact to inference. Every relation carries how it was found, so the reader always knows which kind they are looking at.

| # | Relation | Question it answers | How it is found | Kind |
|---|---|---|---|---|
| 1 | **Cites / cited by (inside the corpus)** | Who in the series builds on this piece? | Bibliography, endnotes and in-text titles matched to corpus pieces | Fact |
| 2 | **Cites (outside the corpus)** | What does it stand on? Shown as small cards. | References resolved to DOIs, then the master list (year, venue, cited-by count, open access, retraction) | Fact |
| 3 | **The series' canon** | Which outside works does the whole series keep returning to? | How often each work is cited, counted across the corpus | Fact (counted) |
| 4 | **Shares sources** (bibliographic coupling) | Who draws on the same literature? | Two pieces citing the same works, weighted by rarity | Fact (counted) |
| 5 | **Cited together** (co-citation) | Which outside works belong to one conversation? | Two works cited by the same pieces | Fact (counted) |
| 6 | **Similar** | What else is like this? | Embedding nearness of abstract and body, top 5–8 with scores | Inference (numeric) |
| 7 | **Themes** | What are the series' threads, and how do they move from volume to volume? | Clusters of the embeddings, named by the LLM, with members and the volumes they span | Inference |
| 8 | **Shared concepts / people** | Who else uses this term? Who else talks about Engelbart? | Defined Concepts, keywords, named people and named works (e.g. "As We May Think" without a formal reference) | Fact (matched) |
| 9 | **Same author elsewhere** | How did this person's thinking develop? | Normalised author names across volumes (`SeriesAuthorRank`) | Fact |
| 10 | **Agrees / extends / responds to** | Who takes this further? | LLM over each piece's claims, for similar pairs only, with quotes from both | Inference, reviewable |
| 11 | **Disagrees / questions** | Who would argue with this? | Same as row 10, but needs both quotes and a stated point of difference; never shown without evidence | Inference, reviewable |
| 12 | **Why it is cited** (citation function) | Background, method, critique, or example? | LLM over the citing sentence (SciCite / CiTO style) | Inference |
| 13 | **Outside standing** of a cited work | Is this source contested out in the world? | Existing scite tallies (supporting/contrasting/mentioning), Retraction Watch | Fact (third party) |

The vocabulary should follow **CiTO**, the Citation Typing Ontology: cites, extends, supports, disputes, agreesWith, disagreesWith, usesMethodIn, citesAsAuthority and so on. `DocumentRelation.swift` already has most of these, so the file stays readable by other tools.

## What the corpus actually offers today

- **Citations are thin inside the corpus.** Only 0–5 references per volume name The Future of Text. Only one reference carries a `vm-id`. So rows 6–11 carry most of the value, and row 1 must also count title mentions in the body.
- **References are pooled.** In Vols 1 and 3 most bibliography entries sit in `back.html`, and endnotes are almost all there too (Vol 6: 813 of 830). Each entry must be traced back to the article whose note marker calls it. Until then, rows 2–5 and 12 undercount badly. This is the first job, and it belongs in Author's binding as well (each work's `resources.references`).
- **Abstracts now exist for 379 of 383 pieces** (328 of them AI-written). That is enough to embed.
- **The embedding is weaker than it looks.** `SeriesIndex` names bge-small, but the app does not link KnowledgeIndex, so it falls back to Apple's `NLEmbedding`. The bake should use a real model on the Mac (bge-small or nomic-embed through Ollama).
- **Agreements and Disagreements are thrown away.** `AgreementsView` and `DisagreementsView` already ask the LLM, but the results live only in `@State`. They should read from and write to this file instead.

## The file

`origami-corpus-relations.json` sits beside `origami-article-metadata.json`. It is published to the community folder, the headset adopts it through `adoptStanding`, and it is keyed by series id and then by book folder and work id. It goes beside the EPUBs, never inside them, so a rebuilt volume keeps its relations.

```json
{
  "format": "origami-corpus-relations", "version": 1,
  "series": "urn:uuid:3F19824A…", "built": "2026-11-…",
  "pieces":   { "<folder>#<work>": { "title": "…", "volume": 3, "year": 2022, "textHash": "…" } },
  "external": { "doi:10.…": { "title": "…", "year": 1945, "citedByCorpus": 14 } },
  "edges": [
    { "from": "<folder>#<work>", "to": "doi:10.…", "type": "cites",
      "function": "citesAsAuthority",
      "evidence": [{ "paragraph": "p41", "quote": "…" }],
      "source": "endnote", "confidence": 1.0 },
    { "from": "…", "to": "…", "type": "disagreesWith",
      "evidence": [{ "side": "from", "paragraph": "p12", "quote": "…" },
                   { "side": "to",   "paragraph": "p7",  "quote": "…" }],
      "point": "Whether links should be typed by the author or the reader",
      "source": "llm · llama3.1:8b", "confidence": 0.7,
      "review": "unreviewed" }
  ],
  "themes": [ { "id": "t3", "label": "Typed links", "keywords": ["…"],
                "members": [{ "piece": "…", "weight": 0.82 }], "volumes": [1, 3, 5] } ],
  "claims": { "<folder>#<work>": [ { "id": "c1", "text": "…", "paragraph": "p9" } ] }
}
```

The rules:

- **Edges carry no layout.** The headset decides where things stand.
- **Similarity is stored as top-k neighbours with scores, not raw vectors**, so the file stays small. Vectors may come later if search on the headset wants them.
- **`review`** is one of `unreviewed`, `confirmed` or `rejected`. Rejected edges are kept, so a rebuild never brings them back.
- **`textHash` makes the bake incremental**, as `ArticleEnrichment` already is.

## The bake (Mac, a pass like Build Article Metadata)

1. **Attribute references.** Trace `back.html` notes and bibliography entries back to the article that calls them, and match title mentions in the body to corpus pieces.
2. **Resolve them.** Reuse CitationLookup and the cited-works master list for DOIs, outside facts, scite and retractions.
3. **Count.** Canon, coupling and co-citation are arithmetic, with no model involved.
4. **Embed.** A real model over the abstract plus body chunks, then top-k neighbours and clusters. The LLM names each cluster.
5. **Extract claims.** 3–5 claims per piece, each with its paragraph id (383 LLM calls).
6. **Judge stance.** Only for pairs that are similar or share a theme (about 8 per piece, roughly 1,500 calls). The answer must quote both sides or it is dropped.
7. **Find citation function.** One call per citing sentence that has a resolved target.
8. **Review on the Mac.** A list of unreviewed agree/disagree edges, each with its two quotes and Confirm / Reject.

Steps 1–4 take minutes. Steps 5–7 take hours on local Ollama, and resume after a stop.

## How the headset shows it

- **A chosen article's verbs** become Related ▸ Cites · Cited by · Shares sources · Similar · Agrees · Disagrees. Each one raises only that set, at most about 8 cards, with lines coloured by type. Disagreement gets its own colour, never green.
- **Outside citations** stay the small `cited:` cards that already exist, now with year, venue, cited-by count and a badge for retracted or contested works.
- **A line's card** shows the evidence: the two quotes and the point of difference, marked AI or Reviewed.
- **Themes** can be a hallway view: a thread lit through the volume planes, showing where it starts, where it peaks and where it fades.
- **Canon** becomes a wall of the outside works the series cites most.

## Decisions (Frode, 1 Nov 2026)

1. **Published.** The file is the editor's and publisher's contribution to the corpus. It is optional metadata, published openly beside the EPUBs, and readers without it lose nothing.
   - So the file names its maker: `"publisher": { "name": "Frode Hegland", "role": "editor and publisher" }`.
   - It carries a licence field, and keeps the `review` states on every edge.
2. **AI relations are shown and marked as AI, but small.** Each card or line made by the model wears a small "AI" tag. A confirmed edge drops the tag and reads "Reviewed by the editor".
3. **Only Origami, for now.** Origami traces the pooled `back.html` notes and bibliography itself. Author's binding is left as it is.
4. **Embedding: `qwen3-embedding:8b` through Ollama** (`ollama pull qwen3-embedding:8b`, about 4.7 GB).
   - It is among the strongest open embedding models, and multilingual.
   - Its 32k-token context takes a whole article at once, so pieces need no chunking.
   - On this Mac (128 GB) the 8b model is easy, and the corpus embeds in minutes.
   - The headset never needs the model: the file stores neighbours and scores, not vectors.
   - The file records the model name, so a later rebake with a better model is visible.
   - `nomic-embed-text` is the fallback if the 8b model is unavailable.
