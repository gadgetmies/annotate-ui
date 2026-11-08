## 1. CLI — changelog delivery (`cli.mjs`)

- [x] 1.1 Add `poll --changelog <file|json>`: read from a file path or inline JSON, validate it is an array of `{ id, title, description?, context? }` entries (fail with a clear message otherwise)
- [x] 1.2 Post the changelog to `/__annotate/reply` as a typed message `{ type: "changelog", changelog: [...] }`; keep it composable with `--agent-reply` (both may be sent in one invocation)
- [x] 1.3 Ensure the `/reply`→`state.messages`→`/messages` path carries the `type`/`changelog` fields through unchanged (server stores the message verbatim; plain replies keep `{ id, message }`)
- [x] 1.4 Render received `kind: "verification"` items in `poll`'s markdown summary — grouped as verification issues tied to `changelogId` + context, distinct from pins and `kind:"note"` notes
- [x] 1.5 Update `poll` usage/help text for `--changelog`

## 2. Web overlay — checklist (`overlay.js`)

- [x] 2.1 In `pollMessages`, branch on message `type`: `changelog` → set the changelog state + render the checklist; plain reply → existing behavior
- [x] 2.2 Add changelog state (entries + per-row `state ∈ {unset,verified,rejected}`) next to `state.pending`; persist to a new `annotate-ui.changelog` `localStorage` key (load on boot, survive reveal-reload, clear on empty/Send)
- [x] 2.3 Render a checklist section in the panel: one row per entry (title/description), **Verified** / **Rejected** controls, and a per-entry reveal affordance when the entry has `context` (reuse `revealBySelector`)
- [x] 2.4 Verified: mark the row verified, dismiss any open reject textbox, and remove any pending verification item for that `changelogId`
- [x] 2.5 Rejected: mark the row rejected and reveal a description textbox; on input, create/update a pending item `{ kind:"verification", changelogId, comment, ...context }` (auto-linked from the entry's `context`)
- [x] 2.6 Re-pin: while a rejection textbox is open, allow entering annotate mode and picking an element to replace that rejection's context with the freshly captured selector/route/source (scoped pick mode, not a standalone pin)
- [x] 2.7 Ensure verification items ride the existing single **Send** (`/__annotate/submit`), pending-count, edit/remove, and minimise/restore with the checklist intact

## 3. QML overlay — checklist (`qml/AnnotateOverlay.qml`)

- [x] 3.1 In the `/messages` drain, branch on `type: "changelog"` and hold the changelog (entries + per-row state) in component state; render a checklist section mirroring the web layout
- [x] 3.2 **Verified** / **Rejected** controls per row; Rejected reveals a `TextArea` for the issue; a reveal/locate affordance when the entry carries QML identity context
- [x] 3.3 Rejection queues a pending `{ surface:"qml", kind:"verification", changelogId, comment, ...identity }` into the existing pending list; un-reject removes it; ride the existing Send and `savePending` persistence
- [x] 3.4 Re-pin: scope the existing pick/hit-test flow to attach captured identity to the active rejection (Alt/⌥ pass-through + snapshot-at-pick-time carry over unchanged)
- [x] 3.5 Preserve checklist through minimise-to-pill; render `title`/`description`/`comment` via `Text` only (never as markup)

## 4. Docs / contract

- [x] 4.1 SKILL.md: document `poll --changelog` (agent delivers the changelog), the verification checklist (Verified/Rejected), and that rejections arrive in the same batch as `kind:"verification"` tied to `changelogId` + context
- [x] 4.2 `qml/HOST-CONTRACT.md`: add the `type:"changelog"` message shape and the `kind:"verification"` submit item to the wire contract; note the checklist needs no new host hooks
- [x] 4.3 README.md: mention the changelog-verification loop in the feature overview

## 5. Tests

- [x] 5.1 CLI test: `poll --changelog <file>` and inline JSON post a `type:"changelog"` message readable via `/messages`; invalid changelog is rejected with a clear error; `--changelog` + `--agent-reply` compose
- [x] 5.2 CLI test: a `submit` batch containing a `kind:"verification"` item is delivered by `poll` and rendered in the markdown summary distinct from pins/notes
- [x] 5.3 Web overlay test (existing overlay test harness): a delivered changelog renders rows; Verified/Rejected transitions create/remove a pending verification item keyed by `changelogId`; a mixed batch (pin + note + verification) submits as one `annotations` array
- [x] 5.4 QML overlay test (headless/offscreen, mirroring existing QML parity tests): changelog message parses and renders; reject queues a `kind:"verification"` pending item; parity of wire shapes with the web overlay
- [x] 5.5 Backward-compat test: a plain `--agent-reply` still renders as text with no checklist; an overlay ignores an unknown message `type` without error

## 6. Manual verification

- [x] 6.1 Live web pass: `serve` a dev app → `poll --changelog <file>` → checklist appears → Verify some, Reject one (with re-pin) → **Send** → confirm the verification issue arrives via `poll` with `changelogId` + context
- [ ] 6.2 Live QML pass: `serve --server-only` + a `--annotate` QML app → deliver a changelog → Verify/Reject → **Send** → confirm the `kind:"verification"` item arrives (requires a live desktop session)

## 7. Verified sign-offs and clearing sent items (revision)

- [x] 7.1 Overlays (QML + web): Verified queues `{ kind:"verification", verdict:"verified", changelogId, title, comment:"" , ...context }`; rejections carry `verdict:"rejected"` and `title`
- [x] 7.2 CLI markdown: list `Verified: <title>` lines apart from the numbered verification issues; an item without `verdict` reads as a rejection
- [x] 7.3 QML: a successful Send removes the sent entries from the checklist; persisted verdicts keep an unchanged re-delivery hidden and show a changed one unset (also across an app restart); Send label counts sign-offs separately
- [x] 7.4 Tests: CLI markdown + integration, web helpers, QML verified payload / removal after Send / restart round trip / changed re-delivery
