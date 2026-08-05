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
    // Minimise the panel to just the bottom-right pill so you can annotate
    // elements in that corner; independent of annotate on/off. Leaving annotate
    // mode clears it so re-entering shows the panel again.
    property bool minimized: false
    onAnnotatingChanged: if (!annotating) minimized = false

    // ---- host contract (injected context properties, guarded) --------------
    // `typeof` guards keep the overlay working even if a host forgets to set one
    // (or runs it standalone) — no ReferenceError, just graceful degradation.
    readonly property string serverUrl:
        (typeof annotateServerUrl !== "undefined" && annotateServerUrl) ? annotateServerUrl : ""
    readonly property var host: (typeof annotateHost !== "undefined") ? annotateHost : null
    function hasServer() { return root.serverUrl.length > 0; }

    // ---- pending-pin state (owned here, not by a bridge) -------------------
    property var _pending: []      // list[payload dict]
    property int pendingCount: 0
    property var _current: null    // snapshot taken at pick time
    property int _lastMessageId: 0
    property string statusText: ""
    property bool statusError: false
    function _setStatus(t, isError) { statusText = t; statusError = isError; }

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

    // ---- transport (XMLHttpRequest — no host code needed) ------------------
    function _base() { return root.serverUrl.replace(/\/+$/, ""); }
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
                root._setStatus("Sent to agent ✓", false);
            } else {
                root._setStatus("Send failed (server down?)", true);
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
        if (!root.hasServer())
            return;
        var xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return;
            if (xhr.status < 200 || xhr.status >= 300)
                return;
            try {
                var body = JSON.parse(xhr.responseText || "{}");
                var msgs = body.messages || [];
                for (var i = 0; i < msgs.length; ++i) {
                    var mid = parseInt(msgs[i].id || 0);
                    if (mid > root._lastMessageId)
                        root._lastMessageId = mid;
                    root._appendMessage(String(msgs[i].message || ""));
                }
            } catch (e) { /* ignore malformed replies */ }
        };
        try {
            xhr.open("GET", root._base() + "/__annotate/messages?since=" + root._lastMessageId);
            xhr.send();
        } catch (e) { /* server down — try again next tick */ }
    }
    function _appendMessage(text) {
        var item = Qt.createQmlObject(
            'import QtQuick; Text { width: ' + msgs.width
            + '; wrapMode: Text.WordWrap; color: "#cfe3ff"; font.pixelSize: 12 }', msgs);
        item.text = "🤖 " + text;
    }
    Timer {
        interval: 3000
        repeat: true
        running: root.hasServer()
        onTriggered: root.pollMessages()
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
            if (it)
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
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 16
        radius: 20
        height: 34
        width: pillRow.implicitWidth + 24
        color: root.annotating ? "#2b5fd0" : "#1b1e24"
        border.color: root.annotating ? "#2b5fd0" : "#3a3f47"

        // Toggle annotate mode. Declared before pillRow so the restore glyph's
        // own MouseArea (a child of pillRow) paints/handles on top of this and
        // can swallow its click.
        MouseArea {
            anchors.fill: parent
            onClicked: root.annotating = !root.annotating
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
                    : "✎ Annotate (QML)"
            }
            // Restore the minimised panel (only while annotating & minimised).
            Text {
                id: restoreGlyph
                visible: root.annotating && root.minimized
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
        z: 6
        visible: root.annotating && !root.minimized
        anchors.right: parent.right
        anchors.bottom: pill.top
        anchors.rightMargin: 16
        anchors.bottomMargin: 8
        width: 300
        radius: 10
        color: "#14161b"
        border.color: "#3a3f47"
        implicitHeight: pcol.implicitHeight + 20
        height: implicitHeight

        Column {
            id: pcol
            anchors.fill: parent
            anchors.margins: 10
            spacing: 8
            // Header: title/count + a "–" minimise button (collapses to the pill).
            Item {
                width: parent.width
                height: minBtn.implicitHeight
                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    color: "#9aa0a6"
                    font.pixelSize: 12
                    font.bold: true
                    text: "Annotations (" + root.pendingCount + ")"
                }
                Button {
                    id: minBtn
                    anchors.right: parent.right
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
            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                color: "#6b7178"
                font.pixelSize: 11
                text: root.hasServer()
                    ? "Alt/⌥-click to use the app (open menus/popups), then click to annotate."
                    : "No annotate-ui server — run `annotate-ui serve --server-only`, then reopen."
            }
            // Freeform note (not tied to an element) — mirrors the web composer.
            TextArea {
                id: noteField
                width: parent.width
                wrapMode: TextArea.Wrap
                placeholderText: "Add a note… (Ctrl+Enter)"
                color: "#e8eaed"
                background: Rectangle { color: "#0e1013"; border.color: "#3a3f47"; radius: 6 }
                Keys.onPressed: ev => {
                    if ((ev.key === Qt.Key_Return || ev.key === Qt.Key_Enter)
                            && (ev.modifiers & Qt.ControlModifier)) {
                        if (noteField.text.trim().length > 0) {
                            root.commitNote(noteField.text);
                            noteField.text = "";
                        }
                        ev.accepted = true;
                    }
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
            Column {
                id: msgs
                width: parent.width
                spacing: 4
            }
        }
    }

    // ---- shortcuts ---------------------------------------------------------
    Shortcut {
        sequences: ["Ctrl+Shift+A"]
        context: Qt.ApplicationShortcut
        onActivated: root.annotating = !root.annotating
    }
    Shortcut {
        sequence: "Escape"
        enabled: root.annotating
        context: Qt.ApplicationShortcut
        onActivated: root.annotating = false
    }
}
