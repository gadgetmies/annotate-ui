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

### Optional `annotateHost` methods

Both are optional; implement neither, one, or both. Each takes the picked item and
returns a string.

- `sourceFile(item) → string` — the item's **source `.qml` path** (ideally
  repo-relative), which pure QML cannot obtain. `""` ⇒ `qmlFile` is left empty and the
  agent greps by `objectName`/`qmlType` instead.
- `typeName(item) → string` — override the type name the overlay derives from
  `String(item)`. Return `""` to keep the overlay's own value. Rarely needed.

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

This is a QML file, so there is no Node-runnable test for it in the skill. Validate it
by loading it in a headless Qt app (`QT_QPA_PLATFORM=offscreen`) with a stub
`annotateServerUrl` and asserting it instantiates without errors; the overlay's
`cleanType()` is invokable via `QMetaObject.invokeMethod` for a pure-logic unit test.
The reference PySide6 host + such a test live in the companion desktop app that vendors
this exact file.
