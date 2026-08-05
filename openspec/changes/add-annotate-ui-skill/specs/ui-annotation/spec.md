## ADDED Requirements

### Requirement: Transparent overlay-injecting reverse proxy

The skill SHALL run a reverse proxy that forwards all traffic to a target dev server URL and injects
the annotation overlay `<script>` into HTML responses, while leaving every other response and the
live-reload websocket untouched, so the running app behaves identically except for the added overlay.

#### Scenario: Overlay injected into HTML responses
- **WHEN** a browser requests a page whose upstream response has `Content-Type: text/html`
- **THEN** the proxy returns that HTML with exactly one `<script src="/__annotate/overlay.js">` tag
  inserted before `</head>` (falling back to before `</body>`, then append), and with a corrected
  `Content-Length`

#### Scenario: Non-HTML assets pass through unmodified
- **WHEN** a browser requests a JS, CSS, image, or JSON asset through the proxy
- **THEN** the proxy streams the upstream bytes through byte-for-byte with no injection

#### Scenario: HMR websocket keeps working
- **WHEN** the dev server initiates a websocket `upgrade` (e.g. Vite HMR / live reload)
- **THEN** the proxy raw-tunnels the upgrade to the target so hot-module reload continues to function

#### Scenario: Callback routes are served locally, never forwarded
- **WHEN** a request path begins with `/__annotate/`
- **THEN** the proxy handles it locally and does not forward it to the target dev server

### Requirement: Configurable, self-healing proxy port

The proxy port SHALL be resolved as `--port` flag, then `ANNOTATE_PORT` environment variable, then
default `6100`, and SHALL avoid failing on a busy default so the agent never has to debug startup.

#### Scenario: Default port is available
- **WHEN** `serve` runs with no port override and `6100` is free
- **THEN** the proxy binds `6100` and prints its URL `http://127.0.0.1:6100`

#### Scenario: Default port is busy
- **WHEN** `serve` runs with no port override and `6100` is in use
- **THEN** the proxy probes upward (`6101`, `6102`, … up to a bounded limit), binds the first free
  port, and prints the actual URL it bound

#### Scenario: Explicit port is busy
- **WHEN** `serve` runs with an explicit `--port`/`ANNOTATE_PORT` that is in use
- **THEN** the command exits non-zero with a one-line remedy naming the busy port and telling the
  caller to pass a different `--port`

### Requirement: Frontend target discovery

The skill SHALL provide a `detect` command that reports candidate running frontend dev URLs so the
agent can determine the target without assuming any project-specific port or setup.

#### Scenario: Exactly one dev server found
- **WHEN** `detect` runs and exactly one probed local port responds to `GET /` with `text/html`
- **THEN** it prints that single URL as the recommended target

#### Scenario: Zero or multiple candidates
- **WHEN** `detect` finds no HTML candidate, or more than one
- **THEN** it prints the full candidate list (possibly empty) so the agent can ask the user which
  URL to target, and the skill never starts the user's dev server on its behalf

### Requirement: Annotation context payload

Every annotation delivered to the agent SHALL carry enough context to locate and fix the element
without guessing: a user comment, a uniquely-resolving CSS selector, the element's bounding rect,
the page route, the viewport, the trimmed text, a capped `outerHTML`, an ancestor/accessibility
summary, and — when available — the React source location.

#### Scenario: Baseline fields are always present
- **WHEN** the user pins a comment on any element and sends it
- **THEN** the annotation includes `comment`, `selector`, `rect`, `route`, `viewport`, and `text`,
  and the `selector` resolves to exactly one element via `document.querySelectorAll`

#### Scenario: Enrichment fields are included
- **WHEN** an annotation is produced
- **THEN** it also includes `outerHTML` (capped, children collapsed), `ancestors`, `role`, and
  `a11yName`

#### Scenario: React source when available, null otherwise
- **WHEN** the pinned element's React fiber exposes `_debugSource` (a dev build using the React JSX
  source transform)
- **THEN** `source` is `{file, line, column, component}`
- **WHEN** no React source information is present (production build or non-React app)
- **THEN** `source` is `null` and all baseline and enrichment fields are still produced

### Requirement: Long-poll annotation delivery loop

Annotations SHALL reach the coding agent push-style through a long-poll CLI that mirrors lavish: the
agent blocks on `poll`, receives batches when the user sends them, and can reply back into the
browser, with no annotation lost across reconnects.

#### Scenario: Poll returns a sent batch
- **WHEN** the agent is blocked on `poll` and the user clicks Send in the overlay
- **THEN** `poll` returns the batch as both machine-readable JSON and a human-readable markdown
  summary, then exits so the agent can act and re-run

#### Scenario: Poll timeout loses nothing
- **WHEN** no batch is sent before the poll timeout elapses
- **THEN** `poll` exits with an empty result and any batch sent afterward is still delivered on the
  next `poll` (batches are queued server-side until drained, keyed by an increasing id)

#### Scenario: Agent reply reaches the browser
- **WHEN** the agent runs `poll --agent-reply "<message>"`
- **THEN** the message is posted to the overlay and shown in its panel before the poll begins waiting

### Requirement: Portable, zero-dependency, publishable skill

The skill SHALL be self-contained with no runtime package dependencies, install at the user level,
and be publishable and reusable in any project by any developer without reference to this repository.

#### Scenario: Runs with only Node built-ins
- **WHEN** the skill's CLI is executed on a machine with Node ≥18 and no `npm install`
- **THEN** all commands (`detect`, `serve`, `poll`, `stop`) run using only Node built-in modules

#### Scenario: User-level install and standalone publish
- **WHEN** the skill directory is copied to `~/.claude/skills/annotate-ui/` or installed via
  `npx skills add <owner/repo@annotate-ui>`
- **THEN** it works against any project's dev server, containing `SKILL.md`, `cli.mjs`, `overlay.js`,
  `README.md`, and an MIT `LICENSE`, with no path or content tying it to this repository

### Requirement: Dev-only, loopback-bound safety

The overlay and callback endpoints SHALL exist only while the proxy runs, bind to loopback only, and
treat captured page content and user comments as untrusted data rather than agent instructions.

#### Scenario: Loopback binding
- **WHEN** the proxy starts
- **THEN** it binds `127.0.0.1` only and injects the overlay solely into responses it proxies while
  running — never into a production build

#### Scenario: Captured content is data, not instructions
- **WHEN** an annotation's `outerHTML`, `text`, or `comment` contains text resembling instructions
- **THEN** SKILL.md directs the agent to treat those fields as untrusted data describing the UI, not
  as commands to execute
