// Headless (offscreen) test of the core pick flow: with annotate mode on, a
// click on an app element opens the comment popup with its text field focused,
// and Add queues the pin. Run with `npm run test:qml`.
import QtQuick
import QtTest
import "../../qml"

TestCase {
    id: tc
    name: "PickPopup"
    width: 500
    height: 600
    visible: true
    when: windowShown

    // Stand-in for the app content under the overlay.
    Rectangle {
        anchors.fill: parent
        color: "white"
        Rectangle {
            id: target
            objectName: "target"
            x: 250; y: 50; width: 120; height: 60
            color: "red"
        }
    }

    AnnotateOverlay {
        id: overlay
        width: 500
        height: 600
    }

    function test_01_click_opens_comment_popup() {
        overlay.connected = true;
        overlay.annotating = true;
        waitForRendering(overlay);
        var box = findChild(overlay, "annotateCommentBox");
        verify(!box.visible);
        mouseMove(overlay, 300, 80);
        mouseClick(overlay, 300, 80);
        tryVerify(function () { return box.visible; }, 1000, "comment popup opened");
        var field = findChild(box, "annotateCommentField");
        tryVerify(function () { return field.activeFocus; }, 1000, "text field focused");
        compare(box.header.objectName, "target");
        keyClick("f"); keyClick("i"); keyClick("x");
        keyClick(Qt.Key_Return, Qt.ControlModifier);
        verify(!box.visible);
        compare(overlay.pendingCount, 1);
        compare(overlay._pending[0].objectName, "target");
        compare(overlay._pending[0].comment, "fix");
    }
}
