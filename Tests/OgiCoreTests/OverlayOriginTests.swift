#if canImport(AppKit)
import AppKit
import XCTest
@testable import OgiCore

/// The one test in this suite that touches the view layer, and it exists for one reason:
/// **every other fixture in the suite puts its screen at (0, 0)**, which is the single
/// arrangement where this whole class of bug is an identity transform and cannot be seen.
///
/// He is positioned in NSScreen-global coordinates. A view's space starts at its window's
/// origin. On a primary display those are the same numbers. On a second display they are not,
/// and every layer lands `screen.frame.origin` away from where it belongs, which is off the
/// window, and a sublayer outside its window is not clipped, it is never drawn at all.
@MainActor
final class OverlayOriginTests: XCTestCase {

    private let size = CGSize(width: 1920, height: 1080)
    /// Deliberately near the right edge of his own screen. A spot near the middle stays inside
    /// the window even when it is drawn a whole screen-origin out, so it cannot tell the two
    /// cases apart: the first version of this test passed against the unfixed code.
    private let spotOnHisScreen = CGPoint(x: 1500, y: 700)

    /// Window-local rect of the container everything visible hangs off, which is what has to
    /// land inside the view for him to appear at all.
    private func drawnBox(_ v: OgiView) throws -> CGRect {
        let root = try XCTUnwrap(v.layer?.sublayers?.first, "no root layer")
        let box = try XCTUnwrap(root.sublayers?.first, "no mask container")
        // `root` has no bounds of its own, so its position is a pure translation of its children.
        return box.frame.offsetBy(dx: root.position.x, dy: root.position.y)
    }

    /// Draws him at `spotOnHisScreen` on a screen whose global origin is `screenOrigin`, and
    /// returns where that landed in the window's own coordinates.
    private func draw(screenOrigin: CGPoint) throws -> CGRect {
        let v = OgiView(frame: CGRect(origin: .zero, size: size))
        v.setScreenOrigin(screenOrigin)
        let cat = CatState(position: CGPoint(x: screenOrigin.x + spotOnHisScreen.x,
                                             y: screenOrigin.y + spotOnHisScreen.y))
        let pose = Body.Pose()
        v.apply(cat, pose: pose, gaze: Gaze(), frame: Sprites.frame(for: cat, pose: pose),
                heightAboveGround: 0, occluders: [])
        return try drawnBox(v)
    }

    private func assertDrawnInsideTheWindow(_ box: CGRect, _ what: String,
                                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(CGRect(origin: .zero, size: size).contains(box),
                      "\(what): drawn at \(box), outside a \(size.width)x\(size.height) window. "
                      + "A sublayer outside its window is not drawn at all, so he is invisible.",
                      file: file, line: line)
    }

    /// The primary display, where it always worked. Guards the fix against being "simplified"
    /// back out by someone who only ever tests on one screen.
    func testPrimaryDisplayIsUnchanged() throws {
        assertDrawnInsideTheWindow(try draw(screenOrigin: .zero), "primary display")
    }

    /// An ordinary two-monitor desk: a display to the right of and below the primary. Without
    /// the root translation the box lands a full screen-origin out and misses the window
    /// completely, which is the shipped bug: invisible cat, and clicks still swallowed at the
    /// place he logically is.
    func testSecondDisplayDrawsInsideItsOwnWindow() throws {
        assertDrawnInsideTheWindow(try draw(screenOrigin: CGPoint(x: 1512, y: -300)),
                                   "display right of and below the primary")
    }

    /// The invariant, stated once: the same cat on the same spot of the same screen is drawn in
    /// the same place, whichever display that screen happens to be. Covers the arrangements
    /// that produce negative origins (a display left of, or above, the primary), which is where
    /// the sign of the translation matters.
    func testTheSameSpotDrawsTheSameWhicheverDisplay() throws {
        let onPrimary = try draw(screenOrigin: .zero)
        for origin in [CGPoint(x: 1512, y: 0), CGPoint(x: -1920, y: 0),
                       CGPoint(x: 0, y: -1117), CGPoint(x: 1512, y: -300)] {
            let elsewhere = try draw(screenOrigin: origin)
            XCTAssertEqual(elsewhere.origin.x, onPrimary.origin.x, accuracy: 0.001,
                           "x differs with the screen at \(origin)")
            XCTAssertEqual(elsewhere.origin.y, onPrimary.origin.y, accuracy: 0.001,
                           "y differs with the screen at \(origin)")
        }
    }
}
#endif
