# QML overlay — host contract

`AnnotateOverlay.qml` is a **generic, self-contained** Qt Quick annotation overlay.
It does its own transport (`XMLHttpRequest`), hit-testing, type introspection
(`String(item)`), geometry capture, and pending-pin state — so a host needs almost
no code to use it. This file is the whole contract for wiring it into a running
Qt Quick app (C++ **or** Python) and for what it emits.

## What the host must do

1. **Run an annotate-ui callback server** (once, outside the app):

       annotate-ui serve --server-only      # prints its base URL; then `annotate-ui poll`

2. **Inject two context properties** before creating the overlay, then **parent the
   overlay into the window's `contentItem`.**

   | Context property | Type | Meaning |
   |---|---|---|
   | `annotateServerUrl` | `string` | Callback base URL (e.g. `http://127.0.0.1:6100`). `""` ⇒ the panel shows a "no server" hint and **Send** is disabled. |
   | `annotateHost` | `QObject` or `null` | **Optional.** If set, the overlay calls the methods below; if `null`/absent it degrades gracefully. |

   The overlay guards both with `typeof`, so it still loads if a host forgets one —
   but set both for a clean integration.

3. **Don't change the overlay root's pointer handling.** Parented into `contentItem` at
   its high `z`, the root covers the whole window *above* the popup layer
   (`Overlay.overlay`). While a modal popup is open, Qt Quick Controls drops every wheel
   event whose top item under the pointer lies outside that popup, and it judges "under
   the pointer" by geometry alone, painted or not. A plain full-window root would
   therefore make every modal dialog in the app impossible to scroll while the overlay
   is installed. The overlay gives its root an empty `containmentMask`, so the root
   itself is never hit and only its children (the pill, the panel, the capture layer
   while annotating) take input. Keep that, don't wrap the overlay in another
   full-window item, and don't replace the mask from the host. Harmonia hit this in its
   "Report a problem" dialog; `test/qml/tst_modal_wheel.qml` guards it.

### Optional `annotateHost` methods

All are optional; implement any subset. If a hook is absent the overlay degrades
gracefully (no persistence, or its own derived value).

- `sourceFile(item) → string` — the item's **source `.qml` path** (ideally
  repo-relative), which pure QML cannot obtain. `""` ⇒ `qmlFile` is left empty and the
  agent greps by `objectName`/`qmlType` instead.
- `typeName(item) → string` — override the type name the overlay derives from
  `String(item)`. Return `""` to keep the overlay's own value. Rarely needed.
- `loadPending() → string` / `savePending(json: string)` — **pending-pin
  persistence.** When both are present the overlay mirrors its queued pins to
  durable storage: it calls `savePending(JSON.stringify(pins))` whenever the queue
  changes (and `savePending("[]")` after a successful Send), and calls
  `loadPending()` on startup to restore them. The host stores the raw JSON string
  verbatim (it never parses it — the overlay owns the payload shape). This is what
  makes annotations survive a quit/crash or a relaunch-to-fix-the-URL; without the
  hooks the queue is in-memory only. (Reference host: writes
  `$ANNOTATE_STATE_DIR/pending.json`, clearing the file on an empty queue.)
- `loadVerdicts() → string` / `saveVerdicts(json: string)` — **checklist-verdict
  persistence** (optional, independent of the pending hooks). The callback server
  re-delivers its last changelog to a freshly started overlay, so without these an app
  restart lists every changelog item as unchecked again. When both are present the
  overlay calls `saveVerdicts(json)` whenever a verdict changes and `loadVerdicts()` once
  on startup. The value is a JSON object keyed by changelog id —
  `{ "<id>": { "hash", "state": "verified"|"rejected", "comment", "sent", "at" } }`
  (`sent` = the verdict already went out with a Send) —
  that the host stores verbatim and never parses; `"{}"` means no verdicts. `hash` covers
  the entry's title, description and context, so when the agent re-delivers an id with
  changed content the stored verdict no longer matches and the row comes back unchecked;
  an unchanged re-delivery of a sent verdict stays hidden.
  The overlay keeps at most 500 verdicts (oldest dropped). Without the hooks verdicts
  are in memory only, as before. (Reference host: `$ANNOTATE_STATE_DIR/verdicts.json`.)

### Connection confirmation (overlay-side, no host code)

The overlay probes `GET <serverUrl>/__annotate/messages` and only lets the user
**enter annotate mode once the server has answered** — so pins are never made
against a dead server and lost. The pill reflects live reachability
(`✎ Annotate` / `⚠ server offline` / `… Connecting`), and when disconnected the
panel exposes a field to **set/correct the server URL at runtime**
(`serverUrlOverride`), so a wrong or unset startup URL is recoverable without
relaunching. None of this needs host code.

## Resolving `annotateServerUrl`

The server writes a session file the host can read (same discovery the Python and
CLI sides use): `$ANNOTATE_SERVER_URL`, else `$ANNOTATE_STATE_DIR/session.json`
(default `~/.annotate/session.json`), whose `url` field is the base URL.

## Emitted payload (wire contract)

The overlay POSTs `{ "annotations": [ … ] }` to `<serverUrl>/__annotate/submit` and
reads replies from `<serverUrl>/__annotate/messages?since=<n>` every 3s. Each element
pin carries:

    { "surface": "qml", "comment": "...",
      "objectName": "...", "qmlType": "Button", "typeChain": ["View","Row"],
      "qmlFile": "Foo.qml",           // "" when no sourceFile() host hook
      "props": { "x":.., "y":.., "w":.., "h":.., "text":.., "enabled":.., "visible":.. },
      "rect":  { "x":.., "y":.., "w":.., "h":.. },
      "route": "" }

A freeform note (from the composer) instead carries:

    { "surface": "qml", "kind": "note", "comment": "..." }

`kind:"note"` is the shared contract the CLI renders as "freeform note (not tied to a
specific element)". A `screenshot` field (a data URL) is part of the contract but the
generic overlay never sets it — pure QML can't produce base64; a future host hook may.

### Changelog verification (typed reply message + verification item)

The overlay also renders an agent-delivered **changelog** as a per-row Verified/Rejected
checklist. This needs **no new host hooks** — it rides the existing `/__annotate/messages`
reply channel and the existing `/__annotate/submit` queue (and its `savePending` persistence).

The agent delivers the changelog (via `annotate-ui poll --changelog`) as a **typed** message on
`<serverUrl>/__annotate/messages`, alongside plain replies:

    { "id": 7, "type": "changelog",
      "changelog": [
        { "id": "c1", "title": "Star now gold", "description": "…",
          "context": { "objectName": "starBtn", "qmlType": "Button",
                       "qmlFile": "Rating.qml", "typeChain": ["Row"] } },
        { "id": "c2", "title": "Debounced search" }          // no context → display-only
      ] }

The overlay branches on `type`: a `"changelog"` message becomes the checklist; a plain reply (no
`type`) is shown as a message line; an **unknown `type` is ignored** without error. When the user
**Rejects** a row, describes the issue and clicks **Add to batch** (or presses Ctrl/⌘+Enter), the
overlay queues a verification item into the same pending array it POSTs to `/__annotate/submit`
(typing alone queues nothing; Cancel/Esc closes the box; an added rejection shows on its row with
**Edit** / **Undo**). Clicking **Verified** queues a sign-off the same way (a second click undoes
it). Both are sent with the panel's next **Send** (whose label counts sign-offs separately, e.g.
"Send 1 · 2 verified to agent"), never on their own:

    { "surface": "qml", "kind": "verification", "verdict": "rejected",
      "changelogId": "c1", "title": "Star now gold", "comment": "still orange after the fix",
      // context auto-linked from the entry, or replaced by a re-pin:
      "objectName": "starBtn", "qmlType": "Button", "qmlFile": "Rating.qml", "typeChain": ["Row"] }

    { "surface": "qml", "kind": "verification", "verdict": "verified",
      "changelogId": "c2", "title": "Debounced search", "comment": "",
      "objectName": "", "qmlType": "", "qmlFile": "", "typeChain": [] }

After a successful Send the sent rows leave the checklist (rows not in that Send stay); when
none are left the checklist section disappears. With the `loadVerdicts`/`saveVerdicts` hooks the
sent verdicts stay hidden when the server re-delivers the same ids (e.g. after an app restart),
and verdicts still waiting for Send come back on their rows, until the agent re-delivers an id
with changed content, which shows it again unchecked.

`kind:"verification"` is the shared discriminator (the web overlay emits the same shape with its DOM
context fields). An item without `verdict` (from an older overlay) means rejected.
All `title`/`description`/`comment` strings are rendered via `Text` only, never as markup.

## Host shim sketch — C++

```cpp
// annotateServerUrl from env/session file; AnnotateHost is optional.
class AnnotateHost : public QObject {
    Q_OBJECT
public:
    Q_INVOKABLE QString sourceFile(QQuickItem *item) {
        if (auto *ctx = QQmlEngine::contextForObject(item))
            return relativeToQmlRoot(ctx->baseUrl().toLocalFile()); // your helper
        return QString();
    }
    Q_INVOKABLE QString typeName(QQuickItem *) { return QString(); } // "" = keep QML's
};

engine.rootContext()->setContextProperty("annotateServerUrl", serverUrl);
engine.rootContext()->setContextProperty("annotateHost", new AnnotateHost(&engine));

QQmlComponent comp(&engine, QUrl::fromLocalFile("AnnotateOverlay.qml"));
auto *overlay = qobject_cast<QQuickItem *>(comp.create());
overlay->setParentItem(window->contentItem());
```

## Host shim sketch — PySide6 / PyQt

```python
from PySide6.QtCore import QObject, Slot
from PySide6.QtQml import QQmlEngine, QQmlComponent, QQmlContext
from PySide6.QtCore import QUrl
from PySide6.QtQuick import QQuickItem, QQuickWindow

class AnnotateHost(QObject):
    @Slot(QQuickItem, result=str)
    def sourceFile(self, item):
        ctx = QQmlEngine.contextForObject(item)
        base = ctx.baseUrl().toString() if ctx and ctx.baseUrl() else ""
        return relativize(base)          # your repo-relative helper, "" if unknown
    @Slot(QQuickItem, result=str)
    def typeName(self, item):
        return ""                        # "" = keep the overlay's String(item) value

ctx = QQmlContext(engine.rootContext(), engine)
ctx.setContextProperty("annotateServerUrl", server_url or "")
ctx.setContextProperty("annotateHost", AnnotateHost(engine))
comp = QQmlComponent(engine, QUrl.fromLocalFile("AnnotateOverlay.qml"))
overlay = comp.create(ctx)
overlay.setParentItem(window.contentItem())
```

Standalone (no host object at all): set `annotateServerUrl` and skip `annotateHost` —
you get every field except `qmlFile`, which stays empty.

## Testing note

This is a QML file, so it has no Node-runnable test. It is validated offscreen with
`qmltestrunner`: `test/qml/tst_changelog.qml` loads the overlay headless
(`QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic`) and exercises the
changelog-verification logic (parse, reject→queue, verify→remove, re-pin, mixed batch) —
run it with `npm run test:qml`. You can validate a host integration the same way: load the
overlay with a stub `annotateServerUrl` and assert it instantiates without errors; the
overlay's `cleanType()` is invokable via `QMetaObject.invokeMethod` for a pure-logic unit
test. The reference PySide6 host lives in the companion desktop app that vendors this file.
