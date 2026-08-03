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
    Surface(id: id, z: z, y: y, extent: from...to, spans: [from...to], targetable: true)
}

private let dt = Feel.Timing.fixedDT

/// Parked on a wide surface with an explicit goal, so nothing is left to chance.
private func standing(at x: CGFloat, on s: Surface) -> CatState {
    var cat = CatState(position: CGPoint(x: x, y: s.y))
    cat.support = .grounded(Perch(id: s.id, dx: x - s.extent.lowerBound))
    cat.restLeft = .greatestFiniteMagnitude   // never invents its own plans mid-test
    return cat
}

@Test func heWalksToHisDestinationAndStops() {
    let ledge = surface(.window(1), y: 500, from: 0, to: 800)
    var cat = standing(at: 100, on: ledge)
    cat.goal = .walkTo(400)

    for _ in 0..<Int(20 / dt) {
        cat = Cat.step(cat, world: sky([ledge]), dt: dt)
        if cat.goal == nil { break }
    }
    #expect(abs(cat.position.x - 400) < Feel.Physics.arrivalSlop + 1)
    #expect(cat.activity == .idle, "he should settle once he arrives")
}

@Test func heFacesTheDirectionHeWalks() {
    let ledge = surface(.window(1), y: 500, from: 0, to: 800)
    var cat = standing(at: 400, on: ledge)
    cat.goal = .walkTo(100)
    cat = Cat.step(cat, world: sky([ledge]), dt: dt)
    #expect(cat.facing == -1)

    cat.goal = .walkTo(700)
    cat = Cat.step(cat, world: sky([ledge]), dt: dt)
    #expect(cat.facing == 1)
}

@Test func walkingIsClampedToTheSurface() {
    // He should never walk off the end just because a destination was out of bounds.
    let ledge = surface(.window(1), y: 500, from: 100, to: 300)
    var cat = standing(at: 200, on: ledge)
    cat.goal = .walkTo(9999)

    for _ in 0..<Int(30 / dt) { cat = Cat.step(cat, world: sky([ledge]), dt: dt) }
    guard case .grounded(let perch) = cat.support else {
        Issue.record("he walked off a surface he was clamped to")
        return
    }
    #expect(perch.dx <= ledge.extent.length + 0.001)
    #expect(cat.position.x <= 300.001)
}

@Test func everyJumpSpendsTheFullAnticipationInCrouch() {
    // Non-negotiable, per the manifesto. This is the difference between a cat and a
    // teleporting rectangle, and it is exactly the sort of thing an optimisation deletes.
    let here = surface(.window(1), y: 500, from: 0, to: 400)
    let there = surface(.window(2), y: 560, from: 500, to: 900, z: 1)
    var cat = standing(at: 300, on: here)
    cat.goal = .jumpTo(.window(2), 600)

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
    cat.goal = .jumpTo(.window(2), 700)

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
    #expect(abs(cat.position.x - 700) < 120)
}

@Test func aJumpToAVanishedSurfaceDoesNotStrandHim() {
    let here = surface(.window(1), y: 500, from: 0, to: 400)
    var cat = standing(at: 300, on: here)
    cat.goal = .jumpTo(.window(99), 700)   // target closed during the crouch

    // Past the crouch, but before he has had time to think of something else to do.
    for _ in 0..<Int(0.3 / dt) { cat = Cat.step(cat, world: sky([here]), dt: dt) }

    if case .jumpTo = cat.goal { Issue.record("still aiming at a window that no longer exists") }
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
    cat.goal = nil

    var moved = false
    for _ in 0..<Int((Feel.Timing.restMin - 0.2) / dt) {
        cat = Cat.step(cat, world: sky([ledge]), dt: dt)
        if cat.goal != nil { moved = true; break }
    }
    #expect(!moved, "he started moving before his rest was up")
    #expect(Feel.Timing.restMin >= 3, "resting less than a few seconds would be exhausting to sit next to")
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
