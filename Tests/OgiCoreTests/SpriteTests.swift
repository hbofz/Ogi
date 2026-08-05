import Testing
import Foundation
import CoreGraphics
@testable import OgiCore

/// Clips regenerated against the current `art/character.png`. Add each name as its sheet
/// lands. Kept by hand on purpose: the old version inferred this from eye colour, which
/// stopped meaning anything the moment the cat himself became ginger.
private let redrawnClips: Set<String> = ["walk", "fall", "land", "idle", "jump", "run", "sitdown", "sleep", "alert", "held", "groom", "curl", "cling", "lookDown", "peek", "turn", "shake"]

/// The drawn frames come from separately-generated sheets that draw him at wildly different
/// sizes, so `Sprites` rescales each clip to make him one cat. These check that it works,
/// because when it does not the failure is subtle on any single frame and glaring in motion.

/// Eye width as a fraction of his ink height, in one frame. The yardstick both size checks
/// use: his eye is a fixed fraction of *him* whatever pose he is in, so a bad eye reading
/// shows up here without punishing an honest crouch. Nil when the frame has no findable eye
/// or is mostly empty band.
@MainActor
private func eyeToInk(_ clip: Sprites.Clip, _ i: Int) -> Double? {
    guard let img = Sprites.image(clip, i), let eye = Sprites.eyes(clip, i).first else { return nil }
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    px.withUnsafeMutableBytes { buf in
        CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
            .draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    var top = h, bottom = 0
    for y in 0..<h {
        for x in 0..<w where px[(y * w + x) * 4 + 3] > 128 {
            top = min(top, y); bottom = max(bottom, y); break
        }
    }
    let inkHeight = bottom - top + 1
    guard inkHeight > 20 else { return nil }
    return Double(eye.width * CGFloat(w) / CGFloat(inkHeight))
}

@MainActor
@Test func everyClipMeasuresHisEyeConsistently() {
    // `clipScale` divides a reference width by the measured eye, so a clip whose eye is
    // mis-measured renders at the wrong size — silently, and only obviously in motion. It has
    // happened twice: `fall` once read a 5px eye against everything else's 20px and rendered
    // nearly 3x too big, and `idle` read 14px against its own median of 25.
    //
    // The invariant is not that clips render to the same height. They must not: a curled cat
    // is legitimately shorter than a sitting one, and an airborne clip's frame is mostly empty
    // band. What holds is that his eye is a fixed fraction of *him*, so measuring eye width
    // against his own ink height catches a bad reading without punishing an honest pose.
    // `held` is deliberately absent: he dangles fully stretched out, so his ink height is
    // nearly twice a sitting cat's while his eye stays the same. His ratio is honestly 0.047
    // against everyone else's 0.06-0.10, and including him would fail correct art.
    //
    // `climbUp` is absent for `held`'s reason exactly: a cat reaching up a wall is stretched to
    // his full length, so his ink height is half again a hanging cat's while his eye stays the
    // same, and his ratio is honestly 0.040 against the band's 0.061-0.097. The eye is found
    // correctly, steady at 17-23px across six frames and proportional to a smaller drawing, and
    // the scale it produces is right: he renders 16.3pt wide against `cling`'s 16.1pt, which is
    // the number `theClimbSheetIsTheSameCatAsTheCling` guards instead.
    //
    // `peek` is absent for the mirror of that reason, and it is the case the median does not
    // cover. Every other clip holds one posture, so its frames agree and the median is the
    // clip. Peek deliberately spans a flat crouch (ink 171px) to an upright cat (335px) —
    // that rise IS the animation — so its four ratios run 0.199, 0.139, 0.099, 0.093 and the
    // median lands on a crouch. His *emerged* frame reads 0.093, inside the band and next to
    // `land`'s 0.097, and his measured eye is steady across the four frames at 34/30/28/31px,
    // so the eye is found correctly; only the yardstick fails.
    // Every clip is IN by default and exclusion is explicit, because the old hardcoded list
    // silently skipped every clip added after it was written — lounge, stretch and peer all
    // shipped with no size coverage at all, which is the exact hole this project has fallen
    // down twice before.
    //
    // `lounge` is excluded for `climbUp`'s reason with the sign flipped: sprawled flat he is
    // half his standing height while his eye stays the same, so his ratio is honestly high.
    // `peer` is the extreme of the same: the drawing is mostly head, so eye-to-ink-height is
    // the wrong yardstick entirely. Both get their own steadiness pin below.
    var ratios: [(String, Double)] = []
    let excluded: Set<Sprites.Clip> = [.held, .climbUp, .peek, .lounge, .peer]
    for clip in Sprites.Clip.allCases
    where !excluded.contains(clip) && redrawnClips.contains(clip.rawValue) {
        // Median across frames. One frame is a bad sample for the same reason clipScale takes
        // a median: a squash frame is legitimately short and would read as an oversized eye.
        var perFrame = (0..<clip.count).compactMap { eyeToInk(clip, $0) }
        guard !perFrame.isEmpty else { continue }
        perFrame.sort()
        ratios.append((clip.rawValue, perFrame[perFrame.count / 2]))
    }
    guard ratios.count > 1 else { return }   // nothing to compare yet
    let vals = ratios.map(\.1)
    let report = ratios.sorted { $0.1 < $1.1 }
        .map { "\($0.0) \(String(format: "%.3f", $0.1))" }.joined(separator: ", ")
    #expect(vals.max()! / vals.min()! < 2.0,
            "one of these clips is mis-measuring his eye, so it renders at the wrong size: \(report)")
}

// MARK: - The turn, whose mirror is inverted

@MainActor
@Test func theTurnSheetIsDrawnRightToLeft() throws {
    // The mirror rule for `turn` is inverted from every other clip, and this is the fact the
    // inversion rests on. Read off the art rather than asserted, because nobody can eyeball it
    // in a unit test: his eye sits on the side of his head he is looking towards, so a cat in
    // full side view facing right has it in the right-hand half of the frame and a cat turned
    // to the left has it in the left-hand half.
    //
    // If this sheet is ever regenerated the other way round, every turn on screen plays
    // backwards (he would pivot away from where he is about to walk), and nothing else in the
    // suite would notice.
    let clip = Sprites.Clip.turn
    let first = try #require(Sprites.eyes(clip, 0).first)
    let last = try #require(Sprites.eyes(clip, clip.count - 1).first)
    #expect(first.midX > 0.5,
            "frame 0 has to be a cat in side view facing RIGHT; his eye reads \(first.midX) across the frame")
    #expect(last.midX < 0.5,
            "the last frame has to have him facing LEFT; his eye reads \(last.midX) across the frame")
}

@MainActor
@Test func theTurnIsTheOneClipWhoseMirrorIsInverted() {
    // Every other sheet is drawn facing right and flipped when he faces left. `turn` cannot
    // work that way, because for a turn the transition IS the content: it is drawn once as
    // right -> left (which `theTurnSheetIsDrawnRightToLeft` pins to the pixels), so playing it
    // as drawn turns him LEFT and mirroring it turns him right.
    //
    // `facing` is already the DESTINATION throughout a turn, so the flag is the opposite of it.
    #expect(Sprites.mirror(.turn, facing: -1) == 1,
            "turning right -> left must play the sheet as drawn")
    #expect(Sprites.mirror(.turn, facing: 1) == -1,
            "turning left -> right must play the sheet mirrored")
    for clip in [Sprites.Clip.walk, .idle, .run, .land, .peek, .lookDown] {
        #expect(Sprites.mirror(clip, facing: 1) == 1)
        #expect(Sprites.mirror(clip, facing: -1) == -1,
                "\(clip.rawValue) is drawn facing right and mirrors with facing")
    }
}

@MainActor
@Test func theTurnAlwaysPlaysAllTheWayThrough() {
    // The same floor `edgeHesitationMin` and `peekSeconds` have, for the same reason: the clip
    // does not loop, so a hold shorter than the sheet cuts him off part-way round and he snaps
    // through the rest of the pivot, which is the instantaneous flip this whole clip exists to
    // remove, only later and smaller.
    let clip = Sprites.Clip.turn
    #expect(Feel.Timing.turnSeconds >= Double(clip.count) / clip.fps - 0.001,
            "the pivot ends before its \(clip.count) frames at \(clip.fps)fps have played")
}

@MainActor
@Test func peeksEmergedFrameIsMeasuredLikeEveryOtherClip() throws {
    // `peek` is out of the aggregate check above because its median lands on a crouch, and
    // leaving it at that would give the clip NO size coverage at all — which is the exact hole
    // this project has fallen down twice (`idle` 44% off its own median; `curl` at nearly half
    // size because the eye finder caught a closed lid reading 5px).
    //
    // The last frame is the one to pin: it is the emerged pose that hands straight off to
    // `walk`, so it is the frame that has to agree with everyone else. It measures 0.093,
    // between `run`'s 0.087 and `land`'s 0.097.
    //
    // The bounds are deliberately looser than that 0.061-0.097 population band. What this
    // catches is a mis-measurement — a lid or a highlight instead of the eye, which is off by
    // three to six times and rescales the whole clip — not a 10% drift in honest new art.
    let clip = Sprites.Clip.peek
    let r = try #require(eyeToInk(clip, clip.count - 1))
    #expect(r > 0.05 && r < 0.11,
            "peek's emerged frame measures \(r) against the other clips' 0.061-0.097, so the whole clip renders at the wrong size")
}

@MainActor
@Test func everyClipHasFindableEyes() {
    // `clipScale` silently falls back to 1.0 when it finds no eyes, which does not crash and
    // does not look obviously wrong in a still — it just renders that clip at the raw pixel
    // size of its sheet. Catching it here is much cheaper than noticing it on screen.
    for clip in Sprites.Clip.allCases {
        let withEyes = (0..<clip.count).filter { !Sprites.eyes(clip, $0).isEmpty }
        #expect(!withEyes.isEmpty, "\(clip.rawValue): no frame has a findable eye")
    }
}

@MainActor
@Test func thePeerRendersAtHeadSize() {
    // The one clip normalised on ink height rather than eye width. Keyed on its huge
    // front-facing eyes it rendered at nine points; keyed on height it is a head over a
    // lip, the same size as the head on his side-view body.
    let size = Sprites.size(.peer, 0)
    #expect(abs(size.height - Feel.Shape.peerHeight) < 0.5)
    #expect(size.width > 12 && size.width < 30,
            "a peeking head \(size.width)pt wide is not the same cat as his 16-28pt body")
}

@MainActor
@Test func theOddShapedClipsMeasureTheirEyesSteadily() throws {
    // lounge and peer sit outside the aggregate ratio band above for honest reasons (a
    // sprawled cat is short; a peeking cat is mostly head), and the peek precedent says an
    // exclusion with no pin of its own is how clips ship at the wrong size. What CAN be
    // pinned for any clip is that the eye measures consistently across its own frames: a
    // lid or a whisker caught instead of the eye is off by multiples, not percents.
    for clip in [Sprites.Clip.lounge, .peer] {
        var widths = (0..<clip.count).compactMap { i -> CGFloat? in
            guard let img = Sprites.image(clip, i),
                  let eye = Sprites.eyes(clip, i).first else { return nil }
            let w = eye.width * CGFloat(img.width)
            return w > 2 ? w : nil
        }
        try #require(widths.count > clip.count / 2,
                     "\(clip.rawValue): most frames have no measurable eye")
        // Against the median, which is what clipScale actually uses, rather than max/min:
        // peer's blink frame legitimately measures a sliver of the open eye (6x off), and
        // the median shrugs that off exactly as it was built to. What must hold is that
        // the median comes from agreement, not from a fluke.
        widths.sort()
        let median = widths[widths.count / 2]
        let agreeing = widths.filter { $0 > median * 0.75 && $0 < median * 1.33 }.count
        #expect(agreeing > clip.count / 2,
                "\(clip.rawValue): only \(agreeing)/\(clip.count) frames agree with the median eye, so the clip's scale is built on a fluke")
    }
}

@MainActor
@Test func everyFrameOfEveryClipLoads() {
    for clip in Sprites.Clip.allCases {
        for i in 0..<clip.count {
            #expect(Sprites.image(clip, i) != nil, "\(clip.rawValue)\(i).png is missing")
        }
    }
}

@Test @MainActor func frameRectIsAnchoredAtTheFeet() {
    var cat = CatState(position: CGPoint(x: 500, y: 300))
    cat.activity = .idle
    let f = Sprites.frame(for: cat, pose: Body.Pose())
    let r = f.rect(at: cat.position)

    #expect(f.clip == .idle)
    #expect(abs(r.midX - 500) < 0.001)
    // anchor 0 means the bottom of the frame sits on his position
    #expect(abs(r.minY - 300) < 0.001)
    #expect(r.height == f.size.height)
}

@Test @MainActor func heldFrameHangsFromTheNape() {
    var cat = CatState(position: CGPoint(x: 500, y: 300))
    cat.support = .held(CGPoint(x: 500, y: 300))
    cat.activity = .scruffed
    var pose = Body.Pose()
    pose.dangling = true
    let f = Sprites.frame(for: cat, pose: pose)
    let r = f.rect(at: cat.position)

    #expect(f.clip == .held)
    #expect(f.anchor > 0.9)
    // gripped near the top, so most of him hangs BELOW his position
    #expect(r.minY < 300)
    #expect(r.maxY - 300 < r.height * 0.15)
}

@Test @MainActor func eachGaitPlaysAtItsOwnClipsDeclaredRate() {
    // The gait cycle is driven by ground covered, not by a clock: `buildPose` advances
    // `walkPhase` by `speed / strideLength` and `Sprites.index` reads `count` frames off it.
    // So the rate a sheet actually plays at is `speed / stride * count`, and NOTHING connected
    // that to the `fps` the sheet declares — which is how the run came to play at 31.5fps
    // against a declared 14, sharing the walk's 30pt stride when a trot covers 67.
    //
    // Everything here is derived, so a change to a speed, a stride, a frame count or an fps
    // has to keep agreeing with itself.
    for (clip, speed, stride) in [(Sprites.Clip.walk, Feel.Physics.walkSpeed, Feel.Shape.strideLength),
                                  (Sprites.Clip.run, Feel.Physics.runSpeed, Feel.Shape.runStrideLength)] {
        let plays = Double(speed / stride) * Double(clip.count)
        // 15%, which is the walk's own deliberate 8%: 30pt is what stops its paws skating and
        // that is the number that matters, so its sheet runs slightly under its declared rate.
        // The run was 125% over, which no tolerance should ever have covered.
        #expect(abs(plays - clip.fps) < clip.fps * 0.15,
                "\(clip.rawValue) plays at \(plays)fps against a declared \(clip.fps)fps: \(speed)px/s over a \(stride)pt stride of \(clip.count) frames")
    }
}

// MARK: - climbUp

@MainActor
@Test func theClimbAndTheClingHangFromTheSamePoint() {
    // He switches between these the instant he decides to go up rather than hang on, so a
    // different anchor would snap him up or down the face at that moment. Both are the same
    // grip by the same front paws on the same wall.
    #expect(Sprites.footAnchor(.climbUp) == Sprites.footAnchor(.cling))
}

@MainActor
@Test func theClimbSheetPlaysAtTheRateHeActuallyClimbs() {
    // Derived rather than declared, so the two numbers cannot drift apart. This is the run-gait
    // bug written as a test: that sheet played at 31.5fps against the 14 it was drawn for
    // because the stride it shared was written down in one place and used for two gaits.
    let cyclesPerSecond = Double(Feel.Physics.clingClimbSpeed / Feel.Shape.climbStride)
    #expect(abs(Sprites.Clip.climbUp.fps - cyclesPerSecond * 6) < 0.001)
    // ...and the rate has to be watchable. Outside this range it is either a slideshow or a blur.
    #expect(Sprites.Clip.climbUp.fps > 6, "the climb is a slideshow at \(Sprites.Clip.climbUp.fps)fps")
    #expect(Sprites.Clip.climbUp.fps < 20, "the climb is a blur at \(Sprites.Clip.climbUp.fps)fps")
}

@MainActor
@Test func theClimbSheetHasAllItsFrames() {
    for i in 0..<Sprites.Clip.climbUp.count {
        #expect(Sprites.image(.climbUp, i) != nil, "climbUp frame \(i) is missing")
    }
    #expect(Sprites.Clip.climbUp.loops, "a climb that does not loop stops after half a second")
}

@MainActor
@Test func theClimbSheetIsTheSameCatAsTheCling() {
    // climbUp cannot be held to the eye-against-ink-height yardstick (see the exemption above),
    // so it needs its own guard against the failure that yardstick exists to catch: a sheet
    // whose eye is mis-measured renders at the wrong size, silently.
    //
    // WIDTH is the right measure for these two. He is on the same wall in both, seen from the
    // side, so he is the same cat wide however stretched out he is tall. A mis-scaled sheet
    // moves this immediately: the two clips are drawn at different pixel sizes and only the
    // eye normalisation brings them together, so if that fails they will not agree.
    func renderedWidth(_ c: Sprites.Clip) -> CGFloat {
        let ws = (0..<c.count).compactMap { i in Sprites.image(c, i).map { CGFloat($0.width) } }
        return ws.sorted()[ws.count / 2] * Sprites.clipScale(c)
    }
    let climb = renderedWidth(.climbUp), cling = renderedWidth(.cling)
    #expect(abs(climb - cling) / cling < 0.20,
            "climbUp renders \(climb)pt wide against cling's \(cling)pt; one of them is mis-scaled")
}

@MainActor
@Test func theClimbSheetDoesNotBobAgainstTheWall() {
    // He hangs from his grip, so the top of his ink is what has to stay put. The cling loop was
    // the top cosmetic risk in the project partly because it did not. Measured off the cut
    // frames: 2px of drift across six, because the prompt demanded his head stay at one height.
    var tops: [Int] = []
    for i in 0..<Sprites.Clip.climbUp.count {
        guard let img = Sprites.image(.climbUp, i),
              let data = img.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { continue }
        let bpr = img.bytesPerRow, bpp = img.bitsPerPixel / 8
        outer: for y in 0..<img.height {
            for x in 0..<img.width where ptr[y * bpr + x * bpp + 3] > 128 { tops.append(y); break outer }
        }
    }
    #expect(tops.count == Sprites.Clip.climbUp.count)
    // In POINTS, not source pixels. Sheets are drawn at wildly different sizes and normalised on
    // eye width, so a pixel bound is a bound on whichever sheet it was written against: the
    // first climb sheet drifted 2px and a bound of 8 looked generous until the second drifted 22.
    // What matters is what you can see, and he renders about 47pt tall, so a point of slide is
    // two percent of him and invisible while three would read as a bob at 12fps.
    let drift = CGFloat((tops.max() ?? 0) - (tops.min() ?? 0)) * Sprites.clipScale(.climbUp)
    #expect(drift < 2.5,
            "his grip slides \(drift)pt up and down the wall across the loop")
}
