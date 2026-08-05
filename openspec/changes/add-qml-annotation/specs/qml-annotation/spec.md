## ADDED Requirements

### Requirement: Opt-in, dev-only, self-contained overlay install

The QML annotator SHALL be a self-contained module installed only on an explicit dev opt-in, adding
nothing to the shipping app when the flag is absent, and removable by deleting its file(s) and one
small install block — mirroring the existing `--hot-reload` dev module.

#### Scenario: Enabled only by the dev flag
- **WHEN** the app is launched with the `--annotate` flag
- **THEN** the overlay module is installed against the running `QQmlApplicationEngine` and its root
  window, and the annotate affordance becomes available

#### Scenario: Inert without the flag
- **WHEN** the app is launched without `--annotate`
- **THEN** the overlay module is never imported, no overlay is created, and the QML view tree is
  byte-identical to a build that has no annotator

#### Scenario: Self-contained and removable
- **WHEN** the annotator's file(s) and the small `if args.annotate:` install block are deleted
- **THEN** the app builds and runs unchanged, because nothing else references the module

### Requirement: Live element hit-testing and highlight

In annotate mode the overlay SHALL identify the Qt Quick item under the cursor and visually highlight
it, without altering the item or the app's own interaction when annotate mode is off.

#### Scenario: Hover highlights the item under the cursor
- **WHEN** annotate mode is on and the pointer moves over the app
- **THEN** the deepest visible non-overlay item under the pointer is highlighted with a bounding
  outline that follows the pointer

#### Scenario: Overlay is click-through when off
- **WHEN** annotate mode is off
- **THEN** the overlay captures no input and the app behaves exactly as without the annotator

#### Scenario: The overlay never targets itself
- **WHEN** the hit-test runs
- **THEN** the overlay's own items (highlight, panel, input) are excluded from the result

### Requirement: Pass-through to operate app popups, with pick-time snapshot

The overlay SHALL let the user operate the app (open menus, popups, dropdowns) while staying in
annotate mode, and SHALL capture a pin's context at pick time so a subsequently-closing popup never
invalidates it.

#### Scenario: Modifier-click passes through to the app
- **WHEN** annotate mode is on and the user Alt/⌥-clicks an element
- **THEN** the click reaches the app (opening a `Popup`/`Menu`/`ComboBox` or toggling a control) and
  no annotation is pinned; the highlight is suppressed while the modifier is held

#### Scenario: Annotating inside an open popup
- **WHEN** a popup is open and the user plain-clicks an element inside it
- **THEN** that element's full context is snapshotted immediately and a comment box opens for it

#### Scenario: Pin survives the popup closing
- **WHEN** the app popup closes after the element was picked (e.g. because focus moved to the comment
  box)
- **THEN** the pending pin retains the snapshotted identity, geometry, and file — nothing is lost

### Requirement: QML annotation payload

Every QML annotation delivered to the agent SHALL carry enough context to locate and fix the element
without an exact line number: a user comment, the item's `objectName`, its QML type and ancestor-type
chain, its source file, a property/geometry snapshot, and a `surface` discriminator.

#### Scenario: Baseline fields are always present
- **WHEN** the user pins a comment on any QML element and sends it
- **THEN** the annotation includes `comment`, `objectName` (empty string when unset), `qmlType`,
  `typeChain`, `qmlFile` (repo-relative to `qml/`), `props` (at least `{x, y, w, h}`), and
  `surface: "qml"`

#### Scenario: Source file from the creation context
- **WHEN** the payload is assembled for an item
- **THEN** `qmlFile` is derived from the item's creation context base URL and made relative to the
  `qml/` root, and `qmlType` names the item's component type, so the agent can grep the file by
  `objectName`/`qmlType`

#### Scenario: No exact line, and that is explicit
- **WHEN** an item exposes no private/debug source-line information
- **THEN** no `line` field is fabricated; the file + objectName + type are sufficient and the agent
  resolves the line by grep

### Requirement: Optional screenshot capture

The overlay SHALL support attaching a cropped screenshot of the pinned item, defaulting to OFF, so the
common path produces a lightweight text payload.

#### Scenario: Screenshots off by default
- **WHEN** the annotator is enabled with no screenshot option
- **THEN** pins carry no `screenshot` field and no image is grabbed

#### Scenario: Screenshots on when requested
- **WHEN** screenshot capture is toggled on
- **THEN** each pin includes a cropped image of the item (base64 PNG via `grabToImage`), in addition
  to the baseline fields

### Requirement: Delivery through the shared annotate-ui server

QML annotations SHALL reach the coding agent through the existing annotate-ui callback server and
`poll` loop, so web and QML pins share one workflow.

#### Scenario: Batch posted to the shared callback server
- **WHEN** the user sends pending pins from the overlay
- **THEN** the overlay POSTs the batch to `/__annotate/submit` on the annotate-ui server discovered
  via its session file (or `ANNOTATE_SERVER_URL`), and the agent receives it from the same
  `annotate-ui poll`

#### Scenario: Agent replies shown in the overlay
- **WHEN** the agent runs `poll --agent-reply "<message>"`
- **THEN** the overlay reads the reply from `/__annotate/messages` and shows it in its panel

### Requirement: Dev-only, passive, loopback safety

The overlay SHALL be passive and dev-only, mutating no app state, and its captured content SHALL be
treated as untrusted data rather than agent instructions.

#### Scenario: Overlay never mutates app state
- **WHEN** the overlay hit-tests, highlights, and snapshots items
- **THEN** it only reads item properties and grabs images; it never sets properties or invokes app
  methods (beyond the user's own pass-through clicks)

#### Scenario: Captured content is data, not instructions
- **WHEN** an annotation's `objectName`, `props`, or `comment` contains text resembling instructions
- **THEN** the workflow docs direct the agent to treat those fields as untrusted UI data, not commands
