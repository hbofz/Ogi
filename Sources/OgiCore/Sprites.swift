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
            case .walk: 8
            case .jump, .run: 6
            case .idle, .land, .fall, .sitdown, .sleep: 4
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
        case .airborne, .righting:  return .jump
        case .slip:                 return .fall
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
    /// Most sheets were drawn with a ground line, so the bottom of the band IS the floor.
    /// Two were not: he is mid-air in `fall`, and in `held` he hangs from a hand that has
    /// been erased, so anchoring those at the bottom would hang him by the tail.
    static func footAnchor(_ clip: Clip) -> CGFloat {
        switch clip {
        case .held: return 0.86     // gripped by the scruff, near the top
        case .fall: return 0.30     // mid-air, no ground in the sheet
        default:    return 0
        }
    }

    /// Where his eyes are in a given frame, in unit coordinates (0..1 from the bottom-left
    /// of the sprite), so the renderer can put a live pupil inside the drawn eye.
    ///
    /// Found rather than authored: he is a black cat, so the only near-white pixels in any
    /// frame ARE his eyes. That means this keeps working for frames nobody has annotated,
    /// including any new sheet dropped in later.
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

        var seen = [Bool](repeating: false, count: w * h)
        func isWhite(_ i: Int) -> Bool {
            px[i * 4 + 3] > 128 && px[i * 4] > 200 && px[i * 4 + 1] > 200 && px[i * 4 + 2] > 200
        }

        var found: [CGRect] = []
        for start in 0..<(w * h) where !seen[start] && isWhite(start) {
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
                    if !seen[j] && isWhite(j) { seen[j] = true; stack.append(j) }
                }
            }
            // Whiskers and highlights are thin; an eye is a chunky blob.
            guard count > 12, maxX - minX > 2, maxY - minY > 2 else { continue }
            // His paws and chest have white in them too, and they were being drawn as
            // extra eyes on his leg. Eyes live in the head, which is always in the upper
            // half of the frame — including when he is upside down mid-fall, because the
            // frames are drawn head-up.
            guard (minY + maxY) / 2 < h / 2 else { continue }
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
    static func clipScale(_ clip: Clip) -> CGFloat {
        if let s = scaleCache[clip.rawValue] { return s }
        var scale: CGFloat = 1
        // Search for a frame with a visible eye; sleeping frames have them closed.
        for i in 0..<clip.count {
            guard let img = image(clip, i), let eye = eyes(clip, i).first else { continue }
            let widthPx = eye.width * CGFloat(img.width)
            guard widthPx > 2 else { continue }
            scale = Feel.Shape.referenceEyeWidth / widthPx
            break
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
