# Origami EPUB Profile 1.0

This folder's address is the profile identifier:

```
https://github.com/frodehegland/OrigamiText/tree/main/profile/1.0
```

A publication declares it in its package document:

```xml
<meta property="dcterms:conformsTo">https://github.com/frodehegland/OrigamiText/tree/main/profile/1.0</meta>
```

**The specification:** [ORIGAMI-EPUB-PROFILE-1.0.md](../../ORIGAMI-EPUB-PROFILE-1.0.md)

Published with it:

- [origami-schemas/](../../origami-schemas/): the JSON Schemas for the records (§19.1), plus the reference validator and extractor (§19.3)
- [origami-corpus/](../../origami-corpus/): the conformance corpus (§20)
- [vocab.md](../vocab.md): the `origami:` vocabulary

Publications written before 8 October 2026 declare
`https://origamitext.org/profile/1.0` instead. That domain was never
registered, so the address never resolved, but it names this same profile
(§4.2).
