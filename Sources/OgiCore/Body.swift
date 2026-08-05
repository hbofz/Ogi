import Foundation
import CoreGraphics

/// What the renderer needs to know about this instant, plus the one procedural drawing that
/// survived the move to drawn frames: the contact shadow.
///
/// Ogi was procedural first — a silhouette assembled from a torso, a skull, four legs and a
/// simulated tail, drawn as one filled path. The drawn sheets replaced all of it, and the
/// dead machinery (the path assembly, the Verlet tail, the procedural eyes, the pose fields
/// only that machinery read) was deleted rather than left warm: it ran every frame feeding
/// layers whose paths were never set. Git history has it if a character-pack fallback ever
/// wants it back. `Gaze` survives separately, computed and tested, because the pupils are
/// scheduled to return for flagged moments.
public enum Body {

    /// The two pose inputs the sprite picker reads. Everything else about what is on screen
    /// comes from `CatState` itself.
    public struct Pose {
        /// 0..1 around the gait cycle. Distance-driven by `App.buildPose`, so paws do not
        /// skate.
        public var walkPhase: CGFloat = 0
        /// Hanging by the scruff: picks the `held` sheet whatever the activity says.
        public var dangling = false
        public init() {}
    }

    // MARK: - Shadow

    /// Contact shadow. Tightens and darkens on landing, softens and separates in the air.
    /// This sells "he is standing on that window" more than anything else in the app.
    public static func shadow(width: CGFloat, height h: CGFloat) -> CGPath {
        let rx = width * (0.30 + 0.006 * h)
        let ry = rx * 0.20
        return CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2),
                      transform: nil)
    }

    public static func shadowOpacity(height h: CGFloat) -> CGFloat {
        0.50 * exp(-h / 26.0)
    }
}
