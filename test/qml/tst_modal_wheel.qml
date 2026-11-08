// Headless (offscreen) test: with the overlay installed above popups, the
// mouse wheel still reaches a modal popup's scrollable content. The overlay's
// full-window root must not count as "the item under the pointer", or Qt
// Quick Controls drops every wheel event outside the modal popup.
// Run with `npm run test:qml`.
import QtQuick
import QtQuick.Controls
import QtTest
import "../../qml"

TestCase {
    id: tc
    name: "ModalWheel"
    width: 420
    height: 500
    visible: true
    when: windowShown

    Popup {
        id: dialog
        modal: true
        x: 40; y: 40
        width: 300; height: 300
        Flickable {
            id: page
            anchors.fill: parent
            contentHeight: 2000
            clip: true
            Rectangle { width: parent.width; height: 2000; color: "#335" }
        }
    }

    AnnotateOverlay {
        id: overlay
        width: 420
        height: 500
    }

    function initTestCase() {
        // Hosts parent it into the window's content item at its z, above the
        // popup layer (Overlay.overlay), as Harmonia's qml_annotate does.
        overlay.parent = tc.Window.window.contentItem;
        // Keep the panel out of the way: only the bare root may be under the
        // pointer (the panel itself is meant to take the wheel).
        overlay.minimized = true;
    }

    function test_wheel_reaches_a_modal_popup() {
        dialog.open();
        tryCompare(dialog, "opened", true);
        page.contentY = 0;
        mouseWheel(page, 100, 100, 0, -120);
        tryVerify(function() { return page.contentY > 0; }, 2000,
                  "the wheel never reached the modal popup's content");
        dialog.close();
    }
}
