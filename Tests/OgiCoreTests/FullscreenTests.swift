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
