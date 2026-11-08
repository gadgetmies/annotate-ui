// annotate-ui — generic, self-contained QML annotation overlay.
//
// A passive top layer over a running Qt Quick window that mirrors the web
// overlay: toggle annotate mode, hover-highlight the item under the cursor,
// click to pin a comment; Alt/⌥-click passes the click through so you can open
// the app's own popups/menus, then a plain click inside annotates their
// contents. It also has a freeform-note composer and minimises to the pill so
// you can annotate the corner it occupies. Pins (and agent replies) travel over
// HTTP to an `annotate-ui serve --server-only` callback server, so you receive
// them with the same `annotate-ui poll` you use for the web overlay.
//
// Self-contained: it does its own transport (XMLHttpRequest), hit-testing, type
// introspection (via `String(item)`), geometry capture, and pending-pin state —
// no C++/Python logic is required to run it. The host only wires two context
// properties (see HOST-CONTRACT.md):
//
//   annotateServerUrl : string        callback base URL ("" ⇒ Send disabled)
//   annotateHost      : QtObject|null  OPTIONAL — sourceFile(item), typeName(item)
//
// Then parent this component into the window's contentItem. Nothing here mutates
// the app; it is dev-only and framework-agnostic (works with a C++ or a Python
// host, or standalone with neither context property set).
import QtQuick
import QtQuick.Controls

Item {
    id: root
    objectName: "annotateOverlayRoot"
    anchors.fill: parent
    z: 2000000

    property bool annotating: false
    // Minimise the panel to just the bottom-left pill so you can annotate
    // elements in that corner; independent of annotate on/off. Leaving annotate
    // mode clears it so re-entering shows the panel again.
    property bool minimized: false
    onAnnotatingChanged: if (!annotating) minimized = false

    // ---- host contract (injected context properties, guarded) --------------
    // `typeof` guards keep the overlay working even if a host forgets to set one
    // (or runs it standalone) — no ReferenceError, just graceful degradation.
    // `serverUrlOverride` — set from the panel when the startup URL was
    // wrong/unset — takes precedence over the injected context property, so a bad
    // URL is fixable at runtime WITHOUT relaunching (which would drop the queue).
    property string serverUrlOverride: ""
    readonly property string serverUrl:
        serverUrlOverride.length > 0
            ? serverUrlOverride
            : ((typeof annotateServerUrl !== "undefined" && annotateServerUrl) ? annotateServerUrl : "")
    readonly property var host: (typeof annotateHost !== "undefined") ? annotateHost : null
    function hasServer() { return root.serverUrl.length > 0; }
    // Connection health: did the callback server actually answer a probe (not
    // merely "a URL is configured")? Gates entering annotate mode + the pill state.
    property bool connected: false
    property bool checking: false

    // ---- pending-pin state (owned here, not by a bridge) -------------------
    property var _pending: []      // list[payload dict]
    property int pendingCount: 0
    property var _current: null    // snapshot taken at pick time
    property int _lastMessageId: 0
    property string statusText: ""
    property bool statusError: false
    function _setStatus(t, isError) { statusText = t; statusError = isError; }

    // ---- changelog verification state (in-memory; pending items persist) ----
    // Agent-delivered entries, each augmented with per-row UI state:
    //   { id, title, description, context, state:"unset"|"verified"|"rejected",
    //     comment, repin }  (repin is a re-pinned identity that overrides context)
    // The checklist display is best-effort in-memory (mirrors how QML treats other
    // transient UI); only the pending kind:"verification" items are persisted.
    property var _changelog: []
    property string _repinFor: ""  // changelogId the next pick re-links (not a pin)

    // ---- introspection (pure QML) ------------------------------------------
    // Reduce a `String(item)` like "QQuickButton(0x…)", "Button_QMLTYPE_1(0x…)",
    // or "Foo_QML_2(0x…)" to a readable type name — the QML-side twin of the
    // web overlay's React-source degradation and the Python `clean_qml_type`.
    function cleanType(raw) {
        if (!raw)
            return "";
        var s = String(raw);
        var lp = s.indexOf("(");            // drop the "(0x…)" address suffix
        if (lp !== -1)
            s = s.substring(0, lp);
        var markers = ["_QMLTYPE_", "_QML_", "_qmltype"];
        for (var i = 0; i < markers.length; ++i) {
            var j = s.indexOf(markers[i]);
            if (j !== -1) { s = s.substring(0, j); break; }
        }
        var prefixes = ["QQuick", "QQml"];
        for (var k = 0; k < prefixes.length; ++k) {
            var p = prefixes[k];
            if (s.indexOf(p) === 0 && s.length > p.length)
                return s.substring(p.length);
        }
        return s;
    }
    // A host may supply more accurate names/paths than pure QML can derive.
    function typeName(item) {
        if (root.host && root.host.typeName) {
            var t = root.host.typeName(item);
            if (t) return t;
        }
        return root.cleanType(String(item));
    }
    function sourceFile(item) {
        if (root.host && root.host.sourceFile) {
            var f = root.host.sourceFile(item);
            if (f) return f;
        }
        return "";
    }
    function typeChain(item) {
        var chain = [];
        var node = item.parent;
        while (node && chain.length < 6) {
            if (node.objectName === "annotateOverlayRoot")
                break;                       // describe the app, not us
            var t = root.typeName(node);
            if (t) chain.unshift(t);
            node = node.parent;
        }
        return chain;
    }
    // Snapshot a picked item's identity + geometry NOW (before the comment box
    // opens), so a popup closing while the user types can never invalidate it.
    function itemInfo(item) {
        var tl = item.mapToItem(null, 0, 0);   // scene (window) coordinates
        var props = {
            "x": Math.round(tl.x), "y": Math.round(tl.y),
            "w": Math.round(item.width), "h": Math.round(item.height)
        };
        if (typeof item.text === "string") props.text = item.text;
        if (typeof item.enabled === "boolean") props.enabled = item.enabled;
        if (typeof item.visible === "boolean") props.visible = item.visible;
        return {
            "surface": "qml",
            "objectName": item.objectName || "",
            "qmlType": root.typeName(item),
            "typeChain": root.typeChain(item),
            "qmlFile": root.sourceFile(item),
            "props": props,
            "route": ""
        };
    }

    // ---- payload assembly + pin lifecycle ----------------------------------
    function _buildPayload(info, comment) {
        var props = info.props || {};
        var p = {
            "surface": info.surface || "qml",
            "comment": String(comment || "").trim(),
            "objectName": info.objectName || "",
            "qmlType": info.qmlType || "",
            "typeChain": info.typeChain || [],
            "qmlFile": info.qmlFile || "",
            "props": props,
            "route": info.route || ""
        };
        if (["x", "y", "w", "h"].every(function (k) { return k in props; }))
            p.rect = { "x": props.x, "y": props.y, "w": props.w, "h": props.h };
        return p;
    }
    function _buildNotePayload(text) {
        return { "surface": "qml", "kind": "note", "comment": String(text || "").trim() };
    }
    function _enqueue(payload) {
        var next = root._pending.slice();
        next.push(payload);
        root._pending = next;
        root.pendingCount = next.length;
        root._persist();
    }
    function beginPin(item) {
        root._current = item ? root.itemInfo(item) : null;
        return root._current
            ? { "objectName": root._current.objectName, "qmlType": root._current.qmlType,
                "qmlFile": root._current.qmlFile }
            : ({});
    }
    function commitPin(comment) {
        if (root._current && String(comment || "").trim().length > 0)
            root._enqueue(root._buildPayload(root._current, comment));
        root._current = null;
    }
    function commitNote(text) {
        if (String(text || "").trim().length > 0)
            root._enqueue(root._buildNotePayload(text));
    }
    function cancelPin() { root._current = null; }

    // ---- changelog verification --------------------------------------------
    // Merge an agent-delivered changelog, de-duplicating by id so a re-delivery
    // never clobbers in-progress row state. Reassigns _changelog (rebuilds the
    // Repeater) — only called on delivery, never per keystroke.
    function _ingestChangelog(list) {
        if (!list || !list.length)
            return;
        var next = root._changelog.slice();
        for (var i = 0; i < list.length; ++i) {
            var e = list[i];
            if (!e || typeof e.id !== "string" || e.id.length === 0)
                continue;
            var dup = false;
            for (var j = 0; j < next.length; ++j)
                if (next[j].id === e.id) { dup = true; break; }
            if (dup)
                continue;
            next.push({
                "id": e.id,
                "title": (typeof e.title === "string") ? e.title : e.id,
                "description": (typeof e.description === "string") ? e.description : "",
                "context": (e.context && typeof e.context === "object") ? e.context : null,
                "state": "unset",
                "comment": "",
                "repin": null
            });
        }
        root._changelog = next;
    }
    // The effective identity for a row: a re-pinned element wins over the entry's
    // agent-provided context; either may be absent.
    function _rowContext(entry) {
        return entry.repin || entry.context || null;
    }
    // Sync the shared pending queue to a row's state: drop any verification item
    // for this changelogId, then re-add it when the row is a non-empty rejection.
    // Matched by changelogId so a row and its queued issue can never drift.
    function _updateVerification(entry) {
        var id = entry.id;
        var next = [];
        for (var i = 0; i < root._pending.length; ++i) {
            var p = root._pending[i];
            if (!(p && p.kind === "verification" && p.changelogId === id))
                next.push(p);
        }
        var comment = String(entry.comment || "").trim();
        if (entry.state === "rejected" && comment.length > 0) {
            var ctx = root._rowContext(entry) || {};
            next.push({
                "surface": "qml",
                "kind": "verification",
                "changelogId": id,
                "comment": comment,
                "objectName": ctx.objectName || "",
                "qmlType": ctx.qmlType || "",
                "qmlFile": ctx.qmlFile || "",
                "typeChain": ctx.typeChain || []
            });
        }
        root._pending = next;
        root.pendingCount = next.length;
        root._persist();
    }
    // Toggle a row Verified/Rejected. Verified clears the issue + drops its item.
    // Mutates the entry object in place (no array reassignment ⇒ no Repeater
    // rebuild ⇒ the open issue TextArea keeps focus); the delegate mirrors the
    // state via its own `rowState` property.
    function _setRowState(entry, s) {
        entry.state = s;
        if (s === "verified") {
            entry.comment = "";
            if (root._repinFor === entry.id)
                root._repinFor = "";
        }
        root._updateVerification(entry);
    }
    // Arm re-pin for a row: the next pick attaches identity to this rejection.
    function _startRepin(entry) {
        if (entry.state !== "rejected")
            entry.state = "rejected";
        root._repinFor = entry.id;
        root.annotating = true;
        root._setStatus("Click an element to link it to this issue", false);
    }
    // Finish a re-pin: attach captured identity to the row and refresh its item.
    function _attachRepin(id, info) {
        for (var i = 0; i < root._changelog.length; ++i) {
            if (root._changelog[i].id === id) {
                root._changelog[i].repin = {
                    "objectName": info.objectName || "",
                    "qmlType": info.qmlType || "",
                    "qmlFile": info.qmlFile || "",
                    "typeChain": info.typeChain || []
                };
                root._updateVerification(root._changelog[i]);
                break;
            }
        }
        root._repinFor = "";
        root.annotating = false;
        root._setStatus("Element linked to the issue ✓", false);
    }
    // Locate a row's item by objectName and flash the hover highlight over it —
    // the QML twin of the web overlay's reveal-by-selector.
    function _locate(entry) {
        var ctx = root._rowContext(entry);
        if (!ctx || !ctx.objectName) {
            root._setStatus("No locatable identity for this item", true);
            return;
        }
        var scene = root.parent;
        var item = scene ? root._findByObjectName(scene, ctx.objectName) : null;
        if (item) {
            root.showHighlight(item);
            locateHideTimer.restart();
        } else {
            root._setStatus("Couldn't find #" + ctx.objectName + " on screen", true);
        }
    }
    function _findByObjectName(node, name) {
        if (!node || node === root)
            return null;
        if (node.objectName === name)
            return node;
        var kids = node.children || [];
        for (var i = 0; i < kids.length; ++i) {
            var f = root._findByObjectName(kids[i], name);
            if (f)
                return f;
        }
        return null;
    }

    // ---- pending-pin persistence (optional host hooks) ---------------------
    // Mirror the queue to disk (when the host provides load/save hooks) so a
    // quit, crash, or relaunch-to-fix-the-URL never loses annotations. With no
    // host it still works — just not durable across restarts.
    function _persist() {
        if (root.host && root.host.savePending)
            root.host.savePending(JSON.stringify(root._pending));
    }
    function _restorePending() {
        if (!(root.host && root.host.loadPending))
            return;
        try {
            var raw = root.host.loadPending();
            var arr = raw ? JSON.parse(raw) : [];
            if (arr && arr.length) {
                root._pending = arr;
                root.pendingCount = arr.length;
            }
        } catch (e) { /* corrupt/absent → start empty */ }
    }

    // ---- transport (XMLHttpRequest — no host code needed) ------------------
    function _base() { return root.serverUrl.replace(/\/+$/, ""); }
    // Probe the callback server so we only let the user annotate against a
    // server that's actually there. `cb(ok)` fires once with the result.
    function checkConnection(cb) {
        if (!root.hasServer()) { root.connected = false; if (cb) cb(false); return; }
        root.checking = true;
        var xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return;
            root.checking = false;
            var ok = xhr.status >= 200 && xhr.status < 300;
            root.connected = ok;
            if (cb) cb(ok);
        };
        try {
            xhr.open("GET", root._base() + "/__annotate/messages?since=" + root._lastMessageId);
            xhr.send();
        } catch (e) { root.checking = false; root.connected = false; if (cb) cb(false); }
    }
    // Enter annotate mode only once the connection is confirmed — never let the
    // user pin against a dead server and lose the work. A failed probe keeps
    // annotate off and surfaces the recovery UI (set the URL / retry) below.
    function requestAnnotate() {
        if (root.annotating) { root.annotating = false; return; }
        if (root.connected) { root.annotating = true; return; }
        root._setStatus("Connecting to " + (root.serverUrl || "—") + " …", false);
        root.checkConnection(function (ok) {
            if (ok) { root._setStatus("", false); root.annotating = true; }
            else root._setStatus("Can't reach the annotate-ui server. Start it with "
                + "`annotate-ui serve --server-only`, or set the URL below — "
                + (root.pendingCount > 0
                   ? (root.pendingCount + " queued pin(s) are kept.") : "pins will be kept."), true);
        });
    }
    function send() {
        if (!root._pending.length)
            return;
        if (!root.hasServer()) {
            root._setStatus("No annotate-ui server — run `annotate-ui serve --server-only`", true);
            return;
        }
        var batch = root._pending.slice();
        var xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return;
            if (xhr.status >= 200 && xhr.status < 300) {
                root._pending = [];
                root.pendingCount = 0;
                root._persist();          // clears the on-disk queue too
                root._changelog = [];     // the verification round went with it
                root._repinFor = "";
                root.connected = true;
                root._setStatus("Sent to agent ✓", false);
            } else {
                root._setStatus("Send failed (server down?) — pins kept, retry", true);
            }
        };
        try {
            xhr.open("POST", root._base() + "/__annotate/submit");
            xhr.setRequestHeader("Content-Type", "application/json");
            xhr.send(JSON.stringify({ "annotations": batch }));
        } catch (e) {
            root._setStatus("Send failed (server down?)", true);
        }
    }
    function pollMessages() {
        if (!root.hasServer()) { root.connected = false; return; }
        var xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return;
            var ok = xhr.status >= 200 && xhr.status < 300;
            root.connected = ok;   // heartbeat: keeps the pill state honest
            if (!ok)
                return;
            try {
                var body = JSON.parse(xhr.responseText || "{}");
                var msgs = body.messages || [];
                for (var i = 0; i < msgs.length; ++i) {
                    var m = msgs[i];
                    var mid = parseInt(m.id || 0);
                    if (mid > root._lastMessageId)
                        root._lastMessageId = mid;
                    // Typed changelog → verification checklist; plain reply → a
                    // message line; an unknown type is ignored without error.
                    if (m.type === "changelog" && m.changelog)
                        root._ingestChangelog(m.changelog);
                    else if (typeof m.message === "string")
                        root._appendMessage(m.message);
                }
            } catch (e) { /* ignore malformed replies */ }
        };
        try {
            xhr.open("GET", root._base() + "/__annotate/messages?since=" + root._lastMessageId);
            xhr.send();
        } catch (e) { root.connected = false; /* server down — retry next tick */ }
    }
    function _appendMessage(text) {
        var item = Qt.createQmlObject(
            'import QtQuick; Text { width: parent.width'
            + '; wrapMode: Text.WordWrap; color: "#cfe3ff"; font.pixelSize: 12 }', msgs);
        item.text = "🤖 " + text;
    }
    Timer {
        interval: 3000
        repeat: true
        running: root.hasServer()
        onTriggered: root.pollMessages()
    }
    // Auto-hide the hover highlight after a `_locate()` flash.
    Timer {
        id: locateHideTimer
        interval: 2000
        onTriggered: hl.visible = false
    }
    // Restore pins persisted by a previous session and probe the server, so the
    // pill reflects real reachability from the moment the overlay appears.
    Component.onCompleted: {
        root._restorePending();
        root.checkConnection();
    }

    // ---- hit-testing (JS) --------------------------------------------------
    // `Item.childAt` returns the top-most child by *stacking order* that merely
    // contains the point — it ignores whether that child paints anything there.
    // A full-window, higher-`z` pass-through layer (a bare `anchors.fill` Item
    // whose visible content sits elsewhere) thus shadows the whole window and
    // swallows every pin. We instead walk children front-to-back and, when the
    // top-most one bottoms out to itself, accept it only if it is *solid* here
    // (a leaf, or it paints its own background); otherwise it is a transparent
    // container whose content is elsewhere, so we fall through to the sibling
    // beneath — mirroring the web overlay's `elementFromPoint` +
    // `pointer-events:none` semantics.

    // Does `it` paint a background at this point? A bare Item paints nothing, so
    // its `color` is undefined; a Rectangle / Control background exposes a
    // `color` whose alpha is > 0 when opaque. (Text/Image leaves have no visible
    // children, so they are taken via the leaf branch before this is consulted.)
    function _paints(it) {
        var c = it.color;
        return c !== undefined && c !== null && c.a > 0;
    }
    function _hasVisibleChild(it) {
        var ch = it.children;
        for (var i = 0; i < ch.length; ++i)
            if (ch[i] !== root && ch[i].visible)
                return true;
        return false;
    }
    // Deepest item genuinely painted at `(x, y)` in `item`'s coordinates, or
    // null if `item` is transparent there. Skips our own overlay (`root`).
    function pickAt(item, x, y) {
        var kids = item.children;
        var cands = [];
        for (var i = 0; i < kids.length; ++i) {
            var c = kids[i];
            if (c === root || !c.visible || c.opacity <= 0)
                continue;
            var p = item.mapToItem(c, x, y);
            if (p.x >= 0 && p.y >= 0 && p.x < c.width && p.y < c.height)
                cands.push({ it: c, x: p.x, y: p.y, z: c.z, i: i });
        }
        // Front-to-back: Qt draws higher `z` (then later declaration order) on top.
        cands.sort(function (a, b) { return (b.z - a.z) || (b.i - a.i); });
        for (var k = 0; k < cands.length; ++k) {
            var cand = cands[k];
            var deep = pickAt(cand.it, cand.x, cand.y);
            if (deep && deep !== cand.it)
                return deep;              // a descendant is really under the point
            // `cand` bottomed out to itself: take it only if it is solid here.
            if (!_hasVisibleChild(cand.it) || _paints(cand.it))
                return cand.it;
            // else transparent container (content elsewhere) → try beneath it.
        }
        return null;                      // nothing painted here above `item`
    }
    // The app item under an overlay-local point (hide self so we never pick it).
    function itemUnder(px, py) {
        var scene = root.parent;
        if (!scene)
            return null;
        root.visible = false;
        var sp = root.mapToItem(scene, px, py);
        var found = pickAt(scene, sp.x, sp.y);
        root.visible = true;
        return found;
    }
    function showHighlight(it) {
        if (!it) {
            hl.visible = false;
            return;
        }
        var tl = it.mapToItem(root, 0, 0);
        hl.x = tl.x;
        hl.y = tl.y;
        hl.width = it.width;
        hl.height = it.height;
        hl.visible = true;
    }

    // ---- hover highlight ---------------------------------------------------
    Rectangle {
        id: hl
        visible: false
        z: 1
        radius: 3
        color: "#206ea8fe"
        border.color: "#6ea8fe"
        border.width: 2
    }

    // ---- capture layer (only while annotating) -----------------------------
    MouseArea {
        id: capture
        anchors.fill: parent
        z: 2
        enabled: root.annotating
        visible: root.annotating
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        cursorShape: Qt.CrossCursor

        onPositionChanged: mouse => {
            // Alt held → the click will drive the app; suppress the highlight.
            if (mouse.modifiers & Qt.AltModifier) {
                hl.visible = false;
                return;
            }
            showHighlight(root.itemUnder(mouse.x, mouse.y));
        }
        onExited: hl.visible = false
        onPressed: mouse => {
            // Alt/⌥-press passes straight through to the app (open popups/menus).
            mouse.accepted = !(mouse.modifiers & Qt.AltModifier);
        }
        onClicked: mouse => {
            if (mouse.modifiers & Qt.AltModifier)
                return;
            var it = root.itemUnder(mouse.x, mouse.y);
            if (!it)
                return;
            // Re-pin mode: the pick re-links the active rejection's identity
            // instead of opening a fresh pin (identical capture path).
            if (root._repinFor.length > 0) {
                root._attachRepin(root._repinFor, root.itemInfo(it));
                return;
            }
            comment.openFor(it, mouse.x, mouse.y);
        }
    }

    // ---- comment box -------------------------------------------------------
    Rectangle {
        id: comment
        visible: false
        z: 5
        width: 300
        implicitHeight: col.implicitHeight + 20
        height: implicitHeight
        radius: 8
        color: "#14161b"
        border.color: "#3a3f47"

        property var header: ({})

        function openFor(item, px, py) {
            header = root.beginPin(item);  // snapshot NOW
            field.text = "";
            x = Math.min(px, root.width - width - 8);
            y = Math.min(py, root.height - height - 8);
            visible = true;
            field.forceActiveFocus();
        }
        function close() {
            visible = false;
        }

        Column {
            id: col
            anchors.fill: parent
            anchors.margins: 10
            spacing: 8
            Text {
                width: parent.width
                elide: Text.ElideMiddle
                color: "#8b9199"
                font.pixelSize: 11
                text: (comment.header.objectName ? ("#" + comment.header.objectName + "  ") : "")
                    + (comment.header.qmlType || "") + "  " + (comment.header.qmlFile || "")
            }
            TextField {
                id: field
                width: parent.width
                placeholderText: "What needs fixing here? (Ctrl+Enter to add)"
                color: "#e8eaed"
                background: Rectangle { color: "#0e1013"; border.color: "#3a3f47"; radius: 6 }
                Keys.onPressed: ev => {
                    if ((ev.key === Qt.Key_Return || ev.key === Qt.Key_Enter)
                            && (ev.modifiers & Qt.ControlModifier)) {
                        addBtn.doAdd();
                        ev.accepted = true;
                    } else if (ev.key === Qt.Key_Escape) {
                        root.cancelPin();
                        comment.close();
                        ev.accepted = true;
                    }
                }
            }
            Row {
                spacing: 8
                anchors.right: parent.right
                Button {
                    text: "Cancel"
                    onClicked: {
                        root.cancelPin();
                        comment.close();
                    }
                }
                Button {
                    id: addBtn
                    text: "Add"
                    function doAdd() {
                        if (field.text.trim().length > 0) {
                            root.commitPin(field.text);
                            comment.close();
                        }
                    }
                    onClicked: doAdd()
                }
            }
        }
    }

    // ---- toggle pill + pending panel --------------------------------------
    Rectangle {
        id: pill
        z: 6
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: 16
        radius: 20
        height: 34
        width: pillRow.implicitWidth + 24
        // Warm tint when disconnected & idle, so "server offline" reads at a glance.
        color: root.annotating ? "#2b5fd0" : (root.connected ? "#1b1e24" : "#3a2326")
        border.color: root.annotating ? "#2b5fd0" : (root.connected ? "#3a3f47" : "#7a3b3b")

        // Toggle annotate mode (gated on a confirmed connection). Declared before
        // pillRow so the restore glyph's own MouseArea (a child of pillRow)
        // paints/handles on top of this and can swallow its click.
        MouseArea {
            anchors.fill: parent
            onClicked: root.requestAnnotate()
        }
        Row {
            id: pillRow
            anchors.centerIn: parent
            spacing: 8
            Text {
                anchors.verticalCenter: parent.verticalCenter
                color: root.annotating ? "#ffffff" : "#e8eaed"
                font.pixelSize: 13
                text: root.annotating
                    ? ("● Annotating — Esc"
                       + (root.pendingCount > 0 ? ("  ·  " + root.pendingCount) : ""))
                    : (root.checking ? "… Connecting"
                       : (root.connected ? "✎ Annotate (QML)"
                          : (root.pendingCount > 0
                             ? ("⚠ Offline — " + root.pendingCount + " unsent")
                             : "⚠ Annotate — server offline")))
            }
            // Restore the minimised panel (while annotating or a checklist is up).
            Text {
                id: restoreGlyph
                visible: root.minimized && (root.annotating || root._changelog.length > 0)
                anchors.verticalCenter: parent.verticalCenter
                color: "#ffffff"
                font.pixelSize: 15
                text: "⤢"
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -4   // easier to hit
                    onClicked: root.minimized = false
                }
            }
        }
    }

    Rectangle {
        id: panel
        objectName: "annotatePanel"
        z: 6
        // Shown while annotating OR disconnected (so the recovery UI is reachable)
        // OR whenever a verification checklist is present (so the user can sign off
        // on it without first entering annotate mode).
        visible: (root.annotating || !root.connected || root._changelog.length > 0) && !root.minimized
        anchors.left: parent.left
        anchors.bottom: pill.top
        anchors.leftMargin: 16
        anchors.bottomMargin: 8
        width: 300
        radius: 10
        color: "#14161b"
        border.color: "#3a3f47"
        // Never taller than the window: the room above the pill, less a top
        // margin. The header stays put; the body scrolls inside what is left.
        readonly property real maxHeight: Math.max(120, pill.y - anchors.bottomMargin - 16)
        implicitHeight: 10 + header.height + 8 + pcol.implicitHeight + 10
        height: Math.min(implicitHeight, maxHeight)

        // Header: title/count, annotate toggle and a "–" minimise button
        // (collapses to the pill). Outside the scrolling body so it is always
        // reachable however long the checklist or the discussion gets.
        Item {
            id: header
            objectName: "annotatePanelHeader"
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: 10
            height: minBtn.implicitHeight
            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                color: "#9aa0a6"
                font.pixelSize: 12
                font.bold: true
                text: "Annotations (" + root.pendingCount + ")"
            }
            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                Button {
                    objectName: "annotateHeaderToggle"
                    anchors.verticalCenter: parent.verticalCenter
                    flat: true
                    padding: 4
                    font.pixelSize: 12
                    text: root.annotating ? "Stop annotating" : "✎ Annotate"
                    onClicked: root.requestAnnotate()
                }
                Button {
                    id: minBtn
                    objectName: "annotateMinimise"
                    anchors.verticalCenter: parent.verticalCenter
                    flat: true
                    padding: 2
                    text: "–"
                    font.pixelSize: 18
                    ToolTip.visible: hovered
                    ToolTip.text: "Minimise"
                    onClicked: root.minimized = true
                }
            }
        }

        // Scrolling body: everything below the header. Wheel and drag scroll it;
        // the bar is shown whenever the content overflows.
        Flickable {
            id: body
            objectName: "annotatePanelBody"
            anchors.top: header.bottom
            anchors.topMargin: 8
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            anchors.bottomMargin: 10
            clip: true
            contentWidth: width
            contentHeight: pcol.implicitHeight
            flickableDirection: Flickable.VerticalFlick
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {
                objectName: "annotatePanelScrollBar"
                policy: body.contentHeight > body.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
            }

            Column {
                id: pcol
                width: body.width - 10   // room for the scroll bar
                spacing: 8
                Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    color: "#6b7178"
                    font.pixelSize: 11
                    text: root.hasServer()
                        ? "Alt/⌥-click to use the app (open menus/popups), then click to annotate."
                        : "No annotate-ui server — run `annotate-ui serve --server-only`, then reopen."
                }
                // Connection status + recover a wrong/unset server URL WITHOUT
                // relaunching — so queued pins are never lost to a bad URL.
                Column {
                    width: parent.width
                    spacing: 6
                    visible: !root.connected
                    Text {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        color: "#ffcf8f"
                        font.pixelSize: 11
                        text: root.checking
                            ? "Connecting…"
                            : ("Not connected."
                               + (root.pendingCount > 0
                                  ? (" " + root.pendingCount + " pin(s) kept safe — fix the URL, then Send.")
                                  : " Set the callback URL, then annotate."))
                    }
                    TextField {
                        id: urlField
                        width: parent.width
                        text: root.serverUrl
                        placeholderText: "http://127.0.0.1:6100"
                        color: "#e8eaed"
                        background: Rectangle { color: "#0e1013"; border.color: "#3a3f47"; radius: 6 }
                        onAccepted: connectBtn.doConnect()
                    }
                    Button {
                        id: connectBtn
                        anchors.right: parent.right
                        text: root.checking ? "Checking…" : "Connect"
                        enabled: !root.checking
                        function doConnect() {
                            root.serverUrlOverride = urlField.text.trim();
                            root.checkConnection(function (ok) {
                                root._setStatus(ok ? "Connected ✓" : "Still can't reach that URL.", !ok);
                            });
                        }
                        onClicked: doConnect()
                    }
                }
                // Verification checklist — one row per agent-delivered changelog entry,
                // mirroring the web overlay. Renders all user/agent strings via `Text`
                // only (never as markup).
                Column {
                    id: checklist
                    width: parent.width
                    spacing: 6
                    visible: root._changelog.length > 0
                    Text {
                        width: parent.width
                        color: "#9aa0a6"
                        font.pixelSize: 11
                        font.bold: true
                        text: "Changelog — verify each change"
                    }
                    Repeater {
                        model: root._changelog
                        delegate: Column {
                            id: clRow
                            width: checklist.width
                            spacing: 4
                            required property var modelData
                            // Local mirror of the entry's state: mutating the plain JS
                            // entry can't notify bindings, so the click handlers set
                            // this explicitly to drive the row's reactive UI.
                            property string rowState: modelData.state
                            Rectangle { width: parent.width; height: 1; color: "#1c1f25" }
                            Text {
                                width: parent.width
                                wrapMode: Text.WordWrap
                                color: "#e8eaed"
                                font.pixelSize: 13
                                text: clRow.modelData.title
                            }
                            Text {
                                width: parent.width
                                visible: clRow.modelData.description.length > 0
                                wrapMode: Text.WordWrap
                                color: "#8b9199"
                                font.pixelSize: 11
                                text: clRow.modelData.description
                            }
                            Row {
                                spacing: 6
                                Button {
                                    text: "✓ Verified"
                                    highlighted: clRow.rowState === "verified"
                                    onClicked: {
                                        root._setRowState(clRow.modelData, "verified");
                                        clRow.rowState = "verified";
                                    }
                                }
                                Button {
                                    text: "✕ Rejected"
                                    highlighted: clRow.rowState === "rejected"
                                    onClicked: {
                                        root._setRowState(clRow.modelData, "rejected");
                                        clRow.rowState = "rejected";
                                    }
                                }
                                Button {
                                    property var ctx: root._rowContext(clRow.modelData)
                                    visible: ctx && ctx.objectName ? true : false
                                    text: "⌖"
                                    ToolTip.visible: hovered
                                    ToolTip.text: "Locate in the app"
                                    onClicked: root._locate(clRow.modelData)
                                }
                            }
                            TextArea {
                                id: issueField
                                width: parent.width
                                visible: clRow.rowState === "rejected"
                                wrapMode: TextArea.Wrap
                                placeholderText: "What's wrong? (sent to the agent as an issue)"
                                color: "#e8eaed"
                                background: Rectangle { color: "#0e1013"; border.color: "#3a3f47"; radius: 6 }
                                text: clRow.modelData.comment
                                onTextChanged: {
                                    clRow.modelData.comment = text;
                                    root._updateVerification(clRow.modelData);
                                }
                            }
                            Button {
                                visible: clRow.rowState === "rejected"
                                text: root._repinFor === clRow.modelData.id
                                    ? "◎ Click an element…" : "⌖ Re-pin element"
                                onClicked: root._startRepin(clRow.modelData)
                            }
                        }
                    }
                }
                // Freeform note (not tied to an element) — mirrors the web composer.
                TextArea {
                    id: noteField
                    width: parent.width
                    wrapMode: TextArea.Wrap
                    placeholderText: "Add a note… (Ctrl+Enter or click Add)"
                    color: "#e8eaed"
                    background: Rectangle { color: "#0e1013"; border.color: "#3a3f47"; radius: 6 }
                    // Queue the freeform note and clear the field. Shared by the
                    // Ctrl+Enter shortcut and the explicit Add button.
                    function doAdd() {
                        if (noteField.text.trim().length > 0) {
                            root.commitNote(noteField.text);
                            noteField.text = "";
                        }
                    }
                    Keys.onPressed: ev => {
                        if ((ev.key === Qt.Key_Return || ev.key === Qt.Key_Enter)
                                && (ev.modifiers & Qt.ControlModifier)) {
                            noteField.doAdd();
                            ev.accepted = true;
                        }
                    }
                }
                // Explicit Add button for the freeform note (twin of the Ctrl+Enter
                // shortcut), so a note can be queued with the mouse alone.
                Row {
                    spacing: 8
                    anchors.right: parent.right
                    Button {
                        text: "Add note"
                        enabled: noteField.text.trim().length > 0
                        onClicked: noteField.doAdd()
                    }
                }
                Row {
                    spacing: 8
                    Button {
                        text: "Send " + root.pendingCount + " to agent"
                        enabled: root.pendingCount > 0
                        onClicked: root.send()
                    }
                }
                Text {
                    id: status
                    visible: root.statusText.length > 0
                    width: parent.width
                    wrapMode: Text.WordWrap
                    font.pixelSize: 12
                    color: root.statusError ? "#ff9d9d" : "#9dffb0"
                    text: root.statusText
                }
                // Agent replies (the discussion). The whole body scrolls, so this
                // needs no scroller of its own.
                Column {
                    id: msgs
                    objectName: "annotateMessages"
                    width: parent.width
                    visible: children.length > 0
                    spacing: 4
                }
            }
        }
    }

    // ---- shortcuts ---------------------------------------------------------
    Shortcut {
        sequences: ["Ctrl+Shift+A"]
        context: Qt.ApplicationShortcut
        onActivated: root.requestAnnotate()
    }
    Shortcut {
        sequence: "Escape"
        enabled: root.annotating
        context: Qt.ApplicationShortcut
        onActivated: root.annotating = false
    }
}
