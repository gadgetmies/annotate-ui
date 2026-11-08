## Context

annotate-ui already has a **bidirectional** transport: the overlay POSTs pending batches to
`/__annotate/submit` (agent reads them via long-poll `poll`), and the agent posts to
`/__annotate/reply` which appends to `state.messages`; overlays read `GET /__annotate/messages?since=<n>`
every ~3s. Today the reply is a bare string rendered as a line in the panel. Both overlays already own
a **pending queue** with per-item edit/remove, freeform notes (`kind:"note"`), minimise-to-pill, and
pending persistence (web `localStorage`; QML `loadPending`/`savePending` host hooks). This change
reuses every one of those seams — it adds a *new message type* in one direction and a *new pending
item kind* in the other, with no new endpoints and no new transport.

The web overlay (`overlay.js`) builds its panel imperatively (`renderList`, `renderDisplayRow`,
`renderEditRow`, the note `composer`, `pollMessages`). The QML overlay (`AnnotateOverlay.qml`) is a
generic, host-agnostic component documented by `qml/HOST-CONTRACT.md`, doing its own
`XMLHttpRequest` transport and pending state. The two must stay behavior-parallel, as the note
composer and minimise-to-pill already are.

## Goals / Non-Goals

**Goals**
- Let the agent push a structured changelog and let the user sign off per item (Verified / Rejected)
  in-place, in both the web and QML overlays.
- Make a rejection a first-class pending item that is already tied to the changed element's context,
  reusing the existing pin/note queue, Send, edit/remove, and persistence.
- Stay additive and backward compatible on the wire so mismatched CLI/overlay versions degrade to
  today's behavior.

**Non-Goals**
- A second transport or new endpoints — it rides `/__annotate/reply`→`/messages` and
  `/__annotate/submit`.
- Auto-generating the changelog — the agent authors it; the skill only carries and displays it.
- Exact QML source lines — QML entries grep-resolve by `objectName`/`qmlType`/`qmlFile`, as existing
  QML pins do.
- A verification "result" round-trip UI (the agent seeing green/red aggregate state) beyond receiving
  the rejected items as issues.

## Decisions

### D1 — Deliver the changelog as a typed message on the existing reply channel
Extend `state.messages` entries with a discriminator. Today an entry is
`{ id, message }`; a changelog is `{ id, type: "changelog", changelog: [ …entries… ] }` (a plain
reply keeps its current shape, treated as `type: "reply"` implicitly). The CLI gains
`poll --changelog <file|json>` which reads/validates the entries and POSTs them to
`/__annotate/reply`; `--changelog` composes with `--agent-reply`. Overlays branch on `type` when
draining `/messages`. *Alternative considered:* a dedicated `/__annotate/changelog` endpoint +
`GET /changelog` — rejected: more surface, more session/version coupling, and the `messages`
long-drain + `since` cursor already solves ordered delivery.

### D2 — A changelog entry is `{ id, title, description?, context? }`
`id` is an agent-chosen stable string (the `changelogId` a verification issue references).
`context` is optional and surface-shaped: web `{ selector, route, source, outerHTML }`, QML
`{ objectName, qmlType, qmlFile, typeChain }`. When the agent has a pin it is fixing, it can copy that
pin's context verbatim into the entry so reveal/auto-link "just work"; when it doesn't (a non-element
change, or `source: null`), it omits `context` and the row is display-only until a re-pin. Reusing the
**exact field names** from the existing pin payloads means the web overlay's `revealBySelector` and
the QML overlay's identity capture apply unchanged.

### D3 — A verdict is a pending item `kind: "verification"`, in the shared queue
Rather than a parallel "verification queue", a verdict is pushed onto the same `state.pending` array
the pins and notes use, as `{ kind: "verification", verdict, changelogId, title, comment, ...context }`
— `verdict: "rejected"` with the issue as `comment`, or `verdict: "verified"` with an empty comment.
This inherits edit/remove, the single **Send** (`/__annotate/submit`), the pending-count, and
persistence for free. The checklist row and its pending item are kept in sync by `changelogId`: one
item per entry, replaced on every state change, removed on unset. *Revision:* the first version sent
nothing for Verified and left the agent to infer it from absence; users then saw verified rows
linger forever, and the agent could not tell "verified" from "not checked". Verified sign-offs now
travel with Send, a missing `verdict` still means rejected (older overlays), and a successful Send
removes the sent entries from the checklist. *Alternative considered:* a
separate "Send verification" button and batch — rejected per the product decision to keep one unified
queue and Send (collect-then-batch, as today).

### D4 — Verified/Rejected are mutually exclusive per-row state, persisted with the checklist
Each row holds `state ∈ {unset, verified, rejected}`. The changelog itself (entries + per-row state)
is held in overlay state next to `pending`, so it survives minimise/restore. On the web it also mirrors
to `localStorage` (a new `annotate-ui.changelog` key) so a reveal-navigation reload keeps the checklist;
on QML it is in-memory plus, for the *pending verification items only*, the existing `savePending`
hook (the checklist display state is best-effort in-memory, matching how QML treats other transient UI).

### D5 — Re-pin reuses the annotate pick flow, scoped to the active rejection
While a rejection textbox is open, entering annotate mode and clicking an element captures that
element's context (the normal pick path) and attaches it to *that* rejection's pending item instead of
creating a standalone pin. This is a small mode flag on the pick handler ("pinning-for-rejection
`<changelogId>`"), not a new capture path — the identity/geometry capture is identical to a normal pin,
so snapshot-at-pick-time and Alt/⌥ pass-through carry over unchanged.

### D6 — Terminology: Verified / Rejected
Per the product decision, the controls read **Verified** (works) and **Rejected** (faulty → reveals
the reason textbox). Wire/`kind` uses the neutral `"verification"`; the `changelogId` links the issue
to its entry.

## Payload

Agent→overlay changelog message (in `/__annotate/messages`):

    { "id": 7, "type": "changelog",
      "changelog": [
        { "id": "c1", "title": "Star color now gold",
          "description": "Changed --star-fill to gold in Rating.tsx",
          "context": { "selector": ".rating > svg", "route": "/movie/42",
                       "source": { "file": "src/Rating.tsx", "line": 18 } } },
        { "id": "c2", "title": "Debounced search input" }        // no context → display-only
      ] }

Overlay→agent verification item (in a `/__annotate/submit` `annotations` batch):

    { "kind": "verification", "changelogId": "c1",
      "comment": "Still orange on the detail page",
      // context: auto-linked from the entry, or replaced by a re-pin
      "selector": ".rating > svg", "route": "/movie/42",
      "source": { "file": "src/Rating.tsx", "line": 18 } }

QML mirrors the shapes with its identity fields (`objectName`/`qmlType`/`qmlFile`/`typeChain`,
`surface: "qml"`), exactly as QML pins already differ from web pins.

## Risks / Trade-offs

- **Version skew (old overlay ↔ new CLI, or vice-versa)** → additive discriminators: an overlay that
  doesn't know `type:"changelog"` ignores the message (D1); a CLI that receives `kind:"verification"`
  it doesn't render still lists it. No endpoint or required-field changes.
- **Changelog entry context is stale by verify time** (the app changed/navigated) → the entry still
  reveals best-effort by `selector`/identity (same tolerance as pin reveal today), and the user can
  re-pin (D5) to correct it.
- **Checklist + pending drift** (a rejected row without a matching pending item, or vice-versa) →
  single source of truth keyed by `changelogId`; the row state transition is what mutates the queue
  (D3/D4), and Send clears both consistently.
- **Untrusted content** → changelog `title`/`description` and issue comments are rendered as text
  (web: `textContent`, never `innerHTML`; QML: `Text`), never executed — same rule as `comment`/
  `outerHTML` today.
- **Web/QML divergence** → the spec scenarios are surface-agnostic and both overlays implement the
  same row states and wire shapes; parity tests mirror the note-composer parity already in place.

## Migration Plan

Additive and backward compatible; no data migration. `poll` without `--changelog` is unchanged; the
overlay renders no checklist until a changelog arrives. Rollback = revert the CLI/overlay edits; the
wire has no new required fields, so a reverted side interoperates with an un-reverted one at the
pre-feature behavior level. New `localStorage` key (`annotate-ui.changelog`) is self-clearing on
Send/empty.

## Open Questions

- Should the overlay surface an explicit "all verified" affordance (e.g. a one-click "Verify all
  remaining") — deferred; per-item is the required behavior.
- ~~Whether to report verified items or leave them to absence~~ — resolved (D3 revision): verified
  items are sent as `verdict: "verified"` sign-offs and summarised as `Verified: <title>` lines.
