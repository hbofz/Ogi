import Foundation
import CoreGraphics

/// Pose to `CGPath`. Knows nothing about windows, physics, or AppKit.
///
/// He is a solid near-black silhouette with two bright eyes and nothing else, which is why
/// this is drawn in code rather than loaded from sprite frames: with no interior detail,
/// the entire character *is* one filled path. Every hard part of procedural creature
/// animation — deformation, texture stretching, shading, joint seams, self-shadowing —
/// simply does not exist here.
///
/// Everything is authored facing **right** in body space: origin at his feet on his
/// midline, +y up. Facing left is a mirror at render time.
public enum Body {

    /// Everything the shape needs to know about what he is doing.
    public struct Pose {
        public var walkPhase: CGFloat = 0     // 0..1 around the gait cycle
        public var stride: CGFloat = 0        // 0 standing, 1 walking
        public var crouch: CGFloat = 0        // 0 standing, 1 fully wound up
        public var airborne = false
        /// Hanging by the scruff: legs tucked, body long and limp.
        public var dangling = false
        /// 0..1 through the mid-air twist.
        public var righting: CGFloat = 1
        public var tail: [CGPoint] = []       // body space, from base to tip
        public var earAngle: CGFloat = 0      // radians, positive = perked
        public init() {}
    }

    // Proportions, as fractions of the bounding box. A cat in side view is much longer
    // than it is tall, and getting that ratio wrong is what makes these things read as
    // bears or rats.
    private static var W: CGFloat { Feel.Shape.width }
    private static var H: CGFloat { Feel.Shape.height }

    public static func path(_ pose: Pose) -> CGPath {
        // Genuinely unioned into a single outline, not merely overlapping subpaths.
        //
        // Overlapping subpaths with .nonZero *fill* identically, so this looks unnecessary
        // until you stroke it: the rim light then draws every internal boundary too, and he
        // reads as a cat assembled out of parts rather than as one solid shape. The union
        // is what makes a silhouette a silhouette.
        var result = CGMutablePath()
        torso(into: result, pose)
        var out: CGPath = result

        for part in [headPath(pose), legsPath(pose), tailPath(pose)] {
            out = out.union(part, using: .winding)
        }
        result = CGMutablePath()
        result.addPath(out)
        return result
    }

    private static func headPath(_ pose: Pose) -> CGPath {
        let p = CGMutablePath(); head(into: p, pose); return p
    }
    private static func legsPath(_ pose: Pose) -> CGPath {
        let p = CGMutablePath(); legs(into: p, pose); return p
    }
    private static func tailPath(_ pose: Pose) -> CGPath {
        let p = CGMutablePath(); tail(into: p, pose); return p
    }

    // MARK: - Torso

    private static func torso(into p: CGMutablePath, _ pose: Pose) {
        // Crouching drops the chest and raises the rump: he coils before he goes.
        let drop = pose.crouch * H * 0.10
        let belly = H * 0.34 - drop * 0.4
        let back = H * 0.70 - drop
        let rump = H * 0.74 - drop * 0.35

        p.move(to: CGPoint(x: W * 0.20, y: back - H * 0.02))
        // Along the spine, rear-ward. The dip behind the shoulders then the rise over the
        // haunches is the single most cat-like thing in the outline.
        p.addCurve(to: CGPoint(x: -W * 0.26, y: rump),
                   control1: CGPoint(x: W * 0.02, y: back + H * 0.03),
                   control2: CGPoint(x: -W * 0.14, y: back - H * 0.02))
        // Over the rump and down the back of the thigh.
        p.addCurve(to: CGPoint(x: -W * 0.40, y: belly + H * 0.06),
                   control1: CGPoint(x: -W * 0.38, y: rump - H * 0.01),
                   control2: CGPoint(x: -W * 0.44, y: belly + H * 0.22))
        // The belly line, tucked up in the middle the way a cat's is.
        p.addCurve(to: CGPoint(x: W * 0.18, y: belly + H * 0.04),
                   control1: CGPoint(x: -W * 0.20, y: belly - H * 0.03),
                   control2: CGPoint(x: W * 0.02, y: belly - H * 0.02))
        // Up the chest.
        p.addCurve(to: CGPoint(x: W * 0.20, y: back - H * 0.02),
                   control1: CGPoint(x: W * 0.28, y: belly + H * 0.16),
                   control2: CGPoint(x: W * 0.28, y: back - H * 0.16))
        p.closeSubpath()
    }

    // MARK: - Head and ears

    private static func head(into p: CGMutablePath, _ pose: Pose) {
        let c = headCentre(pose)
        let r = H * 0.19

        // Skull, slightly squared off at the muzzle rather than a plain circle.
        p.move(to: CGPoint(x: c.x - r, y: c.y))
        p.addCurve(to: CGPoint(x: c.x, y: c.y + r),
                   control1: CGPoint(x: c.x - r, y: c.y + r * 0.6),
                   control2: CGPoint(x: c.x - r * 0.6, y: c.y + r))
        p.addCurve(to: CGPoint(x: c.x + r * 1.05, y: c.y + r * 0.10),
                   control1: CGPoint(x: c.x + r * 0.7, y: c.y + r),
                   control2: CGPoint(x: c.x + r * 1.05, y: c.y + r * 0.7))
        p.addCurve(to: CGPoint(x: c.x + r * 0.2, y: c.y - r),
                   control1: CGPoint(x: c.x + r * 1.05, y: c.y - r * 0.55),
                   control2: CGPoint(x: c.x + r * 0.75, y: c.y - r))
        p.addCurve(to: CGPoint(x: c.x - r, y: c.y),
                   control1: CGPoint(x: c.x - r * 0.5, y: c.y - r),
                   control2: CGPoint(x: c.x - r, y: c.y - r * 0.6))
        p.closeSubpath()

        // Ears. Triangles, deliberately exaggerated: at this size an anatomically correct
        // ear disappears, and the ears are most of what says "cat" in an outline.
        for (i, side) in [CGFloat(-0.62), 0.42].enumerated() {
            let baseAngle = CGFloat.pi / 2 + side
            let rot = pose.earAngle * (i == 0 ? 1 : 0.85)
            ear(into: p, centre: c, radius: r, angle: baseAngle + rot, height: H * 0.24)
        }
    }

    private static func ear(into p: CGMutablePath, centre c: CGPoint,
                            radius r: CGFloat, angle: CGFloat, height: CGFloat) {
        let base = CGPoint(x: c.x + cos(angle) * r * 0.86, y: c.y + sin(angle) * r * 0.86)
        let halfWidth = height * 0.42
        let perp = CGPoint(x: -sin(angle), y: cos(angle))
        let tipLean: CGFloat = 0.18     // ears rake slightly forward
        let dir = CGPoint(x: cos(angle) + tipLean, y: sin(angle))
        let n = (dir.x * dir.x + dir.y * dir.y).squareRoot()

        p.move(to: CGPoint(x: base.x - perp.x * halfWidth, y: base.y - perp.y * halfWidth))
        p.addLine(to: CGPoint(x: base.x + perp.x * halfWidth, y: base.y + perp.y * halfWidth))
        p.addLine(to: CGPoint(x: base.x + dir.x / n * height, y: base.y + dir.y / n * height))
        p.closeSubpath()
    }

    static func headCentre(_ pose: Pose) -> CGPoint {
        CGPoint(x: W * 0.30, y: H * 0.78 - pose.crouch * H * 0.13)
    }

    // MARK: - Legs

    /// Four legs on a proper quadruped gait.
    ///
    /// The rule that makes it read: **when a front leg is at contact, the diagonal hind leg
    /// is at passing.** Cats walk LH, LF, RH, RF, so the four phase offsets are not evenly
    /// spaced the way a naive implementation would make them.
    private static func legs(into p: CGMutablePath, _ pose: Pose) {
        let hipY = H * 0.42 - pose.crouch * H * 0.06
        // Near and far legs are spread apart on purpose. Anatomically they would sit almost
        // on top of each other, and at this size that merges them into one thick column and
        // he reads as a two-legged blob. Animators call it keeping the shapes open.
        let legs: [(x: CGFloat, phase: CGFloat, front: Bool)] = [
            (-W * 0.20, 0.00, false),   // left hind
            (W * 0.17, 0.25, true),     // left fore
            (-W * 0.33, 0.50, false),   // right hind
            (W * 0.04, 0.75, true),     // right fore
        ]
        for l in legs {
            let hip = CGPoint(x: l.x, y: hipY)
            let foot = footPosition(hipX: l.x, phase: (pose.walkPhase + l.phase)
                                        .truncatingRemainder(dividingBy: 1),
                                    pose: pose)
            leg(into: p, hip: hip, foot: foot, front: l.front, pose: pose)
        }
    }

    private static func footPosition(hipX: CGFloat, phase: CGFloat, pose: Pose) -> CGPoint {
        guard !pose.airborne else {
            // Tucked. Dangling tucks them tighter and higher than a normal fall does,
            // which is most of what makes "limp" read at this size.
            let tuck = pose.dangling ? H * 0.26 : H * 0.16
            return CGPoint(x: hipX + W * 0.04, y: tuck)
        }
        let stride = W * 0.16 * pose.stride
        // Stance is the longer part of the cycle: a walking cat has feet on the ground
        // most of the time, and cutting stance short is what makes a walk read as a trot.
        let stanceEnd: CGFloat = 0.68
        if phase < stanceEnd {
            let t = phase / stanceEnd                    // planted, sliding rearward
            return CGPoint(x: hipX + stride * (0.5 - t), y: 0)
        }
        let t = (phase - stanceEnd) / (1 - stanceEnd)    // swing, lifted and forward
        let lift = sin(t * .pi) * H * 0.13 * pose.stride
        return CGPoint(x: hipX + stride * (t - 0.5), y: lift)
    }

    /// A two-segment leg drawn as a tapered outline, with the knee bent the correct way.
    /// Front legs bend backward, hind legs forward — get this wrong and he reads as a dog
    /// standing on its own elbows.
    private static func leg(into p: CGMutablePath, hip: CGPoint, foot: CGPoint,
                            front: Bool, pose: Pose) {
        let dx = foot.x - hip.x, dy = foot.y - hip.y
        let mid = CGPoint(x: hip.x + dx * 0.5, y: hip.y + dy * 0.5)
        let bend = (front ? -1 : 1) * (H * 0.09 + pose.crouch * H * 0.05)
        let knee = CGPoint(x: mid.x + bend, y: mid.y)

        let top = H * 0.075       // thigh
        let bottom = H * 0.042    // ankle

        // Down the front of the leg, across the paw, back up the rear.
        p.move(to: CGPoint(x: hip.x - top, y: hip.y))
        p.addQuadCurve(to: CGPoint(x: foot.x - bottom, y: foot.y),
                       control: CGPoint(x: knee.x - top * 0.7, y: knee.y))
        // The paw. Three pixels of it, and it matters more than anything else here:
        // a leg without a paw reads as a stick and the whole thing collapses to a spider.
        p.addLine(to: CGPoint(x: foot.x + bottom * 1.7, y: foot.y))
        p.addLine(to: CGPoint(x: foot.x + bottom, y: foot.y + bottom * 0.9))
        p.addQuadCurve(to: CGPoint(x: hip.x + top, y: hip.y),
                       control: CGPoint(x: knee.x + top * 0.7, y: knee.y))
        p.closeSubpath()
    }

    // MARK: - Tail

    /// Rendered as a tapered ribbon around the simulated chain.
    private static func tail(into p: CGMutablePath, _ pose: Pose) {
        let pts = pose.tail
        guard pts.count >= 3 else { return }

        func normal(_ i: Int) -> CGPoint {
            let a = pts[max(i - 1, 0)], b = pts[min(i + 1, pts.count - 1)]
            let dx = b.x - a.x, dy = b.y - a.y
            let n = max(hypot(dx, dy), 0.001)
            return CGPoint(x: -dy / n, y: dx / n)
        }
        func halfWidth(_ i: Int) -> CGFloat {
            let u = CGFloat(i) / CGFloat(pts.count - 1)
            return Feel.Tail.baseWidth * pow(1 - u, 0.7) + Feel.Tail.tipWidth
        }

        p.move(to: offset(pts[0], normal(0), halfWidth(0)))
        for i in 1..<pts.count { p.addLine(to: offset(pts[i], normal(i), halfWidth(i))) }
        for i in stride(from: pts.count - 1, through: 0, by: -1) {
            p.addLine(to: offset(pts[i], normal(i), -halfWidth(i)))
        }
        p.closeSubpath()
    }

    private static func offset(_ pt: CGPoint, _ n: CGPoint, _ d: CGFloat) -> CGPoint {
        CGPoint(x: pt.x + n.x * d, y: pt.y + n.y * d)
    }

    /// Where the tail is rooted, in body space.
    public static func tailBase(_ pose: Pose) -> CGPoint {
        CGPoint(x: -W * 0.36, y: H * 0.70 - pose.crouch * H * 0.06)
    }

    // MARK: - Eyes

    /// Two bright shapes on a dark silhouette is the highest expression-per-pixel ratio in
    /// animation. There is no separate pupil: the eye *is* the bright region, so mood is
    /// carried by its size and shape rather than by a dot inside it.
    public static func eyes(gaze: Gaze, pose: Pose) -> CGPath {
        let p = CGMutablePath()
        let c = headCentre(pose)
        let dx = gaze.offset.x * Feel.Eyes.travel
        let dy = gaze.offset.y * Feel.Eyes.travel

        // Side view: the near eye carries the performance, the far one is a hint of a
        // second eye past the bridge of the nose.
        for (i, spec) in [(x: H * 0.075, scale: CGFloat(1.0)),
                          (x: -H * 0.065, scale: Feel.Eyes.asymmetry)].enumerated() {
            let rx = Feel.Eyes.radiusX * spec.scale
            let ry = Feel.Eyes.radiusY * spec.scale * gaze.lid
            let cx = c.x + spec.x + dx
            let cy = c.y + H * 0.03 + dy - (i == 1 ? H * 0.01 : 0)
            p.addEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
        }
        return p
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
