import Foundation
import CoreGraphics

/// Where he is anchored, in the coordinate space of the thing he is standing on.
///
/// This is the structural decision the whole app hangs off. Because his world position is
/// *derived* from a surface origin rather than stored, dragging a window makes him surf it
/// with zero code, and "his window closed" becomes a dictionary lookup returning nil.
public struct Perch: Sendable, Equatable {
    public let id: SurfaceID
    /// Offset from the surface's left edge.
    public var dx: CGFloat
    public init(id: SurfaceID, dx: CGFloat) { self.id = id; self.dx = dx }
}

/// Where he is gripping a window's face, in that window's coordinate space.
///
/// Platform-local for exactly the reason `Perch` is, and it inherits the same three
/// properties for nothing: dragging the window carries him, closing it drops him, and the
/// occlusion rule is unchanged because he is in front of that window and behind everything
/// in front of it.
public struct Grip: Sendable, Equatable {
    public let id: SurfaceID
    /// From the window's left edge.
    public var dx: CGFloat
    /// **Down** from the window's top edge. Climbing shrinks this.
    public var dy: CGFloat
    public init(id: SurfaceID, dx: CGFloat, dy: CGFloat) { self.id = id; self.dx = dx; self.dy = dy }
}

public enum Support: Sendable, Equatable {
    case grounded(Perch)
    case falling
    /// Dangling from the cursor. This is what actually happens to cats.
    case held(CGPoint)
    /// Stuck to a window's face, claws in. Cats go up curtains.
    case clinging(Grip)
}

/// What the ground ahead of him looks like. Recomputed every tick, never stored across one.
///
/// This is what the hesitation reads. Without it he has no way to know he is standing next
/// to a drop, and the tell cannot exist.
public struct Footing: Sendable, Equatable {
    /// Distance to the end of solid ground in his facing direction. `.infinity` if he is
    /// not on solid ground, or airborne.
    public var edgeAhead: CGFloat = .infinity
    /// How far down to the next surface past that edge. Nil means there is nothing he could
    /// land on: a wall, or an interior gap, both of which he treats as a wall.
    ///
    /// The two are not told apart here. Nothing outside the tests asks, and dead state on a
    /// struct rebuilt every tick is worse than nothing: `isGap` and `landing` answer both
    /// questions from the world directly.
    public var dropAhead: CGFloat?

    public var isCliff: Bool { dropAhead != nil }
}

public enum Activity: Sendable, Equatable {
    case idle
    case groom      // washing, in place, while awake
    case sit        // no input for a while; cats settle when the room goes quiet
    case curl
    case sleep
    case lounge     // sprawled flat, head up, watching the room: "nothing to do here" as a behaviour
    case stretch    // the wake-up bow and yawn; also an occasional in-place idea
    case peer       // head and paws over the lip of the window that was hiding him
    case zap        // comically electrocuted: power just arrived
    case vibe       // grooving: an audio device just connected
    case droop      // powering down: the battery crossed properly low
    case curious    // head-tilt at a question mark: something plugged into the machine
    case alert      // frozen and listening: the mic went live
    case onCall     // your mic or your camera is live, and he has joined in. See CatState.rig
    case stroked    // your hand is moving over him, no button down: eyes shut, leaning into it
    case hang       // hanging off the notch's lower lip by his front paws, doing reps
    case peerDown   // lying in the notch, head and paws over its lower lip, watching you
    case scruffed   // limp, legs tucked, dangling
    case righting   // the twist, mid-air
    case walk
    case turn       // pivoting on the spot to face the other way
    case peek       // creeping out of the notch, low and cautious
    case edgeLook   // stopped at the lip, head over the side, deciding
    case crouch     // the 100ms wind-up before every jump
    case brace      // riding a window that is being dragged
    case slip       // the ground just went away
    case cling      // gripping a vertical face
    case climb      // going UP one, on purpose
    case airborne
    case land
    case landHard
}

/// One step. Deliberately small: the router picks a new one every time he lands.
public enum Move: Sendable, Equatable {
    /// A world x on the surface he is already standing on.
    case walk(CGFloat)
    /// Crouch, then launch at a point on another surface.
    case jump(SurfaceID, CGFloat)
    /// Walk to the edge ahead and keep going. This is how he descends, on gravity alone.
    case stepOff
    /// A gap small enough to stride over. No crouch, no arc: a full ballistic leap over a
    /// six-point crack between two tiled windows reads as a comedy pratfall.
    case stepAcross(SurfaceID, CGFloat)
    /// Walk under a window's face at this x, then leap at it, grab on the way up and climb.
    /// Cats go up curtains, and this is the only route out of the desktop: `jumpImpulse` buys
    /// 190pt of rise against windows that are routinely five times that tall.
    case climb(SurfaceID, CGFloat)
    /// Walk to the spot on his own surface directly above a lower ledge, look down, and hop
    /// off the glass onto it. The descent a full-width surface could never make: the menu
    /// bar's only lips are the screen corners, so stepping off it walked the whole bar and
    /// dropped a thousand points into a corner. Windows were never stepping stones down.
    case drop(SurfaceID, CGFloat)
    /// Walk in one notch doorway and out the other, to the far lip's x.
    ///
    /// The cutout is a hole in the *display*, not a hole in the *world*: there is real
    /// aluminium behind it at exactly the height of the bar. `solid` excludes it because a cat
    /// standing there is invisible, not because he is unsupported. `World.build` says so where
    /// it punches the hole. So walking through is a truer model of the hardware than falling
    /// through, and it is the only way the two halves of the menu bar were ever going to join up.
    ///
    /// No `SurfaceID`: a crossing never leaves the menu bar, so the parameter every other case
    /// carries would be a constant here.
    case crossNotch(CGFloat)
}

/// Where he is ultimately going, and the current step toward it. Nil means he is content
/// where he is.
///
/// Storing the destination rather than a single hop is what gives multi-hop routing without a
/// pathfinder: he re-picks `move` every time he lands, hill-climbing toward `destination`, and
/// occasionally gets it wrong. The intent is exactly that: "pathfinding is
/// deliberately dumb ... preserve the failure cases; they are where the charm lives."
///
/// **This is the seam the mind layer plugs into.** The mind replaces only the code that
/// chooses a destination. `Cat.nextMove` is final.
public struct Intent: Sendable, Equatable {
    public var destination: SurfaceID
    public var destinationX: CGFloat
    public var move: Move

    public init(destination: SurfaceID, destinationX: CGFloat, move: Move) {
        self.destination = destination
        self.destinationX = destinationX
        self.move = move
    }
}

/// Something the world just did that he might react to.
///
/// Written by `App` on the tick it happens, consumed and cleared by `Cat.step`. One-shot on
/// purpose: a stimulus that survived its tick would fire on every one of the next 120.
public struct Stimulus: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case windowOpened, appSwitched, goHome
    }
    public var kind: Kind
    /// Screen-global, where it happened. This is what his eyes go to.
    public var at: CGPoint

    public init(kind: Kind, at: CGPoint) {
        self.kind = kind
        self.at = at
    }

    /// How much this stirs him up. `goHome` is an instruction rather than a surprise, so it
    /// adds nothing: it does not need the dial and must not be able to reach the threshold
    /// that turns other signals into trips.
    public var weight: Double {
        switch kind {
        case .windowOpened: return Feel.Mind.arousalWindowOpened
        case .appSwitched: return Feel.Mind.arousalAppSwitched
        case .goHome: return 0
        }
    }

    /// Whether this is the kind of thing he will get up and walk over for, given enough
    /// arousal, or only ever the kind of thing he looks at.
    ///
    /// Only new furniture. An app switch is you moving around your own machine rather than the
    /// world changing, and it fires dozens of times an hour against a window's handful, so
    /// letting it promote makes him follow you around: four switches in a row clear the
    /// threshold on their own, and sustained switching pegs arousal at 1 for as long as you
    /// keep working. It still *contributes*, which is the useful part and the legible one. A
    /// window opening while you have been flitting about is worth getting up for; the flitting
    /// on its own is not.
    ///
    /// `goHome` is excluded for the opposite reason: it does not need the gate, and routes
    /// directly below.
    public var canTravel: Bool { kind == .windowOpened }
}

/// How settled he is, from the machine's point of view.
public enum Repose: Sendable, Equatable {
    case awake, sitting, curled, asleep

    /// Cats settle when the room goes quiet.
    public static func from(idleSeconds: Double, scale: Double = Repose.timeScale) -> Repose {
        switch idleSeconds {
        case ..<(30 * scale): return .awake
        case ..<(180 * scale): return .sitting
        case ..<(600 * scale): return .curled
        default: return .asleep
        }
    }

    /// OGI_TIME_SCALE compresses the whole idle ladder. Testing "he stops costing anything
    /// after ten minutes" is otherwise a ten-minute experiment per attempt.
    public static let timeScale: Double = {
        ProcessInfo.processInfo.environment["OGI_TIME_SCALE"].flatMap(Double.init) ?? 1
    }()

    /// The pose he returns to between behaviours at this level of settledness.
    public var restingActivity: Activity {
        switch self {
        case .awake: return .idle
        case .sitting: return .sit
        case .curled: return .curl
        case .asleep: return .sleep
        }
    }

    /// How much longer he waits between ideas. A settled cat is calmer, not switched off:
    /// returning early here makes him a statue at 30 seconds of *your* inactivity, which is
    /// what happens when you sit still and watch him.
    public var restMultiplier: Double {
        switch self {
        case .awake: return 1
        case .sitting: return Feel.Timing.sittingRest
        case .curled: return Feel.Timing.curledRest
        case .asleep: return .infinity
        }
    }

    /// Chance a bout of boredom becomes an in-place behaviour (a wash, a look around)
    /// rather than a trip somewhere.
    public var inPlaceChance: Double {
        switch self {
        case .awake: return Feel.Timing.groomChance
        case .sitting: return Feel.Timing.sittingInPlace
        case .curled: return Feel.Timing.curledInPlace
        case .asleep: return 1
        }
    }
}

/// The one source of chance in the simulation, carried in the state rather than taken from the
/// system at each call site.
///
/// **Why this exists.** Seventeen call sites used to reach for `Double.random` directly, so a
/// run could not be reproduced even from an identical world, and the dozen behavioural tests
/// that measure tendencies (how often he backs off a high drop, how often a bare desk elects
/// the lounge) failed on luck about one full run in twenty. A suite that reddens for no reason
/// trains everyone to ignore it, which is why CI built the package but would not run it.
///
/// SplitMix64: sixty-four bits of state, no warm-up, and good enough for deciding whether a cat
/// washes or looks out of a window. `CatState` seeds itself from the system once at
/// construction, so shipping behaviour is as varied as it ever was; a test sets `roll` and gets
/// the same cat every time.
public struct Roll: RandomNumberGenerator, Sendable, Equatable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

public struct CatState: Sendable {
    /// Every chance he takes, in one reproducible stream.
    ///
    /// **The default is a fixed seed, and that is the whole point.** A default drawn from the
    /// system would leave every test that builds a cat nondeterministic, which is the state
    /// this replaced: the suite failed about one run in twenty on luck alone, so CI would not
    /// run it and `release.sh` aborted roughly one release attempt in thirty for no reason.
    /// Deterministic by default, random only where somebody asks for it, which is `OgiApp` at
    /// launch and nowhere else. See `Roll`.
    public var roll = Roll(seed: 0)

    /// AppKit global, at his feet, on his midline.
    public var position: CGPoint
    public var velocity: CGVector
    public var facing: CGFloat = 1
    public var support: Support = .falling
    public var activity: Activity = .airborne
    public var activityElapsed: TimeInterval = 0

    /// 0 = no squash, 0.30 = a hard landing.
    public var squash: CGFloat = 0
    public var squashElapsed: TimeInterval = 0

    /// Low-passed drift of the surface under him, in points per physics tick.
    /// Positive means his platform is moving right.
    public var drift: CGFloat = 0
    /// Internal to the drift low-pass. Public only because `Cat.step` is a free function.
    public var lastPerchOrigin: CGFloat?
    /// Signed speed along the surface he is standing on, px/s. Zero while airborne.
    /// This is what gives him weight: he winds up into a walk and coasts out of one.
    public var perchSpeed: CGFloat = 0
    /// Which surface `lastPerchOrigin` belongs to. Without this, landing on a new window
    /// measures drift as the distance between two unrelated windows and he braces hard
    /// against a perfectly stationary ledge.
    public var lastPerchID: SurfaceID?

    /// The ground ahead of him. Recomputed each tick by `Cat.step`.
    public var footing = Footing()

    /// -1..1. How hard he is leaning against the motion of his platform.
    public var lean: CGFloat {
        max(-1, min(1, drift / Feel.Physics.driftReference))
    }

    public var intent: Intent?
    /// Seconds of stillness left before he thinks of something to do.
    public var restLeft: TimeInterval = 1.5

    /// Set from the machine each tick. He is a barometer, not a butler: these arrive as
    /// behaviour, never as UI.
    public var repose: Repose = .awake
    /// Frozen and listening because the microphone went live. Also a privacy indicator: if he
    /// has gone rigid, your mic is hot.
    public var listening = false
    /// Your camera is live. The camera lives in the notch, so this is the one signal that can
    /// throw him out of his own house. See `Den.barred`.
    public var onCamera = false
    /// You are typing hard enough that he stays out of your way. Set by `App` with hysteresis
    /// (`Feel.Mind.typingAlert` to enter, `typingCalm` to leave) or he flickers at the boundary.
    public var typingHard = false

    /// Which drawing the call wears, or nil when this is not a call.
    ///
    /// The camera and the microphone are one event seen twice, so they share one pose and one
    /// prop that assembles: a boom mic when you are talking, a laptop when you are on screen,
    /// both when you are properly on a call. Derived rather than stored, so it can never
    /// disagree with the two signals it is made of.
    ///
    /// It also keeps "ears up means your mic is hot" honest: typing keeps the `alert` drawing,
    /// and a live mic does not share it.
    public enum Rig: Sendable, Equatable { case talk, work, full }
    public var rig: Rig? {
        switch (listening, onCamera) {
        case (true, true):   .full
        case (true, false):  .talk
        case (false, true):  .work
        case (false, false): nil
        }
    }

    /// He holds completely still, for any of three reasons.
    ///
    /// One condition rather than three parallel branches, because the behaviour is identical:
    /// stop, keep the trip you were on, and wait. They stay distinguishable to watch, by the
    /// drawing and by how they end: a typing freeze relaxes the moment you pause, a call holds
    /// for the length of it.
    ///
    /// **The camera counts, and not only because of the drawing.** The call sheets have a
    /// laptop drawn into them, so they are only honest on a stationary cat; and a video call is
    /// precisely the moment you do not want something scampering across your windows. Restraint
    /// Restraint argues for it independently of the art.
    ///
    /// **"Still" means he stops travelling, not that nothing moves.** `callTalk` has him
    /// yapping, mouth and head. The invariant that matters is untouched: `perchSpeed` goes to
    /// zero and he walks nowhere. Only his head moves, in place.
    /// A live microphone or camera stops him dead: he is being quiet for you, and the freeze
    /// doubles as a privacy tell.
    ///
    /// **Typing deliberately does NOT, and that is a reversal.** It used to, and it was the
    /// single biggest reason he looked dead on this machine: you are typing most of the time
    /// you are looking at him, so the pose you saw most was the frozen one, on the menu bar,
    /// going nowhere. Hamzah asked for the opposite, in his words "give him full moving
    /// ability".
    ///
    /// `typingHard` is still measured, with hysteresis, in `App.tick`, but nothing reads it
    /// now. Left in place rather than ripped out because it is a real signal that costs one
    /// counter, and the next thing that wants "is he hammering the keyboard" should use it.
    /// If nothing does, delete the whole path rather than leaving it to rot.
    public var holdingStill: Bool { listening || onCamera }

    /// Your cursor, screen-global. Set by `App` each tick, and in practice never nil: he is
    /// pinned to one screen and the global mouse location is always somewhere, so a cursor on
    /// another display still reads as a live point. Multiple displays would need this honest.
    public var cursor: CGPoint?
    /// How long it has sat within a point or two of where it is now. Cats approach when you
    /// go still, and this is the "still" half of that.
    public var cursorStill: TimeInterval = 0
    /// How far through the righting reflex he is, 0..1.
    public var righting: CGFloat = 1
    /// 0..1. Low battery or Low Power Mode. He moves less and settles sooner.
    public var languor: Double = 0

    /// The whole screen is one window right now. Set by `App` from the same signal as the
    /// fullscreen retreat; while it holds, boredom never becomes a trip and a stimulus never
    /// becomes an investigation, so a movie (or a presentation) does not gain a cat
    /// strolling across it. He still glances, still yields, and still answers a retreat.
    public var screenCovered = false

    /// The doorway he calls home, screen-global. Set by `App` each poll (the notch lip, or
    /// under his own menu bar item on a notchless Mac), so the simulation can act on "he
    /// belongs at home" without a stimulus carrying the x every time.
    public var homeX: CGFloat?

    /// His position is inside the cutout: asleep in the den, hanging off its lower lip, or
    /// lying in it looking down over that lip.
    ///
    /// The one place in his world where the ground model and the hardware disagree. `solid`
    /// excludes the notch because a cat standing there is invisible, not because he is
    /// unsupported. There is aluminium behind it at exactly the bar's height.
    ///
    /// **Stored rather than derived from `activity`, and that is not a style choice.** Derived,
    /// every interrupt in `standing` became a trapdoor: the mic going live mid-hang swaps the
    /// activity for `.onCall`, the flag evaporates with it, and the *next* tick's ground test
    /// (which runs before anything that could have caught it) drops a cat out of the notch onto
    /// the desktop, wearing a laptop. The freeze, the yield and the sleep gate all did it. Held
    /// as state, the exemption outlives whatever took the behaviour away, and `standing` puts
    /// him back on the lip in its own time. See `leaveNotch`.
    /// He has already done his one peek out of the den doorway on this visit. Cleared when he
    /// wanders away from the door. Without it the peek re-arms every time it expires, and a
    /// covered screen becomes the same 1.1s animation on repeat.
    public var settledInDen = false

    public var inNotch = false

    /// ...and asleep in there specifically, which is the one that changes the drawing.
    public var inDen: Bool { inNotch && repose == .asleep }

    /// Which edge of the cutout he is hanging off, which decides how the drawing is turned.
    ///
    /// One sheet, three orientations. `below` hangs him off the underside, head down. `left` and
    /// `right` rotate him a quarter turn onto a *vertical* edge, so his paws grip the side of
    /// the hole and his head sticks out sideways into the lit strip of menu bar beside it.
    public enum NotchSide: Sendable, Equatable { case below, left, right }
    public var notchSide: NotchSide = .below

    /// How far above his world position the notch pose is drawn, in points.
    ///
    /// The side peeks grip the cutout's wall well above the menu bar line, and his position
    /// cannot go up there: the `.grounded` branch rewrites `position.y` from the surface on
    /// every tick, so anything stored there is gone before it is drawn. The lift is a property
    /// of the drawing, applied at render time, and it leaves the physics alone: he is still a
    /// cat standing on the bar as far as everything else is concerned.
    public var notchLift: CGFloat = 0

    /// May he still be in there? The three entitlements, in one place, so the check that pulls
    /// him out cannot drift from the branches that put him in.
    public var mayStayInNotch: Bool {
        // About to do one. Waking up in the den owes him a hang instead of a stretch, and the
        // check that pulls him out of the cutout runs *before* the owed show is consumed, so
        // without this he would be hauled onto the lip on the very tick he was going to swing
        // off it.
        if owed == .hang || owed == .peerDown { return true }
        if repose == .asleep { return !onCamera }
        return activity == .hang || activity == .peerDown
    }

    /// Inside the cutout by any route, including passing through it.
    ///
    /// Exactly one thing depends on this (the ground test in the `.grounded` branch) and it
    /// is deliberately a single named condition rather than checks in four places, because what
    /// it means is one idea: the hole in `solid` is a hole in the *display*, not in the *world*,
    /// and while he is in there he is standing on the camera housing.
    public var insideNotch: Bool {
        if inNotch { return true }
        if case .crossNotch = intent?.move { return true }
        return false
    }

    /// A performance is owed: the wake-up stretch, or one of the machine-event pieces (the
    /// zap, the groove, the power-down, the curious look). Set by `App` on the edges only
    /// it can see, consumed by `standing` once he is grounded, free and calm, so a hot
    /// mic holds the show until the call ends rather than eating it. One slot deep: a
    /// later event replaces an unplayed earlier one, which at these frequencies is
    /// nothing.
    public var owed: Activity?

    /// What he remembers about a place. Session-only by design: quit and he forgets, which
    /// is the product call that keeps the README's uninstall promise intact.
    public struct Place: Sendable, Equatable {
        /// When it appeared. `-infinity` for the world he woke into, which is never novel.
        public var firstSeen: TimeInterval
        /// When he last stood on it. `-infinity` until he has.
        public var lastVisit: TimeInterval = -.infinity
        public var visits = 0
        public init(firstSeen: TimeInterval) { self.firstSeen = firstSeen }
    }
    /// Total simulated time. The clock his memory is written against.
    public var age: TimeInterval = 0
    /// The taste layer's memory of places, keyed by surface. Written by `Cat.step`.
    public var memory: [SurfaceID: Place] = [:]
    /// The surface the current visit was counted for, so sitting still is one visit.
    public var lastVisitedID: SurfaceID?

    /// 0...1. How stirred up he is. Rises when something happens, decays with quiet.
    ///
    /// Two invariants hold this honest, and both are tested:
    /// - it never reaches `Repose.from` or the slumber gate, so the sleep ladder stays driven
    ///   by YOUR idle time and the zero-wakeup guarantee cannot be touched from here
    /// - at zero he behaves exactly as he would with no mind at all, so every behaviour test
    ///   that ignores arousal stays valid
    public var arousal: Double = 0

    /// Something the world just did. Written by `App` through `receive`, consumed and
    /// cleared by `Cat.step`.
    public var stimulus: Stimulus?

    /// Deliver a stimulus without letting it eat a pending retreat.
    ///
    /// The slot is one deep, and `goHome` is an instruction rather than a surprise: an app
    /// activation or a window appearing between the retreat being written and the next tick
    /// must not replace it, and apps activate precisely when something goes fullscreen or
    /// the machine sleeps, which is exactly when retreats are written. A lost glance is
    /// nothing; a lost retreat is the fullscreen retreat or the pre-sleep settle silently
    /// not happening, the two behaviours hardest to catch not happening.
    public mutating func receive(_ stim: Stimulus) {
        guard stimulus?.kind != .goHome || stim.kind == .goHome else { return }
        stimulus = stim
    }

    /// Where he is looking, when it is not at your cursor. `App` renders the gaze at
    /// `lookingAt ?? NSEvent.mouseLocation`, so nil means "back to watching you".
    ///
    /// Here rather than in `App` so that the glance is part of the simulation and can be
    /// tested.
    public var lookingAt: CGPoint?
    /// Seconds of glance left. Internal to the glance; public only because `Cat.step` is free.
    public var glanceLeft: TimeInterval = 0

    /// How long he has been somewhere you cannot see him. He wants to be seen: a cat behind a
    /// window is a cat doing nothing, however good the thing he is doing.
    public var hiddenFor: TimeInterval = 0

    /// How long your cursor has been ON him, which is not the same question as how long it has
    /// been still. `cursorStill` cannot stand in: a pointer jiggling in place resets it for
    /// ever, so he sits under it swallowing clicks and never decides he is in the way.
    public var cursorOnHimFor: TimeInterval = 0

    /// Points of your hand's travel banked on him, bleeding away at `Feel.Mind.strokeDecay`.
    /// Resets outright when your hand leaves him.
    ///
    /// Bleeding rather than resetting is what makes the pause at the end of each stroke
    /// survivable; resetting on the way out is what stops the bank from following your hand
    /// across the screen and re-arming the moment it brushes him again.
    public var strokeTravel: CGFloat = 0
    /// Where your hand was last tick, so the bank can be fed a distance. Nil when it is not
    /// on him, which is also how the first tick of contact is kept from banking the whole
    /// jump from wherever the pointer was before.
    public var lastCursor: CGPoint?
    /// Your hand is on him and covering ground. See `Feel.Mind.strokeSpan`.
    public var beingStroked: Bool { strokeTravel >= Feel.Mind.strokeSpan }

    /// The rect he was actually drawn in last frame, screen-global. Set by `App` each render;
    /// nil until the first one. The sprite is normalised on eye width and is usually larger
    /// than the nominal `Feel.Shape` figure, and the yield has to measure the box that
    /// actually swallows clicks, not the one that is convenient to compute.
    public var drawnBox: CGRect?
    /// Covering a long distance, so he trots instead of strolling.
    public var hurrying = false

    public init(position: CGPoint, velocity: CGVector = .zero) {
        self.position = position
        self.velocity = velocity
    }

    /// Drives the render-rate ladder. When this is false he must cost essentially nothing:
    /// the battery complaint about desktop pets is about wakeups, not pixels.
    public var isMoving: Bool {
        if case .falling = support { return true }
        // He scrabbles, then slides. Always a bounded state (he mantles onto the ledge or
        // runs out of wall), so this cannot hold the render rate up indefinitely.
        if case .clinging = support { return true }
        // A show is motion: the zap's tremble at a settled cat's 8-12Hz render rate is a
        // slideshow. Bounded by each show's own hold, so it cannot pin the link.
        if Cat.isShow(activity) { return true }
        // Being petted breathes, and at a settled cat's 4Hz a breath is a slideshow. Bounded by
        // your hand rather than by a clock: stop stroking and the pose ends within a grace.
        if activity == .stroked { return true }
        // The intent SURVIVES a freeze by design, so that a hot mic at launch cannot destroy
        // the walk out of the notch. Without this clause that same design would pin the display
        // link at 60Hz for the length of every call, which is a far worse bug than the one it
        // fixes. Deliberately below the two airborne cases: a frozen cat in mid-air is still
        // falling and still has to be drawn.
        if holdingStill { return false }
        if intent != nil { return true }
        return squashElapsed < 0.4
    }

    /// He is settled and nothing is going to change until the world does.
    public var isResting: Bool {
        !isMoving && (repose != .awake || holdingStill)
    }

    /// Anisotropic scale about the contact point. Vertical squash, horizontal spread.
    /// `pow(1/sy, 0.85)` rather than true volume preservation, which over-widens into a puddle.
    public var scale: CGSize {
        let envelope = exp(-squashElapsed * 18) * cos(squashElapsed * 22)
        let sy = 1 - squash * envelope
        guard sy > 0.01 else { return CGSize(width: 1, height: 1) }
        return CGSize(width: pow(1 / sy, 0.85), height: sy)
    }
}

public enum Cat {

    /// The entire physics and state machine, as one pure function over value types.
    public static func step(_ state: CatState, world: Skyline, dt: TimeInterval) -> CatState {
        var s = step(inner: state, world: world, dt: dt)
        // A clip has to start at its first frame, and several places assign `activity` without
        // thinking about the clock (the settled branch reassigns it every single tick). Without
        // this, a non-looping clip like `sitdown` or `curl` is handed however long he has been
        // idle and snaps straight to its last frame, so it never plays at all.
        if s.activity != state.activity { s.activityElapsed = 0 }
        return s
    }

    private static func step(inner state: CatState, world: Skyline, dt: TimeInterval) -> CatState {
        var s = state
        s.activityElapsed += dt
        s.squashElapsed += dt
        s.age += dt
        // The taste layer's memory. Recorded here rather than at the election, or a window
        // opened while he was busy would read as brand new an hour later. Costs nothing on
        // the ticks where no surface is new.
        for fresh in world.surfaces where s.memory[fresh.id] == nil {
            s.memory[fresh.id] = CatState.Place(
                firstSeen: s.age < Feel.Taste.launchGrace ? -.infinity : s.age)
        }
        if case .grounded(let p) = s.support, var place = s.memory[p.id] {
            place.lastVisit = s.age
            if s.lastVisitedID != p.id { place.visits += 1; s.lastVisitedID = p.id }
            s.memory[p.id] = place
        }
        s.arousal = max(0, min(1, s.arousal * pow(0.5, dt / Feel.Mind.arousalHalfLife)))
        // How long you have not been able to see him. Counted here rather than in the branch
        // that acts on it, so that time spent hidden while walking somewhere still counts.
        s.hiddenFor = isHidden(s, world: world) ? s.hiddenFor + dt : 0
        let handOnHim = s.cursor.map { hisBox(s).contains($0) } == true
        s.cursorOnHimFor = handOnHim ? s.cursorOnHimFor + dt : 0
        // ...and how much ground that hand is covering ON him, which is the whole of the
        // stroke. Fed a distance and bled at a rate, so what it really measures is how fast
        // your hand is moving over him: fast enough is a pet, and everything slower (a jiggle,
        // a pointer drifting to rest) never fills it.
        if handOnHim, let cursor = s.cursor {
            let moved = s.lastCursor.map { hypot(cursor.x - $0.x, cursor.y - $0.y) } ?? 0
            s.strokeTravel = min(max(0, s.strokeTravel + moved - Feel.Mind.strokeDecay * CGFloat(dt)),
                                 Feel.Mind.strokeBank)
            s.lastCursor = cursor
        } else {
            s.strokeTravel = 0
            s.lastCursor = nil
        }

        // A glance is a one-shot: consumed here, cleared, and never written back, so it cannot
        // re-fire on the next 120 ticks. The gaze is `App`'s only read of this.
        if let stim = s.stimulus {
            s.stimulus = nil
            s.arousal = min(1, s.arousal + stim.weight)
            s.lookingAt = stim.at
            s.glanceLeft = Feel.Mind.glanceSeconds

            // Perk up, visibly. Moving his eyes is the whole of a glance in code and almost
            // none of it on screen: at his rendered size the gaze is a couple of points of
            // pupil, so "he noticed the window you opened" reads as him doing nothing at all.
            //
            // Only when he is standing around. A cat already walking somewhere just flicks his
            // eyes, and snapping the pose mid-walk would stop him dead for a beat. `holdingStill`
            // outranks this for the same reason it outranks everything else.
            // ...and never mid-show. Plugging a charger flashes a transient charging window
            // on macOS, so unguarded this perk kills the zap a beat after it begins. The
            // glance's cheap half (eyes, arousal) still happens above.
            if stim.canTravel, s.intent == nil, !s.holdingStill, !isShow(s.activity),
               case .grounded = s.support {
                s.activity = .alert
                s.activityElapsed = 0
            }

            // Home is not a suggestion. It routes to the menu bar directly rather than through
            // the arousal gate, and it is allowed to replace an intent, because whatever he was
            // doing is on furniture that is about to be gone or covered.
            //
            // If he cannot reach it, no intent forms and he settles where he is. From the floor
            // the notch is 1115pt up against 190pt of rise and inventing a route would be
            // inventing physics, so the honest outcome is that he sprawls on the desktop, which
            // is a behaviour in its own right and the one wanted on a bare
            // screen anyway.
            if stim.kind == .goHome, case .grounded(let perch) = s.support,
               let here = world.surface(perch.id),
               let move = nextMove(from: s, on: here, toward: .menuBar, x: stim.at.x,
                                   world: world) {
                s.intent = Intent(destination: .menuBar, destinationX: stim.at.x, move: move)
                if case .jump = move { s.activity = .crouch } else { s.activity = .walk }
                s.activityElapsed = 0
            }

            // ...and if he is stirred up enough, he goes and has a proper look.
            //
            // The bump is applied BEFORE this test, so the event that crosses the line is the
            // one that acts on it. Tested first, a signal could never respond to itself and the
            // SECOND window in a burst would be the one that moved him, which reads as a
            // delayed reaction to the wrong thing.
            //
            // Never while he already has an intent: a trip that every new window re-targets is
            // a trip he never finishes. He still looks, which is the whole point of the glance
            // being the cheap half.
            // ...unless the screen is covered, in which case looking is the whole of it:
            // a floating panel over fullscreen video is a real stimulus, and crossing the
            // movie to sniff it is exactly what `screenCovered` exists to refuse.
            if stim.canTravel, s.arousal >= Feel.Mind.investigateAbove, s.intent == nil,
               !s.screenCovered, !isShow(s.activity),
               case .grounded(let perch) = s.support,
               let here = world.surface(perch.id),
               let dest = surfaceAt(stim.at, in: world),
               let x = standingRoom(near: stim.at.x, in: dest.spans),
               let move = nextMove(from: s, on: here, toward: dest.id, x: x, world: world) {
                s.intent = Intent(destination: dest.id, destinationX: x, move: move)
                if case .jump = move { s.activity = .crouch } else { s.activity = .walk }
                s.activityElapsed = 0
            }
        }
        if s.glanceLeft > 0 {
            s.glanceLeft -= dt
            if s.glanceLeft <= 0 { s.lookingAt = nil }
        }
        // Never carried across a tick. Cleared here rather than in each of the branches that
        // leaves the ground, because two of them (the vanished platform, the shrunken window)
        // return before the grounded branch ever gets to recompute it, and a cat one tick into
        // a fall would still be reporting the ledge he just lost.
        s.footing = Footing()

        switch s.support {
        case .held(let point):
            // Limp. Legs tucked, no physics: he is not falling, he is being carried.
            s.position = point
            s.velocity = .zero
            s.activity = .scruffed
            s.intent = nil
            s.drift = 0
            s.perchSpeed = 0
            s.lastPerchOrigin = nil
            return s

        case .clinging(var grip):
            guard let surface = world.surface(grip.id), let rect = surface.rect else {
                // The window went away under his claws.
                s.support = .falling
                s.activity = .slip
                s.activityElapsed = 0
                return s
            }
            // Sticky once he has committed to going up. Re-asserting `.cling` unconditionally
            // flips the activity back and forth every tick, and since a changed activity
            // zeroes `activityElapsed`, the hold below restarts forever and he never leaves
            // the spot he grabbed.
            if s.activity != .climb { s.activity = .cling }
            s.velocity = .zero
            s.perchSpeed = 0

            // The hold is the "oh no" beat before he decides. Once he has decided it is spent,
            // which is why committing is part of the condition rather than only the clock: the
            // clock restarts when the activity changes, and asking it again would put him back
            // in the beat he just came out of.
            if s.activity == .climb || s.activityElapsed > Feel.Timing.clingHold {
                // Where the slide would actually put him down: the BOTTOM of the face, not
                // wherever he happens to be hanging. It carries him all the way there and lets
                // go, straight past anything in between, because a clinging cat is never
                // tested against the ground.
                //
                // Asking at his live grip point instead is not merely imprecise, it does not
                // terminate: the answer flips at every intervening window's top edge, and the
                // two branches move him in opposite directions across it, so he saws inside a
                // one-point band for ever. Measured from the bottom edge the question does not
                // depend on `grip.dy` at all, so no such band can exist.
                let at = CGPoint(x: rect.minX + grip.dx, y: rect.minY)
                // He grabbed this face on purpose, so he goes up it whatever is underneath.
                // Without this the whole route is a cycle: he leaps at a window from the
                // desktop, grips it near the bottom, sees perfectly visible floor below him
                // and slides straight back down to start again.
                if grip.dy <= Feel.Physics.mantleReach || climbing(s, grip.id)
                    || !landsInView(at, world: world) {
                    // Close enough to the top, or letting go would put him down somewhere
                    // nobody could see him. Either way the only way is up: he climbs and
                    // mantles onto the ledge.
                    grip.dy -= Feel.Physics.clingClimbSpeed * CGFloat(dt)
                    // Going up on purpose, which is a different animal from hanging on. The
                    // `cling` sheet was drawn as a moment, a cat scrabbling with its ears back,
                    // and a full ascent of a fullscreen face ran it unbroken for up to 10.8s.
                    // The hold before he decides, and the slide when he cannot hold, both stay
                    // on `cling`, which is exactly what it was drawn for.
                    s.activity = .climb
                    if grip.dy <= 0 {
                        // The column he climbed is not necessarily somewhere he can stand: a
                        // top edge is inset by the corner radius and clipped to the visible
                        // screen, so a grip in the top corner mantles onto nothing. He gets
                        // pulled along the lip to the nearest place that is real, and if the
                        // whole edge is unstandable there is nothing to mantle onto, so he
                        // lets go. Without this he grounds for exactly one tick and the
                        // shrunken-window backstop below drops him straight off again.
                        guard let x = nearestSpanX(to: rect.minX + grip.dx, in: surface.solid) else {
                            s.support = .falling
                            s.activity = .slip
                            s.activityElapsed = 0
                            return s
                        }
                        s.support = .grounded(Perch(id: grip.id, dx: x - surface.extent.lowerBound))
                        s.position = CGPoint(x: x, y: surface.y)
                        s.activity = .land
                        s.activityElapsed = 0
                        // Re-plan from the ledge he just pulled himself onto, exactly as a
                        // landing does. A deliberate climb keeps its intent all the way up the
                        // face (that is what tells the branch above to climb rather than slide),
                        // so without this he arrives on the window he was climbing with
                        // `.climb` still on the intent and immediately throws himself at it
                        // again.
                        if let intent = s.intent {
                            let next = nextMove(from: s, on: surface, toward: intent.destination,
                                                x: intent.destinationX, world: world)
                            s.intent?.move = next ?? .walk(s.position.x)
                        }
                        return s
                    }
                } else {
                    grip.dy += Feel.Physics.clingSlideSpeed * CGFloat(dt)
                    if grip.dy >= rect.height {
                        // Out of wall. He lets go.
                        s.support = .falling
                        s.activity = .slip
                        s.activityElapsed = 0
                        return s
                    }
                }
            }
            // World position is derived, so dragging the window carries him. Free, exactly
            // as it is for a perch.
            s.position = CGPoint(x: rect.minX + grip.dx, y: surface.y - grip.dy)
            s.support = .clinging(grip)
            return s

        case .grounded(let perch):
            guard let surface = world.surface(perch.id) else {
                // His platform vanished. This is the demo.
                s.support = .falling
                s.activity = .slip
                s.activityElapsed = 0
                s.velocity = CGVector(dx: s.facing * Feel.Physics.slipKick, dy: 0)
                s.drift = 0
                s.lastPerchOrigin = nil
                return s
            }
            // The window shrank out from under him. A backstop: walking off is handled at
            // the edge itself, below, so what reaches this is a surface that moved rather
            // than a cat that did.
            let standingOn = surface.extent.lowerBound + perch.dx
            // `insideNotch` is the one exemption: the cutout is a hole in `solid` because
            // nothing drawn there is visible, and this test would therefore drop a cat who is
            // asleep in his den or halfway through the tunnel onto the desktop below.
            guard s.insideNotch || surface.solid.contains(where: { $0.contains(standingOn) }) else {
                s.support = .falling
                s.activity = .slip
                s.activityElapsed = 0
                // The one thing that reaches here is a window being resize-dragged, which is
                // exactly when drift is non-zero. Without this he falls through the air still
                // braced against a window he is no longer standing on.
                s.drift = 0
                s.lastPerchOrigin = nil
                return s
            }
            // What the ground ahead looks like. The tell reads this. It has to come from the
            // same rule the fall-off branch uses, not from `supportBelow` on its own: there is
            // a floor under the notch, so a drop measured directly reports a thousand-point
            // cliff at a hole he must never step into.
            // Computed before he decides anything, so the routing and the tell both read the
            // ground he is deciding from rather than the ground he has already stepped onto.
            if let edge = edgeAhead(from: standingOn, facing: s.facing, on: surface) {
                s.footing.edgeAhead = abs(edge - standingOn)
                if let below = landing(past: edge, facing: s.facing, on: surface, world: world) {
                    s.footing.dropAhead = surface.y - below.y
                }
            }

            // World position is derived. Surfing is free: he is already being carried.
            // What this measures is his *reaction* to being carried.
            //
            // The origin arrives as a ~100ms staircase from the world poll, so per-tick
            // drift is zero on most ticks and a big step on the others. Low-pass it hard
            // rather than differentiating, which would produce spikes.
            let origin = surface.extent.lowerBound
            let sameSurface = s.lastPerchID == perch.id
            let step = sameSurface ? origin - (s.lastPerchOrigin ?? origin) : 0
            if !sameSurface { s.drift = 0 }
            s.lastPerchOrigin = origin
            s.lastPerchID = perch.id
            s.drift += (step - s.drift) * Feel.Physics.driftSmoothing

            s.position = CGPoint(x: origin + perch.dx, y: surface.y)
            s.velocity = .zero
            s = ground(s, on: surface, world: world, dt: dt)
            // The other two ways off the ground. `ground` decides to walk off a cliff or to
            // launch a jump, and both leave through here rather than through the branch above,
            // so the ledge he was measuring against a moment ago is gone and the reading with
            // it. Clearing after the decision keeps the pre-decision ground the router reads.
            if case .falling = s.support { s.footing = Footing() }

            // Braced against the motion. He is standing on a moving object.
            //
            // It only ever swaps the pose he is WAITING in for a braced one. This sits outside
            // `ground`, so it runs after every hold `standing` just set, and unconditional it
            // overwrote all of them: the landing shake (and once activity is `.brace`,
            // `landingHold` returns nil, so the hold that keeps the shake on screen stops
            // existing), the pivot on the tick it was set, the wash, and the alert. A sleeping
            // cat is excluded outright: `.brace` draws the alert sheet, so he sat bolt upright
            // on a dragged window and then slumbered in it.
            if s.intent == nil, s.repose != .asleep {
                let braced = abs(s.lean) > Feel.Physics.braceThreshold
                if braced, s.activity == s.repose.restingActivity {
                    s.activity = .brace
                } else if !braced, s.activity == .brace {
                    s.activity = s.repose.restingActivity
                }
            }

        case .falling:
            // Nothing to push against. Whatever he was carrying along the ledge is spent on
            // the way over the lip, and `velocity` is the only thing moving him now.
            s.perchSpeed = 0
            s.velocity.dy = max(s.velocity.dy - Feel.Physics.gravity * dt,
                                -Feel.Physics.terminalVelocity)
            let y0 = s.position.y
            let y1 = y0 + s.velocity.dy * dt
            // The world has hard sides, and this is the only place he can reach them: every
            // surface's `solid` is clipped to the visible frame, so one point outside it there
            // is nothing under him at ANY height. `supportBelow` returns nil for ever, `isMoving`
            // pins the display link at 60Hz, `enterSlumber` becomes unreachable and he is gone
            // for the session, the whole idle-cost claim with him.
            //
            // Deliberately a catch-all rather than a fix to whichever aim let him out. `aimX`
            // is *supposed* to be able to sail past a far lip (see the margin there), a throw
            // can do it at 1500 px/s, and both must keep working; what must not survive is
            // leaving the world at all. Falling short of an interior lip and having to climb
            // back is untouched, because there is always something below one.
            //
            // Inset by `clearance`, the same margin every surface's `solid` uses, so that
            // being caught by this wall leaves him drawn WHOLE rather than merely on the
            // desktop: pinned flush to `visibleFrame.minX` he lands with a third of himself
            // off the panel, which is the same defect as standing on the screen's edge.
            let bounds = world.screen.visibleFrame.insetBy(dx: Feel.Shape.clearance, dy: 0)
            let x = min(max(s.position.x + s.velocity.dx * dt, bounds.minX), bounds.maxX)

            // The second way into `.clinging`, and the only one that is not a release.
            //
            // `velocity.dy > 0` is the whole of why it is safe. This branch's hard rule is that
            // cling entry is on release only and never on a general fall, because sticking to
            // the first window a descent passes would break the fall, and the fall is this
            // app's entire demo. **A fall is always descending.** A grab gated on rising cannot
            // touch one, at any speed, from any height, with any intent live.
            //
            // Gated on the INTENT as well, not on the geometry alone: an ordinary jump whose
            // arc happens to rise through a window's face has to sail straight through it. He
            // must have set out to climb this particular window.
            //
            // The intent is deliberately NOT cleared. It is what tells the `.clinging` branch
            // he is here on purpose and should climb rather than slide, and it is what he
            // re-plans from once he mantles over the top.
            if s.velocity.dy > 0, case .climb(let id, _)? = s.intent?.move,
               let face = world.surface(id), let rect = face.rect,
               rect.contains(CGPoint(x: x, y: y1)) {
                s.support = .clinging(Grip(id: id, dx: x - rect.minX, dy: face.y - y1))
                s.position = CGPoint(x: x, y: y1)
                s.velocity = .zero
                s.activity = .cling
                s.activityElapsed = 0
                return s
            }

            // The world has a hard bottom as well as hard sides, and a fall can START
            // beneath it: a release over the Dock strip puts him below the floor line (the
            // floor is the TOP of a pinned Dock, and the cursor goes lower than that), and
            // `supportBelow` only ever searches downward, so no sweep from there can catch
            // anything. That is the same fatal exit as the sides (gone for the session,
            // display link pinned), so it gets the same catch-all: a descent already under
            // the floor lands ON the floor, which reads as landing on the Dock shelf.
            // Ordinary falls are untouched, because for them y0 starts above the floor and
            // the sweep catches the crossing.
            let underworld = world.surfaces.first { $0.id == .floor && y0 < $0.y }
            if s.velocity.dy < 0,
               let hit = world.supportBelow(x: x, from: y0, to: y1) ?? underworld {
                let impact = abs(s.velocity.dy)
                s.position = CGPoint(x: x, y: hit.y)
                s.support = .grounded(Perch(id: hit.id, dx: x - hit.extent.lowerBound))
                s.velocity = .zero
                s.squash = min(impact / Feel.Shape.squashReference, 1) * Feel.Shape.maxSquash
                s.squashElapsed = 0
                s.activity = impact > Feel.Physics.hardLanding ? .landHard : .land
                s.activityElapsed = 0
                s.righting = 1
                // Re-plan from where he actually landed, not from where he meant to. Asking
                // again on every landing is the entire routing mechanism: one hop of lookahead,
                // repeated, hill-climbs toward a destination without a pathfinder, and a hop
                // he fluffed simply becomes the new starting point rather than a dead end.
                if let intent = s.intent, let surface = world.surface(hit.id) {
                    let next = nextMove(from: s, on: surface, toward: intent.destination,
                                        x: intent.destinationX, world: world)
                    s.intent?.move = next ?? .walk(s.position.x)
                }
            } else {
                s.position = CGPoint(x: x, y: y1)
                // The righting reflex. He twists, gets his feet under him, and lands on
                // four paws every single time, by construction, not by luck.
                // The twist itself finishes long before he lands, but he stays in `.righting`
                // for the whole descent: it draws the same sheet as `.slip`, and staying put
                // means the clip is never restarted underneath him.
                if s.righting < 1 {
                    s.righting = min(1, s.righting + CGFloat(dt) / CGFloat(Feel.Timing.righting))
                }
                // He stays in `.slip` until he lands. The fall sheet does not loop: it runs
                // its six frames and holds the last one, braced for impact, which is exactly
                // what a long descent wants. Timing out into `.airborne` would play the jump
                // sheet for the whole rest of the drop.
            }
        }

        // Settle out of landing back into whatever pose matches how settled he is. Hard-coding
        // `.idle` here made a curled cat render exactly one frame standing before the next tick
        // corrected him.
        if let hold = landingHold(s.activity), s.activityElapsed > hold {
            s.activity = s.repose.restingActivity
            s.activityElapsed = 0
        }
        return s
    }

    /// Would letting go from here put him down somewhere he can actually be seen?
    ///
    /// This is the whole of the climb-or-slide rule, and it deliberately never asks whether
    /// anything is fullscreen. `spans` already answers exactly this question (it is `solid`
    /// minus everything drawn in front of it), so under a fullscreen window the floor has no
    /// span beneath his grip and he climbs, while a window merely floating above the desktop
    /// leaves the desktop visible and he still slides down it. It degrades the right way for
    /// a maximized-but-not-fullscreen window for the same reason, with no third case.
    ///
    /// Nothing below him at all is also "no", and for the same reason rather than by accident:
    /// letting go there is a fall out of the world.
    static func landsInView(_ p: CGPoint, world: Skyline) -> Bool {
        guard let below = world.supportBelow(x: p.x, from: p.y, to: -.greatestFiniteMagnitude)
        else { return false }
        return below.spans.contains { $0.contains(p.x) }
    }

    /// A tap, not a grab. He responds (the first rule of being touched, "he has to respond or
    /// he is scenery") with the two things his body can already do: a small press-down
    /// through the same squash a landing uses, and the alert perk held for a glance's beat,
    /// eyes to your hand. He stays exactly where he is: a pet must never move him, or
    /// clicking him becomes a way to lose him.
    ///
    /// Mid-air and mid-carry are untouched, and a pet mid-walk is just the press: snapping
    /// the pose would stop him dead, the same reason the glance does not interrupt a walk.
    public static func pet(_ state: CatState, at point: CGPoint) -> CatState {
        guard case .grounded = state.support else { return state }
        var s = state
        s.squash = Feel.Mind.petSquash
        s.squashElapsed = 0
        s.lookingAt = point
        s.glanceLeft = Feel.Mind.glanceSeconds
        if !s.holdingStill, s.intent == nil {
            s.activity = .alert
            s.activityElapsed = 0
        }
        return s
    }

    /// Picked up. He goes limp rather than struggling, because that is what cats do.
    public static func grab(_ state: CatState, at point: CGPoint) -> CatState {
        var s = state
        s.support = .held(point)
        s.activity = .scruffed
        s.activityElapsed = 0
        s.intent = nil
        // Picking him up takes him out of the notch, and these have to say so.
        //
        // They used to survive the whole carry: the `.held` branch returns early and
        // `standing` bails unless he is `.grounded`, so nothing on the path cleared them. Two
        // things followed. `Overlay` applies `notchLift` unconditionally, so he dangled ~25pt
        // above the cursor the entire time it was set. And on touchdown `standing`'s first act
        // is `leaveNotch`, which fired against whatever he had landed on and repositioned him
        // to the notch lip: released at x=300, standing at x=1086 two seconds later.
        //
        // The sibling rotation two lines down in `Overlay.apply` is already gated on the frame
        // for exactly this reason, with the note that the flag outlives the pose it belongs
        // to. Same hazard, and `notchLift` was missed.
        s.inNotch = false
        s.notchSide = .below
        s.notchLift = 0
        return s
    }

    /// Let go. If he is over a window's face he grabs it; otherwise he twists, rights
    /// himself, and lands on his feet.
    ///
    /// **Where he is decides it, not how fast he was going.** A cat thrown at a curtain grabs
    /// the curtain, which is the whole reason the cling exists. A speed guard here would make
    /// the feature unreachable: release velocity comes from the last ~100ms of drag, so 20pt
    /// of hand movement already reads as 200 px/s and every real drop sails past the face,
    /// leaving only a dead stop able to grab. A threshold is the worst of both anyway, since
    /// grabbing at 190 and throwing at 210 is less predictable than either rule applied
    /// consistently.
    ///
    /// **Entry is on release only, deliberately.** Clinging on any fall past any window
    /// would stop every descent at the first window it passed, and the fall is the app's
    /// entire demo.
    public static func release(_ state: CatState, throwVelocity v: CGVector,
                               world: Skyline) -> CatState {
        var s = state
        if let face = world.faceContaining(s.position) {
            s.support = .clinging(Grip(id: face.id,
                                       dx: s.position.x - (face.rect?.minX ?? 0),
                                       dy: face.y - s.position.y))
            s.activity = .cling
            s.activityElapsed = 0
            s.velocity = .zero
            s.intent = nil
            return s
        }
        s.support = .falling
        s.velocity = CGVector(dx: max(-Feel.Physics.maxThrow, min(Feel.Physics.maxThrow, v.dx)),
                              dy: max(-Feel.Physics.maxThrow, min(Feel.Physics.maxThrow, v.dy)))
        s.activity = .righting
        s.activityElapsed = 0
        s.righting = 0
        s.facing = v.dx >= 0 ? 1 : -1
        return s
    }

    // MARK: - On the ground

    /// He does not flip like a sprite. Anything that reverses him on solid ground pivots first,
    /// and everything else waits the pivot out.
    ///
    /// One check around the whole of `standing` rather than one at each of the five places that
    /// assign `facing` (the walk, the plant at a lip, the retreat off one, the wall turn, the
    /// stride across a crack), because four of those `return` early, and because a sixth cannot
    /// then be added without it. It reads the facing he came in with against the facing he
    /// leaves with, so a *set* to the direction he already faces is correctly not a turn.
    ///
    /// Deliberately not applied to `release` (mid-air, from a throw) or to the jump launch:
    /// both end with him off the ground, and `case .grounded` is what excludes them. There is
    /// nothing under his paws to pivot on, and the fall sheet carries the reversal anyway.
    private static func ground(_ state: CatState, on surface: Surface,
                               world: Skyline, dt: TimeInterval) -> CatState {
        var s = standing(state, on: surface, world: world, dt: dt)
        if s.facing != state.facing, case .grounded = s.support {
            s.activity = .turn
            // Reset here rather than leaning on `step`'s change-detect, which only fires when
            // the activity DIFFERS from the one this tick started with. A flip landing on a tick
            // that was already `.turn` (the expiry tick) would otherwise start the new pivot
            // with the old one's clock already spent, and it would flip instantly.
            s.activityElapsed = 0
            s.perchSpeed = 0
        }
        return s
    }

    private static func standing(_ state: CatState, on surface: Surface,
                                 world: Skyline, dt: TimeInterval) -> CatState {
        var s = state
        guard case .grounded(var perch) = s.support else { return s }

        // He only has speed of his own while a walk is in progress, and every way one ends
        // (arriving, a wall, the mic going live, being picked up) clears the intent. One line
        // here rather than one in each of them; without it the next walk starts at whatever
        // speed the last one ended at, in whatever direction that happened to be.
        if s.intent == nil { s.perchSpeed = 0 }

        // Something took the notch behaviour away from him while he was in there: the freeze,
        // the yield, waking up, your camera coming on. `inNotch` exempts him from the ground
        // test, so it cannot simply be dropped: he would be standing on a hole. He is put back
        // on a lip and the flag goes with him, in that order.
        //
        // First in the function, before any of the branches that can cause it, so the exit is
        // never more than one tick late.
        if s.inNotch, !s.mayStayInNotch {
            leaveNotch(&s, on: surface, world: world)
            // `leaveNotch` rewrites BOTH `s.support` and `s.position.x`, and `perch` above is a
            // copy taken before it ran. Left stale, the `.walk` arm below reads
            // `surface.extent.lowerBound + perch.dx` and writes that straight back, undoing the
            // reposition on the same tick: one frame of `.slip`, a spurious `.land` with its
            // squash bounce, and a re-planned walk, every time he came out of the notch.
            // This is the only support mutation on this path that falls through to `switch move`.
            if case .grounded(let fresh) = s.support { perch = fresh }
        }

        // Frozen. Ears forward, tail dead still. He hears you, or you are typing hard enough
        // that the kind thing is to stay out of the way, and it doubles as a privacy indicator:
        // if he has gone rigid, your microphone is hot.
        //
        // The intent is SUSPENDED, not cleared. `arrival()` sets the walk out of the notch at
        // launch, and clearing here destroys it moments later, which makes the app's best
        // first impression silently conditional on whether you are on a call, with nothing to
        // restore it. `perchSpeed` still has to go to zero or he coasts through the freeze.
        //
        // `isMoving` knows about this, and has to: an intent that survives would otherwise pin
        // the display link at 60Hz for the length of every call.
        if s.holdingStill {
            s.perchSpeed = 0
            // **Not in the tunnel.** The crossing takes about seven seconds, and freezing
            // partway through parks him inside the cutout, where the permanent notch occluder
            // masks him away completely: on a call, that is the whole call spent invisible.
            // The camera eviction just below cannot rescue him either, because `denDoor` asks
            // `edgeAhead`, which is nil while his x sits in the hole in `solid`.
            //
            // `inNotch` is exempt: a cat who chose the den is meant to be in there. This is
            // only the one who was walking through when you started typing. The rule stated
            // below, that he does not get to stand in the doorway because half of him would be
            // inside a cutout with no pixels behind it, applies with more force to all of him.
            if s.insideNotch, !s.inNotch, case .grounded(var perch) = s.support,
               let out = nearestSpanX(to: s.position.x, in: surface.solid) {
                perch.dx = out - surface.extent.lowerBound
                s.support = .grounded(perch)
                s.position.x = out
                s.intent = nil
            }
            // **The camera lives in the notch, and the notch is his house.** While it is running
            // he does not get to stand in the doorway: half of him would be inside a cutout with
            // no pixels behind it, and the call pose is the one he holds for the whole call.
            //
            // A place is barred; he is never summoned. If your call starts while he is at the
            // other end of the screen he simply puts the headphones on where he is. The joke
            // needs no script: being evicted is what puts him under the camera in the first
            // place, because the doorway is where he was.
            if s.onCamera, case .grounded(var perch) = s.support,
               let den = denDoor(s, on: surface) {
                let clear = den.standAt + den.out * Feel.Shape.clearance
                if surface.solid.contains(where: { $0.contains(clear) }) {
                    perch.dx = clear - surface.extent.lowerBound
                    s.support = .grounded(perch)
                    s.position.x = clear
                    s.facing = den.out
                }
            }
            // Typing alone is still the startled `alert` pose. A live mic or camera is a call,
            // and he joins it. `rig` decides which of the three drawings that is.
            s.activity = s.rig == nil ? .alert : .onCall
            return s
        }
        // Get out of the way. He is a click-through overlay whose window swallows mouse events
        // for exactly as long as your cursor is inside his hit rect, so a cat sitting under your
        // pointer is a cat eating your clicks. One guard rather than a rule per behaviour, so
        // anything that ever puts him on something you use inherits it: coming to your cursor is
        // careful about where it stops, but an ordinary stroll has no idea you are there.
        //
        // Below the freeze on purpose, so he does not shuffle about mid-call, and above the
        // sleep gate, which has better reasons not to move him. Being held puts the cursor on
        // him by definition, and `standing` is only reachable while grounded, so the drag is
        // safe by structure rather than by a check.
        // Both axes, and only once your cursor has been ON him for a beat. Measured across x
        // alone it fires for a cursor anywhere vertically, and firing on arrival means that
        // pointing at him makes him scoot: coming over needs a full minute of stillness and the
        // yield none, so "mouse near cat" always loses the race and reads as the cat avoiding
        // you. He tolerates you pointing at him and moves only if you stay there.
        //
        // `cursorOnHimFor` and not `cursorStill`, which is a different question: a pointer
        // jiggling in place keeps resetting stillness, so he sits under it swallowing clicks
        // for fourteen seconds and never decides he is in the way.
        // ...but a hand that is MOVING over him is a pet, not an obstruction, and the yield is
        // the one thing in the app that would read it backwards. Without this guard, stroking
        // him for longer than `yieldPatience` walks him out from under your hand.
        //
        // **Not while he is asleep**, and the two used to fight every frame. This sets an
        // intent and returns; the sleep gate below opens with `s.intent = nil`. A sleeping cat
        // under a parked cursor therefore flipped sleep -> walk -> sleep at the full link rate,
        // 420 activity changes in five seconds, and never moved a single point. Sleep is the
        // hard stop and it wins. What the yield is really for down here (not swallowing your
        // clicks) is `Overlay.suspend`'s job instead: it drops `ignoresMouseEvents` when the
        // clock stops, so a sleeping cat is click-through wherever he lies.
        if s.intent == nil, !s.beingStroked, s.repose != .asleep, let cursor = s.cursor,
           s.cursorOnHimFor >= Feel.Mind.yieldPatience,
           let x = beside(cursor: cursor, on: surface, from: s.position.x,
                          width: s.drawnBox?.width ?? Feel.Shape.width),
           abs(x - s.position.x) > Feel.Physics.arrivalSlop {
            s.intent = Intent(destination: surface.id, destinationX: x, move: .walk(x))
            s.activity = .walk
            s.activityElapsed = 0
            return s
        }

        // Only sleep is a hard stop, and only because the zero-wakeup guarantee lives there.
        // Sitting and curling *bias* him: longer waits, mostly in-place behaviours. A sitting
        // cat still shifts, washes and looks around. `repose` comes from system HID idle, so
        // freezing him into a pose means sitting still and watching him is what stops him.
        if s.repose == .asleep {
            s.intent = nil
            s.activity = .sleep
            // Asleep at the doorway, he goes all the way IN.
            //
            // Here, inside the hard stop, rather than down among the other resting behaviours,
            // because this gate returns long before any of them run.
            // `asleepAtTheDoorwayHeSleepsInsideTheCutout` holds it.
            //
            // This is the one place his position is allowed inside the cutout, and the whole
            // reason `insideNotch` exists. His body sits above the bar line where the permanent
            // occluder masks it away, so the entire visible animation is a tail hanging out of
            // the hole and swaying, which is why `denSleep` was drawn with the tail as its
            // lowest ink, and why its `footAnchor` is the join between the two.
            //
            // Sticky once entered, because `denDoor` asks what lies ahead on `solid` and by then
            // he is standing in the hole in it: re-asking answers no on the very next tick and
            // drops him. The clear at the top of this function is what keeps sticky from
            // meaning stuck: he leaves the den the moment he wakes or your camera comes on.
            if !s.onCamera, let notch = world.screen.notch,
               s.inNotch || denDoor(s, on: surface) != nil {
                let x = notch.midX
                s.position.x = x
                s.support = .grounded(Perch(id: surface.id, dx: x - surface.extent.lowerBound))
                s.perchSpeed = 0
                s.inNotch = true
            }
            return s
        }

        // Coming out of the doorway. He is standing on the notch's lip with the rest of him
        // still inside the cutout, where the mask clips him away, so the emergence has to
        // finish before anything moves him. Otherwise the walk starts on the first tick and
        // the peek plays while he is already leaving. Above the intent handling rather than
        // inside it for the same reason `edgeLook` holds where it does: the hold IS the beat.
        if s.activity == .peek, s.activityElapsed < Feel.Timing.peekSeconds {
            s.perchSpeed = 0
            return s
        }

        // Mid-pivot. He is turning on the spot and that takes as long as the sheet does, so
        // nothing else happens until it finishes. The same shape as the peek above and the
        // hold at a lip below, and for the same reason: the beat IS the animation, and a walk
        // starting underneath it would slide him sideways through his own turn.
        //
        // `facing` is already the destination, so what ends this is simply the clock: whatever
        // set it has no reason to set it again, and the walk that resumes is now travelling the
        // way he is pointing. That is what makes it terminate rather than re-arm itself.
        if s.activity == .turn, s.activityElapsed < Feel.Timing.turnSeconds {
            s.perchSpeed = 0
            return s
        }

        // Still landing. Same shape again, and this one is what makes the two landing sheets
        // exist at all: the intent SURVIVES a fall by design, so he re-plans on the tick he
        // touches down and the walk overwrote `.land`/`.landHard` on the very next one. Both
        // clips rendered their first frame for a single tick and were never seen. And at
        // `gravity` 2000 the hard threshold is a 90pt drop, which is an ordinary step down
        // between two windows, so that was most landings rather than an edge case.
        //
        // Above the intent handling for the same reason the peek and the pivot are: the beat IS
        // the animation. It cannot deadlock, because what ends it is the timeout in `step`,
        // which runs after this and is not gated on anything.
        if let hold = landingHold(s.activity), s.activityElapsed < hold {
            s.perchSpeed = 0
            return s
        }

        // The screen has gone over to one app and he is behind it. Routing him to the top the
        // ordinary way was timed on a real fullscreen Space at EIGHTEEN seconds: a seven-second
        // run along a floor nobody can see, then a ten-second climb up the covering window's
        // face. A fullscreen Space is somewhere you are for three. So he surfaces at the lip of
        // the thing that covered him instead. It is the same move the hidden branch below already
        // makes, and the climb it skips was invisible by construction, because being behind
        // that window is the premise.
        //
        // `isHidden` is the safety rule and not a detail: a cat you can currently SEE must
        // never jump position. On a covered screen he is only ever moved from somewhere nobody
        // is looking.
        //
        // Above the intent handling, unlike the hidden branch: the fullscreen retreat forms an
        // intent of its own, so behind that guard this would never run at all.
        if s.screenCovered, !upTop(s, on: surface, world: world), isHidden(s, world: world),
           surfaceOverTheLip(&s, world: world) {
            return s
        }

        /// Nothing left to do. He stops where he is and waits before wanting anything else.
        func settle(_ s: inout CatState) {
            s.intent = nil
            s.hurrying = false
            s.activity = s.repose.restingActivity
            s.activityElapsed = 0
            s.restLeft = Feel.Timing.restMin + Double.random(in: 0...Feel.Timing.restJitter, using: &s.roll)
        }

        /// One step of the plan is finished. Re-plan toward the same destination rather than
        /// clearing, or settle if he has arrived.
        func advance(_ s: inout CatState, on surface: Surface) {
            guard let intent = s.intent else { return }
            let arrived = intent.destination == surface.id
                && abs(intent.destinationX - s.position.x) < Feel.Physics.arrivalSlop * 3
            if !arrived, let next = nextMove(from: s, on: surface, toward: intent.destination,
                                            x: intent.destinationX, world: world) {
                s.intent?.move = next
            } else {
                settle(&s)
            }
        }

        guard let intent = s.intent else {
            // A show is owed: the wake-up stretch, or one of the machine-event pieces.
            // First in the region on purpose, so it interrupts every waiting pose and every
            // in-place performance: a jolt of electricity through a lounging cat is the
            // entire gag, and queued behind the lounge it lands up to a spell late. Only the
            // real interrupts outrank it: the freeze, the yield and sleep all return above.
            if let show = s.owed, !isShow(s.activity) {
                s.owed = nil
                s.activity = show
                s.activityElapsed = 0
                return s
            }
            // The pose he waits in tracks how settled he is, so a cat who was standing when
            // the room went quiet sits down rather than only settling into it after his next
            // idea. Only ever swaps one waiting pose for another: a wash or a walk still wins.
            switch s.activity {
            case .groom, .lounge, .stretch, .peek, .peer, .zap, .vibe, .droop, .curious,
                 .hang, .peerDown,
                 .land, .landHard, .brace: break   // busy; each times out on its own
            // Mid-glance at something that just appeared. `glanceLeft` is what tells this apart
            // from a STALE alert left over after the mic went quiet, which this branch has to go
            // on clearing: the hold-still branch returns early, so without that reset he stayed
            // bolt upright for the whole of his next rest.
            case .alert where s.glanceLeft > 0: break
            // Being petted, for exactly as long as you are petting him. Conditional for the
            // same reason the glance above is: an unconditional `break` would leave him blissed
            // out for ever after your hand left, and the default arm is the only thing that
            // hands him back a waiting pose.
            case .stroked where s.beingStroked: break
            default: s.activity = s.repose.restingActivity
            }
            // At a den door he waits IN the doorway, facing out, instead of sitting beside
            // it. The notch is a hardware hole with no pixels behind it, so a cat resting
            // at its lip half-overlaps the cutout and the mask eats half of him. Held as the
            // peek pose (the same drawing the launch arrival uses: hindquarters in the dark,
            // face out) it reads as him watching the room from inside his den. Boredom still
            // drains underneath it, so in ordinary life the next idea gets him up; on a
            // covered screen, where elections are gated, the den is how he watches the whole
            // film.
            //
            // **Once per arrival, not every tick he rests there.** Without the latch this is a
            // loop: it sets `.peek`, the peek holds for `peekSeconds`, expires back to the
            // resting pose, and the resting pose qualifies again on the very next tick.
            // Measured on a covered screen that is peek/idle/peek/idle for as long as the film
            // runs, so he plays the same 1.1s animation at you forever instead of settling in.
            //
            // Latched rather than gated on position, which was tried and is worse: the retreat
            // already walks him to within `arrivalSlop` of this exact spot, so a position check
            // blocks the FIRST peek too and the pose is never seen at all.
            if let den = denDoor(s, on: surface) {
                // Wandered off, so the next arrival is a fresh one.
                if abs(s.position.x - den.standAt) > Feel.Shape.clearance * 2 {
                    s.settledInDen = false
                }
                if !s.settledInDen, s.activity == s.repose.restingActivity, s.repose != .asleep {
                // Out of the hole before he settles into it. Whatever is drawn inside the notch
                // is simply gone, so a cat centred on the lip is missing his back half. The
                // retreats aim at this spot already (`OgiApp.denX`), so on the common path this
                // is a few points at most; it is here as well because the retreats are not the
                // only way he ends up on a lip. A wall bump parks him on one, and so does a
                // launch walk that never finished because the room went quiet.
                    s.position.x = den.standAt
                    s.support = .grounded(Perch(id: surface.id,
                                                dx: den.standAt - surface.extent.lowerBound))
                    // Turn first, peek second, and they cannot share a tick. `ground()` wraps
                    // the whole of `standing` and rewrites the activity to `.turn` whenever
                    // `facing` changed, so setting both here means the turn eats the peek. That
                    // went unnoticed while this branch re-armed every tick (the next attempt
                    // stuck); latched to once per arrival, the single attempt was eaten and the
                    // pose never played at all. So: point him out of the den now, and let the
                    // peek land on a later tick once he is already facing that way.
                    if s.facing != den.out {
                        s.facing = den.out
                        return s
                    }
                    s.activity = .peek
                    s.activityElapsed = 0
                    s.settledInDen = true
                    // The beat IS the animation; nothing below overwrites it on the tick it
                    // starts. The hold near the top of `standing` catches it from here on.
                    return s
                }
            }


            // While the screen is covered he belongs at the top, and that is a STANDING
            // ORDER rather than an event. The edge-triggered retreat alone is losable: it
            // fires on the first sighting of the fullscreen window, before that window has
            // aged into furniture he may climb, and a one-shot stimulus consumed against an
            // unroutable world is simply gone, leaving a cat at the bottom of a covered
            // screen with no urgency anywhere. This asks again on every idle tick he is not
            // up top, so the moment the covering window's face becomes climbable he is on
            // his way up it.
            // **At the DOOR, not merely up top.** `upTop` is satisfied by being anywhere on
            // the menu bar, so a cat already up there when the film starts never walks the
            // rest of the way and falls asleep where he stands: ordinary `curl`, on some
            // arbitrary x, with the den and its tail never reached.
            //
            // This is the line that makes "a covered screen is watched from the den" true. He
            // walks home while the film runs, and is therefore standing at the doorway when
            // the idle ladder reaches sleep, which is the only way into it.
            //
            // The arrival slop has to be wider than the walk's overshoot and narrower than
            // `denDoor`'s reach, or he either paces at the door forever or stops short of it.
            //
            // **It yields to anything already holding him in place, and it did not used to.**
            // Sitting this high in the idle region, it pre-empted every branch below it: the
            // notch exit, the stroke, the in-place holds and the peer. Its own test is "more
            // than 9pt from the den door", and `enterNotch` puts him at `notch.midX` while
            // `homeX` is the door beside it, 130pt away BY CONSTRUCTION, so every notch pose
            // was cancelled on the tick after it started. Measured against the shipping
            // geometry: hang 4.008s -> 0.008s, peerDown 10.000s -> 0.008s, peer 12.008s ->
            // 0.008s, and 94 notch entries out of 200 with not one held past a second.
            //
            // Which made three advertised behaviours invisible in exactly the situation they
            // were written for: `Feel.Timing.peerSeconds` is 12 *because* the covered-screen
            // retreat is when you see it, and the pull-ups happen in the den he retreats to.
            // Two branches in one function, cancelling each other.
            if s.screenCovered, let home = s.homeX,
               // Only what owns its own way out, which is the notch poses (`hang`, `peerDown`
               // and the den, all of which imply `inNotch`), the `.peer` this branch itself
               // produces over a lip, and your hand. An ordinary performance is still
               // interrupted: a lounge is what he does when nothing is happening, and a film
               // starting is something happening. Exempting every `inPlaceHold` instead, as
               // first written here, let a chain of them keep him 126pt from the door for the
               // length of a film.
               !s.inNotch, s.activity != .peer, !s.beingStroked,
               !upTop(s, on: surface, world: world)
                   // **The yard is for a cat who is awake.** As he settles it tightens back to
                   // the doorstep, because the den is entered from the door and nowhere else:
                   // left at a yard, he fell asleep 54pt away and slept ON the bar, so the den
                   // sleep and its tail (the whole reason the notch is his house) stopped
                   // happening. Awake he mooches; drowsy he comes home.
                   || abs(s.position.x - home) > (s.repose == .awake || s.repose == .sitting
                                                  ? Feel.Notch.denYard
                                                  : Feel.Physics.arrivalSlop * 3),
               let move = nextMove(from: s, on: surface, toward: .menuBar, x: home,
                                   world: world) {
                s.intent = Intent(destination: .menuBar, destinationX: home, move: move)
                if case .jump = move { s.activity = .crouch } else { s.activity = .walk }
                s.activityElapsed = 0
                return s
            }

            // He wants to be seen, and it outranks the in-place holds below: a cat behind a
            // window is a cat doing nothing, however good the thing he is doing. A 45-second
            // lounge held behind a window, blind to being hidden, measures out at 52 seconds
            // of invisibility. A wash or a lounge is interrupted; being seen matters more.
            //
            // `spans` is exactly "where he is visible", so a window raised over his perch
            // makes this true with no new world model: the same array the renderer already
            // uses to decide what to clip. He steps out along his own ledge if any of it is
            // still showing, and only leaves the ledge entirely when the whole thing is
            // covered.
            //
            // **A cat who chose the hole is not hiding by accident.** The notch is an occluder
            // by design, so every notch pose accrues `hiddenFor` at exactly the rate its own
            // clock runs. With `peerDownSeconds` and `hiddenPatience` both at 10, a `.below`
            // peer-down (which stands at `notch.midX`, outside `bar.spans`) had the two
            // counters bit-identical, and this branch is tested first and uses `>=` while the
            // pose's own exit below uses `>`. So it won by one comparison, every time, and the
            // pull-up out of the notch never played for half of all peer-downs. The intent
            // planted here then survived `leaveNotch`'s reposition and walked him off the lip.
            if s.hiddenFor >= Feel.Mind.hiddenPatience, !s.inNotch {
                if let x = standingRoom(near: s.position.x, in: surface.spans),
                   abs(x - s.position.x) > Feel.Physics.arrivalSlop * 3 {
                    s.intent = Intent(destination: surface.id, destinationX: x, move: .walk(x))
                    s.activity = .walk
                    s.activityElapsed = 0
                    return s
                }
                // His whole ledge is covered, but the window burying him has a top edge of
                // its own, and surfacing there, head and paws over the lip of the thing
                // that hid him, is better than fleeing. The climb up its back is unseen by
                // construction: he is hidden, which is the premise. The visible event is a
                // head appearing over the lip.
                if surfaceOverTheLip(&s, world: world) { return s }
                // Nothing to surface at. Somewhere else entirely, and the first that routes.
                for other in world.surfaces.shuffled(using: &s.roll)
                where other.id != surface.id && other.targetable && !other.spans.isEmpty {
                    guard let span = other.spans.randomElement(using: &s.roll) else { continue }
                    let x = (span.lowerBound + span.upperBound) / 2
                    if let move = nextMove(from: s, on: surface, toward: other.id, x: x,
                                           world: world) {
                        s.intent = Intent(destination: other.id, destinationX: x, move: move)
                        if case .jump = move { s.activity = .crouch } else { s.activity = .walk }
                        s.activityElapsed = 0
                        return s
                    }
                }
            }

            // Off the notch, and back onto the bar.
            //
            // **Above the general hold below, and that ordering is load-bearing.** Both notch
            // behaviours are in `inPlaceHold`, so the general branch would otherwise catch them
            // first, hand him back his resting pose and leave him standing at `notch.midX`,
            // where `insideNotch` has just gone false, so the ground test drops a cat who was
            // hanging perfectly happily one tick ago. Anything that puts him inside the cutout
            // has to own its own way out.
            //
            // He comes back out the side he went in, which `facing` remembers for free: it was
            // pointed at his entry lip on the way in and nothing between turns him, because
            // both clips are drawn head-on and never consult it.
            if s.activity == .hang || s.activity == .peerDown {
                if let hold = inPlaceHold(s.activity), s.activityElapsed > hold {
                    leaveNotch(&s, on: surface, world: world)
                    // The pull-up back over the lip. `land` is the same clip the peer-over uses
                    // to haul itself up, for the same event.
                    s.activity = .land
                    s.activityElapsed = 0
                }
                return s
            }

            // Your hand is on him and moving. Eyes shut, head into it.
            //
            // **Above the in-place holds and gated on `isShow` instead.** Below them it could
            // not interrupt a wash or a sprawl, and a lounge holds for forty-five seconds. A
            // wash and a sprawl are what he does when nothing is happening, and a hand
            // arriving is something happening. A performance is not, and `isShow` is exactly
            // that distinction, so it is the guard rather than the position in the file.
            //
            // The freeze, the yield and sleep all returned long before this, so a cat frozen by
            // your microphone stays frozen. That is deliberate: he is being quiet for you. The
            // notch behaviours returned just above, so they keep their own way out of the hole.
            if s.beingStroked, !isShow(s.activity) {
                if s.activity != .stroked { s.activity = .stroked; s.activityElapsed = 0 }
                // Boredom does not drain while he is occupied, so he cannot get an idea and
                // walk off mid-pet, the same failure the yield guard above prevents, arriving
                // by the other road.
                return s
            }

            // Mid-performance: a wash, a lounge, a stretch, or one of the event pieces.
            // Held for its spell, then settled back. Everything that actually matters
            // (the freeze, the yield, sleep, being hidden) already returned before this.
            if let hold = inPlaceHold(s.activity) {
                if s.activityElapsed > hold {
                    s.activity = s.repose.restingActivity
                    s.activityElapsed = 0
                    s.restLeft = Feel.Timing.restMin + Double.random(in: 0...Feel.Timing.restJitter, using: &s.roll)
                }
                return s
            }
            // Peering over the lip: a good long nosy look, then he pulls himself up onto
            // the edge: the landing clip is the pull-up, and its own hold hands to rest.
            if s.activity == .peer {
                if s.activityElapsed > Feel.Timing.peerSeconds {
                    s.activity = .land
                    s.activityElapsed = 0
                }
                return s
            }
            // Nothing to do. Sit still until boredom wins.
            // Low battery makes him idle longer. A sluggish cat means plug in.
            // Settledness stretches the same timer rather than stopping it.
            // (Being hidden is handled above the in-place holds now: a lounge held behind a
            // window was 52 seconds of invisibility.)

            // Cats approach when you go still. Not gated on arousal: this is a condition rather
            // than an event, and an excited cat coming over is not what it is for. Above the
            // boredom timer, so a waiting cursor beats an ordinary idea rather than racing it.
            //
            // True distance, not horizontal distance. Measured across only x, a cursor parked
            // in the middle of a small window six hundred points BELOW him counts as near, and
            // since this only ever walks him along the ledge he is already on, he would shuffle
            // sideways to stand directly above a pointer he is nowhere near. Aligned with you
            // and not next to you, which reads as nothing at all.
            if let cursor = s.cursor,
               s.cursorStill >= Feel.Mind.cursorStillSeconds,
               hypot(cursor.x - s.position.x, cursor.y - s.position.y) <= Feel.Mind.cursorNearby,
               let x = beside(cursor: cursor, on: surface, from: s.position.x,
                              width: s.drawnBox?.width ?? Feel.Shape.width),
               abs(x - s.position.x) > Feel.Physics.arrivalSlop * 3 {
                s.intent = Intent(destination: surface.id, destinationX: x, move: .walk(x))
                s.activity = .walk
                s.activityElapsed = 0
                return s
            }
            // ...and stirred up, he gets to the end of that timer sooner.
            s.restLeft -= dt * (1 - s.languor * 0.6)
                * (1 + s.arousal * Feel.Mind.restUrgency) / s.repose.restMultiplier
            if s.restLeft <= 0 {
                // Boredom does not always mean going somewhere. Sometimes he just washes,
                // which is the difference between a creature and a pathfinding demo. The more
                // settled he is, the likelier that is what it turns out to be.
                // ...and a stirred-up cat is likelier to go somewhere than to wash.
                let inPlace = s.repose.inPlaceChance * (1 - s.arousal * Feel.Mind.travelUrgency)
                if Double.random(in: 0...1, using: &s.roll) < inPlace {
                    // Standing at a notch lip there are two things to do that exist nowhere
                    // else on the screen, both of them the same geometric fact used twice: the
                    // cutout is a hole in `solid` sitting above the bar line, so the one
                    // stretch of ledge he cannot STAND on is the only stretch he can hang from
                    // or lie in.
                    //
                    // In the in-place branch rather than as a taste candidate, because the
                    // election scores *places to go* and this is something to do where he
                    // already is. It is rarer than `lipIdeaChance` suggests: reaching it at all
                    // needs boredom to come up in-place while he happens to be at a doorway.
                    if let notch = world.screen.notch, let den = denDoor(s, on: surface),
                       Double.random(in: 0...1, using: &s.roll) < Feel.Notch.lipIdeaChance {
                        // Three things to do in a hole, and which one is a coin flip between
                        // going *into* it and leaning out of the side he is already standing at.
                        //
                        // `facing` is set to point back at the lip he entered by in every case,
                        // because that is how `leaveNotch` finds its way out again.
                        enterNotch(&s, on: surface, notch: notch, out: den.out)
                    } else {
                        // Usually a wash, sometimes a stretch: more is wanted than
                        // one in-place behaviour, and until the stretch the wash was the only
                        // one that existed.
                        s.activity = Double.random(in: 0...1, using: &s.roll) < Feel.Timing.stretchChance
                            ? .stretch : .groom
                    }
                    s.activityElapsed = 0
                } else if s.screenCovered, let home = s.homeX,
                          Double.random(in: 0...1, using: &s.roll) < Feel.Notch.moochChance,
                          // **A mooch, inside the yard.** Ideas are off while the screen is
                          // covered, which is right (he belongs at his den during a film, not
                          // touring the desktop), but with nothing proposing a walk he never
                          // used the yard `denYard` gave him: measured at 0 walks and 32pt of
                          // travel in ten covered minutes, across three seeds. The range he
                          // covered was the notch poses moving him, not him going anywhere.
                          //
                          // So: somewhere else on the bar, near home. Kept to 70% of the yard
                          // so the destination cannot sit on the boundary the standing order
                          // above enforces, which would put the two in a tug of war.
                          let spot = standingRoom(
                              near: home + CGFloat.random(in: -1...1, using: &s.roll)
                                  * Feel.Notch.denYard * 0.7,
                              in: surface.spans),
                          abs(spot - s.position.x) > Feel.Physics.arrivalSlop * 3,
                          let move = nextMove(from: s, on: surface, toward: surface.id,
                                              x: spot, world: world) {
                    s.intent = Intent(destination: surface.id, destinationX: spot, move: move)
                    if case .jump = move { s.activity = .crouch } else { s.activity = .walk }
                    s.activityElapsed = 0
                } else if !s.screenCovered,
                          let choice = idea(from: &s, on: surface, world: world) {
                    switch choice {
                    case .go(let intent):
                        s.intent = intent
                        if case .jump = intent.move { s.activity = .crouch }
                        else { s.activity = .walk }
                        s.activityElapsed = 0
                    case .lounge:
                        s.activity = .lounge
                        s.activityElapsed = 0
                    }
                } else {
                    // Nothing worth doing. Wait before asking again rather than re-rolling
                    // on every one of the next 120 ticks, which both burns work and biases
                    // the destination distribution toward whatever is easiest to pick.
                    s.restLeft = Feel.Timing.restMin
                }
            }
            return s
        }

        // A step-off is a walk that does not stop, so it is resolved into one here and the
        // walking code stays in one place. Resolved fresh each tick rather than written back,
        // so a lip that stops being a lip (the window under it closing, say) is noticed.
        //
        // ...but not immediately. He walks to the lip, stops short of it, puts his head over
        // and HOLDS, and only then commits or thinks better of it. That hold is the same idea
        // as the crouch before a jump, one level up: it is the difference between the cat
        // jumped and the cat decided to jump. `stepOffLip` has already refused every lip with
        // nothing under it, so he can only ever hesitate at a real drop, never at a wall, and
        // never at the interior gap, which he must not so much as consider.
        var move = intent.move
        // A climb starts with a walk to the spot under the face. Resolved into one here, the
        // way a step-off is, so the walking code stays in one place, and deliberately NOT
        // written back to the intent, because `intent.move` staying `.climb` is the only thing
        // arming the grab on the way up. The walk's own arrival re-plans through `nextMove`,
        // which hands back the same `.climb` with the same x (nothing in choosing it depends
        // on where he is standing), so this settles rather than chasing itself.
        if case .climb(_, let x) = move, abs(x - s.position.x) > Feel.Physics.arrivalSlop * 2 {
            move = .walk(x)
        }
        // A drop starts with a walk to the spot above the target, resolved exactly the way
        // a climb's walk is and for the same reason: never written back, and the re-plan on
        // arrival hands back the same drop from the same arithmetic, so it settles rather
        // than chasing itself.
        if case .drop(_, let x) = move, abs(x - s.position.x) > Feel.Physics.arrivalSlop * 2 {
            move = .walk(x)
        }
        if case .stepOff = move {
            guard let lip = stepOffLip(from: s, on: surface, toward: intent.destinationX,
                                       world: world) else {
                settle(&s)      // walls both ways: there is no way down from here after all
                return s
            }
            let toLip = abs(lip.x - s.position.x)
            // Where he plants, and the mark the approach walks to: one braking distance
            // further in, so the approach can never actually *arrive* (see that branch).
            let plantAt = Feel.Physics.edgePlant
            let mark = Feel.Physics.edgePlant - Feel.Physics.brakingDistance

            if s.activity == .edgeLook {
                s.perchSpeed = 0
                // The drop he is weighing, measured this tick by the same rule that chose the
                // lip. A deeper one is looked at for longer.
                let drop = s.footing.dropAhead ?? 0
                guard s.activityElapsed >= hesitation(forDrop: drop) else { return s }

                guard Double.random(in: 0...1, using: &s.roll) < commitChance(forDrop: drop) else {
                    // Thought better of it. He turns, walks a little way back along the ledge
                    // and sits down pretending he was never considering it.
                    //
                    // The retreat is a destination on his OWN surface, and that is what stops a
                    // refusal from becoming a pace: `advance` re-plans toward whatever the
                    // intent says, so a retreat that kept the old destination would route him
                    // straight back to the lip he just turned down, for ever. Giving the trip up
                    // is the honest reading anyway (he decided not to go) and the walk back
                    // plus the rest at the end of it is what puts a real gap before he next
                    // thinks about it.
                    s.facing = -lip.dir
                    let back = lip.x - lip.dir * Feel.Physics.edgeRetreat
                    if let x = nearestSpanX(to: back, in: surface.solid),
                       abs(x - s.position.x) > Feel.Physics.arrivalSlop * 3 {
                        s.intent = Intent(destination: surface.id, destinationX: x, move: .walk(x))
                        s.activity = .walk
                    } else {
                        settle(&s)          // nowhere to retreat to; he just turns round
                    }
                    return s
                }
                // Committed, and written back rather than re-resolved, because it is a decision
                // and not a reading: leave it as `.stepOff` and the next tick finds him at the
                // lip again and he stands there deciding for ever. Aimed past the lip, so the
                // fall starts through the same code as any other walked-off edge.
                move = .walk(lip.x + lip.dir * Feel.Physics.edgeApproach)
                s.intent?.move = move
                s.activity = .walk

            } else if toLip <= plantAt {
                // Close enough. He plants and puts his head over the side.
                s.facing = lip.dir
                s.perchSpeed = 0
                s.activity = .edgeLook
                return s

            } else {
                // The approach, aimed to stop just short of the lip, so that the plant above
                // catches him at `edgePlant`, with his front paws on solid ground and his
                // lowered head out over the drop.
                //
                // The plant above intercepts one braking distance outside that mark so the walk
                // can never actually *arrive*. That is what makes the tell survive: arriving
                // calls `advance`, and from this close to a lip a jump down suddenly clears his
                // own ledge, so re-planning here would quietly turn the whole thing into a leap.
                //
                // Which is also why the slowing down has to happen here rather than in the
                // walk's own braking. The two windows coincide exactly (the walk brakes inside
                // `brakingDistance` of its mark, which is the last `plantAt` points, and those
                // are precisely the points he never spends walking), so left to the walk he
                // would hold a flat `walkSpeed` right up to the lip and then stop dead. A
                // ceiling on his surface speed, easing to a creep over the last `edgeEase`
                // points, is the whole "slows" beat of the tell. It caps the ordinary walk
                // rather than replacing it: the walk still ramps toward it at `accel`, so this
                // is one number lower, not a second way of moving.
                //
                // Scaled off the gait he would otherwise be travelling at, not off `walkSpeed`:
                // a ceiling of `walkSpeed` holds a trotting cat at a walk while `hurrying` is
                // still true, and `Sprites.clip` reads `hurrying`, so he plays the run frames
                // at walking speed, which is the gait desync `strideLength` exists to prevent.
                // Applied only inside the ease itself for the same reason: outside it he is
                // covering ground, and how he covers ground is not this code's business.
                let target = lip.x - lip.dir * mark
                let ease = (toLip - plantAt) / Feel.Physics.edgeEase
                if ease < 1 {
                    let top = gait(over: target - s.position.x, languor: s.languor).top
                    let creep = min(Feel.Physics.edgeCreepSpeed, top)
                    let cap = creep + (top - creep) * max(0, ease)
                    s.perchSpeed = max(-cap, min(cap, s.perchSpeed))
                }
                move = .walk(target)
            }
        }

        switch move {
        case .walk(let targetX):
            let dx = targetX - s.position.x
            let (top, hurrying) = gait(over: dx, languor: s.languor)
            s.hurrying = hurrying

            // The weight, in four lines. One signed surface-local speed ramped toward what he
            // wants gives the wind-up; braking at a fixed distance rather than at the distance
            // he actually needs gives the overshoot, because the two do not match. He arrives
            // a few points past his mark and stops there, which is also why there is no
            // `abs(dx) < arrivalSlop` arrival check: running out of speed IS arriving.
            let braking = abs(dx) <= Feel.Physics.brakingDistance
            let want: CGFloat = braking ? 0 : top * (dx > 0 ? 1 : -1)
            let rate = (braking ? Feel.Physics.decel : Feel.Physics.accel) * CGFloat(dt)
            s.perchSpeed += max(-rate, min(rate, want - s.perchSpeed))

            // Facing follows where he is actually going, not where he is aiming: past the mark
            // those two disagree, and the edge test below reads `facing` to work out which way
            // the ground runs out. Falling back to the target covers the tick where he is
            // turning round and his speed passes through exactly zero.
            if s.perchSpeed != 0 {
                s.facing = s.perchSpeed > 0 ? 1 : -1
            } else if abs(dx) > Feel.Physics.arrivalSlop {
                s.facing = dx > 0 ? 1 : -1
            }

            if braking, abs(s.perchSpeed) < Feel.Physics.stopSpeed {
                s.perchSpeed = 0
                advance(&s, on: surface)
                break
            }
            let step = s.perchSpeed * CGFloat(dt)

            let worldX = surface.extent.lowerBound + perch.dx
            let nextX = worldX + step
            if let edge = edgeAhead(from: worldX, facing: s.facing, on: surface),
               (s.facing > 0 ? nextX > edge : nextX < edge) {
                if braking {
                    // He was stopping anyway and the ground ran out first. The coast past his
                    // mark must not carry him off a lip he was aiming AT, and `nextMove` aims
                    // at lips deliberately: the launch point for a jump, the near side of a
                    // crack to stride over. Three points past one of those is a fall, not a
                    // flourish. A step-off is untouched by this. It aims `edgeApproach` past
                    // the lip, far outside `brakingDistance`, so he is still at full speed when
                    // he gets there and goes straight over.
                    perch.dx = edge - surface.extent.lowerBound
                    s.support = .grounded(perch)
                    s.perchSpeed = 0
                    advance(&s, on: surface)
                } else if let below = landing(past: edge, facing: s.facing, on: surface, world: world) {
                    // He walked off. Gravity was always there; nothing was ever allowed
                    // to reach it. The intent SURVIVES: he re-plans from wherever he lands,
                    // which is what makes a step off a route rather than an accident.
                    s.support = .falling
                    s.activity = .slip
                    s.activityElapsed = 0
                    // Clear of the lip so the fall does not scrape down it, but never past
                    // the far side of what he is stepping ONTO. The menu bar and the desktop
                    // share a span exactly, so at the ends of the screen two points past the
                    // one is two points past the other, and the nudge and the kick together
                    // threw him out of the world for good.
                    let over = edge + s.facing * Feel.Physics.edgeTolerance
                    let clear = below.solid.contains { $0.contains(over) }
                    s.position.x = clear ? over : edge
                    // And half a point below it, so a cat left exactly level with the surface
                    // he just stepped off does not re-ground on it: `supportBelow` sweeps an
                    // inclusive range and has no idea which one he left.
                    s.position.y = surface.y - Feel.World.coplanarEpsilon
                    s.velocity = CGVector(dx: clear ? s.facing * Feel.Physics.slipKick : 0, dy: 0)
                    s.drift = 0
                    s.lastPerchOrigin = nil
                } else {
                    // Nothing below. The end of the world, not a ledge: he turns around.
                    perch.dx = edge - surface.extent.lowerBound
                    s.support = .grounded(perch)
                    s.facing = -s.facing
                    settle(&s)
                }
                break
            }
            perch.dx += step
            s.support = .grounded(perch)
            s.activity = .walk

        case .jump(let destID, let destX):
            // (A chained hop plays its landing before winding up for the next one. The landing
            // hold above covers that, and the walk with it.)
            // The 100ms crouch, from scratch every time. Non-negotiable: it is the entire
            // difference between a cat and a teleporting rectangle. Requiring that he is
            // ALREADY crouching is what makes it survive a jump planned mid-route: the clock
            // left over from the walk that got him here would otherwise count as the wind-up.
            guard s.activity == .crouch, s.activityElapsed >= Feel.Timing.anticipation else {
                s.activity = .crouch
                break
            }
            guard let dest = world.surface(destID),
                  let v = launch(dx: destX - s.position.x, dy: dest.y - s.position.y,
                                 using: &s.roll) else {
                // The window moved while he was winding up and it is out of reach now.
                // Give up rather than teleporting.
                settle(&s)
                break
            }
            s.velocity = v
            s.facing = s.velocity.dx >= 0 ? 1 : -1
            s.support = .falling
            s.activity = .airborne
            s.activityElapsed = 0
            // Same two lines as every other grounded→falling exit. Without them a jump that
            // lands back on the surface he left resumes against a `lastPerchOrigin` from
            // before the flight, and reads the whole of the drag that happened during it as
            // one tick of drift.
            s.drift = 0
            s.lastPerchOrigin = nil
            // The intent survives the flight; he re-plans the instant he lands.

        case .stepAcross(let destID, let x):
            // A stride, not a leap. The gap is narrower than one pace (he is standing on the
            // lip and the far side is a couple of dozen points away), so he simply arrives on
            // it, and two tiled windows read as one shelf instead of an obstacle course.
            guard let far = world.surface(destID) else {
                settle(&s)
                break
            }
            s.facing = x >= s.position.x ? 1 : -1
            s.position = CGPoint(x: x, y: far.y)
            s.support = .grounded(Perch(id: destID, dx: x - far.extent.lowerBound))
            s.activity = .walk
            advance(&s, on: far)

        case .crossNotch(let farX):
            // Squeezing past the camera housing, in the dark, between the two lips of the
            // cutout. A plain walk with a lower ceiling and none of the edge machinery: there
            // is no lip inside the tunnel to look over, and `insideNotch` is already holding
            // the ground test off him for the duration.
            //
            // No acceleration ramp either, unlike `.walk`. He entered this at a walk and comes
            // out of it at one; the whole crossing is shorter than the wind-up would be.
            let dx = farX - s.position.x
            let top = Feel.Physics.walkSpeed * Feel.Notch.squeezeFactor
            s.hurrying = false
            s.activity = .walk
            if abs(dx) > Feel.Physics.arrivalSlop {
                s.facing = dx > 0 ? 1 : -1
                s.perchSpeed = top * s.facing
                s.position.x += min(abs(dx), top * CGFloat(dt)) * s.facing
                s.support = .grounded(
                    Perch(id: surface.id, dx: s.position.x - surface.extent.lowerBound))
            } else {
                // Out the far side and standing on real ground again.
                s.position.x = farX
                s.perchSpeed = 0
                s.support = .grounded(Perch(id: surface.id, dx: farX - surface.extent.lowerBound))
                advance(&s, on: surface)
            }

        case .climb(let destID, _):
            // In position under the face. Same crouch as a jump (the wind-up is the whole
            // difference between a cat and a teleporting rectangle) and the same reason for
            // requiring he is ALREADY crouching: the clock left over from the walk that got
            // him here would otherwise count as the anticipation.
            guard s.activity == .crouch, s.activityElapsed >= Feel.Timing.anticipation else {
                s.activity = .crouch
                break
            }
            // Half-open on the right, matching `CGRect.contains`, which is the test the grab on
            // the way up actually applies. Zero-width exposure, but the two are meant to be the
            // same question and a launch admitted at exactly `maxX` would rise through a face
            // that then refused to hold him.
            guard let target = world.surface(destID), let rect = target.rect,
                  rect.minX <= s.position.x, s.position.x < rect.maxX,
                  let v = launch(dx: 0, dy: climbLift(to: rect, from: s.position), using: &s.roll) else {
                // The window moved out from over him while he was winding up.
                settle(&s)
                break
            }
            // Straight up at the face; he is not aiming to land on anything. The grab in the
            // falling branch catches him on the way past, and if it does not (the window went
            // away mid-flight), he simply comes back down onto the ledge he left.
            s.velocity = v
            s.support = .falling
            s.activity = .airborne
            s.activityElapsed = 0
            s.drift = 0
            s.lastPerchOrigin = nil

        case .drop(let dropID, _):
            // In position over it. Re-verified live, because the window can move or close
            // during the walk over: the thing below him must still be the thing he chose.
            guard let below = world.surface(dropID),
                  world.supportBelow(x: s.position.x,
                                     from: surface.y - Feel.World.coplanarEpsilon,
                                     to: -.greatestFiniteMagnitude)?.id == dropID else {
                settle(&s)
                break
            }
            // The tell, at a lip that is not a lip: plant, look down at the thing below,
            // hold, then commit or think better of it. The same beat as the edge, scaled by
            // the same drop, because the decision is the same size.
            if s.activity != .edgeLook {
                s.perchSpeed = 0
                s.activity = .edgeLook
                break
            }
            let depth = surface.y - below.y
            guard s.activityElapsed >= hesitation(forDrop: depth) else {
                s.perchSpeed = 0
                break
            }
            guard Double.random(in: 0...1, using: &s.roll) < commitChance(forDrop: depth) else {
                settle(&s)      // thought better of it; the next idea starts from scratch
                break
            }
            s.support = .falling
            s.activity = .slip
            s.activityElapsed = 0
            // Half a point below his own line so supportBelow cannot re-catch the surface
            // he just left, exactly as a step-off clears it. Straight down, no kick: the
            // target sits under him by construction, and sideways speed only risks the
            // edge of its span.
            s.position.y = surface.y - Feel.World.coplanarEpsilon
            s.velocity = .zero
            s.drift = 0
            s.lastPerchOrigin = nil
            // The intent survives; he re-plans where he lands, like every other way down.

        case .stepOff:
            break   // resolved into a walk above; unreachable
        }
        return s
    }

    /// A show in progress: one of the owed performances, which nothing short of a real
    /// interrupt (the freeze, the yield, sleep, a retreat) may take the pose from. The
    /// glance's perk, an investigation, and a second show all wait their turn.
    static func isShow(_ activity: Activity) -> Bool {
        switch activity {
        case .stretch, .zap, .vibe, .droop, .curious: return true
        default: return false
        }
    }

    /// How long an in-place performance holds before he settles back, or nil if the
    /// activity is not one. One table because the busy-list, the timeout and the pin tests
    /// all have to agree on what counts as a performance.
    static func inPlaceHold(_ activity: Activity) -> TimeInterval? {
        switch activity {
        case .groom: return Feel.Timing.groomSeconds
        case .lounge: return Feel.Taste.loungeSeconds
        case .stretch: return Feel.Timing.stretchSeconds
        case .zap: return Feel.Timing.zapSeconds
        case .vibe: return Feel.Timing.vibeSeconds
        case .droop: return Feel.Timing.droopSeconds
        case .curious: return Feel.Timing.curiousSeconds
        case .hang: return Feel.Notch.hangSeconds
        case .peerDown: return Feel.Notch.peerDownSeconds
        default: return nil
        }
    }

    /// How long a landing reads for before he is a cat again, or nil if he is not landing.
    ///
    /// Two clocks, because the two landings are two different animations: the hard one shakes
    /// himself off, and that takes the length of the `shake` sheet plus a beat holding its
    /// settled last frame. One function because two callers have to agree (the hold in
    /// `standing` and the timeout in `step`), and a hold that outlasted its own timeout would
    /// freeze him on the spot.
    static func landingHold(_ activity: Activity) -> TimeInterval? {
        switch activity {
        case .land: return Feel.Timing.landSeconds
        case .landHard: return Feel.Timing.landHardSeconds
        default: return nil
        }
    }

    /// What he asks of himself over a walk of `dx`. Long trips are covered at a trot (a cat
    /// crossing a room does not stroll, and it is also the only thing that ever plays the run
    /// frames), and a low battery makes whichever gait it is slower.
    ///
    /// One function because two callers have to agree: the walk sets `hurrying`, the animation
    /// picks the run sheet from it, and the ease at a lip has to scale off the same number. A
    /// second copy of this arithmetic that said `walkSpeed` where this one says `runSpeed` put
    /// the run frames on screen at walking speed.
    static func gait(over dx: CGFloat, languor: Double) -> (top: CGFloat, hurrying: Bool) {
        let hurrying = abs(dx) > Feel.Physics.hurryDistance && languor < 0.5
        let base = hurrying ? Feel.Physics.runSpeed : Feel.Physics.walkSpeed
        return (base * (1 - CGFloat(languor) * 0.45), hurrying)
    }

    /// How long he looks before he decides. Scales with the drop, because a cat weighs a big
    /// one for longer.
    public static func hesitation(forDrop drop: CGFloat) -> TimeInterval {
        Feel.Timing.edgeHesitationMin
            + (Feel.Timing.edgeHesitationMax - Feel.Timing.edgeHesitationMin) * ramp(drop)
    }

    /// Chance he goes through with it. Short drops nearly always; long ones sometimes not.
    ///
    /// **This is where the reluctance lives.** The physics deliberately has no maximum drop
    /// (under a minimum-energy launch a deeper target is *more* reachable, not less), so the
    /// judgement has to be behavioural. A cat that cannot make the jump is a platformer
    /// character; a cat that can and declines is a cat.
    ///
    /// Never zero, deliberately: a drop he will not take under any circumstances is a cat
    /// stranded on the menu bar for the rest of the session, and the way down from there is
    /// the app's entire demo.
    public static func commitChance(forDrop drop: CGFloat) -> Double {
        1 - Feel.Physics.edgeRefusal * ramp(drop)
    }

    /// 0 at no drop at all, 1 at the drop where he is as wary as he ever gets.
    private static func ramp(_ drop: CGFloat) -> Double {
        Double(min(1, max(0, drop / Feel.Physics.edgeHesitationDrop)))
    }

    /// Which lip to walk off, given where he is ultimately trying to end up: the nearest one to
    /// the DESTINATION that actually has something under it.
    ///
    /// Nearest the destination rather than nearest him, because from the middle of a full-width
    /// menu bar both edges are exactly as far away and only one of them is on the way.
    private static func stepOffLip(from s: CatState, on surface: Surface, toward destX: CGFloat,
                                   world: Skyline) -> (x: CGFloat, dir: CGFloat)? {
        [CGFloat(1), -1]
            .compactMap { dir -> (x: CGFloat, dir: CGFloat)? in
                guard let x = edgeAhead(from: s.position.x, facing: dir, on: surface),
                      isCliff(at: x, facing: dir, on: surface, world: world) else { return nil }
                return (x, dir)
            }
            .min { abs($0.x - destX) < abs($1.x - destX) }
    }

    /// The single best next step toward a destination. Deliberately dumb: no A*, no navigation
    /// mesh, one hop of lookahead and a greedy choice. Called again on every landing and at the
    /// end of every step, which is what turns a chain of these into a route, and what lets a
    /// jump he fluffs become the new starting point rather than a dead end.
    ///
    /// **This is final.** The mind layer replaces only the code that chooses a destination.
    public static func nextMove(from s: CatState, on surface: Surface,
                                toward destID: SurfaceID, x destX: CGFloat,
                                world: Skyline, mayWalk: Bool = true) -> Move? {
        // Already there: just walk, unless the cutout is in the way, in which case it is a
        // tunnel rather than a wall and he goes through it.
        if destID == surface.id {
            return notchCrossing(from: s.position.x, to: destX, on: surface, world: world)
                ?? .walk(destX)
        }

        guard let dest = world.surface(destID) else { return nil }
        let here = s.position

        // A crack, not a canyon. Measured between the two surfaces rather than between him and
        // the far side, so he walks to the lip and steps across instead of only ever striding
        // when he happens to be standing on it already.
        //
        // `spans`, not `solid`: he is CHOOSING where to put himself down, and `solid` includes
        // the parts of the far window that are hidden behind something else. Striding onto one
        // of those is a legal place to stand and an absurd place to be seen, which is the
        // distinction the two arrays exist to draw.
        if abs(dest.y - surface.y) <= Feel.World.coplanarTolerance,
           let far = nearestSpanX(to: here.x, in: dest.spans),
           let lip = edgeAhead(from: here.x, facing: far > here.x ? 1 : -1, on: surface),
           // Measured between STANDABLE spans, and `World.build` insets every window's by
           // `cornerInset` at each end, so the number here is the physical crack plus 20.
           // Compared against the bare `strideGap` (a constant written about the crack itself)
           // the stride only ever fired for cracks of 0 to 4 points, and `stepAcross`'s own doc
           // names a six-point crack between two tiled windows as the thing a leap must never
           // be used for. Six was exactly what got a leap.
           abs(far - lip) <= Feel.Physics.strideGap + 2 * Feel.World.cornerInset {
            return abs(here.x - lip) <= Feel.Physics.arrivalSlop
                ? .stepAcross(destID, far) : .walk(lip)
        }

        // The same line, not another ledge. A fullscreen or maximized window's top edge is
        // coplanar with the menu bar, and every landing on that shared line grounds him on
        // the bar (`supportBelow` tie-breaks to the frontmost z), so a jump at the window
        // can never arrive: he re-plans on every touchdown and leaps against the top of the
        // screen forever. Ground that is coplanar AND under his own solid is walked, and
        // being there already is nil ("no route"), which is what lets `advance` settle him
        // rather than chase an identity he can never hold.
        if abs(dest.y - surface.y) <= Feel.World.coplanarTolerance,
           surface.solid.contains(where: { $0.contains(destX) }) {
            return abs(destX - here.x) > Feel.Physics.arrivalSlop * 3 ? .walk(destX) : nil
        }

        // Straight there in one hop.
        if let x = aimX(on: dest, from: here, toward: destX),
           clears(surface, from: here, to: CGPoint(x: x, y: dest.y)) {
            return .jump(destID, x)
        }

        // Otherwise the reachable surface that gets him closest to the destination.
        let target = CGPoint(x: destX, y: dest.y)
        let hop = world.surfaces
            .filter { $0.id != surface.id && $0.targetable && !$0.spans.isEmpty }
            // Never further from the destination's HEIGHT than he already is. Straight-line
            // distance on its own always votes for the floor: he can drop a thousand points
            // for nothing and climb a hundred and ninety, so the one axis he cannot undo has
            // to be the one he refuses to lose ground on.
            .filter { abs($0.y - dest.y) <= abs(surface.y - dest.y) }
            .compactMap { other -> (id: SurfaceID, x: CGFloat, d: CGFloat)? in
                guard let x = aimX(on: other, from: here, toward: destX),
                      clears(surface, from: here, to: CGPoint(x: x, y: other.y)) else { return nil }
                return (other.id, x, hypot(x - target.x, other.y - target.y))
            }
            .min { $0.d < $1.d }

        // Only take the hop if it is actually progress, or he ping-pongs between two ledges.
        let current = hypot(here.x - target.x, here.y - target.y)
        if let hop, hop.d < current - Feel.Physics.arrivalSlop {
            return .jump(hop.id, hop.x)
        }

        // Nothing in the air and the destination is above him, but there may be a curtain.
        // A window's FACE is a route and not just an obstacle, and it is the only way off the
        // desktop: `jumpImpulse` buys 190pt of rise against windows that are routinely five
        // times that tall, so without it he is stranded down there for the session.
        //
        // Below the hop deliberately. A climb is slower and more committing than a leap, so it
        // is what he does when leaping will not do.
        if dest.y > surface.y,
           let climb = climbTarget(on: surface, toward: destX, target: target, world: world) {
            return .climb(climb.id, climb.x)
        }

        // Nothing in the air, and the destination is below him. A lip is only a route if
        // stepping off it gains ground. From a window's end it almost always does. From the
        // menu bar, whose only lips are the screen corners, a step-off walks the whole bar
        // and drops a thousand points into a corner nowhere near where he was going. When
        // the lip loses ground and the target sits under his own solid with nothing in
        // between, he hops down the glass instead, with the same tell the edge gets.
        // ponytail: lip-vs-drop is progress-based, not time-costed; revisit if corner
        // walks still read dumb on a real desktop
        if dest.y < surface.y {
            let lipGains: Bool = {
                guard let lip = stepOffLip(from: s, on: surface, toward: destX, world: world),
                      let below = landing(past: lip.x, facing: lip.dir, on: surface,
                                          world: world) else { return false }
                return hypot(lip.x - destX, below.y - dest.y)
                    < hypot(here.x - destX, here.y - dest.y) - Feel.Physics.arrivalSlop
            }()
            if lipGains { return .stepOff }
            if let x = standingRoom(near: destX, in: dest.spans),
               surface.solid.contains(where: { $0.contains(x) }),
               world.supportBelow(x: x, from: surface.y - Feel.World.coplanarEpsilon,
                                  to: -.greatestFiniteMagnitude)?.id == destID {
                return .drop(destID, x)
            }
            return .stepOff
        }

        // Nothing in the air and the destination is above. Walk to the point on his own ledge
        // nearest to it and ask again from there: half of getting somewhere is standing in the
        // right place first, and without this a hop he lands mid-ledge is a dead end.
        //
        // `spans`, not `solid`, for the same reason the stride above uses it: he is choosing
        // where to put himself, and the hidden part of his own ledge is a legal place to stand
        // and an absurd place to walk to on purpose.
        //
        // But only if standing there would open a route he does not have now. Unconditional,
        // this branch accepts destinations that no impulse can ever reach: he walks to the spot
        // underneath, arrives, re-plans, and does it again for ever. Measured at 49.1% of every
        // decision on a bare desktop, where the menu bar is 1115pt up and `jumpImpulse` buys
        // 190pt of rise, with under half of all intents ever reaching the surface they named.
        //
        // The question is asked by moving him there hypothetically and re-routing. `mayWalk`
        // makes the depth exactly one: the re-ask cannot reach this branch, so the recursion
        // terminates by construction rather than by an argument about the geometry.
        //
        // Note this branch is only ever reached for an upward destination with nothing to
        // climb, since `climbTarget` does not depend on where he is standing.
        if mayWalk,
           let x = nearestSpanX(to: destX, in: surface.spans),
           abs(x - here.x) > Feel.Physics.arrivalSlop * 2 {
            var there = s
            there.position.x = x
            if nextMove(from: there, on: surface, toward: destID, x: destX,
                        world: world, mayWalk: false) != nil {
                return .walk(x)
            }
        }
        return nil
    }

    /// Did he set out to climb this particular face?
    ///
    /// Read off the intent rather than stored on the `Grip`, because the intent already knows
    /// and a second copy of the answer is a second copy that can disagree with the first.
    static func climbing(_ s: CatState, _ id: SurfaceID) -> Bool {
        if case .climb(let target, _)? = s.intent?.move { return target == id }
        return false
    }

    /// How high he throws himself at a face: enough to be INSIDE it with upward speed left
    /// over, since the grab only fires while he is rising. See `Feel.Physics.climbBite`.
    ///
    /// One function because two callers have to agree exactly: the router uses it to decide
    /// whether a face is climbable at all (`launch` returning nil IS the reachability test),
    /// and the launch uses it to decide how hard to push. A gate that admitted a face the
    /// leap then could not reach is precisely the jump-and-fall-back cycle.
    static func climbLift(to rect: CGRect, from p: CGPoint) -> CGFloat {
        max(0, rect.minY - p.y) + Feel.Physics.climbBite
    }

    /// The window face he can get up that leaves him closest to where he is going, or nil.
    ///
    /// Four conditions, all physical rather than arbitrary:
    /// - its top edge is meaningfully above the ledge he is on, or the climb is not a climb
    ///   (and a face he would cross in one tick is one the grab could miss);
    /// - the bottom of the face is within one leap, which is `launch` answering, not a table;
    /// - the leap starts from a point on his own `solid` that lies inside the window's width,
    ///   since he goes up vertically and has to already be under it;
    /// - and getting up there is progress, the same bar the hop has to clear, without which
    ///   he would climb something that takes him further away and then climb back.
    ///
    /// **Nothing in here depends on where he is standing**, only on the destination, his
    /// surface, and the candidate rects. That is what makes "walk to it, then re-plan on
    /// arrival" terminate: he gets the same answer when he arrives as the one that sent him.
    /// Which is why progress is measured from the LAUNCH point rather than from his feet: the
    /// same trade, asked at the place the trade is actually made, and it reduces to the honest
    /// question, does going up leave me vertically nearer than staying on this ledge. Measured
    /// from his feet it would admit a climb from across the room and refuse the identical climb
    /// once he had walked under it, which is a wasted trip rather than a cycle but is still not
    /// the router meaning what it says.
    private static func climbTarget(on surface: Surface, toward destX: CGFloat,
                                    target: CGPoint,
                                    world: Skyline) -> (id: SurfaceID, x: CGFloat)? {
        world.surfaces
            .filter { $0.targetable && !$0.spans.isEmpty }
            .compactMap { other -> (id: SurfaceID, x: CGFloat, d: CGFloat)? in
                guard let rect = other.rect,
                      rect.maxY > surface.y + Feel.Physics.climbBite,
                      let x = nearestSpanX(to: min(max(destX, rect.minX + Feel.World.cornerInset),
                                                   rect.maxX - Feel.World.cornerInset),
                                           in: surface.solid),
                      // Half-open on the right, because `CGRect.contains` is, and the grab on
                      // the way up is exactly that test, so a launch this admitted at maxX
                      // would rise through a face that refused to hold him.
                      rect.minX <= x, x < rect.maxX,
                      {
                          var noAimError = Roll(seed: 0)   // jitter 0: nothing is drawn
                          return launch(dx: 0,
                                        dy: climbLift(to: rect, from: CGPoint(x: x, y: surface.y)),
                                        jitter: 0, using: &noAimError) != nil
                      }() else { return nil }
                let from = hypot(x - target.x, surface.y - target.y)
                let d = hypot(x - target.x, other.y - target.y)
                return d < from - Feel.Physics.arrivalSlop ? (other.id, x, d) : nil
            }
            .min { $0.d < $1.d }
            .map { ($0.id, $0.x) }
    }

    /// Does the arc to `to` get out from over the ledge he is launching from?
    ///
    /// Every jump starts upward, so a target BELOW his own surface means coming back down
    /// through it, and `supportBelow` is inclusive at both ends and has no idea which surface
    /// he left, so he re-grounds wherever the arc re-crosses his own y over his own solid.
    /// Testing the LANDING x instead misses that entirely: the minimum-energy launch is flat,
    /// and menu-bar-to-desktop at 500pt across re-crosses only 44pt out.
    ///
    /// This is also the whole discriminator between `.jump` and `.stepOff`. A deep drop is
    /// nearly free under minimum energy, so without it every downward destination is a jump and
    /// `.stepOff` is dead code. With it the rule is physical rather than arbitrary: if he can
    /// get clear of his own ledge he jumps, and if he cannot he walks to the edge and drops.
    static func clears(_ surface: Surface, from: CGPoint, to: CGPoint) -> Bool {
        guard to.y < surface.y else { return true }
        var noAimError = Roll(seed: 0)   // jitter 0: nothing is drawn
        guard let v = launch(dx: to.x - from.x, dy: to.y - from.y, jitter: 0,
                             using: &noAimError) else { return false }
        // Range at launch height: 2·vx·vy/g, but he judges soberly and executes with a wobble,
        // so what he actually gets is that range scaled by (1 ± aimError)². Every crossing in
        // that band has to clear, not just the sober one: a jump whose sober crossing sits a
        // few points past his own lip comes back down ON it on a low draw. Testing the band
        // rather than its two ends because his own solid can have a hole in the middle of it:
        // the notch is exactly that, and threading a jump through the doorway is the one
        // downward jump on a bare desktop that does work.
        let range = 2 * v.dx * v.dy / Feel.Physics.gravity
        let low = range * (1 - Feel.Physics.aimError) * (1 - Feel.Physics.aimError)
        let high = range * (1 + Feel.Physics.aimError) * (1 + Feel.Physics.aimError)
        let band = (from.x + min(low, high))...(from.x + max(low, high))
        return !surface.solid.contains { $0.overlaps(band) }
    }

    /// The point on `surface` he can actually reach that sits closest to `x`, or nil if none of
    /// it is in range. Deterministic: the router compares candidates to decide which way to
    /// move, and a random draw would have it change its mind on every landing.
    static func aimX(on surface: Surface, from: CGPoint, toward x: CGFloat) -> CGFloat? {
        let reach = reachX(dy: surface.y - from.y)
        guard reach > 0 else { return nil }
        let window = (from.x - reach)...(from.x + reach)
        let runs = surface.spans.filter { $0.overlaps(window) }.map { $0.clamped(to: window) }
        guard let nearest = nearestSpanX(to: x, in: runs),
              let run = runs.first(where: { $0.contains(nearest) }) else { return nil }
        // Off the lip, but by LESS than the error he is about to make. Aiming at a corner is a
        // coin flip on falling past it, so some margin has to exist; a margin as wide as the
        // scatter itself (±2·aimError of the throw, since range goes as (1 ± aimError)²) makes
        // a whole class of jump one he cannot fluff. At 2·aimError he could not sail past a far
        // lip AT ALL (worst overshoot reaches 0.9888 of it) and fell short of a near one on
        // only 4% of draws. Half that leaves 1.0562 and 26%: off the lip, still fallible.
        // Preserve the failure cases: they are where the charm lives.
        //
        // The refusal below is the part that keeps him sensible, and it is deliberately twice
        // the margin. A run too narrow to hold it is not a target at all: he would be clipping
        // the very corner of a ledge at the very limit of his reach, which is where the low
        // half of the error stops being a wobble and becomes a fall. He walks closer and asks
        // again instead.
        let margin = Feel.Physics.aimError * abs(nearest - from.x)
        guard run.length >= 4 * margin else { return nil }
        return min(max(nearest, run.lowerBound + margin), run.upperBound - margin)
    }

    /// One thing to do about being bored: go somewhere, or stay and lounge.
    public enum Idea: Sendable, Equatable { case go(Intent), lounge }

    /// The election. This is where his taste lives. A coin flip in its place chooses
    /// destinations exactly as often as randomness predicts: choice and dwell measure out as
    /// the same distribution.
    ///
    /// Candidates from every visible span plus the null candidate, scored, drawn with a
    /// temperature, and checked against routing. Drawn again from the remainder if
    /// `nextMove` refuses. The lounge always routes, because it is not a move; that makes
    /// nil unreachable in practice, and the branch stays for the day the lounge is ever
    /// conditional.
    ///
    /// **This chooses a destination and nothing else.** `nextMove` is final, and the scorer
    /// never assumes reachability: unroutable dreams simply lose the draw.
    static func idea(from s: inout CatState, on surface: Surface, world: Skyline) -> Idea? {
        var pool = [Candidate(id: nil, x: s.position.x, y: s.position.y)]
        for other in world.surfaces where other.targetable {
            for span in other.spans where span.length > Feel.World.minStandWidth {
                pool.append(Candidate(id: other.id,
                                      x: .random(in: span.lowerBound...span.upperBound, using: &s.roll),
                                      y: other.y))
            }
        }
        var scores = pool.map { score($0, from: s, world: world) }
        while let i = draw(scores, temperature: Feel.Taste.temperature,
                           roll: .random(in: 0..<1, using: &s.roll)) {
            let c = pool[i]
            if let id = c.id {
                // A stroll to the spot he is already standing on is not an idea.
                let arrived = id == surface.id
                    && abs(c.x - s.position.x) < Feel.Physics.arrivalSlop * 2
                if !arrived, let move = nextMove(from: s, on: surface, toward: id, x: c.x,
                                                 world: world) {
                    return .go(Intent(destination: id, destinationX: c.x, move: move))
                }
            } else {
                return .lounge
            }
            pool.remove(at: i)
            scores.remove(at: i)
        }
        return nil
    }

    /// One thing the election could choose. `id == nil` is the null candidate: stay here
    /// and lounge.
    public struct Candidate: Sendable, Equatable {
        public let id: SurfaceID?
        public let x: CGFloat
        public let y: CGFloat
        public init(id: SurfaceID?, x: CGFloat, y: CGFloat) {
            self.id = id; self.x = x; self.y = y
        }
    }

    /// What a place offers him right now. Spec §2: every urge lands in 0…1 before
    /// weighting, and the weights are the personality. Pure (the memory and the world go
    /// in, one number comes out), so each urge's arithmetic is testable on its own.
    static func score(_ c: Candidate, from s: CatState, world: Skyline) -> Double {
        typealias T = Feel.Taste
        guard let id = c.id else { return T.loungeBase }
        let place = s.memory[id]
        // New furniture stays interesting for minutes, not for a glance. The launch world
        // carries firstSeen = -infinity and is never novel.
        let novelty: Double = {
            guard let p = place, p.firstSeen > -.infinity else { return 0 }
            return exp(-(s.age - p.firstSeen) / T.noveltyHalfLife)
        }()
        // A perch he has not used in a while feels fresh again; never visited is fully so.
        let stale: Double = {
            guard let p = place, p.lastVisit > -.infinity else { return 1 }
            return 1 - exp(-(s.age - p.lastVisit) / T.staleHalfLife)
        }()
        let floorY = world.surface(.floor)?.y ?? 0
        let barY = world.surface(.menuBar)?.y ?? floorY + 1
        let height = Double(min(max((c.y - floorY) / max(barY - floorY, 1), 0), 1))
        let near = s.cursor.map { Double(exp(-hypot($0.x - c.x, $0.y - c.y) / T.nearScale)) } ?? 0
        let visits = Double(place?.visits ?? 0)
        let familiar = visits / (visits + T.familiarVisits)
        let effort = Double(min(1, hypot(c.x - s.position.x, c.y - s.position.y) / T.effortScale))
        return T.wNovelty * novelty + T.wStale * stale + T.wHeight * height
             + T.wNear * near + T.wFamiliar * familiar - T.wEffort * effort
    }

    /// Which index a softmax draw lands on, given one uniform roll in [0, 1). Pure, so the
    /// arithmetic is testable exactly; the caller supplies the randomness.
    static func draw(_ scores: [Double], temperature: Double, roll: Double) -> Int? {
        guard !scores.isEmpty else { return nil }
        let top = scores.max()!             // subtracted for numeric stability only
        let weights = scores.map { exp(($0 - top) / temperature) }
        var mark = roll * weights.reduce(0, +)
        for (i, w) in weights.enumerated() {
            mark -= w
            if mark < 0 { return i }
        }
        return scores.count - 1
    }

    /// Is he standing at the lip of an interior hole (a den door), and if so, which way faces
    /// OUT of it and where he has to stand so that none of him is drawn inside it.
    ///
    /// Nil everywhere else, which is all of a notchless Mac and all of the bar except the two
    /// lips of the cutout. `isGap` alone is not enough: it answers "does solid resume somewhere
    /// ahead", which is true anywhere left of the notch, so the lip itself has to be underfoot.
    static func denDoor(_ s: CatState, on surface: Surface) -> (out: CGFloat, standAt: CGFloat)? {
        // A body-width of reach, not a footstep. He does not *wait* on the lip, because everything
        // past it is a hardware hole with no pixels behind it and half a cat reads as a broken
        // sprite. So standing clear of it has to still count as standing at the door, or the
        // pose he waits in would never play at all.
        let reach = Feel.Shape.clearance + Feel.Physics.arrivalSlop * 3
        for dir: CGFloat in [1, -1] {
            if let edge = edgeAhead(from: s.position.x, facing: dir, on: surface),
               abs(edge - s.position.x) <= reach,
               isGap(at: edge, facing: dir, on: surface) {
                return (out: -dir, standAt: edge - dir * Feel.Shape.clearance)
            }
        }
        return nil
    }

    /// Head and paws over the lowest lip above him that you could actually see him on.
    /// Returns false if there is no such lip.
    ///
    /// He is BEHIND all of it, so the scramble up is unseen by construction, which is what
    /// makes arriving at the top directly honest rather than a cheat. The visible event is a
    /// head appearing over an edge, and it is the same event either way.
    ///
    /// **The lowest VISIBLE one, not the window he happens to be under.** A fullscreen Chrome
    /// is four stacked full-width bands: the one that buried him has its own top edge buried
    /// under the next, so its lip is not a place anyone could see him, and asking only about
    /// the window directly overhead left him sitting on the floor of a covered screen for as
    /// long as it lasted. Walking up the stack finds the first edge that is actually on show.
    ///
    /// Somewhere random along that lip, rather than directly above wherever he was hiding.
    /// He came up in the same spot every time otherwise, because the place he gets buried is
    /// itself the same most days, and a cat who always appears at the same x reads as a
    /// scripted popup instead of a cat. `standingRoom` keeps the draw off both ends of the
    /// run, which is what stops a random x putting half of him inside the notch or past the
    /// edge of the panel.
    ///
    /// Callers must check `isHidden` first. Nothing here can tell whether he is currently on
    /// screen, and moving a cat you can see is the one thing this must never do. That check
    /// is also what makes the sideways jump free: there is nobody to see it happen.
    static func surfaceOverTheLip(_ s: inout CatState, world: Skyline) -> Bool {
        let above = world.surfaces
            .filter { $0.targetable && $0.y > s.position.y + Feel.World.coplanarEpsilon }
            .sorted { $0.y < $1.y }
        guard let lip = above.first(where: { !$0.spans.isEmpty }),
              let x = standingRoom(near: randomX(in: lip.spans, using: &s.roll), in: lip.spans)
        else { return false }
        s.support = .grounded(Perch(id: lip.id, dx: x - lip.extent.lowerBound))
        s.position = CGPoint(x: x, y: lip.y)
        s.activity = .peer
        s.activityElapsed = 0
        // Cleared for the covered-screen caller, which arrives here with the retreat's own
        // intent live. Left over, it would walk him straight back off the lip he just reached.
        s.intent = nil
        s.lastPerchOrigin = nil
        s.lastPerchID = nil
        return true
    }

    /// Home enough, for the standing order: on the menu bar itself, or on any surface
    /// sharing the top line, which is what a fullscreen window's own top edge is.
    static func upTop(_ s: CatState, on surface: Surface, world: Skyline) -> Bool {
        surface.id == .menuBar
            || surface.y >= (world.surface(.menuBar)?.y ?? .infinity)
                - Feel.World.coplanarTolerance
    }

    /// Is he behind something, where you cannot see him?
    ///
    /// A lookup rather than a computation. `Surface.spans` is defined as `solid` minus every
    /// window in front, which is exactly "where he is visible", so the occlusion work already
    /// done for rendering answers this for free. Only while grounded: falling, clinging and
    /// being carried are all brief, and a cat who ducks behind a window mid-leap has not been
    /// abandoned there.
    public static func isHidden(_ s: CatState, world: Skyline) -> Bool {
        guard case .grounded(let p) = s.support, let surface = world.surface(p.id) else {
            return false
        }
        return !surface.spans.contains { $0.contains(s.position.x) }
    }

    /// The box your cursor has to be inside for him to count as being in your way: the rect
    /// he was DRAWN in, padded by the same `hitPad` the click rect uses, so the two are one
    /// figure. `App.hitRect` decides whether his window swallows your clicks, and this must
    /// be that rect. Built from the nominal 52×34 instead, it missed every drawn point
    /// outside it (the sprite is normalised on eye width and is usually larger), so a cursor
    /// parked on his ear ate clicks for ever and the yield never saw it.
    ///
    /// The nominal figure only stands in before the first render, when nothing has been
    /// drawn and nothing can be clicked anyway.
    public static func hisBox(_ s: CatState) -> CGRect {
        let box = s.drawnBox ?? CGRect(x: s.position.x - Feel.Shape.width / 2,
                                       y: s.position.y,
                                       width: Feel.Shape.width, height: Feel.Shape.height)
        return box.insetBy(dx: -Feel.Shape.hitPad, dy: -Feel.Shape.hitPad)
    }

    /// Where to stop so he is beside your cursor rather than on top of it, or nil if there is
    /// no standable spot on this surface that clears it.
    ///
    /// He settles on the side he is arriving from, so he does not walk past the thing he came
    /// for and turn round. The clearance is half of `width` plus `cursorGap`: the caller
    /// passes his DRAWN width when there is one, because the sprite is usually larger than
    /// the nominal figure and a clearance measured against the smaller box can settle his
    /// drawn edge onto the cursor.
    ///
    /// **He must never come to rest ON the cursor.** `Overlay.setInteractive` toggles
    /// `ignoresMouseEvents` from exactly "is the cursor inside his hit rect", so a cat parked on
    /// your cursor is a cat swallowing every click you make until he moves. The rule
    /// asks for him to curl up on it; that is a defect by construction and this refuses it. A
    /// cat does not sit on your hand, it sits against your hand.
    public static func beside(cursor: CGPoint, on surface: Surface, from x0: CGFloat,
                              width: CGFloat = Feel.Shape.width) -> CGFloat? {
        let clear = width / 2 + Feel.Mind.cursorGap
        let near = cursor.x + (x0 < cursor.x ? -clear : clear)
        let far = cursor.x + (x0 < cursor.x ? clear : -clear)
        // The near side first, then the far one, so a cursor at the very end of a ledge still
        // gets him beside it rather than nowhere.
        for want in [near, far] {
            guard let x = standingRoom(near: want, in: surface.spans) else { continue }
            if abs(x - cursor.x) >= clear { return x }
        }
        return nil
    }

    /// Which walkable surface a stimulus at this point belongs to, if any.
    ///
    /// Matched on the top edge, because that is what a stimulus carries and what he can
    /// actually stand on: a window opening reports its own `y`, and an app activation reports
    /// its window's `maxY`, which is the same line. Nearest rather than exact, with the same
    /// tolerance that decides whether two ledges are one shelf, so a point or two of drift
    /// between the raw snapshot and the built skyline cannot lose the match.
    ///
    /// Nil is a legitimate answer and not a failure. It means a thing he can look at but not
    /// visit, which is most of what happens on a screen.
    static func surfaceAt(_ p: CGPoint, in world: Skyline) -> Surface? {
        world.surfaces
            .filter { $0.targetable && !$0.spans.isEmpty }
            .min { abs($0.y - p.y) < abs($1.y - p.y) }
            .flatMap { abs($0.y - p.y) <= Feel.World.coplanarTolerance ? $0 : nil }
    }

    /// A uniformly random point across a set of spans, weighted by their length so a 30pt
    /// sliver is not as likely as the rest of the screen. Falls back to the first span's start
    /// when the run has no length at all.
    static func randomX(in spans: [ClosedRange<CGFloat>], using roll: inout Roll) -> CGFloat {
        let total = spans.reduce(0) { $0 + $1.length }
        guard total > 0 else { return spans.first?.lowerBound ?? 0 }
        var mark = CGFloat.random(in: 0...total, using: &roll)
        for span in spans {
            if mark <= span.length { return span.lowerBound + mark }
            mark -= span.length
        }
        return spans[spans.count - 1].upperBound
    }

    /// The point on these spans closest to `x`, kept back from their outer ends so he does not
    /// arrive standing on a lip.
    ///
    /// Every deliberate destination in the mind layer goes through here, and `nearestSpanX`
    /// clamps to the boundary exactly. A uniform point inside a span lands on its end with
    /// essentially zero probability; a clamped one lands there routinely, and the menu bar's
    /// outer ends are cliffs: a walk to x=5, a step off the left end of the bar, and a drop to
    /// the desktop he cannot climb back from.
    ///
    /// Inset by `edgeApproach`, the distance a step-off aims past a lip. Spans shorter than
    /// twice that get their midpoint, since there is nowhere in them that is not near an end.
    static func standingRoom(near x: CGFloat, in spans: [ClosedRange<CGFloat>]) -> CGFloat? {
        let inset = Feel.Physics.edgeApproach
        return spans.map { span -> CGFloat in
            guard span.length > inset * 2 else { return (span.lowerBound + span.upperBound) / 2 }
            return min(max(x, span.lowerBound + inset), span.upperBound - inset)
        }.min { abs($0 - x) < abs($1 - x) }
    }

    /// The point on these spans closest to `x`. Deterministic, unlike `landingX`: the router
    /// compares candidate distances to decide which way to move, and a random draw would make
    /// it change its mind every tick.
    static func nearestSpanX(to x: CGFloat, in spans: [ClosedRange<CGFloat>]) -> CGFloat? {
        spans.map { min(max(x, $0.lowerBound), $0.upperBound) }
             .min { abs($0 - x) < abs($1 - x) }
    }

    /// The **cheapest** launch that hits `(dx, dy)`. Nil means he cannot make it: `jumpImpulse`
    /// is a ceiling on effort, and running out of it *is* the reachability test.
    ///
    /// Of the infinitely many arcs through a point, the minimum-energy one is
    ///     v_min² = g·(dy + r),  θ = atan2(dy + r, |dx|),  r = √(dx² + dy²)
    /// so speed, apex and hang time all rise with distance and a long jump visibly costs more
    /// than a short one. Solving instead for the angle at a *fixed* speed inverts that: it
    /// sends a 60pt hop off at 85°, 189pt into the air for 0.87s, against 98pt and 0.63s for a
    /// 380pt leap, a hop that outclimbs and outhangs the leap.
    ///
    /// `v_min ≤ jumpImpulse` is algebraically the discriminant: solving
    /// `v⁴ − 2g·dy·v² − g²dx² ≥ 0` for v² gives exactly `v² ≥ g(dy + r)`. So the set of
    /// reachable targets, `reachX` and `canReach` all agree with this solve; only the
    /// `(speed, angle)` pair chosen inside it is particular to it.
    ///
    /// The error is on the **speed**, not the angle. At the minimum-energy solution the target
    /// sits at a tangency, so angular error is second-order and he would never miss; and
    /// `min(v, …)` means the jumps at the very edge of his reach can only ever fall short.
    /// A cat misjudges how hard to push off. It does not misjudge which way is up.
    ///
    /// Note that a *downward* target lowers `v_min`, so deep drops are more reachable, not
    /// less. That is physically right, and it is why the reluctance to make a big drop lives
    /// in the hesitation at the edge rather than in a constant here.
    public static func launch(dx: CGFloat, dy: CGFloat,
                              speed v: CGFloat = Feel.Physics.jumpImpulse,
                              g: CGFloat = Feel.Physics.gravity,
                              jitter: CGFloat = Feel.Physics.aimError,
                              using roll: inout Roll) -> CGVector? {
        // r ≥ |dy|, so dy + r ≥ 0 and neither root can be NaN. atan2 also handles dx = 0,
        // which is why this needs no straight-up special case and no angle clamp: θ lands in
        // [0, π/2] by construction and nothing perturbs it.
        let r = (dx * dx + dy * dy).squareRoot()
        let vMin = (g * (dy + r)).squareRoot()
        guard vMin <= v else { return nil }

        let noise = jitter > 0 ? CGFloat.random(in: -jitter...jitter, using: &roll) : 0
        let t = atan2(dy + r, abs(dx))
        let speed = min(v, vMin * (1 + noise))
        return CGVector(dx: cos(t) * speed * (dx < 0 ? -1 : 1), dy: sin(t) * speed)
    }

    /// How far he can throw himself sideways to arrive `dy` above his feet (negative for a
    /// drop). Zero means that height is out of reach at any angle. Same limit `launch` tests,
    /// solved for x instead of for yes-or-no, so a landing spot can be *chosen* from the
    /// reachable interval rather than proposed and rejected.
    ///
    /// Flat that is v²/g = 380pt; straight up, v²/2g = 190pt.
    static func reachX(dy: CGFloat, v: CGFloat = Feel.Physics.jumpImpulse,
                       g: CGFloat = Feel.Physics.gravity) -> CGFloat {
        max(0, v * v * v * v - 2 * g * dy * v * v).squareRoot() / g
    }

    /// Can he make this jump at all? Derived from physics, not asserted by a constant.
    /// Aimed soberly on purpose: he judges without the jitter and then executes with it,
    /// which is what lets him commit to a jump and still fall short of it.
    public static func canReach(from: CGPoint, to: CGPoint) -> Bool {
        {
            var noAimError = Roll(seed: 0)   // jitter 0: nothing is drawn
            return launch(dx: to.x - from.x, dy: to.y - from.y, jitter: 0,
                          using: &noAimError) != nil
        }()
    }

    /// Where solid ground runs out in the direction he is facing, in world x.
    /// Nil means he is not standing on solid ground at all.
    ///
    /// Nothing may clamp him inside `extent`: that makes the fall-off guard in `step`
    /// unreachable and he can never walk off anything.
    public static func edgeAhead(from worldX: CGFloat, facing: CGFloat,
                                 on surface: Surface) -> CGFloat? {
        guard let range = surface.solid.first(where: { $0.contains(worldX) }) else { return nil }
        return facing > 0 ? range.upperBound : range.lowerBound
    }

    /// Is there anywhere to land past that edge? Cliff if yes, wall if no.
    static func isCliff(at x: CGFloat, facing: CGFloat, on surface: Surface, world: Skyline) -> Bool {
        landing(past: x, facing: facing, on: surface, world: world) != nil
    }

    /// The same question, answered with the surface itself so `Footing` can measure the drop.
    /// One implementation, because a `Footing` that disagreed with `isCliff` would have him
    /// hesitating at edges he walks straight over and stepping off ones he stops at.
    ///
    /// Nil covers two of the three cases. A hole with more of the SAME surface beyond it is a
    /// gap, not a cliff, and a gap is a wall (`isGap`). The notch is the only one that exists
    /// (windows produce a single solid run and the floor is uncarved) and it is a trap rather
    /// than a ledge: he cannot jump to the surface he is standing on (`nextMove` walks there
    /// instead), and his whole impulse buys 190pt of rise against the thousand points back up
    /// from the desktop, so stepping into it is one-way.
    static func landing(past x: CGFloat, facing: CGFloat,
                        on surface: Surface, world: Skyline) -> Surface? {
        if isGap(at: x, facing: facing, on: surface) { return nil }
        return world.supportBelow(x: x, from: surface.y - Feel.World.coplanarEpsilon,
                                  to: -.greatestFiniteMagnitude)
    }

    /// Into the cutout, one of three ways.
    ///
    /// `out` is the direction that faces away from the hole, which `denDoor` already worked out,
    /// so it says which lip he is standing at, and therefore which wall is his to lean out of.
    ///
    /// - **hang**: from the middle of the underside, paws on the lower lip, doing pull-ups.
    /// - **peer down**: from the middle of the underside, head and paws over the lower lip.
    /// - **peer sideways**: from his own lip's *vertical* edge, head out into the lit strip
    ///   beside the cutout. Two thirds of the way up it, which is `notchLift`'s only job.
    ///
    /// The side one is drawn by turning the same sheet a quarter circle, so it costs no art.
    /// See `Sprites.turn`. That is also why it is the one that most wants its own drawing later.
    static func enterNotch(_ s: inout CatState, on surface: Surface,
                           notch: CGRect, out: CGFloat) {
        s.inNotch = true
        s.perchSpeed = 0
        s.activityElapsed = 0
        // Pointing back at the lip he came in by, which is how he gets out again.
        s.facing = out

        switch Int.random(in: 0..<3, using: &s.roll) {
        case 0, 1:
            // Under the middle of the hole. `facing` has to be re-derived here: he is no longer
            // at the lip he entered by, so "which way is out" becomes "which lip is nearer".
            s.position.x = notch.midX
            s.facing = out
            s.notchSide = .below
            s.notchLift = 0
            s.activity = Bool.random(using: &s.roll) ? .hang : .peerDown
        default:
            // Out of the side wall he is already standing at.
            let x = out < 0 ? notch.minX : notch.maxX
            s.position.x = x
            s.notchSide = out < 0 ? .left : .right
            s.notchLift = notch.height * Feel.Notch.sidePeekHeight
            s.activity = .peerDown
        }
        s.support = .grounded(Perch(id: surface.id,
                                    dx: s.position.x - surface.extent.lowerBound))
    }

    /// Back out of the cutout and onto a lip, wherever he was in there and whatever ended it.
    ///
    /// One function because four things can end a stay in the notch (the hold expiring, the
    /// freeze, the yield, waking up) and every one of them has to reposition him, not merely
    /// stop the behaviour. Standing inside the hole is legal only while `inNotch` says so, and
    /// clearing that without moving him is the trapdoor described on `CatState.inNotch`.
    ///
    /// He comes back out the side he went in, which `facing` remembers for free: it was pointed
    /// at his entry lip on the way in, and neither notch clip consults it, both being drawn
    /// head-on. Falls back to the other lip if his own has been inset away by a screen edge.
    static func leaveNotch(_ s: inout CatState, on surface: Surface, world: Skyline) {
        s.inNotch = false
        // Back the right way up, and back down onto the bar. Both belong to the pose, not to
        // the cat, and a stale one turns or lifts every drawing he has afterwards.
        s.notchSide = .below
        s.notchLift = 0
        guard let notch = world.screen.notch else { return }
        let goRight = s.facing > 0
        let near = goRight ? notch.maxX + Feel.Shape.clearance
                           : notch.minX - Feel.Shape.clearance
        let far = goRight ? notch.minX - Feel.Shape.clearance
                          : notch.maxX + Feel.Shape.clearance
        let x = surface.solid.contains(where: { $0.contains(near) }) ? near : far
        guard surface.solid.contains(where: { $0.contains(x) }) else { return }
        s.position.x = x
        s.support = .grounded(Perch(id: surface.id, dx: x - surface.extent.lowerBound))
        s.perchSpeed = 0
    }

    /// Going through the cutout rather than stopping at it.
    ///
    /// Without this the notch makes the menu bar two ledges that cannot reach each other.
    /// `isGap` reads the hole as a wall, correctly (walking *into* it is walking into a region
    /// with no pixels), but nothing else reads it as a doorway, so the far half of the bar is
    /// only reachable by going down onto a window and back up.
    ///
    /// Returns nil unless the cutout lies strictly between him and where he is going, so on a
    /// notchless Mac and on every surface that does not reach the cutout this costs one optional
    /// unwrap and disappears.
    ///
    /// The vertical test is the same one `World.punchNotch` uses to decide the hole exists at
    /// all, and it must stay that way: this is only legal on a ledge whose `solid` actually has
    /// the notch subtracted from it, and a fullscreen window's top edge is one of those too.
    static func notchCrossing(from x: CGFloat, to destX: CGFloat,
                              on surface: Surface, world: Skyline) -> Move? {
        guard let notch = world.screen.notch,
              surface.y < notch.maxY, surface.y + Feel.Shape.height > notch.minY,
              // Inclusive on both lips, because standing ON the near one is the normal way to
              // arrive here: the two-stage walk below aims at exactly `notch.minX`, and a
              // strict test made the second stage unreachable: he walked to the doorway and
              // then re-planned a walk to a destination he could not get to.
              min(x, destX) <= notch.minX, notch.maxX <= max(x, destX) else { return nil }
        let goingRight = destX > x
        let nearLip = goingRight ? notch.minX : notch.maxX
        let farLip = goingRight ? notch.maxX : notch.minX
        // The tunnel has to open onto something. Both lips are the bounds of the runs either
        // side, so this is normally true and is here for the screen edge case where the cutout
        // is not centred and one side has been inset away to nothing.
        guard surface.solid.contains(where: { $0.contains(farLip) }) else { return nil }
        // Walk to the doorway first, then step in. Same two-stage shape as `stepAcross`, and
        // for the same reason: the entry has to start from the lip or he clips the housing.
        return abs(x - nearLip) <= Feel.Physics.arrivalSlop * 3
            ? .crossNotch(farLip) : .walk(nearLip)
    }

    /// Does the surface resume past that edge? Then it is a hole, not the end of it.
    static func isGap(at x: CGFloat, facing: CGFloat, on surface: Surface) -> Bool {
        surface.solid.contains { facing > 0 ? $0.lowerBound > x : $0.upperBound < x }
    }
}
