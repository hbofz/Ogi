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
    case slip       // the ground just went away
    case airborne
    case land
    case landHard
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

    public init(position: CGPoint, velocity: CGVector = .zero) {
        self.position = position
        self.velocity = velocity
    }

    public var isMoving: Bool {
        if case .falling = support { return true }
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
}
