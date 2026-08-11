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
    // Named rather than counted: this screen has a notch, and the notch is a permanent
    // occluder of its own.
    #expect(!sky.occluders.contains { $0.rect == ghost.rect })
}

@Test func ownWindowsAreExcluded() {
    let mine = win(1, CGRect(x: 0, y: 0, width: 1920, height: 1243), pid: 42)
    let sky = World.build(windows: [mine], screen: screen, ownPID: 42)
    #expect(!sky.occluders.contains { $0.rect == mine.rect })
}

@Test func menuBarAndFloorAlwaysExist() {
    let sky = World.build(windows: [], screen: screen, ownPID: 99)
    #expect(sky.surface(.menuBar) != nil)
    #expect(sky.surface(.floor) != nil)
    #expect(sky.surface(.menuBar)?.y == screen.visibleFrame.maxY)
}

@Test func revealedDockRaisesTheFloor() {
    // With the Dock auto-hidden, visibleFrame runs to the screen bottom. When it slides
    // up, its window is the only thing that says where the floor actually is.
    // Without this he'd stand behind the revealed Dock and it would look like a crash.
    let autoHide = ScreenGeometry(frame: screen.frame,
                                  visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1205),
                                  notch: screen.notch)
    let dock = win(9, CGRect(x: 400, y: 0, width: 1100, height: 70), layer: 20, owner: "Dock")
    let sky = World.build(windows: [dock], screen: autoHide, ownPID: 99)
    #expect(sky.surface(.floor)?.y == 70)
}

@Test func dockFullScreenBackingWindowDoesNotBecomeTheFloor() {
    // Regression: the Dock process owns a full-screen layer-20 window as well as the visible
    // Dock. Matching on owner+layer alone puts the floor at y=1243, the TOP of the screen,
    // and he falls forever.
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
    #expect(sky.occluders.contains { $0.rect == menu.rect }, "but it still occludes")
}

// MARK: - Walkable is not the same as visible

@Test func maximizedWindowHidesTheFloorButDoesNotDeleteIt() {
    // A maximized window's rect starts at visibleFrame.minY, which IS floorY, so a carve of
    // its whole width takes the entire screen width and the floor stops existing.
    let big = win(1, screen.visibleFrame)
    let sky = World.build(windows: [big], screen: screen, ownPID: 99)
    let floor = try! #require(sky.surface(.floor))

    #expect(floor.spans.isEmpty)            // correctly invisible
    #expect(!floor.solid.isEmpty)           // but still there to stand on
    // The whole width bar a body-width at each end, which is not the same thing as the whole
    // width: `solid` is where he can stand and be DRAWN, and the panel's own edges are as
    // real a boundary as the notch. Flush to them he stood with a third of himself off screen.
    #expect(floor.solid[0].length
            == screen.visibleFrame.width - Feel.Shape.clearance * 2)
}

@Test func theNotchIsAHoleInTheMenuBar() {
    let sky = World.build(windows: [], screen: screen, ownPID: 99)
    let bar = try! #require(sky.surface(.menuBar))

    // Two pieces, one either side of the cutout.
    #expect(bar.solid.count == 2)
    #expect(!bar.solid.contains { $0.contains(960) })   // 960 is inside the notch
    #expect(bar.solid.contains { $0.contains(400) })
    #expect(bar.solid.contains { $0.contains(1500) })
    // The anchor space still spans the whole screen: `extent` is the perch coordinate system
    // and must never develop holes, however many the surface itself has. arrival() places him
    // on the cutout's lip, which is in `solid`, and his dx is measured from this origin.
    #expect(bar.extent.contains(960))
}

@Test func aWindowsSolidExcludesItsRoundedCorners() {
    let w = win(1, CGRect(x: 400, y: 600, width: 500, height: 300))
    let sky = World.build(windows: [w], screen: screen, ownPID: 99)
    let s = try! #require(sky.surface(.window(1)))

    #expect(s.extent == 400...900)
    #expect(s.solid.count == 1)
    #expect(abs(s.solid[0].lowerBound - (400 + Feel.World.cornerInset)) < 0.001)
    #expect(abs(s.solid[0].upperBound - (900 - Feel.World.cornerInset)) < 0.001)
    #expect(s.rect == w.rect)
}

@Test func aWindowInFrontHidesTheSurfaceBehindWithoutRemovingIt() {
    let back = win(2, CGRect(x: 400, y: 600, width: 500, height: 300))    // top edge y = 900
    let front = win(1, CGRect(x: 500, y: 400, width: 200, height: 800))   // z=0, straddles it
    let sky = World.build(windows: [front, back], screen: screen, ownPID: 99)
    let s = try! #require(sky.surface(.window(2)))

    #expect(s.solid.count == 1)                         // unbroken ground
    #expect(s.spans.count == 2)                         // visible either side of the front one
    #expect(!s.spans.contains { $0.contains(600) })     // 600 is behind the front window
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

@Test func theDockFullScreenBackingWindowDoesNotCarveAwayWalkableSpans() {
    // Regression: the same phantom window that breaks the floor and the mask also straddles
    // every surface, so counting it as geometry carves every walkable span down to nothing
    // and he stands frozen forever with no reachable destination.
    let dockBacking = win(9, CGRect(x: 0, y: 0, width: 1920, height: 1243), layer: 20, owner: "Dock")
    let ledge = win(2, CGRect(x: 200, y: 300, width: 450, height: 332))
    let sky = World.build(windows: [dockBacking, ledge], screen: screen, ownPID: 99)

    let s = try! #require(sky.surface(.window(2)))
    #expect(!s.spans.isEmpty, "the Dock's phantom window carved away the whole ledge")
}

@Test func menusDoNotCarveAwayWalkableSpans() {
    // A ledge should not evaporate because someone opened a menu over it.
    let menu = win(1, CGRect(x: 0, y: 0, width: 1920, height: 1243), layer: 101)
    let ledge = win(2, CGRect(x: 200, y: 300, width: 450, height: 332))
    let sky = World.build(windows: [menu, ledge], screen: screen, ownPID: 99)
    #expect(!(try! #require(sky.surface(.window(2)))).spans.isEmpty)
}

@Test func menusAndPopoversDoNotOcclude() {
    // They are above his own window level, so they occlude him for real. Masking as well would
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

@Test func aSpaceChangeDoesNotDropEverySurface() {
    // Switching Spaces turns the entire window list over at once. Ordinary hysteresis is two
    // polls deep, so without a hold-off he reads the turnover as every platform vanishing
    // and falls off the one he is standing on.
    var tracker = WorldTracker()
    let w = win(1, CGRect(x: 100, y: 300, width: 600, height: 400))
    _ = tracker.ingest(World.build(windows: [w], screen: screen, ownPID: 99))
    _ = tracker.ingest(World.build(windows: [w], screen: screen, ownPID: 99))

    tracker.holdOff(polls: Feel.World.spaceChangeHoldOffPolls)
    for poll in 1...Feel.World.spaceChangeHoldOffPolls {
        let held = tracker.ingest(World.build(windows: [], screen: screen, ownPID: 99))
        #expect(held.surface(.window(1)) != nil, "he lost his platform on hold-off poll \(poll)")
    }
}

@Test func theHoldOffExpiresAndAClosedWindowStillGoesAway() {
    // Otherwise the fix is worse than the bug: he'd stand on the ghost of a window that was
    // genuinely closed during the Space change.
    var tracker = WorldTracker()
    let w = win(1, CGRect(x: 100, y: 300, width: 600, height: 400))
    _ = tracker.ingest(World.build(windows: [w], screen: screen, ownPID: 99))

    tracker.holdOff(polls: 2)
    for _ in 0..<2 { _ = tracker.ingest(World.build(windows: [], screen: screen, ownPID: 99)) }

    // The hold must not SPEND the ordinary grace period on its way past. Misses are not
    // counted while it holds, so the first poll after it is the first miss — count them and
    // every surface in the world is already at the vanish threshold when the hold lifts, so
    // the whole thing dies on one poll and the hold-off has bought exactly nothing.
    var last = tracker.ingest(World.build(windows: [], screen: screen, ownPID: 99))
    #expect(last.surface(.window(1)) != nil, "misses were counted while the hold-off held")

    for _ in 1..<Feel.World.vanishConfirmPolls {
        last = tracker.ingest(World.build(windows: [], screen: screen, ownPID: 99))
    }
    #expect(last.surface(.window(1)) == nil, "the hold-off never ended")
}

@Test func aSpaceChangeIsNotNewFurniture() {
    // Switching Spaces expires one cast and ages in another, and the newcomers all cross the
    // age threshold together. Reporting them hands the mind a windowOpened per switch — 0.30
    // of arousal, canTravel, two inside a half-life is a trip — which is exactly what app
    // switches were deliberately barred from doing, smuggled in through the window channel.
    // Furniture the new Space always had is not news.
    #expect(Feel.World.spaceChangeHoldOffPolls >= Feel.World.minAgePolls,
            "the hold must outlast the age threshold or the suppression cannot work")

    var tracker = WorldTracker()
    let a = win(1, CGRect(x: 100, y: 300, width: 600, height: 400))
    let b = win(2, CGRect(x: 800, y: 300, width: 600, height: 400))
    for _ in 0..<3 { _ = tracker.ingest(World.build(windows: [a], screen: screen, ownPID: 99)) }

    // The switch: the hold arrives, then the other Space's window list.
    tracker.holdOff(polls: Feel.World.spaceChangeHoldOffPolls)
    for poll in 1...(Feel.World.spaceChangeHoldOffPolls + Feel.World.vanishConfirmPolls) {
        _ = tracker.ingest(World.build(windows: [b], screen: screen, ownPID: 99))
        #expect(!tracker.justAppeared.contains(.window(2)),
                "the new Space's own furniture was reported as news on poll \(poll)")
    }

    // A window that opens once the dust has settled is real news again.
    for i in 1...Feel.World.minAgePolls {
        _ = tracker.ingest(World.build(windows: [b, a], screen: screen, ownPID: 99))
        #expect(tracker.justAppeared.contains(.window(1)) == (i == Feel.World.minAgePolls),
                "a genuinely new window on poll \(i) after the switch")
    }
}

@Test func newSurfacesAreNotImmediatelyTargetable() {
    var tracker = WorldTracker()
    let w = win(1, CGRect(x: 100, y: 300, width: 600, height: 400))
    let first = tracker.ingest(World.build(windows: [w], screen: screen, ownPID: 99))
    #expect(first.surface(.window(1))?.targetable == false, "he'd chase menus and sheets")

    let second = tracker.ingest(World.build(windows: [w], screen: screen, ownPID: 99))
    #expect(second.surface(.window(1))?.targetable == true)
}

/// `Surface.spans` is documented as "where he is currently visible" and is the mind's only
/// visibility oracle: `Cat.isHidden` is a straight `spans.contains(x)`, feeding `hiddenFor`
/// and the ten-second recovery. It used to ask whether an occluder straddled the line under
/// his feet, so a window covering all but the last point of him reported him fully visible,
/// the recovery never ran, and nothing else ever revised the answer.
@Test func aWindowOverHisBodyHidesHimEvenIfItClearsHisFeet() {
    let screen = ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                notch: nil)
    let back = RawWindow(id: 1, pid: 1, layer: 0,
                         rect: CGRect(x: 100, y: 100, width: 900, height: 400), alpha: 1, owner: "Back")
    let ledge = back.rect.maxY

    // Sweep the front window from flush with his feet to clear of his head.
    for lift in stride(from: CGFloat(0), through: Feel.Shape.height, by: 1) {
        let front = RawWindow(id: 2, pid: 2, layer: 0,
                              rect: CGRect(x: 300, y: ledge + lift, width: 400, height: 400), alpha: 1, owner: "Front")
        let world = World.build(windows: [front, back], screen: screen, ownPID: 99)   // front-to-back
        guard let s = world.surfaces.first(where: { $0.id == .window(1) }) else {
            Issue.record("the back window is not a surface at lift \(lift)")
            return
        }
        let covered = Feel.Shape.height - lift        // how much of him the window overlaps
        let visible = s.spans.contains { $0.contains(front.rect.midX) }
        // Clear of his head is the only lift where he is genuinely all there.
        let shouldSee = covered <= 0
        #expect(visible == shouldSee,
                Comment(rawValue: "at lift \(lift) the window covers \(covered) of his "
                        + "\(Feel.Shape.height)pt body; spans say visible=\(visible)"))
    }
}

/// The window list is global across every display and `snapshot` flips it against the primary,
/// so a window straddling onto a taller neighbouring screen has a top edge above this one's.
/// Unclipped that became walkable ground off the top of the panel, reachable with an ordinary
/// jump, and standing there means being grounded somewhere he is never drawn.
@Test func aWindowTallerThanTheScreenIsNotWalkableGroundAboveIt() {
    let s = ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                           visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                           notch: nil)
    let tall = RawWindow(id: 1, pid: 1, layer: 0,
                         rect: CGRect(x: 100, y: 500, width: 600, height: 1000), alpha: 1, owner: "Tall")
    let world = World.build(windows: [tall], screen: s, ownPID: 99)
    #expect(!world.surfaces.contains { $0.id == .window(1) },
            "a top edge at y=1500 became a ledge on a screen that ends at 1080")
    #expect(world.surfaces.allSatisfy { $0.y <= s.frame.maxY },
            "there is a walkable surface above the top of the screen")
}

/// `visibleFrame.maxY == frame.maxY` means nothing is reserved at the top, and that is true in
/// two situations the geometry alone cannot tell apart: a fullscreen Space, where the menu bar
/// line is synthetic and must stay coplanar with the fullscreen window's top edge, and a menu
/// bar merely set to auto-hide, where perching him at the very top draws his whole body off
/// the display. All four rows here, so neither fix can be made at the other's expense.
@Test func theMenuBarLineKnowsWhyThereIsNoBar() {
    let H = CGFloat(1117), W = CGFloat(1728)
    func geometry(bar: CGFloat, notch: CGRect? = nil, height: CGFloat = H) -> ScreenGeometry {
        ScreenGeometry(frame: CGRect(x: 0, y: 0, width: W, height: height),
                       visibleFrame: CGRect(x: 0, y: 90, width: W, height: height - 90 - bar),
                       notch: notch)
    }

    // A NOTCHED display: the line is the notch's lower lip and must not move a point, because
    // the cutout, the den, the doorways and the tunnel are all measured from it.
    let notched = geometry(bar: 38, notch: CGRect(x: 856, y: 1206, width: 208, height: 37),
                           height: 1243)
    #expect(World.build(windows: [], screen: notched, ownPID: 99).surface(.menuBar)!.y
                == notched.visibleFrame.maxY,
            "the notch's lower lip moved, which moves the den with it")

    // A FULLSCREEN Space: synthetic line, must stay at the top and coplanar with the window's
    // own top edge, or every landing on it re-plans as a jump.
    let fs = geometry(bar: 0, height: 1243)
    let film = RawWindow(id: 1, pid: 7, layer: 0,
                         rect: CGRect(x: 0, y: 0, width: W, height: 1243), alpha: 1, owner: "Film")
    #expect(World.build(windows: [film], screen: fs, ownPID: 99).surface(.menuBar)!.y
                == fs.frame.maxY,
            "the fullscreen line moved off the window's top edge")

    // Any OTHER display: he has to fit in the strip he stands on. A plain bar is 24-25pt
    // through Sequoia and about 31pt on Tahoe, against a cat who is `Shape.height` tall, so
    // the line drops as far as it must and no further.
    for bar in [CGFloat(0), 24, 25, 31, 38, 60] {
        let g = geometry(bar: bar)
        let y = World.build(windows: [], screen: g, ownPID: 99).surface(.menuBar)!.y
        #expect(y + Feel.Shape.height <= g.frame.maxY,
                Comment(rawValue: "with a \(bar)pt bar his head is drawn \(y + Feel.Shape.height - g.frame.maxY)pt off the top"))
        #expect(y <= g.visibleFrame.maxY,
                Comment(rawValue: "with a \(bar)pt bar he perches ABOVE the bar line"))
        // ...and never lower than it has to be: a bar tall enough for him keeps its own line.
        if bar >= Feel.Shape.height {
            #expect(y == g.visibleFrame.maxY,
                    Comment(rawValue: "a \(bar)pt bar has room for him and still moved his perch"))
        }
    }
}
