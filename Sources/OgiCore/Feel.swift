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
        /// He never arrives exactly on the mark.
        public static let arrivalSlop: CGFloat = 3

        /// How high he clears the higher end of a jump.
        public static let jumpArc: CGFloat = 58
        public static let maxJumpRise: CGFloat = 190       // vertical reach, either direction
        public static let maxJumpReach: CGFloat = 420      // horizontal reach
        public static let jumpChance = 0.35
        /// Deliberate aiming error. A cat that always sticks the landing reads as a machine.
        public static let aimError: CGFloat = 0.09
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
        public static let restMin: TimeInterval = 3.5
        public static let restJitter: TimeInterval = 9.0
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
        public static let height: CGFloat = 34
        public static let width: CGFloat = 46
        /// Squash depth is proportional to impact speed, capped here.
        public static let maxSquash: CGFloat = 0.30
        /// Impact speed that produces maxSquash.
        public static let squashReference: CGFloat = 900
    }
}
