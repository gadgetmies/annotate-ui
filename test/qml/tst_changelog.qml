// Headless (offscreen) QML parity tests for the changelog-verification checklist.
// Run with:
//   QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Basic \
//     qmltestrunner -input test/qml
// Mirrors the web overlay's pure-logic tests: a delivered changelog parses and
// renders rows; rejecting queues a kind:"verification" pending item keyed by
// changelogId; verifying (or re-pinning) keeps the row and its queued issue in
// sync; the wire shapes match the web overlay's discriminators.
import QtQuick
import QtTest
import "../../qml"

TestCase {
    id: tc
    name: "ChangelogVerification"
    width: 400
    height: 400
    when: windowShown

    AnnotateOverlay {
        id: overlay
        width: 400
        height: 400
    }

    function reset() {
        overlay._changelog = [];
        overlay._pending = [];
        overlay.pendingCount = 0;
        overlay._repinFor = "";
    }

    // A delivered changelog parses into rows; entries without context still parse.
    function test_01_ingest_parses_rows() {
        reset();
        overlay._ingestChangelog([
            { id: "c1", title: "Star now gold", description: "changed fill",
              context: { objectName: "starBtn", qmlType: "Button",
                         qmlFile: "Rating.qml", typeChain: ["Row"] } },
            { id: "c2", title: "Debounced search" }        // no context
        ]);
        compare(overlay._changelog.length, 2);
        compare(overlay._changelog[0].id, "c1");
        compare(overlay._changelog[0].title, "Star now gold");
        compare(overlay._changelog[1].context, null);
        // Re-delivery de-dupes by id (never clobbers in-progress state).
        overlay._ingestChangelog([{ id: "c1", title: "dupe" }]);
        compare(overlay._changelog.length, 2);
    }

    // Rejecting with a comment queues a kind:"verification" item auto-linked to
    // the entry's context; verifying removes it.
    function test_02_reject_queues_verification() {
        reset();
        overlay._ingestChangelog([
            { id: "c1", title: "Star", context: { objectName: "starBtn",
              qmlType: "Button", qmlFile: "Rating.qml", typeChain: ["Row"] } }
        ]);
        var e = overlay._changelog[0];
        overlay._setRowState(e, "rejected");
        compare(overlay._pending.length, 0);       // rejected but no comment yet
        e.comment = "still orange";
        overlay._updateVerification(e);
        compare(overlay._pending.length, 1);
        var v = overlay._pending[0];
        compare(v.kind, "verification");
        compare(v.verdict, "rejected");
        compare(v.title, "Star");
        compare(v.surface, "qml");
        compare(v.changelogId, "c1");
        compare(v.comment, "still orange");
        compare(v.objectName, "starBtn");          // auto-linked from context
        compare(v.qmlType, "Button");
        // Switching to Verified replaces it with a verified sign-off (one item
        // per changelogId), still tied to the entry's context.
        overlay._setRowState(e, "verified");
        compare(overlay._pending.length, 1);
        compare(overlay._pending[0].verdict, "verified");
        compare(overlay._pending[0].changelogId, "c1");
        compare(overlay._pending[0].title, "Star");
        compare(overlay._pending[0].comment, "");
        compare(overlay._pending[0].objectName, "starBtn");
        // Back to unset drops it.
        overlay._setRowState(e, "unset");
        compare(overlay._pending.length, 0);
    }

    // A re-pin replaces the row's context on its queued verification item.
    function test_03_repin_overrides_context() {
        reset();
        overlay._ingestChangelog([
            { id: "c3", title: "x", context: { objectName: "old", qmlType: "T",
              qmlFile: "F.qml", typeChain: [] } }
        ]);
        var e = overlay._changelog[0];
        overlay._setRowState(e, "rejected");
        e.comment = "bad"; overlay._updateVerification(e);
        compare(overlay._pending[0].objectName, "old");
        overlay._attachRepin("c3", { objectName: "fresh", qmlType: "Button",
                                     qmlFile: "New.qml", typeChain: ["Col"] });
        compare(overlay._pending.length, 1);
        compare(overlay._pending[0].objectName, "fresh");
        compare(overlay._pending[0].qmlType, "Button");
    }

    // A mixed queue (pin + note + verification) is one annotations array, and the
    // verification is identifiable by kind — parity with the web overlay.
    function test_04_mixed_batch_shape() {
        reset();
        overlay._enqueue(overlay._buildPayload(
            { surface: "qml", objectName: "b", qmlType: "Button", typeChain: [],
              qmlFile: "A.qml", props: {}, route: "" }, "a pin"));
        overlay.commitNote("a note");
        overlay._ingestChangelog([{ id: "c9", title: "y" }]);
        var e = overlay._changelog[0];
        overlay._setRowState(e, "rejected");
        e.comment = "nope"; overlay._updateVerification(e);
        compare(overlay._pending.length, 3);
        var kinds = overlay._pending.map(function (p) { return p.kind || "pin"; });
        verify(kinds.indexOf("note") !== -1);
        verify(kinds.indexOf("verification") !== -1);
        verify(kinds.indexOf("pin") !== -1);
    }

    // Malformed / unknown changelog input is ignored without error.
    function test_05_bad_input_ignored() {
        reset();
        overlay._ingestChangelog(null);
        overlay._ingestChangelog([]);
        overlay._ingestChangelog([{ title: "no id" }]);   // missing id → skipped
        compare(overlay._changelog.length, 0);
    }
}
