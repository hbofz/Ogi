import Testing
import CoreGraphics
@testable import OgiCore

@Suite struct JumpTests {

    /// Integrate the launch and check he actually arrives. Aimed soberly (`jitter: 0`),
    /// because what is under test is the solver, not the deliberate error on top of it.
    private func flightLands(dx: CGFloat, dy: CGFloat) -> Bool {
        guard let v = Cat.launch(dx: dx, dy: dy, jitter: 0) else { return false }
        var p = CGPoint.zero
        var vel = v
        let dt: CGFloat = 1.0 / 480
        for _ in 0..<20_000 {
            vel.dy -= Feel.Physics.gravity * dt
            p.x += vel.dx * dt
            p.y += vel.dy * dt
            if vel.dy < 0 && p.y <= dy && (dx > 0 ? p.x >= dx * 0.9 : p.x <= dx * 0.9) {
                return abs(p.x - dx) < 12
            }
        }
        return false
    }

    @Test func aShortHopIsReachable() {
        #expect(Cat.launch(dx: 60, dy: 0) != nil)
        #expect(flightLands(dx: 60, dy: 0))
    }

    @Test func aLongFlatLeapIsNotReachable() {
        // At 872 px/s against 2000 px/s^2 gravity, the flat range maxes out at 380pt.
        // The old code would have solved this exactly and taken it anyway.
        #expect(Cat.launch(dx: 900, dy: 0) == nil)
    }

    @Test func droppingFurtherMakesATargetMoreReachable() {
        // Physically correct, and the reason the reluctance has to live in behaviour rather
        // than in a maxJumpDrop constant. 600pt is comfortably past the 380pt flat range
        // and comfortably inside the 775pt range a 600pt drop buys him.
        #expect(Cat.launch(dx: 600, dy: 0) == nil)
        #expect(Cat.launch(dx: 600, dy: -600) != nil)
    }

    @Test func heCannotJumpHigherThanHisOwnImpulse() {
        let maxRise = Feel.Physics.jumpImpulse * Feel.Physics.jumpImpulse
            / (2 * Feel.Physics.gravity)
        #expect(Cat.launch(dx: 20, dy: maxRise * 0.5) != nil)
        #expect(Cat.launch(dx: 20, dy: maxRise * 1.5) == nil)
    }

    @Test func theHighRootIsChosen() {
        // Two angles hit any reachable target. The steeper one is slower, reads better,
        // and is what cats do.
        let v = Cat.launch(dx: 80, dy: 0)!
        #expect(v.dy > v.dx)
    }

    @Test func launchSpeedIsAlwaysTheBudget() {
        for (dx, dy) in [(60.0, 0.0), (100.0, -200.0), (30.0, 40.0)] {
            let v = Cat.launch(dx: CGFloat(dx), dy: CGFloat(dy), jitter: 0)!
            let speed = (v.dx * v.dx + v.dy * v.dy).squareRoot()
            #expect(abs(speed - Feel.Physics.jumpImpulse) < 0.5)
        }
    }

    @Test func canReachAgreesWithLaunch() {
        let a = CGPoint(x: 100, y: 500)
        #expect(Cat.canReach(from: a, to: CGPoint(x: 160, y: 500)))
        #expect(!Cat.canReach(from: a, to: CGPoint(x: 1000, y: 500)))
    }
}
