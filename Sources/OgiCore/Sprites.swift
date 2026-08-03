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
    public static func clip(for activity: Activity, dangling: Bool) -> Clip {
        if dangling { return .held }
        switch activity {
        case .walk:                 return .walk
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

    /// Aspect-correct size. Frames within a clip already share a vertical band, so this keeps
    /// him a consistent height across an animation.
    public static func size(_ clip: Clip, _ index: Int) -> CGSize {
        guard let img = image(clip, index) else {
            return CGSize(width: Feel.Shape.width, height: Feel.Shape.height)
        }
        let s = Feel.Shape.spriteScale
        return CGSize(width: CGFloat(img.width) * s, height: CGFloat(img.height) * s)
    }
}
#endif
