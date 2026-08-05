## Why

Iterating on a web UI, the fastest way to say "fix this, here" is to point at the actual element on
the running page. No existing skill supports that: `frontend-design` and ecosystem "design review"
skills run agent→self (Claude critiques its own screenshots), and `lavish` has the right
point-and-click-then-poll interaction but only against a generated static HTML artifact, not the
developer's live dev build. This change delivers the missing capability — annotate the live app,
send pins back to the coding agent.

## What Changes

- Add a new **`annotate-ui`** Claude skill: a standalone, framework-agnostic reverse proxy that
  sits in front of any running web dev server, injects a point-and-click annotation overlay into
  `text/html` responses, and tunnels the HMR websocket so the live app (and its backend calls) keep
  working unchanged.
- Ship a zero-dependency Node CLI (`cli.mjs`, Node built-ins only) with four commands:
  `detect` (find the frontend dev URL), `serve --target <url> [--port N] [--open]`,
  `poll [--agent-reply "..."]`, `stop`.
- **Self-healing, configurable proxy port**: precedence `--port` → `ANNOTATE_PORT` → default
  `6100`; a busy default auto-probes upward and prints the real URL; an explicit busy port exits
  with a one-line remedy. Documented in SKILL.md so the agent never debugs `EADDRINUSE`.
- Deliver annotations to the agent push-style via a **long-poll CLI loop** (`poll --agent-reply`),
  mirroring lavish. Each annotation carries: `comment`, unique CSS `selector`, `rect`, `route`,
  `viewport`, `text`, `outerHTML` (capped), `ancestors` + `role`/`a11yName`, and React
  `_debugSource` `file:line` (`null` when absent, so non-React apps still work).
- Package it as a **publishable, MIT-licensed, self-contained** skill installed at the user level
  (`~/.claude/skills/annotate-ui/`), with no reference to this repo, so any developer can drop it
  into any project or install it via `npx skills add <owner/repo@annotate-ui>`.

## Capabilities

### New Capabilities
- `ui-annotation`: point-and-click annotation of a live web dev build via an injected browser
  overlay and a callback proxy server, with annotations streamed to the coding agent through a
  long-poll CLI; framework-agnostic, zero-dependency, and publishable as a standalone skill.

### Modified Capabilities
<!-- None — this is a net-new, self-contained skill and touches no existing spec. -->

## Impact

- **New files only**, under a self-contained skill directory (target install
  `~/.claude/skills/annotate-ui/`): `SKILL.md`, `cli.mjs`, `overlay.js`, `README.md`, `LICENSE`.
- **No changes** to `apps/web`, its `vite.config.ts`, build, or any existing code — the proxy is
  transparent and the skill assumes nothing about this project.
- **Dependencies:** none at runtime (Node ≥18 built-ins only). No new package installs.
- **Security surface:** loopback-bound, dev-only overlay + callback endpoints; injected app
  `outerHTML`/`text` and user `comment` are treated as untrusted data, never agent instructions.
- Supersedes the prior superpowers design note at
  `docs/superpowers/specs/2026-08-02-annotate-ui-skill-design.md` (kept as background; this change
  is the source of truth going forward).
