import Foundation
import CoreGraphics

/// Where he is looking, and whether his eyes are open.
///
/// The whole performance lives here. Two rules matter more than any constant:
///
/// 1. **Eyes saccade, they do not glide.** Real eyes snap between targets and then hold
///    perfectly still. Smoothly interpolating toward the cursor is the single thing that
///    makes an animated character read as software. The manifesto's "80ms lag" is a
///    *latency before the jump*, not a smoothing factor.
/// 2. **Nothing is on a metronome.** Blinks are Poisson-distributed, and the eyes make
///    small involuntary movements even when nothing has changed.
public struct Gaze: Sendable {

    // Saccade state. All offsets are in the unit disc, scaled to pixels at render time.
    public private(set) var offset: CGPoint = .zero
    private var fixation: CGPoint = .zero     // what he is locked onto
    private var origin: CGPoint = .zero       // where the current jump started
    private var progress: CGFloat = 1         // 0..1 through the jump
    private var duration: CGFloat = 0.04
    private var latency: CGFloat = -1         // counting down to the jump; <0 means idle
    private var held: CGFloat = 0             // time since the last saccade

    // Blink state.
    public private(set) var lid: CGFloat = 1  // 1 open, 0.06 closed
    private var untilBlink: CGFloat = 2
    private var blinkT: CGFloat = -1
    private var queuedDouble = false

    public init() { untilBlink = Self.nextBlinkInterval() }

    /// Mean 4s, exponentially distributed. `-ln(U)/λ` with λ = 0.25.
    /// A metronome blink reads as a machine; this reads as an animal.
    static func nextBlinkInterval() -> CGFloat {
        let u = Double.random(in: .leastNonzeroMagnitude...1)
        return CGFloat(min(max(-log(u) * 4.0, 0.8), 14))
    }

    /// `target` is the direction he wants to look, already clamped to the unit disc.
    public mutating func step(target: CGPoint, dt: CGFloat) {
        stepSaccade(target: target, dt: dt)
        stepBlink(dt: dt)
    }

    private mutating func stepSaccade(target: CGPoint, dt: CGFloat) {
        held += dt

        let drift = hypot(target.x - fixation.x, target.y - fixation.y)
        let wantsJump = drift > Feel.Eyes.saccadeThreshold
            // Involuntary micro-saccades. Real eyes never hold perfectly still for a full
            // second, and this is the cheapest aliveness tell in the app.
            || (held > Feel.Eyes.microSaccadeAfter && drift > 0.05)

        if wantsJump, latency < 0, progress >= 1 {
            latency = Feel.Eyes.latency
        }

        if latency >= 0 {
            latency -= dt
            if latency < 0 {
                origin = offset
                fixation = target
                let d = hypot(fixation.x - origin.x, fixation.y - origin.y)
                // The main sequence: saccade duration rises with amplitude, 20-80ms.
                duration = min(max(0.020 + 0.055 * d, 0.020), 0.080)
                progress = 0
                held = 0
                // Blinks are suppressed during a saccade, as in a real visual system.
                if blinkT < 0 { untilBlink = max(untilBlink, 0.15) }
            }
        }

        if progress < 1 {
            progress = min(1, progress + dt / duration)
            let t = progress
            // Symmetric ease. No overshoot: real saccades do not bounce.
            let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            offset = CGPoint(x: origin.x + (fixation.x - origin.x) * e,
                             y: origin.y + (fixation.y - origin.y) * e)
        }
    }

    private mutating func stepBlink(dt: CGFloat) {
        if blinkT >= 0 {
            blinkT += dt
            let close = Feel.Eyes.blinkClose
            let hold = close + Feel.Eyes.blinkHold
            let open = hold + Feel.Eyes.blinkOpen
            if blinkT < close {
                lid = 1 - (1 - Feel.Eyes.lidFloor) * (blinkT / close)
            } else if blinkT < hold {
                lid = Feel.Eyes.lidFloor
            } else if blinkT < open {
                // Opening slower than closing is true of real lids, and reads far better
                // than a symmetric blink.
                lid = Feel.Eyes.lidFloor + (1 - Feel.Eyes.lidFloor) * ((blinkT - hold) / Feel.Eyes.blinkOpen)
            } else {
                lid = 1
                blinkT = -1
                if queuedDouble {
                    queuedDouble = false
                    untilBlink = Feel.Eyes.doubleBlinkGap
                } else {
                    untilBlink = Self.nextBlinkInterval()
                }
            }
            return
        }

        untilBlink -= dt
        if untilBlink <= 0 {
            blinkT = 0
            // Cats double-blink. Cheap, and people notice it without knowing why.
            queuedDouble = Double.random(in: 0...1) < Feel.Eyes.doubleBlinkChance
        }
    }
}

extension Feel {
    public enum Eyes {
        /// How far the cursor must drift before he re-aims. Below this he simply holds.
        public static let saccadeThreshold: CGFloat = 0.18
        /// Delay between deciding to look and the eyes moving. The manifesto's "80ms".
        public static let latency: CGFloat = 0.080
        public static let microSaccadeAfter: CGFloat = 1.2

        public static let blinkClose: CGFloat = 0.060
        public static let blinkHold: CGFloat = 0.030
        public static let blinkOpen: CGFloat = 0.090
        /// Never scale to zero. A 1px line reads "closed eye"; absence reads "bug".
        public static let lidFloor: CGFloat = 0.06
        public static let doubleBlinkChance = 0.12
        public static let doubleBlinkGap: CGFloat = 0.12

        /// How far the eyes travel within the head, in points.
        public static let travel: CGFloat = 1.0
        /// Perfect symmetry reads as a logo, so the far eye is slightly smaller.
        public static let asymmetry: CGFloat = 0.80
        // Sized against a head radius of H*0.19 (~6pt). Anything larger reads as googly
        // eyes rather than as a cat, which was the first thing wrong with this.
        //
        public static let radiusX: CGFloat = 1.9
        public static let radiusY: CGFloat = 2.2
        public static let heightFraction: CGFloat = 0.78   // × body height, for the head
    }
}

/// Maps a world-space point he is attending to into a unit-disc look direction.
public func lookDirection(from head: CGPoint, to point: CGPoint) -> CGPoint {
    let dx = point.x - head.x, dy = point.y - head.y
    let d = hypot(dx, dy)
    guard d > 0.001 else { return .zero }
    // Saturates quickly: anything past ~200px away is simply "over there".
    let m = min(d / 200, 1)
    return CGPoint(x: dx / d * m, y: dy / d * m)
}

// The Verlet tail that used to trail the procedural silhouette lived here. It died with
// the silhouette: the drawn sheets carry his tail now, and the sim was stepping every
// frame to feed a path nothing rendered. Git history has it.
