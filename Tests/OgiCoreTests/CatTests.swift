import Testing
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
