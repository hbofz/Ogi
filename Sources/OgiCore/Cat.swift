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
/// to a drop, which is why v1 could not have a tell: the information did not exist.
public struct Footing: Sendable, Equatable {
    /// Distance to the end of solid ground in his facing direction. `.infinity` if he is
    /// not on solid ground, or airborne.
    public var edgeAhead: CGFloat = .infinity
    /// How far down to the next surface past that edge. Nil means there is nothing he could
    /// land on: a wall, or an interior gap, both of which he treats as a wall.
    public var dropAhead: CGFloat?
    /// What he would land on if he stepped off.
    public var landingAhead: SurfaceID?
    /// The same surface resumes past that edge: a hole, not the end of the world. He stops at
    /// both, but they are different beats, because a gap has a far side you can see across.
    /// Mutually exclusive with `isCliff`, since a gap is never something to step into.
    public var gapAhead = false

    public var isAtEdge: Bool { edgeAhead <= Feel.Physics.edgeApproach }
    public var isCliff: Bool { dropAhead != nil }
}

public enum Activity: Sendable, Equatable {
    case idle
    case groom      // washing, in place, while awake
    case sit        // no input for a while; cats settle when the room goes quiet
    case curl
    case sleep
    case alert      // frozen and listening: the mic went live
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
    /// Walk to the edge ahead and keep going. This is how he descends: gravity was always
    /// there, and v1 simply had no way to ask for it.
    case stepOff
    /// A gap small enough to stride over. No crouch, no arc — a full ballistic leap over a
    /// six-point crack between two tiled windows reads as a comedy pratfall.
    case stepAcross(SurfaceID, CGFloat)
}

/// Where he is ultimately going, and the current step toward it. Nil means he is content
/// where he is.
///
/// Storing the destination rather than a single hop is what gives multi-hop routing without a
/// pathfinder: he re-picks `move` every time he lands, hill-climbing toward `destination`, and
/// occasionally gets it wrong. The manifesto asks for exactly that — "pathfinding is
/// deliberately dumb ... preserve the failure cases; they are where the charm lives."
///
/// **This is the seam the mind layer plugs into.** v2b replaces only the code that chooses a
/// destination. `Cat.nextMove` is final.
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

/// How settled he is, from the machine's point of view.
public enum Repose: Sendable, Equatable {
    case awake, sitting, curled, asleep

    /// Manifesto §7.1. Cats settle when the room goes quiet.
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
    /// v1 returned early here and he became a statue at 30 seconds of *your* inactivity,
    /// which is what happens when you sit still and watch him.
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

public struct CatState: Sendable {
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
    /// Frozen and listening because the microphone went live. Also a privacy indicator.
    public var listening = false
    /// How far through the righting reflex he is, 0..1.
    public var righting: CGFloat = 1
    /// 0..1. Low battery or Low Power Mode. He moves less and settles sooner.
    public var languor: Double = 0
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
        // He scrabbles, then slides. Always a bounded state — he mantles onto the ledge or
        // runs out of wall — so this cannot hold the render rate up indefinitely.
        if case .clinging = support { return true }
        if intent != nil { return true }
        return squashElapsed < 0.4
    }

    /// He is settled and nothing is going to change until the world does.
    public var isResting: Bool {
        !isMoving && (repose != .awake || listening)
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
        // thinking about the clock — the settled branch reassigns it every single tick. Left to
        // itself, `sitdown` and `curl` are non-looping, so they were handed an elapsed time of
        // however long he had been idle and snapped straight to their last frame. Neither
        // animation had ever actually played.
        if s.activity != state.activity { s.activityElapsed = 0 }
        return s
    }

    private static func step(inner state: CatState, world: Skyline, dt: TimeInterval) -> CatState {
        var s = state
        s.activityElapsed += dt
        s.squashElapsed += dt
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
            s.activity = .cling
            s.velocity = .zero
            s.perchSpeed = 0

            if s.activityElapsed > Feel.Timing.clingHold {
                if grip.dy <= Feel.Physics.mantleReach {
                    // Close enough to the top: he climbs it and mantles onto the ledge.
                    grip.dy -= Feel.Physics.clingSlideSpeed * CGFloat(dt)
                    if grip.dy <= 0 {
                        // The column he climbed is not necessarily somewhere he can stand: a
                        // top edge is inset by the corner radius and clipped to the visible
                        // screen, so a grip in the top corner mantles onto nothing. He gets
                        // pulled along the lip to the nearest place that is real — and if the
                        // whole edge is unstandable there is nothing to mantle onto, so he
                        // lets go. Without this he grounded for exactly one tick and the
                        // shrunken-window backstop below dropped him straight off again.
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
            guard surface.solid.contains(where: { $0.contains(standingOn) }) else {
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
                s.footing.gapAhead = isGap(at: edge, facing: s.facing, on: surface)
                if let below = landing(past: edge, facing: s.facing, on: surface, world: world) {
                    s.footing.dropAhead = surface.y - below.y
                    s.footing.landingAhead = below.id
                }
            }

            // World position is derived. Surfing is free — he is already being carried.
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
            if abs(s.lean) > Feel.Physics.braceThreshold, s.intent == nil {
                s.activity = .brace
            } else if s.activity == .brace {
                s.activity = .idle
            }

        case .falling:
            // Nothing to push against. Whatever he was carrying along the ledge is spent on
            // the way over the lip, and `velocity` is the only thing moving him now.
            s.perchSpeed = 0
            s.velocity.dy = max(s.velocity.dy - Feel.Physics.gravity * dt,
                                -Feel.Physics.terminalVelocity)
            let y0 = s.position.y
            let y1 = y0 + s.velocity.dy * dt
            let x = s.position.x + s.velocity.dx * dt

            if s.velocity.dy < 0, let hit = world.supportBelow(x: x, from: y0, to: y1) {
                let impact = abs(s.velocity.dy)
                s.position = CGPoint(x: x, y: hit.y)
                s.support = .grounded(Perch(id: hit.id, dx: x - hit.extent.lowerBound))
                s.velocity = .zero
                s.squash = min(impact / Feel.Shape.squashReference, 1) * Feel.Shape.maxSquash
                s.squashElapsed = 0
                s.activity = impact > 600 ? .landHard : .land
                s.activityElapsed = 0
                s.righting = 1
                // Re-plan from where he actually landed, not from where he meant to. Asking
                // again on every landing is the entire routing mechanism: one hop of lookahead,
                // repeated, hill-climbs toward a destination without a pathfinder — and a hop
                // he fluffed simply becomes the new starting point rather than a dead end.
                if let intent = s.intent, let surface = world.surface(hit.id) {
                    let next = nextMove(from: s, on: surface, toward: intent.destination,
                                        x: intent.destinationX, world: world)
                    s.intent?.move = next ?? .walk(s.position.x)
                }
            } else {
                s.position = CGPoint(x: x, y: y1)
                // The righting reflex. He twists, gets his feet under him, and lands on
                // four paws every single time — by construction, not by luck.
                // The twist itself finishes long before he lands, but he stays in `.righting`
                // for the whole descent: it draws the same sheet as `.slip`, and staying put
                // means the clip is never restarted underneath him.
                if s.righting < 1 {
                    s.righting = min(1, s.righting + CGFloat(dt) / CGFloat(Feel.Timing.righting))
                }
                // `.slip` used to time out into `.airborne` after 0.12s, which meant a cat
                // whose window closed played 120ms of the fall and then the jump sheet for the
                // whole rest of the drop. The fall sheet does not loop: it runs its six frames
                // and holds the last one, braced for impact, which is exactly what a long
                // descent wants. So he stays in it until he lands.
            }
        }

        // Settle out of landing back to idle. Two clocks, because the two landings are now two
        // different animations: the hard one shakes himself off and that takes the length of
        // the sheet plus a beat holding the settled frame.
        let landingHold = s.activity == .landHard ? Feel.Timing.landHardSeconds
                                                  : Feel.Timing.landSeconds
        if s.activity == .land || s.activity == .landHard, s.activityElapsed > landingHold {
            s.activity = .idle
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
        return s
    }

    /// Let go. If he is over a window's face he grabs it; otherwise he twists, rights
    /// himself, and lands on his feet.
    ///
    /// **Entry is on release only, deliberately.** Clinging on any fall past any window
    /// would stop every descent at the first window it passed, and the fall is the app's
    /// entire demo.
    public static func release(_ state: CatState, throwVelocity v: CGVector,
                               world: Skyline) -> CatState {
        var s = state
        if abs(v.dx) < Feel.Physics.clingGrabSpeed, abs(v.dy) < Feel.Physics.clingGrabSpeed,
           let face = world.faceContaining(s.position) {
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

        // Frozen. Ears forward, tail dead still. He hears you, and it doubles as a privacy
        // indicator: if he has gone rigid, your microphone is hot.
        if s.listening {
            s.intent = nil
            s.activity = .alert
            return s
        }
        // Only sleep is a hard stop, and only because the zero-wakeup guarantee lives there.
        // Sitting and curling *bias* him: longer waits, mostly in-place behaviours. A sitting
        // cat still shifts, washes and looks around. Before this he froze into a pose, and
        // `repose` comes from system HID idle, so sitting still and watching him was precisely
        // what stopped him.
        if s.repose == .asleep {
            s.intent = nil
            s.activity = .sleep
            return s
        }

        // Coming out of the doorway. He is standing on the notch's lip with the rest of him
        // still inside the cutout, where the mask clips him away, so the emergence has to
        // finish before anything moves him — otherwise the walk starts on the first tick and
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

        /// Nothing left to do. He stops where he is and waits before wanting anything else.
        func settle(_ s: inout CatState) {
            s.intent = nil
            s.hurrying = false
            s.activity = s.repose.restingActivity
            s.activityElapsed = 0
            s.restLeft = Feel.Timing.restMin + Double.random(in: 0...Feel.Timing.restJitter)
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
            // The pose he waits in tracks how settled he is, so a cat who was standing when
            // the room went quiet sits down rather than only settling into it after his next
            // idea. Only ever swaps one waiting pose for another: a wash or a walk still wins.
            switch s.activity {
            case .groom, .land, .landHard, .brace: break   // busy; each times out on its own
            default: s.activity = s.repose.restingActivity
            }
            // Already washing: keep at it for a few seconds, then settle back. Anything that
            // actually matters — settling to sleep, the mic going live — is handled above this
            // and overrides it, which is the right precedence.
            if s.activity == .groom {
                if s.activityElapsed > Feel.Timing.groomSeconds {
                    s.activity = s.repose.restingActivity
                    s.activityElapsed = 0
                    s.restLeft = Feel.Timing.restMin + Double.random(in: 0...Feel.Timing.restJitter)
                }
                return s
            }
            // Nothing to do. Sit still until boredom wins.
            // Low battery makes him idle longer. A sluggish cat means plug in.
            // Settledness stretches the same timer rather than stopping it.
            s.restLeft -= dt * (1 - s.languor * 0.6) / s.repose.restMultiplier
            if s.restLeft <= 0 {
                // Boredom does not always mean going somewhere. Sometimes he just washes,
                // which is the difference between a creature and a pathfinding demo. The more
                // settled he is, the likelier that is what it turns out to be.
                if Double.random(in: 0...1) < s.repose.inPlaceChance {
                    s.activity = .groom
                    s.activityElapsed = 0
                } else if let idea = pickIntent(from: s, on: surface, world: world) {
                    s.intent = idea
                    if case .jump = idea.move { s.activity = .crouch } else { s.activity = .walk }
                    s.activityElapsed = 0
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
        // so a lip that stops being a lip — the window under it closing, say — is noticed.
        //
        // ...but not immediately. He walks to the lip, stops short of it, puts his head over
        // and HOLDS, and only then commits or thinks better of it. That hold is the same idea
        // as the crouch before a jump, one level up: it is the difference between the cat
        // jumped and the cat decided to jump. `stepOffLip` has already refused every lip with
        // nothing under it, so he can only ever hesitate at a real drop — never at a wall, and
        // never at the interior gap, which he must not so much as consider.
        var move = intent.move
        if case .stepOff = move {
            guard let lip = stepOffLip(from: s, on: surface, toward: intent.destinationX,
                                       world: world) else {
                settle(&s)      // walls both ways: there is no way down from here after all
                return s
            }
            let toLip = abs(lip.x - s.position.x)
            // Where he plants: one braking distance outside the mark he is walking to, so the
            // approach can never actually *arrive* (see the approach branch).
            let plantAt = Feel.Physics.edgeApproach + Feel.Physics.brakingDistance

            if s.activity == .edgeLook {
                s.perchSpeed = 0
                // The drop he is weighing, measured this tick by the same rule that chose the
                // lip. A deeper one is looked at for longer.
                let drop = s.footing.dropAhead ?? 0
                guard s.activityElapsed >= hesitation(forDrop: drop) else { return s }

                guard Double.random(in: 0...1) < commitChance(forDrop: drop) else {
                    // Thought better of it. He turns, walks a little way back along the ledge
                    // and sits down pretending he was never considering it.
                    //
                    // The retreat is a destination on his OWN surface, and that is what stops a
                    // refusal from becoming a pace: `advance` re-plans toward whatever the
                    // intent says, so a retreat that kept the old destination would route him
                    // straight back to the lip he just turned down, for ever. Giving the trip up
                    // is the honest reading anyway — he decided not to go — and the walk back
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
                // The approach, aimed to stop `edgeApproach` SHORT of the lip — roughly half
                // his drawn width, so he ends up with his nose over the edge and his paws on
                // solid ground.
                //
                // The plant above intercepts one braking distance outside that mark so the walk
                // can never actually *arrive*. That is what makes the tell survive: arriving
                // calls `advance`, and from this close to a lip a jump down suddenly clears his
                // own ledge, so re-planning here would quietly turn the whole thing into a leap.
                //
                // Which is also why the slowing down has to happen here rather than in the
                // walk's own braking. The two windows coincide exactly — the walk brakes inside
                // `brakingDistance` of its mark, which is the last `plantAt` points, and those
                // are precisely the points he never spends walking — so left to the walk he
                // would hold a flat `walkSpeed` right up to the lip and then stop dead. A
                // ceiling on his surface speed, easing to a creep over the last `edgeEase`
                // points, is the whole "slows" beat of the tell. It caps the ordinary walk
                // rather than replacing it: the walk still ramps toward it at `accel`, so this
                // is one number lower, not a second way of moving.
                //
                // Scaled off the gait he would otherwise be travelling at, not off `walkSpeed`:
                // a ceiling of `walkSpeed` holds a trotting cat at a walk while `hurrying` is
                // still true, and `Sprites.clip` reads `hurrying` — so he plays the run frames
                // at walking speed, which is the gait desync `strideLength` exists to prevent.
                // Applied only inside the ease itself for the same reason: outside it he is
                // covering ground, and how he covers ground is not this code's business.
                let target = lip.x - lip.dir * Feel.Physics.edgeApproach
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
            // a few points past his mark and stops there, which is also what retires the old
            // `abs(dx) < arrivalSlop` arrival check: running out of speed IS arriving now.
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
                    // Clear of the lip so the fall does not scrape down it — but never past
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
            // He is allowed to arrive before he leaves again: a chained hop still plays the
            // landing before it winds up for the next one.
            if s.activity == .land || s.activity == .landHard { break }
            // The 100ms crouch, from scratch every time. Non-negotiable: it is the entire
            // difference between a cat and a teleporting rectangle. Requiring that he is
            // ALREADY crouching is what makes it survive a jump planned mid-route — the clock
            // left over from the walk that got him here would otherwise count as the wind-up.
            guard s.activity == .crouch, s.activityElapsed >= Feel.Timing.anticipation else {
                s.activity = .crouch
                break
            }
            guard let dest = world.surface(destID),
                  let v = launch(dx: destX - s.position.x, dy: dest.y - s.position.y) else {
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
            // The intent survives the flight; he re-plans the instant he lands.

        case .stepAcross(let destID, let x):
            // A stride, not a leap. The gap is narrower than one pace — he is standing on the
            // lip and the far side is a couple of dozen points away — so he simply arrives on
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

        case .stepOff:
            break   // resolved into a walk above; unreachable
        }
        return s
    }

    /// What he asks of himself over a walk of `dx`. Long trips are covered at a trot — a cat
    /// crossing a room does not stroll, and it is also the only thing that ever plays the run
    /// frames — and a low battery makes whichever gait it is slower.
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
    /// **This is where the reluctance lives.** The physics deliberately has no maximum drop —
    /// under a minimum-energy launch a deeper target is *more* reachable, not less — so the
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
    /// end of every step, which is what turns a chain of these into a route — and what lets a
    /// jump he fluffs become the new starting point rather than a dead end.
    ///
    /// **This is final.** v2b's mind replaces only the code that chooses a destination.
    public static func nextMove(from s: CatState, on surface: Surface,
                                toward destID: SurfaceID, x destX: CGFloat,
                                world: Skyline) -> Move? {
        // Already there: just walk.
        if destID == surface.id { return .walk(destX) }

        guard let dest = world.surface(destID) else { return nil }
        let here = s.position

        // A crack, not a canyon. Measured between the two surfaces rather than between him and
        // the far side, so he walks to the lip and steps across instead of only ever striding
        // when he happens to be standing on it already.
        //
        // `spans`, not `solid`: he is CHOOSING where to put himself down, and `solid` includes
        // the parts of the far window that are hidden behind something else. Striding onto one
        // of those is a legal place to stand and an absurd place to be seen — which is the
        // distinction the two arrays exist to draw.
        if abs(dest.y - surface.y) <= Feel.World.coplanarTolerance,
           let far = nearestSpanX(to: here.x, in: dest.spans),
           let lip = edgeAhead(from: here.x, facing: far > here.x ? 1 : -1, on: surface),
           abs(far - lip) <= Feel.Physics.strideGap {
            return abs(here.x - lip) <= Feel.Physics.arrivalSlop
                ? .stepAcross(destID, far) : .walk(lip)
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

        // Nothing in the air, and the destination is below him. Walk to the lip and step off.
        // Gravity was always there; v1 simply had no way to ask for it.
        if dest.y < surface.y { return .stepOff }

        // Nothing in the air and the destination is above. Walk to the point on his own ledge
        // nearest to it and ask again from there: half of getting somewhere is standing in the
        // right place first, and without this a hop he lands mid-ledge is a dead end.
        if let x = nearestSpanX(to: destX, in: surface.solid),
           abs(x - here.x) > Feel.Physics.arrivalSlop * 2 {
            return .walk(x)
        }
        return nil
    }

    /// Does the arc to `to` get out from over the ledge he is launching from?
    ///
    /// Every jump starts upward, so a target BELOW his own surface means coming back down
    /// through it — and `supportBelow` is inclusive at both ends and has no idea which surface
    /// he left, so he re-grounds wherever the arc re-crosses his own y over his own solid.
    /// Testing the LANDING x instead (as `pickGoal` used to) misses that entirely: the
    /// minimum-energy launch is flat, and menu-bar-to-desktop at 500pt across re-crosses 44pt
    /// out, where the old fixed-speed solve crossed at 268.
    ///
    /// This is also the whole discriminator between `.jump` and `.stepOff`. A deep drop is
    /// nearly free under minimum energy, so without it every downward destination is a jump and
    /// `.stepOff` is dead code. With it the rule is physical rather than arbitrary: if he can
    /// get clear of his own ledge he jumps, and if he cannot he walks to the edge and drops.
    static func clears(_ surface: Surface, from: CGPoint, to: CGPoint) -> Bool {
        guard to.y < surface.y else { return true }
        guard let v = launch(dx: to.x - from.x, dy: to.y - from.y, jitter: 0) else { return false }
        // Range at launch height: 2·vx·vy/g — but he judges soberly and executes with a wobble,
        // so what he actually gets is that range scaled by (1 ± aimError)². Every crossing in
        // that band has to clear, not just the sober one: a jump whose sober crossing sits a
        // few points past his own lip comes back down ON it on a low draw. Testing the band
        // rather than its two ends because his own solid can have a hole in the middle of it —
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
        // lip AT ALL — worst overshoot reaches 0.9888 of it — and fell short of a near one on
        // only 4% of draws. Half that leaves 1.0562 and 26%: off the lip, still fallible.
        // Manifesto §6: "preserve the failure cases; they are where the charm lives."
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

    /// Where he'd like to go next, and the first step toward it. Deliberately dumb: no A*, no
    /// navigation mesh. A cat that pathfinds perfectly reads as a robot.
    ///
    /// **This is the seam.** v2b's mind replaces this function and nothing else: everything
    /// below it takes a destination as given.
    private static func pickIntent(from s: CatState, on surface: Surface,
                                   world: Skyline) -> Intent? {
        if Double.random(in: 0...1) < Feel.Physics.jumpChance {
            // Somewhere else entirely: the first candidate that routes, in random order.
            // Unfiltered by reach on purpose — `nextMove` will chain two hops to get there, and
            // filtering here by what is reachable in ONE would make multi-hop routing something
            // only a test could ever ask for.
            for other in world.surfaces.shuffled()
            where other.id != surface.id && other.targetable {
                guard let span = other.spans.randomElement() else { continue }
                let x = CGFloat.random(in: span.lowerBound...span.upperBound)
                if let move = nextMove(from: s, on: surface, toward: other.id, x: x, world: world) {
                    return Intent(destination: other.id, destinationX: x, move: move)
                }
            }
        }
        // A stroll along the ledge he is on. The span is picked without weighting by length, so
        // a 5pt sliver is as likely as a 300pt run; surfaces are one span in almost every real
        // case, and a slight bias toward the awkward perches is not a defect worth code.
        guard let span = surface.spans.randomElement(), span.length > Feel.World.minStandWidth else {
            return nil
        }
        let x = CGFloat.random(in: span.lowerBound...span.upperBound)
        return abs(x - s.position.x) < Feel.Physics.arrivalSlop * 2
            ? nil : Intent(destination: surface.id, destinationX: x, move: .walk(x))
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
    /// than a short one. Solving instead for the angle at a *fixed* speed inverted that: it
    /// sent a 60pt hop off at 85°, 189pt into the air for 0.87s, against 98pt and 0.63s for a
    /// 380pt leap — a hop that outclimbed and outhung the leap, which is the same defect as
    /// v1's constant arc height with the sign flipped.
    ///
    /// `v_min ≤ jumpImpulse` is algebraically the old discriminant: solving
    /// `v⁴ − 2g·dy·v² − g²dx² ≥ 0` for v² gives exactly `v² ≥ g(dy + r)`. So the set of
    /// reachable targets, `reachX` and `canReach` are all unchanged by the switch — only the
    /// `(speed, angle)` pair chosen inside it is.
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
                              jitter: CGFloat = Feel.Physics.aimError) -> CGVector? {
        // r ≥ |dy|, so dy + r ≥ 0 and neither root can be NaN. atan2 also handles dx = 0,
        // which is why this needs no straight-up special case and no angle clamp: θ lands in
        // [0, π/2] by construction and nothing perturbs it.
        let r = (dx * dx + dy * dy).squareRoot()
        let vMin = (g * (dy + r)).squareRoot()
        guard vMin <= v else { return nil }

        let noise = jitter > 0 ? CGFloat.random(in: -jitter...jitter) : 0
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
        launch(dx: to.x - from.x, dy: to.y - from.y, jitter: 0) != nil
    }

    /// Where solid ground runs out in the direction he is facing, in world x.
    /// Nil means he is not standing on solid ground at all.
    ///
    /// This replaces `clampToSurface`, which pinned him inside `extent` and thereby made the
    /// fall-off guard in `step` unreachable. He could not walk off anything.
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
    /// gap, not a cliff, and a gap is a wall (`isGap`). The notch is the only one that exists —
    /// windows produce a single solid run and the floor is uncarved — and it is a trap rather
    /// than a ledge: he cannot jump to the surface he is standing on (`nextMove` walks there
    /// instead), and his whole impulse buys 190pt of rise against the thousand points back up
    /// from the desktop, so stepping into it is one-way.
    static func landing(past x: CGFloat, facing: CGFloat,
                        on surface: Surface, world: Skyline) -> Surface? {
        if isGap(at: x, facing: facing, on: surface) { return nil }
        return world.supportBelow(x: x, from: surface.y - Feel.World.coplanarEpsilon,
                                  to: -.greatestFiniteMagnitude)
    }

    /// Does the surface resume past that edge? Then it is a hole, not the end of it.
    static func isGap(at x: CGFloat, facing: CGFloat, on surface: Surface) -> Bool {
        surface.solid.contains { facing > 0 ? $0.lowerBound > x : $0.upperBound < x }
    }
}
