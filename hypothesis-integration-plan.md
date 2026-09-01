# Hypothesis Integration Plan for Origami Text
*Revised after peer review — 2026-09-01*

## Core principle

**Origami owns the annotation; Hypothesis is one place it can be published.**

Local storage and community publishing are separate operations. An annotation saved in the local sidecar does not automatically become a public Hypothesis annotation — the user controls that explicitly. This fits Origami's local-first design and matches Hypothesis's own distinction between private highlights and public annotations.

---

## Phase 0 — DOI Interoperability Spike (do this first, before any code)

The plan's most important claim is: annotate a document via its DOI URI and the annotation will appear for anyone using the Hypothesis browser extension on the same paper. This claim needs to be tested before writing the URI codec, because Hypothesis's URI equivalence depends on metadata it has already encountered from prior annotations — it is not a simple string match.

**Experiment (30 minutes, no code):**

1. Find a real scholarly paper with a known DOI (e.g. `10.1145/3290605.3300526`).
2. Open the publisher HTML page in Chrome with the Hypothesis extension. Create one annotation.
3. Open the publisher PDF in Chrome with the Hypothesis extension. Create one annotation.
4. Query the Hypothesis API directly:
   `GET https://api.hypothes.is/api/search?uri=https://doi.org/10.1145/3290605.3300526`
5. Note whether the HTML and PDF annotations both appear in the result.
6. Create a test annotation via the API using only the DOI URI as target.
7. Reload the publisher HTML/PDF in the browser. Check whether the API-created annotation renders.

**Outcome A** — DOI URI resolves to the same document as the publisher URLs → `canonicalURI` can stay as one string `"https://doi.org/" + doi`.

**Outcome B** — DOI URI is isolated from publisher URLs → `canonicalURI` must return the publisher URL when available, with DOI as a declared alias. Extend `EPUBRecord` to carry a `canonicalURL` field populated from the EPUB's own metadata (many EPUBs carry the publisher URL in their spine or metadata).

The rest of the plan proceeds either way; only the URI strategy function changes.

---

## The Document Identity Problem

Hypothesis identifies documents by URL. Origami Text uses internal addresses. For community annotations to work across different installations and different clients, the URI must be globally stable and installation-independent.

**Priority order for canonical URI:**

| Situation | URI used | Why |
|---|---|---|
| EPUB has a DOI | `https://doi.org/<doi>` | Globally assigned; interoperable with browser extensions |
| No DOI, EPUB has publisher URL | `<publisher URL from metadata>` | Next most stable; may work with browser extension |
| Neither | `https://origamitext.app/epub/<package-identifier>` | Origami-only, but stable across installations |

`EPUBRecord.doi` already stores the bare DOI. The package identifier (`urn:uuid:...` from `package.opf`) is already captured as `OrigamiEPUBImport.ImportResult.identifier` — it needs to flow into `EPUBRecord` so it's available at runtime.

**Critical constraint on the fallback:** The Origami address (`EPUBRecord.id`) is generated at import time on each device and is NOT globally stable — two users independently importing the same EPUB get different Origami addresses. `https://origamitext.app/epub/<address>` would therefore create a community namespace for one installation only. The EPUB's own package identifier is the correct fallback because it is embedded in the file and identical everywhere.

**Action required before Phase 2:** Add `var packageIdentifier: String? = nil` to `EPUBRecord`, populate it from `ImportResult.identifier` during book opening, and use it as the fallback URI.

---

## Authentication and Access Layers

Authentication and annotation access are separate concerns:

| Capability | Requires sign-in? |
|---|---|
| View public Hypothesis annotations | No |
| Publish annotations to Hypothesis | Yes |
| Delete or update your annotations | Yes |
| View annotations in private groups | Yes (group member) |

This means Origami Text can show community annotations to any user who opens an EPUB with a canonical URI — no account needed. This is a significantly better first experience: open a paper, see "11 public annotations", decide whether to create an account.

`HypermediaSession` should model these as distinct states:

```swift
// Public read layer — no auth required
var hypothesisPublicEnabled: Bool  // user toggle

// Authenticated publish layer
var hypothesisAuthState: HypothesisAuthState

enum HypothesisAuthState: Equatable {
    case signedOut
    case connecting
    case signedIn(username: String)
    case failed(String)
}
```

Auto-restore on launch: check Keychain for a token and set `.signedIn(username:)` without re-validating (validation occurs at the next network call).

**v1 auth method: personal API token.** The user visits `https://hypothes.is/account/developer`, copies their token, pastes it into Settings → Hypermedia → Hypothesis. Token validated via `GET /api/profile`. Stored in Keychain via the existing `HypermediaKeychain`.

**OAuth** (full multi-user app registration) is v2.

---

## Architecture

### New file: `HypothesisClient.swift`

A `nonisolated enum` with `async` functions. Owns all Hypothesis HTTP calls and the codec between Origami's `WebAnnotation` and Hypothesis's JSON.

```
HypothesisClient
  ├── validateToken(_:) async throws -> String           // GET /api/profile → username
  ├── canonicalURI(for record: EPUBRecord) -> String?    // DOI → packageID → nil
  ├── push(_:uri:token:) async throws -> String          // POST → Hypothesis ID
  ├── delete(hypothesisID:token:) async throws           // DELETE /api/annotations/<id>
  └── fetchPublic(uri:token:) async throws -> [WebAnnotation]
       // GET /api/search?uri=<uri>&limit=200
       // token is optional — public annotations require no auth
```

Base URL: `https://api.hypothes.is`. All authenticated requests carry `Authorization: Bearer <token>`.

### New file: `HypothesisIDMap.swift`

A small persistent sidecar (`<address>.hypothesis.json`) mapping local annotation IDs to Hypothesis sync state. This is kept separate from the W3C sidecar to avoid contaminating the annotation model with Hypothesis implementation state.

```swift
struct HypothesisRecord: Codable {
    var localID: String           // the urn:uuid the local sidecar uses
    var hypothesisID: String?     // assigned by the server after a successful push
    var documentURI: String       // the URI used when this annotation was pushed
    var syncState: SyncState

    enum SyncState: String, Codable {
        case local          // saved locally, not yet published
        case publishing     // push in flight
        case published      // successfully pushed; hypothesisID is valid
        case publishFailed  // push failed; will retry
        case deleting       // delete in flight
        case deleteFailed   // delete failed; remote copy may still exist
    }
}

nonisolated enum HypothesisIDMap {
    static func load(for address: String, in folder: URL) -> [String: HypothesisRecord]
    static func save(_ records: [String: HypothesisRecord], for address: String, in folder: URL)
    static func record(localID: String, for address: String, in folder: URL) -> HypothesisRecord?
    static func upsert(_ record: HypothesisRecord, for address: String, in folder: URL)
    static func remove(localID: String, for address: String, in folder: URL)
}
```

The offline failure case is explicit: if a push fails, `syncState = .publishFailed` and the `hypothesisID` remains nil. The annotation is healthy locally. When connectivity returns, a background retry can pick up `.publishFailed` records and attempt again.

If the user deletes an annotation while offline, `syncState = .deleting` with the `hypothesisID` preserved — so the DELETE can still be sent later.

### Modified: `HypermediaSession.swift`

New properties and methods:

```
var hypothesisAuthState: HypothesisAuthState = .signedOut
var hypothesisPublicEnabled: Bool              // mirrors UserDefaults toggle
var communityAnnotations: [WebAnnotation] = [] // volatile, not persisted

connectHypothesis(token:) async            // validate → Keychain → .signedIn
disconnectHypothesis()
publishAnnotation(_:for:) async            // push if signedIn; record sync state
unpublishAnnotation(localID:for:) async    // delete from Hypothesis if published
fetchCommunity(for record:) async          // fetch public + deduplicate
```

### Modified: `SettingsView.swift` — `HypermediaSettingsView`

Add a **Hypothesis** section:

**When signed out:**
- `SecureField` for API token
- "Sign in" button
- Footer: where to find the token (hypothes.is/account/developer)

**When signed in:**
- `LabeledContent("Signed in as") { Text(username) }`
- Red "Sign out" button

**Separate toggle (always visible, no sign-in required):**
- "Show public Hypothesis annotations" — enables the unauthenticated fetch layer

---

## The Annotation Codec

### Origami WebAnnotation → Hypothesis POST body

```
Hypothesis field        From Origami
───────────────         ─────────────────────────────────────────────
uri                     canonicalURI(for: epubRecord)
text                    annotation.body?.value  (when motivation = commenting)
tags                    [body.value]            (when motivation = tagging)
                        ["origami-kind:<kind>"] (for ReaderAnnotationKind tags)
target[0].source        same uri
target[0].selector      ONLY TextQuoteSelector + TextPositionSelector
                        Drop FragmentSelector (Origami paragraph ID — unknown externally)
                        Drop ProgressionSelector (not a Hypothesis type)
permissions.read        ["group:__world__"]  (v1: public only)
group                   "__world__"
```

**Annotation kind tags** use the `origami-kind:` namespace to distinguish Origami-semantic tags from arbitrary user tags:

| Origami kind | Hypothesis tag |
|---|---|
| Important | `origami-kind:important` |
| Quotable | `origami-kind:quotable` |
| Great | `origami-kind:great` |
| Disagree | `origami-kind:disagree` |
| Language Issue | `origami-kind:language-issue` |
| Problematic | `origami-kind:problematic` |
| What is this? | `origami-kind:what-is-this` |
| Highlight | `origami-kind:highlight` |
| Strikethrough | `origami-kind:strikethrough` |

When a community annotation arrives with an `origami-kind:` tag, Origami renders it with the correct kind icon. Ordinary Hypothesis tags remain ordinary tags.

### Hypothesis response → Origami WebAnnotation

Only top-level annotations with a `TextQuoteSelector` are imported in v1. Replies, page notes (no selector), and highlights without a `TextQuoteSelector` are silently skipped.

```
Origami field           From Hypothesis
──────────────          ──────────────────────────────────────────────
id                      "https://hypothes.is/a/" + annotation.id  (full W3C IRI)
motivation              "commenting" if text present, "highlighting" otherwise
body.value              text
body.purpose            "commenting" or "tagging"
creator.name            user, stripped of "acct:" prefix and "@<authority>" suffix
target.source           uri
target.selectors        Decode TextQuoteSelector + TextPositionSelector only
created                 created (ISO 8601)
modified                updated (ISO 8601)
```

Using `https://hypothes.is/a/<id>` as the W3C `id` gives the annotation a globally meaningful IRI, not a service-local opaque string. This matters when Origami eventually communicates with more than one annotation service.

### Anchoring priority for incoming community annotations

When anchoring a community annotation whose selectors came from a browser annotation of publisher HTML:

1. **TextQuoteSelector** — exact words + prefix/suffix context *(primary)*
2. Fuzzy match of exact words if exact fails *(existing AnnotationAnchor logic)*
3. **TextPositionSelector** — used only as a search hint, not as a primary anchor *(character offsets from publisher HTML will not match EPUB offsets)*

The existing `AnnotationAnchor.resolve` in `AnnotationStore.swift` already follows this priority. No change needed in the anchoring code.

**Unanchorable annotations are kept, never discarded.** A community annotation that cannot be anchored still appears in the annotations list with "location not found" — the same treatment as local orphaned annotations.

---

## Deduplication

When Origami fetches community annotations it may receive annotations that the current user published from Origami. Without deduplication, the user sees their own annotation twice: once from the local sidecar, once from the community feed.

**Rule:** Before displaying a community annotation, check `HypothesisIDMap`. If the incoming Hypothesis ID matches any record's `hypothesisID`, skip it from the community list — the local copy already represents it.

Three annotation states visible in the UI:

| State | Source | Display |
|---|---|---|
| Local | Sidecar only | Normal annotation style |
| Published (mine) | Sidecar + Hypothesis ID in IDMap | Normal annotation style + small cloud badge |
| Community (others') | Hypothesis fetch only | Subdued style, contributor username |

---

## Phase Breakdown

### Phase 0 — Interoperability Spike
*(30 min, manual experiment — see top of document)*

Result determines whether `canonicalURI` stays simple or needs a publisher-URL alias.

---

### Phase 1 — Foundation changes + Auth UI
**Estimate: 2–3 days**

1. Add `var packageIdentifier: String? = nil` to `EPUBRecord`. Populate from `ImportResult.identifier` when a book is opened. This is the fallback canonical URI for books without a DOI.
2. Add `HypothesisAuthState` enum and `hypothesisPublicEnabled` bool to `HypermediaSession`
3. Implement `connectHypothesis(token:)` — `GET /api/profile`, extract username, store token in Keychain
4. Implement `disconnectHypothesis()`
5. Add auto-restore on launch
6. Add Hypothesis section to `HypermediaSettingsView` in `SettingsView.swift`

Checkpoint: Settings shows Hypothesis section. Sign in with a real token shows the username. "Show public annotations" toggle is visible and persisted even when signed out.

---

### Phase 2 — Publish (local → Hypothesis)
**Estimate: 2–3 days**

1. Write `HypothesisClient.canonicalURI(for:)` — DOI → packageIdentifier fallback → nil
2. Write `HypothesisClient.push` — build POST payload using codec, return server ID
3. Write `HypothesisClient.delete`
4. Write `HypothesisIDMap` helpers
5. Identify the hook point where `AnnotationStore.save` is called in `AppModel`/`EPUBReaderView` — call `HypermediaSession.publishAnnotation` there **after** the local sidecar write succeeds and **only if** the user has "Send annotations to community" enabled
6. Hook deletion: when `model.removeAnnotation` is called, look up `HypothesisIDMap` and call `unpublishAnnotation` if a server record exists

Publishing is a side effect of local save, not the primary action. If the push fails (network offline, server error), `syncState = .publishFailed` and the annotation is healthy locally. No error is surfaced to the user for a background push failure — a small cloud badge shows "not yet synced" in the annotations list.

Checkpoint: Make an annotation in the reader. Open `https://hypothes.is/stream` in a browser — annotation appears. Delete it in Origami — it disappears from the stream.

---

### Phase 3 — Fetch (Hypothesis → display)
**Estimate: 2–3 days**

1. Write `HypothesisClient.fetchPublic(uri:token:)` — `GET /api/search?uri=<uri>&limit=200`, filter to top-level TextQuoteSelector annotations only, decode via response codec
2. Call fetch when a book is opened, if `hypothesisPublicEnabled` is true (no auth required for public annotations)
3. Populate `HypermediaSession.communityAnnotations`
4. Apply deduplication rule (skip annotations whose Hypothesis ID is in local IDMap)
5. Display community annotations in the reading margin: subdued style, contributor username, same anchoring ladder as local annotations

Checkpoint: Post a test annotation on a DOI paper using the browser extension. Open the paper in Origami — the community annotation appears in the margin anchored to the correct words.

---

### Phase 4 — Real-time WebSocket (v2)

The Hypothesis WebSocket at `wss://hypothes.is/ws` is documented as early-stage and subject to change. Polling on document open is safe for v1. The `EventSource` and `swift-websocket` packages are already in the project's dependencies.

---

## Scope Boundaries

| In scope for v1 | Out of scope / v2 |
|---|---|
| Personal API token auth | OAuth (multi-user app registration) |
| Publish new annotations | Bidirectional sync / conflict resolution |
| Fetch public annotations (no auth required) | Real-time WebSocket updates |
| Public group only (`__world__`) | Private Hypothesis groups |
| DOI + package-identifier canonical URI | Publisher URL extraction / alias |
| Top-level annotations with TextQuoteSelector | Replies, page notes, highlights-only |
| `origami-kind:` tag namespace | Arbitrary tag semantic mapping |
| EPUBs only | `.origamitext` drafts |
| Hypothesis hosted service | Self-hosted Hypothesis instance |

---

## UI Decisions (settled)

**Display placement:** Community annotations appear inline alongside local annotations in the reading margin — annotating the same words, same ladder — with a visually distinct treatment (subdued colour, username label). A separate browsing panel can come later but the annotation belongs beside its target text.

**Visibility control:** One master "Show public Hypothesis annotations" toggle in Settings, always visible (no sign-in required to enable it). Provider-specific controls sit beneath a "Community Annotations" header when more providers are added.

**Annotation kind rendering:** Render an Origami kind icon only for an explicitly `origami-kind:` prefixed tag. Arbitrary Hypothesis tags from other users render as plain text tags. This preserves semantic correctness.

---

## What Does Not Change

- `WebAnnotation.swift` — the W3C annotation model is not modified
- `AnnotationStore.swift` — the sidecar format is not modified
- `AnnotationAnchor` — anchoring logic is unchanged (already TextQuote-first)
- The local annotation flow — everything works offline, exactly as before

The integration is purely additive.
