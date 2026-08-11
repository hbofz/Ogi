import Testing
import CoreGraphics
@testable import OgiCore

@Suite struct JumpTests {

    /// Seeded, so the aim error is still real and still scatters, but the same run twice gives
    /// the same answer. The generator is passed IN rather than made here: a fresh one per call
    /// would hand every trial in a loop the identical draw, which would quietly turn the
    /// scatter tests below into assertions about one number.
    private func launched(_ dx: CGFloat, _ dy: CGFloat,
                          jitter: CGFloat = Feel.Physics.aimError,
                          using roll: inout Roll) -> CGVector? {
        Cat.launch(dx: dx, dy: dy, jitter: jitter, using: &roll)
    }

    /// For the reachability checks, which only ask whether an arc exists at all.
    private func reachable(_ dx: CGFloat, _ dy: CGFloat) -> Bool {
        var roll = Roll(seed: 0x061)
        return Cat.launch(dx: dx, dy: dy, using: &roll) != nil
    }

    /// Integrate the launch and check he actually arrives, aim error and all. A 60pt hop
    /// scatters over [53, 67], well inside the 12pt tolerance. Solving for the angle at a fixed
    /// speed instead sends a short hop off at 85°, where dR/dθ is −751 pt/rad, so ±0.06 rad
    /// puts a 60pt target anywhere in [15, 104].
    private func flightLands(dx: CGFloat, dy: CGFloat) -> Bool {
        var roll = Roll(seed: 0x061)
        guard let v = launched(dx, dy, using: &roll) else { return false }
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
        #expect(reachable(60, 0))
        #expect(flightLands(dx: 60, dy: 0))
    }

    @Test func aLongFlatLeapIsNotReachable() {
        // At 872 px/s against 2000 px/s^2 gravity, the flat range maxes out at 380pt.
        // A solver that ignores the speed budget would solve this exactly and take it anyway.
        #expect(!reachable(900, 0))
    }

    @Test func droppingFurtherMakesATargetMoreReachable() {
        // Physically correct, and the reason the reluctance has to live in behaviour rather
        // than in a maxJumpDrop constant. 600pt is comfortably past the 380pt flat range
        // and comfortably inside the 775pt range a 600pt drop buys him.
        #expect(!reachable(600, 0))
        #expect(reachable(600, -600))
    }

    @Test func heCannotJumpHigherThanHisOwnImpulse() {
        let maxRise = Feel.Physics.jumpImpulse * Feel.Physics.jumpImpulse
            / (2 * Feel.Physics.gravity)
        #expect(reachable(20, maxRise * 0.5))
        #expect(!reachable(20, maxRise * 1.5))
    }

    @Test func aLongJumpVisiblyCostsMoreThanAShortOne() {
        // The one thing a fixed-speed solve cannot give you: spending the whole budget on
        // every jump makes a 60pt hop climb 189pt and hang for 0.87s against 98pt and 0.63s
        // for a 380pt leap, so every visible proxy for effort runs backwards. Both must be
        // monotonic, and neither may exceed the budget.
        var lastSpeed: CGFloat = 0
        var lastApex: CGFloat = 0
        var roll = Roll(seed: 0x061)
        for dx in stride(from: CGFloat(40), through: 360, by: 40) {
            let v = launched(dx, 0, jitter: 0, using: &roll)!
            let speed = (v.dx * v.dx + v.dy * v.dy).squareRoot()
            let apex = v.dy * v.dy / (2 * Feel.Physics.gravity)
            #expect(speed > lastSpeed, "\(Int(dx))pt costs no more to launch than \(Int(dx) - 40)")
            #expect(apex > lastApex, "\(Int(dx))pt goes no higher than \(Int(dx) - 40)")
            #expect(speed <= Feel.Physics.jumpImpulse + 0.5, "\(Int(dx))pt overspends the budget")
            lastSpeed = speed
            lastApex = apex
        }
    }

    @Test func theAimErrorCanSendHimBothShortAndLong() {
        // Otherwise he is a machine that always sticks the landing. Asserted rather than
        // merely present, because an angular error at the minimum-energy solution would be
        // second-order and this would silently become a no-op.
        var roll = Roll(seed: 0xA1E)
        let ideal = launched(200, 0, jitter: 0, using: &roll)!.dx
        // One generator across the trials, so they genuinely scatter.
        var tries: [CGFloat] = []
        for _ in 0..<200 { tries.append(launched(200, 0, using: &roll)!.dx) }
        #expect(tries.contains { $0 < ideal * 0.99 }, "he never pushes off too softly")
        #expect(tries.contains { $0 > ideal * 1.01 }, "he never pushes off too hard")
    }

    @Test func theHardestJumpsCanBarelyOvershoot() {
        // At the edge of his reach the cheapest arc already spends nearly the whole budget, so
        // the upward half of the error is clipped against it: he can scrape a jump he barely
        // makes, but he cannot sail past it the way he can on a short hop.
        func widestOvershoot(_ dx: CGFloat) -> CGFloat {
            var roll = Roll(seed: 0x00E)
            let ideal = launched(dx, 0, jitter: 0, using: &roll)!.dx
            var widest: CGFloat = 0
            for _ in 0..<400 { widest = max(widest, launched(dx, 0, using: &roll)!.dx) }
            return widest / ideal - 1
        }
        #expect(widestOvershoot(60) > 0.05)                      // a hop: the whole error
        #expect(widestOvershoot(Cat.reachX(dy: 0) - 1) < 0.005)  // 379pt: almost none of it
    }

    @Test func nearestSpanXIsTheClosestReachablePoint() {
        let spans: [ClosedRange<CGFloat>] = [0...100, 300...400]
        #expect(Cat.nearestSpanX(to: 50, in: spans) == 50)      // already inside one
        #expect(Cat.nearestSpanX(to: 260, in: spans) == 300)    // nearer the far span's lip
        #expect(Cat.nearestSpanX(to: 900, in: spans) == 400)
        #expect(Cat.nearestSpanX(to: 0, in: []) == nil)
    }

    @Test func canReachAgreesWithLaunch() {
        let a = CGPoint(x: 100, y: 500)
        #expect(Cat.canReach(from: a, to: CGPoint(x: 160, y: 500)))
        #expect(!Cat.canReach(from: a, to: CGPoint(x: 1000, y: 500)))
    }
}
