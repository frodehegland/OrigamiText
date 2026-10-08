# The `origami:` vocabulary

The prefix a publication binds in its package document (§4.1 of the [profile](../ORIGAMI-EPUB-PROFILE-1.0.md)):

```xml
prefix="origami: https://github.com/frodehegland/OrigamiText/blob/main/profile/vocab.md#"
```

Each term below is that address with the term as its fragment. For example,
`origami:visual-meta` is `…/profile/vocab.md#visual-meta`. Publications
written before 8 October 2026 bind the prefix to
`https://origamitext.org/vocab/`, which names the same terms (§4.2).

## visual-meta

A `<link rel="record">` `properties` value. It marks the linked resource as the semantic record, `visual-meta.json` (§4.4, §9).

## interaction

A `<link rel="record">` `properties` value. It marks the linked resource as the interaction record, `origami.json` (§4.4, §10).

## bibliography

A `<link rel="record">` `properties` value. It marks the linked resource as the bibliography record, `references.bib` (§4.4, §11).

## bibliography-csl

A `<link rel="record">` `properties` value. It marks an optional CSL JSON rendering of the bibliography record, which is derived and never canonical (§11).

## Terms that are not defined

A publication MUST NOT use `origami:profile`, `origami:work`,
`origami:supersedes` or `origami:replaces`. Dublin Core already says each
of these (§4.2, §4.3).
