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
