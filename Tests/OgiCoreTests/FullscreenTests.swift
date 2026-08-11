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
        // Close everything, open a browser fullscreen. An edge-triggered retreat fires on the
        // first sighting, before the fullscreen window has aged into furniture he may climb,
        // consumes itself against an unroutable world, and is gone: he sits at the bottom of
        // a covered screen with no urgency at all. No stimulus is delivered in this test,
        // only the level signal, and he must still end up at the top, by climbing the
        // covering window's own face.
        let world = fullscreenWorld()
        let floor = world.surface(.floor)!
        let barY = world.surface(.menuBar)!.y
        var cat = CatState(position: CGPoint(x: 700, y: floor.y))
        cat.support = .grounded(Perch(id: .floor, dx: 700 - floor.extent.lowerBound))
        cat.screenCovered = true
        cat.homeX = 500
        cat.restLeft = .greatestFiniteMagnitude   // taste must not be what saves him

        let dt = Feel.Timing.fixedDT
        var elapsed = 0.0
        for _ in 0..<Int(60 / dt) {
            cat = Cat.step(cat, world: world, dt: dt)
            elapsed += dt
            if case .grounded(let p) = cat.support, let s = world.surface(p.id),
               s.y >= barY - Feel.World.coplanarTolerance { break }
        }
        // ...and fast. Timed on a real fullscreen Space, the ordinary route takes eighteen
        // seconds (a run along a floor nobody can see, then a ten-second climb), which is
        // longer than most people spend on the Space at all. He is behind the covering
        // window for all of it, so he surfaces at its lip instead of climbing to it.
        #expect(elapsed < 2,
                "took \(String(format: "%.1f", elapsed))s to get up top; the film is over by then")
        guard case .grounded(let p) = cat.support, let top = world.surface(p.id) else {
            Issue.record("not grounded at the end, at y=\(cat.position.y)")
            return
        }
        #expect(top.y >= barY - Feel.World.coplanarTolerance,
                "still at y=\(Int(cat.position.y)): chilling at the bottom of a covered screen")
    }

    /// Chrome's fullscreen, dumped live from a real window list: four stacked full-width bands
    /// rather than one window. The band that buries him has its own top edge buried under the
    /// next one, so "the lip of the window over me" is not somewhere anyone can see him, and he
    /// stays on the floor of a covered screen for the whole film because of it.
    @Test func heSurfacesOnAFullscreenThatIsFourStackedBands() {
        // The real screen too, not the square one the tests above use: on a notched Mac the
        // menu bar line is y=1205 and the bands stop exactly there, which is the whole reason
        // their top edge counts as up top.
        let real = ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1920, height: 1243),
                                  visibleFrame: CGRect(x: 0, y: 90, width: 1920, height: 1115),
                                  notch: CGRect(x: 856, y: 1206, width: 208, height: 37))
        // Front-to-back, the order CGWindowList reports them in, because that IS the z order
        // and it decides which lips are buried: the toolbars sit in front of the content, so
        // the content's own top edge at y=1083 is carved away to nothing by the band above it.
        let bands = [(1164.0, 41.0), (1083.0, 81.0), (1047.0, 158.0), (0.0, 1083.0)]
            .enumerated().map { i, b in
                RawWindow(id: CGWindowID(10 + i), pid: 8, layer: 0,
                          rect: CGRect(x: 0, y: b.0, width: 1920, height: b.1),
                          alpha: 1, owner: "Google Chrome")
            }
        let world = World.build(windows: bands, screen: real, ownPID: 99)
        let floor = world.surface(.floor)!
        let barY = world.surface(.menuBar)!.y
        var cat = CatState(position: CGPoint(x: 522, y: floor.y))
        cat.support = .grounded(Perch(id: .floor, dx: 522 - floor.extent.lowerBound))
        cat.screenCovered = true
        cat.homeX = 500
        cat.restLeft = .greatestFiniteMagnitude

        let dt = Feel.Timing.fixedDT
        var elapsed = 0.0
        for _ in 0..<Int(30 / dt) {
            cat = Cat.step(cat, world: world, dt: dt)
            elapsed += dt
            if case .grounded(let p) = cat.support, let s = world.surface(p.id),
               s.y >= barY - Feel.World.coplanarTolerance { break }
        }
        guard case .grounded(let p) = cat.support, let top = world.surface(p.id) else {
            Issue.record("not grounded at the end, at y=\(cat.position.y)")
            return
        }
        #expect(top.y >= barY - Feel.World.coplanarTolerance,
                "still at y=\(Int(cat.position.y)): the banded fullscreen left him underneath it")
        #expect(elapsed < 2, "took \(String(format: "%.1f", elapsed))s to surface")
        // Wherever he comes up, all of him has to be on lit pixels: clear of the cutout and
        // clear of both ends of the panel. The draw is random now, so this is the invariant
        // that replaces "he comes up where he was hiding".
        let notch = real.notch!
        let box = CGRect(x: cat.position.x - Feel.Shape.clearance, y: 0,
                         width: Feel.Shape.clearance * 2, height: 1)
        #expect(!box.intersects(CGRect(x: notch.minX, y: -1, width: notch.width, height: 3)),
                "surfaced at x=\(Int(cat.position.x)), part of him inside the cutout")
        #expect(box.minX >= real.visibleFrame.minX && box.maxX <= real.visibleFrame.maxX,
                "surfaced at x=\(Int(cat.position.x)), part of him off the panel")
    }

    /// Coming up directly above wherever he was buried is the same spot every time on a desktop
    /// you use the same way every day, and it looks like it. Nobody can see him before he
    /// surfaces, so the draw is free.
    @Test func heDoesNotSurfaceInTheSamePlaceEveryTime() {
        let world = fullscreenWorld()
        let floor = world.surface(.floor)!
        var seen = Set<Int>()
        for trial in 0..<20 {
            // A seed per trial. Every cat defaults to the same fixed stream, so without this
            // all the trials are one trial and a "sometimes" test becomes an "always" one.
            var cat = CatState(position: CGPoint(x: 700, y: floor.y))
            cat.roll = Roll(seed: UInt64(trial))
            cat.support = .grounded(Perch(id: .floor, dx: 700 - floor.extent.lowerBound))
            guard Cat.surfaceOverTheLip(&cat, world: world) else {
                Issue.record("did not surface at all")
                return
            }
            seen.insert(Int(cat.position.x / 40))
        }
        #expect(seen.count > 5,
                "twenty surfacings landed in \(seen.count) places; he is still popping up on a mark")
    }

    @Test func atTheDoorTheStandingOrderLeavesHimAlone() {
        // The standing order must stop asking once it is satisfied, or a film is a cat walking
        // on the spot for two hours.
        //
        // What satisfies it is being AT THE DOOR, not merely up top. "Anywhere up top" leaves
        // him asleep in the ordinary curl on an arbitrary spot with a film on: he is on the
        // bar, so nothing ever walks him the rest of the way to the doorway and the den is
        // unreachable. So this asserts the settling rather than the staying put.
        let world = fullscreenWorld()
        let bar = world.surface(.menuBar)!
        var cat = CatState(position: CGPoint(x: 500, y: bar.y))
        cat.support = .grounded(Perch(id: .menuBar, dx: 500 - bar.extent.lowerBound))
        cat.screenCovered = true
        cat.homeX = 500
        cat.restLeft = .greatestFiniteMagnitude

        let dt = Feel.Timing.fixedDT
        for _ in 0..<Int(10 / dt) { cat = Cat.step(cat, world: world, dt: dt) }
        #expect(abs(cat.position.x - 500) < 1, "he paced away from the door he was already at")
    }

    @Test func awayFromTheDoorTheStandingOrderWalksHimToIt() {
        // The other half, and the bug itself: up top but not at the doorway is NOT where he
        // belongs during a film, because the den is the only place the sleep goes.
        let world = fullscreenWorld()
        let bar = world.surface(.menuBar)!
        var cat = CatState(position: CGPoint(x: 1500, y: bar.y))
        cat.support = .grounded(Perch(id: .menuBar, dx: 1500 - bar.extent.lowerBound))
        cat.screenCovered = true
        cat.homeX = 500
        cat.restLeft = .greatestFiniteMagnitude

        let dt = Feel.Timing.fixedDT
        for _ in 0..<Int(60 / dt) { cat = Cat.step(cat, world: world, dt: dt) }
        #expect(abs(cat.position.x - 500) < Feel.Physics.arrivalSlop * 3,
                "he stayed at \(cat.position.x) with a film on instead of going to the door")
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
