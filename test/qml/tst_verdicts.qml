// Headless (offscreen) tests: checklist verdicts survive an overlay restart
// through the optional loadVerdicts/saveVerdicts host hooks, and a re-delivery
// of the same id with changed content resets the row.
// Run with `npm run test:qml`.
import QtQuick
import QtTest
import "../../qml"

TestCase {
    id: tc
    name: "Verdicts"
    width: 420
    height: 600
    visible: true
    when: windowShown

    // Stand-in for the host's durable storage (Harmonia: files in its state
    // dir). It outlives the overlays, like the files outlive the app.
    QtObject {
        id: store
        property string pending: ""
        property string verdicts: ""
        function loadPending() { return pending; }
        function savePending(raw) { pending = raw; }
        function loadVerdicts() { return verdicts; }
        function saveVerdicts(raw) { verdicts = raw; }
    }
    Component {
        id: overlayComp
        AnnotateOverlay { width: 420; height: 600 }
    }

    readonly property var delivered: [
        { id: "c1", title: "Star now gold", description: "fill colour",
          context: { objectName: "starBtn", qmlType: "Button", qmlFile: "Rating.qml", typeChain: ["Row"] } },
        { id: "c2", title: "Debounced search" },
        { id: "c3", title: "Bigger font" },
        { id: "c4", title: "Untouched" }
    ]

    function boot() {
        var o = createTemporaryObject(overlayComp, tc, { host: store });
        verify(o);
        o.connected = true;
        o._ingestChangelog(JSON.parse(JSON.stringify(delivered)));   // the server re-delivers
        return o;
    }
    function init() {
        store.pending = "";
        store.verdicts = "";
    }

    // Verified, rejected-and-sent and rejected-pending all come back after a
    // restart; an untouched row stays unset.
    function test_01_restart_round_trip() {
        var a = boot();
        a._toggleVerified("c1");
        a._toggleRejected("c3");
        verify(a._submitRejection("c3", "still tiny"));
        a._sendSucceeded(a._pending.slice());           // c3 went to the agent
        a._ingestChangelog(JSON.parse(JSON.stringify(delivered)));
        a._toggleRejected("c2");
        verify(a._submitRejection("c2", "fires twice"));  // queued, not sent
        compare(a.pendingCount, 1);
        a.destroy();
        wait(0);

        var b = boot();                                   // the app restarted
        compare(b._entryOf("c1").state, "verified");
        compare(b._entryOf("c2").state, "rejected");
        compare(b._entryOf("c2").comment, "fires twice");
        verify(!b._entryOf("c2").sent);
        compare(b.pendingCount, 1, "the unsent rejection is still queued");
        compare(b._pending[0].changelogId, "c2");
        compare(b._entryOf("c3").state, "rejected");
        verify(b._entryOf("c3").sent);
        compare(b._entryOf("c4").state, "unset");
        waitForRendering(b);
        var c3 = findChild(b, "changelogRow_c3");
        verify(findChild(c3, "sentRejectionNote").visible, "shown as sent, collapsed");
        verify(!findChild(c3, "verifyButton").visible, "no controls on a sent rejection");
        verify(findChild(findChild(b, "changelogRow_c1"), "verifiedNote").visible);
    }

    // The agent re-delivers c1 with changed content: it comes back unset and
    // its remembered verdict is forgotten; unchanged c3 keeps its verdict.
    function test_02_changed_redelivery_resets() {
        var a = boot();
        a._toggleVerified("c1");
        a._toggleRejected("c3");
        a._submitRejection("c3", "still tiny");
        a.destroy();
        wait(0);

        var changed = JSON.parse(JSON.stringify(delivered));
        changed[0].description = "fill colour, fixed again";
        var b = createTemporaryObject(overlayComp, tc, { host: store });
        b._ingestChangelog(changed);
        compare(b._entryOf("c1").state, "unset");
        compare(JSON.parse(store.verdicts).c1, undefined, "stale verdict forgotten");
        compare(b._entryOf("c3").state, "rejected");
        compare(b._entryOf("c3").comment, "still tiny");
        // Key order in the context does not count as a change.
        var reordered = { id: "c9", title: "t", context: { b: 1, a: 2 } };
        b._ingestChangelog([reordered]);
        b._toggleVerified("c9");
        var c = createTemporaryObject(overlayComp, tc, { host: store });
        c._ingestChangelog([{ id: "c9", title: "t", context: { a: 2, b: 1 } }]);
        compare(c._entryOf("c9").state, "verified");
    }

    // A checklist whose rows all have a verdict does not open the panel alone.
    function test_03_resolved_checklist_keeps_panel_closed() {
        var a = boot();
        a._toggleVerified("c1"); a._toggleVerified("c2");
        a._toggleVerified("c3"); a._toggleVerified("c4");
        waitForRendering(a);
        verify(!findChild(a, "annotatePanel").visible);
        a._toggleVerified("c4");                          // undo → open again
        verify(findChild(a, "annotatePanel").visible);
    }

    // No verdict hooks (older host): everything still works in memory.
    function test_04_no_hooks_in_memory() {
        var o = createTemporaryObject(overlayComp, tc, { host: null });
        o._ingestChangelog([{ id: "x", title: "x" }]);
        o._toggleVerified("x");
        compare(o._entryOf("x").state, "verified");
    }
}
