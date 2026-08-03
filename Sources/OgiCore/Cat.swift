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
        var s = state
        s.activityElapsed += dt
        s.squashElapsed += dt

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
            // Walked off, or the window shrank out from under him.
            guard perch.dx >= 0, perch.dx <= surface.extent.length else {
                s.support = .falling
                s.activity = .slip
                s.activityElapsed = 0
                return s
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
                if s.righting < 1 {
                    s.righting = min(1, s.righting + CGFloat(dt) / CGFloat(Feel.Timing.righting))
                    // Falling, not jumping. `.airborne` means he chose to leave the ground and
                    // draws the jump sheet; being dropped is the fall sheet from the first
                    // frame to the last. `activityElapsed` deliberately keeps running across
                    // this handover so the clip continues rather than restarting.
                    s.activity = s.righting < 1 ? .righting : .slip
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
            } else {
                s.facing = dx > 0 ? 1 : -1
                // Long trips are covered at a trot. A cat crossing a room does not stroll,
                // and it is also the only thing that ever plays the run frames.
                s.hurrying = abs(dx) > Feel.Physics.hurryDistance && s.languor < 0.5
                let base = s.hurrying ? Feel.Physics.runSpeed : Feel.Physics.walkSpeed
                let speed = base * (1 - CGFloat(s.languor) * 0.45)
                let step = min(abs(dx), speed * CGFloat(dt)) * s.facing
                perch.dx = clampToSurface(perch.dx + step, surface)
                s.support = .grounded(perch)
                s.activity = .walk
            }

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
            s.velocity = launchVelocity(from: s.position, toX: destX, toY: dest.y)
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
        let reach = (s.position.x - Feel.Physics.maxJumpReach)...(s.position.x + Feel.Physics.maxJumpReach)
        let reachable = world.surfaces.filter { other in
            other.id != surface.id && other.targetable && !other.spans.isEmpty
                && (other.y - surface.y < Feel.Physics.maxJumpRise)
                && (surface.y - other.y < Feel.Physics.maxJumpDrop)
                && other.extent.overlaps(reach)
        }

        if !reachable.isEmpty, Double.random(in: 0...1) < Feel.Physics.jumpChance,
           let target = reachable.randomElement(),
           let span = target.spans.randomElement() {
            return .jumpTo(target.id, CGFloat.random(in: span.lowerBound...span.upperBound))
        }

        guard let span = surface.spans.randomElement(), span.length > Feel.World.minStandWidth else {
            return nil
        }
        let x = CGFloat.random(in: span.lowerBound...span.upperBound)
        return abs(x - s.position.x) < Feel.Physics.arrivalSlop * 2 ? nil : .walkTo(x)
    }

    /// A real ballistic arc, with a deliberate aiming error.
    ///
    /// The error is the point. A cat that always sticks the landing reads as a machine;
    /// one that occasionally misjudges, slips and recovers reads as a cat. Preserve it.
    private static func launchVelocity(from: CGPoint, toX: CGFloat, toY: CGFloat) -> CGVector {
        let g = Feel.Physics.gravity
        let dy = toY - from.y
        // Clear the higher of the two ends by a comfortable margin.
        let rise = max(dy, 0) + Feel.Physics.jumpArc
        let vy = (2 * g * rise).squareRoot()
        let timeUp = vy / g
        let timeDown = (2 * max(rise - dy, 1) / g).squareRoot()
        let flight = timeUp + timeDown
        let error = CGFloat.random(in: -Feel.Physics.aimError...Feel.Physics.aimError)
        return CGVector(dx: (toX - from.x) / flight * (1 + error), dy: vy)
    }

    private static func clampToSurface(_ dx: CGFloat, _ surface: Surface) -> CGFloat {
        min(max(dx, 0), surface.extent.length)
    }
}

extension Goal {
    var isJump: Bool { if case .jumpTo = self { return true }; return false }
}
