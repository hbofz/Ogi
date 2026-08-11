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

// MARK: - Routing refuses the impossible

@Test func heWillNotSetOutForSomewhereHeCanNeverReach() {
    // A bare desktop: the menu bar is 1115pt above the floor and jumpImpulse buys 190pt.
    // Answering ".walk to the x underneath it" paced him across the desktop for ever,
    // re-planning the same impossible trip on every arrival.
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

// MARK: - The scalar

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
    // bout of boredom, over many trials, because restLeft is randomised per settle. An idea
    // is any of the timer's outcomes (an intent, a wash, or a won lounge) and it must be all
    // three: on a bare floor the election mostly elects the lounge, so counting intents alone
    // adds whole lounge spells to the clock and measures the election's taste rather than the
    // timer this test is about.
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
                if cat.intent != nil || cat.activity == .groom || cat.activity == .lounge {
                    break
                }
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
        // A seed per trial, and the SAME two hundred seeds for both arousal levels, so the
        // comparison is between the two settings rather than between two dice rolls.
        for trial in 0..<200 {
            var cat = CatState(position: CGPoint(x: 300, y: 90))
            cat.roll = Roll(seed: UInt64(trial))
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

// MARK: - Nothing on screen can keep him awake

@Test func nothingHappeningOnScreenCanKeepHimAwake() {
    // repose is driven by YOUR idle time and nothing else, so arousal must not be able to
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

// MARK: - The glance

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

// MARK: - A window opening

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

// MARK: - Promotion

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
    // Reachability seen from the mind rather than from the router: a stimulus on an
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

// MARK: - Switching apps

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

// MARK: - Holding still

@Test func typingDoesNotFreezeHim() {
    // The reversal, pinned as precisely as it can be: typing is read by nothing, so the same
    // cat in the same world with the same seed must live exactly the same life whether you are
    // hammering the keyboard or not. A call still stops him; `onlyACallHoldsHimStill` covers it.
    //
    // Asserted as "identical" rather than "he moved a lot", because he can legitimately elect a
    // 45-second lounge and spend a short window doing nothing at all, which is a cat, not a bug.
    let ground = surface(.floor, y: 90, from: 0, to: 1920, z: .max)
    func life(typing: Bool) -> [String] {
        var cat = CatState(position: CGPoint(x: 300, y: 90))
        cat.roll = Roll(seed: 4)
        cat.support = .grounded(Perch(id: .floor, dx: 300))
        cat.typingHard = typing
        cat.restLeft = 0
        var trail: [String] = []
        var last: Activity = .idle
        for _ in 0..<(120 * 120) {
            cat = Cat.step(cat, world: sky([ground]), dt: dt)
            cat.typingHard = typing          // App re-derives it every tick
            if cat.activity != last { trail.append("\(cat.activity)@\(Int(cat.position.x))"); last = cat.activity }
        }
        return trail
    }
    let quiet = life(typing: false)
    let typed = life(typing: true)
    #expect(quiet == typed, "typing changed what he did, so it is still steering him")
    #expect(quiet.count > 3, Comment(rawValue: "he only did \(quiet), so this proves little"))
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
    #expect(cat.activity == .onCall)
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

@Test func onlyACallHoldsHimStill() {
    // Typing used to count too. It was removed on Hamzah's report: you are typing most of the
    // time you are looking at him, so the frozen pose was the one you saw most.
    var cat = CatState(position: .zero)
    #expect(cat.holdingStill == false)
    cat.listening = true
    #expect(cat.holdingStill, "a hot mic must still stop him: the freeze is the privacy tell")
    cat.listening = false
    cat.onCamera = true
    #expect(cat.holdingStill, "a live camera must still stop him")
    cat.onCamera = false
    cat.typingHard = true
    #expect(cat.holdingStill == false, "typing froze him again")
}

@Test func theTypingThresholdsCannotFlicker() {
    #expect(Feel.Mind.typingCalm < Feel.Mind.typingAlert,
            "without hysteresis he flickers in and out of the pose at every pause for breath")
}

// MARK: - Coming to your cursor

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

// MARK: - He gets out of the way

@Test func heMovesAsideIfYouPutTheCursorOnHim() {
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 900))
    cat.restLeft = .infinity              // so any move must be the yield
    cat.cursor = CGPoint(x: 900, y: 1215) // right on him

    let clear = Feel.Shape.width / 2 + Feel.Mind.cursorGap
    for _ in 0..<(120 * 20) {
        cat.cursorStill += dt             // parked there, not sweeping past
        cat = Cat.step(cat, world: sky([bar]), dt: dt)
        // Moving aside is the whole claim; see theYieldMeasuresTheDrawnSpriteNotTheNominalBox.
        if abs(cat.position.x - 900) >= clear - Feel.Physics.arrivalSlop * 3,
           cat.intent == nil { break }
    }
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
    #expect(cat.activity == .onCall)
}

// MARK: - Going home

@Test func whenTheWorldGoesFullscreenHeHeadsHome() {
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    let ledge = win(7, y: 1100, from: 400, to: 900)
    let floor = surface(.floor, y: 90, from: 0, to: 1920, z: .max)
    var cat = CatState(position: CGPoint(x: 650, y: 1100))
    cat.support = .grounded(Perch(id: .window(7), dx: 250))
    cat.stimulus = Stimulus(kind: .goHome, at: CGPoint(x: 1000, y: 1205))

    cat = Cat.step(cat, world: sky([bar, ledge, floor]), dt: dt)
    #expect(cat.intent?.destination == .menuBar, "he did not head home")
    #expect(cat.intent?.destinationX == 1000)
}

@Test func reduceMotionIsAPermanentlyCalmCat() {
    // The one accessibility signal a moving overlay must respect, and it costs no panel and
    // no permission: the user already told the OS. It pins languor, the dial low battery
    // already tunes, so he idles longer, never trots, and settles sooner.
    var s = Sensations()
    s.reduceMotion = true
    #expect(s.languor == 1)
    s.reduceMotion = false
    #expect(s.languor == 0)
}

@Test func buriedHeSurfacesAtTheLipOfWhatBuriedHim() {
    // A window covers his whole ledge, and instead of fleeing somewhere else he surfaces at
    // the covering window's own top edge, head and paws over the lip of the thing that hid
    // him. The climb up its back is unseen by construction (he was hidden, which is the
    // premise) so the visible event is a head appearing over the lip.
    let front = Surface(id: .window(1), z: 0, y: 900, extent: 100...900,
                        solid: [110...890], spans: [110...890],
                        targetable: true, rect: CGRect(x: 100, y: 200, width: 800, height: 700))
    let buried = Surface(id: .window(2), z: 1, y: 600, extent: 200...800,
                         solid: [210...790], spans: [], targetable: true,
                         rect: CGRect(x: 200, y: 300, width: 600, height: 300))
    let floor = surface(.floor, y: 90, from: 0, to: 1920, z: .max)
    let world = sky([front, buried, floor])

    var cat = CatState(position: CGPoint(x: 500, y: 600))
    cat.support = .grounded(Perch(id: .window(2), dx: 300))
    cat.restLeft = .greatestFiniteMagnitude

    var peered = false
    for _ in 0..<Int((Feel.Mind.hiddenPatience + Feel.Timing.peerSeconds + 3) / dt) {
        cat = Cat.step(cat, world: world, dt: dt)
        if cat.activity == .peer { peered = true; break }
    }
    #expect(peered, "he never surfaced at the lip of the window that buried him")
    guard case .grounded(let p) = cat.support else { Issue.record("not grounded"); return }
    #expect(p.id == .window(1), "he peers from the covering window's own top edge")
    #expect(cat.position.y == 900)

    // The look ends by pulling himself up onto the edge, not by holding for ever.
    for _ in 0..<Int((Feel.Timing.peerSeconds + 2) / dt) {
        cat = Cat.step(cat, world: world, dt: dt)
        if cat.activity != .peer { break }
    }
    #expect(cat.activity != .peer, "the peer never ends")
}

@Test func wakingOwesHimAStretch() {
    // The three stretch moments that matter: first unlock of the morning, the Mac
    // waking, power plugged in — are one flag: the first unlock of the morning IS a wake,
    // so no wall clock exists anywhere in the simulation.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 900))
    cat.owed = .stretch
    cat = Cat.step(cat, world: sky([bar]), dt: dt)
    #expect(cat.activity == .stretch)
    #expect(cat.owed == nil, "the show must be consumed or he performs it for ever")

    // It runs its little arc and hands back to ordinary life.
    for _ in 0..<Int((Feel.Timing.stretchSeconds + 0.5) / dt) {
        cat = Cat.step(cat, world: sky([bar]), dt: dt)
    }
    #expect(cat.activity != .stretch, "the stretch never ends")
}

@Test func aFrozenCatDoesNotStretchMidCall() {
    // The flag survives the freeze; the stretch plays after the call ends, not during it.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 900))
    cat.owed = .stretch
    cat.listening = true
    for _ in 0..<120 { cat = Cat.step(cat, world: sky([bar]), dt: dt) }
    #expect(cat.activity == .onCall)
    #expect(cat.owed == .stretch, "the freeze ate the stretch")

    cat.listening = false
    cat = Cat.step(cat, world: sky([bar]), dt: dt)
    #expect(cat.activity == .stretch)
}

@Test func boredomSometimesStretchesInsteadOfWashing() {
    // More in-place behaviours are wanted than the wash, which was the only one
    // that existed. Statistical: over many bouts both must appear, and the wash must stay
    // the commoner.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var stretches = 0, washes = 0
    // A seed per trial: see `boredomAtALipReachesAllThreeNotchPoses`.
    for trial in 0..<200 {
        var cat = CatState(position: CGPoint(x: 900, y: 1205))
        cat.roll = Roll(seed: UInt64(trial))
        cat.support = .grounded(Perch(id: .menuBar, dx: 900))
        cat.repose = .curled          // inPlaceChance 0.95: the roll is almost always in place
        cat.restLeft = 0.01
        for _ in 0..<60 {
            cat = Cat.step(cat, world: sky([bar]), dt: dt)
            if cat.activity == .stretch { stretches += 1; break }
            if cat.activity == .groom { washes += 1; break }
        }
    }
    #expect(stretches > 5, "he never stretches out of boredom (\(stretches)/200)")
    #expect(washes > stretches, "a wash should stay the commoner idle behaviour")
}

@Test func aTapIsAPetNotAScruffing() {
    // Click him and he responds. mouseDown used to go straight
    // to the grab, so the most basic interaction there is read as rough handling. A pet
    // presses him down through the same squash a landing uses, perks him for a glance's
    // beat, and never moves him.
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 900))

    let petted = Cat.pet(cat, at: CGPoint(x: 900, y: 1215))
    #expect(petted.position == cat.position, "a pet moved him")
    if case .held = petted.support { Issue.record("a pet picked him up") }
    #expect(petted.squash > 0, "no press, no response")
    #expect(petted.activity == .alert, "he did not react at all")
    #expect(petted.lookingAt != nil, "his eyes should go to your hand")

    // Mid-air he is not pettable, he is falling.
    cat.support = .falling
    #expect(Cat.pet(cat, at: .zero).squash == 0)
}

// MARK: - The stroke

/// Sweeps your hand back and forth across him for `seconds`, `perTick` points at a time,
/// staying inside his box. `perTick: 0` is a hand resting on him without moving.
///
/// Real motion rather than a "moving" flag on purpose: a jiggling pointer sets such a flag
/// every single tick.
@discardableResult
private func stroke(_ cat: CatState, around: CGPoint, perTick: CGFloat, seconds: TimeInterval,
                    world: Skyline) -> CatState {
    var s = cat
    var offset: CGFloat = 0
    var direction: CGFloat = 1
    for _ in 0..<Int(seconds / dt) {
        if perTick > 0 {
            offset += direction * perTick
            if abs(offset) > 16 { direction = -direction }   // well inside his 52pt box
        }
        s.cursor = CGPoint(x: around.x + offset, y: around.y)
        s.cursorStill = perTick > 0 ? 0 : s.cursorStill + dt
        s = Cat.step(s, world: world, dt: dt)
    }
    return s
}

/// A comfortable sweep: 4pt a tick is 480pt/s, which is an unhurried hand at 120Hz and three
/// times `strokeDecay`.
private let strokePace: CGFloat = 4

@Test func movingYourHandOverHimIsAStroke() {
    // Not a click and not a drag: the cursor crossing his body with no button down is how you
    // pet a real cat, and it is the one gesture that costs nothing on a desktop.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 900))
    cat.restLeft = .infinity

    cat = stroke(cat, around: CGPoint(x: 900, y: 1215), perTick: strokePace,
                 seconds: 0.5, world: sky([bar]))
    #expect(cat.activity == .stroked, "he ignored being petted (\(cat.activity))")
    #expect(abs(cat.position.x - 900) < 1, "a stroke moved him")
}

@Test func aGentleStrokeStillCounts() {
    // `strokeDecay` is a floor on how fast your hand has to move, and it sits between two
    // things that are only three times apart: the jiggle in
    // `aJigglingCursorStillGetsHimToMove` is 48pt/s and has to fail, and an unhurried hand
    // petting a cat is not much quicker than 150. Set the floor by the gentle stroke, not by
    // the brisk one, or petting him properly means scrubbing at him.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 900))
    cat.restLeft = .infinity

    // 0.7pt a tick at 120Hz: 84pt/s, a slow drag back and forth across a 50pt cat.
    cat = stroke(cat, around: CGPoint(x: 900, y: 1215), perTick: 0.7,
                 seconds: 2, world: sky([bar]))
    #expect(cat.activity == .stroked, "a gentle hand did not read as petting him")
}

@Test func youCanPetHimWhileHeIsWashingOrSprawled() {
    // A wash and a sprawl are not performances, they are what he does when nothing is
    // happening, and a hand arriving IS something happening. The stroke sat below every
    // in-place hold so that a jolt of electricity could not be cancelled by a passing cursor,
    // correct for the zap and badly wrong for these two, because a lounge holds for 45 seconds
    // and he was unpettable for all of it.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    for busy in [Activity.groom, .lounge] {
        var cat = CatState(position: CGPoint(x: 900, y: 1205))
        cat.support = .grounded(Perch(id: .menuBar, dx: 900))
        cat.restLeft = .infinity
        cat.activity = busy

        cat = stroke(cat, around: CGPoint(x: 900, y: 1215), perTick: strokePace,
                     seconds: 0.5, world: sky([bar]))
        #expect(cat.activity == .stroked, "a \(busy) cat cannot be petted (\(cat.activity))")
    }
}

@Test func aCursorPassingOverHimIsNotAStroke() {
    // The pointer crosses him on its way somewhere else constantly. That is traffic, not
    // affection, and a cat who shut his eyes every time it happened would be a twitch.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 900))
    cat.restLeft = .infinity

    // One flick across him and straight off again: about a fiftieth of a second of contact.
    cat = stroke(cat, around: CGPoint(x: 900, y: 1215), perTick: strokePace,
                 seconds: dt * 2, world: sky([bar]))
    #expect(cat.activity != .stroked, "a pointer merely crossing him read as a pet")
}

@Test func aStillCursorOnHimIsStillYouWantingWhatIsUnderneath() {
    // The collision this whole feature has to survive. His window swallows clicks while the
    // pointer is inside his hit rect, so a PARKED cursor still has to move him aside — the
    // yield is not weakened, it is only told apart from a stroke by whether your hand moves.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 900))
    cat.restLeft = .infinity

    cat = stroke(cat, around: CGPoint(x: 900, y: 1215), perTick: 0,
                 seconds: Feel.Mind.yieldPatience * 1.5, world: sky([bar]))
    #expect(cat.intent != nil, "he sat under a parked cursor eating clicks")
}

@Test func heDoesNotWalkOffMidStroke() {
    // The other half of the same collision, and the one that would read as broken: stroke him
    // for longer than `yieldPatience` and the yield must not fire underneath the pet.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 900))
    cat.restLeft = .infinity

    cat = stroke(cat, around: CGPoint(x: 900, y: 1215), perTick: strokePace,
                 seconds: Feel.Mind.yieldPatience * 3, world: sky([bar]))
    #expect(cat.activity == .stroked, "he broke off being petted (\(cat.activity))")
    #expect(cat.intent == nil, "he walked away from a hand that was still stroking him")
}

@Test func aPauseMidStrokeDoesNotEndIt() {
    // Your hand stops at the end of every stroke before it goes back for the next one. If
    // that beat dropped him out of the pose he would blink in and out of it the whole time.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 900))
    cat.restLeft = .infinity
    let at = CGPoint(x: 900, y: 1215)

    cat = stroke(cat, around: at, perTick: strokePace, seconds: 0.5, world: sky([bar]))
    cat = stroke(cat, around: at, perTick: 0, seconds: Feel.Mind.strokeGrace * 0.6, world: sky([bar]))
    #expect(cat.activity == .stroked, "a pause between strokes ended the pet")
}

@Test func takingYourHandAwayEndsTheStroke() {
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 900))
    cat.restLeft = .infinity

    cat = stroke(cat, around: CGPoint(x: 900, y: 1215), perTick: strokePace,
                 seconds: 0.5, world: sky([bar]))
    #expect(cat.activity == .stroked)
    // Off him entirely, which is a reset rather than a bleed.
    cat = stroke(cat, around: CGPoint(x: 200, y: 1215), perTick: strokePace,
                 seconds: dt * 2, world: sky([bar]))
    #expect(cat.activity != .stroked, "he stayed blissed out after your hand left")
    #expect(cat.strokeTravel == 0, "leaving him has to reset the bank, not bleed it")
}

@Test func aCatBeingCarriedIsNotBeingStroked() {
    // Being held puts the cursor on him by definition, and it is already a whole other
    // interaction. Same guard the freeze and the yield rely on.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .held(CGPoint(x: 900, y: 1215))

    cat = stroke(cat, around: CGPoint(x: 900, y: 1215), perTick: strokePace,
                 seconds: 0.5, world: sky([bar]))
    #expect(cat.activity == .scruffed, "he is dangling from your hand, not enjoying it")
}

@Test func heDoesNotBreakOffAShowToBeStroked() {
    // A jolt of electricity through a cat is the gag; a hand on him mid-zap must not cancel
    // it. Same rule every other interrupt in `standing` already obeys.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 900))
    cat.activity = .zap
    cat.restLeft = .infinity

    cat = stroke(cat, around: CGPoint(x: 900, y: 1215), perTick: strokePace,
                 seconds: Feel.Timing.zapSeconds * 0.5, world: sky([bar]))
    #expect(cat.activity == .zap, "a stroke assassinated the zap")
}

@Test func aCoveredScreenGetsNoStrolls() {
    // After the retreat the world is still there — the fullscreen window's top edge, the menu
    // bar, the floor — and ordinary boredom would put him back on top of the movie within a
    // rest or two. While the screen is covered he keeps to himself. Presentations must never
    // gain a cat.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    let face = win(7, y: 1205, from: 0, to: 1920)
    let floor = surface(.floor, y: 90, from: 0, to: 1920, z: .max)
    var cat = CatState(position: CGPoint(x: 1000, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 1000))
    cat.screenCovered = true
    cat.restLeft = 0.1

    for _ in 0..<(120 * 60) { cat = Cat.step(cat, world: sky([bar, face, floor]), dt: dt) }
    #expect(abs(cat.position.x - 1000) < 1, "he went for a stroll across a covered screen")
}

@Test func aWindowOpeningOverACoveredScreenIsOnlyALook() {
    // A floating panel over fullscreen video is a real window and a real stimulus. He may
    // look; crossing the movie to investigate is what the gate exists to refuse.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    let panel = win(9, y: 800, from: 600, to: 1000)
    var cat = CatState(position: CGPoint(x: 1000, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 1000))
    cat.screenCovered = true
    cat.arousal = 1
    cat.stimulus = Stimulus(kind: .windowOpened, at: CGPoint(x: 800, y: 800))

    cat = Cat.step(cat, world: sky([bar, panel]), dt: dt)
    #expect(cat.lookingAt != nil, "he should still look")
    #expect(cat.intent == nil, "he set out across a covered screen to investigate")
}

@Test func aRetreatCannotBeEatenByALesserStimulus() {
    // The slot is one deep and App writes it from three places. An app activating between the
    // fullscreen retreat being written and the next tick would silently replace it — and apps
    // activate precisely when something goes fullscreen or the machine sleeps. The victims
    // would be the retreat and the pre-sleep settle, the two behaviours hardest to observe.
    var cat = CatState(position: CGPoint(x: 300, y: 1205))
    cat.receive(Stimulus(kind: .goHome, at: CGPoint(x: 1000, y: 1205)))
    cat.receive(Stimulus(kind: .appSwitched, at: CGPoint(x: 500, y: 900)))
    #expect(cat.stimulus?.kind == .goHome, "the app switch ate the retreat")

    // The other way round the retreat wins the slot: it is an instruction, not a surprise.
    var late = CatState(position: CGPoint(x: 300, y: 1205))
    late.receive(Stimulus(kind: .windowOpened, at: CGPoint(x: 500, y: 900)))
    late.receive(Stimulus(kind: .goHome, at: CGPoint(x: 1000, y: 1205)))
    #expect(late.stimulus?.kind == .goHome)
}

@Test func goingHomeDoesNotStirHimUp() {
    // .goHome is an instruction, not a surprise. If it could raise arousal it could push him
    // over investigateAbove and make the NEXT window that opens a trip, which is a reaction
    // to the wrong thing.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 300, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 300))
    cat.stimulus = Stimulus(kind: .goHome, at: CGPoint(x: 1000, y: 1205))
    cat = Cat.step(cat, world: sky([bar]), dt: dt)
    #expect(cat.arousal == 0)
}

@Test func goingHomeOverridesWhateverHeWasDoing() {
    // Unlike a window opening, which never re-targets a trip already underway. The furniture he
    // was heading for is the thing that is about to be covered.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    let ledge = win(7, y: 1100, from: 400, to: 900)
    var cat = CatState(position: CGPoint(x: 650, y: 1100))
    cat.support = .grounded(Perch(id: .window(7), dx: 250))
    cat.intent = Intent(destination: .window(7), destinationX: 500, move: .walk(500))
    cat.stimulus = Stimulus(kind: .goHome, at: CGPoint(x: 1000, y: 1205))

    cat = Cat.step(cat, world: sky([bar, ledge]), dt: dt)
    #expect(cat.intent?.destination == .menuBar)
}

@Test func heSprawlsRatherThanPacingWhenHomeIsOutOfReach() {
    // From the floor the notch is 1115pt up against 190pt of rise. That is unroutable, so no
    // intent forms and he settles instead of walking back and forth underneath it for ever.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    let floor = surface(.floor, y: 90, from: 0, to: 1920, z: .max)
    var cat = CatState(position: CGPoint(x: 300, y: 90))
    cat.support = .grounded(Perch(id: .floor, dx: 300))
    cat.stimulus = Stimulus(kind: .goHome, at: CGPoint(x: 1000, y: 1205))

    cat = Cat.step(cat, world: sky([bar, floor]), dt: dt)
    #expect(cat.intent?.destination != .menuBar, "he set out for a menu bar he cannot reach")
}

// MARK: - The stale pose

@Test func aCurledCatDoesNotStandUpForOneFrameAfterALanding() {
    // The landing timeout hard-codes .idle instead of the pose that matches how settled he is,
    // so a curled cat renders exactly one frame standing before the next tick corrects him.
    // Watched frame by frame rather than at the end, because a one-frame defect is invisible
    // to an assertion about where he finishes.
    let ground = surface(.floor, y: 90, from: 0, to: 1920, z: .max)
    var cat = CatState(position: CGPoint(x: 300, y: 400))
    cat.repose = .curled

    var sawIdle = false
    for _ in 0..<(120 * 10) {
        cat = Cat.step(cat, world: sky([ground]), dt: dt)
        if cat.activity == .idle { sawIdle = true }
    }
    #expect(cat.activity == .curl, "he ended up \(cat.activity) rather than curled")
    #expect(!sawIdle, "he stood up for a frame on the way out of the landing")
}

// MARK: - A cursor floating in mid-air, nowhere he can stand

@Test func heIgnoresACursorFloatingWellBelowHisLedge() {
    // Coming over only ever walks him along the ledge he is already on, so "near him" has to be
    // a radius. Measured across x alone, a cursor parked in the middle of a small window 600pt
    // below counted as near, and he shuffled sideways to stand directly above a pointer he was
    // nowhere close to: aligned with you rather than next to you.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    let mini = win(7, y: 700, from: 800, to: 1100)
    let floor = surface(.floor, y: 90, from: 0, to: 1920, z: .max)
    var cat = CatState(position: CGPoint(x: 800, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 800))
    cat.cursor = CGPoint(x: 900, y: 600)          // inside the mini window's body, 605pt away
    cat.cursorStill = Feel.Mind.cursorStillSeconds + 1
    cat.restLeft = .infinity                      // so any intent must be the cursor's doing

    cat = Cat.step(cat, world: sky([bar, mini, floor]), dt: dt)
    #expect(cat.intent == nil,
            "he set off for a cursor he cannot get anywhere near: \(String(describing: cat.intent))")
}

@Test func heNeverLeavesHisLedgeForYourCursor() {
    // The reassuring half, and it is structural rather than a tuning accident: coming over
    // emits a walk on the surface he is standing on and nothing else, so it can never become a
    // climb he falls off. If this ever needs to route across surfaces it belongs with the rest
    // of the routing, not bolted onto a stroll.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    let mini = win(7, y: 1150, from: 700, to: 1100)
    var cat = CatState(position: CGPoint(x: 800, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 800))
    cat.cursor = CGPoint(x: 950, y: 1150)         // on the little window just below him
    cat.cursorStill = Feel.Mind.cursorStillSeconds + 1
    cat.restLeft = .infinity

    cat = Cat.step(cat, world: sky([bar, mini]), dt: dt)
    if let intent = cat.intent {
        #expect(intent.destination == .menuBar, "coming over routed him off his own ledge")
        if case .walk = intent.move {} else {
            Issue.record("coming over produced \(intent.move) rather than a walk")
        }
    }
}

// MARK: - The glance has to be visible

@Test func noticingAWindowIsSomethingYouCanActuallySee() {
    // Moving his eyes is the whole of a glance in code and almost none of it on screen. He has
    // to perk up as well, or "he noticed the window you opened" reads as him doing nothing.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 300, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 300))
    cat.restLeft = .infinity
    cat.stimulus = Stimulus(kind: .windowOpened, at: CGPoint(x: 1500, y: 900))

    cat = Cat.step(cat, world: sky([bar]), dt: dt)
    #expect(cat.activity == .alert, "he noticed it without showing it: \(cat.activity)")

    // ...and it is a beat, not a new resting pose.
    for _ in 0..<Int(Feel.Mind.glanceSeconds / dt + 4) {
        cat = Cat.step(cat, world: sky([bar]), dt: dt)
    }
    #expect(cat.activity != .alert, "he is still staring; the glance never ended")
}

@Test func aStaleAlertAfterTheMicGoesQuietStillGetsCleared() {
    // The exclusion that lets a glance play must not also resurrect the 12s freeze: the
    // hold-still branch returns early, so an alert left behind when the mic goes off has to be
    // cleared here. glanceLeft is what tells the two apart.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 300, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 300))
    cat.listening = true
    for _ in 0..<(120 * 2) { cat = Cat.step(cat, world: sky([bar]), dt: dt) }
    #expect(cat.activity == .onCall, "fixture: the mic should have frozen him")

    cat.listening = false
    cat = Cat.step(cat, world: sky([bar]), dt: dt)
    // The stale pose is `.onCall` rather than `.alert`, and it has to be cleared for the same
    // reason: the hold-still branch returns early, so nothing else would.
    #expect(cat.activity != .onCall && cat.activity != .alert,
            "he stayed in the call pose after the mic went quiet")
}

@Test func aGlanceDoesNotInterruptAWalkHeIsAlreadyOn() {
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 300, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 300))
    cat.intent = Intent(destination: .menuBar, destinationX: 900, move: .walk(900))
    cat.activity = .walk
    cat.stimulus = Stimulus(kind: .windowOpened, at: CGPoint(x: 1500, y: 900))

    cat = Cat.step(cat, world: sky([bar]), dt: dt)
    #expect(cat.activity == .walk, "the glance stopped him mid-walk")
    #expect(cat.lookingAt != nil, "he should still have looked")
}

@Test func pointingAtHimDoesNotMakeHimScoot() {
    // Coming over needs a full minute of cursor stillness and the yield needed none, so a
    // cursor arriving near him always lost that race and read as avoidance.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 900))
    cat.restLeft = .infinity
    cat.cursor = CGPoint(x: 900, y: 1215)
    cat.cursorStill = 0                   // you have only just arrived

    for _ in 0..<Int(Feel.Mind.yieldPatience * 0.8 / dt) {
        cat.cursorStill += dt
        cat = Cat.step(cat, world: sky([bar]), dt: dt)
    }
    #expect(cat.intent == nil, "he bolted the moment you pointed at him")
    #expect(abs(cat.position.x - 900) < 1)
}

@Test func aCursorFarBelowHimIsNotInHisWay() {
    // The yield measured x alone, so a cursor anywhere vertically counted as being on him. Same
    // mistake as the approach had, in the other half of the feature.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    let floor = surface(.floor, y: 90, from: 0, to: 1920, z: .max)
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 900))
    cat.restLeft = .infinity
    cat.cursor = CGPoint(x: 900, y: 400)  // directly below him, 800pt down
    cat.cursorStill = 999

    for _ in 0..<(120 * 10) {
        cat.cursorStill += dt
        cat = Cat.step(cat, world: sky([bar, floor]), dt: dt)
    }
    #expect(abs(cat.position.x - 900) < 1, "he moved aside for a cursor nowhere near him")
}

@Test func hisBoxAgreesWithTheRectThatSwallowsClicks() {
    // App.hitRect is what actually decides whether his window eats your clicks: the DRAWN
    // rect, padded by hitPad. If these two drift he either moves aside for a cursor that was
    // never on him, or sits on one that is. Built from the nominal 52×34 while the sprite is
    // normalised on eye width and usually larger, a cursor parked on his ear swallowed clicks
    // for ever and the yield never saw it.
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 900))

    // Before the first render there is no drawn rect and the nominal figure stands in.
    let nominal = CGRect(x: cat.position.x - Feel.Shape.width / 2, y: cat.position.y,
                         width: Feel.Shape.width, height: Feel.Shape.height)
    #expect(Cat.hisBox(cat) == nominal.insetBy(dx: -Feel.Shape.hitPad, dy: -Feel.Shape.hitPad))

    // Once he has been drawn, the drawn rect is the truth.
    let drawn = CGRect(x: 855, y: 1205, width: 90, height: 60)
    cat.drawnBox = drawn
    #expect(Cat.hisBox(cat) == drawn.insetBy(dx: -Feel.Shape.hitPad, dy: -Feel.Shape.hitPad),
            "his box has to be exactly the rect that swallows a click")
}

@Test func theYieldMeasuresTheDrawnSpriteNotTheNominalBox() {
    // A cursor can sit on a drawn part of him that the nominal box cannot see. That cursor
    // is inside the rect that eats clicks, so he has to treat it as being in his way.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 900))
    cat.restLeft = .infinity
    cat.drawnBox = CGRect(x: 855, y: 1205, width: 90, height: 60)
    cat.cursor = CGPoint(x: 940, y: 1215)   // on his drawn rump, outside the nominal box

    for _ in 0..<(120 * 20) {
        cat.cursorStill += dt
        cat = Cat.step(cat, world: sky([bar]), dt: dt)
        // Moving aside is the whole claim. Running the clock on after he has done it lets a
        // later random stroll be mid-walk at the cutoff, which fails one run in eight.
        if abs(cat.position.x - 940) >= 45 + Feel.Mind.cursorGap - Feel.Physics.arrivalSlop * 3,
           cat.intent == nil { break }
    }
    #expect(abs(cat.position.x - 940) >= 45 + Feel.Mind.cursorGap - Feel.Physics.arrivalSlop * 3,
            "he stayed at \(cat.position.x) with the cursor on his drawn body, eating clicks")
}

@Test func theSettleClearanceKeepsTheCursorOutOfTheClickRect() {
    // He aims to stop width/2 + cursorGap from the cursor and overshoots a few points toward
    // it, and the click rect reaches hitPad past his ink. If the gap cannot absorb both, the
    // settle parks the cursor inside the rect that eats clicks — at 8 it did, by one point.
    #expect(Feel.Mind.cursorGap > Feel.Shape.hitPad + Feel.Physics.arrivalSlop,
            "cursorGap has no room for the click padding plus the arrival overshoot")
}

// MARK: - He wants to be seen

/// A ledge whose middle is covered by a window in front of it: solid all the way across, but
/// only the two ends are visible. This is exactly what `spans` means.
private func partlyCoveredLedge() -> Surface {
    Surface(id: .window(1), z: 1, y: 600, extent: 0...1000,
            solid: [0...1000], spans: [0...300, 700...1000], targetable: true, rect: nil)
}

@Test func spansIsWhatTellsHimHeIsHidden() {
    let ledge = partlyCoveredLedge()
    let world = sky([ledge, surface(.floor, y: 90, from: 0, to: 1920, z: .max)])
    var cat = CatState(position: CGPoint(x: 500, y: 600))
    cat.support = .grounded(Perch(id: .window(1), dx: 500))
    #expect(Cat.isHidden(cat, world: world), "x=500 is behind the window in front")

    cat.position.x = 150
    #expect(!Cat.isHidden(cat, world: world), "x=150 is on a visible part of the ledge")
}

@Test func heStepsOutFromBehindAWindow() {
    let ledge = partlyCoveredLedge()
    let world = sky([ledge, surface(.floor, y: 90, from: 0, to: 1920, z: .max)])
    var cat = CatState(position: CGPoint(x: 500, y: 600))
    cat.support = .grounded(Perch(id: .window(1), dx: 500))
    cat.restLeft = .infinity          // so anything he does is about being hidden

    for _ in 0..<Int((Feel.Mind.hiddenPatience + 20) / dt) {
        cat = Cat.step(cat, world: world, dt: dt)
        // Stepping out is the whole claim. Running the clock on after he has done it lets a
        // later random wander be mid-crossing of the covered middle at the cutoff, which fails
        // about one run in eight.
        if !Cat.isHidden(cat, world: world), cat.intent == nil { break }
    }
    #expect(!Cat.isHidden(cat, world: world),
            "he stayed behind the window at x=\(cat.position.x)")
}

@Test func heDoesNotBoltTheInstantAWindowCoversHim() {
    // A window raised over him for a moment should not start a stampede.
    let ledge = partlyCoveredLedge()
    let world = sky([ledge, surface(.floor, y: 90, from: 0, to: 1920, z: .max)])
    var cat = CatState(position: CGPoint(x: 500, y: 600))
    cat.support = .grounded(Perch(id: .window(1), dx: 500))
    cat.restLeft = .infinity

    for _ in 0..<Int(Feel.Mind.hiddenPatience * 0.5 / dt) {
        cat = Cat.step(cat, world: world, dt: dt)
    }
    #expect(cat.intent == nil, "he moved before his patience ran out")
}

@Test func heLeavesTheLedgeEntirelyIfAllOfItIsCovered() {
    // Nothing of his own ledge showing, so stepping along it cannot help.
    let buried = Surface(id: .window(1), z: 1, y: 600, extent: 0...1000,
                         solid: [0...1000], spans: [], targetable: true, rect: nil)
    let floor = surface(.floor, y: 90, from: 0, to: 1920, z: .max)
    var cat = CatState(position: CGPoint(x: 500, y: 600))
    cat.support = .grounded(Perch(id: .window(1), dx: 500))
    cat.restLeft = .infinity

    var left = false
    for _ in 0..<Int((Feel.Mind.hiddenPatience + 30) / dt) {
        cat = Cat.step(cat, world: sky([buried, floor]), dt: dt)
        if case .grounded(let p) = cat.support, p.id != .window(1) { left = true; break }
    }
    #expect(left, "his whole ledge was covered and he stayed on it")
}

@Test func beingHiddenBeatsAnOrdinaryIdea() {
    // He wants to be seen more than he wants anything else, so this outranks the boredom timer.
    let ledge = partlyCoveredLedge()
    let world = sky([ledge, surface(.floor, y: 90, from: 0, to: 1920, z: .max)])
    var cat = CatState(position: CGPoint(x: 500, y: 600))
    cat.support = .grounded(Perch(id: .window(1), dx: 500))
    cat.hiddenFor = Feel.Mind.hiddenPatience + 1
    cat.restLeft = 0                  // boredom is due this very tick

    cat = Cat.step(cat, world: world, dt: dt)
    guard let intent = cat.intent else { Issue.record("he did nothing at all"); return }
    // Somewhere visible, and not standing on the lip of it: the destination is inset from the
    // span's ends so he does not arrive already deciding whether to step off.
    let visible = ledge.spans.first { $0.contains(intent.destinationX) }
    guard let span = visible else {
        Issue.record("he headed for \(intent.destinationX), which is still behind the window")
        return
    }
    #expect(intent.destinationX - span.lowerBound >= Feel.Physics.edgeApproach - 0.01)
    #expect(span.upperBound - intent.destinationX >= Feel.Physics.edgeApproach - 0.01)
}

// MARK: - Deliberate destinations stay off the lip

@Test func aDeliberateDestinationIsNeverOnTheVeryEndOfALedge() {
    // The menu bar's outer ends were unreachable while destinations were uniform points inside
    // a span. Every destination the mind layer picks goes through nearestSpanX, which CLAMPS to
    // the boundary, so the ends went from never to routine: a walk to x=5 followed by a step
    // off the left end and a drop to the desktop.
    let spans = [CGFloat(0)...CGFloat(1920)]
    for want in [CGFloat(-500), -1, 0, 5, 960, 1919, 1921, 5000] {
        guard let x = Cat.standingRoom(near: want, in: spans) else {
            Issue.record("no standing room at all for \(want)"); continue
        }
        #expect(x >= Feel.Physics.edgeApproach,
                "want \(want) put him at \(x), on the left lip")
        #expect(x <= 1920 - Feel.Physics.edgeApproach,
                "want \(want) put him at \(x), on the right lip")
    }
}

@Test func aShortLedgeGivesHimItsMiddle() {
    // Narrower than two insets there is nowhere that is not near an end, so the honest answer is
    // the middle rather than nothing.
    let narrow = [CGFloat(500)...CGFloat(530)]
    #expect(Cat.standingRoom(near: 500, in: narrow) == 515)
    #expect(Cat.standingRoom(near: 900, in: narrow) == 515)
}

@Test func comingToYourCursorDoesNotParkHimOnALip() {
    // The specific path that caught it: cursor near the far left of the menu bar.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    guard let x = Cat.beside(cursor: CGPoint(x: 12, y: 1205), on: bar, from: 800) else {
        Issue.record("no spot beside a cursor at the left end"); return
    }
    #expect(x >= Feel.Physics.edgeApproach, "he settles at \(x), on the lip")
}

@Test func stepOffTargetsAreUnaffected() {
    // nearestSpanX still exists and the router still uses it. Insetting THAT would move where he
    // steps off a ledge, which is the router's business and not this layer's.
    let spans = [CGFloat(0)...CGFloat(1920)]
    #expect(Cat.nearestSpanX(to: -50, in: spans) == 0, "the router's clamp must stay exact")
    #expect(Cat.nearestSpanX(to: 5000, in: spans) == 1920)
}

@Test func aJigglingCursorStillGetsHimToMove() {
    // The yield used to hang off cursorStill, which a pointer moving slightly in place resets
    // for ever. He sat under it eating clicks for fourteen seconds. The question is how long it
    // has been ON him, not how long it has been still.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 900))
    cat.restLeft = .infinity

    var jiggle: CGFloat = 0
    for _ in 0..<(120 * 20) {
        jiggle = jiggle > 1 ? 0 : jiggle + 0.4     // never still, always on him
        cat.cursor = CGPoint(x: 900 + jiggle, y: 1215)
        cat.cursorStill = 0                        // exactly what a moving pointer does
        cat = Cat.step(cat, world: sky([bar]), dt: dt)
    }
    let clear = Feel.Shape.width / 2 + Feel.Mind.cursorGap
    #expect(abs(cat.position.x - 900) >= clear - Feel.Physics.arrivalSlop * 3,
            "he stayed under a jiggling pointer at \(cat.position.x), eating every click")
}

/// The yield sets an intent and returns; the sleep gate below it opens by clearing the intent.
/// A sleeping cat under a parked cursor therefore flipped between the two at the full link
/// rate and never moved a point. Sleep is the hard stop, so it wins.
@MainActor
@Test func aSleepingCatUnderAParkedCursorDoesNotFlap() {
    let world = World.build(windows: [], screen: screen, ownPID: 99)
    let bar = world.surface(.menuBar)!
    var s = CatState(position: CGPoint(x: 400, y: bar.y))
    s.support = .grounded(Perch(id: .menuBar, dx: 400 - bar.extent.lowerBound))
    s.repose = .asleep
    s.activity = .sleep
    s.cursor = CGPoint(x: 400, y: bar.y + 10)
    s.cursorOnHimFor = Feel.Mind.yieldPatience * 3

    var flips = 0
    var last = s.activity
    let startX = s.position.x
    for _ in 0..<Int(5 / Feel.Timing.fixedDT) {
        s = Cat.step(s, world: world, dt: Feel.Timing.fixedDT)
        s.cursorOnHimFor += Feel.Timing.fixedDT
        if s.activity != last { flips += 1; last = s.activity }
    }
    #expect(flips <= 2, Comment(rawValue: "\(flips) activity changes in 5s of a sleeping cat"))
    #expect(s.activity == .sleep, "he did not stay asleep")
    #expect(s.position.x == startX, "he moved while asleep")
}

/// A sleeping cat sleeps through a keystroke. Waking used to be instant: any HID event drops
/// the idle clock to zero, the ladder says awake, and he snapped upright from a dead sleep.
/// Hamzah's word for it was scary. A wake has to be earned now, and the ladder itself is what
/// this pins: the gate lives in `OgiApp`, but the numbers it uses live here.
@Test func wakingTakesSustainedUseNotOneKeystroke() {
    // The shape of the gate: continuous use for `wakeSettle`, where any gap longer than
    // `stirWindow` restarts the count.
    #expect(Feel.Timing.wakeSettle > Feel.Timing.stirWindow,
            "a single burst inside one stir window would earn a wake on its own")
    #expect(Feel.Timing.stirWindow >= 1.5,
            "shorter than this and an ordinary pause between keystrokes restarts the count")
    #expect(Feel.Timing.wakeSettle <= 8,
            "longer than this and coming back to the machine leaves him asleep in your face")

    // And the ladder it gates is still the one the tick uses: asleep well past ten minutes,
    // awake the instant the idle clock is low. The gate is what stops that being immediate.
    #expect(Repose.from(idleSeconds: 601, scale: 1) == .asleep)
    #expect(Repose.from(idleSeconds: 0, scale: 1) == .awake)
}

/// The rule itself, driven second by second. A sleeping cat has to sleep through a keystroke:
/// waking used to be instant, because any HID event drops the idle clock to zero and the ladder
/// says awake on the very next tick.
@MainActor
@Test func oneKeystrokeDoesNotWakeHimButComingBackDoes() {
    var since: CFTimeInterval?

    // One key, then you go back to reading. Idle climbs, and he sleeps on.
    var woke = false
    for t in stride(from: 0.0, through: 30.0, by: 0.25) {
        let idle = t == 0 ? 0 : t                       // one event at t=0, nothing after
        if OgiApp.wakeIsEarned(idle: idle, now: t, since: &since) { woke = true }
    }
    #expect(!woke, "a single keystroke woke him")

    // A short burst and then you go back to reading. The idle clock only climbs after you
    // stop, so a burst counts as its own length plus a stir window; the bar has to clear both.
    since = nil
    woke = false
    for t in stride(from: 0.0, through: 30.0, by: 0.25) {
        let idle = t < 2 ? 0.1 : t - 2          // two seconds of typing, then quiet
        if OgiApp.wakeIsEarned(idle: idle, now: t, since: &since) { woke = true }
    }
    #expect(!woke, "a two-second burst of typing woke him")

    // Actually coming back to the machine: continuous use.
    since = nil
    var wokeAt: CFTimeInterval?
    for t in stride(from: 0.0, through: 30.0, by: 0.25) {
        if OgiApp.wakeIsEarned(idle: 0.1, now: t, since: &since), wokeAt == nil { wokeAt = t }
    }
    #expect(wokeAt != nil, "he never woke up, which is worse than waking too easily")
    #expect(wokeAt! >= Feel.Timing.wakeSettle - 0.3 && wokeAt! <= Feel.Timing.wakeSettle + 0.3,
            Comment(rawValue: "woke after \(wokeAt!)s, expected about \(Feel.Timing.wakeSettle)s"))
}
