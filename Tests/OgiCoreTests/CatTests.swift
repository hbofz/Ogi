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

@Test func heCannotFallOutOfTheBottomOfTheWorld() {
    // Grab him, drag over the Dock strip, let go: the cursor can sit BELOW the floor line
    // (the floor is the top of a pinned Dock), so the fall starts beneath the lowest surface.
    // `supportBelow` only ever searches downward, so nothing can catch a fall that starts
    // under everything — he leaves the world for the session with the display link pinned,
    // which is the same fatal exit as the sides.
    let world = sky([surface(.floor, y: 100, from: 0, to: 1920, z: .max)])
    var cat = Cat.release(CatState(position: CGPoint(x: 500, y: 40)),
                          throwVelocity: .zero, world: world)

    for _ in 0..<600 {
        cat = Cat.step(cat, world: world, dt: dt)
        if case .grounded = cat.support { break }
    }

    guard case .grounded(let perch) = cat.support else {
        Issue.record("fell out of the world, still at y=\(Int(cat.position.y))")
        return
    }
    #expect(perch.id == .floor)
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
    #expect(cat.footing.isCliff)
    #expect(cat.footing.edgeAhead > Feel.Physics.edgeApproach, "50 is not at the edge")
    let s = world.surface(.window(1))!
    #expect(Cat.landing(past: 900, facing: 1, on: s, world: world)?.id == .floor)
    #expect(!Cat.isGap(at: 900, facing: 1, on: s))
}

@Test func footingReportsNoDropAtAWall() {
    let world = ledgeWorld()
    var cat = CatState(position: CGPoint(x: 20, y: 100))
    cat.support = .grounded(Perch(id: .floor, dx: 20))
    cat.facing = -1

    cat = Cat.step(cat, world: world, dt: dt)

    #expect(cat.footing.dropAhead == nil)             // wall, nothing below the floor
    #expect(!cat.footing.isCliff)
    #expect(cat.footing.edgeAhead <= Feel.Physics.edgeApproach, "20 is at the edge")
    let floor = world.surface(.floor)!
    #expect(Cat.landing(past: 0, facing: -1, on: floor, world: world) == nil)
    #expect(!Cat.isGap(at: 0, facing: -1, on: floor), "the end of the world is not a hole")
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
    #expect(cat.footing.dropAhead == nil)
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

@Test func heIsNeverDrawnHalfOffThePanel() {
    // He could plant at x=5 on a 1920pt screen. `edgePlant` stops him 6pt back from a lip,
    // which is right at a window's edge and wrong at the display's, because there is nothing
    // behind the display's: a peek over the left edge with only his tail still on the panel.
    let world = World.build(windows: [], screen: notched, ownPID: 99)
    let margin = Feel.Shape.clearance
    for id in [SurfaceID.menuBar, .floor] {
        let s = world.surface(id)!
        #expect(s.solid.allSatisfy { $0.lowerBound >= notched.visibleFrame.minX + margin
                                  && $0.upperBound <= notched.visibleFrame.maxX - margin },
                "\(id) lets him stand where he would be drawn off the panel: \(s.solid)")
        // `extent` is the perch anchor space and must NOT shrink, or every window's
        // surfing offset moves the moment this changes.
        #expect(s.extent.lowerBound == notched.visibleFrame.minX)
        #expect(s.extent.upperBound == notched.visibleFrame.maxX)
    }

    // ...and a fall that sails off the side is caught by the same margin, not by the raw
    // frame. Pinned flush to it he simply lands half off instead of standing half off.
    var thrown = CatState(position: CGPoint(x: 60, y: 900))
    thrown.support = .falling
    thrown.velocity = CGVector(dx: -1500, dy: 0)
    for _ in 0..<Int(3 / dt) { thrown = Cat.step(thrown, world: world, dt: dt) }
    #expect(thrown.position.x >= notched.visibleFrame.minX + margin - 0.01,
            "thrown at the wall he ended at x=\(thrown.position.x), part of him off the panel")
}

@Test func theNotchIsAHoleInEveryLedgeAtThatHeight() {
    // The bar is not the only ledge up there: a fullscreen window's top edge sits exactly ON
    // the bar line and runs the full width, and the covered-screen retreat puts him there, so
    // it is where he lives. Standing under the cutout drew him into a region with no pixels
    // behind it, taking a whole cat down to a sliver of tail.
    let notch = notched.notch!
    let fullscreen = RawWindow(id: 1, pid: 7, layer: 0,
                               rect: CGRect(x: 0, y: 0, width: notched.frame.width,
                                            height: notched.visibleFrame.maxY),
                               alpha: 1, owner: "Google Chrome")
    let top = World.build(windows: [fullscreen], screen: notched, ownPID: 99).surface(.window(1))!
    #expect(top.y == notched.visibleFrame.maxY, "a fullscreen top edge should be the bar line")
    #expect(!top.solid.contains { $0.contains(notch.midX) },
            "he can still stand under the cutout on a fullscreen window's top edge")

    // A ledge nowhere near it keeps its ground: the hole is at the notch's height, not
    // everywhere. Without this the fix would delete a strip out of every window on screen.
    let low = RawWindow(id: 2, pid: 7, layer: 0,
                        rect: CGRect(x: 0, y: 100, width: notched.frame.width, height: 400),
                        alpha: 1, owner: "Terminal")
    let below = World.build(windows: [low], screen: notched, ownPID: 99).surface(.window(2))!
    #expect(below.solid.contains { $0.contains(notch.midX) },
            "a ledge 700pt below the notch lost ground to it")
}

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
        // far side of the cutout instead of idling. Idling is not inert: a deep drop is
        // easier to reach than a shallow one, so left alone he deliberately leaps off the
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
    #expect(!cat.footing.isCliff)
    #expect(Cat.landing(past: notch.maxX, facing: -1, on: bar, world: world) == nil)
    #expect(Cat.isGap(at: notch.maxX, facing: -1, on: bar), "a hole is not the end of the world")
}

@Test func fromTheMenuBarHeDropsOntoTheWindowBelow() {
    // From the bar, every descent walked to a screen corner, because a full-width surface's
    // only lips ARE the corners: stepOff picks the lip nearest the destination, and from the
    // bar that is a thousand-point walk followed by a thousand-point fall into a corner
    // nowhere near where he was going. Windows were never stepping stones on the way down.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    let win1 = surface(.window(1), y: 1110, from: 264, to: 1091)
    let floor = surface(.floor, y: 90, from: 0, to: 1920, z: .max)
    let world = sky([bar, win1, floor])
    var cat = CatState(position: CGPoint(x: 1500, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 1500))

    let move = Cat.nextMove(from: cat, on: bar, toward: .window(1), x: 650, world: world)
    guard case .drop(.window(1), let x)? = move else {
        Issue.record("expected a drop, got \(String(describing: move))")
        return
    }
    #expect(abs(x - 650) < Feel.Physics.edgeApproach + 1)
}

@Test func aWindowLipStillGetsTheTellNotADrop() {
    // The drop must not eat the edge. From a window whose lip actually gains ground, the
    // approach-slow-look-hold beat stays intact.
    let ledge = surface(.window(1), y: 600, from: 400, to: 900)
    let floor = surface(.floor, y: 90, from: 0, to: 1920, z: .max)
    var cat = CatState(position: CGPoint(x: 650, y: 600))
    cat.support = .grounded(Perch(id: .window(1), dx: 250))
    let move = Cat.nextMove(from: cat, on: ledge, toward: .floor, x: 650,
                            world: sky([ledge, floor]))
    if case .drop = move { Issue.record("the drop ate the edge tell") }
}

@Test func heUsesWindowsAsStepsDownFromTheBar() {
    // End to end: walk along the bar to above the window, the look-down tell, the hop, the
    // landing — and never a trip to the screen corner.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    let win1 = surface(.window(1), y: 1110, from: 264, to: 1091,
                       rect: CGRect(x: 264, y: 192, width: 827, height: 918))
    let floor = surface(.floor, y: 90, from: 0, to: 1920, z: .max)
    let world = sky([bar, win1, floor])

    // He can refuse a drop after looking at it (commitChance), which settles the intent, so
    // a few attempts are legitimate; three failures in a row would be a 0.01% draw.
    var landed = false, cornered = false, looked = false
    for _ in 0..<3 {
        var cat = CatState(position: CGPoint(x: 1500, y: 1205))
        cat.support = .grounded(Perch(id: .menuBar, dx: 1500))
        cat.restLeft = .greatestFiniteMagnitude
        guard let move = Cat.nextMove(from: cat, on: bar, toward: .window(1), x: 650,
                                      world: world) else {
            Issue.record("no route from the bar to the window below it"); return
        }
        cat.intent = Intent(destination: .window(1), destinationX: 650, move: move)
        for _ in 0..<Int(60 / dt) {
            cat = Cat.step(cat, world: world, dt: dt)
            looked = looked || cat.activity == .edgeLook
            cornered = cornered || cat.position.x < 150 || cat.position.x > 1770
            if case .grounded(let p) = cat.support, p.id == .window(1) { landed = true; break }
            if cat.intent == nil { break }      // refused after the look; try again
        }
        if landed { break }
    }
    #expect(landed, "he never made it down onto the window")
    #expect(looked, "he dropped without the look-down tell")
    #expect(!cornered, "he walked to a screen corner instead of using the window below")
}

@MainActor
@Test func aNotchlessMacStillHasADoorway() {
    // homeX used to be nil without a notch, so desktop Macs got no fullscreen retreat, no
    // pre-sleep settle, and an instant quit with no goodbye. Home falls back to under his own
    // menu bar item — where you click to quit — and doorway() must hand a mid-run home back
    // untouched rather than "the edge ahead": on an unbroken bar the edge ahead is the screen
    // corner, which is a lip he must not be sent to.
    let world = World.build(windows: [], screen: screen, ownPID: 99)
    let bar = world.surface(.menuBar)!
    #expect(OgiApp.doorway(from: 400, toward: 1700, on: bar) == 1700)
    #expect(OgiApp.doorway(from: 1900, toward: 1700, on: bar) == 1700)
}

@MainActor
@Test func fullscreenSomewhereElseIsNotFullscreenHere() {
    // The raw snapshot is the GLOBAL window list. Judged on a window's own size, a
    // fullscreen video on the external display — or any window merely bigger than his
    // screen, wherever it sits — reads as fullscreen here and sends the laptop cat home.
    let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let his = RawWindow(id: 1, pid: 7, layer: 0, rect: frame, alpha: 1, owner: "Safari")
    let elsewhere = RawWindow(id: 2, pid: 7, layer: 0,
                              rect: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
                              alpha: 1, owner: "Safari")
    let poking = RawWindow(id: 3, pid: 7, layer: 0,
                           rect: CGRect(x: 1500, y: 0, width: 2560, height: 1440),
                           alpha: 1, owner: "Safari")
    let own = RawWindow(id: 4, pid: 99, layer: 0, rect: frame, alpha: 1, owner: "Ogi")

    let g = ScreenGeometry(frame: frame, visibleFrame: frame, notch: nil)
    #expect(OgiApp.somethingFullscreen(in: [his], screen: g, ownPID: 99))
    #expect(!OgiApp.somethingFullscreen(in: [elsewhere], screen: g, ownPID: 99),
            "a fullscreen window on another display sent him home")
    #expect(!OgiApp.somethingFullscreen(in: [poking], screen: g, ownPID: 99),
            "a big window poking 12pt into his screen sent him home")
    #expect(!OgiApp.somethingFullscreen(in: [own], screen: g, ownPID: 99),
            "his own overlay counted as the world being covered")
}

/// The geometry a fullscreen Space actually has, measured on a notched 1920x1243pt display
/// running macOS 26.5.1 while sitting on one.
@MainActor
@Test func aSettledFullscreenSpaceReadsAsCovered() {
    let g = ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1920, height: 1243),
                           visibleFrame: CGRect(x: 0, y: 90, width: 1920, height: 1115),
                           notch: CGRect(x: 856, y: 1206, width: 208, height: 37))

    // A settled fullscreen window is 1920x**1205**: it stops at the menu bar line and leaves
    // the 38pt notch strip bare. That is 96.9% of the frame, so a ">= 98% of the frame" test
    // says NO, and the only thing that ever passed it was the 1920x1243 window macOS shows
    // for ~0.7s during the zoom animation. Which is exactly why *entering* fullscreen worked
    // and swiping to a Space that was already fullscreen did nothing at all.
    let textEdit = [RawWindow(id: 1, pid: 7, layer: 0,
                              rect: CGRect(x: 0, y: 0, width: 1920, height: 1205),
                              alpha: 1, owner: "TextEdit")]
    #expect(OgiApp.somethingFullscreen(in: textEdit, screen: g, ownPID: 99),
            "a fullscreen Space he is standing in did not read as covered")

    // And a fullscreen app is not one big window. Chrome's is four full-width bands, measured
    // on the same display; the tallest is 87% of the screen and no single one is close.
    let chrome = [(0.0, 1083.0), (1083.0, 81.0), (1164.0, 41.0), (1047.0, 158.0)]
        .enumerated().map { i, b in
            RawWindow(id: CGWindowID(10 + i), pid: 8, layer: 0,
                      rect: CGRect(x: 0, y: b.0, width: 1920, height: b.1),
                      alpha: 1, owner: "Google Chrome")
        }
    #expect(OgiApp.somethingFullscreen(in: chrome, screen: g, ownPID: 99),
            "a fullscreen app that splits into bands did not read as covered")

    // A merely maximized window is NOT this, and telling them apart is what the Dock band is
    // for: fullscreen owns it, zoom does not. He still has a bar to walk on and a shelf below.
    let zoomed = [RawWindow(id: 2, pid: 7, layer: 0, rect: g.visibleFrame, alpha: 1, owner: "Safari")]
    #expect(!OgiApp.somethingFullscreen(in: zoomed, screen: g, ownPID: 99),
            "a maximized window sent him home")

    // Nor is a tall window that leaves either side of the screen showing.
    let tall = [RawWindow(id: 3, pid: 7, layer: 0,
                          rect: CGRect(x: 40, y: 0, width: 1840, height: 1243),
                          alpha: 1, owner: "Safari")]
    #expect(!OgiApp.somethingFullscreen(in: tall, screen: g, ownPID: 99),
            "a window with desktop showing either side of it sent him home")
}

@Test func heWaitsInTheDoorwayFacingOut() {
    // The notch is a hardware hole with no pixels behind it, so a cat resting AT its lip
    // half-overlaps the cutout and the mask eats half of him: he disappears. At a den door his
    // waiting pose is the peek instead: hindquarters in the dark, face out, watching the room
    // from inside his den.
    let world = World.build(windows: [], screen: notched, ownPID: 99)
    let bar = world.surface(.menuBar)!
    let notch = notched.notch!
    var cat = CatState(position: CGPoint(x: notch.minX, y: bar.y))
    cat.support = .grounded(Perch(id: .menuBar, dx: notch.minX - bar.extent.lowerBound))
    cat.restLeft = .greatestFiniteMagnitude
    for _ in 0..<(120 * 2) { cat = Cat.step(cat, world: world, dt: dt) }
    #expect(cat.activity == .peek, "at the den door he should wait in the doorway")
    #expect(cat.facing == -1, "at the left lip, out is away from the cutout")
    // Started centred ON the lip, which is where a wall bump and an interrupted launch walk
    // both leave him. He must not settle there: the cutout has no pixels behind it, so half
    // of him would simply not be drawn.
    #expect(cat.position.x <= notch.minX - Feel.Shape.clearance + 0.01,
            "waiting at x=\(cat.position.x) leaves part of him inside the cutout")

    // Mid-bar, resting is just resting: the den pose belongs to the doorway alone.
    var away = CatState(position: CGPoint(x: 300, y: bar.y))
    away.support = .grounded(Perch(id: .menuBar, dx: 300 - bar.extent.lowerBound))
    away.restLeft = .greatestFiniteMagnitude
    for _ in 0..<(120 * 2) { away = Cat.step(away, world: world, dt: dt) }
    #expect(away.activity != .peek, "he peeked at a doorway that is not there")
}

@MainActor
@Test func heWaitsBesideTheHoleAndNotInIt() {
    // The notch has no pixels behind it, so whatever is drawn inside it is gone. Parked
    // centred on the lip, where both retreats send him and where he then stays for as long as
    // the screen is covered, about half of him disappears. Every waiting spot must leave his
    // whole box on lit pixels.
    let notch = notched.notch!
    for lip in [notch.minX, notch.maxX] {
        let x = OgiApp.denX(lip, notch: notch)
        let box = CGRect(x: x - Feel.Shape.width / 2, y: 0, width: Feel.Shape.width, height: 1)
        #expect(!box.intersects(CGRect(x: notch.minX, y: -1, width: notch.width, height: 3)),
                "waiting at \(x) puts part of him inside the cutout")
    }
    // Out of the cutout, not merely somewhere else: each lip pushes away from the hole.
    #expect(OgiApp.denX(notch.minX, notch: notch) < notch.minX)
    #expect(OgiApp.denX(notch.maxX, notch: notch) > notch.maxX)
    // Anywhere that is not a lip is left alone. A notchless Mac's home is under the status
    // item, and nudging that sideways would be 26pt of drift with no hole to explain it.
    #expect(OgiApp.denX(1700, notch: notch) == 1700)
    #expect(OgiApp.denX(1700, notch: nil) == 1700)

    // ...and he must still hold the den pose once he is standing there, or the fix would have
    // deleted the behaviour instead of repairing it.
    let world = World.build(windows: [], screen: notched, ownPID: 99)
    let bar = world.surface(.menuBar)!
    let wait = OgiApp.denX(notch.minX, notch: notch)
    var cat = CatState(position: CGPoint(x: wait, y: bar.y))
    cat.support = .grounded(Perch(id: .menuBar, dx: wait - bar.extent.lowerBound))
    cat.restLeft = .greatestFiniteMagnitude
    for _ in 0..<(120 * 2) { cat = Cat.step(cat, world: world, dt: dt) }
    #expect(cat.activity == .peek, "beside the doorway he stopped reading it as a doorway")
    #expect(cat.facing == -1, "at the left lip, out is away from the cutout")
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
@Test func aSmallerScreenDoesNotStrandHimOutsideIt() {
    // Unplug the 4K and the desktop shrinks under him. Everything he could stand on is now
    // to his left, so he slips off his perch, falls past a floor whose `solid` no longer
    // contains his x, and keeps falling forever somewhere off the side of the screen.
    let small = CGRect(x: 0, y: 90, width: 1440, height: 800)
    var cat = CatState(position: CGPoint(x: 3200, y: 900))
    cat.support = .grounded(Perch(id: .menuBar, dx: 3200))

    let moved = OgiApp.reseat(cat, into: small)
    #expect(moved.position.x < small.maxX && moved.position.x > small.minX,
            "he is still off the side of the new screen")
    guard case .falling = moved.support else {
        Issue.record("he kept a perch that no longer exists under him")
        return
    }

    // ...and he actually lands, rather than falling through a world that has no ground at
    // the x he was teleported to.
    let world = World.build(windows: [], screen: ScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: small, notch: nil),
                            ownPID: 99)
    // Stop at the first landing rather than simulating on: given a few seconds of freedom he
    // goes for a walk, and catching him mid-jump would fail this for the wrong reason.
    var c = moved
    var landed = false
    for _ in 0..<Int(5 / dt) where !landed {
        c = Cat.step(c, world: world, dt: dt)
        if case .grounded = c.support { landed = true }
    }
    #expect(landed, "he never found the ground again, at x=\(Int(c.position.x))")
}

@MainActor
@Test func heIsNotLeftBelowTheBottomOfTheNewDesktop() {
    // The same bug on the other axis, and the nastier one. A built-in display arranged BELOW
    // an external primary has a negative frame origin, so he can be standing at y = -100.
    // Unplug the external and the built-in becomes the primary at (0, 0): his x is fine, so a
    // downward-only clamp leaves him untouched, grounded on a perch that no longer exists.
    // When hysteresis expires it he falls — and `supportBelow` only ever searches DOWNWARD,
    // so the floor above him can never catch him. Terminal velocity, forever.
    let visible = CGRect(x: 0, y: 0, width: 1440, height: 800)
    var cat = CatState(position: CGPoint(x: 700, y: -100))
    cat.support = .grounded(Perch(id: .window(1), dx: 0))

    let moved = OgiApp.reseat(cat, into: visible)
    #expect(moved.position.y >= visible.minY, "he is still below the bottom of the world")

    let world = World.build(windows: [], screen: ScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: visible, notch: nil),
                            ownPID: 99)
    var c = moved
    var landed = false
    for _ in 0..<Int(5 / dt) where !landed {
        c = Cat.step(c, world: world, dt: dt)
        if case .grounded = c.support { landed = true }
    }
    #expect(landed, "he fell out of the bottom of the world, at y=\(Int(c.position.y))")
}

@MainActor
@Test func aScreenChangeLeavesHimAloneIfHeIsStillOnIt() {
    // Reconfiguration fires for a brightness change on an external display too. Dropping him
    // off his perch every time one arrives would be a worse bug than the one being fixed.
    let visible = CGRect(x: 0, y: 90, width: 1920, height: 1115)
    var cat = CatState(position: CGPoint(x: 800, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 800))

    let after = OgiApp.reseat(cat, into: visible)
    #expect(after.position == cat.position)
    guard case .grounded = after.support else {
        Issue.record("he was dropped for no reason")
        return
    }
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
    // overhanging the cutout is masked away by the occlusion machinery that already exists,
    // rather than by drawing a black cat against a black bezel.
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

// MARK: - A bone-rattling drop reads differently from a step down

/// Falls from `h` and returns him on the tick he touches down, plus how long he then spends in
/// whatever landing he ended up in.
private func landing(fromHeight h: CGFloat, routing: Bool = false) -> (Activity, TimeInterval) {
    let ground = surface(.window(1), y: 100, from: 0, to: 500)
    let world = sky([ground])
    var cat = CatState(position: CGPoint(x: 250, y: 100 + h))
    // `routing` is the common case, not the exotic one: the intent survives a fall by design,
    // so anything he lands from mid-route arrives with one.
    if routing {
        cat.intent = Intent(destination: .window(1), destinationX: 450, move: .walk(450))
    }
    cat.restLeft = .greatestFiniteMagnitude       // no new ideas while this is being measured
    while cat.support == .falling { cat = Cat.step(cat, world: world, dt: dt) }
    let landed = cat.activity
    var held: TimeInterval = 0
    while cat.activity == landed, held < 5 {
        cat = Cat.step(cat, world: world, dt: dt)
        held += dt
    }
    return (landed, held)
}

@Test @MainActor func aHardLandingShakesHimOffAndAGentleOneDoesNot() {
    // Before this they were the same picture: `landHard` played the ordinary `land` clip and
    // timed out on the same clock, so a drop off the menu bar and a step down onto the window
    // below it were indistinguishable. The squash depth already differed and nothing else did.
    #expect(Sprites.clip(for: .landHard, dangling: false) == .shake)
    #expect(Sprites.clip(for: .land, dangling: false) == .land)
}

@Test func aHardLandingIsHeldLongerThanAGentleOne() {
    // The other half of the same defect. Both landings used to time out on one 0.35s clock,
    // so even with a different sheet the shake would be cut off part-way through: it does not
    // loop, and a hard landing that ends on the same beat as a step down is not a hard landing.
    let (hardActivity, hardHeld) = landing(fromHeight: 600)
    let (softActivity, softHeld) = landing(fromHeight: 40)

    #expect(hardActivity == .landHard, "a 600pt drop has to be the hard landing")
    #expect(softActivity == .land, "a 40pt step down has to be the ordinary landing")
    #expect(hardHeld > softHeld + 0.05,
            "he shrugs off a \(hardHeld)s bone-rattling drop as fast as a \(softHeld)s step down")
    #expect(hardHeld >= Feel.Timing.landHardSeconds - 2 * dt,
            "he was back to idle after \(hardHeld)s, before the shake had played out")
}

@Test func aLandingHeIsRoutingThroughStillPlaysAllTheWayOut() {
    // The one that matters, and the one the two tests above miss because neither gives him an
    // intent. A landing mid-route was overwritten by the walk on the very NEXT tick: he
    // re-plans on the tick he touches down (that is what makes a fluffed hop a new starting
    // point rather than a dead end), and the walk branch ends by setting `.walk`. Both landing
    // sheets rendered their first frame for 1/120s and were never seen.
    //
    // Not a corner case either way round: he re-plans on every touchdown, so a landing
    // mid-route is how most landings arrive.
    let (hard, hardHeld) = landing(fromHeight: 600, routing: true)
    #expect(hard == .landHard, "a 600pt drop has to be the hard landing")
    #expect(hardHeld >= Feel.Timing.landHardSeconds - 2 * dt,
            "the walk overwrote the shake after \(hardHeld)s")

    let (soft, softHeld) = landing(fromHeight: 40, routing: true)
    #expect(soft == .land, "a 40pt step down has to be the ordinary landing")
    #expect(softHeld >= Feel.Timing.landSeconds - 2 * dt,
            "the walk overwrote the landing after \(softHeld)s")
}

@Test func aLandingDoesNotStrandHimMidRoute() {
    // The other half: a hold that blocks the walk must hand back to it. What ends the hold is
    // the timeout in `step`, which runs after `ground` and is gated on nothing.
    let ground = surface(.window(1), y: 100, from: 0, to: 500)
    let world = sky([ground])
    var cat = CatState(position: CGPoint(x: 250, y: 700))
    cat.intent = Intent(destination: .window(1), destinationX: 450, move: .walk(450))
    cat.restLeft = .greatestFiniteMagnitude

    for _ in 0..<Int(20 / dt) {
        cat = Cat.step(cat, world: world, dt: dt)
        if cat.intent == nil { break }
    }
    #expect(cat.intent == nil, "he never finished the walk; the landing hold stranded him")
    #expect(abs(cat.position.x - 450) < Feel.Physics.brakingDistance + Feel.Physics.arrivalSlop)
}

@Test func theShakeIsBeyondHisOwnJump() {
    // A landing he could have chosen is not a hard one. His deliberate leaps land at up to
    // jumpImpulse of speed (plus the aim wobble), so a threshold inside that rattles him at
    // the end of his own jumps — which is how the shake became every landing and stopped
    // being a tell. And it must stay under terminal velocity, or no fall could ever qualify.
    #expect(Feel.Physics.hardLanding > Feel.Physics.jumpImpulse * (1 + Feel.Physics.aimError))
    #expect(Feel.Physics.hardLanding < Feel.Physics.terminalVelocity)
}

@Test @MainActor func theEventPerformancesOutlastTheirSheets() {
    // Same floor the stretch, the shake and the peek have: none of these loop, so a hold
    // shorter than the sheet cuts the gag off mid-jolt, the power-down mid-collapse, or
    // the head-tilt mid-tilt.
    let pairs: [(Sprites.Clip, TimeInterval)] = [
        (.zap, Feel.Timing.zapSeconds),
        (.droop, Feel.Timing.droopSeconds),
        (.curious, Feel.Timing.curiousSeconds),
    ]
    for (clip, hold) in pairs {
        #expect(hold > Double(clip.count) / clip.fps,
                "\(clip.rawValue) settles back before its \(clip.count) frames at \(clip.fps)fps have played")
    }
}

@Test func aLoungingCatIsStillZapped() {
    // The show interrupts the in-place performances rather than queueing behind them: owed
    // consumption below the hold block makes a plug-in during a lounge play up to a whole
    // spell late.
    let floor = surface(.floor, y: 90, from: 0, to: 1920, z: .max)
    var cat = CatState(position: CGPoint(x: 900, y: 90))
    cat.support = .grounded(Perch(id: .floor, dx: 900))
    cat.activity = .lounge
    cat.activityElapsed = 2
    cat.owed = .zap
    cat = Cat.step(cat, world: sky([floor]), dt: dt)
    #expect(cat.activity == .zap, "the jolt queued behind the lounge")
}

@Test func aWindowOpeningDoesNotStompTheShow() {
    // Plugging the charger makes macOS flash a transient charging window, and the glance's
    // perk overwrote .zap with .alert on the next poll, so the zap died in under a second on
    // screen however long its buzz was. A roused cat could also abandon the show for an
    // investigation trip. He still glances (eyes and arousal are the cheap half) but the pose
    // belongs to the show until it ends.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    let win1 = surface(.window(1), y: 900, from: 300, to: 800)
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 900))
    cat.restLeft = .greatestFiniteMagnitude
    cat.activity = .zap
    cat.activityElapsed = 0.3
    cat.arousal = 1
    cat.stimulus = Stimulus(kind: .windowOpened, at: CGPoint(x: 550, y: 900))
    cat = Cat.step(cat, world: sky([bar, win1]), dt: dt)
    #expect(cat.activity == .zap, "a transient window stomped the show")
    #expect(cat.lookingAt != nil, "he should still glance")
    #expect(cat.intent == nil, "roused, he abandoned the show for a trip")
}

@Test func aShowRendersLive() {
    // The zap's tremble at a settled cat's 8-12Hz render rate is a slideshow.
    var cat = CatState(position: .zero)
    cat.support = .grounded(Perch(id: .floor, dx: 0))
    cat.activity = .zap
    #expect(cat.isMoving, "shows must hold the display link at full rate")
}

@Test func aSecondShowQueuesBehindTheFirst() {
    // One slot, no stomping: a second event mid-show waits for the first to finish.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 900))
    cat.restLeft = .greatestFiniteMagnitude
    cat.activity = .zap
    cat.activityElapsed = 0.3
    cat.owed = .curious
    cat = Cat.step(cat, world: sky([bar]), dt: dt)
    #expect(cat.activity == .zap, "the queued show stomped the running one")
    #expect(cat.owed == .curious, "the queued show was dropped instead of waiting")
}

@Test @MainActor func theBuzzLoopsBeforeTheRecovery() {
    let fps = Sprites.Clip.zap.fps
    let oneCycle = 3.0 / fps
    // One full cycle in, the buzz is back on its first frame, not marching to the end.
    #expect(Sprites.index(.zap, activity: .zap, walkPhase: 0, elapsed: oneCycle + 0.001) == 0)
    // The buzz has room for at least two full passes.
    #expect(Feel.Timing.zapBuzzSeconds >= 2 * oneCycle)
    // After the buzz the recovery marches to the settled last frame and holds there.
    #expect(Sprites.index(.zap, activity: .zap, walkPhase: 0,
                          elapsed: Feel.Timing.zapBuzzSeconds + 10) == Sprites.Clip.zap.count - 1)
    // And the whole show outlasts buzz plus recovery, or the pleased finish is cut off.
    #expect(Feel.Timing.zapSeconds > Feel.Timing.zapBuzzSeconds + 2.0 / fps)
}

@Test func anOwedShowPlaysItsWholeSpell() {
    // The generic slot, exercised with the zap: consumed once, held for its spell, settled.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 900))
    cat.restLeft = .greatestFiniteMagnitude
    cat.owed = .zap
    cat = Cat.step(cat, world: sky([bar]), dt: dt)
    #expect(cat.activity == .zap)
    // Half the spell in, still performing.
    for _ in 0..<Int(Feel.Timing.zapSeconds / 2 / dt) {
        cat = Cat.step(cat, world: sky([bar]), dt: dt)
    }
    #expect(cat.activity == .zap, "the jolt was cut short")
    // Past the end, settled.
    for _ in 0..<Int(Feel.Timing.zapSeconds / dt) {
        cat = Cat.step(cat, world: sky([bar]), dt: dt)
    }
    #expect(cat.activity != .zap, "the jolt never ends")
}

@Test @MainActor func theStretchOutlastsItsOwnSheet() {
    // Same floor the shake and the peek have: the clip does not loop, so a timeout shorter
    // than the sheet cuts the yawn off mid-gape and snaps him to standing.
    let clip = Sprites.Clip.stretch
    #expect(Feel.Timing.stretchSeconds > Double(clip.count) / clip.fps,
            "he returns to idle before the stretch's \(clip.count) frames at \(clip.fps)fps have played")
}

@Test @MainActor func theShakeOutlastsItsOwnSheet() {
    // The floor `peekSeconds` and `edgeHesitationMin` both have, for the same reason: the clip
    // does not loop, so a timeout shorter than the sheet cuts him off mid-shudder and snaps him
    // upright with his fur still on end. Strictly longer, because the last frame is him
    // settling back to normal and the remainder is spent holding it, which is the pose idle
    // picks up from.
    let clip = Sprites.Clip.shake
    #expect(Feel.Timing.landHardSeconds > Double(clip.count) / clip.fps,
            "he returns to idle before the shake's \(clip.count) frames at \(clip.fps)fps have played")
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
    // An occasional in-place behaviour while awake. The failure this
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

@Test func droppedFastOnAWindowFaceHeStillClingsToIt() {
    // The bug: a drag that was still moving when you let go sailed past the face. Real drags
    // are never still (20pt in the ~100ms velocity window is already 200 px/s), so the old
    // speed guard meant only a dead stop ever grabbed. Inside the face is inside the face.
    let world = ledgeWorld()          // window(1) rect is x 400...900, y 300...600
    var cat = CatState(position: CGPoint(x: 650, y: 420))
    cat = Cat.grab(cat, at: CGPoint(x: 650, y: 420))
    cat = Cat.release(cat, throwVelocity: CGVector(dx: 900, dy: -900), world: world)

    guard case .clinging(let g) = cat.support else {
        Issue.record("expected clinging, got \(cat.support)")
        return
    }
    #expect(g.id == .window(1))
    #expect(cat.activity == .cling)
    #expect(cat.velocity == .zero, "he caught the face, he is not still travelling")
}

@Test func thrownJustAsFastInOpenAirHeStillFallsAndRights() {
    // The other half: nothing about deleting the guard touches a throw that misses everything.
    let world = ledgeWorld()
    var cat = CatState(position: CGPoint(x: 1500, y: 800))
    cat = Cat.grab(cat, at: CGPoint(x: 1500, y: 800))
    cat = Cat.release(cat, throwVelocity: CGVector(dx: 900, dy: -900), world: world)

    guard case .falling = cat.support else {
        Issue.record("expected falling, got \(cat.support)")
        return
    }
    #expect(cat.activity == .righting)
    #expect(cat.righting == 0)
    #expect(cat.velocity == CGVector(dx: 900, dy: -900))

    cat = Cat.release(Cat.grab(cat, at: CGPoint(x: 1500, y: 800)),
                      throwVelocity: CGVector(dx: 99_000, dy: -99_000), world: world)
    #expect(abs(cat.velocity.dx) <= Feel.Physics.maxThrow)
    #expect(abs(cat.velocity.dy) <= Feel.Physics.maxThrow)
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

@Test func aDescendingPassCannotGrabEvenWhileHeMeansToClimb() {
    // The same fall, with a live climb intent naming the very window he is passing. This is
    // the load-bearing half of why the climb grab is safe to add at all: it is gated on
    // `velocity.dy > 0`, and a fall is always descending. Nothing about wanting to climb
    // a window can turn a descent past it into a grab.
    let world = ledgeWorld()
    var cat = CatState(position: CGPoint(x: 300, y: 560))
    cat.support = .falling
    cat.velocity = CGVector(dx: 260, dy: 0)
    cat.intent = Intent(destination: .window(1), destinationX: 650,
                        move: .climb(.window(1), 650))

    var crossedTheFace = false
    for _ in 0..<1200 {
        cat = Cat.step(cat, world: world, dt: 1.0 / 120)
        if world.faceContaining(cat.position) != nil { crossedTheFace = true }
        if case .clinging = cat.support {
            Issue.record("a descent grabbed the face at \(cat.position)")
            return
        }
        if case .grounded = cat.support { break }
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

/// A real skyline with one window on it, built through `World.build` rather than hand-stubbed,
/// because the property under test IS what `carve` does to the floor's `spans`.
private func desktop(with w: CGRect) -> Skyline {
    World.build(windows: [RawWindow(id: 1, pid: 2, layer: 0, rect: w, alpha: 1, owner: "Safari")],
                screen: screen, ownPID: 99)
}

@Test func heClimbsRatherThanSlidingSomewhereHeCannotBeSeen() {
    // Held over a fullscreen window and let go, he slid down its face and dropped to the
    // desktop BEHIND it, where he cannot be seen.
    //
    // The rule needs no fullscreen check. `spans` is exactly "where he is visible" — `solid`
    // minus everything in front — so the question is only ever whether the spot he would land
    // on has a span at his x.
    func gripped(_ world: Skyline, dy: CGFloat) -> CatState {
        let face = world.surface(.window(1))!
        var cat = CatState(position: CGPoint(x: 900, y: face.y - dy))
        cat.support = .clinging(Grip(id: .window(1), dx: 900 - face.rect!.minX, dy: dy))
        return cat
    }

    // Fullscreen: its bottom edge sits ON the floor, so the floor is carved away entirely.
    let full = desktop(with: CGRect(x: 0, y: 90, width: 1920, height: 1115))
    #expect(full.surface(.floor)?.spans.isEmpty == true, "the floor is still visible; fixture is wrong")
    var cat = gripped(full, dy: 505)          // far past mantleReach: today he slides
    for _ in 0..<(120 * 30) {
        cat = Cat.step(cat, world: full, dt: dt)
        if case .grounded = cat.support { break }
    }
    guard case .grounded(let p) = cat.support else {
        Issue.record("he slid into somewhere invisible instead of climbing, got \(cat.support)")
        return
    }
    #expect(p.id == .window(1))
    #expect(abs(cat.position.y - 1205) < 0.001, "he did not mantle onto the top edge")

    // The same window lifted off the desktop. Now the floor below him IS visible, so the slide
    // is still the right answer — a cat slipping down a curtain is the behaviour that earned
    // the sheet, and this is what stops the new rule from eating it.
    let floating = desktop(with: CGRect(x: 0, y: 300, width: 1920, height: 900))
    #expect(floating.surface(.floor)?.spans.isEmpty == false, "the floor vanished; fixture is wrong")
    var slider = gripped(floating, dy: 505)
    for _ in 0..<(120 * 30) {
        slider = Cat.step(slider, world: floating, dt: dt)
        if case .falling = slider.support { break }
    }
    guard case .falling = slider.support else {
        Issue.record("he climbed a face he should have slid down, got \(slider.support)")
        return
    }
    #expect(slider.position.y < 1200 - 505, "he let go without ever sliding down")
}

@Test func aWindowInFrontOfTheFaceCannotTrapHimSawingAtIt() {
    // The slide does not release him where he is hanging. It carries him to the BOTTOM of the
    // face and lets go there, straight past anything in between, because a clinging cat is
    // never tested against the ground. So "where would letting go put him" has to be asked
    // about the bottom of the face — and asking it at his live grip point instead is not
    // merely imprecise, it OSCILLATES: the answer flips at every intervening window's top
    // edge, and the two branches move him in opposite directions across it.
    //
    // A maximized window with its bottom edge on the floor (so the floor is carved away at
    // every x), and a smaller one in front of it. Above the small window's top edge, letting
    // go looks like it would land him on something visible; below it, on the invisible floor.
    // He saws back and forth across y = 700 for ever inside a one-point band — and `.clinging`
    // means `isMoving`, so `enterSlumber` becomes unreachable and the display link is pinned at
    // 60Hz for the rest of the session. Exactly what the comment on `isMoving` promises cannot
    // happen.
    let world = World.build(
        windows: [RawWindow(id: 1, pid: 2, layer: 0,
                            rect: CGRect(x: 700, y: 400, width: 500, height: 300),
                            alpha: 1, owner: "Front"),
                  RawWindow(id: 2, pid: 2, layer: 0,
                            rect: CGRect(x: 0, y: 90, width: 1920, height: 1115),
                            alpha: 1, owner: "Maximized")],
        screen: screen, ownPID: 99)
    #expect(world.surface(.floor)?.spans.isEmpty == true,
            "fixture: the floor is still visible, so there is nothing to flip against")
    #expect(world.surface(.window(1))?.spans.first?.contains(950) == true,
            "fixture: the window in front is not visible at his x, so there is no flip")

    // On the maximized window's face at x=950, a hundred points above the other's top edge and
    // far past `mantleReach`. No intent: this is a release, not a deliberate climb.
    var cat = CatState(position: CGPoint(x: 950, y: 800))
    cat.support = .clinging(Grip(id: .window(2), dx: 950, dy: 405))

    for _ in 0..<(120 * 30) {
        cat = Cat.step(cat, world: world, dt: dt)
        if case .clinging = cat.support { continue }
        break
    }
    guard case .grounded(let p) = cat.support else {
        Issue.record("he never got off the face in 30s, got \(cat.support)")
        return
    }
    #expect(p.id == .window(2), "he mantled onto the wrong thing")
    #expect(abs(cat.position.y - 1205) < 0.001)
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
    // Stopped short of the lip at 900, on the ledge, not hanging over it — and stopped where
    // `edgePlant` says, which is the tick the plant intercepts on.
    let plant = 900 - Feel.Physics.edgePlant
    #expect(lookedAt < 900 && abs(lookedAt - plant) < Feel.Physics.arrivalSlop,
            "he looked from x=\(lookedAt); the lip is at 900 and he should plant at \(plant)")
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
    // 400 seconds each: an approach is a slow one (see `edgeEase`), a refusal costs a retreat,
    // a rest and a fresh idea, and that fresh idea is usually a 45-second lounge, which is the
    // election working as designed. On a fixture this bare the lounge wins most draws, so a
    // second look at the lip needs several election cycles to appear. At 180s, zero second
    // looks across forty trials is a 3% draw. A trial where he only ever looked once measures
    // nothing at all, hence the refusal count below, which cannot pass vacuously.
    let world = ledgeWorld()
    var looks = 0, refusals = 0, left = 0
    var tightest = TimeInterval.infinity, closest: CGFloat = 0
    for _ in 0..<40 {
        var cat = steppingOff()
        var wasLooking = false, sinceLook = TimeInterval.infinity
        for _ in 0..<Int(400 / dt) {
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
    // `.onCall` and not `.alert`: a live mic is a call and he joins it, wearing the boom mic.
    // The freeze still interrupts the edge tell, and the trip below still survives it.
    #expect(cat.activity == .onCall)
    // The trip SURVIVES the freeze: clearing the intent here is exactly what destroyed the walk
    // out of the notch when the app launched during a call.
    #expect(cat.intent != nil, "the freeze ate his trip again")

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
        // The cutout is a tunnel, so being inside it is not forbidden outright, but it is only
        // ever legal as a CROSSING. Wandering in, hesitating at it, or coming to rest in it are
        // all the trap this test guards, and `insideNotch` is exactly the difference. Sampled
        // rather than asserted so the failure names the x.
        if !cat.insideNotch { westmost = min(westmost, cat.position.x) }
        if cat.activity == .edgeLook { lookedNear = min(lookedNear, cat.position.x) }
    }
    #expect(westmost >= notch.maxX,
            "he stood in the cutout at x=\(Int(westmost)) without crossing it")
    #expect(lookedNear < .greatestFiniteMagnitude, "he never looked at anything")
    #expect(lookedNear > notch.maxX + Feel.Physics.edgeApproach,
            "he put his head over the cutout at x=\(Int(lookedNear))")
}

@MainActor
@Test func theLookPlaysTheWholeLookDownSheetAndThenHolds() {
    // Checked frame by frame because the alternative is watching it. A non-looping clip handed
    // a stale clock renders its last frame immediately: here that would mean he is already
    // leaning over the edge on the tick he arrives at it, and the lean is the tell.
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

/// Where the held `lookDown` frame reaches, in drawn points forward of the spot he stands on.
///
/// The sheets are cropped tight sideways and drawn on a ground line, so whatever touches the
/// bottom rows is what he is standing on: reading left to right that is his hind paw, his front
/// paw, then his lowered chin and whiskers, which in this pose are also on the floor. Measured
/// rather than written down because it is a property of the art and it can move.
@MainActor
private func lookDownReach() -> (toes: CGFloat, nose: CGFloat) {
    let clip = Sprites.Clip.lookDown, held = clip.count - 1
    guard let img = Sprites.image(clip, held) else { return (0, 0) }
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    px.withUnsafeMutableBytes { buf in
        CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
            .draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    func opaque(_ x: Int, _ y: Int) -> Bool { px[(y * w + x) * 4 + 3] > 128 }

    var floor = 0, inkRight = 0
    for y in 0..<h { for x in 0..<w where opaque(x, y) { floor = max(floor, y); inkRight = max(inkRight, x) } }
    // Contact runs along the bottom few rows, merged across gaps narrower than a toe.
    var runs: [(lo: Int, hi: Int)] = []
    for x in 0..<w where (max(0, floor - 7)...floor).contains(where: { opaque(x, $0) }) {
        if var last = runs.last, x <= last.hi + 4 { last.hi = x; runs[runs.count - 1] = last }
        else { runs.append((x, x)) }
    }
    let size = Sprites.size(clip, held)
    let px2pt = size.width / CGFloat(w)
    let frontPaw = runs.count > 1 ? runs[1].hi : inkRight
    return (CGFloat(frontPaw + 1) * px2pt - size.width / 2,
            CGFloat(inkRight + 1) * px2pt - size.width / 2)
}

@MainActor
@Test func hePlantsWithHisPawsOnTheLedgeAndHisHeadOverTheLip() {
    // He used to stop 30pt back from a lip, which on the held `lookDown` frame — 23pt of cat,
    // all of it behind him — left an 18pt gap of bare ledge between his nose and the drop. He
    // read as looking at the floor near the edge rather than over it.
    //
    // The two ends of the right answer both come off the art: near enough that his lowered head
    // clears the lip, far enough back that his front paws still have ledge under them.
    let (toes, nose) = lookDownReach()
    #expect(Feel.Physics.edgePlant < nose,
            "planted \(Feel.Physics.edgePlant)pt back his head stops \(nose - Feel.Physics.edgePlant)pt short of the lip")
    #expect(Feel.Physics.edgePlant > toes,
            "planted \(Feel.Physics.edgePlant)pt back his front paws are \(toes - Feel.Physics.edgePlant)pt past the lip, on nothing")
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

@MainActor
@Test func goingUpAFacePlaysTheClimbSheetAndHangingOnDoesNot() {
    // The whole reason the sheet exists. `cling` was drawn as a moment, a cat scrabbling with
    // its ears back, and a full ascent of a fullscreen face ran it unbroken for up to 10.8s.
    // The hold before he decides has to stay on `cling`, which is exactly what it is for.
    let world = ledgeWorld()          // window(1) face runs x 400...900, y 300...600
    var cat = CatState(position: CGPoint(x: 650, y: 560))
    cat.support = .clinging(Grip(id: .window(1), dx: 250, dy: 40))
    cat.intent = Intent(destination: .window(1), destinationX: 650, move: .climb(.window(1), 650))

    var sawCling = false, sawClimb = false
    for _ in 0..<(120 * 20) {
        cat = Cat.step(cat, world: world, dt: dt)
        if cat.activity == .cling { sawCling = true }
        if cat.activity == .climb { sawClimb = true }
        if case .grounded = cat.support { break }
    }
    #expect(sawCling, "he never played the grab-and-hold beat")
    #expect(sawClimb, "he climbed the whole face on the sheet drawn for hanging on")
    #expect(Sprites.clip(for: .climb, dangling: false) == .climbUp)
    #expect(Sprites.clip(for: .cling, dangling: false) == .cling)
}
