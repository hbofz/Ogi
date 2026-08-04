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
        /// Impact speed above which a landing is a hard one and he shakes himself off rather
        /// than simply arriving. Against `gravity` that is a 90pt drop, which is an ordinary
        /// step down between two windows — so most landings are hard ones, deliberately.
        public static let hardLanding: CGFloat = 600
        /// Sideways nudge when the ground vanishes underfoot, so he doesn't drop straight down.
        public static let slipKick: CGFloat = 40
        /// How far past the lip he is placed at the instant he steps off, so the fall starts
        /// clear of the edge he just left rather than scraping down it. Small: his centre of
        /// mass has only just crossed.
        public static let edgeTolerance: CGFloat = 2
        /// How far PAST a lip a committed step-off aims, and how close to one counts as "at the
        /// edge" for the tell. Comfortably outside `brakingDistance` on purpose: a step-off has
        /// to be still at speed when it reaches the lip, or he brakes at it instead of over it.
        ///
        /// It used to be where he stopped to look as well, on the reasoning that it was roughly
        /// half his drawn width. It is not — see `edgePlant` — and one number cannot be both,
        /// because this one may not shrink.
        public static let edgeApproach: CGFloat = 26
        /// Where he stops to look: how far back from the lip he plants, and the number to move
        /// if he reads as standing too far back. The approach walks to a mark one
        /// `brakingDistance` further in, which is what stops it from ever arriving — so this has
        /// to stay above `brakingDistance` or the mark lands past the lip.
        ///
        /// Off the art, not off his nominal size. `Shape.width` is 52 and means nothing here:
        /// every clip is normalised on eye width and cropped tight sideways, so what is actually
        /// drawn around `position.x` varies per clip and per frame. The held `lookDown` frame is
        /// 23pt wide, and reading its ground contacts gives his front paws 2.5pt ahead of his
        /// midline and his lowered head reaching 11.5pt ahead — he is looking straight down past
        /// his own paws, so the head is the part that has to clear the lip.
        ///
        /// That brackets this number, and `hePlantsWithHisPawsOnTheLedgeAndHisHeadOverTheLip`
        /// derives both ends from `Sprites` and fails if the sheet is redrawn. At 26 he stopped
        /// 30pt back with an 18pt strip of bare ledge between his nose and the drop, which reads
        /// as a cat looking at the floor rather than over an edge.
        ///
        /// 6 rather than the 2.5 that would put his toes exactly on the lip, because the clip is
        /// cropped per frame: his paws sit 9.7pt forward of his midline in the standing frame he
        /// plants on and 2.5pt forward in the one he holds, so his feet appear to slide back 7pt
        /// during the lean. Standing between the two keeps either end under `arrivalSlop`.
        public static let edgePlant: CGFloat = 6
        /// Drop at which the hesitation is longest and the reluctance strongest.
        public static let edgeHesitationDrop: CGFloat = 800
        /// How often he turns down a drop that deep, having walked over to look at it. Below
        /// half on purpose: the reluctance has to be visible without stranding him up there,
        /// and he can always change his mind a minute later.
        public static let edgeRefusal: Double = 0.45
        /// How far back along the ledge he retreats when he thinks better of it. Far enough
        /// that the next idea starts from somewhere that is not the lip.
        public static let edgeRetreat: CGFloat = 70
        /// Over how many points he eases off on the way to a lip, and the creep he is down to
        /// when he gets there. This is the "slows" beat of the tell and it cannot come from
        /// the walk's own braking: that only acts inside `brakingDistance` of its mark, which
        /// is exactly the stretch he never walks, since he plants before reaching it.
        ///
        /// Three body lengths of approach, ending at about a third of a stroll. Long enough to
        /// read as a decision being made before he arrives rather than a stop.
        public static let edgeEase: CGFloat = 78
        public static let edgeCreepSpeed: CGFloat = 16

        public static let walkSpeed: CGFloat = 46          // px/s
        public static let runSpeed: CGFloat = 118
        /// Beyond this he trots rather than strolls.
        public static let hurryDistance: CGFloat = 210
        /// He never arrives exactly on the mark.
        public static let arrivalSlop: CGFloat = 3

        /// Surface-local acceleration and braking, px/s². He winds up into a walk over about
        /// 0.2s and coasts out of one over about 0.3s, which is the whole of the weight.
        ///
        /// Braking is finite AND starts late, and the second half is where the overshoot comes
        /// from: `walkSpeed` needs 7pt to stop in, he only starts braking `brakingDistance`
        /// out, so he arrives ~3pt past his mark. Braking slightly late IS the overshoot.
        ///
        /// Two ceilings on that difference, both of them real:
        /// - keep it under `arrivalSlop * 3` or every arrival counts as a miss and he walks
        ///   back, and a walk-back long enough to reach full speed overshoots by exactly as
        ///   much again, which is a cat pacing between two points for ever.
        /// - keep `brakingDistance` well under `edgeApproach` or a step-off brakes at the lip
        ///   instead of going over it, since a step-off is aimed `edgeApproach` past it.
        public static let accel: CGFloat = 220
        public static let decel: CGFloat = 150
        /// How far out he starts braking.
        public static let brakingDistance: CGFloat = 4
        /// Below this he counts as stopped.
        public static let stopSpeed: CGFloat = 3
        /// A gap he strides over rather than leaping. Two tiled windows sharing a top edge
        /// read as one shelf; a full ballistic arc over the crack between them does not.
        public static let strideGap: CGFloat = 24

        /// The whole jump budget: his launch speed, in px/s. Distance is an *output* of
        /// this and the angle, not an input.
        ///
        /// v1 solved the ballistic exactly for whatever target it was handed, so a 40pt hop
        /// and a 420pt leap had identical arc height and neither could fail. Three separate
        /// constants (maxJumpRise, maxJumpDrop, maxJumpReach) tried to fence that in from
        /// outside and were ignored by the solver. Fixing the speed collapses all three into
        /// one physically meaningful number, and makes the discriminant the reachability
        /// test rather than an assertion.
        ///
        /// 872 px/s against 2000 px/s² gives a maximum rise of v²/2g = 190pt and a maximum
        /// flat range of v²/g = 380pt, which reproduces v1's stated envelope (190 up, 420
        /// across) almost exactly. Keep the ceiling roughly here: raising it lets him climb
        /// out of places he should be stuck in, and lowering it lets him ratchet steadily
        /// downward over a session, since a downward target is cheaper to reach than the
        /// way back up.
        ///
        /// A ceiling, not the speed he always uses: every launch is the cheapest one that
        /// reaches its target, so what he actually spends rises with the distance.
        public static let jumpImpulse: CGFloat = 872
        public static let jumpChance = 0.55
        /// Deliberate aiming error, as a **fraction of the launch speed**. A cat that always
        /// sticks the landing reads as a machine.
        ///
        /// On the speed rather than the angle because every launch is the minimum-energy one,
        /// where the target sits at a tangency and angular error is second-order: ±0.06 rad
        /// moves a 60pt hop by half a point, so he would never miss at all. Speed error puts
        /// range ∝ (1+ε)², which scatters a 60pt hop over [53, 67] and a 300pt jump over
        /// [265, 337] — proportional to the distance, and signed both ways.
        ///
        /// v1 scaled horizontal speed against a fixed flight time, which also gave a signed
        /// error proportional to distance; in that one respect v1's model was the same shape
        /// as this one and better than the angular form that briefly replaced it. What v1
        /// could not do was fail to reach the target at all.
        public static let aimError: CGFloat = 0.06
        /// However hard you flick him, he does not become a projectile.
        public static let maxThrow: CGFloat = 1500

        /// How fast he slides down a face he cannot hold, px/s. Deliberately slow: this is
        /// a moment, not a transition.
        public static let clingSlideSpeed: CGFloat = 34
        /// ...and how fast he goes UP one, px/s. A separate number because they are not the
        /// same event: the slide is something happening to him, the climb is something he is
        /// doing. Sharing the slide's 34 made a full-height window a twenty-second climb,
        /// which is not a cat going up a curtain, it is a progress bar. First knob to turn if
        /// the climb reads slow or frantic.
        public static let clingClimbSpeed: CGFloat = 110
        /// Within this far of the top edge he climbs up and mantles onto it instead of
        /// sliding down.
        public static let mantleReach: CGFloat = 90
        /// How gently he has to be put down to catch the face at all, px/s on either axis.
        /// Above it he was thrown rather than placed, and a thrown cat does not grab.
        public static let clingGrabSpeed: CGFloat = 200

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
        /// How long he holds still after grabbing on. The "oh no" beat.
        public static let clingHold: TimeInterval = 0.7

        /// The hold at the lip, before and after scaling with the drop. This is the same idea
        /// as `anticipation` one level up: the crouch is the difference between a cat and a
        /// teleporting rectangle, and this is the difference between the cat jumped and the
        /// cat decided to jump. Long enough to read as thinking, short enough not to look
        /// broken. Tune these before anything else if the hold does not land.
        ///
        /// **The minimum has a floor under it: the `lookDown` sheet's own time to its held
        /// frame**, 3 frames at 6fps. Below that a shallow drop commits part-way through the
        /// lean and the tell is a cat twitching his head down — and window-to-window drops are
        /// the common case, so that would be most of them. `theLeanAlwaysFinishesBeforeHeCanCommit`
        /// derives the figure from the clip and fails if either number moves; it lives in the
        /// tests rather than here because `Cat.step` cannot see `Sprites`.
        public static let edgeHesitationMin: TimeInterval = 0.5
        public static let edgeHesitationMax: TimeInterval = 1.6

        /// How long a landing reads for before he goes back to being a cat.
        ///
        /// A hard one runs longer because it has more to say: the `shake` sheet is 4 frames at
        /// 12fps, and the extra tenth is spent holding its settled last frame, which is the pose
        /// idle picks up from. Below the sheet's own length he would snap upright with his fur
        /// still on end, since the clip does not loop. `theShakeOutlastsItsOwnSheet` derives the
        /// floor from the clip and fails if either number moves; it lives in the tests rather
        /// than here because `Cat.step` cannot see `Sprites`.
        public static let landSeconds: TimeInterval = 0.35
        public static let landHardSeconds: TimeInterval = 4.0 / 12 + 0.1

        /// How long the pivot takes, and for that whole time nothing else moves him. 4 frames
        /// at the `turn` clip's 12fps: he does not flip like a sprite, and a flip is one of the
        /// top-three tells that something is a drawing rather than an animal.
        ///
        /// `theTurnAlwaysPlaysAllTheWayThrough` derives the figure from the clip and fails if
        /// either number moves; it lives in the tests rather than here because `Cat.step`
        /// cannot see `Sprites`.
        public static let turnSeconds: TimeInterval = 4.0 / 12

        /// How long he creeps out of the notch on launch before he starts walking. The whole
        /// of the first impression, so it is a beat rather than a transition.
        ///
        /// Floored by the `peek` sheet's own length, 4 frames at 5fps, for the same reason
        /// `edgeHesitationMin` is floored by `lookDown`: the clip does not loop, so anything
        /// shorter cuts him off mid-crouch and he snaps upright into a walk. The remainder is
        /// spent holding the last frame — front half out, head up, hindquarters still in the
        /// dark — which is the pose the walk starts from. `thePeekFinishesBeforeHeWalksOut`
        /// derives the floor from the clip and fails if either number moves.
        public static let peekSeconds: TimeInterval = 1.1

        /// OGI_RESTLESS=1 collapses these so his behaviour can actually be watched.
        /// Living with him wants long pauses; testing him does not.
        public static let restMin: TimeInterval = restless ? 0.4 : 3.5
        public static let restJitter: TimeInterval = restless ? 0.8 : 9.0
        /// How long one washing bout lasts. Six lick cycles at the clip's 8fps.
        public static let groomSeconds: TimeInterval = 4.5
        /// Chance that a bout of boredom becomes a wash rather than a trip somewhere.
        /// Manifesto §7.1 wants an occasional in-place behaviour roughly every few minutes,
        /// and washing is currently the only one of those that exists.
        public static let groomChance: Double = 0.15

        /// How much longer he waits between ideas once he has settled. A settled cat is
        /// calmer, not switched off: these stretch the rest timer, they do not stop it.
        public static let sittingRest = 4.0
        public static let curledRest = 12.0
        /// ...and how much likelier a bout of boredom is to become an in-place behaviour
        /// (a wash, a look around) rather than a trip somewhere. A curled cat will get up,
        /// but rarely.
        public static let sittingInPlace = 0.75
        public static let curledInPlace = 0.95
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
        /// A Space change replaces the entire window list in one go. For this many polls
        /// afterwards every known surface is held regardless of misses: two polls of ordinary
        /// hysteresis is nowhere near enough, and without it the turnover reads as every
        /// platform in the world vanishing at once and he falls.
        ///
        /// Polls and not seconds, because `WorldTracker` is pure and has no clock. `pollRate()`
        /// runs anywhere from 1 to 30Hz, so what this buys varies: ~400ms at the usual 10Hz,
        /// ~130ms if you happen to be mid-drag, and up to 4s if he is asleep — harmless, since
        /// a sleeping cat is not walking off anything.
        public static let spaceChangeHoldOffPolls = 4
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
        /// Two surfaces within this vertical distance count as the same shelf, and the gap
        /// between them as a crack to step over rather than a drop to leap.
        public static let coplanarTolerance: CGFloat = 2
        public static let positionDeadband: CGFloat = 1
    }

    /// The drifting "z"s while he sleeps. Deliberately slow and faint: this is the one thing on
    /// screen while he is doing nothing, so it has to be noticeable once and then ignorable.
    public enum Sleepiness {
        /// Seconds for one z to rise, fade in and fade out.
        public static let riseSeconds: Double = 3.4
        /// How many are in flight at once, evenly staggered across the rise.
        public static let count = 3
        /// How far one travels over its life, as a multiple of his rendered height.
        public static let driftHeight: CGFloat = 0.85
        /// Sideways drift over the same life, same units. Small; they wander, not zigzag.
        public static let driftSide: CGFloat = 0.22
        /// Size of the first z, as a multiple of his height. Each one grows as it rises.
        public static let glyphHeight: CGFloat = 0.15
        public static let growth: CGFloat = 0.6
        public static let peakOpacity: Float = 0.65
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
        ///
        /// One per gait, because a trotting cat covers much more ground per stride than a
        /// strolling one and the gait is cycled off distance: `buildPose` advances the phase by
        /// `speed / stride`, so a stride that is too short cranks the sheet. Sharing the walk's
        /// 30pt ran the 8-frame run sheet at 31.5fps against the 14 it declares — 2.25x, a blur
        /// of legs rather than a trot, and the one thing the distance-driven gait was supposed
        /// to have fixed.
        ///
        /// The run figure is `runSpeed * frames / fps`: the stride that makes the sheet play at
        /// the rate it was drawn for. The walk's 30 is a hand-tuned figure that predates the
        /// arithmetic and leaves its sheet 8% slow, which is invisible and stops the paws
        /// skating; `eachGaitPlaysAtItsOwnClipsDeclaredRate` holds both against their clips.
        public static let strideLength: CGFloat = 30
        public static let runStrideLength: CGFloat = 67
        /// Impact speed that produces maxSquash.
        public static let squashReference: CGFloat = 900
    }
}
