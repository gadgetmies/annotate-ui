## Why

The `annotate-ui` skill only annotates **web** dev builds — it works by proxying a dev server,
injecting a DOM overlay, and reading React fibers. The companion desktop app (`apps/desktop`) is a
native **PySide6 / Qt Quick (QML)** application: there is no DOM, no HTML to inject, and no proxy
seam. Reviewing its UI today means describing elements in prose — exactly the friction annotate-ui
removed for the web. This change extends the same point-and-click-then-poll workflow to a running
QML app, reusing the annotate-ui callback server and `poll` loop so web and QML pins share one
workflow.

## What Changes

- Add a **`qml-annotation`** capability: a self-contained, opt-in, **dev-only in-process overlay**
  for a running PySide6/QML app that hit-tests the Qt Quick item under the cursor, pins comments,
  and streams them to the coding agent.
- Mirror the existing `hot_reload.py` precedent exactly: a new `apps/desktop/qml_annotate.py` plus a
  bundled `apps/desktop/qml/AnnotateOverlay.qml`, installed from `gui.py` behind a new `--annotate`
  flag (composes with `--hot-reload`). Deleting the file(s) + the small `if args.annotate:` install
  block removes the feature entirely.
- **Reuse the annotate-ui transport**: the overlay POSTs annotation batches to the shared
  `/__annotate/submit` server and reads `/__annotate/messages` for agent replies; the agent keeps
  using the same `annotate-ui poll`.
- Extend the annotate-ui CLI with a **server-only mode** (`serve` with `--target` made optional) so
  the callback server can run for a non-web surface with no reverse proxying.
- Capture per pin: `comment`, `objectName`, `qmlType`, `typeChain`, `qmlFile` (creation-context base
  URL, repo-relative), `props` (geometry + a few key props), `surface: "qml"`, and an **optional**
  cropped screenshot. No exact source line — it is grep-resolved by `objectName`/`qmlType`, the same
  graceful degradation the web overlay uses when React `source` is `null`.
- Carry over the web interaction lessons: a toggled annotate mode, click-to-pin, **Alt/⌥ pass-through**
  to operate app popups/menus/dropdowns, and **snapshotting the pin context at pick time** so a
  closing popup never invalidates it.

## Capabilities

### New Capabilities
- `qml-annotation`: point-and-click annotation of a running PySide6/QML desktop app via an in-process
  dev-only overlay that hit-tests Qt Quick items, delivered to the coding agent through the shared
  annotate-ui callback server and long-poll CLI.

### Modified Capabilities
- `ui-annotation`: the `serve` command gains a **server-only mode** (callback server without the
  reverse proxy) so non-web surfaces — like the QML overlay — can use the same `/__annotate/*`
  endpoints and `poll` loop.

## Impact

- **Desktop app (`apps/desktop`):** new dev-only files `qml_annotate.py` and `qml/AnnotateOverlay.qml`;
  a `--annotate` flag + a small self-contained install block in `gui.py` (mirrors `--hot-reload`); new
  Qt-free tests under `apps/desktop/tests/`. **No shipping-path behavior change** — the overlay only
  exists under `--annotate` and is otherwise inert.
- **annotate-ui skill:** `cli.mjs` gains an optional-`--target` server-only serve mode (+ a CLI test);
  `overlay.js` is untouched.
- **Dependencies:** none new — PySide6 is already the desktop stack; the skill stays Node-built-ins
  only.
- **Security surface:** the overlay is dev-only, passive (it never mutates app state), and the server
  stays loopback-bound; captured `objectName`/`props`/`comment` are treated as untrusted data
  describing the UI, never agent instructions (same rule as the web overlay).
- **Known limitations (accepted):** no exact source line (grep-resolved); reused Qt Quick components
  report their **use-site** file via the creation context; the overlay resets no app state (it is a
  passive top-layer, not a reload).
