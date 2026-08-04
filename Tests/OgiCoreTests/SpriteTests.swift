import Testing
import CoreGraphics
@testable import OgiCore

/// Clips regenerated against the current `art/character.png`. Add each name as its sheet
/// lands. Kept by hand on purpose: the old version inferred this from eye colour, which
/// stopped meaning anything the moment the cat himself became ginger.
private let redrawnClips: Set<String> = ["walk", "fall", "land", "idle", "jump", "run", "sitdown", "sleep", "alert", "held", "groom", "curl", "cling", "lookDown", "peek"]

/// The drawn frames come from separately-generated sheets that draw him at wildly different
/// sizes, so `Sprites` rescales each clip to make him one cat. These check that it works,
/// because when it does not the failure is subtle on any single frame and glaring in motion.

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
    // `peek` is absent for the mirror of that reason, and it is the case the median does not
    // cover. Every other clip holds one posture, so its frames agree and the median is the
    // clip. Peek deliberately spans a flat crouch (ink 171px) to an upright cat (335px) —
    // that rise IS the animation — so its four ratios run 0.199, 0.139, 0.099, 0.093 and the
    // median lands on a crouch. His *emerged* frame reads 0.093, inside the band and next to
    // `land`'s 0.097, and his measured eye is steady across the four frames at 34/30/28/31px,
    // so the eye is found correctly; only the yardstick fails.
    var ratios: [(String, Double)] = []
    for clip in [Sprites.Clip.walk, .idle, .jump, .land, .fall, .run, .alert, .sitdown, .sleep, .groom, .curl, .cling, .lookDown]
    where redrawnClips.contains(clip.rawValue) {
        // Median across frames. One frame is a bad sample for the same reason clipScale takes
        // a median: a squash frame is legitimately short and would read as an oversized eye.
        var perFrame: [Double] = []
        for i in 0..<clip.count {
            guard let img = Sprites.image(clip, i), let eye = Sprites.eyes(clip, i).first else { continue }
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
            guard inkHeight > 20 else { continue }
            perFrame.append(Double(eye.width * CGFloat(w) / CGFloat(inkHeight)))
        }
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

@MainActor
@Test func everyClipHasFindableEyes() {
    // `clipScale` silently falls back to 1.0 when it finds no eyes, which does not crash and
    // does not look obviously wrong in a still — it just renders that clip at the raw pixel
    // size of its sheet. Catching it here is much cheaper than noticing it on screen.
    for clip in [Sprites.Clip.walk, .idle, .jump, .land, .fall, .run, .alert, .sitdown, .held, .cling, .lookDown, .peek] {
        let withEyes = (0..<clip.count).filter { !Sprites.eyes(clip, $0).isEmpty }
        #expect(!withEyes.isEmpty, "\(clip.rawValue): no frame has a findable eye")
    }
}

@MainActor
@Test func everyFrameOfEveryClipLoads() {
    for clip in [Sprites.Clip.walk, .idle, .jump, .land, .fall, .run, .alert, .sitdown, .held, .sleep, .cling, .lookDown, .peek] {
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
