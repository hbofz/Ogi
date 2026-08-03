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
            case .walk: 9
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
        let out = whitenEyes(cg, key: name)
        cache[name] = out
        return out
    }

    /// Which sheets were drawn to `docs/ART-BRIEF.md`, keyed by frame. Set during load,
    /// because having an orange eye to strip is exactly what identifies them.
    private static var redrawn: [String: Bool] = [:]

    /// His eyes are drawn amber, and amber is not what he looks like.
    ///
    /// Rather than repaint ten sheets, the hue is stripped once at load: every orange pixel
    /// becomes a neutral of its own brightness, so the socket keeps its hand-drawn outline
    /// and its internal shading and loses only the colour. Stamping a white ellipse over the
    /// top instead is the approach that was already tried and removed, because a drawn-on
    /// ellipse never matches a hand-drawn shape.
    private static func whitenEyes(_ img: CGImage, key: String) -> CGImage {
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        // Orange: red clearly leads blue and the channels descend. His warm ear pink and his
        // grey whiskers both fail the first test, so on a redrawn sheet this finds only the
        // eye — including the amber's darker rim, which has to shade down with the rest or it
        // is left behind as an orange outline around a white eye.
        func isOrange(_ i: Int) -> Bool {
            px[i * 4 + 3] > 128 && Int(px[i * 4]) > Int(px[i * 4 + 2]) + 60
                && px[i * 4] > px[i * 4 + 1] && px[i * 4 + 1] > px[i * 4 + 2]
        }
        // Decide per frame before touching anything, because "orange" alone is not specific
        // enough: the `held` sheet was drawn with a human hand holding him, and the skin left
        // behind after DROP_WARM is orange too. Skin is dark (r≈116) and an amber eye is not
        // (r≈250), so requiring real brightness separates them — and gating the whole frame on
        // it means a sheet with no eye to recolour is passed through completely untouched.
        let hasAmberEye = (0..<(w * h)).contains { isOrange($0) && px[$0 * 4] > 180 }
        redrawn[key] = hasAmberEye
        guard hasAmberEye else { return img }
        for i in 0..<(w * h) where isOrange(i) {
            px[i * 4 + 1] = px[i * 4]; px[i * 4 + 2] = px[i * 4]
        }
        let recoloured = px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        return recoloured ?? img
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
    /// Found rather than authored: he is a black cat, so the only bright pixels in any frame
    /// ARE his eyes. That means this keeps working for frames nobody has annotated, including
    /// any new sheet dropped in later.
    ///
    /// Two palettes, because the sheets were not all drawn at once: the original cat has white
    /// eyes and everything generated against `docs/ART-BRIEF.md` has amber ones. Matching both
    /// is what lets a new sheet drop in beside the old ones instead of replacing all ten at
    /// once — and it is load-bearing, not cosmetic. `clipScale` normalises every animation on
    /// eye width, so a clip whose eyes are not found silently renders at the wrong size.
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
        // One test for both palettes: `image` has already stripped the hue out of an amber
        // socket, so by the time this runs every eye in every sheet is a bright neutral blob.
        func isEye(_ i: Int) -> Bool {
            px[i * 4 + 3] > 128 && px[i * 4] > 200 && px[i * 4 + 1] > 200 && px[i * 4 + 2] > 200
        }

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
            // On the white-eyed sheets his paws and chest have white in them too, and they
            // were being drawn as extra eyes on his leg. Eyes live in the head, which is in
            // the upper half of the frame — including when he is upside down mid-fall,
            // because the frames are drawn head-up.
            //
            // This is a workaround for one palette, so it is scoped to that palette. The
            // redrawn sheets have nothing white on them except the eye, so they need no
            // positional test — and must not get one, because it is only ever approximately
            // true. A leaping cat's head is not in the top half of his own bounding box (his
            // arched back and tail are above it), so any tighter version of this guard throws
            // away the real eyes on `jump`.
            guard redrawn[key] == true || (minY + maxY) / 2 < h / 2 else { continue }
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

    /// Whether this clip was drawn to `docs/ART-BRIEF.md`, identified by the amber eye that
    /// `whitenEyes` stripped out of it on the way in.
    ///
    /// The brief specifies a flat featureless socket, so these clips have an empty eye the
    /// renderer can paint a live cursor-tracking pupil into. The older sheets have a pupil
    /// painted in already; drawing a second one on top of that is exactly what got cursor
    /// tracking switched off once, so those clips keep their drawn eyes until redrawn.
    public static func isCurrentArt(_ clip: Clip) -> Bool {
        for i in 0..<clip.count {
            let key = "\(clip.rawValue)\(i)"
            _ = image(clip, i)                       // populates `redrawn` as a side effect
            if redrawn[key] == true { return true }
        }
        return false
    }

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
