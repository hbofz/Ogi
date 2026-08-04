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

/// A single hop on the surface he is already standing on: what `Goal.walkTo` used to mean.
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
    // He no longer stops dead on the mark: he brakes late and coasts a few points past it, so
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
    // claim as the manifesto's "settles back". He does not walk back, deliberately, and this
    // test cannot tell the difference: at a 3pt overshoot the third expectation below passes
    // identically whether a settle-back exists or not. Naming it after one would be how a
    // behaviour gets marked done on a green run without ever having been built, which is
    // precisely what happened to overshoot itself on the old roadmap.
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
    // 210pt, so he is inside `hurryDistance` and strolling. Aimed at 850 this passed on the
    // RUN speed, which is 2.5x the bound below and would have stayed green with no ramp on
    // the walk at all.
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

    // Reversing him no longer happens on the tick it is asked for: he pivots, which takes the
    // length of the `turn` sheet, and `facing` leads the pivot rather than following it. So the
    // second half of this is a few hundred milliseconds later than the first, and the
    // interesting claim moved to `heTurnsRatherThanFlipping`.
    //
    // Run to the resumed walk rather than for a fixed count. He is ALREADY pivoting when this
    // starts (the step above reversed him too), so a fixed budget here has to cover two of
    // them back to back, and one written to cover only one passed for a while by landing on a
    // zero-length second pivot.
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
    // Non-negotiable, per the manifesto. This is the difference between a cat and a
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
    // The headline acceptance, and the reason the below-surface guard had to move out of the
    // destination chooser and into the router: on a bare desktop the menu bar runs the full
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
    // minimum-energy launch made this worse rather than better: menu-bar-to-desktop at 500pt
    // across re-crosses 44pt out, where the old fixed-speed solve crossed at 268.
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
    // Manifesto §6: a cat that occasionally misjudges a jump and has to recover reads as a cat.
    let there = surface(.window(2), y: 500, from: 500, to: 900, z: 1)
    let from = CGPoint(x: 300, y: 500)
    // Aimed at the NEAR lip, which is where the clamp actually bites.
    let aim = try! #require(Cat.aimX(on: there, from: from, toward: 400))
    #expect(aim > 500 && aim < 560, "expected an aim just inside the lip, got \(aim)")

    let short = (0..<400).filter { _ in
        let v = Cat.launch(dx: aim - from.x, dy: 0)!
        return from.x + 2 * v.dx * v.dy / Feel.Physics.gravity < 500
    }.count
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
    // the fall clear of the lip took him two points past the floor as well — and the slip kick
    // carried him further out with every tick. He fell out of the world and never came back.
    // Unreachable before `stepOff` existed, because nothing ever walked him to the screen edge.
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
    // The righting reflex, by construction rather than by luck. Try it from every angle
    // and every throw speed we allow.
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

