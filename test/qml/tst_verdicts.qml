// Headless (offscreen) tests: checklist verdicts go to the agent with Send,
// sent rows leave the checklist, and verdicts survive an overlay restart
// through the optional loadVerdicts/saveVerdicts host hooks, so an unchanged
// re-delivery stays hidden while a changed one comes back unset.
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
    function copy(v) { return JSON.parse(JSON.stringify(v)); }

    // A fresh overlay that gets the server's (re-)delivered changelog.
    function boot(list) {
        var o = createTemporaryObject(overlayComp, tc, { host: store });
        verify(o);
        o.connected = true;
        o._ingestChangelog(copy(list || delivered));
        return o;
    }
    function ids(o) { return o._changelog.map(function (e) { return e.id; }); }
    function init() {
        store.pending = "";
        store.verdicts = "";
    }

    // The batch carries a verified sign-off and a rejection, each with its
    // verdict, changelogId, title and context.
    function test_01_verified_payload() {
        var o = boot();
        o._toggleVerified("c1");
        o._toggleRejected("c3");
        verify(o._submitRejection("c3", "still tiny"));
        compare(o.pendingCount, 2);
        var byId = {};
        o._pending.forEach(function (p) { byId[p.changelogId] = p; });
        compare(byId.c1.kind, "verification");
        compare(byId.c1.verdict, "verified");
        compare(byId.c1.title, "Star now gold");
        compare(byId.c1.comment, "");
        compare(byId.c1.objectName, "starBtn");
        compare(byId.c3.verdict, "rejected");
        compare(byId.c3.comment, "still tiny");
        waitForRendering(o);
        compare(findChild(o, "annotateSend").text, "Send 1 · 1 verified to agent");
    }

    // After a successful Send the sent rows leave the checklist; the rest
    // stay. When every row is settled and sent, the checklist disappears.
    function test_02_sent_items_removed() {
        var o = boot();
        o._toggleVerified("c1");
        o._toggleRejected("c3");
        o._submitRejection("c3", "still tiny");
        o._sendSucceeded(o._pending.slice());
        compare(o.pendingCount, 0);
        compare(ids(o), ["c2", "c4"], "only the unsent rows remain");
        waitForRendering(o);
        verify(findChild(o, "annotateChecklist").visible);
        o._toggleVerified("c2");
        o._toggleVerified("c4");
        o._sendSucceeded(o._pending.slice());
        compare(o._changelog.length, 0);
        waitForRendering(o);
        verify(!findChild(o, "annotateChecklist").visible, "checklist gone");
    }

    // Restart: sent verdicts stay hidden on the server's re-delivery; settled
    // but unsent verdicts come back with their queued items; untouched rows
    // stay unset.
    function test_03_restart_round_trip() {
        var a = boot();
        a._toggleVerified("c1");
        a._toggleRejected("c3");
        a._submitRejection("c3", "still tiny");
        a._sendSucceeded(a._pending.slice());           // c1 + c3 sent
        a._toggleRejected("c2");
        a._submitRejection("c2", "fires twice");          // queued, not sent
        a.destroy();
        wait(0);

        var b = boot();                                   // the app restarted
        compare(ids(b), ["c2", "c4"], "sent c1/c3 stay hidden");
        compare(b._entryOf("c2").state, "rejected");
        compare(b._entryOf("c2").comment, "fires twice");
        compare(b.pendingCount, 1, "the unsent rejection is still queued");
        compare(b._pending[0].changelogId, "c2");
        compare(b._entryOf("c4").state, "unset");
        // An unsent Verified also survives.
        b._toggleVerified("c4");
        b.destroy();
        wait(0);
        var c = boot();
        compare(c._entryOf("c4").state, "verified");
        compare(c.pendingCount, 2);
    }

    // The agent re-delivers a sent id with changed content ("fixed again"):
    // it reappears unset and its old verdict is forgotten. Reordered context
    // keys are not a change.
    function test_04_changed_redelivery_reappears() {
        var a = boot();
        a._toggleVerified("c1");
        a._toggleVerified("c2");
        a._sendSucceeded(a._pending.slice());
        a.destroy();
        wait(0);

        var changed = copy(delivered);
        changed[0].description = "fill colour, fixed again";
        changed[0].context = { typeChain: ["Row"], qmlFile: "Rating.qml",
                               qmlType: "Button", objectName: "starBtn" };  // reordered only
        var b = boot(changed);
        verify(ids(b).indexOf("c1") !== -1, "changed c1 is back");
        compare(b._entryOf("c1").state, "unset");
        compare(JSON.parse(store.verdicts).c1, undefined, "stale verdict forgotten");
        verify(ids(b).indexOf("c2") === -1, "unchanged c2 stays hidden");

        var reordered = copy(delivered);
        reordered[1].title = "Debounced search";
        var c = boot(reordered);
        verify(ids(c).indexOf("c2") === -1);
    }

    // No verdict hooks (older host): everything still works in memory.
    function test_05_no_hooks_in_memory() {
        var o = createTemporaryObject(overlayComp, tc, { host: null });
        o._ingestChangelog([{ id: "x", title: "x" }]);
        o._toggleVerified("x");
        compare(o._entryOf("x").state, "verified");
        o._sendSucceeded(o._pending.slice());
        compare(o._changelog.length, 0);
    }
}
