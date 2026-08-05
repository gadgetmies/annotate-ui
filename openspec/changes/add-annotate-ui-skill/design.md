## Context

Fast UI iteration needs a way for the developer to point at a real element on the running app and
say "fix this here", with enough context for the coding agent to act. `lavish` already proves the
interaction — pin comments on DOM elements in a browser, stream them to the agent via a long-poll
`poll` CLI — but only against a generated static HTML artifact served by its own server. This change
applies the same loop to the **live dev build** of any project.

Constraints that shape the design:
- Must not assume this repo's structure (it targets `apps/web` today but must work anywhere).
- Must keep the app fully functional through the proxy — including its own API proxying and HMR.
- Must be publishable and dependency-free so any developer can install and reuse it.
- Modeled on lavish's server + long-poll conventions (foreground poll, nothing lost on reconnect).

Background design note (superseded, kept for history):
`docs/superpowers/specs/2026-08-02-annotate-ui-skill-design.md`.

## Goals / Non-Goals

**Goals:**
- Point-and-click annotation on the live running app (real DOM, real backend, HMR intact).
- Annotations rich enough to locate/fix without guessing (selector, rect, route, viewport, text,
  outerHTML, ancestor/a11y, React source `file:line` when present).
- Push-style delivery to the agent via a long-poll CLI with an agent→browser reply channel.
- Repo/framework-agnostic; zero runtime dependencies; user-level, publishable install.

**Non-Goals:**
- Screenshot/pixel capture (dropped — avoids an `html2canvas` dependency; rect+outerHTML+source
  locate the element).
- Editing the target project's build/config (rejected in favor of a transparent proxy).
- Production use (dev-only, loopback-bound).
- Auto-starting the user's dev server (detect + ask; never guess project scripts).
- Multi-session concurrency (one active `serve` session at a time in v1).

## Decisions

### D1 — Standalone reverse proxy (not a Vite plugin, not a static-build server)
Sit a proxy in front of whatever dev server the project runs; inject the overlay into `text/html`
responses and raw-tunnel websocket upgrades. *Why:* a Vite plugin would edit this repo's config and
only serve React/Vite apps; a static-build server loses HMR and the live backend. A proxy is
framework-agnostic and requires **no change to the target repo**, which is what makes the skill
publishable. *Alternatives:* Vite plugin (rejected — invasive, framework-locked), static `dist/`
server (rejected — no HMR/API), browser extension (rejected — install friction, not agent-drivable).

### D2 — Node built-ins only, ephemeral single-session server
Implement the proxy with `http` + `net` (raw socket for `upgrade`) and no npm packages. Requests are
re-issued upstream with `Accept-Encoding: identity` so HTML never needs gunzipping before injection;
HTML responses are buffered (small) and injected, everything else streams. *Why:* zero-dependency =
trivially portable and publishable; `identity` encoding sidesteps a compression dependency.
*Alternative:* `http-proxy`/`express` (rejected — adds deps, defeats the portability goal).

### D3 — Callback surface under `/__annotate/*`, discovered via a session file
The proxy owns `overlay.js`, `submit`, `poll`, `reply`, `messages`, `shutdown` under `/__annotate/`
(a prefix unlikely to collide with app routes) and never forwards them. `serve` writes
`~/.annotate/session.json` (`{port, target, pid, url}`, overridable via `$ANNOTATE_STATE_DIR`) so
`poll`/`stop` — separate processes — find the running server over HTTP. *Why:* separate short-lived
processes need a rendezvous; a small state file mirrors how lavish keys a session. Queues are
in-memory with a monotonically increasing `batchId` so a reconnecting `poll` acknowledges drained
batches and never re-emits.

### D4 — Self-healing, precedence-ordered port
Resolve port as `--port` → `ANNOTATE_PORT` → `6100`. A busy **default** probes upward (bounded) and
prints the real URL; a busy **explicit** port exits with a one-line remedy. SKILL.md documents this
and instructs the agent to read the URL from `serve` output rather than assuming `6100`. *Why:* the
single most likely startup snag is a taken port; auto-healing the default removes agent debugging
while an explicit port stays predictable.

### D5 — Overlay as an isolated, self-contained client
`overlay.js` renders a shadow-DOM-isolated toggle + comment popover + pending-list panel, so the
app's CSS can neither restyle nor collide with it, and the overlay excludes its own DOM from element
targeting. Annotate-mode clicks are captured (`preventDefault`/`stopPropagation`) so the app doesn't
receive them. Pending pins persist in `sessionStorage` to survive an HMR reload mid-annotation.
Selector strategy: prefer `#id`, then `[data-*]` test ids, then `tag.classes:nth-of-type(k)` walking
up until the selector resolves to exactly one node. React source: read the DOM node's
`__reactFiber$*`/`__reactInternalInstance$*` key and walk `return`/`_debugOwner` to the nearest
`_debugSource`; `null` if absent — never throws.

### D6 — Long-poll loop with an agent→browser reply channel
`poll [--agent-reply] [--timeout≈25]` optionally posts a reply (surfaced in the overlay via
`GET /__annotate/messages`), then blocks on `GET /__annotate/poll` until a batch arrives or it times
out (exit empty; re-run). Output is JSON **plus** a markdown summary. *Why:* mirrors lavish's proven
foreground loop and two-way conversation; server-side queuing makes reconnects lossless.

## Risks / Trade-offs

- **HTML injection breaks a page (strict CSP, unusual encoding)** → inject only into `text/html`,
  request `identity` encoding, insert at a robust anchor with fallbacks; SKILL.md notes that a page
  with a script-src CSP may need the overlay allowed, and the app is otherwise untouched.
- **Websocket/HMR tunnel edge cases** → raw `net` pipe of the `upgrade` in both directions; covered
  by an integration test with a ws echo upstream.
- **React source absent (prod build / non-React)** → treated as expected; `source: null` with all
  other fields intact, verified by a scenario.
- **Selector not unique on dynamic DOM** → build the selector by widening until
  `querySelectorAll(...).length === 1`; `outerHTML` + `ancestors` + `a11yName` give the agent
  fallbacks when the DOM shifts before a fix.
- **Global single-session state file collides across projects** → v1 is single-session by design;
  `$ANNOTATE_STATE_DIR` allows per-project isolation; multi-session is a future non-goal.
- **Injected app content is untrusted** → SKILL.md instructs treating `outerHTML`/`text`/`comment`
  as data, never instructions (mirrors DesignSync's caution).

## Migration Plan

Net-new, additive skill; no rollback of existing behavior needed. Deploy by placing the directory at
`~/.claude/skills/annotate-ui/` (or publishing to its own repo for `npx skills add`). Removing the
skill directory fully reverts. No changes to `apps/web` or any existing code.

## Open Questions

None blocking. Deferred (future): multi-session support, optional flagged screenshot capture, and
non-React source resolution via framework devtools hooks (Vue/Svelte).
