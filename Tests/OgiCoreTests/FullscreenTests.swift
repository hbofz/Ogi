import Testing
import Foundation
import CoreGraphics
@testable import OgiCore

/// A fullscreen space: no menu bar, no dock, one window covering the whole frame. The
/// window's top edge and the synthetic menu-bar line are the same y, and `supportBelow`
/// tie-breaks every landing on that line to the menu bar (z = -1). An intent whose
/// destination is the window's top surface therefore can never arrive, and re-planning on
/// each touchdown launches a fresh jump, forever, straight up against the top of the screen.
@Suite struct FullscreenTests {

    private let screen = ScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1243),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1243),
        notch: nil)

    private func fullscreenWorld() -> Skyline {
        let w = RawWindow(id: 1, pid: 7, layer: 0,
                          rect: CGRect(x: 0, y: 0, width: 1920, height: 1243),
                          alpha: 1, owner: "Safari")
        return World.build(windows: [w], screen: screen, ownPID: 99)
    }

    @Test func aCoveredScreenIsAStandingOrderNotAnEvent() {
        // What Hamzah watched: close everything, open Chrome fullscreen. The edge-triggered
        // retreat fired on the first sighting, before the fullscreen window had aged into
        // furniture he may climb, consumed itself against an unroutable world, and was gone:
        // he sat at the bottom of a covered screen, chilling, with no urgency at all. No
        // stimulus is delivered in this test — only the level signal — and he must still
        // end up at the top, by climbing the covering window's own face.
        let world = fullscreenWorld()
        let floor = world.surface(.floor)!
        let barY = world.surface(.menuBar)!.y
        var cat = CatState(position: CGPoint(x: 700, y: floor.y))
        cat.support = .grounded(Perch(id: .floor, dx: 700 - floor.extent.lowerBound))
        cat.screenCovered = true
        cat.homeX = 500
        cat.restLeft = .greatestFiniteMagnitude   // taste must not be what saves him

        let dt = Feel.Timing.fixedDT
        var formed = false
        for _ in 0..<Int(60 / dt) {
            cat = Cat.step(cat, world: world, dt: dt)
            formed = formed || cat.intent != nil
            if case .grounded(let p) = cat.support, let s = world.surface(p.id),
               s.y >= barY - Feel.World.coplanarTolerance { break }
        }
        #expect(formed, "the standing order never formed an intent")
        guard case .grounded(let p) = cat.support, let top = world.surface(p.id) else {
            Issue.record("not grounded at the end, at y=\(cat.position.y)")
            return
        }
        #expect(top.y >= barY - Feel.World.coplanarTolerance,
                "still at y=\(Int(cat.position.y)): chilling at the bottom of a covered screen")
    }

    @Test func upTopTheStandingOrderLeavesHimAlone() {
        // On the menu bar of a covered screen he is exactly where he belongs, and the
        // standing order must not make him pace toward homeX for ever.
        let world = fullscreenWorld()
        let bar = world.surface(.menuBar)!
        var cat = CatState(position: CGPoint(x: 1500, y: bar.y))
        cat.support = .grounded(Perch(id: .menuBar, dx: 1500 - bar.extent.lowerBound))
        cat.screenCovered = true
        cat.homeX = 500
        cat.restLeft = .greatestFiniteMagnitude

        let dt = Feel.Timing.fixedDT
        for _ in 0..<Int(10 / dt) { cat = Cat.step(cat, world: world, dt: dt) }
        #expect(abs(cat.position.x - 1500) < 1, "he paced toward home despite being up top")
    }

    @Test func heDoesNotJumpAtASurfaceCoplanarWithHisOwn() {
        let world = fullscreenWorld()
        let bar = world.surface(.menuBar)!
        var cat = CatState(position: CGPoint(x: 960, y: bar.y))
        cat.support = .grounded(Perch(id: .menuBar, dx: 960 - bar.extent.lowerBound))

        let move = Cat.nextMove(from: cat, on: bar, toward: .window(1), x: 300, world: world)
        if case .jump = move {
            Issue.record("jumped at a coplanar surface he can simply walk on: \(String(describing: move))")
        }
    }

    @Test func anIntentAtAFullscreenWindowTopSettlesInsteadOfLoopingForever() {
        let world = fullscreenWorld()
        let bar = world.surface(.menuBar)!
        var cat = CatState(position: CGPoint(x: 960, y: bar.y))
        cat.support = .grounded(Perch(id: .menuBar, dx: 960 - bar.extent.lowerBound))
        cat.restLeft = .greatestFiniteMagnitude
        cat.intent = Intent(destination: .window(1), destinationX: 300,
                            move: Cat.nextMove(from: cat, on: bar, toward: .window(1),
                                               x: 300, world: world) ?? .walk(300))

        let dt = Feel.Timing.fixedDT
        var launches = 0
        var wasAirborne = false
        for _ in 0..<Int(30 / dt) {
            cat = Cat.step(cat, world: world, dt: dt)
            let airborne = cat.support == .falling
            if airborne && !wasAirborne { launches += 1 }
            wasAirborne = airborne
            if cat.intent == nil { break }
        }
        #expect(cat.intent == nil, "still chasing the same intent after 30 simulated seconds")
        #expect(launches <= 1, "went airborne \(launches) times chasing one coplanar intent")
    }
}
