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
