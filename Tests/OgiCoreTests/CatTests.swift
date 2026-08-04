import Testing
import Foundation
import CoreGraphics
@testable import OgiCore

private let screen = ScreenGeometry(
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1243),
    visibleFrame: CGRect(x: 0, y: 90, width: 1920, height: 1115),
    notch: nil)

private func sky(_ surfaces: [Surface]) -> Skyline {
    Skyline(surfaces: surfaces, occluders: [], screen: screen)
}

private func surface(_ id: SurfaceID, y: CGFloat, from: CGFloat, to: CGFloat, z: Int = 0,
                     rect: CGRect? = nil) -> Surface {
    Surface(id: id, z: z, y: y, extent: from...to,
            solid: [from...to], spans: [from...to], targetable: true, rect: rect)
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
    // This branch returns before the grounded branch can recompute it, so the reading has to
    // be cleared on the way in rather than at each exit.
    #expect(cat.footing.edgeAhead == .infinity)
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
/// The ledge is the top edge of a window whose face runs down to y=300, which is what he
/// clings to.
private func ledgeWorld() -> Skyline {
    sky([surface(.window(1), y: 600, from: 400, to: 900,
                 rect: CGRect(x: 400, y: 300, width: 500, height: 300)),
         surface(.floor, y: 100, from: 0, to: 1920, z: .max)])
}

@Test func heWalksOffTheEndOfALedgeAndFalls() {
    let world = ledgeWorld()
    var cat = CatState(position: CGPoint(x: 880, y: 600))
    cat.support = .grounded(Perch(id: .window(1), dx: 480))
    cat.facing = 1
    // Past the right-hand end at 900.
    cat.intent = Intent(destination: .window(1), destinationX: 1200, move: .walk(1200))

    for _ in 0..<600 {
        cat = Cat.step(cat, world: world, dt: dt)
        if case .falling = cat.support { break }
    }

    guard case .falling = cat.support else {
        Issue.record("still grounded at x=\(Int(cat.position.x)); clampToSurface is still pinning him")
        return
    }
    #expect(cat.footing.edgeAhead == .infinity, "airborne, still reporting the ledge he left")
}

@Test func heTurnsAroundAtAWallInsteadOfStopping() {
    // The floor's left edge has nothing below it, so it is a wall, not a cliff.
    let world = ledgeWorld()
    var cat = CatState(position: CGPoint(x: 30, y: 100))
    cat.support = .grounded(Perch(id: .floor, dx: 30))
    cat.facing = -1
    cat.intent = Intent(destination: .floor, destinationX: -500, move: .walk(-500))

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

// MARK: - Footing

@Test func footingMeasuresTheDropAhead() {
    let world = ledgeWorld()          // ledge 400...900 at y=600, floor at y=100
    var cat = CatState(position: CGPoint(x: 850, y: 600))
    cat.support = .grounded(Perch(id: .window(1), dx: 450))
    cat.facing = 1

    cat = Cat.step(cat, world: world, dt: dt)

    #expect(abs(cat.footing.edgeAhead - 50) < 1)      // 900 - 850
    #expect(cat.footing.dropAhead != nil)
    #expect(abs((cat.footing.dropAhead ?? 0) - 500) < 1)   // 600 - 100
    #expect(cat.footing.landingAhead == .floor)
    #expect(cat.footing.isCliff)
    #expect(!cat.footing.gapAhead)
    #expect(!cat.footing.isAtEdge)                    // 50 > edgeApproach
}

@Test func footingReportsNoDropAtAWall() {
    let world = ledgeWorld()
    var cat = CatState(position: CGPoint(x: 20, y: 100))
    cat.support = .grounded(Perch(id: .floor, dx: 20))
    cat.facing = -1

    cat = Cat.step(cat, world: world, dt: dt)

    #expect(cat.footing.dropAhead == nil)             // wall, nothing below the floor
    #expect(cat.footing.landingAhead == nil)
    #expect(!cat.footing.isCliff)
    #expect(!cat.footing.gapAhead, "the end of the world is not a hole")
    #expect(cat.footing.isAtEdge)                     // 20 <= edgeApproach
}

@Test func footingIsClearedOnTheTickHeCommitsToAJump() {
    // The fourth way off the ground, and the one with no `.falling` branch in front of it:
    // `ground` decides to launch *after* footing has been computed, so the launch tick ended
    // with him airborne and still reporting a 50pt edge and a 500pt drop under it. That is
    // exactly the frame a hesitation tell reads, and it would play one over a cat already in
    // the air.
    let world = ledgeWorld()
    var cat = CatState(position: CGPoint(x: 850, y: 600))
    cat.support = .grounded(Perch(id: .window(1), dx: 450))
    cat.facing = 1
    cat.intent = Intent(destination: .floor, destinationX: 1200, move: .jump(.floor, 1200))
    cat.activity = .crouch          // already past the decision; only the wind-up is left

    cat = Cat.step(cat, world: world, dt: dt)
    #expect(cat.footing.dropAhead != nil, "he was never measuring an edge, so this proves nothing")

    for _ in 0..<Int(1 / dt) {
        cat = Cat.step(cat, world: world, dt: dt)
        if case .falling = cat.support { break }
    }
    guard case .falling = cat.support else { Issue.record("he never left the ground"); return }
    #expect(cat.footing.edgeAhead == .infinity, "airborne, still standing next to a drop")
    #expect(cat.footing.dropAhead == nil)
}

@Test func footingIsInfiniteWhileAirborne() {
    let world = ledgeWorld()
    var cat = CatState(position: CGPoint(x: 600, y: 900))
    cat.support = .falling

    cat = Cat.step(cat, world: world, dt: dt)

    #expect(cat.footing.edgeAhead == .infinity)
    #expect(!cat.footing.isAtEdge)
}

/// A 1920-wide screen with a 200pt cutout at 830...1030, as a notched Mac reports it.
///
/// The cutout's bottom edge is one point ABOVE the menu bar line, which is what the machine
/// actually reports: `safeAreaInsets.top` is 37 while the menu bar is 38 tall, so
/// `visibleFrame.maxY` is 1205 and the notch runs 1206...1243. Measured on the real display
/// (`notch=(856.0, 1206.0, 208.0, 37.0)`), and `WorldTests` uses the same offset. A fixture
/// flush at 1205 is one point kinder than the hardware, and the point it forgives is exactly
/// the row of him that the occluder cannot cover.
private let notched = ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1920, height: 1243),
                                     visibleFrame: CGRect(x: 0, y: 90, width: 1920, height: 1115),
                                     notch: CGRect(x: 830, y: 1206, width: 200, height: 37))

@Test func heDoesNotWalkIntoTheNotch() {
    // The cutout is a hole in the MIDDLE of the menu bar, not the end of it, and the desktop
    // visible through it makes it look exactly like a ledge. It is a trap: he cannot jump the
    // gap (nextMove walks along the surface he is on rather than jumping to it) and he cannot
    // climb back up
    // from the floor a thousand points below (his whole impulse buys 190pt of rise), so one
    // step in and he is off the menu bar for the rest of the session. An interior gap has to
    // be a wall.
    let world = World.build(windows: [], screen: notched, ownPID: 99)
    let bar = world.surface(.menuBar)!
    let notch = notched.notch!
    var cat = CatState(position: CGPoint(x: 1200, y: bar.y))
    cat.support = .grounded(Perch(id: .menuBar, dx: 1200 - bar.extent.lowerBound))

    for _ in 0..<Int(10 / dt) {
        // Re-issued every time he gives up, so he spends the whole ten seconds shoving at the
        // far side of the cutout instead of idling. Idling is no longer inert: a deep drop is
        // easier to reach than a shallow one, so left alone he now deliberately leaps off the
        // menu bar to the desktop, which is a feature and not what this test is about.
        // Straight across the cutout.
        if cat.intent == nil {
            cat.intent = Intent(destination: .menuBar, destinationX: 400, move: .walk(400))
        }
        cat = Cat.step(cat, world: world, dt: dt)
        guard case .grounded(let p) = cat.support, p.id == .menuBar else {
            Issue.record("he stepped into the notch at x=\(Int(cat.position.x)) and cannot get back")
            return
        }
        #expect(cat.position.x >= notch.maxX - 0.001, "he is standing in the cutout")
    }
}

@Test func footingReportsNoDropAtTheNotch() {
    // The third case, and the reason `Footing` cannot re-derive the answer from `supportBelow`
    // alone: there IS a floor a thousand points under the cutout, so a naive drop measurement
    // reports a 1115pt cliff. It is not a cliff, it is a hole with more menu bar on the far
    // side, and stepping in is one-way. `Footing` has to agree with `isCliff` or the tell will
    // hesitate over a gap he must never step into.
    let world = World.build(windows: [], screen: notched, ownPID: 99)
    let bar = world.surface(.menuBar)!
    let notch = notched.notch!
    var cat = CatState(position: CGPoint(x: notch.maxX + 30, y: bar.y))
    cat.support = .grounded(Perch(id: .menuBar, dx: notch.maxX + 30 - bar.extent.lowerBound))
    cat.facing = -1

    cat = Cat.step(cat, world: world, dt: dt)

    // There really is something below, which is what makes this the interesting case.
    #expect(world.supportBelow(x: notch.midX, from: bar.y - 1, to: -.greatestFiniteMagnitude) != nil)

    #expect(abs(cat.footing.edgeAhead - 30) < 1)
    #expect(cat.footing.dropAhead == nil, "he sees a cliff into the notch")
    #expect(cat.footing.landingAhead == nil)
    #expect(!cat.footing.isCliff)
    #expect(cat.footing.gapAhead, "a hole is not the end of the world")
}

@MainActor
@Test func heGoesHomeToTheDoorwayOnHisOwnSide() {
    // `homeX` is fixed at launch to the ONE edge he came out of. Walking to it from the far
    // side routes him across the cutout, where he now stops dead — so quitting would hang for
    // the full eight seconds of the terminate failsafe, with him standing at the lip.
    let world = World.build(windows: [], screen: notched, ownPID: 99)
    let bar = world.surface(.menuBar)!
    let notch = notched.notch!

    // He arrived out of the right-hand doorway, so homeX is notch.maxX.
    #expect(OgiApp.doorway(from: 1500, toward: notch.maxX, on: bar) == notch.maxX)
    #expect(OgiApp.doorway(from: 400, toward: notch.maxX, on: bar) == notch.minX)
    // ...and the mirror image, for a notch closer to the right-hand edge.
    #expect(OgiApp.doorway(from: 400, toward: notch.minX, on: bar) == notch.minX)
    #expect(OgiApp.doorway(from: 1500, toward: notch.minX, on: bar) == notch.maxX)

    // Standing exactly on a lip, which is the common case rather than a corner: it is where
    // the wall branch parks him after every bump, and where the under-the-notch guard puts
    // him. The runs either side of the cutout are closed, so asking which way to walk from a
    // boundary he already occupies picks the run *behind* him — from the left lip that is the
    // whole left half of the bar, a 9.7s walk the wrong way, past the 8s quit failsafe.
    #expect(OgiApp.doorway(from: notch.minX, toward: notch.minX, on: bar) == notch.minX)
    #expect(OgiApp.doorway(from: notch.maxX, toward: notch.maxX, on: bar) == notch.maxX)
    // On a centred notch homeX is the left lip, so this is what a bump on the RIGHT one gives.
    #expect(OgiApp.doorway(from: notch.maxX, toward: notch.minX, on: bar) == notch.maxX)

    // He actually reaches it, and `tick`'s arrival check fires.
    let home = OgiApp.doorway(from: 400, toward: notch.maxX, on: bar)
    var cat = CatState(position: CGPoint(x: 400, y: bar.y))
    cat.support = .grounded(Perch(id: .menuBar, dx: 400 - bar.extent.lowerBound))
    cat.intent = Intent(destination: .menuBar, destinationX: home, move: .walk(home))
    for _ in 0..<Int(30 / dt) {
        cat = Cat.step(cat, world: world, dt: dt)
        if cat.intent == nil { break }
    }
    guard case .grounded = cat.support else {
        Issue.record("he fell on the way out")
        return
    }
    #expect(abs(cat.position.x - home) < Feel.Physics.arrivalSlop * 2, "the app would hang until the failsafe")
}

@MainActor
@Test func heArrivesStandingOnSolidGround() {
    // The notch is a hole in the menu bar's `solid` — a hardware cutout with no pixels
    // behind it — so the doorway he steps out of is its *edge*. Grounding him at its centre
    // stands him on nothing, and the edge test drops him on the first tick after launch.
    let world = World.build(windows: [], screen: notched, ownPID: 99)
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

@MainActor
@Test func heComesOutOfTheDoorwayBeforeHeWalksOutOfIt() {
    // The arrival, in three beats: he is on the lip with half of him still in the cutout, he
    // creeps out, and only then does he walk. Without the hold the walk starts on the first
    // tick and the peek plays while he is already leaving, which is a cat sliding sideways.
    let world = World.build(windows: [], screen: notched, ownPID: 99)
    let bar = world.surface(.menuBar)!
    let notch = notched.notch!
    var cat = OgiApp.arrival(notch: notch, bar: bar, screenMaxX: notched.frame.maxX)
    #expect(cat.activity == .peek)

    for _ in 0..<Int(Feel.Timing.peekSeconds * 0.9 / dt) { cat = Cat.step(cat, world: world, dt: dt) }
    #expect(cat.activity == .peek, "something walked out from underneath the peek")
    #expect(abs(cat.position.x - notch.maxX) < 1, "he slid out of the doorway mid-peek")

    // ...and then he leaves, without having lost the walk that was queued behind it.
    for _ in 0..<Int(1 / dt) { cat = Cat.step(cat, world: world, dt: dt) }
    #expect(cat.activity == .walk)
    #expect(cat.position.x > notch.maxX + 10, "he never left the doorway")
}

@MainActor
@Test func thePeekFinishesBeforeHeWalksOut() {
    // Same shape as the lean at a lip: a non-looping clip holds its last frame, so the peek is
    // only ever *seen* if the hold outlasts the sheet. Derived from the clip so it tracks a
    // change to either number.
    let clip = Sprites.Clip.peek
    let toHeldFrame = Double(clip.count - 1) / clip.fps
    #expect(Feel.Timing.peekSeconds >= toHeldFrame,
            "the hold is \(Feel.Timing.peekSeconds)s and the emergence takes \(toHeldFrame)s")
}

@MainActor
@Test func theNotchClipsTheHalfOfHimStillInsideIt() {
    // What makes the peek real. He stands on the lip, which is solid, and the half of him
    // overhanging the cutout is masked away by the occlusion machinery that already exists —
    // rather than by the old trick of a black cat against a black bezel, which died the day
    // he became a ginger tabby.
    let world = World.build(windows: [], screen: notched, ownPID: 99)
    let bar = world.surface(.menuBar)!
    let notch = notched.notch!
    let cat = OgiApp.arrival(notch: notch, bar: bar, screenMaxX: notched.frame.maxX)

    // Exactly the question `renderNow` asks: everything in front of the surface he is perched
    // on, intersecting the box he is drawn in. The notch has to survive BOTH filters in there
    // — `isRealWindow` as well as the z test — or it is silently ignored.
    let body = CGRect(x: cat.position.x - Feel.Shape.width / 2, y: cat.position.y,
                      width: Feel.Shape.width, height: Feel.Shape.height)
    let mask = world.occluders(above: bar.z, intersecting: body)
    #expect(mask.contains { $0.contains(CGPoint(x: notch.maxX - 4, y: cat.position.y + 8)) },
            "the cutout does not clip the part of him that is inside it")
    #expect(!mask.contains { $0.contains(CGPoint(x: notch.maxX + 4, y: cat.position.y + 8)) },
            "it clipped the part of him that is out in the open")
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
    cat = Cat.release(cat, throwVelocity: CGVector(dx: 0, dy: 0), world: sky([]))
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
    // guards is a wash that never ends: `groom` has no intent, so it sits in the same branch as
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

// MARK: - Repose biases rather than gates

@Test func aSittingCatStillDoesThingsOccasionally() {
    let world = ledgeWorld()
    var cat = CatState(position: CGPoint(x: 600, y: 600))
    cat.support = .grounded(Perch(id: .window(1), dx: 200))
    cat.repose = .sitting

    var sawSomethingOtherThanSitting = false
    for _ in 0..<(120 * 600) {          // ten simulated minutes
        cat = Cat.step(cat, world: world, dt: 1.0 / 120)
        if cat.activity != .sit { sawSomethingOtherThanSitting = true }
    }
    #expect(sawSomethingOtherThanSitting)
}

@Test func aSleepingCatIsAHardStop() {
    let world = ledgeWorld()
    var cat = CatState(position: CGPoint(x: 600, y: 600))
    cat.support = .grounded(Perch(id: .window(1), dx: 200))
    cat.repose = .asleep

    for _ in 0..<(120 * 600) {
        cat = Cat.step(cat, world: world, dt: 1.0 / 120)
        #expect(cat.activity == .sleep)
        #expect(cat.intent == nil)
    }
}

// MARK: - The face

@Test func droppedOnAWindowFaceHeClingsToIt() {
    let world = ledgeWorld()          // window(1) rect is x 400...900, y 300...600
    var cat = CatState(position: CGPoint(x: 650, y: 420))
    cat = Cat.grab(cat, at: CGPoint(x: 650, y: 420))
    cat = Cat.release(cat, throwVelocity: .zero, world: world)

    guard case .clinging(let g) = cat.support else {
        Issue.record("expected clinging, got \(cat.support)")
        return
    }
    #expect(g.id == .window(1))
    #expect(abs(g.dx - 250) < 1)      // 650 - 400
    #expect(abs(g.dy - 180) < 1)      // 600 - 420, down from the top edge
}

@Test func droppedInOpenAirHeStillFalls() {
    let world = ledgeWorld()
    var cat = CatState(position: CGPoint(x: 1500, y: 800))
    cat = Cat.grab(cat, at: CGPoint(x: 1500, y: 800))
    cat = Cat.release(cat, throwVelocity: .zero, world: world)

    guard case .falling = cat.support else {
        Issue.record("expected falling, got \(cat.support)")
        return
    }
}

@Test func aFallPastAWindowFaceDoesNotCling() {
    // The regression that would break the fall, which is the app's entire demo.
    //
    // He has to genuinely cross the face for this to prove anything. Dropping him from
    // straight above the window does not: its top edge is terrain, so he lands on it at
    // y=600 and never reaches the face at all. So he comes in from the side, already below
    // the top edge, and drifts across it on his way to the floor — which is what happens
    // every time he steps off the menu bar past the edge of a window.
    let world = ledgeWorld()
    var cat = CatState(position: CGPoint(x: 300, y: 560))
    cat.support = .falling
    cat.velocity = CGVector(dx: 260, dy: 0)

    var crossedTheFace = false
    for _ in 0..<1200 {
        cat = Cat.step(cat, world: world, dt: 1.0 / 120)
        if world.faceContaining(cat.position) != nil { crossedTheFace = true }
        if case .clinging = cat.support {
            Issue.record("clung mid-fall at \(cat.position)")
            return
        }
    }
    #expect(crossedTheFace, "the fall never entered the face, so this test proved nothing")
}

@Test func clingingCarriesHimWhenTheWindowMoves() {
    var world = ledgeWorld()
    var cat = CatState(position: CGPoint(x: 650, y: 420))
    cat.support = .clinging(Grip(id: .window(1), dx: 250, dy: 180))
    cat = Cat.step(cat, world: world, dt: 1.0 / 120)
    let before = cat.position.x

    // Slide the window +200.
    var moved = world.surfaces
    moved[0].extent = 600...1100
    moved[0].solid = [600...1100]
    moved[0].rect = CGRect(x: 600, y: 300, width: 500, height: 300)
    world = Skyline(surfaces: moved, occluders: [], screen: world.screen)

    cat = Cat.step(cat, world: world, dt: 1.0 / 120)
    #expect(abs(cat.position.x - (before + 200)) < 1)
}

@Test func closingTheWindowUnderAClingingCatDropsHim() {
    let world = ledgeWorld()
    var cat = CatState(position: CGPoint(x: 650, y: 420))
    cat.support = .clinging(Grip(id: .window(1), dx: 250, dy: 180))

    let empty = Skyline(surfaces: world.surfaces.filter { $0.id != .window(1) },
                        occluders: [], screen: world.screen)
    cat = Cat.step(cat, world: empty, dt: 1.0 / 120)

    guard case .falling = cat.support else {
        Issue.record("expected falling, got \(cat.support)")
        return
    }
}

@Test func heSlidesDownAFaceHeCannotHoldAndEventuallyLetsGo() {
    // The beat, then the slide. Gripped 180 below the top edge, well past `mantleReach`,
    // so down is the only way he goes.
    let world = ledgeWorld()
    var cat = CatState(position: CGPoint(x: 650, y: 420))
    cat.support = .clinging(Grip(id: .window(1), dx: 250, dy: 180))

    // Nothing moves during the hold.
    for _ in 0..<Int(Feel.Timing.clingHold * 120) - 2 {
        cat = Cat.step(cat, world: world, dt: 1.0 / 120)
    }
    #expect(abs(cat.position.y - 420) < 0.5, "he slid during the hold")

    for _ in 0..<(120 * 30) {
        cat = Cat.step(cat, world: world, dt: 1.0 / 120)
        if case .falling = cat.support { break }
    }
    guard case .falling = cat.support else {
        Issue.record("still on the face after 30s, got \(cat.support)")
        return
    }
    #expect(cat.position.y < 420, "he let go without ever sliding down")
}

@Test func grippingNearTheTopHeClimbsUpAndMantlesOntoTheLedge() {
    let world = ledgeWorld()
    var cat = CatState(position: CGPoint(x: 650, y: 560))   // 40 below the top edge
    cat.support = .clinging(Grip(id: .window(1), dx: 250, dy: 40))

    for _ in 0..<(120 * 30) {
        cat = Cat.step(cat, world: world, dt: 1.0 / 120)
        if case .grounded = cat.support { break }
    }
    guard case .grounded(let p) = cat.support else {
        Issue.record("never made it over the lip, got \(cat.support)")
        return
    }
    #expect(p.id == .window(1))
    #expect(abs(cat.position.y - 600) < 0.001)
    #expect(abs(cat.position.x - 650) < 1)
}

@Test func mantlingOutOfACornerPutsHimSomewhereHeCanActuallyStand() {
    // A real window's top edge is inset by `cornerInset` and clipped to the visible screen, so
    // the column he climbed is not necessarily standable. Landing on it grounded him for
    // exactly one tick, and the shrunken-window backstop then dropped him straight back off.
    var inset = surface(.window(1), y: 600, from: 400, to: 900,
                        rect: CGRect(x: 400, y: 300, width: 500, height: 300))
    inset.solid = [410...890]           // the rounded corners eat the ends
    inset.spans = inset.solid
    let world = sky([inset, surface(.floor, y: 100, from: 0, to: 1920, z: .max)])

    var cat = CatState(position: CGPoint(x: 403, y: 560))
    cat.support = .clinging(Grip(id: .window(1), dx: 3, dy: 40))   // gripping the top-left corner

    for _ in 0..<(120 * 30) {
        cat = Cat.step(cat, world: world, dt: 1.0 / 120)
        if case .grounded = cat.support { break }
    }
    guard case .grounded = cat.support else {
        Issue.record("never made it over the lip, got \(cat.support)")
        return
    }
    // ...and he is still up there a moment later, rather than popping over and falling off.
    for _ in 0..<10 { cat = Cat.step(cat, world: world, dt: 1.0 / 120) }
    guard case .grounded(let p) = cat.support else {
        Issue.record("mantled onto a corner he cannot stand on, got \(cat.support)")
        return
    }
    #expect(p.id == .window(1))
    #expect(cat.position.x >= 410, "he is standing where no window is drawn")
}

// MARK: - The tell

/// He is on the ledge at 700 with a reason to be on the floor. `stepOffLip` picks the right-hand
/// lip at 900, since that is the one on the way to x=1200.
private func steppingOff() -> CatState {
    var cat = CatState(position: CGPoint(x: 700, y: 600))
    cat.support = .grounded(Perch(id: .window(1), dx: 300))
    cat.facing = 1
    cat.intent = Intent(destination: .floor, destinationX: 1200, move: .stepOff)
    return cat
}

@Test func heLooksBeforeHeStepsOff() {
    // The whole point of the task. Approach, slow, stop SHORT of the lip, put his head over
    // and hold — and only then go. It is the difference between the cat jumped and the cat
    // decided to jump.
    let world = ledgeWorld()
    var cat = steppingOff()

    // The first look only. He may turn this drop down and come back to it, and a second
    // episode is a second decision rather than more of this one.
    var looked = 0, lookedAt: CGFloat = 0, movedWhileLooking: CGFloat = 0
    for _ in 0..<1800 {
        cat = Cat.step(cat, world: world, dt: dt)
        if cat.activity == .edgeLook {
            if looked == 0 { lookedAt = cat.position.x }
            looked += 1
            movedWhileLooking = max(movedWhileLooking, abs(cat.position.x - lookedAt))
        } else if looked > 0 {
            break
        }
        if case .falling = cat.support { break }
    }

    #expect(looked > 0, "he walked straight off the lip without a moment's thought")
    // Long enough to read as thinking, at the 500pt drop this ledge has.
    #expect(Double(looked) * dt >= Cat.hesitation(forDrop: 500) - 2 * dt)
    // Stopped short of the lip at 900, on the ledge, not hanging over it.
    #expect(lookedAt < 900 && lookedAt > 900 - Feel.Physics.edgeApproach * 2,
            "he looked from x=\(Int(lookedAt)); the lip is at 900")
    #expect(movedWhileLooking < 0.01, "he is still drifting toward the edge while looking")
}

@Test func aDeeperDropGetsALongerLook() {
    #expect(Cat.hesitation(forDrop: 60) < Cat.hesitation(forDrop: 900))
    #expect(Cat.hesitation(forDrop: 0) == Feel.Timing.edgeHesitationMin)
    #expect(Cat.hesitation(forDrop: 99_999) == Feel.Timing.edgeHesitationMax)
}

@Test func aDeeperDropIsLessLikelyToBeTaken() {
    // This is where the reluctance lives. The solver has no maximum drop on purpose — a deeper
    // target is physically MORE reachable — so the judgement has to be behavioural.
    #expect(Cat.commitChance(forDrop: 40) > 0.9)
    #expect(Cat.commitChance(forDrop: 40) > Cat.commitChance(forDrop: 900))
    #expect(Cat.commitChance(forDrop: 99_999) > 0, "he would never come down off anything")
}

@Test func heSometimesBacksOffAHighDrop() {
    let world = ledgeWorld()
    var backedOff = 0
    for _ in 0..<60 {
        var cat = steppingOff()
        for _ in 0..<2400 {
            cat = Cat.step(cat, world: world, dt: dt)
            if case .falling = cat.support { break }
        }
        if case .grounded = cat.support { backedOff += 1 }
    }
    // A 500pt drop should be declined sometimes, and taken sometimes.
    #expect(backedOff > 2, "he took every single one; the reluctance does nothing")
    #expect(backedOff < 58, "he never goes anywhere")
}

@Test func backingOffDoesNotBecomeAPacingLoop() {
    // A cat pacing to the same lip for ever is worse than one that jumps. Two things have to
    // hold: a refusal has to put a real gap before the next approach (he goes and does
    // something else), and he has to get down eventually.
    // 90 seconds each, not 40: an approach is a slow one now (see `edgeEase`), and a refusal
    // costs a retreat, a rest and a fresh idea before he is back at the lip. At 40s the second
    // look often fell outside the window, and a trial where he only ever looked once measures
    // nothing at all — hence the refusal count below, which cannot pass vacuously.
    let world = ledgeWorld()
    var looks = 0, refusals = 0, left = 0
    var tightest = TimeInterval.infinity, closest: CGFloat = 0
    for _ in 0..<40 {
        var cat = steppingOff()
        var wasLooking = false, sinceLook = TimeInterval.infinity
        for _ in 0..<Int(90 / dt) {
            cat = Cat.step(cat, world: world, dt: dt)
            sinceLook += dt
            let looking = cat.activity == .edgeLook
            if looking, !wasLooking {
                looks += 1
                tightest = min(tightest, sinceLook)
                sinceLook = 0
            }
            // He stopped looking and is still up here: he turned it down. The retreat is a
            // destination on his own surface, which is exactly what distinguishes it.
            if wasLooking, !looking, cat.intent?.destination != .floor { refusals += 1 }
            wasLooking = looking
            if case .falling = cat.support { left += 1; break }
            if !looking { closest = max(closest, cat.position.x) }
        }
    }
    #expect(refusals > 0, "nobody refused, so the loop this guards against never happened")
    #expect(looks > 40, "every refusal was a dead end; he never came back to reconsider")
    #expect(tightest > Feel.Timing.restMin,
            "he went back to the lip \(tightest)s after turning it down: that is pacing")
    #expect(left > 20, "\(left)/40 got down; a refusal has become a dead end")
    #expect(closest <= 900, "he wandered off the ledge somewhere he was not deciding to")
}

@Test func theHoldYieldsToTheMicGoingLive() {
    // Everything that already interrupts him has to keep interrupting him. `listening` and
    // `.asleep` both return before the movement code, so the hold must sit behind them.
    let world = ledgeWorld()
    var cat = steppingOff()
    for _ in 0..<1800 {
        cat = Cat.step(cat, world: world, dt: dt)
        if cat.activity == .edgeLook { break }
    }
    #expect(cat.activity == .edgeLook, "he never got to the lip, so this proves nothing")

    cat.listening = true
    cat = Cat.step(cat, world: world, dt: dt)
    #expect(cat.activity == .alert)
    #expect(cat.intent == nil)

    var asleep = steppingOff()
    for _ in 0..<1800 {
        asleep = Cat.step(asleep, world: world, dt: dt)
        if asleep.activity == .edgeLook { break }
    }
    asleep.repose = .asleep
    asleep = Cat.step(asleep, world: world, dt: dt)
    #expect(asleep.activity == .sleep)
    #expect(asleep.intent == nil)
}

@Test func heNeverLooksOverTheNotch() {
    // The interior gap is a trap, not a ledge: there is a floor a thousand points under it, so
    // a drop measured directly reports a cliff. He must never hesitate at one, because
    // hesitating at one means considering it.
    let world = World.build(windows: [], screen: notched, ownPID: 99)
    let bar = world.surface(.menuBar)!
    let notch = notched.notch!
    var cat = CatState(position: CGPoint(x: notch.maxX + 40, y: bar.y))
    cat.support = .grounded(Perch(id: .menuBar, dx: notch.maxX + 40 - bar.extent.lowerBound))
    cat.facing = -1
    // Aimed at the floor *under the cutout*: the nearest way down is through it.
    cat.intent = Intent(destination: .floor, destinationX: notch.midX, move: .stepOff)

    var lookedNear = CGFloat.greatestFiniteMagnitude
    var westmost = CGFloat.greatestFiniteMagnitude
    for _ in 0..<Int(60 / dt) {
        cat = Cat.step(cat, world: world, dt: dt)
        // Until he leaves the bar, however he leaves it. Threading a jump down through the
        // doorway is legal and is not what this is about.
        guard case .grounded(let p) = cat.support, p.id == .menuBar else { break }
        westmost = min(westmost, cat.position.x)
        if cat.activity == .edgeLook { lookedNear = min(lookedNear, cat.position.x) }
    }
    #expect(westmost >= notch.maxX, "he stood in the cutout at x=\(Int(westmost))")
    #expect(lookedNear < .greatestFiniteMagnitude, "he never looked at anything")
    #expect(lookedNear > notch.maxX + Feel.Physics.edgeApproach,
            "he put his head over the cutout at x=\(Int(lookedNear))")
}

@MainActor
@Test func theLookPlaysTheWholeLookDownSheetAndThenHolds() {
    // Checked frame by frame because the alternative is watching it. A non-looping clip handed
    // a stale clock renders its last frame immediately, which is how `sitdown` and `curl` both
    // shipped having never once played: here that would mean he is already leaning over the
    // edge on the tick he arrives at it, and the lean is the tell.
    let world = ledgeWorld()
    var cat = steppingOff()
    var indices: [Int] = []
    var clips: Set<Sprites.Clip> = []
    for _ in 0..<1800 {
        cat = Cat.step(cat, world: world, dt: dt)
        guard cat.activity == .edgeLook else {
            if !indices.isEmpty { break }       // the first look only
            continue
        }
        let f = Sprites.frame(for: cat, pose: Body.Pose())
        clips.insert(f.clip)
        indices.append(f.index)
    }
    #expect(clips == [.lookDown])
    #expect(indices.first == 0, "he snapped straight to a leaning frame")
    #expect(indices.last == Sprites.Clip.lookDown.count - 1, "the sheet never reached the hold")
    #expect(indices == indices.sorted(), "the frames played out of order")
}

@Test func heSlowsDownOnTheApproachInsteadOfArrivingAtAWalk() {
    // The "slows" beat. It has to be its own thing: the walk's braking acts only inside
    // `brakingDistance` of its mark, and he plants before ever getting there, so with the walk
    // alone he holds a flat `walkSpeed` from wherever he set off right up to the lip and then
    // stops dead in one tick. Two beats collapsed into one, and invisible on screen.
    let world = ledgeWorld()
    var cat = steppingOff()          // 700, lip at 900

    var speeds: [CGFloat] = []
    for _ in 0..<1800 {
        cat = Cat.step(cat, world: world, dt: dt)
        if cat.activity == .edgeLook { break }
        speeds.append(abs(cat.perchSpeed))
    }
    guard let top = speeds.max(), cat.activity == .edgeLook else {
        Issue.record("he never reached the lip; nothing here was measured")
        return
    }
    #expect(top > Feel.Physics.walkSpeed * 0.9, "he never got up to a walk at all")
    // From the fastest tick onward he only ever slows. Not strictly, because he holds his top
    // speed for the stretch before the ease begins.
    let ramp = speeds.drop(while: { $0 < top })
    #expect(zip(ramp, ramp.dropFirst()).allSatisfy { $0 >= $1 },
            "he speeds back up on the way in: \(Array(ramp.suffix(12)))")
    // ...and it is a real slowdown, not one tick of it. He arrives at a creep.
    #expect(speeds.last! < Feel.Physics.walkSpeed * 0.5,
            "he arrived at the lip doing \(speeds.last!) of \(Feel.Physics.walkSpeed)")
    // ...and the ease is the part BELOW his cruising speed. Counting the whole tail counts the
    // cruise, which on this ledge is 500 ticks of it, so a single tick stepping straight down
    // to the creep would have passed.
    let easing = ramp.filter { $0 < top - 0.5 }
    #expect(easing.count > 60, "the ease lasted \(easing.count) ticks; that is not a beat")
}

@MainActor
@Test func theLeanAlwaysFinishesBeforeHeCanCommit() {
    // A non-looping clip holds its last frame, so the lean is only ever *seen* if the shortest
    // hold outlasts the sheet. Derived from the clip so it tracks a change to either number.
    let clip = Sprites.Clip.lookDown
    let toHeldFrame = Double(clip.count - 1) / clip.fps
    #expect(Cat.hesitation(forDrop: 0) >= toHeldFrame,
            "the shortest look is \(Cat.hesitation(forDrop: 0))s and the lean takes \(toHeldFrame)s")
}

@MainActor
@Test func aLongApproachToALipStillTrots() {
    // The ease must not clip the trot. `Sprites.clip` picks the run sheet off `hurrying`, so a
    // ceiling that holds him at a walk while he is still hurrying plays the run frames at
    // walking speed — a moonwalk, and the same gait desync `strideLength` exists to prevent.
    let world = ledgeWorld()
    var cat = CatState(position: CGPoint(x: 410, y: 600))   // 490pt of ledge before the lip
    cat.support = .grounded(Perch(id: .window(1), dx: 10))
    cat.facing = 1
    cat.intent = Intent(destination: .floor, destinationX: 1200, move: .stepOff)

    var topWhileHurrying: CGFloat = 0
    var clipsWhileHurrying: Set<Sprites.Clip> = []
    var slowestAfterHurrying = CGFloat.greatestFiniteMagnitude
    for _ in 0..<1800 {
        cat = Cat.step(cat, world: world, dt: dt)
        if cat.activity == .edgeLook { break }
        if cat.hurrying {
            topWhileHurrying = max(topWhileHurrying, abs(cat.perchSpeed))
            clipsWhileHurrying.insert(Sprites.clip(for: cat.activity, dangling: false,
                                                   hurrying: cat.hurrying))
        } else if topWhileHurrying > 0 {
            slowestAfterHurrying = min(slowestAfterHurrying, abs(cat.perchSpeed))
        }
    }
    #expect(cat.activity == .edgeLook, "he never got to the lip")
    #expect(clipsWhileHurrying == [.run], "half a ledge and he never trotted")
    #expect(topWhileHurrying > Feel.Physics.runSpeed * 0.9,
            "he played the run frames at \(topWhileHurrying) px/s against a run of \(Feel.Physics.runSpeed)")
    // ...and he still arrives at a creep, so the trot is restored without losing the ease.
    #expect(slowestAfterHurrying < Feel.Physics.edgeCreepSpeed * 1.5,
            "he stopped easing: slowest after the trot was \(slowestAfterHurrying)")
}
