// Headless (offscreen) usability tests for the QML overlay's panel: it stays
// inside the window with its header reachable, and its body scrolls.
// Run with `npm run test:qml`.
import QtQuick
import QtQuick.Controls
import QtTest
import "../../qml"

TestCase {
    id: tc
    name: "PanelUsability"
    width: 420
    height: 500
    // TestCase is invisible by default; the panel's controls must be visible
    // for the mouse to reach them.
    visible: true
    when: windowShown

    AnnotateOverlay {
        id: overlay
        width: 420
        height: 500
    }

    function reset() {
        overlay.annotating = false;
        overlay.minimized = false;
        overlay._changelog = [];
        overlay._pending = [];
        overlay.pendingCount = 0;
        overlay._repinFor = "";
    }
    function many(n) {
        var list = [];
        for (var i = 0; i < n; ++i)
            list.push({ id: "c" + i, title: "Change number " + i,
                        description: "A fairly long description of what changed in item " + i });
        overlay._ingestChangelog(list);
    }
    function panel() { return findChild(overlay, "annotatePanel"); }
    function body() { return findChild(overlay, "annotatePanelBody"); }

    // With many changelog items the panel is bounded by the window, the header
    // and its minimise button stay on screen, and the body scrolls.
    function test_01_panel_bounded_header_visible() {
        reset();
        many(30);
        waitForRendering(overlay);
        var p = panel();
        verify(p.visible);
        verify(p.implicitHeight > overlay.height, "content taller than the window");
        var top = p.mapToItem(overlay, 0, 0).y;
        verify(top >= 0, "panel top inside the window: " + top);
        verify(top + p.height <= overlay.height, "panel bottom inside the window");
        var min = findChild(overlay, "annotateMinimise");
        verify(min.visible);
        var mt = min.mapToItem(overlay, 0, 0).y;
        verify(mt >= 0 && mt + min.height <= overlay.height, "minimise on screen");
        var b = body();
        verify(b.contentHeight > b.height, "body overflows, so it scrolls");
        compare(findChild(overlay, "annotatePanelScrollBar").policy, ScrollBar.AlwaysOn);
        // Minimise still works with the long list.
        mouseClick(min);
        verify(overlay.minimized);
        verify(!p.visible);
    }

    // The mouse wheel scrolls the panel body.
    function test_02_wheel_scrolls_body() {
        reset();
        many(30);
        waitForRendering(overlay);
        var b = body();
        compare(b.contentY, 0);
        mouseWheel(b, b.width / 2, b.height / 2, 0, -360);
        tryVerify(function () { return b.contentY > 0; }, 1000, "wheel scrolled the body");
    }

    // A short panel is as tall as its content (no needless empty space).
    function test_03_short_panel_fits_content() {
        reset();
        overlay.connected = true;   // no recovery UI → a short panel
        many(1);
        waitForRendering(overlay);
        var p = panel();
        compare(p.height, p.implicitHeight);
        compare(findChild(overlay, "annotatePanelScrollBar").policy, ScrollBar.AlwaysOff);
    }

    // Annotate mode hides the checklist and the discussion; the composer and
    // Send stay. Leaving annotate mode shows them again.
    function test_04_annotate_mode_hides_checklist_and_messages() {
        reset();
        many(2);
        overlay._appendMessage("Fixed the star colour");
        waitForRendering(overlay);
        var cl = findChild(overlay, "annotateChecklist");
        var msgs = findChild(overlay, "annotateMessages");
        verify(cl.visible);
        verify(msgs.visible);
        overlay.annotating = true;
        verify(!cl.visible, "checklist hidden while annotating");
        verify(!msgs.visible, "agent replies hidden while annotating");
        verify(findChild(overlay, "annotateHiddenHint").visible);
        verify(findChild(overlay, "annotateNoteField").visible, "note composer kept");
        verify(findChild(overlay, "annotateSend").visible, "Send kept");
        overlay.annotating = false;
        verify(cl.visible);
        verify(msgs.visible);
        verify(!findChild(overlay, "annotateHiddenHint").visible);
    }

    function row(id) { return findChild(overlay, "changelogRow_" + id); }
    function rowChild(id, name) { return findChild(row(id), name); }

    // Clicking Verified changes the live entry (not a delegate copy), shows it
    // on the row, queues a verified sign-off, and a second click undoes it.
    function test_05_verified_toggles() {
        reset();
        overlay.connected = true;
        many(2);
        waitForRendering(overlay);
        var btn = rowChild("c0", "verifyButton");
        verify(btn);
        mouseClick(btn);
        compare(overlay._entryOf("c0").state, "verified");
        verify(btn.on, "button shows the verified state");
        verify(rowChild("c0", "verifiedNote").visible, "row says nothing is sent");
        compare(overlay.pendingCount, 1, "verified sign-off queued for Send");
        compare(overlay._pending[0].verdict, "verified");
        compare(findChild(overlay, "annotateSend").text, "Send 1 verified to agent");
        // A later changelog delivery rebuilds the rows; the state survives.
        overlay._ingestChangelog([{ id: "late", title: "Late change" }]);
        waitForRendering(overlay);
        compare(row("c0").rowState, "verified");
        mouseClick(rowChild("c0", "verifyButton"));
        compare(overlay._entryOf("c0").state, "unset");
        compare(overlay.pendingCount, 0, "undo drops the sign-off");
        verify(!rowChild("c0", "verifyButton").on);
        verify(!rowChild("c0", "verifiedNote").visible);
    }

    // Rejected opens an issue box; nothing is queued while typing. "Add to
    // batch" queues a kind:"verification" item (sent with the next Send), the
    // row then shows the rejection with Edit / Undo.
    function test_06_rejection_submit_adds_to_batch() {
        reset();
        overlay.connected = true;
        overlay._ingestChangelog([{ id: "r1", title: "Star gold",
            context: { objectName: "starBtn", qmlType: "Button", qmlFile: "Rating.qml", typeChain: [] } }]);
        waitForRendering(overlay);
        mouseClick(rowChild("r1", "rejectButton"));
        var field = rowChild("r1", "issueField");
        verify(field.visible, "issue box opens");
        tryVerify(function () { return field.activeFocus; }, 1000, "issue box focused");
        var add = rowChild("r1", "addRejectionButton");
        verify(add.visible);
        verify(!add.enabled, "nothing to add yet");
        keyClick("s"); keyClick("t"); keyClick("i"); keyClick("l"); keyClick("l");
        compare(overlay.pendingCount, 0, "typing does not queue");
        verify(add.enabled);
        waitForRendering(overlay);   // typing re-lays out the row
        mouseClick(add);
        compare(overlay.pendingCount, 1);
        var v = overlay._pending[0];
        compare(v.kind, "verification");
        compare(v.changelogId, "r1");
        compare(v.comment, "still");
        compare(v.objectName, "starBtn");
        verify(!field.visible, "issue box closes");
        verify(rowChild("r1", "rejectedSummary").visible);
        compare(rowChild("r1", "rejectedText").text, "✕ Rejected: still");
        compare(findChild(overlay, "annotateSend").text, "Send 1 to agent");
        // Edit + Ctrl+Enter updates the queued item in place.
        waitForRendering(overlay);
        mouseClick(rowChild("r1", "editRejectionButton"));
        verify(field.visible);
        tryVerify(function () { return field.activeFocus; }, 1000);
        field.selectAll();
        keyClick("x");
        keyClick(Qt.Key_Return, Qt.ControlModifier);
        compare(overlay.pendingCount, 1);
        compare(overlay._pending[0].comment, "x");
        // Undo drops it.
        waitForRendering(overlay);
        mouseClick(rowChild("r1", "undoRejectionButton"));
        compare(overlay.pendingCount, 0);
        compare(overlay._entryOf("r1").state, "unset");
    }

    // Cancel on a never-added rejection returns the row to unset, queuing nothing.
    function test_07_rejection_cancel() {
        reset();
        overlay.connected = true;
        overlay._ingestChangelog([{ id: "r2", title: "x" }]);
        waitForRendering(overlay);
        mouseClick(rowChild("r2", "rejectButton"));
        tryVerify(function () { return rowChild("r2", "issueField").activeFocus; }, 1000);
        keyClick("n");
        waitForRendering(overlay);
        mouseClick(rowChild("r2", "cancelRejectionButton"));
        compare(overlay.pendingCount, 0);
        compare(overlay._entryOf("r2").state, "unset");
        verify(!rowChild("r2", "issueField").visible);
    }
}
