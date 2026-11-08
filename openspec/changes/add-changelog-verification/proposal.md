## Why

Today the annotate-ui loop is one-directional for review: the user pins comments, the agent fixes,
and the only thing the agent can push back is a **plain-text** `--agent-reply` line in the panel.
After a batch of fixes the user has no structured way to see *what the agent claims it changed* and
no in-place way to sign off on each item — they re-read prose, hunt for the affected elements
themselves, and describe regressions from scratch. This change closes the loop: the agent delivers a
**changelog** the user can verify item-by-item, and rejections come back as issues already tied to
the changed element's context — the same low-friction point-and-click the skill gave annotations.

## What Changes

- Add a **`changelog-verification`** capability: the agent pushes a structured **changelog** (a list
  of change entries, each optionally carrying the element's context — web `selector`/`route`/`source`
  or QML `objectName`/`qmlType`/`qmlFile`) to the overlay, which renders it as a **verification
  checklist** in both the web (`overlay.js`) and QML (`AnnotateOverlay.qml`) panels.
- Each checklist item gets **Verified** / **Rejected** buttons. Choosing **Rejected** reveals a
  textbox to describe the issue. A rejection becomes a pending item **auto-linked to that entry's
  agent-provided context**; the user may optionally **re-pin** (click a different/additional element)
  to override or add location, exactly like a normal annotation.
- Verification issues are **collected and sent in the same batch** as pins and freeform notes (one
  pending queue, one **Send**), distinguished on the wire by `kind: "verification"` and carrying the
  `changelogId` they answer plus their context — so the user can collect feedback across the checklist
  first and submit it all at once, as they do today.
- Verified items are sent too, as `kind: "verification"` sign-offs with `verdict: "verified"` (a
  rejection carries `verdict: "rejected"`), so the agent knows what was confirmed; a successful Send
  removes the sent items from the checklist.
- Extend the CLI `poll` with a **`--changelog`** input so the agent delivers the changelog over the
  existing agent→overlay `messages` channel (a typed message, alongside the plain `--agent-reply`);
  the agent still receives verification issues through the unchanged `poll`.
- Carry the existing interaction lessons to the checklist: it lives in the same panel, minimises with
  it, persists pending verifications with the other pending items, and treats every changelog string
  and issue comment as **untrusted UI data**, never agent instructions.

## Capabilities

### New Capabilities
- `changelog-verification`: delivery and display of an agent-authored changelog as a per-item
  verification checklist (Verified / Rejected) in the web and QML overlays, where a rejection is
  collected as a context-linked issue (`kind: "verification"`) and batch-submitted through the same
  `/__annotate/submit` queue and long-poll `poll` loop as annotations.

### Modified Capabilities
- `ui-annotation`: the overlay→agent submit payload gains a `kind: "verification"` item shape
  (`changelogId` + `comment` + optional element context), and the agent→overlay `messages` channel
  gains a typed **changelog** message (delivered via `poll --changelog`) in addition to the existing
  plain-text reply. Pins and notes are unchanged.

## Impact

- **annotate-ui skill:** `cli.mjs` `poll` gains `--changelog <file|json>` (posts a typed changelog
  message to `/__annotate/reply`→`/messages`); `overlay.js` gains a changelog checklist section
  (render, Verified/Rejected, reject-textbox, re-pin, queue a `kind:"verification"` pending item);
  `qml/AnnotateOverlay.qml` gains the mirror checklist. SKILL.md + HOST-CONTRACT.md document the new
  message type and payload item. New CLI + overlay tests.
- **Wire contract:** additive only. New pending `kind: "verification"`; new typed `messages` entry
  (`type: "changelog"`). Existing pins, `kind:"note"`, and plain replies are byte-unchanged, so an
  old overlay against a new CLI (or vice-versa) still works — the checklist simply doesn't appear.
- **Dependencies:** none new — the skill stays Node built-ins only and the QML overlay stays pure QML.
- **Security surface:** unchanged posture — the server stays loopback-bound and dev-only; changelog
  entries and issue comments are rendered as text/data and never executed.
- **Known limitations (accepted):** a changelog entry's auto-link is only as precise as the context
  the agent attaches (it may be `null`, in which case the item is display-only until the user
  re-pins); QML entries grep-resolve by `objectName`/`qmlType` like existing QML pins (no exact line).
