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

// MARK: - Task 1: routing refuses the impossible

@Test func heWillNotSetOutForSomewhereHeCanNeverReach() {
    // A bare desktop: the menu bar is 1115pt above the floor and jumpImpulse buys 190pt.
    // Before this fix nextMove answered ".walk to the x underneath it", so he paced the
    // desktop for ever, re-planning the same impossible trip on every arrival.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    let floor = surface(.floor, y: 90, from: 0, to: 1920, z: .max)
    let world = sky([bar, floor])

    var cat = CatState(position: CGPoint(x: 300, y: 90))
    cat.support = .grounded(Perch(id: .floor, dx: 300))

    let move = Cat.nextMove(from: cat, on: floor, toward: .menuBar, x: 1500, world: world)
    #expect(move == nil, "he cannot get to the menu bar from the floor, so there is no next move")
}

@Test func heStillWalksIntoPositionWhenWalkingThereOpensARoute() {
    // The load-bearing half of the same branch, and the reason it cannot simply return nil.
    // He is at the far left of a long floor and the step up is 1500pt to his right: too far to
    // leap from here, and one jump from directly underneath. Walking there is real progress.
    //
    // The ledge deliberately has no `rect`, so it has no face. `climbTarget` does not depend on
    // where he is standing, so a climbable face would be chosen from his starting x too and
    // this branch would never be reached. A ledge with no face is the only shape that isolates
    // it, which is worth knowing: the walk-into-position fallback only ever fires for an upward
    // destination with nothing to climb.
    let floor = surface(.floor, y: 90, from: 0, to: 1920, z: .max)
    let ledge = surface(.window(1), y: 230, from: 1400, to: 1900, z: 0)
    let world = sky([floor, ledge])

    var cat = CatState(position: CGPoint(x: 100, y: 90))
    cat.support = .grounded(Perch(id: .floor, dx: 100))

    let move = Cat.nextMove(from: cat, on: floor, toward: .window(1), x: 1650, world: world)
    guard case .walk(let x)? = move else {
        Issue.record("expected a walk into position, got \(String(describing: move))")
        return
    }
    #expect(x > cat.position.x, "the walk has to be toward the ledge, not away from it")
}

@Test func theReachabilityReAskCannotRecurseMoreThanOnce() {
    // Structural, not behavioural: mayWalk == false must skip the branch that recurses, so
    // the depth is bounded by construction rather than by an argument about the geometry.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    let floor = surface(.floor, y: 90, from: 0, to: 1920, z: .max)
    let world = sky([bar, floor])

    var cat = CatState(position: CGPoint(x: 300, y: 90))
    cat.support = .grounded(Perch(id: .floor, dx: 300))

    let move = Cat.nextMove(from: cat, on: floor, toward: .menuBar, x: 1500,
                            world: world, mayWalk: false)
    #expect(move == nil)
}

// MARK: - Task 2: the scalar

@Test func excitementFadesOnItsOwnSchedule() {
    let ground = surface(.floor, y: 90, from: 0, to: 1920, z: .max)
    var cat = CatState(position: CGPoint(x: 300, y: 90))
    cat.support = .grounded(Perch(id: .floor, dx: 300))
    cat.arousal = 1

    for _ in 0..<Int(Feel.Mind.arousalHalfLife / dt) {
        cat = Cat.step(cat, world: sky([ground]), dt: dt)
    }
    #expect(abs(cat.arousal - 0.5) < 0.02, "one half-life should halve it, got \(cat.arousal)")
}

@Test func arousalNeverGoesNegativeOrAboveOne() {
    let ground = surface(.floor, y: 90, from: 0, to: 1920, z: .max)
    var cat = CatState(position: CGPoint(x: 300, y: 90))
    cat.support = .grounded(Perch(id: .floor, dx: 300))
    cat.arousal = 1
    for _ in 0..<(120 * 600) { cat = Cat.step(cat, world: sky([ground]), dt: dt) }
    #expect(cat.arousal >= 0)
    #expect(cat.arousal <= 1)
}

@Test func aRousedCatHasIdeasSooner() {
    // The first of arousal's two everywhere-effects. Measured as elapsed time to the first
    // intent, over many trials, because restLeft is randomised per settle.
    func timeToFirstIdea(arousal: Double) -> Double {
        let ground = surface(.floor, y: 90, from: 0, to: 1920, z: .max)
        var total = 0.0
        for _ in 0..<60 {
            var cat = CatState(position: CGPoint(x: 300, y: 90))
            cat.support = .grounded(Perch(id: .floor, dx: 300))
            var t = 0.0
            for _ in 0..<(120 * 120) {
                cat.arousal = arousal          // held, so decay does not confound the measurement
                cat = Cat.step(cat, world: sky([ground]), dt: dt)
                t += dt
                if cat.intent != nil { break }
            }
            total += t
        }
        return total / 60
    }
    let calm = timeToFirstIdea(arousal: 0)
    let roused = timeToFirstIdea(arousal: 1)
    #expect(roused < calm * 0.75, "roused \(roused)s vs calm \(calm)s: not visibly sooner")
}

@Test func aRousedCatGoesSomewhereRatherThanWashing() {
    // The second everywhere-effect. A CURLED cat is used deliberately: inPlaceChance is 0.95
    // there, so if arousal cannot move this number it cannot move any of them.
    func tripShare(arousal: Double) -> Double {
        let ground = surface(.floor, y: 90, from: 0, to: 1920, z: .max)
        var trips = 0, bouts = 0
        for _ in 0..<200 {
            var cat = CatState(position: CGPoint(x: 300, y: 90))
            cat.support = .grounded(Perch(id: .floor, dx: 300))
            cat.repose = .curled
            for _ in 0..<(120 * 600) {
                cat.arousal = arousal
                cat = Cat.step(cat, world: sky([ground]), dt: dt)
                if cat.intent != nil { trips += 1; bouts += 1; break }
                if cat.activity == .groom { bouts += 1; break }
            }
        }
        return Double(trips) / Double(max(bouts, 1))
    }
    #expect(tripShare(arousal: 1) > tripShare(arousal: 0),
            "arousal does not tip boredom toward travelling")
}

// MARK: - Invariant I1

@Test func nothingHappeningOnScreenCanKeepHimAwake() {
    // I1. repose is driven by YOUR idle time and nothing else, so arousal must not be able to
    // reach the sleep ladder. This is what protects the 0.0% idle headline.
    let ground = surface(.floor, y: 90, from: 0, to: 1920, z: .max)
    var cat = CatState(position: CGPoint(x: 300, y: 90))
    cat.support = .grounded(Perch(id: .floor, dx: 300))
    cat.repose = Repose.from(idleSeconds: 700)
    #expect(cat.repose == .asleep, "fixture: 700s of idle has to be the asleep rung")

    for _ in 0..<(120 * 60) {
        cat.arousal = 1                        // pegged, as if something happened every tick
        cat = Cat.step(cat, world: sky([ground]), dt: dt)
    }
    #expect(cat.activity == .sleep, "he woke up because things were happening on screen")
    #expect(cat.intent == nil)
    #expect(cat.isMoving == false, "enterSlumber is unreachable while isMoving is true")
}

// MARK: - Task 3: the glance

@Test func somethingHappeningMakesHimLookAtIt() {
    let ground = surface(.floor, y: 90, from: 0, to: 1920, z: .max)
    var cat = CatState(position: CGPoint(x: 300, y: 90))
    cat.support = .grounded(Perch(id: .floor, dx: 300))
    cat.stimulus = Stimulus(kind: .windowOpened, at: CGPoint(x: 1500, y: 700))

    cat = Cat.step(cat, world: sky([ground]), dt: dt)
    #expect(cat.lookingAt == CGPoint(x: 1500, y: 700))
    #expect(cat.stimulus == nil, "the stimulus has to be consumed, or it fires every tick")
    #expect(cat.arousal > 0, "a window opening has to stir him")
}

@Test func heGoesBackToWatchingYourCursorAfterwards() {
    let ground = surface(.floor, y: 90, from: 0, to: 1920, z: .max)
    var cat = CatState(position: CGPoint(x: 300, y: 90))
    cat.support = .grounded(Perch(id: .floor, dx: 300))
    cat.stimulus = Stimulus(kind: .windowOpened, at: CGPoint(x: 1500, y: 700))
    cat = Cat.step(cat, world: sky([ground]), dt: dt)
    #expect(cat.lookingAt != nil)

    for _ in 0..<Int(Feel.Mind.glanceSeconds / dt + 2) {
        cat = Cat.step(cat, world: sky([ground]), dt: dt)
    }
    #expect(cat.lookingAt == nil, "his eyes never went back to you")
}

@Test func oneWindowIsAGlanceAndTwoIsATrip() {
    // The legibility rule, asserted as arithmetic on the constants rather than as behaviour,
    // so that moving any of the three numbers fails here loudly instead of making him
    // subtly duller with every test still green.
    let one = Feel.Mind.arousalWindowOpened
    #expect(one < Feel.Mind.investigateAbove,
            "one window opening now earns a trip; he will chase every menu that appears")
    let two = one * pow(0.5, 10 / Feel.Mind.arousalHalfLife) + one
    #expect(two > Feel.Mind.investigateAbove,
            "two windows ten seconds apart no longer earn a trip; the dial does nothing")
}

// MARK: - Task 4: a window opening

private func win(_ id: CGWindowID, y: CGFloat, from: CGFloat, to: CGFloat) -> Surface {
    surface(.window(id), y: y, from: from, to: to,
            rect: CGRect(x: from, y: y - 300, width: to - from, height: 300))
}

@Test func theTrackerReportsAWindowTheMomentItBecomesSomewhereHeCouldGo() {
    var tracker = WorldTracker()
    let floor = surface(.floor, y: 90, from: 0, to: 1920, z: .max)

    // Settle the world first. Everything is new at launch, including the floor and the menu
    // bar, and each is reported on the poll its age reaches minAgePolls. That is correct for
    // a tracker primitive and wrong as a behaviour, so `App` ignores the first poll rather
    // than the tracker pretending the world began already old.
    for _ in 0...Feel.World.minAgePolls { _ = tracker.ingest(sky([floor])) }
    #expect(tracker.justAppeared.isEmpty, "fixture: the world has not settled")

    for poll in 1...Feel.World.minAgePolls {
        _ = tracker.ingest(sky([floor, win(7, y: 600, from: 400, to: 900)]))
        if poll < Feel.World.minAgePolls {
            #expect(tracker.justAppeared.isEmpty,
                    "he noticed it on poll \(poll), before it was a place he could stand")
        }
    }
    #expect(tracker.justAppeared == [.window(7)])

    _ = tracker.ingest(sky([floor, win(7, y: 600, from: 400, to: 900)]))
    #expect(tracker.justAppeared.isEmpty, "it reported the same window twice")
}

@Test func aWindowThatClosesAndReopensIsNewAgain() {
    var tracker = WorldTracker()
    let floor = surface(.floor, y: 90, from: 0, to: 1920, z: .max)
    let w = win(7, y: 600, from: 400, to: 900)

    for _ in 0..<5 { _ = tracker.ingest(sky([floor, w])) }
    // Gone long enough to be forgotten: vanishConfirmPolls of misses expires it.
    for _ in 0..<(Feel.World.vanishConfirmPolls + 2) { _ = tracker.ingest(sky([floor])) }
    for _ in 0..<Feel.World.minAgePolls { _ = tracker.ingest(sky([floor, w])) }
    #expect(tracker.justAppeared == [.window(7)])
}

// MARK: - Task 5: promotion

/// A world where the stimulus is somewhere he can actually get to, so a refusal to travel is
/// about arousal rather than about routing.
private func twoLedges() -> Skyline {
    sky([surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1),
         win(7, y: 1100, from: 400, to: 900),
         surface(.floor, y: 90, from: 0, to: 1920, z: .max)])
}

@Test func aCalmCatOnlyLooks() {
    let world = twoLedges()
    var cat = CatState(position: CGPoint(x: 300, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 300))
    cat.arousal = 0
    cat.stimulus = Stimulus(kind: .windowOpened, at: CGPoint(x: 650, y: 1100))

    cat = Cat.step(cat, world: world, dt: dt)
    #expect(cat.lookingAt != nil, "he did not even look")
    #expect(cat.intent == nil, "a calm cat set off after it; the dial does nothing")
}

@Test func aRousedCatGoesToLookProperly() {
    let world = twoLedges()
    var cat = CatState(position: CGPoint(x: 300, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 300))
    cat.arousal = 1
    cat.stimulus = Stimulus(kind: .windowOpened, at: CGPoint(x: 650, y: 1100))

    cat = Cat.step(cat, world: world, dt: dt)
    #expect(cat.lookingAt != nil)
    #expect(cat.intent?.destination == .window(7),
            "a roused cat did not set off, got \(String(describing: cat.intent))")
}

@Test func heDoesNotAbandonWhatHeIsAlreadyDoing() {
    // A stimulus arriving mid-trip must not re-target him, or he never completes anything and
    // every window that opens resets him.
    let world = twoLedges()
    var cat = CatState(position: CGPoint(x: 300, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 300))
    cat.arousal = 1
    cat.intent = Intent(destination: .floor, destinationX: 1700, move: .stepOff)
    cat.stimulus = Stimulus(kind: .windowOpened, at: CGPoint(x: 650, y: 1100))

    cat = Cat.step(cat, world: world, dt: dt)
    #expect(cat.intent?.destination == .floor, "the new window hijacked a trip already underway")
    #expect(cat.lookingAt != nil, "he should still have LOOKED at it")
}

@Test func heDoesNotSetOffForSomewhereHeCannotReach() {
    // Task 1's fix, seen from the mind rather than from the router: a stimulus on an
    // unreachable surface earns a look and nothing more.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    let floor = surface(.floor, y: 90, from: 0, to: 1920, z: .max)
    var cat = CatState(position: CGPoint(x: 300, y: 90))
    cat.support = .grounded(Perch(id: .floor, dx: 300))
    cat.arousal = 1
    cat.stimulus = Stimulus(kind: .windowOpened, at: CGPoint(x: 1500, y: 1205))

    cat = Cat.step(cat, world: sky([bar, floor]), dt: dt)
    #expect(cat.lookingAt != nil)
    #expect(cat.intent == nil, "he set off for the menu bar from the floor again")
}

// MARK: - Task 6: switching apps

@Test func switchingAppsStirsHimLessThanNewFurniture() {
    // Both are glances, but they are not equally interesting, and the ordering is what stops a
    // busy hour of alt-tabbing from reading the same as a window actually appearing.
    #expect(Feel.Mind.arousalAppSwitched < Feel.Mind.arousalWindowOpened)
    #expect(Feel.Mind.arousalAppSwitched > 0, "an app switch he cannot feel is not a signal")
}

@Test func anAppSwitchMakesHimLookAtThatWindow() {
    let world = twoLedges()
    var cat = CatState(position: CGPoint(x: 300, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 300))
    cat.stimulus = Stimulus(kind: .appSwitched, at: CGPoint(x: 650, y: 1100))

    cat = Cat.step(cat, world: world, dt: dt)
    #expect(cat.lookingAt == CGPoint(x: 650, y: 1100))
    #expect(cat.arousal > 0)
}

@Test func altTabbingAloneCannotSendHimAcrossTheScreen() {
    // Four switches back to back stay under the trip threshold, so flicking between two apps
    // is a cat glancing rather than a cat pacing after you.
    let world = twoLedges()
    var cat = CatState(position: CGPoint(x: 300, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 300))
    cat.restLeft = .infinity          // so any intent must come from the switches

    for _ in 0..<4 {
        cat.stimulus = Stimulus(kind: .appSwitched, at: CGPoint(x: 650, y: 1100))
        cat = Cat.step(cat, world: world, dt: dt)
    }
    #expect(cat.intent == nil, "four alt-tabs sent him walking; arousal \(cat.arousal)")
}

@Test func flittingAroundStillMakesTheNextWindowWorthGettingUpFor() {
    // The other half of `canTravel`. An app switch cannot move him on its own, but it still
    // contributes, so a window opening while you have been busy is likelier to be worth a trip
    // than the same window opening into a quiet room. That contribution is the whole reason the
    // weight is not simply zero.
    let world = twoLedges()
    func went(afterSwitches n: Int) -> Bool {
        var cat = CatState(position: CGPoint(x: 300, y: 1205))
        cat.support = .grounded(Perch(id: .menuBar, dx: 300))
        cat.restLeft = .infinity
        for _ in 0..<n {
            cat.stimulus = Stimulus(kind: .appSwitched, at: CGPoint(x: 650, y: 1100))
            cat = Cat.step(cat, world: world, dt: dt)
        }
        cat.stimulus = Stimulus(kind: .windowOpened, at: CGPoint(x: 650, y: 1100))
        cat = Cat.step(cat, world: world, dt: dt)
        return cat.intent != nil
    }
    #expect(went(afterSwitches: 0) == false, "one window into a quiet room should be a glance")
    #expect(went(afterSwitches: 2), "a window opening after you had been busy should be worth a trip")
}

// MARK: - Task 7: holding still

@Test func typingFastFreezesHim() {
    let ground = surface(.floor, y: 90, from: 0, to: 1920, z: .max)
    var cat = CatState(position: CGPoint(x: 300, y: 90))
    cat.support = .grounded(Perch(id: .floor, dx: 300))
    cat.typingHard = true
    cat.restLeft = 0                     // he would otherwise be about to have an idea

    for _ in 0..<(120 * 30) { cat = Cat.step(cat, world: sky([ground]), dt: dt) }
    #expect(cat.activity == .alert, "he did not snap alert while you were typing")
    #expect(cat.intent == nil, "he set off somewhere while you were typing")
}

@Test func aHotMicDoesNotDestroyWhereHeWasGoing() {
    // The bug: ground()'s listening branch did `intent = nil`, and arrival() sets the
    // walk-out-of-the-notch intent moments earlier. Launching with a live mic silently
    // destroyed the app's first impression and nothing restored it.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 900))
    cat.intent = Intent(destination: .menuBar, destinationX: 804, move: .walk(804))
    cat.listening = true

    for _ in 0..<(120 * 5) { cat = Cat.step(cat, world: sky([bar]), dt: dt) }
    #expect(cat.activity == .alert)
    #expect(cat.intent?.destinationX == 804, "the mic ate where he was going")
    #expect(abs(cat.position.x - 900) < 1, "he moved while frozen")

    // Mic goes quiet: he picks the trip back up rather than picking somewhere new.
    //
    // Asked as "does he ever get there", not "where is he in twenty seconds". He arrives in
    // about two, settles, and then has a fresh idea like any other cat, so a snapshot taken
    // later measures the next trip rather than this one.
    cat.listening = false
    var resumed = false
    for _ in 0..<(120 * 10) {
        cat = Cat.step(cat, world: sky([bar]), dt: dt)
        if abs(cat.position.x - 804) < Feel.Physics.arrivalSlop * 3 { resumed = true; break }
    }
    #expect(resumed, "he never resumed the walk; he stopped at \(cat.position.x)")
}

@Test func aFrozenCatCostsNothingToRender() {
    // The regression this task could easily cause. isMoving drives the render-rate ladder, and
    // it returns true whenever intent != nil. Now that a held intent survives the freeze, a
    // live mic would otherwise pin the display link at 60Hz for the whole call.
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 900))
    cat.intent = Intent(destination: .menuBar, destinationX: 804, move: .walk(804))
    cat.listening = true
    #expect(cat.isMoving == false, "a frozen cat is pinning the display link at 60Hz")
    #expect(cat.isResting == true)

    // ...but a frozen cat in mid-air is still falling, and that has to render.
    cat.support = .falling
    #expect(cat.isMoving == true, "he stopped rendering mid-fall because your mic was live")
}

@Test func holdingStillIsEitherReason() {
    var cat = CatState(position: .zero)
    #expect(cat.holdingStill == false)
    cat.listening = true
    #expect(cat.holdingStill)
    cat.listening = false
    cat.typingHard = true
    #expect(cat.holdingStill)
}

@Test func theTypingThresholdsCannotFlicker() {
    #expect(Feel.Mind.typingCalm < Feel.Mind.typingAlert,
            "without hysteresis he flickers in and out of the pose at every pause for breath")
}

// MARK: - Task 8: coming to your cursor

@Test func heComesOverWhenYourCursorHasSatStillNearHim() {
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 300, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 300))
    cat.cursor = CGPoint(x: 600, y: 1205)
    cat.cursorStill = Feel.Mind.cursorStillSeconds + 1

    for _ in 0..<(120 * 2) { cat = Cat.step(cat, world: sky([bar]), dt: dt) }
    #expect(cat.intent != nil, "your cursor sat still next to him and he ignored it")
    #expect(cat.intent?.destination == .menuBar)
}

@Test func heIgnoresACursorAcrossTheScreen() {
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 300, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 300))
    cat.cursor = CGPoint(x: 300 + Feel.Mind.cursorNearby + 200, y: 1205)
    cat.cursorStill = Feel.Mind.cursorStillSeconds + 1
    cat.restLeft = .infinity            // so any intent must be the cursor's doing

    for _ in 0..<(120 * 2) { cat = Cat.step(cat, world: sky([bar]), dt: dt) }
    #expect(cat.intent == nil, "he crossed the screen for a cursor that was not near him")
}

@Test func heIgnoresACursorThatIsStillMoving() {
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 300, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 300))
    cat.cursor = CGPoint(x: 600, y: 1205)
    cat.cursorStill = 1                 // barely settled
    cat.restLeft = .infinity

    for _ in 0..<(120 * 2) { cat = Cat.step(cat, world: sky([bar]), dt: dt) }
    #expect(cat.intent == nil)
}

@Test func heSettlesBesideYourCursorAndNeverOnIt() {
    // THE load-bearing assertion of this task. Overlay.setInteractive toggles
    // ignoresMouseEvents from exactly "is the cursor inside his hit rect", so a cat resting on
    // your cursor is a cat swallowing every click you make until he moves.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    for startX in stride(from: CGFloat(100), through: 1800, by: 100) {
        let cursor = CGPoint(x: 900, y: 1205)
        guard let x = Cat.beside(cursor: cursor, on: bar, from: startX) else { continue }
        let halfWidth = Feel.Shape.width / 2
        #expect(abs(x - cursor.x) >= halfWidth + Feel.Mind.cursorGap,
                "from \(startX) he settles at \(x), which puts the cursor inside his hit rect")
    }
}

@Test func heSettlesOnWhicheverSideHeArrivesFrom() {
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    let cursor = CGPoint(x: 900, y: 1205)
    let fromLeft = Cat.beside(cursor: cursor, on: bar, from: 200)
    let fromRight = Cat.beside(cursor: cursor, on: bar, from: 1600)
    #expect(fromLeft != nil && fromLeft! < cursor.x, "coming from the left he overshot past it")
    #expect(fromRight != nil && fromRight! > cursor.x, "coming from the right he overshot past it")
}

// MARK: - Task 9: he gets out of the way

@Test func heMovesAsideIfYouPutTheCursorOnHim() {
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 900))
    cat.restLeft = .infinity              // so any move must be the yield
    cat.cursor = CGPoint(x: 900, y: 1215) // right on him

    for _ in 0..<(120 * 20) { cat = Cat.step(cat, world: sky([bar]), dt: dt) }
    let clear = Feel.Shape.width / 2 + Feel.Mind.cursorGap
    #expect(abs(cat.position.x - 900) >= clear - Feel.Physics.arrivalSlop * 3,
            "he stayed under the cursor at \(cat.position.x), so his window is eating clicks")
}

@Test func heDoesNotYieldToACursorThatIsNotOnHim() {
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 900))
    cat.restLeft = .infinity
    cat.cursor = CGPoint(x: 400, y: 1205)

    for _ in 0..<(120 * 20) { cat = Cat.step(cat, world: sky([bar]), dt: dt) }
    #expect(abs(cat.position.x - 900) < 1, "he wandered off for no reason")
}

@Test func heDoesNotYieldWhileYouAreHoldingHim() {
    // Being held puts the cursor on him by definition. Yielding then would fight the drag.
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .held(CGPoint(x: 900, y: 1205))
    cat.cursor = CGPoint(x: 900, y: 1205)
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    cat = Cat.step(cat, world: sky([bar]), dt: dt)
    #expect(cat.intent == nil, "he tried to walk away while you were holding him")
}

@Test func aFrozenCatStaysFrozenEvenIfYouPointAtHim() {
    // Precedence: the freeze is above the yield, so he does not shuffle aside mid-call.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 900))
    cat.listening = true
    cat.cursor = CGPoint(x: 900, y: 1215)

    for _ in 0..<(120 * 5) { cat = Cat.step(cat, world: sky([bar]), dt: dt) }
    #expect(abs(cat.position.x - 900) < 1, "he moved during a call")
    #expect(cat.activity == .alert)
}
