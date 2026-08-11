import Testing
import Foundation
import CoreGraphics
@testable import OgiCore

@MainActor
@Test func beingPettedDoesNotChangeHisSize() {
    // The stroke sheet has his eyes squeezed shut in all five frames, so it is sized by
    // `Feel.Shape.strokedHeight` rather than by an eye it cannot measure. A hand-tuned
    // constant with nothing holding it is how `denSleep` came out 30% short, so it is pinned
    // here against the clip it hands off to and from.
    //
    // `idle` is the reference because it is the same animal in the same posture: a cat sitting
    // upright, side on, drawn to the same ground line. Pinning against a number instead would
    // only restate the constant.
    //
    // Slightly TALLER than idle is correct rather than a tolerance: the band has to hold his
    // head at the top of the push, and the cutter crops to the tallest frame in the sheet.
    let idle = Sprites.size(.idle, 0).height
    let stroked = Sprites.size(.stroked, 0).height
    let ratio = stroked / idle
    let detail = String(format: "%.2fx an idle cat (%.1fpt against %.1fpt)", ratio, stroked, idle)
    #expect(ratio > 1.0 && ratio < 1.25, "a petted cat renders \(detail)")
}

@MainActor
@Test func theStrokeSheetHasAllItsFrames() {
    for i in 0..<Sprites.Clip.stroked.count {
        #expect(Sprites.image(.stroked, i) != nil, "stroked\(i) is missing")
    }
}

@MainActor
@Test func aPettedCatIsSizedByHisBandAndNotByAShutEye() {
    // The rule the sheet was drawn under, kept next to the sheet. A contentedly shut eye is a
    // wide flat line, so `eyes()` measures it wide and the clip renders short — the third of
    // the three ways that measurement fails, and the second sheet to hit it.
    #expect(Sprites.bandHeight(.stroked) != nil,
            "the stroke sheet is being sized by an eye that is closed in every frame")
}

/// `App` builds the hit rect and `Overlay` builds the drawing, and they used to work out
/// independently where he is. During a notch side peek they disagreed completely: the lift up
/// the cutout wall and the quarter turn onto its side moved the picture and not the box, so his
/// visible head was click-through while a patch below him petted a cat who was not there.
@MainActor
@Test func theClickBoxFollowsHimIntoTheNotch() {
    var cat = CatState(position: CGPoint(x: 834, y: 1205))
    cat.activity = .peerDown
    cat.inNotch = true
    let frame = Sprites.frame(for: cat, pose: Body.Pose())
    let at = cat.position

    // Straight down out of the cutout: no turn, so only the lift moves it.
    let below = Sprites.drawnBox(frame, at: at, lift: 24.05, side: .below)
    #expect(below.minY > frame.rect(at: at).minY, "the lift did not move the box")

    // Onto a side wall: a quarter turn about the anchor.
    for side in [CatState.NotchSide.left, .right] {
        let turned = Sprites.drawnBox(frame, at: at, lift: 24.05, side: side)
        let flat = Sprites.drawnBox(frame, at: at, lift: 24.05, side: .below)
        #expect(turned.intersects(flat), "the turned box lost him entirely")
        // A quarter turn swaps the extents, so a tall frame becomes a wide box.
        #expect(abs(turned.width - flat.height) < 0.001, "the turn did not rotate the box")
        #expect(abs(turned.height - flat.width) < 0.001, "the turn did not rotate the box")
    }
}
