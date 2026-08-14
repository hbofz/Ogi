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

/// A notched display cannot give him room the way a notchless one can. That line is the
/// cutout's lower lip and the den, the tunnel and both doorways are measured from it, so it
/// cannot drop. The strip is whatever the hardware says: 38pt on a 16-inch MacBook Pro, 32pt on
/// a 14-inch or any MacBook Air, and smaller again under a Larger Text scaling.
///
/// So on those Macs the cat moves instead of the line. He was tuned by eye against a 38pt strip;
/// every other strip gets him at the same fraction of it, which is what makes a 14-inch look
/// like the 16-inch he was tuned on rather than like a cat with his ears sawn off.
@Test func aNotchedStripScalesTheCatRatherThanTheLine() {
    func notched(strip: CGFloat) -> ScreenGeometry {
        let H: CGFloat = 1243
        return ScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1920, height: H),
            visibleFrame: CGRect(x: 0, y: 90, width: 1920, height: H - 90 - strip),
            notch: CGRect(x: 856, y: H - strip, width: 208, height: strip - 1))
    }

    // The 16-inch he was tuned on. Anything but exactly 1 here silently resizes the cat Hamzah
    // hand-tuned, on the one machine the numbers were chosen against.
    #expect(notched(strip: 38).catFit == 1, "the reference strip resized the cat")

    // A 14-inch Pro, and every M2-or-later Air.
    #expect(abs(notched(strip: 32).catFit - 32.0 / 38.0) < 0.001)

    // He never grows. A taller strip is headroom, not an invitation.
    #expect(notched(strip: 60).catFit == 1, "a roomy strip made him bigger than he was tuned")

    // A notchless display gets room by moving the LINE (see `noLedgeSitsCloserToTheTopThanHeIsTall`),
    // so it must never also shrink him. Its bar is 24-31pt and that formula would render him at
    // two thirds for no reason.
    for bar in [CGFloat(0), 24, 31, 38] {
        let g = ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1920, height: 1243),
                               visibleFrame: CGRect(x: 0, y: 90, width: 1920, height: 1153 - bar),
                               notch: nil)
        #expect(g.catFit == 1, Comment(rawValue: "a notchless \(bar)pt bar shrank him to \(g.catFit)"))
    }
}

/// Everything about how big he is has to move together. The drawing, the collision box, the
/// standing-room inset and the headroom clamp are four readings of ONE size, and a fit that
/// scaled the drawing alone would render a smaller cat that is still clicked, hidden, shadowed
/// and given room as the larger one.
///
/// `clearance` is why this samples rather than reasons: it was `static let width / 2`, which
/// under a computed `width` freezes at whatever the fit happened to be the first time anything
/// asked. Nothing but a real change of fit catches that.
@MainActor
@Test func fitMovesEveryMeasurementOfHimTogether() {
    // Read, flip, sample, restore, all straight-line and with no suspension point in it. `fit`
    // is process-global and most of this suite is nonisolated, so the window in which another
    // test could see the flipped value is a handful of property reads wide.
    let one = (Feel.Shape.spriteScale, Feel.Shape.height, Feel.Shape.width,
               Feel.Shape.standingHeight, Feel.Shape.clearance, Sprites.size(.idle, 0).height)
    Feel.Shape.fit = 0.5
    let half = (Feel.Shape.spriteScale, Feel.Shape.height, Feel.Shape.width,
                Feel.Shape.standingHeight, Feel.Shape.clearance, Sprites.size(.idle, 0).height)
    Feel.Shape.fit = 1

    #expect(half.0 == one.0 * 0.5, "the drawing scale did not follow the fit")
    #expect(half.1 == one.1 * 0.5, "the collision box did not follow the fit")
    #expect(half.2 == one.2 * 0.5, "his width did not follow the fit")
    #expect(half.3 == one.3 * 0.5, "the headroom clamp did not follow the fit")
    #expect(half.4 == one.4 * 0.5, "the standing-room inset did not follow the fit")
    // ...and the sheets, which are the only one of these that reaches the screen.
    #expect(abs(half.5 - one.5 * 0.5) < 0.01,
            "the drawing did not follow the fit; `clipScale` is caching `spriteScale`")
}

/// He is drawn UPWARDS from the line he stands on, so any ledge within his own drawn height of
/// the top of the display puts part of him off the panel. Reported from a MacBook Air M1 (no
/// notch, 1440x900) with Chrome fullscreen: his head was sliced off flat at the panel's edge.
///
/// Two ledges did it and both are covered here. In a fullscreen Space the menu bar line was
/// pinned to `frame.maxY`, which is zero headroom, and the fullscreen window's own top edge was
/// accepted as a second ledge at the same place. `Feel.Shape.height` is not the measurement
/// either: it is his nominal collision box, and six standing clips are drawn taller than it.
@Test func noLedgeSitsCloserToTheTopThanHeIsTall() {
    // The reporter's machine, in the state the photograph was taken in.
    let air = ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                             visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                             notch: nil)
    let chrome = win(1, air.frame)
    let world = World.build(windows: [chrome], screen: air, ownPID: 99)

    for s in world.surfaces {
        #expect(s.y + Feel.Shape.standingHeight <= air.frame.maxY,
                Comment(rawValue: "\(s.id) is \(s.y + Feel.Shape.standingHeight - air.frame.maxY)pt "
                        + "too close to the top; standing there draws his head off the panel"))
    }

    // ...and the two ledges must not become a pair he crouches and jumps between. A fullscreen
    // window's top edge is now no ledge at all, so the bar line is the only thing up there.
    #expect(!world.surfaces.contains { $0.id == .window(1) },
            "the fullscreen window's top edge is still a ledge with nothing above it")
}

/// The nominal collision box is not what gets drawn. `standingHeight` is the yardstick for the
/// top of the display and has to stay equal to the tallest clip he can be in while standing on
/// a ledge, or the clamp it feeds is wrong again the next time a sheet is added.
///
/// Jumping and falling are excluded on purpose: he is airborne, not standing, and there is
/// nothing above the top line to jump at.
@MainActor
@Test func standingHeightIsTheTallestClipHeCanStandIn() {
    let airborne: Set<Sprites.Clip> = [.jump, .fall, .cling, .climbUp, .held,
                                       .hang, .peer, .peerDown, .denSleep]
    var tallest: (Sprites.Clip, CGFloat) = (.idle, 0)
    for c in Sprites.Clip.allCases where !airborne.contains(c) {
        for i in 0..<c.count where Sprites.size(c, i).height > tallest.1 {
            tallest = (c, Sprites.size(c, i).height)
        }
    }
    #expect(abs(Feel.Shape.standingHeight - tallest.1) < 1,
            Comment(rawValue: "the tallest standing clip is \(tallest.0.rawValue) at "
                    + "\(tallest.1)pt, but standingHeight says \(Feel.Shape.standingHeight)"))
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

    // A FULLSCREEN Space on a notchless display: the line used to be pinned to the very top so
    // it stayed coplanar with the window's own top edge, or every landing on it re-planned as a
    // jump. Pinned there it also drew his entire body off the panel, which is what a MacBook Air
    // M1 running Chrome fullscreen actually looked like.
    //
    // So the line drops to where he fits, and the coplanar problem is answered from the other
    // end: the window's top edge is no longer a ledge either, so there is no second ledge left
    // to crouch and jump at. Both halves are asserted, because either one alone is a bug.
    let fs = geometry(bar: 0, height: 1243)
    let film = RawWindow(id: 1, pid: 7, layer: 0,
                         rect: CGRect(x: 0, y: 0, width: W, height: 1243), alpha: 1, owner: "Film")
    let fsWorld = World.build(windows: [film], screen: fs, ownPID: 99)
    #expect(fsWorld.surface(.menuBar)!.y + Feel.Shape.standingHeight <= fs.frame.maxY,
            "in a fullscreen Space his head is still drawn off the top of the panel")
    #expect(!fsWorld.surfaces.contains { $0.id == .window(1) },
            "the fullscreen window's top edge is a second ledge above the line he stands on")

    // Any OTHER display: he has to fit in the strip he stands on. A plain bar is 24-25pt
    // through Sequoia and about 31pt on Tahoe, against a cat drawn `standingHeight` tall, so
    // the line drops as far as it must and no further. `standingHeight` and not `Shape.height`:
    // the nominal box is 40 and six standing clips are taller, so the old figure left his ears
    // off the panel on every notchless Mac in the tallest of them.
    for bar in [CGFloat(0), 24, 25, 31, 38, 47, 60] {
        let g = geometry(bar: bar)
        let y = World.build(windows: [], screen: g, ownPID: 99).surface(.menuBar)!.y
        #expect(y + Feel.Shape.standingHeight <= g.frame.maxY,
                Comment(rawValue: "with a \(bar)pt bar his head is drawn \(y + Feel.Shape.standingHeight - g.frame.maxY)pt off the top"))
        #expect(y <= g.visibleFrame.maxY,
                Comment(rawValue: "with a \(bar)pt bar he perches ABOVE the bar line"))
        // ...and never lower than it has to be: a bar tall enough for him keeps its own line.
        if bar >= Feel.Shape.standingHeight {
            #expect(y == g.visibleFrame.maxY,
                    Comment(rawValue: "a \(bar)pt bar has room for him and still moved his perch"))
        }
    }
}
