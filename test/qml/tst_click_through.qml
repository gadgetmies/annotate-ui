// Headless (offscreen) test: the overlay's panel and pill take every mouse
// event on their whole area, so nothing reaches the app underneath, while a
// click outside them (annotate mode off) still reaches the app.
// Run with `npm run test:qml`.
import QtQuick
import QtTest
import "../../qml"

TestCase {
    id: tc
    name: "ClickThrough"
    width: 420
    height: 500
    visible: true
    when: windowShown

    // Stand-in for the app: counts every mouse event that reaches it.
    MouseArea {
        id: app
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        hoverEnabled: true
        property int presses: 0
        property int wheels: 0
        onPressed: presses++
        onWheel: wheel => { wheels++; wheel.accepted = true; }
    }

    AnnotateOverlay {
        id: overlay
        width: 420
        height: 500
    }

    function init() {
        overlay.annotating = false;
        overlay.minimized = false;
        overlay.connected = true;
        overlay._changelog = [];
        overlay._pending = [];
        overlay.pendingCount = 0;
        app.presses = 0;
        app.wheels = 0;
    }

    function test_01_panel_and_pill_swallow_mouse() {
        overlay._ingestChangelog([{ id: "c1", title: "A change",
                                    description: "Some text to click on" }]);
        waitForRendering(overlay);
        var panel = findChild(overlay, "annotatePanel");
        verify(panel.visible);
        // Empty corner of the panel (inside its border, outside any control),
        // then the middle of the body, with every button and the wheel.
        var spots = [[3, 3], [3, panel.height - 3], [panel.width / 2, panel.height - 4]];
        for (var i = 0; i < spots.length; ++i) {
            var x = spots[i][0], y = spots[i][1];
            mouseClick(panel, x, y, Qt.LeftButton);
            mouseClick(panel, x, y, Qt.RightButton);
            mouseClick(panel, x, y, Qt.MiddleButton);
            mouseWheel(panel, x, y, 0, -120);
        }
        compare(app.presses, 0, "no press reached the app through the panel");
        compare(app.wheels, 0, "no wheel reached the app through the panel");

        var pill = findChild(overlay, "annotatePill");
        mouseClick(pill, 2, 2, Qt.RightButton);
        mouseWheel(pill, 2, 2, 0, -120);
        compare(app.presses, 0, "no press reached the app through the pill");
        compare(app.wheels, 0, "no wheel reached the app through the pill");
    }

    // Outside the panel and pill, with annotate mode off, the app still gets clicks.
    function test_02_outside_still_reaches_app() {
        waitForRendering(overlay);
        mouseClick(overlay, overlay.width - 10, 10, Qt.LeftButton);
        compare(app.presses, 1);
        mouseWheel(overlay, overlay.width - 10, 10, 0, -120);
        compare(app.wheels, 1);
    }
}
