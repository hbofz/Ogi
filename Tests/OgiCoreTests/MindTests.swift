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
