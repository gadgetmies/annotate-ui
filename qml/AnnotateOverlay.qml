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
    // The root covers the whole window above the popup layer, but must not
    // count as "the item under the pointer" itself: while a modal popup is
    // open, Qt Quick Controls drops every wheel event whose top item lies
    // outside the popup, judged by geometry alone. A mask containing nothing
    // takes the root out of hit-testing; its children (pill, panel, the
    // capture layer while annotating) still get their input.
    containmentMask: QtObject {
        function contains(point: point): bool { return false }
    }

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
    // Writable only so a test can hand an overlay a stub host at creation.
    property var host: (typeof annotateHost !== "undefined") ? annotateHost : null
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
    //     comment, draft, editing, repin }
    // `comment` is the rejection as added to the batch (what is queued); `draft`
    // is the issue box's text while `editing`, not queued until submitted.
    // `repin` is a re-pinned identity that overrides context.
    // The checklist display is best-effort in-memory (mirrors how QML treats other
    // transient UI); only the pending kind:"verification" items are persisted.
    property var _changelog: []
    property string _repinFor: ""  // changelogId the next pick re-links (not a pin)
    // Bumped after every in-place change to a row's state, so the checklist
    // delegates re-read it. Rows are mutated in place (no _changelog
    // reassignment, so the Repeater never rebuilds and an open issue box keeps
    // focus); plain JS objects can't notify bindings, this counter does.
    property int _changelogRev: 0
    // Checklist verdicts, kept across overlay restarts through the optional
    // loadVerdicts/saveVerdicts host hooks (the callback server re-delivers its
    // last changelog to a fresh overlay). Keyed by changelog id:
    //   { hash, state: "verified"|"rejected", comment, sent, at }
    // `hash` covers the entry's title, description and context, so a
    // re-delivery of the same id with changed content ("fixed again, please
    // re-check") no longer matches and the row comes back unset.
    property var _verdicts: ({})
    readonly property int _maxVerdicts: 500

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
            var entry = {
                "id": e.id,
                "title": (typeof e.title === "string") ? e.title : e.id,
                "description": (typeof e.description === "string") ? e.description : "",
                "context": (e.context && typeof e.context === "object") ? e.context : null,
                "state": "unset",
                "comment": "",
                "draft": "",
                "editing": false,
                "sent": false,
                "repin": null
            };
            entry.hash = root._entryHash(entry);
            root._applyVerdict(entry);
            if (entry.sent)
                continue;   // its verdict already reached the agent: stay hidden
            next.push(entry);
        }
        root._changelog = next;
    }
    // Stable text for a value: object keys sorted, so the same content always
    // hashes the same whatever order the agent wrote its JSON keys in.
    function _canonical(v) {
        if (v === null || typeof v !== "object")
            return JSON.stringify(v === undefined ? null : v);
        if (Array.isArray(v))
            return "[" + v.map(root._canonical).join(",") + "]";
        var keys = Object.keys(v).sort();
        return "{" + keys.map(function (k) {
            return JSON.stringify(k) + ":" + root._canonical(v[k]);
        }).join(",") + "}";
    }
    // FNV-1a (32-bit) of an entry's title, description and context.
    function _entryHash(entry) {
        var str = root._canonical([entry.title, entry.description, entry.context]);
        var h = 0x811c9dc5;
        for (var i = 0; i < str.length; ++i) {
            h ^= str.charCodeAt(i);
            h = Math.imul(h, 0x01000193) >>> 0;
        }
        return ("0000000" + h.toString(16)).slice(-8);
    }
    // Restore a remembered verdict onto a freshly delivered entry, or forget a
    // verdict whose entry changed (and drop its unsent rejection, which was
    // about the old version).
    function _applyVerdict(entry) {
        var v = root._verdicts[entry.id];
        if (!v)
            return;
        if (v.hash === entry.hash) {
            entry.state = v.state;
            entry.comment = v.comment || "";
            entry.sent = v.sent === true;
            return;
        }
        var next = {};
        for (var k in root._verdicts)
            if (k !== entry.id)
                next[k] = root._verdicts[k];
        root._verdicts = next;
        root._saveVerdicts();
        root._updateVerification(entry);   // unset → drops a stale queued item
        root._setStatus("Some changes were updated by the agent — please check them again", false);
    }
    // Record (or clear) a row's verdict after any change to it. Only finished
    // verdicts are kept: verified, or rejected with an added comment.
    function _recordVerdict(entry) {
        var next = {};
        for (var k in root._verdicts)
            if (k !== entry.id)
                next[k] = root._verdicts[k];
        var comment = String(entry.comment || "").trim();
        if (entry.state === "verified" || (entry.state === "rejected" && comment.length > 0)) {
            next[entry.id] = {
                "hash": entry.hash || root._entryHash(entry),
                "state": entry.state,
                "comment": entry.state === "rejected" ? comment : "",
                "sent": entry.sent === true,
                "at": Date.now()
            };
        }
        // Keep the store bounded: drop the oldest beyond _maxVerdicts.
        var ids = Object.keys(next);
        if (ids.length > root._maxVerdicts) {
            ids.sort(function (a, b) { return (next[a].at || 0) - (next[b].at || 0); });
            for (var i = 0; i < ids.length - root._maxVerdicts; ++i)
                delete next[ids[i]];
        }
        root._verdicts = next;
        root._saveVerdicts();
    }
    function _saveVerdicts() {
        if (root.host && root.host.saveVerdicts)
            root.host.saveVerdicts(JSON.stringify(root._verdicts));
    }
    function _restoreVerdicts() {
        if (!(root.host && root.host.loadVerdicts))
            return;
        try {
            var raw = root.host.loadVerdicts();
            var obj = raw ? JSON.parse(raw) : {};
            if (obj && typeof obj === "object" && !Array.isArray(obj))
                root._verdicts = obj;
        } catch (e) { /* corrupt/absent → start empty */ }
    }
    // The live entry for a changelogId (or for an entry-like object, by its id).
    // Delegates must go through this: a Repeater over a JS array hands each
    // delegate a *copy* of its element as `modelData`, so writing to modelData
    // never reaches _changelog — the cause of the old "Verified does nothing".
    function _entryOf(entryOrId) {
        var id = (typeof entryOrId === "string") ? entryOrId : (entryOrId ? entryOrId.id : "");
        for (var i = 0; i < root._changelog.length; ++i)
            if (root._changelog[i].id === id)
                return root._changelog[i];
        return null;
    }
    // Read one field of a row for a binding; depends on _changelogRev so the
    // binding re-evaluates after an in-place change.
    function _rowField(id, key) {
        var rev = root._changelogRev;   // dependency only
        var e = root._entryOf(id);
        return e ? e[key] : undefined;
    }
    // The effective identity for a row: a re-pinned element wins over the entry's
    // agent-provided context; either may be absent.
    function _rowContext(entry) {
        return entry.repin || entry.context || null;
    }
    // Sync the shared pending queue to a row's state: drop any verification item
    // for this changelogId, then re-add it when the row is verified or a
    // non-empty rejection.
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
        var rejected = entry.state === "rejected" && comment.length > 0;
        // A verdict goes to the agent with the next Send: a rejection with its
        // comment, or a sign-off that the change works.
        if (rejected || entry.state === "verified") {
            var ctx = root._rowContext(entry) || {};
            next.push({
                "surface": "qml",
                "kind": "verification",
                "verdict": rejected ? "rejected" : "verified",
                "changelogId": id,
                "title": entry.title || "",
                "comment": rejected ? comment : "",
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
    // Set a row to "verified", "rejected" or back to "unset". Verified and unset
    // clear the issue and drop its queued item. Takes the entry or its id and
    // always mutates the live entry in place (see _entryOf), then bumps
    // _changelogRev so the row redraws.
    function _setRowState(entryOrId, s) {
        var entry = root._entryOf(entryOrId);
        if (!entry)
            return;
        entry.state = s;
        if (s !== "rejected") {
            entry.comment = "";
            entry.draft = "";
            entry.editing = false;
            if (root._repinFor === entry.id)
                root._repinFor = "";
        } else {
            // A rejection without an added issue opens its issue box.
            entry.editing = String(entry.comment || "").trim().length === 0;
        }
        entry.sent = false;
        root._updateVerification(entry);
        root._recordVerdict(entry);
        root._changelogRev++;
    }
    // The Rejected button: opens the issue box on an unset/verified row, and
    // undoes the rejection (drops its queued item) on a rejected one.
    function _toggleRejected(id) {
        var entry = root._entryOf(id);
        if (entry)
            root._setRowState(entry, entry.state === "rejected" ? "unset" : "rejected");
    }
    // Add (or update) a rejection in the pending batch. Rejections are not
    // sent on their own: like pins and notes they wait for the panel's Send.
    function _submitRejection(id, text) {
        var entry = root._entryOf(id);
        var t = String(text || "").trim();
        if (!entry)
            return false;
        if (t.length === 0) {
            root._setStatus("Describe what's wrong before adding the rejection", true);
            return false;
        }
        entry.state = "rejected";
        entry.comment = t;
        entry.draft = "";
        entry.editing = false;
        entry.sent = false;
        root._updateVerification(entry);
        root._recordVerdict(entry);
        root._changelogRev++;
        root._setStatus("Rejection added — it goes to the agent with the next Send", false);
        return true;
    }
    // Reopen an added rejection's issue box (the queued item stays until a new
    // text is submitted or the rejection is undone).
    function _editRejection(id) {
        var entry = root._entryOf(id);
        if (!entry)
            return;
        entry.draft = entry.comment;
        entry.editing = true;
        root._changelogRev++;
    }
    // Close the issue box without submitting: an added rejection keeps its
    // queued text; a rejection never added goes back to unset.
    function _cancelRejection(id) {
        var entry = root._entryOf(id);
        if (!entry)
            return;
        if (String(entry.comment || "").trim().length > 0) {
            entry.draft = "";
            entry.editing = false;
            root._changelogRev++;
        } else {
            root._setRowState(entry, "unset");
        }
    }
    // Verified is a toggle: a second click returns the row to unset.
    function _toggleVerified(id) {
        var entry = root._entryOf(id);
        if (entry)
            root._setRowState(entry, entry.state === "verified" ? "unset" : "verified");
    }
    // Arm re-pin for a row: the next pick attaches identity to this rejection.
    function _startRepin(entryOrId) {
        var entry = root._entryOf(entryOrId);
        if (!entry)
            return;
        if (entry.state !== "rejected") {
            entry.state = "rejected";
            entry.editing = true;
        }
        root._changelogRev++;
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
                root._changelogRev++;
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
        var ctx = entry ? root._rowContext(entry) : null;
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
    // A batch reached the server: clear the queue, remember the batch's
    // rejections as sent, and close this verification round.
    function _sendSucceeded(batch) {
        root._pending = [];
        root.pendingCount = 0;
        root._persist();          // clears the on-disk queue too
        // The verdicts in this batch are now with the agent: remember them as
        // sent (an unchanged re-delivery stays hidden, also after a restart)
        // and take those rows off the checklist. Rows not in the batch stay.
        var nv = {};
        for (var k in root._verdicts)
            nv[k] = root._verdicts[k];
        var sentIds = {};
        for (var b = 0; b < batch.length; ++b) {
            var it = batch[b];
            if (!(it && it.kind === "verification"))
                continue;
            sentIds[it.changelogId] = true;
            var v = nv[it.changelogId];
            if (v)
                nv[it.changelogId] = { "hash": v.hash, "state": v.state,
                    "comment": v.comment, "sent": true, "at": Date.now() };
        }
        root._verdicts = nv;
        root._saveVerdicts();
        root._changelog = root._changelog.filter(function (e) { return !sentIds[e.id]; });
        root._repinFor = "";
        root.connected = true;
        root._setStatus("Sent to agent ✓", false);
    }
    // "Send 3 to agent", or with sign-offs split out: "Send 1 · 2 verified to agent".
    function _sendLabel() {
        var v = 0;
        for (var i = 0; i < root._pending.length; ++i) {
            var p = root._pending[i];
            if (p && p.kind === "verification" && p.verdict === "verified")
                v++;
        }
        var n = root.pendingCount - v;
        var parts = [];
        if (n > 0 || v === 0)
            parts.push(String(n));
        if (v > 0)
            parts.push(v + " verified");
        return "Send " + parts.join(" · ") + " to agent";
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
                root._sendSucceeded(batch);
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
        root._restoreVerdicts();
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

    // A checklist control whose "on" look does not depend on the Controls
    // style (Button.highlighted is nearly invisible on a dark palette).
    component RowToggle: Button {
        id: tb
        property bool on: false
        property color onColor: "#1f5130"
        property color onBorder: "#2f7d49"
        property color onText: "#c9ffd8"
        padding: 6
        font.pixelSize: 12
        contentItem: Text {
            text: tb.text
            font: tb.font
            color: tb.on ? tb.onText : "#e8eaed"
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
            implicitHeight: 28
            radius: 6
            color: tb.on ? tb.onColor : (tb.down ? "#2a2e36" : "#1f232a")
            border.color: tb.on ? tb.onBorder : "#3a3f47"
        }
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
        objectName: "annotateCommentBox"
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
            // Qualified: an unqualified `header` would resolve to any element
            // id of that name in this file before this property.
            comment.header = root.beginPin(item);  // snapshot NOW
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
                objectName: "annotateCommentField"
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
        objectName: "annotatePill"
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
        // Takes every button, the wheel and hover over the whole pill, so none
        // of it reaches the app underneath; only a left click toggles.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            hoverEnabled: true
            preventStealing: true
            onClicked: mouse => {
                if (mouse.button === Qt.LeftButton)
                    root.requestAnnotate();
            }
            onWheel: wheel => { wheel.accepted = true; }
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
        implicitHeight: 10 + panelHeader.height + 8 + pcol.implicitHeight + 10
        height: Math.min(implicitHeight, maxHeight)

        // Swallow every mouse event on the panel's whole area (empty space,
        // text, margins) so nothing falls through to the app beneath it. The
        // controls and the scrolling body sit above this and still get theirs.
        MouseArea {
            objectName: "annotatePanelBlocker"
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            hoverEnabled: true
            preventStealing: true
            onWheel: wheel => { wheel.accepted = true; }
        }

        // Header: title/count, annotate toggle and a "–" minimise button
        // (collapses to the pill). Outside the scrolling body so it is always
        // reachable however long the checklist or the discussion gets.
        Item {
            id: panelHeader
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
            anchors.top: panelHeader.bottom
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
                // While annotating, say where the checklist and replies went.
                Text {
                    objectName: "annotateHiddenHint"
                    width: parent.width
                    wrapMode: Text.WordWrap
                    color: "#6b7178"
                    font.pixelSize: 11
                    font.italic: true
                    visible: root.annotating && (root._changelog.length > 0 || msgs.children.length > 0)
                    text: "Checklist and agent replies are hidden while annotating — press Esc or Stop annotating to see them."
                }
                // Verification checklist — one row per agent-delivered changelog entry,
                // mirroring the web overlay. Renders all user/agent strings via `Text`
                // only (never as markup).
                Column {
                    id: checklist
                    objectName: "annotateChecklist"
                    width: parent.width
                    spacing: 6
                    // Hidden while annotating: picking needs only the composer
                    // and Send, and the checklist would cover the app.
                    visible: root._changelog.length > 0 && !root.annotating
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
                            objectName: "changelogRow_" + entryId
                            width: checklist.width
                            spacing: 4
                            required property var modelData
                            // modelData is a copy; only its id is used. Everything
                            // that changes is read live from the entry.
                            readonly property string entryId: modelData.id
                            readonly property string rowState: root._rowField(entryId, "state") || "unset"
                            readonly property bool verified: rowState === "verified"
                            readonly property bool editing: rowState === "rejected"
                                && (root._rowField(entryId, "editing") === true)
                            readonly property string savedComment: root._rowField(entryId, "comment") || ""
                            // Opening the issue box puts the cursor in it.
                            onEditingChanged: if (editing) issueField.forceActiveFocus()
                            Rectangle { width: parent.width; height: 1; color: "#1c1f25" }
                            Text {
                                width: parent.width
                                wrapMode: Text.WordWrap
                                color: clRow.verified ? "#9dffb0" : "#e8eaed"
                                opacity: clRow.verified ? 0.75 : 1
                                font.pixelSize: 13
                                text: (clRow.verified ? "✓ " : "") + clRow.modelData.title
                            }
                            Text {
                                width: parent.width
                                visible: !clRow.verified && clRow.modelData.description.length > 0
                                wrapMode: Text.WordWrap
                                color: "#8b9199"
                                font.pixelSize: 11
                                text: clRow.modelData.description
                            }
                            Row {
                                spacing: 6
                                RowToggle {
                                    objectName: "verifyButton"
                                    text: clRow.verified ? "✓ Verified" : "Verified"
                                    on: clRow.verified
                                    ToolTip.visible: hovered
                                    ToolTip.text: clRow.verified ? "Click to undo" : "It works"
                                    onClicked: root._toggleVerified(clRow.entryId)
                                }
                                RowToggle {
                                    objectName: "rejectButton"
                                    text: "✕ Rejected"
                                    on: clRow.rowState === "rejected"
                                    onColor: "#5a2530"
                                    onBorder: "#8a3b48"
                                    onText: "#ffd6dc"
                                    ToolTip.visible: hovered
                                    ToolTip.text: clRow.rowState === "rejected" ? "Click to undo the rejection" : "It's wrong — describe the issue"
                                    onClicked: root._toggleRejected(clRow.entryId)
                                }
                                RowToggle {
                                    property var ctx: { root._changelogRev; return root._rowContext(root._entryOf(clRow.entryId) || {}); }
                                    visible: ctx && ctx.objectName ? true : false
                                    text: "⌖"
                                    ToolTip.visible: hovered
                                    ToolTip.text: "Locate in the app"
                                    onClicked: root._locate(root._entryOf(clRow.entryId))
                                }
                            }
                            Text {
                                objectName: "verifiedNote"
                                width: parent.width
                                visible: clRow.verified
                                wrapMode: Text.WordWrap
                                color: "#6fbf88"
                                font.pixelSize: 11
                                text: "Verified — goes to the agent with the next Send."
                            }
                            // Issue box (while editing): nothing is queued until
                            // "Add to batch" or Ctrl/⌘+Enter; Cancel / Esc closes it.
                            TextArea {
                                id: issueField
                                objectName: "issueField"
                                width: parent.width
                                visible: clRow.editing
                                wrapMode: TextArea.Wrap
                                textFormat: TextEdit.PlainText
                                placeholderText: "What's wrong? (Ctrl/⌘+Enter adds it to the batch)"
                                color: "#e8eaed"
                                background: Rectangle { color: "#0e1013"; border.color: "#8a3b48"; radius: 6 }
                                text: root._rowField(clRow.entryId, "draft") || ""
                                onTextChanged: {
                                    var e = root._entryOf(clRow.entryId);
                                    if (e)
                                        e.draft = text;   // a draft, not queued
                                }
                                Keys.onPressed: ev => {
                                    if ((ev.key === Qt.Key_Return || ev.key === Qt.Key_Enter)
                                            && (ev.modifiers & (Qt.ControlModifier | Qt.MetaModifier))) {
                                        root._submitRejection(clRow.entryId, issueField.text);
                                        ev.accepted = true;
                                    } else if (ev.key === Qt.Key_Escape) {
                                        root._cancelRejection(clRow.entryId);
                                        ev.accepted = true;
                                    }
                                }
                            }
                            Row {
                                visible: clRow.editing
                                spacing: 6
                                anchors.right: parent.right
                                RowToggle {
                                    objectName: "cancelRejectionButton"
                                    text: "Cancel"
                                    onClicked: root._cancelRejection(clRow.entryId)
                                }
                                RowToggle {
                                    objectName: "addRejectionButton"
                                    text: clRow.savedComment.length > 0 ? "Update rejection" : "Add to batch"
                                    on: issueField.text.trim().length > 0
                                    enabled: issueField.text.trim().length > 0
                                    onColor: "#2b5fd0"
                                    onBorder: "#2b5fd0"
                                    onText: "#ffffff"
                                    onClicked: root._submitRejection(clRow.entryId, issueField.text)
                                }
                            }
                            // Added rejection: what will be sent, with Edit / Undo.
                            Column {
                                objectName: "rejectedSummary"
                                width: parent.width
                                spacing: 4
                                visible: clRow.rowState === "rejected" && !clRow.editing
                                         && clRow.savedComment.length > 0
                                Text {
                                    objectName: "rejectedText"
                                    width: parent.width
                                    wrapMode: Text.WordWrap
                                    textFormat: Text.PlainText
                                    color: "#ffb3be"
                                    font.pixelSize: 12
                                    text: "✕ Rejected: " + clRow.savedComment
                                }
                                Text {
                                    width: parent.width
                                    wrapMode: Text.WordWrap
                                    color: "#8b9199"
                                    font.pixelSize: 11
                                    text: "In the batch — goes to the agent with the next Send."
                                }
                                Row {
                                    spacing: 6
                                    RowToggle {
                                        objectName: "editRejectionButton"
                                        text: "Edit"
                                        onClicked: root._editRejection(clRow.entryId)
                                    }
                                    RowToggle {
                                        objectName: "undoRejectionButton"
                                        text: "Undo"
                                        onClicked: root._setRowState(clRow.entryId, "unset")
                                    }
                                }
                            }
                            Button {
                                visible: clRow.rowState === "rejected"
                                text: root._repinFor === clRow.entryId
                                    ? "◎ Click an element…" : "⌖ Re-pin element"
                                onClicked: root._startRepin(clRow.entryId)
                            }
                        }
                    }
                }
                // Freeform note (not tied to an element) — mirrors the web composer.
                TextArea {
                    id: noteField
                    objectName: "annotateNoteField"
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
                        objectName: "annotateSend"
                        text: root._sendLabel()
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
                    visible: children.length > 0 && !root.annotating
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
