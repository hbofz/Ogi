import Foundation
import CoreGraphics

/// Every tunable number in Ogi. No types, no logic.
///
/// The physical character of this thing has to be tuned by hand, and no amount of
/// correct math substitutes for sitting there adjusting numbers until it feels right.
public enum Feel {

    public enum Physics {
        /// px/s². Manifesto §6.
        public static let gravity: CGFloat = 2000
        /// Capped so long falls stay readable rather than becoming a blur.
        public static let terminalVelocity: CGFloat = 1400
        /// Sideways nudge when the ground vanishes underfoot, so he doesn't drop straight down.
        public static let slipKick: CGFloat = 40

        public static let walkSpeed: CGFloat = 46          // px/s
        public static let runSpeed: CGFloat = 118
        /// Beyond this he trots rather than strolls.
        public static let hurryDistance: CGFloat = 210
        /// He never arrives exactly on the mark.
        public static let arrivalSlop: CGFloat = 3

        /// How high he clears the higher end of a jump.
        public static let jumpArc: CGFloat = 58
        public static let maxJumpRise: CGFloat = 190       // how far UP he will jump
        /// How far DOWN he will drop. Much further than he can jump up, because falling is
        /// free — and without this he almost never jumps at all, since on a normal desktop
        /// the only things below him are a long way down.
        public static let maxJumpDrop: CGFloat = 700
        public static let maxJumpReach: CGFloat = 420      // horizontal reach
        public static let jumpChance = 0.55
        /// Deliberate aiming error. A cat that always sticks the landing reads as a machine.
        public static let aimError: CGFloat = 0.09
        /// However hard you flick him, he does not become a projectile.
        public static let maxThrow: CGFloat = 1500

        /// Per-tick drift at which he leans as far as he ever will (~480 px/s of drag).
        public static let driftReference: CGFloat = 4.0
        public static let driftSmoothing: CGFloat = 0.02
        public static let braceThreshold: CGFloat = 0.25
        /// How far he tips into the motion, in radians. Small: he is bracing, not falling over.
        public static let maxLean: CGFloat = 0.30
    }

    public enum Timing {
        public static let fixedDT: TimeInterval = 1.0 / 120
        /// Without this clamp the first tick after the display link resumes from screen
        /// lock integrates a multi-hour delta and launches him into orbit.
        public static let maxFrameDelta: TimeInterval = 0.1
        /// The 100ms crouch before every jump. Non-negotiable: it is the entire
        /// difference between a cat and a teleporting rectangle.
        public static let anticipation: TimeInterval = 0.100
        public static let squashRecovery: TimeInterval = 0.080

        /// How long he stays put between ideas. Restraint is the feature: he is still by
        /// default and most interesting when you are not working.
        /// The mid-air twist. Fixed duration, so he is always feet-down before he lands.
        public static let righting: TimeInterval = 0.18

        /// OGI_RESTLESS=1 collapses these so his behaviour can actually be watched.
        /// Living with him wants long pauses; testing him does not.
        public static let restMin: TimeInterval = restless ? 0.4 : 3.5
        public static let restJitter: TimeInterval = restless ? 0.8 : 9.0
        static let restless = ProcessInfo.processInfo.environment["OGI_RESTLESS"] != nil
    }

    public enum World {
        public static let pollHz: Double = 10
        /// Burst rate while a mouse button is down, so dragged windows don't strobe.
        public static let dragPollHz: Double = 30
        /// A surface absent for fewer than this many polls is re-inserted with its last
        /// known geometry. The ~200ms beat before the fall reads as realization.
        public static let vanishConfirmPolls = 2
        /// New surfaces occlude immediately but aren't walk targets yet, so he doesn't
        /// chase menus and sheets.
        public static let minAgePolls = 2
        public static let minStandWidth: CGFloat = 24
        /// Rounded window corners eat the walkable part of the top edge.
        public static let cornerInset: CGFloat = 10
        /// macOS 26 default. Non-uniform per window type with no public API to query it,
        /// so this is a compromise. Measure and adjust.
        public static let windowCornerRadius: CGFloat = 16
        /// Windows below this alpha are animation frames or invisible helper windows.
        /// This one filter removes most of the world's jitter.
        public static let minWindowAlpha: Double = 0.95
        /// Tiled windows very often share a top edge exactly. Without this, the rear
        /// one's entire surface gets erased by the front one.
        public static let coplanarEpsilon: CGFloat = 0.5
        public static let positionDeadband: CGFloat = 1
    }

    public enum Shape {
        // A cat in side view is much longer than it is tall. Getting this ratio wrong is
        // what makes these things read as bears or rats.
        public static let height: CGFloat = 32
        public static let width: CGFloat = 52
        /// Reference frames are ~70-95px tall. 0.55 puts him at roughly 40-50pt, which is
        /// large enough to read on a window edge and small enough to stay out of the way.
        public static let spriteScale: CGFloat = 1.0
        /// Target on-screen eye width in points. Every clip is scaled to match it, which is
        /// what keeps him the same size whether he is sitting or walking.
        public static let referenceEyeWidth: CGFloat = 2.1
        /// Squash depth is proportional to impact speed, capped here.
        public static let maxSquash: CGFloat = 0.30
        /// Ground covered per full gait cycle. Tuned so the paws do not skate.
        public static let strideLength: CGFloat = 30
        /// Impact speed that produces maxSquash.
        public static let squashReference: CGFloat = 900
    }
}
