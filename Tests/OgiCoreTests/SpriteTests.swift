import Testing
import CoreGraphics
@testable import OgiCore

/// Clips regenerated against the current `art/character.png`. Add each name as its sheet
/// lands. Kept by hand on purpose: the old version inferred this from eye colour, which
/// stopped meaning anything the moment the cat himself became ginger.
private let redrawnClips: Set<String> = ["walk", "fall", "land", "idle", "jump", "run", "sitdown", "sleep"]

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
    var ratios: [(String, Double)] = []
    for clip in [Sprites.Clip.walk, .idle, .jump, .land, .fall, .run, .alert, .sitdown, .sleep]
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
