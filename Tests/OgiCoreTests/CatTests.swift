import Testing
import CoreGraphics
@testable import OgiCore

private let screen = ScreenGeometry(
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1243),
    visibleFrame: CGRect(x: 0, y: 90, width: 1920, height: 1115),
    notch: nil)

private func sky(_ surfaces: [Surface]) -> Skyline {
    Skyline(surfaces: surfaces, occluders: [], screen: screen)
}

private func surface(_ id: SurfaceID, y: CGFloat, from: CGFloat, to: CGFloat, z: Int = 0) -> Surface {
    Surface(id: id, z: z, y: y, extent: from...to,
            solid: [from...to], spans: [from...to], targetable: true, rect: nil)
}

private let dt = Feel.Timing.fixedDT

@Test func gravityClampsAtTerminalVelocity() {
    var cat = CatState(position: CGPoint(x: 100, y: 5000))
    let world = sky([])
    for _ in 0..<2000 { cat = Cat.step(cat, world: world, dt: dt) }
    #expect(cat.velocity.dy >= -Feel.Physics.terminalVelocity - 1)
    #expect(cat.velocity.dy <= -Feel.Physics.terminalVelocity + 1)
}

@Test func heDoesNotTunnelThroughSurfacesAtTerminalVelocity() {
    // Surfaces are infinitely thin lines and a 120Hz step at terminal velocity covers ~12px.
    // A point test would drop him straight through the window.
    let ground = surface(.window(1), y: 100, from: 0, to: 500)
    let world = sky([ground])
    var cat = CatState(position: CGPoint(x: 250, y: 1300))

    for _ in 0..<1000 {
        cat = Cat.step(cat, world: world, dt: dt)
        if case .grounded = cat.support { break }
    }

    guard case .grounded(let perch) = cat.support else {
        Issue.record("tunnelled through the surface")
        return
    }
    #expect(perch.id == .window(1))
    #expect(cat.position.y == 100)
}

@Test func vanishingPlatformMakesHimFall() {
    let ground = surface(.window(1), y: 500, from: 0, to: 400)
    var cat = CatState(position: CGPoint(x: 200, y: 500))
    cat.support = .grounded(Perch(id: .window(1), dx: 200))

    cat = Cat.step(cat, world: sky([ground]), dt: dt)
    #expect(cat.support == .grounded(Perch(id: .window(1), dx: 200)))

    // Close the window.
    cat = Cat.step(cat, world: sky([]), dt: dt)
    #expect(cat.support == .falling)
    #expect(cat.activity == .slip)
}

@Test func draggingHisWindowCarriesHim() {
    // The whole point of platform-local anchoring: surfing costs zero code.
    var cat = CatState(position: CGPoint(x: 200, y: 500))
    cat.support = .grounded(Perch(id: .window(1), dx: 150))

    let before = surface(.window(1), y: 500, from: 50, to: 450)
    cat = Cat.step(cat, world: sky([before]), dt: dt)
    #expect(cat.position.x == 200)

    // Window moves right by 200 and up by 30.
    let after = surface(.window(1), y: 530, from: 250, to: 650)
    cat = Cat.step(cat, world: sky([after]), dt: dt)

    #expect(cat.position.x == 400, "he did not surf the window")
    #expect(cat.position.y == 530)
    guard case .grounded(let perch) = cat.support else { Issue.record("fell off"); return }
    #expect(perch.dx == 150, "his platform-local offset should be untouched")
}

@Test func shrinkingWindowSlidesHimOffTheEdge() {
    var cat = CatState(position: CGPoint(x: 400, y: 500))
    cat.support = .grounded(Perch(id: .window(1), dx: 350))

    let wide = surface(.window(1), y: 500, from: 50, to: 450)
    cat = Cat.step(cat, world: sky([wide]), dt: dt)
    #expect(cat.support == .grounded(Perch(id: .window(1), dx: 350)))

    // Resized narrower; his offset is now past the right edge.
    let narrow = surface(.window(1), y: 500, from: 50, to: 250)
    cat = Cat.step(cat, world: sky([narrow]), dt: dt)
    #expect(cat.support == .falling)
}

// MARK: - Edges

/// A ledge from x=400 to x=900 at y=600, with the floor a long way below it at y=100.
private func ledgeWorld() -> Skyline {
    sky([surface(.window(1), y: 600, from: 400, to: 900),
         surface(.floor, y: 100, from: 0, to: 1920, z: .max)])
}

@Test func heWalksOffTheEndOfALedgeAndFalls() {
    let world = ledgeWorld()
    var cat = CatState(position: CGPoint(x: 880, y: 600))
    cat.support = .grounded(Perch(id: .window(1), dx: 480))
    cat.facing = 1
    cat.goal = .walkTo(1200)          // past the right-hand end at 900

    for _ in 0..<600 {
        cat = Cat.step(cat, world: world, dt: dt)
        if case .falling = cat.support { break }
    }

    guard case .falling = cat.support else {
        Issue.record("still grounded at x=\(Int(cat.position.x)); clampToSurface is still pinning him")
        return
    }
}

@Test func heTurnsAroundAtAWallInsteadOfStopping() {
    // The floor's left edge has nothing below it, so it is a wall, not a cliff.
    let world = ledgeWorld()
    var cat = CatState(position: CGPoint(x: 30, y: 100))
    cat.support = .grounded(Perch(id: .floor, dx: 30))
    cat.facing = -1
    cat.goal = .walkTo(-500)

    for _ in 0..<600 { cat = Cat.step(cat, world: world, dt: dt) }

    guard case .grounded = cat.support else {
        Issue.record("he fell off the bottom of the world")
        return
    }
    #expect(cat.position.x >= 0)
    #expect(cat.facing == 1)          // turned around
}

@Test func edgeAheadFindsTheEndOfSolidGround() {
    let s = ledgeWorld().surface(.window(1))!
    #expect(Cat.edgeAhead(from: 500, facing: 1, on: s) == 900)
    #expect(Cat.edgeAhead(from: 500, facing: -1, on: s) == 400)
    #expect(Cat.edgeAhead(from: 5000, facing: 1, on: s) == nil)
}

@MainActor
@Test func heArrivesStandingOnSolidGround() {
    // The notch is a hole in the menu bar's `solid` — a hardware cutout with no pixels
    // behind it — so the doorway he steps out of is its *edge*. Grounding him at its centre
    // stands him on nothing, and the edge test drops him on the first tick after launch.
    let notched = ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1920, height: 1243),
                                 visibleFrame: CGRect(x: 0, y: 90, width: 1920, height: 1115),
                                 notch: CGRect(x: 830, y: 1205, width: 200, height: 38))
    let world = World.build(windows: [], screen: notched, ownPID: 0)
    let bar = world.surface(.menuBar)!
    var cat = OgiApp.arrival(notch: notched.notch!, bar: bar, screenMaxX: notched.frame.maxX)

    guard case .grounded(let perch) = cat.support else {
        Issue.record("he arrives in mid-air")
        return
    }
    #expect(bar.solid.contains { $0.contains(bar.extent.lowerBound + perch.dx) },
            "he was placed where the menu bar has no pixels behind it")

    // ...and he walks out of the doorway rather than dropping straight through it.
    for _ in 0..<Int(2 / dt) { cat = Cat.step(cat, world: world, dt: dt) }
    guard case .grounded = cat.support else {
        Issue.record("he fell out of the world on launch, at x=\(Int(cat.position.x))")
        return
    }
    #expect(cat.position.x > notched.notch!.maxX, "he never left the doorway")
}

@Test func squashDepthIsMonotonicInImpactSpeed() {
    let ground = surface(.window(1), y: 100, from: 0, to: 500)
    let world = sky([ground])

    func land(fromHeight h: CGFloat) -> CGFloat {
        var cat = CatState(position: CGPoint(x: 250, y: 100 + h))
        for _ in 0..<3000 {
            cat = Cat.step(cat, world: world, dt: dt)
            if case .grounded = cat.support { return cat.squash }
        }
        return -1
    }

    let gentle = land(fromHeight: 40)
    let hard = land(fromHeight: 600)
    #expect(gentle > 0)
    #expect(hard > gentle, "a longer fall must squash deeper")
    #expect(hard <= Feel.Shape.maxSquash + 0.001)
}

@Test func squashSpringsBackToNeutral() {
    var cat = CatState(position: .zero)
    cat.support = .grounded(Perch(id: .floor, dx: 0))
    cat.squash = Feel.Shape.maxSquash
    cat.squashElapsed = 0
    #expect(cat.scale.height < 0.8, "should start compressed")

    let ground = surface(.floor, y: 0, from: -100, to: 100)
    for _ in 0..<Int(0.4 / dt) { cat = Cat.step(cat, world: sky([ground]), dt: dt) }
    #expect(abs(cat.scale.height - 1) < 0.02, "should settle back to neutral")
}

@Test func landingOnTheHigherOfTwoSurfaces() {
    let low = surface(.window(1), y: 100, from: 0, to: 500, z: 1)
    let high = surface(.window(2), y: 300, from: 0, to: 500, z: 0)
    var cat = CatState(position: CGPoint(x: 250, y: 900))

    for _ in 0..<1000 {
        cat = Cat.step(cat, world: sky([low, high]), dt: dt)
        if case .grounded = cat.support { break }
    }
    guard case .grounded(let perch) = cat.support else { Issue.record("never landed"); return }
    #expect(perch.id == .window(2), "landed on the lower surface, passing through the higher one")
}

@MainActor
@Test func heFallsAsAFallingCatForTheWholeDropNotJustTheFirstMoment() {
    // The fall is the demo, and it was 120ms long. `.slip` timed out into `.airborne` after
    // 0.12s, and `.airborne` draws the jump sheet — so closing his window played a sliver of
    // the fall and then a *jumping* cat all the way down. Every existing test passed through
    // it, because they all assert on physics and this was only ever visible on screen.
    let ground = surface(.window(1), y: 900, from: 0, to: 400)
    var cat = CatState(position: CGPoint(x: 200, y: 900))
    cat.support = .grounded(Perch(id: .window(1), dx: 200))
    cat = Cat.step(cat, world: sky([ground]), dt: dt)

    cat = Cat.step(cat, world: sky([]), dt: dt)          // close the window
    #expect(cat.activity == .slip)

    // Two full seconds of falling, far longer than the old 0.12s timeout.
    for _ in 0..<Int(2.0 / dt) {
        cat = Cat.step(cat, world: sky([]), dt: dt)
        guard case .falling = cat.support else { break }
        #expect(Sprites.clip(for: cat.activity, dangling: false) == .fall,
                "drew \(Sprites.clip(for: cat.activity, dangling: false)) mid-fall, not .fall")
    }
}

@MainActor
@Test func droppingHimAlsoDrawsTheFallSheet() {
    // The other way he leaves the ground without choosing to. Righting used to hand over to
    // `.airborne` once the twist finished, which put him back on the jump sheet in mid-air.
    var cat = CatState(position: CGPoint(x: 200, y: 900))
    cat = Cat.release(cat, throwVelocity: CGVector(dx: 0, dy: 0))
    #expect(cat.activity == .righting)

    for _ in 0..<Int(1.0 / dt) {
        cat = Cat.step(cat, world: sky([]), dt: dt)
        guard case .falling = cat.support else { break }
        #expect(Sprites.clip(for: cat.activity, dangling: false) == .fall,
                "drew \(Sprites.clip(for: cat.activity, dangling: false)) after being dropped")
    }
}

@MainActor
@Test func heSometimesWashesInsteadOfGoingSomewhere() {
    // Manifesto §7.1 wants an occasional in-place behaviour while awake. The failure this
    // guards is a wash that never ends: `groom` has no goal, so it sits in the same branch as
    // resting and would loop forever if the timeout were dropped.
    let ground = surface(.window(1), y: 500, from: 0, to: 900)
    var grooming = 0, longest = 0.0
    for seed in 0..<400 {
        var cat = CatState(position: CGPoint(x: 400 + CGFloat(seed % 5), y: 500))
        cat.support = .grounded(Perch(id: .window(1), dx: 400))
        cat.restLeft = 0
        var elapsed = 0.0, thisBout = 0.0
        while elapsed < 20 {
            cat = Cat.step(cat, world: sky([ground]), dt: dt)
            elapsed += dt
            if cat.activity == .groom { thisBout += dt; longest = max(longest, thisBout) }
            else { thisBout = 0 }
        }
        if longest > 0 { grooming += 1 }
    }
    #expect(grooming > 0, "he never washed in 400 runs")
    #expect(longest < Feel.Timing.groomSeconds + 1,
            "a washing bout ran \(longest)s and should cap at \(Feel.Timing.groomSeconds)s")
    #expect(Sprites.clip(for: .groom, dangling: false) == .groom)
}

@MainActor
@Test func aNonLoopingClipStartsAtItsFirstFrame() {
    // The settled branch reassigns `activity` every tick, so nothing there ever reset the
    // animation clock. `sitdown` and `curl` do not loop, which meant they were handed however
    // long he had been idle and rendered their last frame immediately — the settling animation
    // existed in the sheet and had never once played on screen.
    let ground = surface(.window(1), y: 500, from: 0, to: 900)
    var cat = CatState(position: CGPoint(x: 400, y: 500))
    cat.support = .grounded(Perch(id: .window(1), dx: 400))
    // He must not invent plans of his own here: an idea five seconds in changes his activity
    // and resets the very clock this test needs to be stale. That was a 1-in-10 flake.
    cat.restLeft = .greatestFiniteMagnitude
    for _ in 0..<600 { cat = Cat.step(cat, world: sky([ground]), dt: dt) }   // let time pile up
    #expect(cat.activityElapsed > 1, "needed a stale clock to make this test mean anything")

    cat.repose = .curled
    cat = Cat.step(cat, world: sky([ground]), dt: dt)
    #expect(cat.activity == .curl)
    #expect(Sprites.index(.curl, activity: .curl, walkPhase: 0, elapsed: cat.activityElapsed) == 0,
            "curl began at frame \(Sprites.index(.curl, activity: .curl, walkPhase: 0, elapsed: cat.activityElapsed))")

    // ...and it does not restart every tick either, or it would never leave frame 0.
    for _ in 0..<40 { cat = Cat.step(cat, world: sky([ground]), dt: dt) }
    #expect(cat.activityElapsed > 0.1, "the clock is being reset every tick")
}
