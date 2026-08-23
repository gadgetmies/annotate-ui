## ADDED Requirements

### Requirement: Typed changelog message on the agent→overlay channel

The agent→overlay `messages` channel SHALL support a **typed** message carrying a structured
changelog, in addition to the existing plain-text reply. A changelog message SHALL be identifiable by
a `type: "changelog"` discriminator and carry a `changelog` array of entries; a plain reply SHALL
remain identifiable as before. The `poll` command SHALL accept a `--changelog <file|json>` input that
posts such a message via `/__annotate/reply`, and MAY be combined with `--agent-reply`.

#### Scenario: poll --changelog posts a typed message
- **WHEN** `poll --changelog <file|json>` is run against a live session
- **THEN** the CLI reads/validates the changelog, posts a message with `type: "changelog"` and the
  entries to `/__annotate/reply`, and it is delivered to overlays via `/__annotate/messages`

#### Scenario: Typed and plain messages coexist
- **WHEN** an overlay reads `/__annotate/messages`
- **THEN** it can distinguish a `type: "changelog"` message from a plain-text reply and render each
  appropriately, and an overlay that does not understand the type ignores it without error

#### Scenario: Backward compatibility of the reply channel
- **WHEN** `poll --agent-reply "<msg>"` is run with no `--changelog`
- **THEN** the message channel behaves exactly as before (plain text reply), with no changelog field

### Requirement: Verification item shape in the submit payload

The overlay→agent submit payload SHALL support a verification item in the `annotations` array,
identified by `kind: "verification"`, in addition to element pins and `kind: "note"` freeform notes.
A verification item SHALL carry the `changelogId` of the entry it answers and the user's `comment`,
and MAY carry element context (web `selector`/`route`/`source`/`outerHTML`; QML `objectName`/
`qmlType`/`qmlFile`/`typeChain`) auto-linked from the changelog entry or captured by a re-pin. Element
pins and freeform notes are unchanged.

#### Scenario: Submit includes a verification item
- **WHEN** the overlay submits a batch containing a rejected changelog entry
- **THEN** the batch's `annotations` array includes an item with `kind: "verification"`, its
  `changelogId`, and `comment`, plus context fields when available

#### Scenario: Existing item shapes unchanged
- **WHEN** the overlay submits element pins and `kind: "note"` freeform notes
- **THEN** those items keep their existing shape and the agent renders them exactly as before

#### Scenario: Agent renders verification items in its summary
- **WHEN** the agent receives a batch via `poll` that contains `kind: "verification"` items
- **THEN** the markdown summary presents each as a verification issue tied to its `changelogId` and
  context, distinct from element pins and freeform notes
