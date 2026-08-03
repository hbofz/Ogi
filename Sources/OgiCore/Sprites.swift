#if canImport(AppKit)
import AppKit

/// The drawn cat.
///
/// Ogi was procedural first — one filled path assembled from a torso, a skull, four IK-ish
/// legs and a simulated tail. It worked, it animated, and it did not look good enough. The
/// silhouette read as *a* cat rather than as *this* cat, and charm is the entire product.
///
/// So the body is now drawn frames, cut from a reference sheet. Physics, terrain, occlusion,
/// squash and facing are untouched: they were never coupled to how he was drawn, which is why
/// swapping the renderer was a small change rather than a rewrite.
///
/// The tail is still simulated for poses that need it, and the eyes are still procedural on
/// top — see `Sprites.eyeSockets`.
@MainActor
public enum Sprites {

    public enum Frame: String, CaseIterable {
        case idle, sit, alert, crouch, airborne, midair, land, curl, sleep, fall
        case walk0, walk1, walk2
    }

    // Everything in this app runs on the main actor, so a plain cache needs no lock.
    private static var cache: [Frame: CGImage] = [:]

    public static func image(_ f: Frame) -> CGImage? {
        if let c = cache[f] { return c }
        guard let url = Bundle.module.url(forResource: f.rawValue, withExtension: "png",
                                          subdirectory: "Sprites")
                ?? Bundle.module.url(forResource: f.rawValue, withExtension: "png"),
              let data = try? Data(contentsOf: url),
              let src = NSImage(data: data),
              let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        cache[f] = cg
        return cg
    }

    /// Which frame to show, given what he is doing.
    ///
    /// The walk cycle is three drawn frames sampled from the gait phase, deliberately at
    /// 8-10fps rather than the display rate: a slightly-lower framerate reads as handmade,
    /// while 60fps sprite motion reads as a screensaver.
    public static func frame(for activity: Activity, walkPhase: CGFloat,
                             airborne: Bool, dangling: Bool) -> Frame {
        if dangling { return .fall }
        switch activity {
        case .walk:
            let n = [Frame.walk0, .walk1, .walk2, .walk1]
            return n[Int(walkPhase * CGFloat(n.count)) % n.count]
        case .crouch:   return .crouch
        case .airborne: return .airborne
        case .slip:     return .fall
        case .righting: return .midair
        case .scruffed: return .fall
        case .land, .landHard: return .land
        case .sit:      return .sit
        case .curl:     return .curl
        case .sleep:    return .sleep
        case .alert:    return .alert
        case .brace:    return .alert
        case .idle:     return airborne ? .midair : .idle
        }
    }

    /// Aspect-correct size for a frame, scaled so every pose shares one ground plane.
    /// Sprites are cropped to their own ink, so their heights differ; scaling by height
    /// alone would make him grow and shrink as he changed pose.
    public static func size(_ f: Frame) -> CGSize {
        guard let img = image(f) else { return CGSize(width: Feel.Shape.width, height: Feel.Shape.height) }
        let scale = Feel.Shape.spriteScale
        return CGSize(width: CGFloat(img.width) * scale, height: CGFloat(img.height) * scale)
    }
}
#endif
