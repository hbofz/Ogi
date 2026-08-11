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

private func surface(_ id: SurfaceID, y: CGFloat, from: CGFloat, to: CGFloat, z: Int = 0) -> Surface {
    Surface(id: id, z: z, y: y, extent: from...to,
            solid: [from...to], spans: [from...to], targetable: true, rect: nil)
}

private let dt = Feel.Timing.fixedDT

/// Parked on a wide surface with an explicit intent, so nothing is left to chance.
private func standing(at x: CGFloat, on s: Surface) -> CatState {
    var cat = CatState(position: CGPoint(x: x, y: s.y))
    cat.support = .grounded(Perch(id: s.id, dx: x - s.extent.lowerBound))
    cat.restLeft = .greatestFiniteMagnitude   // never invents its own plans mid-test
    return cat
}

/// A single hop on the surface he is already standing on.
private func strolling(to x: CGFloat, on s: Surface) -> Intent {
    Intent(destination: s.id, destinationX: x, move: .walk(x))
}

@Test func heWalksToHisDestinationAndStops() {
    let ledge = surface(.window(1), y: 500, from: 0, to: 800)
    var cat = standing(at: 100, on: ledge)
    cat.intent = strolling(to: 400, on: ledge)

    for _ in 0..<Int(20 / dt) {
        cat = Cat.step(cat, world: sky([ledge]), dt: dt)
        if cat.intent == nil { break }
    }
    // He does not stop dead on the mark: he brakes late and coasts a few points past it, so
    // this bound is `brakingDistance` plus the slop rather than the slop alone. It and its twin
    // in `heStridesOverACrackRatherThanLeapingIt` are the real ceiling on how big the overshoot
    // is allowed to get, tighter than anything in the overshoot tests themselves.
    #expect(abs(cat.position.x - 400) < Feel.Physics.brakingDistance + Feel.Physics.arrivalSlop)
    #expect(cat.activity == .idle, "he should settle once he arrives")
}

// MARK: - Weight in the walk

/// One wide ledge with nothing under either end, so an overshoot cannot quietly become a fall
/// and confuse the thing being measured.
private func ledgeWorld() -> Skyline {
    sky([surface(.window(1), y: 600, from: 400, to: 900)])
}

@Test func heCoastsPastHisMarkInsteadOfStoppingDeadOnIt() {
    // What this checks is that he PASSES his mark and stops near it, which is not the same
    // claim as "settles back". He does not walk back, deliberately, and this
    // test cannot tell the difference: at a 3pt overshoot the third expectation below passes
    // identically whether a settle-back exists or not. Naming it after one would be how a
    // behaviour gets marked done on a green run without ever having been built.
    //
    // Why it is unbuilt: a walk back only happens if the overshoot exceeds `advance`'s
    // arrival tolerance, and the window where that is stable is
    //     max(arrivalSlop * 3, brakingDistance) < overshoot < brakingDistance + walkSpeed² / (2 * accel)
    // At or below `brakingDistance` he cannot move on the return leg at all and deadlocks;
    // above the ceiling the return leg reaches full speed and overshoots by exactly as much
    // again, for ever. That ceiling is 4.81pt wide at ANY tuning, because the width is
    // walkSpeed² / (2 * accel) and nothing else. Too narrow to ship. Widening it properly
    // means tapering the approach speed rather than braking at a fixed distance.
    let world = ledgeWorld()          // ledge 400...900 at y=600
    var cat = CatState(position: CGPoint(x: 450, y: 600))
    cat.support = .grounded(Perch(id: .window(1), dx: 50))
    cat.intent = Intent(destination: .window(1), destinationX: 700, move: .walk(700))

    var maxX: CGFloat = 0
    for _ in 0..<1200 {
        cat = Cat.step(cat, world: world, dt: 1.0 / 120)
        maxX = max(maxX, cat.position.x)
        if cat.intent == nil { break }
    }
    #expect(maxX > 700)                            // he went past it
    #expect(maxX < 700 + 20)                       // but not far past it
    #expect(abs(cat.position.x - 700) < 12)        // and stopped near it
}

@Test func heAcceleratesRatherThanStartingAtFullSpeed() {
    let world = ledgeWorld()
    var cat = CatState(position: CGPoint(x: 450, y: 600))
    cat.support = .grounded(Perch(id: .window(1), dx: 50))
    // 210pt, so he is inside `hurryDistance` and strolling. Aimed at 850 instead it measures
    // the RUN speed, which is 2.5x the bound below and stays green with no ramp on the walk
    // at all.
    cat.intent = Intent(destination: .window(1), destinationX: 660, move: .walk(660))

    cat = Cat.step(cat, world: world, dt: 1.0 / 120)
    let early = abs(cat.perchSpeed)
    for _ in 0..<120 { cat = Cat.step(cat, world: world, dt: 1.0 / 120) }
    let later = abs(cat.perchSpeed)

    #expect(!cat.hurrying, "he is trotting, so this is measuring the wrong top speed")
    #expect(early < Feel.Physics.walkSpeed * 0.5)
    #expect(later > Feel.Physics.walkSpeed * 0.8)
    #expect(later <= Feel.Physics.walkSpeed, "he wound up past the speed he was asking for")
}

@Test func heDoesNotCoastOffALipHeWasAimingAt() {
    // The overshoot meets the edge test. `nextMove` aims AT lips on purpose (the launch point
    // for the next hop, the near side of a crack to stride over), so a brake that carries him a
    // few points past his mark carries him off the ledge, and ledge two has the floor a couple
    // of hundred points below it. He has to arrive ON the lip, not past it.
    let world = stairsWorld()
    let ledge = world.surface(.window(2))!          // 500...800 at y=310
    var cat = standing(at: 600, on: ledge)
    cat.intent = Intent(destination: .window(2), destinationX: 800, move: .walk(800))

    for _ in 0..<Int(30 / dt) {
        cat = Cat.step(cat, world: world, dt: dt)
        if cat.intent == nil { break }
    }
    guard case .grounded(let p) = cat.support else {
        Issue.record("he coasted off the lip and fell to \(cat.position)")
        return
    }
    #expect(p.id == .window(2))
    #expect(cat.position.x > 800 - Feel.Physics.brakingDistance && cat.position.x <= 800.001)
}

@Test func heFacesTheDirectionHeWalks() {
    let ledge = surface(.window(1), y: 500, from: 0, to: 800)
    var cat = standing(at: 400, on: ledge)
    cat.intent = strolling(to: 100, on: ledge)
    cat = Cat.step(cat, world: sky([ledge]), dt: dt)
    #expect(cat.facing == -1)

    // Reversing him does not happen on the tick it is asked for: he pivots, which takes the
    // length of the `turn` sheet, and `facing` leads the pivot rather than following it. So the
    // second half of this is a few hundred milliseconds later than the first, and the
    // interesting claim lives in `heTurnsRatherThanFlipping`.
    //
    // Run to the resumed walk rather than for a fixed count. He is ALREADY pivoting when this
    // starts (the step above reversed him too), so a fixed budget has to cover two pivots back
    // to back, and one that covers only one passes by landing on a zero-length second pivot.
    cat.intent = strolling(to: 700, on: ledge)
    for _ in 0..<Int(5 / dt) {
        cat = Cat.step(cat, world: sky([ledge]), dt: dt)
        if cat.activity == .walk { break }
    }
    #expect(cat.facing == 1)
    #expect(cat.activity == .walk, "he is still pivoting; the walk never resumed")
}

@Test func walkingIntoAWallKeepsHimOnTheSurface() {
    // Nothing is below this ledge, so both its ends are walls rather than cliffs: he turns
    // around instead of stepping off, however far out of bounds the destination is, and he
    // stays inside it for the whole half-minute of wandering that follows.
    let ledge = surface(.window(1), y: 500, from: 100, to: 300)
    var cat = standing(at: 200, on: ledge)
    cat.intent = strolling(to: 9999, on: ledge)

    for _ in 0..<Int(30 / dt) { cat = Cat.step(cat, world: sky([ledge]), dt: dt) }
    guard case .grounded(let perch) = cat.support else {
        Issue.record("he walked off a surface he was clamped to")
        return
    }
    #expect(perch.dx <= ledge.extent.length + 0.001)
    #expect(cat.position.x <= 300.001)
}

// MARK: - The turn

/// Standing at 800 facing right with a reason to be at 500, so the very first thing the walk
/// asks of him is to reverse. Nothing under either end of the ledge, so a reversal cannot
/// quietly become a fall and confuse what is being measured.
private func mustReverse() -> (Skyline, CatState) {
    let ledge = surface(.window(1), y: 600, from: 400, to: 900)
    var cat = standing(at: 800, on: ledge)
    cat.facing = 1
    cat.intent = strolling(to: 500, on: ledge)
    return (sky([ledge]), cat)
}

@Test func heTurnsRatherThanFlipping() {
    // An instantaneous mirror of `facing` is one of the top-three tells that something is a
    // sprite rather than an animal. He pivots, and the pivot takes time.
    let (world, start) = mustReverse()
    var cat = start
    var sawTurn = false
    for _ in 0..<600 {
        cat = Cat.step(cat, world: world, dt: dt)
        if cat.activity == .turn { sawTurn = true }
        if cat.facing == -1 && !sawTurn {
            Issue.record("facing flipped without a turn")
            return
        }
        if sawTurn && cat.activity == .walk { break }
    }
    #expect(sawTurn)
}

@Test func thePivotHoldsHimStillForTheWholeClip() {
    let (world, start) = mustReverse()
    var cat = start
    var turning = 0, pivotedAt: CGFloat = 0, movedWhilePivoting: CGFloat = 0
    for _ in 0..<600 {
        cat = Cat.step(cat, world: world, dt: dt)
        if cat.activity == .turn {
            if turning == 0 { pivotedAt = cat.position.x }
            turning += 1
            movedWhilePivoting = max(movedWhilePivoting, abs(cat.position.x - pivotedAt))
        } else if turning > 0 {
            break
        }
    }
    #expect(Double(turning) * dt >= Feel.Timing.turnSeconds - 2 * dt,
            "the pivot was cut short, so the last frames of the sheet never play")
    #expect(movedWhilePivoting < 0.5,
            "he slid \(movedWhilePivoting)pt sideways while pivoting on the spot")
    #expect(cat.facing == -1, "he came out of the pivot facing the way he went in")
}

@Test func aWalkThatReversesStillFinishes() {
    // The deadlock this guards is circular: the turn stops the walk, and the walk is the only
    // thing that ends the turn. Break it either way and he stands there for the session.
    let (world, start) = mustReverse()
    var cat = start
    for _ in 0..<Int(20 / dt) {
        cat = Cat.step(cat, world: world, dt: dt)
        if cat.intent == nil { break }
    }
    #expect(cat.intent == nil, "he never arrived; the pivot deadlocked the walk")
    #expect(abs(cat.position.x - 500) < Feel.Physics.brakingDistance + Feel.Physics.arrivalSlop)
    #expect(cat.facing == -1)
}

@Test func heOnlyPivotsOnceToReverseOnce() {
    // The failure this guards is a pivot that re-triggers itself. The turn zeroes his surface
    // speed, and the walk reads `facing` off that speed, so a rule that flipped him back
    // whenever the speed passed through zero would leave him spinning on the spot for ever.
    let (world, start) = mustReverse()
    var cat = start
    var pivots = 0, wasTurning = false
    for _ in 0..<Int(20 / dt) {
        cat = Cat.step(cat, world: world, dt: dt)
        let turning = cat.activity == .turn
        if turning && !wasTurning { pivots += 1 }
        wasTurning = turning
        if cat.intent == nil { break }
    }
    #expect(pivots == 1, "he pivoted \(pivots) times to reverse direction once")
}

@Test func aWalkTheWayHeAlreadyFacesDoesNotPivot() {
    // A facing SET is not a facing change. Firing on every assignment rather than on a genuine
    // reversal would put a third of a second of pivot in front of every walk he ever takes.
    let ledge = surface(.window(1), y: 600, from: 400, to: 900)
    var cat = standing(at: 500, on: ledge)
    cat.facing = 1
    cat.intent = strolling(to: 800, on: ledge)

    var pivoted = false
    for _ in 0..<Int(20 / dt) {
        cat = Cat.step(cat, world: sky([ledge]), dt: dt)
        if cat.activity == .turn { pivoted = true }
        if cat.intent == nil { break }
    }
    #expect(!pivoted, "he pivoted to face the way he was already facing")
}

@Test func heDoesNotPivotInMidAir() {
    // `release` sets `facing` from the throw, and there is nothing under his paws to pivot on.
    // The fall sheet is the righting reflex and it already carries the reversal.
    let ledge = surface(.window(1), y: 600, from: 400, to: 900)
    var cat = standing(at: 700, on: ledge)
    cat.facing = 1
    cat = Cat.grab(cat, at: CGPoint(x: 700, y: 900))
    cat = Cat.release(cat, throwVelocity: CGVector(dx: -900, dy: 0), world: sky([ledge]))

    #expect(cat.facing == -1)
    #expect(cat.activity == .righting, "he tried to pivot on thin air")
}

@Test func everyJumpSpendsTheFullAnticipationInCrouch() {
    // Non-negotiable. This is the difference between a cat and a
    // teleporting rectangle, and it is exactly the sort of thing an optimisation deletes.
    let here = surface(.window(1), y: 500, from: 0, to: 400)
    let there = surface(.window(2), y: 560, from: 500, to: 900, z: 1)
    var cat = standing(at: 300, on: here)
    cat.intent = Intent(destination: .window(2), destinationX: 600, move: .jump(.window(2), 600))

    var crouchTime: TimeInterval = 0
    for _ in 0..<Int(1.0 / dt) {
        cat = Cat.step(cat, world: sky([here, there]), dt: dt)
        if cat.activity == .crouch { crouchTime += dt }
        if cat.velocity.dy > 0 { break }
    }
    #expect(crouchTime >= Feel.Timing.anticipation - dt, "he launched without winding up")
    #expect(cat.velocity.dy > 0, "he never actually left the ground")
}

@Test func aJumpActuallyLandsOnTheTargetSurface() {
    let here = surface(.window(1), y: 500, from: 0, to: 400)
    let there = surface(.window(2), y: 560, from: 500, to: 900, z: 1)
    var cat = standing(at: 300, on: here)
    // 300pt across and 60 up. His whole impulse is 380pt flat, and a 60pt rise costs some of
    // that, so this sits near the edge of what he can do without being outside it.
    cat.intent = Intent(destination: .window(2), destinationX: 600, move: .jump(.window(2), 600))

    for _ in 0..<Int(6 / dt) {
        cat = Cat.step(cat, world: sky([here, there]), dt: dt)
        if case .grounded(let p) = cat.support, p.id == .window(2) { break }
    }
    guard case .grounded(let perch) = cat.support else {
        Issue.record("never landed anywhere")
        return
    }
    #expect(perch.id == .window(2), "the arc missed the target surface entirely")
    // Aim error is deliberate, so this is a loose bound on purpose.
    #expect(abs(cat.position.x - 600) < 120)
}

@Test func aJumpToAVanishedSurfaceDoesNotStrandHim() {
    let here = surface(.window(1), y: 500, from: 0, to: 400)
    var cat = standing(at: 300, on: here)
    // Target closed during the crouch.
    cat.intent = Intent(destination: .window(99), destinationX: 700, move: .jump(.window(99), 700))

    // Past the crouch, but before he has had time to think of something else to do.
    for _ in 0..<Int(0.3 / dt) { cat = Cat.step(cat, world: sky([here]), dt: dt) }

    if case .jump = cat.intent?.move { Issue.record("still aiming at a window that no longer exists") }
    guard case .grounded = cat.support else {
        Issue.record("he launched at nothing")
        return
    }
    #expect(cat.position.x == 300, "he should not have moved at all")
}

@Test func heRestsBetweenIdeas() {
    // Restraint is the feature. Anything moving on screen becomes hateful within three days
    // unless it reads the room, so "still by default" is a requirement, not a nicety.
    let ledge = surface(.window(1), y: 500, from: 0, to: 800)
    var cat = standing(at: 400, on: ledge)
    cat.restLeft = Feel.Timing.restMin
    cat.intent = nil

    var moved = false
    for _ in 0..<Int((Feel.Timing.restMin - 0.2) / dt) {
        cat = Cat.step(cat, world: sky([ledge]), dt: dt)
        if cat.intent != nil { moved = true; break }
    }
    #expect(!moved, "he started moving before his rest was up")
    #expect(Feel.Timing.restMin >= 3, "resting less than a few seconds would be exhausting to sit next to")
}

// MARK: - Intent: a destination, re-planned on every landing

/// A staircase going UP. Each ledge is one comfortable hop above the last and the next-but-one
/// is out of reach at any angle, because a 120pt rise leaves him nothing to spend sideways.
///
/// Upward on purpose. A *descending* staircase is not a two-hop problem at all: a drop is
/// nearly free under a minimum-energy launch, so the bottom step is reachable from the top one
/// in a single leap and the router would be right to take it.
private func stairsWorld() -> Skyline {
    func ledge(_ id: CGWindowID, _ z: Int, _ y: CGFloat, _ r: ClosedRange<CGFloat>) -> Surface {
        Surface(id: .window(id), z: z, y: y, extent: r, solid: [r], spans: [r],
                targetable: true, rect: CGRect(x: r.lowerBound, y: y - 200,
                                               width: r.length, height: 200))
    }
    return sky([ledge(1, 0, 250, 100...400),
                ledge(2, 1, 310, 500...800),
                ledge(3, 2, 370, 1000...1300),
                surface(.floor, y: 100, from: 0, to: 1920, z: .max)])
}

/// A bare desktop: a full-width menu bar eleven hundred points above a full-width floor, with
/// nothing in between. The world at launch on a Mac with no windows open.
private func bareDesktop() -> Skyline {
    sky([surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1),
         surface(.floor, y: 90, from: 0, to: 1920, z: .max)])
}

@Test func theStaircaseReallyIsTwoHops() {
    // Guards the fixture. If ledge 3 were reachable from ledge 1 the routing tests below would
    // pass without any routing happening at all.
    #expect(Cat.canReach(from: CGPoint(x: 400, y: 250), to: CGPoint(x: 500, y: 310)))
    #expect(!Cat.canReach(from: CGPoint(x: 400, y: 250), to: CGPoint(x: 1000, y: 370)))
}

@Test func nextMoveWalksWhenTheDestinationIsUnderfoot() {
    let world = stairsWorld()
    var cat = CatState(position: CGPoint(x: 150, y: 250))
    cat.support = .grounded(Perch(id: .window(1), dx: 50))
    let m = Cat.nextMove(from: cat, on: world.surface(.window(1))!,
                         toward: .window(1), x: 280, world: world)
    #expect(m == .walk(280))
}

@Test func nextMoveHopsToAnIntermediateLedge() {
    let world = stairsWorld()
    var cat = CatState(position: CGPoint(x: 380, y: 250))
    cat.support = .grounded(Perch(id: .window(1), dx: 280))
    // Ledge 3 is two hops away. He should aim at ledge 2, not give up and not teleport.
    let m = Cat.nextMove(from: cat, on: world.surface(.window(1))!,
                         toward: .window(3), x: 1150, world: world)
    guard case .jump(let id, _) = m else {
        Issue.record("expected a jump, got \(String(describing: m))")
        return
    }
    #expect(id == .window(2))
}

@Test func nextMoveWalksToABetterLaunchPointWhenNothingIsInReach() {
    // Standing at the wrong end of his own ledge is not a dead end, it is a walk. Without this
    // he lands mid-ledge, finds the next step out of reach from exactly there, and gives up.
    let world = stairsWorld()
    var cat = CatState(position: CGPoint(x: 600, y: 310))
    cat.support = .grounded(Perch(id: .window(2), dx: 100))
    let m = Cat.nextMove(from: cat, on: world.surface(.window(2))!,
                         toward: .window(3), x: 1150, world: world)
    #expect(m == .walk(800), "got \(String(describing: m))")
}

@Test func heActuallyGetsThereInTwoHops() {
    let world = stairsWorld()
    var cat = CatState(position: CGPoint(x: 150, y: 250))
    cat.support = .grounded(Perch(id: .window(1), dx: 50))
    cat.intent = Intent(destination: .window(3), destinationX: 1150, move: .walk(400))

    for _ in 0..<3600 {
        cat = Cat.step(cat, world: world, dt: dt)
        // Stop the moment he has arrived and settled, or he thinks of something else to do
        // with the twenty seconds left on the clock.
        if cat.intent == nil, case .grounded(let p) = cat.support, p.id == .window(3) { break }
    }

    guard case .grounded(let p) = cat.support else {
        Issue.record("not grounded, ended at \(cat.position)")
        return
    }
    #expect(p.id == .window(3))
    #expect(abs(cat.position.x - 1150) < Feel.Physics.arrivalSlop * 3)
}

@Test func nextMoveStepsOffWhenTheOnlyWayIsDown() {
    let world = stairsWorld()
    var cat = CatState(position: CGPoint(x: 150, y: 250))
    cat.support = .grounded(Perch(id: .window(1), dx: 50))
    cat.facing = -1
    // He could physically throw himself at the floor — a drop is nearly free — but the arc
    // comes back down through his own ledge before it ever clears it.
    let m = Cat.nextMove(from: cat, on: world.surface(.window(1))!,
                         toward: .floor, x: 60, world: world)
    #expect(m == .stepOff)
}

@Test func heGetsFromTheMenuBarToTheFloorBySteppingOff() {
    // The headline case, and the reason the below-surface guard lives in the router rather
    // than in the destination chooser: on a bare desktop the menu bar runs the full
    // width of the screen above the floor, so every arc he can throw re-crosses the bar he
    // launched from and drops him back onto it. The only route down is to walk to the end and
    // step off.
    //
    // Driven through `Cat.step` rather than `nextMove`, deliberately. A router that returns
    // `.stepOff` into an engine with no way to execute one would pass a unit test green.
    let world = bareDesktop()
    let bar = world.surface(.menuBar)!
    var cat = standing(at: 960, on: bar)
    // A move that is already finished, so the router has to produce the first real one itself.
    cat.intent = Intent(destination: .floor, destinationX: 200, move: .walk(960))

    var sawStepOff = false, launched = false
    var landedOn: SurfaceID?
    for _ in 0..<Int(60 / dt) {
        // Re-issued every time he gives up on it, like the notch test above. Wanting to be on
        // the floor is now something he can think better of at the lip — that is the tell, and
        // the reluctance in it is deliberate — so what has to be tested here is that WHEN he
        // goes down, he goes down by stepping off. A cat who asks once and is talked out of it
        // by his own better judgement would fail this for the wrong reason.
        if cat.intent == nil {
            cat.intent = Intent(destination: .floor, destinationX: 200, move: .walk(cat.position.x))
        }
        cat = Cat.step(cat, world: world, dt: dt)
        if cat.intent?.move == .stepOff { sawStepOff = true }
        if cat.velocity.dy > 0 { launched = true }
        if case .grounded(let p) = cat.support, p.id != .menuBar { landedOn = p.id; break }
    }
    #expect(sawStepOff, "he never chose to step off, so Move.stepOff is dead code")
    #expect(!launched, "he tried to jump down instead of stepping off")
    #expect(landedOn == .floor, "he never got off the menu bar")
}

@Test func heDoesNotPlanAJumpThatLandsHimBackWhereHeStarted() {
    // `supportBelow` is inclusive at both ends and does not know which surface he left, so a
    // downward arc re-grounds him wherever it re-crosses his own y over his own solid. The
    // minimum-energy launch makes it tighter rather than looser: menu-bar-to-desktop at 500pt
    // across re-crosses 44pt out, against 268 for a fixed-speed solve.
    let world = bareDesktop()
    let bar = world.surface(.menuBar)!
    var forced = standing(at: 960, on: bar)
    forced.intent = Intent(destination: .floor, destinationX: 1460, move: .jump(.floor, 1460))
    for _ in 0..<Int(10 / dt) {
        forced = Cat.step(forced, world: world, dt: dt)
        if case .grounded(let p) = forced.support, p.id == .floor { break }
    }
    guard case .grounded(let p) = forced.support else {
        Issue.record("still in the air after ten seconds")
        return
    }
    #expect(p.id == .menuBar, "the arc cleared his own surface, so this proves nothing")

    // ...which is precisely why the router refuses to plan it, and steps off instead.
    #expect(Cat.nextMove(from: standing(at: 960, on: bar), on: bar,
                         toward: .floor, x: 1460, world: world) == .stepOff)
}

@Test func aLevelJumpCanStillFallShortOfTheLedge() {
    // The aim margin keeps him off the lip, and it has to stay SMALLER than the shortfall he
    // can actually make, or a whole class of jump silently becomes one he cannot fluff. A level
    // throw's range is exactly s² of nominal, so a −6% push-off falls 11.6% short: against a
    // margin of 2·aimError he misses about one draw in twenty-five, against aimError about one
    // in four. (The overshoot side is starker still — at 2·aimError the worst overshoot reaches
    // 0.9888 of a far lip, so sailing past one was arithmetically impossible.)
    //
    // A cat that occasionally misjudges a jump and has to recover reads as a cat.
    let there = surface(.window(2), y: 500, from: 500, to: 900, z: 1)
    let from = CGPoint(x: 300, y: 500)
    // Aimed at the NEAR lip, which is where the clamp actually bites.
    let aim = try! #require(Cat.aimX(on: there, from: from, toward: 400))
    #expect(aim > 500 && aim < 560, "expected an aim just inside the lip, got \(aim)")

    // One generator across the four hundred trials, so they still scatter and the count is
    // still the same number every run. See `Roll`.
    var roll = Roll(seed: 0x5CA7)
    var short = 0
    for _ in 0..<400 {
        let v = Cat.launch(dx: aim - from.x, dy: 0, using: &roll)!
        if from.x + 2 * v.dx * v.dy / Feel.Physics.gravity < 500 { short += 1 }
    }
    #expect(short > 40, "he fell short only \(short)/400 times; the margin has eaten the error")
}

@Test func heStridesOverACrackRatherThanLeapingIt() {
    // Two tiled windows sharing a top edge are one shelf. A full ballistic arc over the ten
    // points between them reads as a comedy pratfall.
    let left = surface(.window(1), y: 500, from: 0, to: 300)
    let right = surface(.window(2), y: 500, from: 310, to: 600, z: 1)
    let world = sky([left, right])

    // From the middle of his own window he walks to the lip first...
    #expect(Cat.nextMove(from: standing(at: 200, on: left), on: left,
                         toward: .window(2), x: 500, world: world) == .walk(300))
    // ...and from the lip he steps across.
    #expect(Cat.nextMove(from: standing(at: 300, on: left), on: left,
                         toward: .window(2), x: 500, world: world) == .stepAcross(.window(2), 310))

    var cat = standing(at: 300, on: left)
    cat.intent = Intent(destination: .window(2), destinationX: 500,
                        move: .stepAcross(.window(2), 310))
    var fell = false
    for _ in 0..<Int(20 / dt) {
        cat = Cat.step(cat, world: world, dt: dt)
        if case .falling = cat.support { fell = true; break }
        if cat.intent == nil { break }
    }
    #expect(!fell, "he fell into a ten-point crack")
    guard case .grounded(let p) = cat.support else { Issue.record("not grounded"); return }
    #expect(p.id == .window(2))
    // Braking distance plus slop, not slop alone: he coasts past his mark. See the twin of this
    // bound in `heWalksToHisDestinationAndStops`.
    #expect(abs(cat.position.x - 500) < Feel.Physics.brakingDistance + Feel.Physics.arrivalSlop)
}

@Test func steppingOffTheEndOfTheScreenStillLandsOnTheFloor() {
    // The menu bar and the desktop share a span exactly, so the two-point nudge that starts
    // the fall clear of the lip takes him two points past the floor as well, and the slip kick
    // carries him further out with every tick. He falls out of the world and never comes back.
    let world = bareDesktop()
    let bar = world.surface(.menuBar)!
    var cat = standing(at: 30, on: bar)
    cat.intent = Intent(destination: .menuBar, destinationX: -200, move: .walk(-200))

    for _ in 0..<Int(20 / dt) {
        cat = Cat.step(cat, world: world, dt: dt)
        if case .grounded(let p) = cat.support, p.id == .floor { break }
    }
    guard case .grounded(let p) = cat.support else {
        Issue.record("he fell past the floor at x=\(Int(cat.position.x))")
        return
    }
    #expect(p.id == .floor)
    #expect(cat.position.x >= 0)
}

// MARK: - Surfing a dragged window

@Test func heLeansWhenHisPlatformIsDragged() {
    // Being carried is free (his position is derived). This tests the *reaction*.
    var cat = standing(at: 400, on: surface(.window(1), y: 500, from: 0, to: 800))
    var origin: CGFloat = 0

    // Drag right at ~480 px/s, delivered as a 10Hz staircase like the real world poll.
    for tick in 0..<Int(1.5 / dt) {
        if tick % 12 == 0 { origin += 4 * 12 }
        cat = Cat.step(cat, world: sky([surface(.window(1), y: 500, from: origin, to: origin + 800)]), dt: dt)
    }
    #expect(cat.lean > 0.5, "he should be leaning hard into a fast drag")
    #expect(cat.activity == .brace)
}

@Test func aStationaryWindowProducesNoLean() {
    let ledge = surface(.window(1), y: 500, from: 0, to: 800)
    var cat = standing(at: 400, on: ledge)
    for _ in 0..<Int(2 / dt) { cat = Cat.step(cat, world: sky([ledge]), dt: dt) }
    #expect(abs(cat.lean) < 0.01, "he is leaning at nothing")
    #expect(cat.activity != .brace)
}

@Test func leanSettlesBackAfterTheDragStops() {
    var cat = standing(at: 400, on: surface(.window(1), y: 500, from: 0, to: 800))
    var origin: CGFloat = 0
    for tick in 0..<Int(1.5 / dt) {
        if tick % 12 == 0 { origin += 48 }
        cat = Cat.step(cat, world: sky([surface(.window(1), y: 500, from: origin, to: origin + 800)]), dt: dt)
    }
    #expect(cat.lean > 0.5)

    let parked = surface(.window(1), y: 500, from: origin, to: origin + 800)
    for _ in 0..<Int(3 / dt) { cat = Cat.step(cat, world: sky([parked]), dt: dt) }
    #expect(abs(cat.lean) < 0.05, "he never straightened up again")
}

@Test func leanResetsWhenTheGroundDisappears() {
    var cat = standing(at: 400, on: surface(.window(1), y: 500, from: 0, to: 800))
    cat.drift = 4
    cat = Cat.step(cat, world: sky([]), dt: dt)
    #expect(cat.support == .falling)
    #expect(cat.drift == 0, "he would fall through the air still leaning")
}

// MARK: - Being handled

@Test func pickingHimUpMakesHimGoLimp() {
    var cat = standing(at: 400, on: surface(.window(1), y: 500, from: 0, to: 800))
    cat = Cat.grab(cat, at: CGPoint(x: 410, y: 600))
    #expect(cat.support == .held(CGPoint(x: 410, y: 600)))
    #expect(cat.activity == .scruffed)
    #expect(cat.intent == nil, "he should stop whatever he was doing")
}

@Test func heIsNotAffectedByGravityWhileHeld() {
    var cat = CatState(position: CGPoint(x: 400, y: 600))
    cat = Cat.grab(cat, at: CGPoint(x: 400, y: 600))
    for _ in 0..<Int(2 / dt) {
        cat = Cat.step(cat, world: sky([surface(.floor, y: 0, from: 0, to: 1920)]), dt: dt)
    }
    #expect(cat.position.y == 600, "he fell out of your hand")
    #expect(cat.velocity.dy == 0)
}

@Test func heAlwaysLandsOnHisFeet() {
    // The righting reflex, by construction rather than by luck. Tried from every angle and
    // every throw speed the physics allows.
    let ground = surface(.floor, y: 100, from: 0, to: 1920)
    for vx in stride(from: -1400.0, through: 1400.0, by: 350) {
        for vy in stride(from: -1400.0, through: 1400.0, by: 700) {
            var cat = CatState(position: CGPoint(x: 900, y: 800))
            cat = Cat.grab(cat, at: CGPoint(x: 900, y: 800))
            cat = Cat.release(cat, throwVelocity: CGVector(dx: vx, dy: vy),
                              world: sky([ground]))
            #expect(cat.righting == 0, "the twist should start from scratch")

            var landed = false
            for _ in 0..<Int(12 / dt) {
                cat = Cat.step(cat, world: sky([ground]), dt: dt)
                if case .grounded = cat.support { landed = true; break }
            }
            guard landed else { continue }   // thrown clean off the side, fine
            #expect(cat.righting == 1, "he landed mid-twist, on his side, from \\(vx),\\(vy)")
            #expect(cat.activity == .land || cat.activity == .landHard)
        }
    }
}

@Test func theTwistFinishesLongBeforeATypicalLanding() {
    var cat = CatState(position: CGPoint(x: 900, y: 800))
    let ground = surface(.floor, y: 100, from: 0, to: 1920)
    cat = Cat.release(Cat.grab(cat, at: CGPoint(x: 900, y: 800)),
                      throwVelocity: CGVector(dx: 0, dy: 0), world: sky([ground]))

    var rightedAt: TimeInterval?
    var t: TimeInterval = 0
    for _ in 0..<Int(12 / dt) {
        cat = Cat.step(cat, world: sky([ground]), dt: dt)
        t += dt
        if rightedAt == nil, cat.righting >= 1 { rightedAt = t }
        if case .grounded = cat.support { break }
    }
    let righted = try! #require(rightedAt)
    #expect(righted <= Feel.Timing.righting + 0.02)
    #expect(righted < t, "he was still twisting when he hit the ground")
}

@Test func aViolentFlickDoesNotTurnHimIntoAProjectile() {
    var cat = CatState(position: CGPoint(x: 900, y: 800))
    cat = Cat.release(Cat.grab(cat, at: CGPoint(x: 900, y: 800)),
                      throwVelocity: CGVector(dx: 99_000, dy: 99_000), world: sky([]))
    #expect(abs(cat.velocity.dx) <= Feel.Physics.maxThrow)
    #expect(abs(cat.velocity.dy) <= Feel.Physics.maxThrow)
}

@Test func landingOnANewSurfaceDoesNotFakeADrift() {
    // Regression: lastPerchOrigin kept pointing at the PREVIOUS window after a jump, so the
    // first drift sample was the distance between two unrelated windows and he braced hard
    // against a perfectly stationary ledge.
    let here = surface(.window(1), y: 500, from: 0, to: 300)
    let far = surface(.window(2), y: 520, from: 1200, to: 1600, z: 1)
    var cat = standing(at: 150, on: here)
    cat = Cat.step(cat, world: sky([here, far]), dt: dt)

    cat.support = .grounded(Perch(id: .window(2), dx: 100))
    for _ in 0..<Int(0.5 / dt) { cat = Cat.step(cat, world: sky([here, far]), dt: dt) }
    #expect(abs(cat.lean) < 0.05, "he braced against a window that never moved")
    #expect(cat.activity != .brace)
}


// MARK: - The world has sides

/// A drag delivered the way the real world poll delivers one: a 10Hz staircase of 48pt steps,
/// which is ~480 px/s, well past the speed he leans as hard as he ever will at.
private func draggedLedge(_ origin: CGFloat) -> Skyline {
    sky([surface(.window(1), y: 500, from: origin, to: origin + 800)])
}

@Test func heCannotBeAimedOutOfTheWorldAltogether() {
    // `aimX` deliberately leaves him able to sail past the far lip of the run he is aiming at:
    // the margin is one `aimError` and the scatter is roughly two, and that failability is the
    // point — a cat who always sticks the landing reads as a machine.
    //
    // At an interior lip whatever is below catches him. At the OUTERMOST one there is nothing:
    // every surface's `solid` is clipped to the visible frame, so a cat one point outside it
    // has nothing under him at any height, `supportBelow` returns nil for ever, `isMoving`
    // pins the display link at 60Hz and the 0.0% idle claim dies with him. He is gone for the
    // session.
    let ledge = surface(.window(1), y: 1160, from: 1400, to: 1600)
    let world = sky([surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1), ledge,
                     surface(.floor, y: 90, from: 0, to: 1920, z: .max)])

    // The real planner, over enough jumps at the screen's own edge that a 20%-per-jump escape
    // cannot hide. Deterministic in everything except the wobble it is here to survive.
    for _ in 0..<5 {
        for destX in stride(from: CGFloat(1860), through: 1920, by: 4) {
            var cat = standing(at: 1600, on: ledge)
            let move = try! #require(Cat.nextMove(from: cat, on: ledge, toward: .menuBar,
                                                  x: destX, world: world))
            guard case .jump = move else {
                Issue.record("the planner did not jump at \(Int(destX)): \(move)")
                return
            }
            cat.intent = Intent(destination: .menuBar, destinationX: destX, move: move)
            cat.activity = .crouch

            var launched = false
            var landed = false
            for _ in 0..<Int(4 / dt) {
                cat = Cat.step(cat, world: world, dt: dt)
                if case .falling = cat.support { launched = true; continue }
                if launched, case .grounded = cat.support { landed = true; break }
            }
            guard landed else {
                Issue.record("aimed at \(Int(destX)), he left the world at x=\(Int(cat.position.x)) and is still falling")
                return
            }
        }
    }
}

// MARK: - The brace respects the holds

@Test func aHardLandingOnADraggedWindowStillPlaysItsShake() {
    // A brace that sits OUTSIDE the holds in `standing` overwrites whatever they have just
    // set. Landing on a window someone is actually dragging then deletes the shake: once
    // activity is `.brace`, `landingHold` returns nil, so the hold that exists to keep it on
    // screen stops existing.
    var origin: CGFloat = 0
    var tick = 0
    var cat = CatState(position: CGPoint(x: 400, y: 900))     // 400pt up: past hardLanding's 250
    cat.restLeft = .greatestFiniteMagnitude

    func advance() {
        if tick % 12 == 0 { origin += 48 }
        cat = Cat.step(cat, world: draggedLedge(origin), dt: dt)
        tick += 1
    }
    while case .falling = cat.support, tick < Int(3 / dt) { advance() }
    #expect(cat.activity == .landHard, "he did not land hard; the test proves nothing")

    var braced = false
    var leaned = false
    for _ in 0..<Int(Feel.Timing.landHardSeconds / dt) - 1 {
        advance()
        braced = braced || cat.activity == .brace
        leaned = leaned || abs(cat.lean) > Feel.Physics.braceThreshold
    }
    #expect(leaned, "the drag never got past the brace threshold; the test proves nothing")
    #expect(!braced, "the brace overwrote the landing shake")
}

@Test func aPivotOnADraggedWindowStillPivots() {
    // Same root cause, and this one costs the property `turnSeconds` exists to guarantee: the
    // brace overwrites `.turn` on the tick it is set, so he flips like a sprite.
    let ledge = surface(.window(1), y: 500, from: 0, to: 800)
    var cat = standing(at: 40, on: ledge)
    // Already pointing the way he is going, so the only pivot in the whole run is the one at
    // the wall — which is the one that matters, because bouncing off a wall clears the intent
    // and the brace only ever fired when there was none.
    cat.facing = -1
    // Already riding a fast drag rather than spending the walk building one up, so the wall is
    // reached with the lean already over the threshold.
    cat.drift = 3
    cat.lastPerchID = .window(1)
    cat.lastPerchOrigin = 0
    cat.intent = Intent(destination: .window(1), destinationX: -200, move: .walk(-200))

    var origin: CGFloat = 0
    var turnedAt: Int?
    var flipped = false
    for tick in 0..<Int(3 / dt) {
        if tick % 12 == 0 { origin += 48 }
        cat = Cat.step(cat, world: draggedLedge(origin), dt: dt)
        if cat.activity == .turn, turnedAt == nil { turnedAt = tick }
        if let t = turnedAt, tick - t < Int(Feel.Timing.turnSeconds / dt) - 1 {
            flipped = flipped || cat.activity != .turn
        }
    }
    #expect(cat.facing == 1, "he never reached the wall; the test proves nothing")
    #expect(cat.lean > Feel.Physics.braceThreshold, "the drag stopped; the test proves nothing")
    #expect(turnedAt != nil, "the brace overwrote the pivot on the tick it was set")
    #expect(!flipped, "the pivot was cut short and he flipped on the spot")
}

@Test func aSleepingCatRidesTheDragOutAsleep() {
    // `.brace` draws the alert sheet, so a sleeping cat on a dragged window sits bolt upright
    // in it, and then slumbers there, since `isResting` does not care what he is drawing.
    var cat = standing(at: 400, on: surface(.window(1), y: 500, from: 0, to: 800))
    cat.repose = .asleep
    var origin: CGFloat = 0
    for tick in 0..<Int(2 / dt) {
        if tick % 12 == 0 { origin += 48 }
        cat = Cat.step(cat, world: draggedLedge(origin), dt: dt)
    }
    #expect(cat.lean > Feel.Physics.braceThreshold, "the drag never registered")
    #expect(cat.activity == .sleep)
}

@Test func aCurledCatGoesBackToBeingCurledWhenTheDragStops() {
    // A brace that restores to `.idle` rather than to the pose he was actually resting in pops
    // a curled cat upright for a tick and then plays the whole curl-down again.
    var cat = standing(at: 400, on: surface(.window(1), y: 500, from: 0, to: 800))
    cat.repose = .curled
    var origin: CGFloat = 0
    for tick in 0..<Int(1.5 / dt) {
        if tick % 12 == 0 { origin += 48 }
        cat = Cat.step(cat, world: draggedLedge(origin), dt: dt)
    }
    #expect(cat.activity == .brace, "he never braced; the test proves nothing")

    var popped = false
    for _ in 0..<Int(3 / dt) {
        cat = Cat.step(cat, world: draggedLedge(origin), dt: dt)   // the drag stops
        popped = popped || cat.activity == .idle
    }
    #expect(abs(cat.lean) < Feel.Physics.braceThreshold, "the lean never settled")
    #expect(!popped, "he popped upright out of the brace instead of settling back")
    #expect(cat.activity == .curl)
}

// MARK: - Climbing as a route

/// A bare desktop with one tall window standing on it. Built through `World.build` so the
/// spans and the corner insets are the real ones.
///
/// Its top edge is 810 points above the floor, against the 190 of rise `jumpImpulse` buys, so
/// no jump reaches it from down there at any angle. Its bottom edge is 110 up, which IS within
/// one leap. The face is the only way, and it is the world he gets stuck in without one: once
/// he falls all the way to the desktop, every window is higher than he can reach.
private func curtainWorld(bottom: CGFloat = 200) -> Skyline {
    World.build(windows: [RawWindow(id: 1, pid: 2, layer: 0,
                                    rect: CGRect(x: 700, y: bottom,
                                                 width: 500, height: 900 - bottom),
                                    alpha: 1, owner: "Xcode")],
                screen: screen, ownPID: 99)
}

@Test func theCurtainReallyIsOutOfJumpingReach() {
    // Guards the fixture. If the top edge were reachable the climb tests below would pass
    // without a single climb happening.
    let world = curtainWorld()
    #expect(!Cat.canReach(from: CGPoint(x: 950, y: 90), to: CGPoint(x: 950, y: 900)))
    #expect(Cat.canReach(from: CGPoint(x: 950, y: 90), to: CGPoint(x: 950, y: 200)),
            "the bottom of the face is out of reach too; nothing could ever climb this")
    #expect(world.surface(.floor)?.spans.first?.contains(950) == true,
            "the floor under the window is hidden, so Part A's rule would carry this on its own")
}

@Test func nextMoveClimbsWhenTheOnlyWayUpIsAWindowFace() {
    let world = curtainWorld()
    let floor = world.surface(.floor)!
    let cat = standing(at: 300, on: floor)
    let m = Cat.nextMove(from: cat, on: floor, toward: .window(1), x: 950, world: world)
    guard case .climb(let id, let x) = m else {
        Issue.record("expected a climb, got \(String(describing: m))")
        return
    }
    #expect(id == .window(1))
    #expect(x >= 700 && x <= 1200, "the launch point is not under the face")
}

@Test func heGetsOffTheDesktopByClimbing() {
    // Driven all the way through `Cat.step`. A router that returns `.climb` into an engine
    // with no way to execute one would pass the unit test above green.
    let world = curtainWorld()
    var cat = standing(at: 300, on: world.surface(.floor)!)
    cat.intent = Intent(destination: .window(1), destinationX: 950, move: .walk(300))

    var clung = false
    for _ in 0..<Int(60 / dt) {
        cat = Cat.step(cat, world: world, dt: dt)
        if case .clinging = cat.support { clung = true }
        if cat.intent == nil, case .grounded = cat.support { break }
    }
    guard case .grounded(let p) = cat.support else {
        Issue.record("still in the air after a minute, at \(cat.position)")
        return
    }
    #expect(clung, "he got up there without ever touching the face; this proves nothing")
    #expect(p.id == .window(1), "he never got off the desktop")
    #expect(abs(cat.position.x - 950) < Feel.Physics.arrivalSlop * 3)
    #expect(cat.intent == nil, "he arrived and never settled, so `isMoving` is pinned true")
}

@Test func anOrdinaryJumpThroughAWindowFaceStillDoesNotStick() {
    // The grab is gated on the INTENT, not on the geometry. An arc that happens to pass
    // through a face on the way up has to sail straight through it.
    //
    // Level ledges 300 apart, and a short curtain planted between them whose face the arc
    // crosses while it is still rising (apex is 150pt out; the face is at 50-100).
    let here = surface(.window(1), y: 500, from: 0, to: 120)
    let there = surface(.window(2), y: 500, from: 380, to: 800, z: 2)
    let curtain = Surface(id: .window(3), z: 1, y: 560, extent: 150...200,
                          solid: [150...200], spans: [150...200], targetable: true,
                          rect: CGRect(x: 150, y: 480, width: 50, height: 80))
    let world = sky([here, there, curtain, surface(.floor, y: 90, from: 0, to: 1920, z: .max)])

    var cat = standing(at: 100, on: here)
    cat.intent = Intent(destination: .window(2), destinationX: 400, move: .jump(.window(2), 400))
    cat.activity = .crouch

    var crossedTheFace = false
    for _ in 0..<Int(5 / dt) {
        cat = Cat.step(cat, world: world, dt: dt)
        if cat.velocity.dy > 0, world.faceContaining(cat.position)?.id == .window(3) {
            crossedTheFace = true
        }
        if case .clinging = cat.support {
            Issue.record("an ordinary jump stuck to a window face at \(cat.position)")
            return
        }
    }
    #expect(crossedTheFace, "the arc never rose through the face, so this test proved nothing")
}

@Test func climbingAlwaysEndsSomewhereRatherThanCycling() {
    // The real risk in a climb: a route that oscillates between leaping at a face and dropping
    // back off it would be worse than the stuckness it replaces, because `intent != nil` pins
    // `isMoving` and with it the render rate, and `enterSlumber` never runs again.
    //
    // The wobble on the launch is the thing being soaked: `launch` scatters the push-off by
    // +/-6% of the speed, so whether he is still RISING when he reaches the bottom of the face
    // is a fresh draw every attempt. `climbBite` is the margin that has to survive all of them.
    var worstAirborne = 0.0, worstRun = 0.0, launches = 0, stranded = 0
    for seed in 0..<240 {
        // Vary where he starts and how high the face begins, across the whole band the gate
        // admits (a bottom edge 150pt up is the last one `climbBite` lets him try).
        let world = curtainWorld(bottom: 90 + CGFloat(seed % 16) * 10)
        var cat = standing(at: 120 + CGFloat(seed / 16) * 30, on: world.surface(.floor)!)
        cat.intent = Intent(destination: .window(1), destinationX: 950,
                            move: .walk(cat.position.x))

        var airborne = 0, ticks = 0, ups = 0
        var finished = false
        for t in 0..<Int(90 / dt) {
            let wasGrounded = { if case .grounded = cat.support { return true } else { return false } }()
            cat = Cat.step(cat, world: world, dt: dt)
            if case .grounded = cat.support { airborne = 0 } else { airborne += 1 }
            if wasGrounded, case .falling = cat.support { ups += 1 }
            worstAirborne = max(worstAirborne, Double(airborne) * dt)
            ticks = t
            if cat.intent == nil, case .grounded = cat.support { finished = true; break }
        }
        worstRun = max(worstRun, Double(ticks) * dt)
        launches = max(launches, ups)
        guard finished else {
            Issue.record("run \(seed) never settled; ended \(cat.support) at \(cat.position)")
            return
        }
        if case .grounded(let p) = cat.support, p.id != .window(1) { stranded += 1 }
    }
    #expect(stranded == 0, "\(stranded)/240 runs never got up the curtain")
    // A climb is one launch. More than a couple means he is dropping back and trying again,
    // which is the cycle this test exists to refuse.
    #expect(launches <= 2, "some run left the ground \(launches) times to make one climb")
    #expect(worstAirborne < 12, "longest unsupported stretch was \(worstAirborne)s")
    #expect(worstRun < 30, "slowest run took \(worstRun)s")
}

/// The sibling test above hand-builds spans, so it never meets `World.build`, which insets
/// every window's standable span by `cornerInset` at each end. Through the real world builder
/// the number `strideGap` is compared against is the physical crack plus 20, so a constant
/// written about the crack itself only ever admitted cracks of 0 to 4 points. `stepAcross`'s
/// own doc names a six-point crack between two tiled windows as the case a leap must never be
/// used for, and six is exactly what got a leap.
@Test func realTiledWindowsGetAStrideAndNotALeap() {
    let screen = ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                               visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                               notch: nil)
    for crack in [CGFloat(0), 2, 4, 6, 8] {
        let a = RawWindow(id: 1, pid: 1, layer: 0,
                          rect: CGRect(x: 100, y: 200, width: 600, height: 400), alpha: 1, owner: "A")
        let b = RawWindow(id: 2, pid: 2, layer: 0,
                          rect: CGRect(x: 700 + crack, y: 200, width: 600, height: 400), alpha: 1, owner: "B")
        let world = World.build(windows: [a, b], screen: screen, ownPID: 99)
        guard let left = world.surfaces.first(where: { $0.id == .window(1) }),
              let lip = left.solid.last?.upperBound else {
            Issue.record("no left surface at crack \(crack)"); return
        }
        let move = Cat.nextMove(from: standing(at: lip, on: left), on: left,
                                toward: .window(2), x: 1000, world: world)
        guard case .stepAcross = move else {
            Issue.record("a \(crack)pt crack between two tiled windows got \(String(describing: move))")
            return
        }
    }
}
