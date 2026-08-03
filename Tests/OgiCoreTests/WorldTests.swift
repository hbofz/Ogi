import Testing
import CoreGraphics
@testable import OgiCore

private func win(_ id: CGWindowID, _ rect: CGRect, layer: Int = 0,
                 alpha: Double = 1, pid: pid_t = 1, owner: String = "App") -> RawWindow {
    RawWindow(id: id, pid: pid, layer: layer, rect: rect, alpha: alpha, owner: owner)
}

private let screen = ScreenGeometry(
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1243),
    visibleFrame: CGRect(x: 0, y: 90, width: 1920, height: 1115),
    notch: CGRect(x: 856, y: 1206, width: 208, height: 37))

// MARK: - Interval subtraction

@Test func subtractDisjointLeavesSpanIntact() {
    #expect(subtract([0...100], 200...300) == [0...100])
}

@Test func subtractStraddlingLeftTrimsStart() {
    #expect(subtract([100...200], 50...120) == [120...200])
}

@Test func subtractStraddlingRightTrimsEnd() {
    #expect(subtract([100...200], 180...250) == [100...180])
}

@Test func subtractContainedSplitsInTwo() {
    #expect(subtract([0...100], 40...60) == [0...40, 60...100])
}

@Test func subtractFullCoverRemovesSpan() {
    #expect(subtract([40...60], 0...100).isEmpty)
}

@Test func subtractAppliesToEverySpan() {
    #expect(subtract([0...100, 200...300], 50...250) == [0...50, 250...300])
}

// MARK: - Skyline construction

@Test func frontWindowErasesSpanBehindIt() {
    // Back window's top edge at y=800, front window's body straddles it.
    let front = win(1, CGRect(x: 300, y: 400, width: 400, height: 600))   // spans y 400...1000
    let back = win(2, CGRect(x: 100, y: 200, width: 800, height: 600))    // top edge y = 800
    let sky = World.build(windows: [front, back], screen: screen, ownPID: 99)

    let s = try! #require(sky.surface(.window(2)))
    #expect(s.y == 800)
    // The front window covers x 300...700 of it.
    #expect(s.spans.allSatisfy { !$0.overlaps(310...690) })
    #expect(s.spans.contains { $0.lowerBound < 300 })
}

@Test func coplanarTopEdgesDoNotEraseEachOther() {
    // Tiled windows very often share a top edge exactly. With >= instead of >, the rear
    // window's entire surface would vanish.
    let a = win(1, CGRect(x: 0, y: 200, width: 500, height: 600))     // top 800
    let b = win(2, CGRect(x: 400, y: 200, width: 500, height: 600))   // top 800, overlaps a
    let sky = World.build(windows: [a, b], screen: screen, ownPID: 99)

    let rear = try! #require(sky.surface(.window(2)))
    #expect(!rear.spans.isEmpty, "coplanar front window erased the rear surface")
}

@Test func lowAlphaWindowsAreIgnored() {
    // Animation frames and invisible helper windows.
    let ghost = win(1, CGRect(x: 0, y: 100, width: 900, height: 900), alpha: 0.4)
    let sky = World.build(windows: [ghost], screen: screen, ownPID: 99)
    #expect(sky.surface(.window(1)) == nil)
    #expect(sky.occluders.isEmpty)
}

@Test func ownWindowsAreExcluded() {
    let mine = win(1, CGRect(x: 0, y: 0, width: 1920, height: 1243), pid: 42)
    let sky = World.build(windows: [mine], screen: screen, ownPID: 42)
    #expect(sky.occluders.isEmpty)
}

@Test func menuBarAndFloorAlwaysExist() {
    let sky = World.build(windows: [], screen: screen, ownPID: 99)
    #expect(sky.surface(.menuBar) != nil)
    #expect(sky.surface(.floor) != nil)
    #expect(sky.surface(.menuBar)?.y == screen.visibleFrame.maxY)
}

@Test func revealedDockRaisesTheFloor() {
    // With the Dock auto-hidden, visibleFrame runs to the screen bottom. When it slides
    // up, its window is the only thing that tells us where the floor actually is.
    // Without this he'd stand behind the revealed Dock and it would look like a crash.
    let autoHide = ScreenGeometry(frame: screen.frame,
                                  visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1205),
                                  notch: screen.notch)
    let dock = win(9, CGRect(x: 400, y: 0, width: 1100, height: 70), layer: 20, owner: "Dock")
    let sky = World.build(windows: [dock], screen: autoHide, ownPID: 99)
    #expect(sky.surface(.floor)?.y == 70)
}

@Test func dockFullScreenBackingWindowDoesNotBecomeTheFloor() {
    // Regression, found by M0 against the real system: the Dock process owns a full-screen
    // layer-20 window as well as the visible Dock. Matching on owner+layer alone put the
    // floor at y=1243, the TOP of the screen, and he fell forever.
    let autoHide = ScreenGeometry(frame: screen.frame,
                                  visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1205),
                                  notch: screen.notch)
    let backing = win(9, CGRect(x: 0, y: 0, width: 1920, height: 1243), layer: 20, owner: "Dock")
    let sky = World.build(windows: [backing], screen: autoHide, ownPID: 99)
    #expect(sky.surface(.floor)?.y == 0, "the Dock's full-screen backing window became the floor")
}

@Test func pinnedDockLeavesTheFloorAtTheVisibleFrame() {
    // visibleFrame.minY already sits at a pinned Dock's top edge, so floor and
    // "Dock shelf" collapse into one surface and the max() is a no-op.
    let dock = win(9, CGRect(x: 400, y: 0, width: 1100, height: 90), layer: 20, owner: "Dock")
    let sky = World.build(windows: [dock], screen: screen, ownPID: 99)
    #expect(sky.surface(.floor)?.y == 90)
}

@Test func narrowWindowsAreNotPlatforms() {
    let sliver = win(1, CGRect(x: 0, y: 300, width: 30, height: 400), layer: 0)
    let sky = World.build(windows: [sliver], screen: screen, ownPID: 99)
    #expect(sky.surface(.window(1)) == nil)
}

@Test func nonZeroLayersOccludeButAreNotWalkable() {
    let menu = win(1, CGRect(x: 100, y: 500, width: 300, height: 400), layer: 101)
    let sky = World.build(windows: [menu], screen: screen, ownPID: 99)
    #expect(sky.surface(.window(1)) == nil, "a popup menu is not a platform")
    #expect(sky.occluders.count == 1, "but it still occludes")
}

// MARK: - Occlusion

@Test func onlyWindowsInFrontOfThePerchOcclude() {
    let front = win(1, CGRect(x: 100, y: 100, width: 400, height: 400))
    let perch = win(2, CGRect(x: 100, y: 100, width: 400, height: 400))
    let behind = win(3, CGRect(x: 100, y: 100, width: 400, height: 400))
    let sky = World.build(windows: [front, perch, behind], screen: screen, ownPID: 99)

    let perchZ = try! #require(sky.surface(.window(2))).z
    let hits = sky.occluders(above: perchZ, intersecting: CGRect(x: 200, y: 200, width: 50, height: 50))
    #expect(hits.count == 1, "only the window in front of his perch should occlude him")
}

@Test func theDockFullScreenBackingWindowNeverOccludesHim() {
    // Regression: this window is at layer 20 and sits in front of everything. Left in the
    // occluder set it masks him away completely, everywhere, at all times.
    let dockBacking = win(9, CGRect(x: 0, y: 0, width: 1920, height: 1243), layer: 20, owner: "Dock")
    let perch = win(2, CGRect(x: 100, y: 100, width: 400, height: 400))
    let sky = World.build(windows: [dockBacking, perch], screen: screen, ownPID: 99)

    let perchZ = try! #require(sky.surface(.window(2))).z
    let hits = sky.occluders(above: perchZ, intersecting: CGRect(x: 200, y: 200, width: 50, height: 50))
    #expect(hits.isEmpty, "the Dock's full-screen window masked him away")
}

@Test func menusAndPopoversDoNotOcclude() {
    // They are above our window level, so they occlude him for real. Masking as well would
    // double-count, and their shapes are not rectangles anyway.
    let menu = win(1, CGRect(x: 150, y: 150, width: 200, height: 300), layer: 101)
    let perch = win(2, CGRect(x: 100, y: 100, width: 400, height: 400))
    let sky = World.build(windows: [menu, perch], screen: screen, ownPID: 99)

    let perchZ = try! #require(sky.surface(.window(2))).z
    #expect(sky.occluders(above: perchZ,
                          intersecting: CGRect(x: 200, y: 200, width: 50, height: 50)).isEmpty)
}

@Test func standingOnTheFloorEverythingOccludes() {
    // floor.z == Int.max, so every normal window is in front of him. Correct: he is behind
    // everything when he is down on the desktop.
    let w = win(1, CGRect(x: 100, y: 100, width: 400, height: 400))
    let sky = World.build(windows: [w], screen: screen, ownPID: 99)
    let floorZ = try! #require(sky.surface(.floor)).z
    #expect(sky.occluders(above: floorZ,
                          intersecting: CGRect(x: 200, y: 200, width: 50, height: 50)).count == 1)
}

// MARK: - Hysteresis

@Test func oneFrameDropoutDoesNotRemoveASurface() {
    var tracker = WorldTracker()
    let w = win(1, CGRect(x: 100, y: 300, width: 600, height: 400))
    _ = tracker.ingest(World.build(windows: [w], screen: screen, ownPID: 99))

    let afterDropout = tracker.ingest(World.build(windows: [], screen: screen, ownPID: 99))
    #expect(afterDropout.surface(.window(1)) != nil, "a single-poll blip dropped him")
}

@Test func sustainedDisappearanceRemovesTheSurface() {
    var tracker = WorldTracker()
    let w = win(1, CGRect(x: 100, y: 300, width: 600, height: 400))
    _ = tracker.ingest(World.build(windows: [w], screen: screen, ownPID: 99))
    _ = tracker.ingest(World.build(windows: [], screen: screen, ownPID: 99))
    let gone = tracker.ingest(World.build(windows: [], screen: screen, ownPID: 99))
    #expect(gone.surface(.window(1)) == nil)
}

@Test func newSurfacesAreNotImmediatelyTargetable() {
    var tracker = WorldTracker()
    let w = win(1, CGRect(x: 100, y: 300, width: 600, height: 400))
    let first = tracker.ingest(World.build(windows: [w], screen: screen, ownPID: 99))
    #expect(first.surface(.window(1))?.targetable == false, "he'd chase menus and sheets")

    let second = tracker.ingest(World.build(windows: [w], screen: screen, ownPID: 99))
    #expect(second.surface(.window(1))?.targetable == true)
}
