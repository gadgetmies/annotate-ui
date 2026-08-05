## Context

`annotate-ui` proxies a web dev server and injects a DOM overlay; the coding agent receives pins via
a long-poll CLI. The desktop app is native Qt Quick — `gui.py` builds a `QQmlApplicationEngine`,
registers the `Controller` as the QML singleton `App`, and loads `qml/Main.qml`. There is already a
self-contained, opt-in dev module for QML — `hot_reload.py`, installed from `gui.py --hot-reload` and
documented as "delete the file + the small block to remove." That precedent defines the shape of this
feature: an in-process, dev-only, deletable overlay — not an external tool.

Qt Quick exposes exactly what a point-and-click annotator needs from Python: the root window is a
`QQuickWindow`; items can be hit-tested from `contentItem` (`childAt`, recursed); each item's
creation context (`QQmlEngine.contextForObject(item).baseUrl()`) yields its **source file**; the
item's `metaObject().className()` yields its **type**; `grabToImage()` yields a **screenshot crop**.
The one thing Qt does *not* expose through PySide's public surface is the exact source **line**
(stored in private `QQmlData`); this design accepts a grep-resolved file+type+objectName instead.

## Goals / Non-Goals

**Goals**
- Point at a live QML element, type a comment, send it to the agent — reusing the annotate-ui server
  and `poll` so QML and web pins share one workflow.
- Self-contained, opt-in, dev-only, and trivially removable (the `hot_reload.py` contract).
- Robust against Qt Quick popups/menus that close on outside interaction.

**Non-Goals**
- Exact source line numbers (grep-resolved from `qmlFile` by `objectName`/`qmlType`).
- Any change to shipping behavior, or any dependency on Qt private/debug APIs.
- A second annotation transport — it rides the existing `/__annotate/*` server.

## Decisions

### D1 — In-process QML overlay, not an external attach
Inject the overlay into the running scene (parented into the root window's `contentItem` at top z),
rather than attaching externally via Qt's QML-debug connector (`-qmljsdebugger`) or a separate overlay
window. The app runs on `QGuiApplication` (no QtWidgets), and the debug-connector protocol is heavy
and fragile to speak from Python. In-process matches the `hot_reload.py` precedent and gives direct,
public-API introspection.

### D2 — Self-contained, opt-in, deletable module (the hot-reload contract)
Ship `apps/desktop/qml_annotate.py` + `apps/desktop/qml/AnnotateOverlay.qml`, installed from a
`if args.annotate: from qml_annotate import install; install(engine, ...)` block in `gui.py`,
mirroring `--hot-reload`. `AnnotateOverlay.qml` is loaded by `qml_annotate.py` via `QQmlComponent`
and is **not** referenced by `Main.qml`, so it never enters the shipping tree.

### D3 — Reuse the annotate-ui callback server (server-only serve mode)
The overlay's Python bridge POSTs batches to `http://127.0.0.1:<port>/__annotate/submit` and GETs
`/__annotate/messages` for replies — the exact endpoints the web overlay uses. To run that server
for a non-web surface, `annotate-ui serve` gains a server-only mode: `--target` becomes optional; with
no target it starts the `/__annotate/*` callback server + session file and skips the reverse proxy and
overlay injection. The overlay discovers the port from the session file (or `ANNOTATE_SERVER_URL`).
The agent uses the unchanged `annotate-ui poll`.

### D4 — Hit-testing + element identity
On a pin, hide the overlay for the hit-test, then walk `contentItem.childAt(x, y)` recursively
(mapping coordinates into each child) to the deepest visible, non-overlay item. Identity is captured
as: `objectName` (when set — the app already uses it widely, e.g. in QML tests), `qmlType` (cleaned
`metaObject().className()`, stripping Qt's `QQuick`/`_QMLTYPE_`/`QMLTYPE` decorations), `typeChain`
(the ancestor items' types), and `qmlFile` (creation-context `baseUrl()`, made repo-relative to
`qml/`). Between file + objectName + type, the agent greps straight to the element.

### D5 — Interaction model carried over from the web overlay
A toggled annotate mode (key chord + an on-screen pill); hover highlights the item under the cursor;
click pins an inline comment box appended to a pending list; **Alt/⌥-click passes the click through**
to the app so `Popup`/`Menu`/`ComboBox` can open, then a plain click inside annotates their contents;
Esc exits. The pin **context is snapshotted at pick time** (identity + geometry captured immediately),
so a popup closing while the comment box is open never invalidates the pin — the direct port of the
web overlay's fix.

### D6 — Optional screenshot
Per review, the screenshot is **optional and off by default** (a panel toggle / `--annotate-screenshots`).
When enabled, each pin includes a cropped PNG (base64) of the item via `grabToImage`/`QQuickItemGrabResult`.
When disabled, the payload relies on file + objectName + type + props, which the agent grep-resolves.

## Payload

Per pin (`surface: "qml"`): `comment`, `objectName`, `qmlType`, `typeChain`, `qmlFile`, `props`
(`{x, y, w, h}` plus a small set like `text`/`enabled`/`visible` when present), `route` (the active
view/screen name when discoverable, else the window title), and optional `screenshot`. Field names
deliberately overlap the web payload (`comment`, `rect`→`props` geometry, `route`) so the agent's
existing markdown summary renders both surfaces.

## Risks / Trade-offs

- **No exact line** — mitigated by objectName+type+file grep; matches the web tool's `source: null`
  degradation. Exact line would need the QML-debug connector (deferred).
- **Reused components report the use-site file** via the creation context — usually what you want; the
  `qmlType` still names the component, so the agent can open either.
- **Overlay stealing focus/press from a closing popup** — mitigated by snapshot-at-pick-time (D5) so
  the pin survives regardless of what the click closes.
- **Coordinate mapping across nested items / scale** — hit-test maps coordinates per level via
  `mapToItem`/`childAt` to stay correct under transforms.

## Migration Plan

Additive and dev-only. No migration: `--annotate` is off by default; absent the flag the new module is
never imported and the shipping tree is byte-unchanged. The annotate-ui `serve` change is backward
compatible (`--target` still works exactly as before; only its absence is newly permitted).

## Open Questions

- Toggle affordance: key chord only vs. an always-visible dev pill (leaning: both — a pill that also
  shows the mode, like the web toggle).
- `route` for QML: best-effort active-view name vs. window title when no view id is resolvable.
