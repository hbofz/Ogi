import Foundation
import CoreGraphics

/// Every tunable number in Ogi. No types, no logic.
///
/// The physical character of this thing has to be tuned by hand, and no amount of
/// correct math substitutes for sitting there adjusting numbers until it feels right.
public enum Feel {

    public enum Physics {
        /// px/s².
        public static let gravity: CGFloat = 2000
        /// Capped so long falls stay readable rather than becoming a blur.
        public static let terminalVelocity: CGFloat = 1400
        /// Impact speed above which a landing rattles him and he shakes himself off rather
        /// than simply arriving. Against `gravity` that is a 250pt drop.
        ///
        /// Bracketed on both sides, and `theShakeIsBeyondHisOwnJump` holds the bracket:
        /// above `jumpImpulse * (1 + aimError)`, because a landing he could have chosen is
        /// not a hard one and his own deliberate leaps must never rattle him; below
        /// `terminalVelocity`, or no fall could ever qualify. Keep it well clear of an ordinary
        /// step down between windows (a 90pt drop): at 600 every landing is a hard one, and a
        /// tell that always fires stops being a tell.
        public static let hardLanding: CGFloat = 1000
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
        /// Where he stops to look is a separate number (`edgePlant`): one cannot do both jobs,
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
        /// derives both ends from `Sprites` and fails if the sheet is redrawn. Much larger leaves
        /// a strip of bare ledge between his nose and the drop, which reads as a cat looking at
        /// the floor rather than over an edge.
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
        /// Fixing the speed is what makes the envelope real: one physically meaningful number
        /// rather than separate rise, drop and reach limits fenced on from outside, and the
        /// discriminant becomes the reachability test rather than an assertion.
        ///
        /// 872 px/s against 2000 px/s² gives a maximum rise of v²/2g = 190pt and a maximum
        /// flat range of v²/g = 380pt. Keep the ceiling roughly here: raising it lets him climb
        /// out of places he should be stuck in, and lowering it lets him ratchet steadily
        /// downward over a session, since a downward target is cheaper to reach than the
        /// way back up.
        ///
        /// A ceiling, not the speed he always uses: every launch is the cheapest one that
        /// reaches its target, so what he actually spends rises with the distance.
        public static let jumpImpulse: CGFloat = 872
        /// Deliberate aiming error, as a **fraction of the launch speed**. A cat that always
        /// sticks the landing reads as a machine.
        ///
        /// On the speed rather than the angle because every launch is the minimum-energy one,
        /// where the target sits at a tangency and angular error is second-order: ±0.06 rad
        /// moves a 60pt hop by half a point, so he would never miss at all. Speed error puts
        /// range ∝ (1+ε)², which scatters a 60pt hop over [53, 67] and a 300pt jump over
        /// [265, 337] — proportional to the distance, and signed both ways.
        public static let aimError: CGFloat = 0.06
        /// However hard you flick him, he does not become a projectile.
        public static let maxThrow: CGFloat = 1500

        /// How fast he slides down a face he cannot hold, px/s. Deliberately slow: this is
        /// a moment, not a transition.
        public static let clingSlideSpeed: CGFloat = 34
        /// ...and how fast he goes UP one, px/s. A separate number because they are not the
        /// same event: the slide is something happening to him, the climb is something he is
        /// doing. At the slide's 34 a full-height window is a twenty-second climb, which is not
        /// a cat going up a curtain, it is a progress bar. First knob to turn if the climb reads
        /// slow or frantic.
        public static let clingClimbSpeed: CGFloat = 110
        /// Within this far of the top edge he climbs up and mantles onto it instead of
        /// sliding down.
        public static let mantleReach: CGFloat = 90
        /// How far INTO a face he has to be able to leap before he will try to climb it, and
        /// how much extra height he asks of that leap. One number doing both jobs, because
        /// they are the same job: it is the margin that stops a leap which merely GRAZES the
        /// bottom edge — arriving at its apex with no upward speed left, so the grab never
        /// fires and he drops back to try again — from being a thing that can happen.
        ///
        /// The margin has to survive `aimError`, which scatters the push-off by ±6% of the
        /// speed and so the rise by (1±0.06)². Worst case is the deepest leap he will attempt
        /// (the full 190pt of rise): a −6% draw still clears the bottom edge by 18pt, which is
        /// eight ticks of face at the speed he is doing when he gets there. Raising this
        /// shrinks the set of windows he will climb; lowering it eats that margin.
        public static let climbBite: CGFloat = 40

        /// Per-tick drift at which he leans as far as he ever will (~480 px/s of drag).
        public static let driftReference: CGFloat = 4.0
        public static let driftSmoothing: CGFloat = 0.02
        public static let braceThreshold: CGFloat = 0.25
        /// How far he tips into the motion, in radians. Small: he is bracing, not falling over.
        public static let maxLean: CGFloat = 0.30
    }

    /// What he notices, and how strongly he responds to it.
    ///
    /// One scalar, `arousal`, rises with stimulus and decays with quiet. It is deliberately
    /// additive: at zero he behaves exactly as he would without it, which keeps the whole layer
    /// testable against the rest of the suite.
    public enum Mind {
        /// Seconds for excitement to halve. Sets the whole rhythm of the layer.
        ///
        /// The tuning below is chosen so that **one thing happening is a look and several
        /// things happening is a decision**: a single window opening reaches 0.30 against a
        /// 0.45 threshold and can only ever be a glance, while two openings inside a half-life
        /// clear it. If any of these three numbers move, that relationship is the thing that
        /// has to survive, and `oneWindowIsAGlanceAndTwoIsATrip` fails if it does not.
        ///
        /// **45 and not 20.** At 20 the rule is arithmetically true and practically invisible:
        /// two windows twenty seconds apart land exactly ON the threshold and fail it 60 times
        /// out of 60, and twenty seconds apart is simply what opening two windows looks like.
        /// At 45 the pair still has to be deliberate, and it survives the pause a person takes
        /// between them.
        public static let arousalHalfLife: Double = 45
        public static let arousalWindowOpened: Double = 0.30
        public static let arousalAppSwitched: Double = 0.12
        /// Above this, a signal that would have earned a glance earns a destination instead.
        public static let investigateAbove: Double = 0.45

        /// How long he keeps looking at a thing before his eyes go back to your cursor.
        /// Long enough to read as a look rather than a twitch, short enough that he is not
        /// staring at a window while you move the mouse.
        public static let glanceSeconds: TimeInterval = 1.2

        /// Keystrokes per minute at which he snaps alert and holds still, and the lower
        /// figure he has to fall back to before he relaxes. Two numbers, because one would
        /// flicker him in and out of the pose at every pause for breath.
        ///
        /// 240 kpm is roughly 48 words per minute, which is a person typing rather than a
        /// person poking at a keyboard. `Signals` smooths the rate with a 0.35 EMA already.
        public static let typingAlert: Double = 240
        public static let typingCalm: Double = 140

        /// How long the microphone or the camera has to stay live before he believes it.
        ///
        /// Not zero. Both reads go true the instant *any* process opens the stream, and
        /// `corespeechd` (the always-on "Hey Siri" listener) takes the microphone in bursts well
        /// under a second, which puts a cat in a headset with nobody on the other end.
        ///
        /// Long enough to swallow those bursts, short enough that joining a call still feels
        /// like a reaction. Only the arming is delayed; releasing is instant. See `Settling`.
        public static let deviceSettleSeconds: Double = 1.5

        /// How long your cursor has to sit still, and how close to him, before he comes over.
        ///
        /// `cursorNearby` is a **radius**, not a horizontal gap. Coming over only ever walks him
        /// along the ledge he is already standing on, so a cursor far below him is not somewhere
        /// he can get to: measured across x alone he would shuffle sideways to stand above a
        /// pointer six hundred points down, which is aligned with you rather than next to you.
        public static let cursorStillSeconds: TimeInterval = 60
        public static let cursorNearby: CGFloat = 400
        /// Clearance between his DRAWN edge and your cursor when he settles beside it.
        ///
        /// He must never come to rest ON the cursor. `Overlay.setInteractive` toggles
        /// `ignoresMouseEvents` from exactly one condition, whether the cursor is inside his
        /// hit rect, because Apple's per-pixel alpha hit testing regressed again on 26.5.1.
        /// A cat parked on your cursor is a cat swallowing every click you make.
        ///
        /// Floored by `Shape.hitPad + arrivalSlop`: the click rect reaches `hitPad` past his
        /// ink and the walk overshoots a few points toward its mark, so anything smaller can
        /// settle him with the cursor still inside the rect that eats clicks. Tune by eye upward
        /// only; `theSettleClearanceKeepsTheCursorOutOfTheClickRect` holds the floor.
        public static let cursorGap: CGFloat = 12
        /// How long your cursor has to sit on him before he gets up and moves aside.
        ///
        /// Not zero. Firing on arrival means pointing at him makes him scoot, and since coming
        /// over needs a full minute of stillness, "mouse near cat" always loses that race and
        /// reads as the cat avoiding you. Long enough
        /// to sweep the pointer across him, or to reach for him to pick him up, without him
        /// deciding you wanted the thing underneath.
        public static let yieldPatience: TimeInterval = 1.5

        /// How long he will put up with being behind a window before moving somewhere you can
        /// see him. Long enough that a window raised over him for a moment is not a stampede,
        /// short enough that you do not lose him.
        public static let hiddenPatience: TimeInterval = 10

        /// How far your hand has to move before a press becomes a grab. Below it, releasing
        /// is a pet: the most basic interaction there is, and it must not read as a
        /// scruffing. A real drag starts this many points late, which is imperceptible.
        public static let grabSlop: CGFloat = 4
        /// How hard a pet presses him down, through the same squash a landing uses. Well
        /// under a hard landing's 0.30: a hand is not a floor.
        public static let petSquash: CGFloat = 0.12

        /// **The stroke.** Not a click and not a drag: your cursor moving across his body with
        /// no button down, which is how you pet an actual cat.
        ///
        /// The whole feature is one distinction, and these three numbers are it. His window
        /// swallows clicks while the pointer is inside his hit rect, so a cursor sitting on him
        /// has to move him aside (`yieldPatience`, above) — and a cursor *stroking* him has to
        /// do the opposite. Whether your hand is moving is what tells those apart, and it is
        /// the same distinction that separates `cursorOnHimFor` from `cursorStill`.
        ///
        /// How much of your hand's travel has to bank on him before he gives in. Points, not
        /// seconds, and roughly one sweep across a cat who is drawn about 50 wide.
        ///
        /// **A stroke is ground covered, not motion.** Keying it off "is the pointer moving"
        /// is the obvious thing and it is wrong: a pointer jiggling in place is moving every
        /// single tick, which leaves him sitting under a twitching cursor, eating clicks, now
        /// with his eyes shut. `aJigglingCursorStillGetsHimToMove` holds that line, and the bank
        /// below is what tells the two apart.
        ///
        /// Half a sweep across a cat drawn about 50 wide. A full sweep, against the decay below,
        /// makes a gentle hand take over a second to register.
        public static let strokeSpan: CGFloat = 20
        /// Points per second bled off the bank, which is what makes it a **rate** and not a
        /// total: a jiggle covers ground too, just slowly, so given long enough any pure
        /// accumulator credits it.
        ///
        /// **This is a floor on how fast your hand has to move, and the window is narrower
        /// than it looks.** Below it lies a jiggling pointer at 48pt/s, which must go on
        /// getting him out of your way; above it lies a hand petting a cat.
        ///
        /// Both ends are measured. At 150 a gentle stroke does not merely fail to register, the
        /// yield fires underneath it and he walks out from under the hand; at 90 the cursor has
        /// to be moved aggressively to count. 60 is a quarter above the jiggle, which is a
        /// thinner margin than is comfortable, and it is the honest place for it: the jiggle it
        /// has to beat is a synthetic worst case sustained for twenty seconds, and the hand it
        /// has to admit is a real one. `aGentleStrokeStillCounts` holds 84pt/s.
        public static let strokeDecay: CGFloat = 60
        /// How long your hand may rest on him mid-pet before he opens his eyes. Your hand stops
        /// at the end of every stroke before going back for the next one, so without this he
        /// would blink out of the pose between strokes.
        ///
        /// **Must stay well under `yieldPatience`**, or a cursor parked on him rides out the
        /// grace and he never gets out of the way of your click.
        public static let strokeGrace: TimeInterval = 0.35
        /// The ceiling on the bank, derived rather than tuned so the grace above is the only
        /// knob: exactly enough banked travel to survive one `strokeGrace` of a still hand and
        /// no more. Without a cap a long pet banks minutes of credit and leaves him purring at
        /// a hand that stopped ages ago.
        public static var strokeBank: CGFloat { strokeSpan + strokeDecay * CGFloat(strokeGrace) }

        /// **The purr.** A purr you can physically feel is the detail nobody
        /// forgets, and nothing else on macOS does it.
        ///
        /// A real purr is a continuous ~25Hz flutter and the Taptic engine only gives discrete
        /// taps, so this is a run of taps and the spacing is the whole illusion. **Tuned by
        /// feel on a real trackpad**, which is the only instrument that applies: 0.06 reads as
        /// too slow. 25Hz proper is 0.04 exactly, so this is as close to a real purr as the
        /// hardware goes.
        public static let purrTapInterval: TimeInterval = 0.04
        /// How many taps a click gets. A tap on him is a moment rather than a state, so it
        /// buzzes once and stops; stroking him purrs for as long as your hand keeps going.
        public static let petPurrTaps = 8

        /// `restLeft` drains at `1 + arousal * this`, so a fully roused cat has an idea about
        /// two and a half times sooner.
        public static let restUrgency: Double = 1.5
        /// `inPlaceChance` scales by `1 - arousal * this`, so a roused cat travels rather than
        /// washing. Below 1 on purpose: even at full tilt a wash stays possible.
        public static let travelUrgency: Double = 0.6
    }

    /// Where he goes when nothing has happened: the taste election. Candidates are
    /// scored by six urges and drawn with a temperature, so he leans toward what he likes
    /// and stays unpredictable. Hand-tuned like everything else physical; the two rules
    /// that keep the numbers honest are pinned by `noveltyOutranksHabit` and
    /// `theLoungeWinsBareDesksButNotAlways`.
    public enum Taste {
        /// How opinionated he is. Lower is more compulsive; higher approaches a coin flip.
        /// 0.25 measures out at a choice-vs-dwell divergence of 0.095 on a real desktop, which
        /// is taste you can measure and not quite feel. First knob to turn.
        public static let temperature: Double = 0.18
        /// New furniture stays interesting for minutes, not for a glance. Dominant by
        /// design: a new window must beat any stale, familiar perch.
        public static let wNovelty: Double = 1.0
        public static let noveltyHalfLife: Double = 90
        /// A perch he has not used in a while feels fresh again. This is what rotates him.
        public static let wStale: Double = 0.5
        public static let staleHalfLife: Double = 300
        /// Cats like being up.
        public static let wHeight: Double = 0.3
        /// A mild pull toward you.
        public static let wNear: Double = 0.3
        public static let nearScale: CGFloat = 500
        /// A whisper of habit: a perch he has used before is a perch he trusts.
        public static let wFamiliar: Double = 0.2
        public static let familiarVisits: Double = 3
        /// Walking is work.
        public static let wEffort: Double = 0.4
        public static let effortScale: CGFloat = 800
        /// The null candidate: stay here and lounge. Has to beat a bare floor's typical
        /// stroll score, and by less than a couple of temperatures, or he either paces
        /// for ever or never strolls at all.
        public static let loungeBase: Double = 0.55
        /// A lounge is a spell, not a pose. The rest jitter after it provides the variety.
        public static let loungeSeconds: TimeInterval = 45
        /// Surfaces recorded in the first moments are the world he woke into, and the
        /// launch world is not news. Same rule the window-opened signal follows.
        public static let launchGrace: TimeInterval = 5
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

        /// How long he stays put between ideas. Restraint is the feature: he is still by
        /// default, and most interesting when you are not working.
        ///
        /// OGI_RESTLESS=1 collapses these so his behaviour can actually be watched.
        /// Living with him wants long pauses; testing him does not.
        public static let restMin: TimeInterval = restless ? 0.4 : 3.5
        public static let restJitter: TimeInterval = restless ? 0.8 : 9.0
        /// How long one washing bout lasts. Six lick cycles at the clip's 8fps.
        public static let groomSeconds: TimeInterval = 4.5
        /// How long the wake-up bow and yawn runs. Sized for a 5-frame sheet at 5fps plus a
        /// beat holding its settled last frame; pin it against the clip the way the shake and
        /// the peek are pinned.
        public static let stretchSeconds: TimeInterval = 1.3
        /// Chance an in-place bout of boredom is a stretch rather than a wash. Below half:
        /// the wash stays the commoner idle behaviour.
        public static let stretchChance: Double = 0.25
        /// How long he peers over the lip of the window that was hiding him before pulling
        /// himself up onto it. A good long nosy look: about eight blink-loops of the sheet.
        ///
        /// Long, because the covered-screen retreat makes this the pose you actually see:
        /// swiping to a fullscreen Space surfaces him at the lip within half a second, and the
        /// head is worth leaving up there a while. The same number covers being buried under an
        /// ordinary window, which is the same act.
        public static let peerSeconds: TimeInterval = 12

        /// The event performances. Each non-looping one is floored by its own sheet, the
        /// way the stretch and the shake are, and `theEventPerformancesOutlastTheirSheets`
        /// holds the floors. The zap is a gag and reads quick; the droop decelerates into
        /// lying flat and stays there a while, because running out of battery should look
        /// like running out of battery; the vibe loops for a proper little groove.
        public static let zapSeconds: TimeInterval = 3.5
        /// How long the jolt itself cycles before the recovery: ten passes of the three
        /// buzz frames at the clip's 10fps. Tuned by eye: 0.8 and 1.2 both read as short on
        /// screen against what the arithmetic promised, because a gag holds longer than a
        /// reflex says it should. Every 0.3 here is one more full pass;
        /// `theBuzzLoopsBeforeTheRecovery` holds the relationships.
        public static let zapBuzzSeconds: TimeInterval = 3.0
        public static let vibeSeconds: TimeInterval = 8
        public static let droopSeconds: TimeInterval = 4.2
        public static let curiousSeconds: TimeInterval = 1.6
        /// Chance that a bout of boredom becomes a wash rather than a trip somewhere.
        /// An occasional in-place behaviour is wanted roughly every few minutes,
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

    /// The notch as a place with rules.
    ///
    /// Everything here follows from one fact `World.punchNotch` already encodes: the cutout is a
    /// hole in `solid` sitting **above** the menu bar line, and `notch.minY` IS that line. So he
    /// cannot stand under it, cannot be seen inside it, and can both pass through it and hang
    /// from it with every drawn pixel in live display.
    public enum Notch {
        /// How much of his walking speed he keeps while crossing behind the camera housing.
        /// He is squeezing past hardware, not strolling. Tune by eye: too low reads as lag,
        /// too high loses the squeeze.
        public static let squeezeFactor: CGFloat = 0.6
        /// How long he hangs off the lower lip before he pulls himself back up. Long enough
        /// for two reps of the `hang` sheet's loop plus the lowering-in, so the second rep is
        /// what tells you the first was not a slip.
        public static let hangSeconds: TimeInterval = 4.0
        /// How long he stays draped over the lip looking down at you.
        public static let peerDownSeconds: TimeInterval = 10
        /// Chance that a bout of boredom at a notch lip becomes a hang or a look down rather
        /// than the usual wash. Only reachable standing at a lip, so it is rarer than it looks.
        public static let lipIdeaChance: Double = 0.5
        /// How much sooner he settles while the screen is covered, as a multiple of the whole
        /// idle ladder. Half: asleep in **five** minutes rather than ten, sitting at fifteen
        /// seconds, curled at ninety.
        ///
        /// Not a shortcut — it is the situation being different. With a film up there is
        /// nowhere to go and nothing to look at, the taste election is gated off entirely, and
        /// ten minutes of a cat waiting in a doorway is ten minutes of nothing. Five is roughly
        /// how long it takes to stop fidgeting with the volume and actually watch.
        public static let coveredSlumberScale: Double = 0.5
        /// How far up the cutout's side he grips when he peeks out of a vertical edge, as a
        /// fraction of its height. Two thirds: level with the top of the strip rather than
        /// straddling the menu bar line.
        public static let sidePeekHeight: CGFloat = 0.65
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
        /// A final multiplier on top of the eye-width normalisation, kept at 1: his actual
        /// size comes from `referenceEyeWidth` below, and this is the knob for scaling him
        /// globally without retuning that.
        public static let spriteScale: CGFloat = 1.0
        /// Target on-screen eye width in points. Every clip is scaled to match it, which is
        /// what keeps him the same size whether he is sitting or walking.
        ///
        /// Width alone is only half a measurement, and a handful of sheets drew his eye a
        /// different shape from the rest. Those carry a correction: `Sprites.sheetCorrection`.
        public static let referenceEyeWidth: CGFloat = 2.1
        /// The peer clip's on-screen ink height, its own yardstick because eye-width
        /// normalisation is wrong for a front-facing head-shot: his front-drawn eyes are
        /// stylistically huge, and keying on them rendered the whole peeking head at nine
        /// points. Sized so the head over the lip matches the head on his side-view body;
        /// tune by eye.
        public static let peerHeight: CGFloat = 19
        /// The same yardstick for the two front-facing clips. See `Sprites.frontFacingHeight`.
        ///
        /// `peerDown` is the same subject as `peer` — his head and his two front paws over a
        /// lip — in a squarer band, so it starts near `peerHeight` scaled for the taller frame.
        /// `hang` is a whole cat drawn head-on and stretched out by his own weight, so it is
        /// the tallest thing he ever renders as: longer than his standing height, because a
        /// hanging cat is longer than a standing one.
        ///
        /// Both are tune-by-eye.
        public static let peerDownHeight: CGFloat = 22
        public static let hangHeight: CGFloat = 46
        /// ...and the same yardstick again for the three call sheets, which need it for a
        /// different reason: they have a dark prop drawn on them, and the eye finder picks the
        /// prop. See `Sprites.bandHeight`.
        ///
        /// `callTalk` is a sitting cat and nothing else, so its band is his sitting height.
        /// `callWork` and `callFull` share a band with the laptop beside him, so theirs is a
        /// shade taller for the same cat, and the two must stay equal or he changes size when
        /// you put your headphones on mid-call.
        public static let callTalkHeight: CGFloat = 34
        public static let callDeskHeight: CGFloat = 35
        /// ...and once more for the den, for a third reason: his eyes are *closed*, and the
        /// lids measure 30x22 — wide rather than small in both directions, so eye-width
        /// normalisation renders the whole clip about 30% short: 17pt of tail hanging out of
        /// the notch, which reads as a stub rather than a tail.
        ///
        /// Half the band is tail and half is the body that the cutout masks away, so this is
        /// roughly twice the length of tail you want hanging below the lip.
        public static let denSleepHeight: CGFloat = 50
        /// ...and again for the stroke, for the same reason as the den: a contentedly shut eye
        /// is drawn as one flat curved line, so it measures WIDE and the clip renders short.
        ///
        /// A whole sitting cat in the band, so this is his full drawn height, and it is pinned
        /// against `idle` by `beingPettedDoesNotChangeHisSize` rather than left as a bare
        /// number the way every other height here was.
        ///
        /// **Derived, not guessed.** `idle` renders a sitting cat at 30pt and its band is 99.8%
        /// ink; the stroke's band is 416px holding 393px of cat in its lowest frame, because the
        /// cutter has to crop to the tallest frame and his head goes up. So the same cat wants
        /// `30 * 416/393`. A guess at 44 renders a petted cat half again the size of a sitting
        /// one.
        public static let strokedHeight: CGFloat = 32
        /// How far from a hole in his world he has to stand to be drawn whole. Half his
        /// nominal box, so it covers every pose rather than the one clip that happens to play
        /// there.
        ///
        /// His world has two kinds of hole and both cost him the same way. The **notch** is a
        /// hardware cutout with no pixels behind it: parked centred on its lip he loses
        /// everything past it, which reduces a whole cat to a sliver of tail. The **edges of
        /// the display** are the other: standing at x=5 on a 1920pt screen puts a third of him
        /// off the panel.
        ///
        /// *Moving* through either is fine and is sometimes the point. The launch emergence
        /// comes half out of the notch, and the goodbye walks back into it. Coming to rest
        /// there is what reads as a broken sprite. `reseat` keeps him on screen with the same
        /// half-width.
        public static let clearance: CGFloat = width / 2
        /// How far past his drawn ink a click still counts as touching him. He is a small
        /// target, so the hit rect is padded — and the yield box is built from the same
        /// figure, because the box he moves aside for must be the box that swallows clicks.
        public static let hitPad: CGFloat = 6
        /// Squash depth is proportional to impact speed, capped here.
        public static let maxSquash: CGFloat = 0.30
        /// Ground covered per full gait cycle. Tuned so the paws do not skate.
        ///
        /// One per gait, because a trotting cat covers much more ground per stride than a
        /// strolling one and the gait is cycled off distance: `buildPose` advances the phase by
        /// `speed / stride`, so a stride that is too short cranks the sheet. Sharing the walk's
        /// 30pt runs the 8-frame run sheet at 31.5fps against the 14 it declares (2.25x), a blur
        /// of legs rather than a trot.
        ///
        /// The run figure is `runSpeed * frames / fps`: the stride that makes the sheet play at
        /// the rate it was drawn for. The walk's 30 is hand-tuned rather than derived and leaves
        /// its sheet 8% slow, which is invisible and stops the paws skating;
        /// `eachGaitPlaysAtItsOwnClipsDeclaredRate` holds both against their clips.
        public static let strideLength: CGFloat = 30
        public static let runStrideLength: CGFloat = 67
        /// How much wall one full six-frame `climbUp` cycle covers.
        ///
        /// The sheet is three poses drawn twice rather than six distinct ones, so a full cycle
        /// reads as TWO reaches, which is why this is 55 and not half of it. At 27.5pt
        /// a reach against his 32pt height that is a plausibly long stretch for a climbing cat.
        ///
        /// `Sprites.Clip.climbUp.fps` is derived from this and `clingClimbSpeed`, so the sheet
        /// can never play at a rate the ascent does not match. That is the run-gait trap above:
        /// two numbers that have to agree, written down twice.
        public static let climbStride: CGFloat = 55
        /// Impact speed that produces maxSquash.
        public static let squashReference: CGFloat = 900
    }
}
