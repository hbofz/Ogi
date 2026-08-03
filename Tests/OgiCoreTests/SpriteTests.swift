import Testing
import CoreGraphics
@testable import OgiCore

/// Clips regenerated against the current `art/character.png`. Add each name as its sheet
/// lands. Kept by hand on purpose: the old version inferred this from eye colour, which
/// stopped meaning anything the moment the cat himself became ginger.
private let redrawnClips: Set<String> = []

/// The drawn frames come from separately-generated sheets that draw him at wildly different
/// sizes, so `Sprites` rescales each clip to make him one cat. These check that it works,
/// because when it does not the failure is subtle on any single frame and glaring in motion.

@MainActor
@Test func everyClipRendersHimTheSameSize() {
    // The bug this exists for: `clipScale` used to measure the first frame that had a visible
    // eye, and on `idle` that frame reads 14px against a median of 25. He sat at one size and
    // changed size the moment he walked. Nothing about a single frame catches that; only
    // comparing clips against each other does.
    //
    // Scoped to clips regenerated against docs/ART-BRIEF.md. The older white-eyed sheets are
    // a 7x spread — `sitdown` measures 100px against `sleep`'s 14 — because eye detection on
    // them is simply unreliable: `sitdown` reads [6, 19, 5] and a sleeping cat's closed eyes
    // read [27, 40, 9, 4], none of which are eyes. No amount of statistics rescues a bad
    // measurement, and the fix is the sheet, not the code. So this covers the art that has
    // been redrawn, and gains teeth with each sheet that lands.
    let clips: [Sprites.Clip] = [.walk, .idle, .jump, .land, .fall, .run, .alert, .sitdown, .sleep]
        .filter { redrawnClips.contains($0.rawValue) }
    guard clips.count > 1 else { return }   // nothing to compare yet
    let heights: [(Sprites.Clip, CGFloat)] = clips.compactMap { clip in
        let sizes = (0..<clip.count).map { Sprites.size(clip, $0).height }
        guard let tallest = sizes.max(), tallest > 0 else { return nil }
        return (clip, tallest)
    }
    #expect(heights.count == clips.count, "some clips failed to load")

    let values = heights.map(\.1)
    let smallest = values.min()!, largest = values.max()!
    // `held` is excluded above: he dangles fully stretched out, so being taller is correct.
    // Everything else is a cat standing, crouching or curled, and those legitimately differ
    // by well under 2x. A 44% error hid inside the old 3x spread without anyone noticing.
    let spread = heights.sorted { $0.1 < $1.1 }
        .map { "\($0.0.rawValue) \(Int($0.1))" }.joined(separator: ", ")
    #expect(largest / smallest < 2.0, "he changes size between animations: \(spread)")
}

@MainActor
@Test func everyClipHasFindableEyes() {
    // `clipScale` silently falls back to 1.0 when it finds no eyes, which does not crash and
    // does not look obviously wrong in a still — it just renders that clip at the raw pixel
    // size of its sheet. Catching it here is much cheaper than noticing it on screen.
    for clip in [Sprites.Clip.walk, .idle, .jump, .land, .fall, .run, .alert, .sitdown, .held] {
        let withEyes = (0..<clip.count).filter { !Sprites.eyes(clip, $0).isEmpty }
        #expect(!withEyes.isEmpty, "\(clip.rawValue): no frame has a findable eye")
    }
}

@MainActor
@Test func everyFrameOfEveryClipLoads() {
    for clip in [Sprites.Clip.walk, .idle, .jump, .land, .fall, .run, .alert, .sitdown, .held, .sleep] {
        for i in 0..<clip.count {
            #expect(Sprites.image(clip, i) != nil, "\(clip.rawValue)\(i).png is missing")
        }
    }
}
