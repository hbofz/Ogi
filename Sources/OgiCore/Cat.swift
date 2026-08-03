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
}

public enum Activity: Sendable, Equatable {
    case idle
    case walk
    case crouch     // the 100ms wind-up before every jump
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

    public var goal: Goal?
    /// Seconds of stillness left before he thinks of something to do.
    public var restLeft: TimeInterval = 1.5

    public init(position: CGPoint, velocity: CGVector = .zero) {
        self.position = position
        self.velocity = velocity
    }

    public var isMoving: Bool {
        if case .falling = support { return true }
        if goal != nil { return true }
        return squashElapsed < 0.4
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
        case .grounded(let perch):
            guard let surface = world.surface(perch.id) else {
                // His platform vanished. This is the demo.
                s.support = .falling
                s.activity = .slip
                s.activityElapsed = 0
                s.velocity = CGVector(dx: s.facing * Feel.Physics.slipKick, dy: 0)
                return s
            }
            // Walked off, or the window shrank out from under him.
            guard perch.dx >= 0, perch.dx <= surface.extent.length else {
                s.support = .falling
                s.activity = .slip
                s.activityElapsed = 0
                return s
            }
            // World position is derived. Surfing is free.
            s.position = CGPoint(x: surface.extent.lowerBound + perch.dx, y: surface.y)
            s.velocity = .zero
            s = ground(s, on: surface, world: world, dt: dt)

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
            } else {
                s.position = CGPoint(x: x, y: y1)
                if s.activityElapsed > 0.12, s.activity == .slip { s.activity = .airborne }
            }
        }

        // Settle out of landing back to idle.
        if s.activity == .land || s.activity == .landHard, s.activityElapsed > 0.35 {
            s.activity = .idle
            s.activityElapsed = 0
        }
        return s
    }

    // MARK: - On the ground

    private static func ground(_ state: CatState, on surface: Surface,
                               world: Skyline, dt: TimeInterval) -> CatState {
        var s = state
        guard case .grounded(var perch) = s.support else { return s }

        switch s.goal {
        case nil:
            // Nothing to do. Sit still until boredom wins.
            s.restLeft -= dt
            if s.restLeft <= 0, let goal = pickGoal(from: s, on: surface, world: world) {
                s.goal = goal
                s.activity = (goal.isJump ? .crouch : .walk)
                s.activityElapsed = 0
            }

        case .walkTo(let targetX):
            let dx = targetX - s.position.x
            if abs(dx) < Feel.Physics.arrivalSlop {
                s.goal = nil
                s.activity = .idle
                s.activityElapsed = 0
                s.restLeft = Feel.Timing.restMin + Double.random(in: 0...Feel.Timing.restJitter)
            } else {
                s.facing = dx > 0 ? 1 : -1
                let step = min(abs(dx), Feel.Physics.walkSpeed * CGFloat(dt)) * s.facing
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
                && abs(other.y - surface.y) < Feel.Physics.maxJumpRise
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
