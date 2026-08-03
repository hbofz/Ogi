import CoreGraphics

/// Pose to `CGPath`. Knows nothing about windows, physics, or AppKit.
public enum Body {

    /// M0 placeholder: an ellipse with two triangular ears.
    ///
    /// ponytail: deliberately not the real cat. M0 exists to answer four platform questions
    /// and to test whether the fall is charming, and if it isn't charming as a blob the
    /// problem is timing, not art. The real silhouette lands in M5.
    ///
    /// Origin is at his feet on his midline, +y up.
    public static func placeholder(width: CGFloat = Feel.Shape.width,
                                   height: CGFloat = Feel.Shape.height) -> CGPath {
        let p = CGMutablePath()
        let rx = width / 2

        // Body. Multiple closed subpaths wound the same way and filled .nonZero render as
        // their union, so ears need no boolean op.
        p.addEllipse(in: CGRect(x: -rx, y: 0, width: width, height: height))

        // Ears. Wound the SAME direction as the ellipse, which `addEllipse` draws
        // clockwise. Reverse one of them and .nonZero subtracts it instead of unioning,
        // which renders as notches bitten out of his skull.
        let earW = width * 0.20, earH = height * 0.34
        for side in [CGFloat(-1), 1] {
            let baseX = side * width * 0.24
            let baseY = height * 0.74
            p.move(to: CGPoint(x: baseX - earW / 2, y: baseY))
            p.addLine(to: CGPoint(x: baseX + earW / 2, y: baseY - earH * 0.15))
            p.addLine(to: CGPoint(x: baseX + side * earW * 0.1, y: baseY + earH))
            p.closeSubpath()
        }
        return p
    }

    /// The eyes, in body space (origin at his feet, midline, +y up).
    ///
    /// Two bright shapes on a dark silhouette is the highest expression-per-pixel ratio in
    /// animation. There is no separate pupil: the eye *is* the bright region, so mood is
    /// carried by its size and shape rather than by a dot inside it.
    public static func eyes(gaze: Gaze,
                            width: CGFloat = Feel.Shape.width,
                            height: CGFloat = Feel.Shape.height) -> CGPath {
        let p = CGMutablePath()
        let cy = height * Feel.Eyes.heightFraction
        let dx = gaze.offset.x * Feel.Eyes.travel
        let dy = gaze.offset.y * Feel.Eyes.travel

        for (i, side) in [CGFloat(-1), 1].enumerated() {
            let scale = i == 0 ? 1 : Feel.Eyes.asymmetry
            let rx = Feel.Eyes.radiusX * scale
            // The lid closes by flattening the eye vertically about its own centre.
            let ry = Feel.Eyes.radiusY * scale * gaze.lid
            let cx = side * width * Feel.Eyes.separation
            p.addEllipse(in: CGRect(x: cx + dx - rx, y: cy + dy - ry,
                                    width: rx * 2, height: ry * 2))
        }
        return p
    }

    /// Contact shadow. Tightens and darkens on landing, softens and separates in the air.
    /// Sells "he is standing on that window" more than anything else in the app.
    public static func shadow(width: CGFloat, height h: CGFloat) -> CGPath {
        let rx = width * (0.30 + 0.006 * h)
        let ry = rx * 0.22
        return CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2),
                      transform: nil)
    }

    public static func shadowOpacity(height h: CGFloat) -> CGFloat {
        0.50 * exp(-h / 12.0)
    }
}
