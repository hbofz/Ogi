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

public enum Support: Sendable, Equatable {
    case grounded(Perch)
    case falling
    /// Dangling from the cursor. This is what actually happens to cats.
    case held(CGPoint)
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
    case crouch     // the 100ms wind-up before every jump
    case brace      // riding a window that is being dragged
    case slip       // the ground just went away
    case airborne
    case land
    case landHard
}

/// What he is currently trying to do. Nil means he is content where he is.
public enum Goal: Sendable, Equatable {
    case walkTo(CGFloat)
    /// Crouch, then launch at a point on another surface.
    case jumpTo(SurfaceID, CGFloat)
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

    public var activity: Activity? {
        switch self {
        case .awake: return nil
        case .sitting: return .sit
        case .curled: return .curl
        case .asleep: return .sleep
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

    public var goal: Goal?
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
        if goal != nil { return true }
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
            s.goal = nil
            s.drift = 0
            s.lastPerchOrigin = nil
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
            if abs(s.lean) > Feel.Physics.braceThreshold, s.goal == nil {
                s.activity = .brace
            } else if s.activity == .brace {
                s.activity = .idle
            }

        case .falling:
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

        // Settle out of landing back to idle.
        if s.activity == .land || s.activity == .landHard, s.activityElapsed > 0.35 {
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
        s.goal = nil
        return s
    }

    /// Let go. He twists, rights himself, and lands on his feet.
    public static func release(_ state: CatState, throwVelocity v: CGVector) -> CatState {
        var s = state
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

    private static func ground(_ state: CatState, on surface: Surface,
                               world: Skyline, dt: TimeInterval) -> CatState {
        var s = state
        guard case .grounded(var perch) = s.support else { return s }

        // Frozen. Ears forward, tail dead still. He hears you, and it doubles as a privacy
        // indicator: if he has gone rigid, your microphone is hot.
        if s.listening {
            s.goal = nil
            s.activity = .alert
            return s
        }
        // Settled. He asks nothing of you, so nothing here nags: he simply gets sleepier.
        if let settled = s.repose.activity {
            s.goal = nil
            s.activity = settled
            return s
        }

        switch s.goal {
        case nil:
            // Already washing: keep at it for a few seconds, then settle back. Anything that
            // actually matters — settling to sleep, the mic going live — is handled above this
            // and overrides it, which is the right precedence.
            if s.activity == .groom {
                if s.activityElapsed > Feel.Timing.groomSeconds {
                    s.activity = .idle
                    s.activityElapsed = 0
                    s.restLeft = Feel.Timing.restMin + Double.random(in: 0...Feel.Timing.restJitter)
                }
                break
            }
            // Nothing to do. Sit still until boredom wins.
            // Low battery makes him idle longer. A sluggish cat means plug in.
            s.restLeft -= dt * (1 - s.languor * 0.6)
            if s.restLeft <= 0 {
                // Boredom does not always mean going somewhere. Sometimes he just washes,
                // which is the difference between a creature and a pathfinding demo.
                if Double.random(in: 0...1) < Feel.Timing.groomChance {
                    s.activity = .groom
                    s.activityElapsed = 0
                } else if let goal = pickGoal(from: s, on: surface, world: world) {
                    s.goal = goal
                    s.activity = (goal.isJump ? .crouch : .walk)
                    s.activityElapsed = 0
                } else {
                    // Nothing worth doing. Wait before asking again rather than re-rolling
                    // on every one of the next 120 ticks, which both burns work and biases
                    // the destination distribution toward whatever is easiest to pick.
                    s.restLeft = Feel.Timing.restMin
                }
            }

        case .walkTo(let targetX):
            let dx = targetX - s.position.x
            if abs(dx) < Feel.Physics.arrivalSlop {
                s.goal = nil
                s.hurrying = false
                s.activity = .idle
                s.activityElapsed = 0
                s.restLeft = Feel.Timing.restMin + Double.random(in: 0...Feel.Timing.restJitter)
                break
            }
            s.facing = dx > 0 ? 1 : -1
            // Long trips are covered at a trot. A cat crossing a room does not stroll,
            // and it is also the only thing that ever plays the run frames.
            s.hurrying = abs(dx) > Feel.Physics.hurryDistance && s.languor < 0.5
            let base = s.hurrying ? Feel.Physics.runSpeed : Feel.Physics.walkSpeed
            let speed = base * (1 - CGFloat(s.languor) * 0.45)
            let step = min(abs(dx), speed * CGFloat(dt)) * s.facing

            let worldX = surface.extent.lowerBound + perch.dx
            let nextX = worldX + step
            if let edge = edgeAhead(from: worldX, facing: s.facing, on: surface),
               (s.facing > 0 ? nextX > edge : nextX < edge) {
                if isCliff(at: edge, facing: s.facing, on: surface, world: world) {
                    // He walked off. Gravity was always there; nothing was ever allowed
                    // to reach it.
                    s.support = .falling
                    s.activity = .slip
                    s.activityElapsed = 0
                    s.velocity = CGVector(dx: s.facing * Feel.Physics.slipKick, dy: 0)
                    s.position.x = edge + s.facing * Feel.Physics.edgeTolerance
                    s.goal = nil
                    s.drift = 0
                    s.lastPerchOrigin = nil
                } else {
                    // Nothing below. The end of the world, not a ledge: he turns around.
                    perch.dx = edge - surface.extent.lowerBound
                    s.support = .grounded(perch)
                    s.facing = -s.facing
                    s.goal = nil
                    s.activity = .idle
                    s.activityElapsed = 0
                    s.restLeft = Feel.Timing.restMin
                }
                break
            }
            perch.dx += step
            s.support = .grounded(perch)
            s.activity = .walk

        case .jumpTo(let destID, let destX):
            // The 100ms crouch. Non-negotiable: it is the entire difference between a cat
            // and a teleporting rectangle. Only after it does the impulse happen.
            guard s.activityElapsed >= Feel.Timing.anticipation else {
                s.activity = .crouch
                break
            }
            guard let dest = world.surface(destID) else {
                s.goal = nil; s.activity = .idle; s.restLeft = 0.5
                break
            }
            guard let v = launch(dx: destX - s.position.x, dy: dest.y - s.position.y) else {
                // The window moved while he was winding up and it is out of reach now.
                // Give up rather than teleporting.
                s.goal = nil; s.activity = .idle; s.restLeft = 0.5
                break
            }
            s.velocity = v
            s.facing = s.velocity.dx >= 0 ? 1 : -1
            s.support = .falling
            s.activity = .airborne
            s.activityElapsed = 0
            s.goal = nil
            s.restLeft = Feel.Timing.restMin + Double.random(in: 0...Feel.Timing.restJitter)
        }
        return s
    }

    /// Where he'd like to go next. Deliberately dumb: no A*, no navigation mesh.
    /// A cat that pathfinds perfectly reads as a robot.
    private static func pickGoal(from s: CatState, on surface: Surface, world: Skyline) -> Goal? {
        let jumps = world.surfaces.compactMap { other -> Goal? in
            guard other.id != surface.id, other.targetable,
                  let x = landingX(on: other, from: s.position) else { return nil }
            // He cannot fall through the ledge he launched from. Every jump starts upward, so
            // a target below his own surface is only reachable where that surface is not in
            // the way. Without this he "jumps to the desktop" from a full-width menu bar and
            // comes straight back down onto the menu bar, over and over.
            guard other.y > surface.y || !surface.solid.contains(where: { $0.contains(x) }) else {
                return nil
            }
            return .jumpTo(other.id, x)
        }

        if let jump = jumps.randomElement(), Double.random(in: 0...1) < Feel.Physics.jumpChance {
            return jump
        }

        guard let span = surface.spans.randomElement(), span.length > Feel.World.minStandWidth else {
            return nil
        }
        let x = CGFloat.random(in: span.lowerBound...span.upperBound)
        return abs(x - s.position.x) < Feel.Physics.arrivalSlop * 2 ? nil : .walkTo(x)
    }

    /// A random point on that surface he can actually get to, uniform over the reachable
    /// part of it. Nil means none of it is in range.
    ///
    /// Choosing and filtering are the same question, so they are the same call. v1 asked them
    /// separately — filter on `extent` overlap, then pick a landing point at random from
    /// `spans` — so it could select a jump it had just declared out of range, and the solver
    /// would take it anyway. Picking uniformly rather than at the near corner also matters:
    /// the aim error is symmetric about wherever he aims, so aiming at the lip of a ledge is
    /// a coin flip on falling short of it.
    static func landingX(on surface: Surface, from: CGPoint) -> CGFloat? {
        let reach = reachX(dy: surface.y - from.y)
        guard reach > 0 else { return nil }
        let window = (from.x - reach)...(from.x + reach)
        guard let span = surface.spans.filter({ $0.overlaps(window) }).randomElement() else {
            return nil
        }
        return CGFloat.random(in: span.clamped(to: window))
    }

    /// Solve for a launch that hits `(dx, dy)` at a **fixed speed**. Nil means he cannot
    /// make it: the discriminant *is* the reachability test.
    ///
    /// For a projectile of speed v at angle t under gravity g:
    ///     y = x·tan(t) − g·x²·(1 + tan²t) / (2v²)
    /// Solving for tan(t):
    ///     tan(t) = ( v² ± √(v⁴ − 2·g·y·v² − g²·x²) ) / (g·x)
    ///
    /// The **high root** is taken: steeper, slower, more readable, and what cats do.
    ///
    /// Note that a *downward* target grows the discriminant, so deep drops are more
    /// reachable, not less. That is physically right, and it is why the reluctance to make
    /// a big drop lives in the hesitation at the edge rather than in a constant here.
    public static func launch(dx: CGFloat, dy: CGFloat,
                              speed v: CGFloat = Feel.Physics.jumpImpulse,
                              g: CGFloat = Feel.Physics.gravity,
                              jitter: CGFloat = Feel.Physics.aimError) -> CGVector? {
        let noise = jitter > 0 ? CGFloat.random(in: -jitter...jitter) : 0

        // Straight up, where the general form divides by zero.
        guard abs(dx) > 0.5 else {
            guard v * v >= 2 * g * max(dy, 0) else { return nil }
            return CGVector(dx: 0, dy: v)
        }

        let x = abs(dx)
        let disc = v * v * v * v - 2 * g * dy * v * v - g * g * x * x
        guard disc >= 0 else { return nil }

        let theta = atan((v * v + disc.squareRoot()) / (g * x)) + noise
        // Clamp so a bad roll near the vertical cannot send him backwards.
        let t = max(0.05, min(.pi / 2 - 0.05, theta))
        return CGVector(dx: cos(t) * v * (dx < 0 ? -1 : 1), dy: sin(t) * v)
    }

    /// How far he can throw himself sideways to arrive `dy` above his feet (negative for a
    /// drop). Zero means that height is out of reach at any angle. Same discriminant `launch`
    /// tests, solved for x instead of for yes-or-no, so a landing spot can be *chosen* from
    /// the reachable interval rather than proposed and rejected.
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
    /// than a ledge: he cannot jump to the surface he is standing on (`pickGoal` excludes it),
    /// and his whole impulse buys 190pt of rise against the thousand points back up from the
    /// desktop, so stepping into it is one-way.
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

extension Goal {
    var isJump: Bool { if case .jumpTo = self { return true }; return false }
}
