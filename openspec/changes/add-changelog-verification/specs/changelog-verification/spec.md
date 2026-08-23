## ADDED Requirements

### Requirement: Agent delivers a structured changelog to the overlay

The agent SHALL be able to push a structured **changelog** — an ordered list of change entries — to
the running overlay through the existing agent→overlay message channel, so the user can review what
the agent claims it changed. Each entry SHALL carry a stable `id` and a human `title`/`description`,
and MAY carry an element **context** locating the change (web: `selector`, `route`, `source`,
`outerHTML`; QML: `objectName`, `qmlType`, `qmlFile`, `typeChain`). The changelog is delivered as a
**typed** message so the overlay can distinguish it from a plain-text reply.

#### Scenario: Agent posts a changelog
- **WHEN** the agent runs `poll --changelog <file|json>` (with or without an accompanying
  `--agent-reply`)
- **THEN** the CLI posts a typed changelog message to the callback server and the running overlay
  receives it on its next `messages` read, rendering the entries as a verification checklist

#### Scenario: Changelog entry with element context
- **WHEN** a changelog entry includes an element context
- **THEN** that entry is displayable with an affordance to locate/reveal the element, and a rejection
  of the entry is auto-linked to that context without the user having to pin anything

#### Scenario: Changelog entry without context
- **WHEN** a changelog entry omits element context (context unavailable, e.g. `source: null` or a
  non-element change)
- **THEN** the entry still renders as a checklist item and can be Verified or Rejected; a rejection is
  collected with no auto-linked context unless the user re-pins an element

#### Scenario: Plain reply still works
- **WHEN** the agent runs `poll --agent-reply "<msg>"` with no `--changelog`
- **THEN** the overlay shows the plain-text reply exactly as before and renders no checklist

### Requirement: Overlay renders the changelog as a verification checklist

Both the web overlay (`overlay.js`) and the QML overlay (`AnnotateOverlay.qml`) SHALL render a
received changelog as a checklist in the annotation panel, one row per entry. Each row SHALL offer a
**Verified** control and a **Rejected** control that are mutually exclusive and reflect the current
state of that entry. The checklist SHALL live in the same panel as the pin list and freeform-note
composer, and SHALL minimise/restore with the panel.

#### Scenario: Checklist appears on delivery
- **WHEN** a changelog is delivered while the overlay is running
- **THEN** the panel shows a checklist section with one row per entry, each row showing the entry's
  title/description and Verified / Rejected controls in an unset state

#### Scenario: Marking an entry Verified
- **WHEN** the user clicks **Verified** on an entry
- **THEN** the entry is shown as verified, any open reject textbox for that entry is dismissed, and no
  pending issue is created for it

#### Scenario: Checklist shares panel behavior
- **WHEN** the user minimises the panel to the pill and restores it
- **THEN** the checklist section and its per-entry states are preserved and shown again on restore

### Requirement: Rejecting an entry collects a context-linked issue

When the user marks a changelog entry **Rejected**, the overlay SHALL reveal a textbox for describing
the issue, and SHALL collect the description as a pending item of `kind: "verification"` that carries
the entry's `changelogId` and its context. The user MAY optionally **re-pin** an element (click a
different or additional element, as for a normal annotation) to override or supplement the
auto-linked context. A verification issue SHALL be editable and removable before sending, consistent
with pending pins.

#### Scenario: Reject reveals a description textbox
- **WHEN** the user clicks **Rejected** on an entry
- **THEN** a textbox appears for that entry to describe the issue, and the entry is marked rejected

#### Scenario: Rejection becomes a pending verification issue
- **WHEN** the user enters an issue description for a rejected entry
- **THEN** a pending item is queued with `kind: "verification"`, the entry's `changelogId`, the issue
  comment, and the entry's auto-linked context (when present)

#### Scenario: Optional re-pin overrides context
- **WHEN** the user re-pins an element while a rejection is being described
- **THEN** the pending verification item carries the freshly pinned element's context (web selector/
  route/source or QML identity) in place of, or in addition to, the entry's auto-linked context

#### Scenario: Un-rejecting removes the pending issue
- **WHEN** the user switches a rejected entry back to Verified (or clears the rejection)
- **THEN** the corresponding pending verification item is removed from the queue

### Requirement: Verification issues are batch-submitted with annotations

Verification issues SHALL join the same pending queue as pins and freeform notes and SHALL be
submitted by the same **Send** action, so the user can collect verification feedback across the
checklist first and submit it in one batch. On the wire they SHALL be part of the same
`/__annotate/submit` `annotations` array, distinguished by `kind: "verification"`.

#### Scenario: Mixed batch submit
- **WHEN** the pending queue contains any mix of pins, freeform notes, and verification issues and the
  user clicks **Send**
- **THEN** all pending items are submitted in one `/__annotate/submit` batch and the agent receives
  them from a single `poll`, with verification items identifiable by `kind: "verification"`

#### Scenario: Collect first, send later
- **WHEN** the user rejects several entries and adds descriptions without sending
- **THEN** the verification issues accumulate in the pending queue (persisted alongside other pending
  items) until the user chooses to **Send**

#### Scenario: Pending queue persists verification issues
- **WHEN** pending-pin persistence is available (web `localStorage`, or the QML `savePending` host
  hook) and the overlay reloads or relaunches
- **THEN** queued verification issues are restored with their `changelogId`, comment, and context
