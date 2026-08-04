// v2c: the taste election. Spec: docs/superpowers/specs/2026-08-04-ogi-v2c-taste-design.md
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

// MARK: - The anchors

@Test func noveltyOutranksHabit() {
    // A new window must beat any stale, familiar perch. Staleness and familiarity are the
    // two urges a long-lived perch can max out; novelty must outweigh their sum, or a
    // creature of habit is all he can ever be.
    #expect(Feel.Taste.wNovelty > Feel.Taste.wStale + Feel.Taste.wFamiliar)
}

@Test func theLoungeWinsBareDesksButNotAlways() {
    // The typical bare-floor stroll: no novelty, no height, no cursor, staleness half
    // recovered, a few visits of familiarity, a middling walk. The lounge has to beat it,
    // or the bare desktop stays a pacing pen — and by less than two temperatures, or it
    // always wins and he never strolls at all.
    let stroll = Feel.Taste.wStale * 0.5
        + Feel.Taste.wFamiliar * 0.5
        - Feel.Taste.wEffort * 0.3
    let edge = Feel.Taste.loungeBase - stroll
    #expect(edge > 0, "the lounge loses to an ordinary bare-floor stroll")
    #expect(edge < 2 * Feel.Taste.temperature, "the lounge always wins; he would never stroll")
}

// MARK: - Scoring and the draw

@Test func theDrawFavoursTheHighScoreWithoutGuaranteeingIt() {
    let scores = [1.0, 0.0]
    // At tiny temperature the high score takes essentially the whole roll range.
    #expect(Cat.draw(scores, temperature: 0.01, roll: 0.95) == 0)
    // At huge temperature the two split it nearly evenly, so a roll past the midpoint is
    // the second candidate.
    #expect(Cat.draw(scores, temperature: 100, roll: 0.6) == 1)
    #expect(Cat.draw([], temperature: 1, roll: 0.5) == nil)
}

@Test func theUrgesReadHisMemory() {
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    let floor = surface(.floor, y: 90, from: 0, to: 1920, z: .max)
    let world = sky([bar, floor])
    var cat = CatState(position: CGPoint(x: 900, y: 90))
    cat.support = .grounded(Perch(id: .floor, dx: 900))
    cat.age = 100
    var floorPlace = CatState.Place(firstSeen: -.infinity)
    floorPlace.lastVisit = 100
    floorPlace.visits = 5
    cat.memory[.floor] = floorPlace
    cat.memory[.menuBar] = CatState.Place(firstSeen: 95)

    let here = Cat.score(Cat.Candidate(id: .floor, x: 905, y: 90), from: cat, world: world)
    let fresh = Cat.score(Cat.Candidate(id: .menuBar, x: 905, y: 1205), from: cat, world: world)
    // The menu bar candidate is novel (appeared 5s ago), never visited, and high; the floor
    // under his feet is none of those. This ordering is the entire point of the layer.
    #expect(fresh > here + 0.5, "a brand-new high perch barely outscores the floor he is on")

    let lounge = Cat.score(Cat.Candidate(id: nil, x: 900, y: 90), from: cat, world: world)
    #expect(lounge == Feel.Taste.loungeBase)
}

// MARK: - The election

@Test func theElectionReturnsARoutableTrip() {
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    let ledge = surface(.window(1), y: 1100, from: 400, to: 900)
    let floor = surface(.floor, y: 90, from: 0, to: 1920, z: .max)
    let world = sky([bar, ledge, floor])
    var cat = CatState(position: CGPoint(x: 650, y: 1100))
    cat.support = .grounded(Perch(id: .window(1), dx: 250))
    cat.age = 100
    // Fifty elections: every .go must carry a move routing agreed to, whatever was drawn.
    for _ in 0..<50 {
        guard case .go(let intent)? = Cat.idea(from: cat, on: ledge, world: world) else {
            continue
        }
        #expect(Cat.nextMove(from: cat, on: ledge, toward: intent.destination,
                             x: intent.destinationX, world: world) != nil,
                "the election proposed a trip routing had refused")
    }
}

@Test func aBareDeskElectsTheLoungeMoreOftenThanNot() {
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    let floor = surface(.floor, y: 90, from: 0, to: 1920, z: .max)
    let world = sky([bar, floor])
    var cat = CatState(position: CGPoint(x: 900, y: 90))
    cat.support = .grounded(Perch(id: .floor, dx: 900))
    cat.age = 1000
    var lived = CatState.Place(firstSeen: -.infinity)
    lived.lastVisit = 900
    lived.visits = 10
    cat.memory[.floor] = lived
    cat.memory[.menuBar] = lived    // stale but familiar; unreachable from the floor anyway

    var lounges = 0
    for _ in 0..<200 {
        if case .lounge? = Cat.idea(from: cat, on: floor, world: world) { lounges += 1 }
    }
    #expect(lounges > 100, "the lounge won only \(lounges)/200 bare-desk elections")
    #expect(lounges < 195, "the lounge never loses; he would never stroll at all")
}

// MARK: - Task 1: session memory

@Test func theLaunchWorldIsNeverNovel() {
    // v2b learned this with the window-opened signal: everything is new at launch, so the
    // furniture he wakes into must carry no novelty, ever.
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 900))
    cat = Cat.step(cat, world: sky([bar]), dt: dt)
    #expect(cat.memory[.menuBar]?.firstSeen == -.infinity)
}

@Test func aWindowAppearingLaterIsRemembered() {
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    let win7 = surface(.window(7), y: 800, from: 300, to: 900)
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 900))
    // Live past the launch grace, then the window appears.
    for _ in 0..<Int(10 / dt) { cat = Cat.step(cat, world: sky([bar]), dt: dt) }
    cat = Cat.step(cat, world: sky([bar, win7]), dt: dt)
    let seen = cat.memory[.window(7)]?.firstSeen ?? -1
    #expect(seen > 5, "a window that appeared at age ~10 recorded firstSeen \(seen)")
}

@Test func aVisitCountsOncePerArrival() {
    let bar = surface(.menuBar, y: 1205, from: 0, to: 1920, z: -1)
    var cat = CatState(position: CGPoint(x: 900, y: 1205))
    cat.support = .grounded(Perch(id: .menuBar, dx: 900))
    for _ in 0..<Int(3 / dt) { cat = Cat.step(cat, world: sky([bar]), dt: dt) }
    #expect(cat.memory[.menuBar]?.visits == 1, "standing still re-counted the same visit")
    #expect((cat.memory[.menuBar]?.lastVisit ?? 0) > 2.5, "lastVisit should track while grounded")
}
