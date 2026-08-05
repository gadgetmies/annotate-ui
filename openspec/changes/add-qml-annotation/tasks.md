## 1. annotate-ui server-only mode

- [x] 1.1 Make `--target`/`ANNOTATE_TARGET` optional in `cli.mjs serve`; add a server-only path (`--server-only`) that starts the `/__annotate/*` callback server + session file + loopback bind, skipping the reverse proxy and overlay injection
- [x] 1.2 Keep proxy mode byte-identical when a target IS given (no regression to `detect`/`serve`/`poll`/`stop`)
- [x] 1.3 SKILL.md + `serve` usage: document the server-only mode and the QML workflow (`serve --server-only` → `poll`), noting the overlay lives in the app, not the browser

## 2. Desktop install seam (`gui.py`)

- [x] 2.1 Add a `--annotate` flag (dev only; composes with `--hot-reload`) and an `--annotate-screenshots` toggle
- [x] 2.2 Add the small self-contained install block: `if args.annotate: from qml_annotate import install; install(...)` — mirroring the `--hot-reload` block, with the same "delete to remove" comment
- [x] 2.3 Resolve the annotate-ui server base URL from its session file (or `ANNOTATE_SERVER_URL`) and pass it to `install(...)` (via `read_server_url`)

## 3. Overlay module (`qml_annotate.py`)

- [x] 3.1 `install(engine, qml_dir, server_url=None, screenshots=False)`: locate the root `QQuickWindow`, create `AnnotateOverlay.qml` via `QQmlComponent`, parent it into `contentItem`, keep it alive
- [x] 3.2 Hit-test: recursive deepest-visible `childAt(x, y)` excluding the overlay (implemented in the overlay QML, which has direct scene access)
- [x] 3.3 Identity + payload assembly (pure, Qt-free): `objectName`, cleaned `qmlType`, `typeChain`, `qmlFile` (creation-context `baseUrl()` made relative to `qml/`), `props` (`x,y,w,h` + `text`/`enabled`/`visible`), `surface:"qml"`
- [x] 3.4 Optional screenshot: when enabled, `grabToImage` → cropped base64 PNG attached to the pin
- [x] 3.5 Transport bridge: POST batches to `<server_url>/__annotate/submit`; poll `<server_url>/__annotate/messages` for replies (urllib, off the UI thread); tolerate the server being down

## 4. Overlay UI (`qml/AnnotateOverlay.qml`)

- [x] 4.1 Top-layer overlay: hover highlight bound to the hit-tested item's mapped geometry; an on-screen toggle pill showing mode
- [x] 4.2 Interaction: toggle annotate mode (Ctrl+Shift+A + pill); click-to-pin → inline comment box → pending count; Send; Esc exits
- [x] 4.3 Alt/⌥ pass-through: while the modifier is held, suppress the highlight and let the press reach the app; a plain click then annotates
- [x] 4.4 Snapshot-at-pick-time: `beginPin` captures identity + geometry synchronously on pick so a closing popup never invalidates a pending pin

## 5. Tests

- [x] 5.1 Qt-free unit tests (bare `python3`): `qmlType` cleaner, `typeChain`/`qmlFile` relativizer, payload assembly, `read_server_url`, stdlib transport (`post_batch`/`fetch_messages` vs a stub server)
- [x] 5.2 annotate-ui CLI test: `serve --server-only` starts the callback server (no proxy), writes the session file, non-callback paths 404, and a `submit` → blocked `poll` round-trip works with no target
- [x] 5.3 Headless PySide6 tests (venv, offscreen): bridge `_item_info` reads real item identity/geometry; `beginPin`/`commitPin` flow; `AnnotateOverlay.qml` parses + its `annotateBridge` bindings resolve
- [ ] 5.4 Manual live pass: `annotate-ui serve --server-only` + `gui.py --annotate` → pin an element (incl. inside a popup via Alt-click) → confirm it arrives via `annotate-ui poll`, and an `--agent-reply` shows in the overlay  *(requires a live desktop session)*

## 6. Docs

- [x] 6.1 `--annotate`/`--annotate-screenshots` documented via `gui.py --help` + the `qml_annotate.py` module docstring — the same self-documenting convention as `--hot-reload` (no separate docs entry exists for it)
- [x] 6.2 Known limitations recorded (no exact line → grep-resolved; use-site file for reused components; optional screenshot off by default) — in proposal.md / design.md / spec
