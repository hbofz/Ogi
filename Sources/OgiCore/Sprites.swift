#if canImport(AppKit)
import AppKit

/// The drawn cat: 45 frames across ten animations.
///
/// Ogi was procedural first — one filled path assembled from a torso, a skull, four legs and
/// a simulated tail. It worked, it animated, and it did not look good enough. The silhouette
/// read as *a* cat rather than as *this* cat, and charm is the entire product.
///
/// Physics, terrain, occlusion, squash and facing are untouched. They were never coupled to
/// how he was drawn, which is why swapping the renderer was a small change rather than a
/// rewrite.
///
/// **Every frame in an animation shares one vertical band**, aligned on the source sheet's own
/// ground line, rather than being cropped tight to its own ink. That is what preserves the air
/// in a jump: crop each frame individually and an airborne cat gets re-planted on the ground,
/// so a crouch and a leap render at exactly the same height. See `Tools/extract-sprites.swift`.
@MainActor
public enum Sprites {

    /// Ordered frames per animation. Names match the files in Resources/Sprites.
    public enum Clip: String {
        case walk, idle, jump, land, fall, run, alert, sitdown, held, sleep

        var count: Int {
            switch self {
            case .walk: 6
            case .jump, .run: 6
            case .fall: 6
            case .land: 3
            case .sitdown: 5
            case .idle, .sleep: 4
            case .held: 3
            case .alert: 2
            }
        }

        /// Frames per second. Deliberately low: a slightly-lower framerate reads as
        /// handmade, while 60fps sprite motion reads as a screensaver.
        var fps: Double {
            switch self {
            case .walk: 10
            case .run: 14
            case .land: 14      // impacts are quick
            case .fall: 12
            case .jump: 12
            case .idle, .sleep: 2.5   // breathing, not action
            case .sitdown: 8
            case .held: 3
            case .alert: 1.2
            }
        }

        var loops: Bool {
            switch self {
            case .walk, .run, .idle, .sleep, .held, .alert: true
            case .jump, .land, .fall, .sitdown: false
            }
        }
    }

    // Everything in this app runs on the main actor, so a plain cache needs no lock.
    private static var cache: [String: CGImage] = [:]

    public static func image(_ clip: Clip, _ index: Int) -> CGImage? {
        let name = "\(clip.rawValue)\(min(max(index, 0), clip.count - 1))"
        if let c = cache[name] { return c }
        guard let url = Bundle.module.url(forResource: name, withExtension: "png",
                                          subdirectory: "Sprites")
                ?? Bundle.module.url(forResource: name, withExtension: "png"),
              let data = try? Data(contentsOf: url),
              let src = NSImage(data: data),
              let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        cache[name] = cg
        return cg
    }

    /// Which animation a given behaviour plays.
    public static func clip(for activity: Activity, dangling: Bool, hurrying: Bool = false) -> Clip {
        if dangling { return .held }
        switch activity {
        case .walk:                 return hurrying ? .run : .walk
        case .crouch:               return .jump      // the wind-up frames
        case .airborne:             return .jump
        // Both ways he leaves the ground without choosing to: his platform vanished, or you
        // dropped him. The fall sheet is the righting reflex, so it covers both.
        case .slip, .righting:      return .fall
        case .scruffed:             return .held
        case .land, .landHard:      return .land
        case .sit:                  return .sitdown
        case .curl, .sleep:         return .sleep
        case .alert, .brace:        return .alert
        case .idle:                 return .idle
        }
    }

    /// Where in the animation to be.
    ///
    /// Locomotion is driven by the gait phase so the paws do not skate; everything else runs
    /// off its own elapsed time. Non-looping clips hold their last frame.
    public static func index(_ clip: Clip, activity: Activity,
                             walkPhase: CGFloat, elapsed: TimeInterval) -> Int {
        switch clip {
        case .walk, .run:
            return Int(walkPhase * CGFloat(clip.count)) % clip.count
        case .jump where activity == .crouch:
            // Hold on the coiled frame for the whole 100ms wind-up.
            return 1
        case .jump:
            // Skip the wind-up frames; he is already in the air.
            let n = clip.count - 2
            return 2 + min(n - 1, Int(elapsed * clip.fps))
        default:
            let raw = Int(elapsed * clip.fps)
            return clip.loops ? raw % clip.count : min(raw, clip.count - 1)
        }
    }

    /// Where his feet are, as a fraction up from the bottom of the frame.
    ///
    /// Most sheets are drawn with a ground line, so the bottom of the band IS the floor. The
    /// exception is `held`, where he hangs from a hand that has been erased: anchoring him at
    /// the bottom would hang him by the tail.
    ///
    /// `fall` used to be listed here at 0.30, because on the old sheet he never reached the
    /// bottom of his band and anchoring at the floor left him hovering. The redrawn sheet ends
    /// on a frame braced for impact with his legs at full stretch, and those paws land exactly
    /// on the last row of the band — so the floor is the right anchor again, and the special
    /// case is gone. Measure this whenever an airborne clip is redrawn; it is a property of the
    /// sheet, not of the animation.
    static func footAnchor(_ clip: Clip) -> CGFloat {
        switch clip {
        case .held: return 0.86     // gripped by the scruff, near the top
        default:    return 0
        }
    }

    /// Where his eyes are in a given frame, in unit coordinates (0..1 from the bottom-left
    /// of the sprite).
    ///
    /// Found rather than authored, so it keeps working on any sheet dropped in later without
    /// anyone annotating it. This is load-bearing rather than cosmetic: `clipScale` normalises
    /// every animation on eye width, so a clip whose eyes are not found renders at the wrong
    /// size, and it does that silently.
    ///
    /// The eye is whatever stands furthest from the fur, and which direction that is depends on
    /// the cat. The original was black with white eyes, so his eyes were the brightest thing on
    /// him. The ginger tabby in `art/character.png` inverts it: he is a mid-value orange and his
    /// eyes are near-black, the darkest thing on him. Matching both is what lets the sheets be
    /// replaced one at a time instead of all ten at once.
    ///
    /// Which of the two applies is decided from the fur rather than configured, so a new sheet
    /// still needs no annotation.
    public static func eyes(_ clip: Clip, _ index: Int) -> [CGRect] {
        let key = "\(clip.rawValue)\(index)"
        if let e = eyeCache[key] { return e }
        guard let img = image(clip, index) else { return [] }
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }

        /// White eyes, as the black cat has.
        func isPale(_ i: Int) -> Bool {
            px[i * 4 + 3] > 128 && px[i * 4] > 200 && px[i * 4 + 1] > 200 && px[i * 4 + 2] > 200
        }
        /// Near-black eyes, as the ginger tabby has. Dark *and neutral*: his outline is dark
        /// too, but warm (r≈128 against g≈48), so requiring the red channel down with the rest
        /// keeps the outline out. His cream belly and paws stop short of `isPale` for the same
        /// kind of reason — their blue channel never reaches it.
        func isInky(_ i: Int) -> Bool {
            px[i * 4 + 3] > 128 && px[i * 4] < 80 && px[i * 4 + 1] < 80 && px[i * 4 + 2] < 90
        }

        var ink = 0, inky = 0
        for i in 0..<(w * h) where px[i * 4 + 3] > 128 {
            ink += 1
            if isInky(i) { inky += 1 }
        }

        // Which test finds the eye depends on the cat, so ask the fur. A black cat is almost
        // entirely inky (88% of his pixels), which means his eyes cannot be the dark ones; a
        // ginger tabby is barely inky at all, so his eyes are exactly the dark ones.
        //
        // This has to be a choice rather than the union of both tests. Matching either one in
        // a single flood fill merges a white eye into the black fur it sits against, and the
        // combined blob is then the whole animal: `walk`, `jump` and `sitdown` found no eyes
        // at all that way, and `held` found twenty.
        let eyesAreInky = inky * 2 < ink
        func isEye(_ i: Int) -> Bool { eyesAreInky ? isInky(i) : isPale(i) }

        var seen = [Bool](repeating: false, count: w * h)

        var found: [CGRect] = []
        for start in 0..<(w * h) where !seen[start] && isEye(start) {
            var minX = w, maxX = 0, minY = h, maxY = 0, count = 0
            var stack = [start]; seen[start] = true
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                count += 1
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                    let j = ny * w + nx
                    if !seen[j] && isEye(j) { seen[j] = true; stack.append(j) }
                }
            }
            // Whiskers and highlights are thin; an eye is a chunky blob.
            guard count > 12, maxX - minX > 2, maxY - minY > 2 else { continue }
            // An eye is a feature, not the animal. Without this the dark test would match the
            // whole of a black cat as one blob and hand back his entire silhouette as an eye,
            // which is both wrong and the largest thing on the frame, so it would win.
            guard count * 6 < ink else { continue }
            // On the white-eyed sheets his paws and chest have white in them too, and they
            // were being drawn as extra eyes on his leg. Eyes live in the head, which is in
            // the upper half of the frame — including when he is upside down mid-fall,
            // because the frames are drawn head-up.
            //
            // Scoped to that palette, because it is only ever approximately true and the dark
            // test does not need it: a leaping cat's head is not in the top half of his own
            // bounding box (his arched back and tail are above it), so any tighter version of
            // this guard throws away the real eyes on `jump`.
            guard eyesAreInky || (minY + maxY) / 2 < h / 2 else { continue }
            // CGImage y runs downward; the layer works bottom-up.
            found.append(CGRect(x: CGFloat(minX) / CGFloat(w),
                                y: 1 - CGFloat(maxY) / CGFloat(h),
                                width: CGFloat(maxX - minX + 1) / CGFloat(w),
                                height: CGFloat(maxY - minY + 1) / CGFloat(h)))
        }
        // Biggest first, so the near eye leads when a frame only shows part of the far one.
        found.sort { $0.width * $0.height > $1.width * $1.height }
        let result = Array(found.prefix(2))
        eyeCache[key] = result
        return result
    }

    private static var eyeCache: [String: [CGRect]] = [:]

    /// How much to scale a clip so he is the same size in all of them.
    ///
    /// The source sheets were generated separately and drew him at quite different sizes —
    /// the walk band is 158px tall and the sit band is 287px — so one global scale made him
    /// visibly shrink the moment he started walking.
    ///
    /// Normalised on **eye width**, because it is the one feature present and consistent in
    /// every frame regardless of pose: a crouching cat is legitimately shorter than a
    /// sitting one, so height cannot be the reference, but his eyes are always his eyes.
    ///
    /// Measured across every frame and taken as the **median**, not from the first frame that
    /// happens to have one. A single frame is a bad sample: his eye narrows when he turns his
    /// head and closes when he blinks, so one unlucky frame set the size of a whole animation.
    /// Reading frame 0 alone had `idle` 44% and `run` 42% off their own medians, which is him
    /// visibly changing size the moment he starts moving. The median ignores those outliers.
    static func clipScale(_ clip: Clip) -> CGFloat {
        if let s = scaleCache[clip.rawValue] { return s }
        var scale: CGFloat = 1
        var widths: [CGFloat] = []
        for i in 0..<clip.count {
            guard let img = image(clip, i), let eye = eyes(clip, i).first else { continue }
            let widthPx = eye.width * CGFloat(img.width)
            // Blinking and sleeping frames have them closed; a sliver is not a measurement.
            guard widthPx > 2 else { continue }
            widths.append(widthPx)
        }
        if !widths.isEmpty {
            widths.sort()
            scale = Feel.Shape.referenceEyeWidth / widths[widths.count / 2]
        }
        scaleCache[clip.rawValue] = scale
        return scale
    }

    private static var scaleCache: [String: CGFloat] = [:]

    /// Aspect-correct size. Frames within a clip already share a vertical band, so this keeps
    /// him a consistent height across an animation.
    public static func size(_ clip: Clip, _ index: Int) -> CGSize {
        guard let img = image(clip, index) else {
            return CGSize(width: Feel.Shape.width, height: Feel.Shape.height)
        }
        let s = Feel.Shape.spriteScale * clipScale(clip)
        return CGSize(width: CGFloat(img.width) * s, height: CGFloat(img.height) * s)
    }
}
#endif
