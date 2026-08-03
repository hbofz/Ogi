import Testing
import CoreGraphics
@testable import OgiCore

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
        .filter(Sprites.isCurrentArt)
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
@Test func theArtMigrationIsWhereWeThinkItIs() {
    // everyClipRendersHimTheSameSize only covers regenerated clips, so if this drifted to
    // "none of them" that test would pass by checking nothing. Update the list as sheets land.
    let redrawn: Set<String> = ["walk"]
    for clip in [Sprites.Clip.walk, .idle, .jump, .land, .fall, .run, .alert, .sitdown, .held, .sleep] {
        #expect(Sprites.isCurrentArt(clip) == redrawn.contains(clip.rawValue),
                "\(clip.rawValue): regenerated-art detection disagrees with the list above")
    }
}

@MainActor
@Test func noFrameRendersWithAnOrangeEye() {
    // The sheets are drawn with amber eyes and Sprites strips the hue on load. This checks the
    // result rather than the rule, so a future sheet whose amber sits outside the expected
    // range fails here instead of shipping one orange-eyed animation among nine white ones.
    for clip in [Sprites.Clip.walk, .idle, .jump, .land, .fall, .run, .alert, .sitdown, .held, .sleep] {
        for i in 0..<clip.count {
            guard let img = Sprites.image(clip, i) else { continue }
            let w = img.width, h = img.height
            var px = [UInt8](repeating: 0, count: w * h * 4)
            px.withUnsafeMutableBytes { buf in
                CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                    .draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            let orange = (0..<(w * h)).filter {
                px[$0 * 4 + 3] > 128 && px[$0 * 4] > 180
                    && Int(px[$0 * 4]) > Int(px[$0 * 4 + 2]) + 60 && px[$0 * 4] > px[$0 * 4 + 1]
            }
            #expect(orange.isEmpty, "\(clip.rawValue)\(i): \(orange.count) orange px survived")
        }
    }
}

@MainActor
@Test func redrawnClipsHaveABrightSocketToPaintAPupilInto() {
    // Recolouring must leave the socket bright enough for eyes() to find, or the pupil has
    // nowhere to go and clipScale loses its reference at the same time.
    for clip in [Sprites.Clip.walk, .idle, .jump, .land, .fall, .run, .alert, .sitdown, .held, .sleep]
    where Sprites.isCurrentArt(clip) {
        let framesWithEyes = (0..<clip.count).filter { !Sprites.eyes(clip, $0).isEmpty }
        #expect(framesWithEyes.count == clip.count,
                "\(clip.rawValue): only \(framesWithEyes.count)/\(clip.count) frames kept a findable eye")
    }
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
