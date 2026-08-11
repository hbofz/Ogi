import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Types

/// A window as the system reports it, already flipped into AppKit bottom-left coordinates.
public struct RawWindow: Sendable, Equatable {
    public let id: CGWindowID
    public let pid: pid_t
    public let layer: Int
    public let rect: CGRect
    public let alpha: Double
    public let owner: String

    public init(id: CGWindowID, pid: pid_t, layer: Int, rect: CGRect, alpha: Double, owner: String) {
        self.id = id; self.pid = pid; self.layer = layer
        self.rect = rect; self.alpha = alpha; self.owner = owner
    }
}

public enum SurfaceID: Hashable, Sendable {
    case window(CGWindowID)
    case menuBar
    case floor
}

/// A walkable horizontal line.
public struct Surface: Sendable {
    public let id: SurfaceID
    /// Index into the front-to-back occluder array. menuBar = -1, floor = .max.
    public let z: Int
    public var y: CGFloat
    /// Full top-edge extent, and the perch anchor space. Does NOT shrink for any reason.
    public var extent: ClosedRange<CGFloat>
    /// Where he can physically stand. **Structural** exclusions only: rounded corners, the
    /// notch, anything off-screen. A window raised in front of this one never reduces it.
    ///
    /// Kept separate from `spans` because merging them lets him stand on a rounded corner
    /// where no window is drawn, lets a maximized window delete the floor outright, and
    /// stops the notch being a hole, so he walks through the cutout and vanishes.
    public var solid: [ClosedRange<CGFloat>]
    /// Where he is currently visible: `solid` minus everything in front. Governs where he
    /// *prefers* to be. **Never used to decide whether he falls** (see `Skyline`).
    public var spans: [ClosedRange<CGFloat>]
    public var targetable: Bool
    /// The source window's full rect, for clinging to its face. Nil for the menu bar and
    /// the floor, which have no face.
    public var rect: CGRect?
}

public struct Occluder: Sendable {
    public let rect: CGRect
    public let z: Int
    public let layer: Int

    /// A real application window, as opposed to system furniture.
    ///
    /// Defined once because **the Dock process owns a full-screen layer-20 window** in
    /// addition to the visible Dock. It straddles every surface and sits in front of
    /// everything, so counting it as geometry puts the floor at the top of the screen,
    /// masks him away entirely, and carves every walkable span down to nothing.
    ///
    /// Menus, popovers, sheets and tooltips are excluded for a second reason: they are
    /// above this window's level, so they already occlude him for real, and they are
    /// transient (a walkable ledge should not evaporate because someone opened a menu).
    public var isRealWindow: Bool { layer == 0 }
}

public struct ScreenGeometry: Sendable {
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var notch: CGRect?

    public init(frame: CGRect, visibleFrame: CGRect, notch: CGRect?) {
        self.frame = frame; self.visibleFrame = visibleFrame; self.notch = notch
    }

    #if canImport(AppKit)
    public init(_ s: NSScreen) {
        frame = s.frame
        visibleFrame = s.visibleFrame
        // safeAreaInsets.top > 0 is the notch test. It returns 0 on non-notched Macs
        // and on every external display, so this is also the "no notch" branch.
        if s.safeAreaInsets.top > 0,
           let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            notch = CGRect(x: l.maxX,
                           y: s.frame.maxY - s.safeAreaInsets.top,
                           width: r.minX - l.maxX,
                           height: s.safeAreaInsets.top)
        } else {
            notch = nil
        }
    }
    #endif
}

public struct Skyline: Sendable {
    public let surfaces: [Surface]
    public let occluders: [Occluder]
    public let screen: ScreenGeometry

    public func surface(_ id: SurfaceID) -> Surface? {
        surfaces.first { $0.id == id }
    }

    /// Swept ground test. At terminal velocity a 120Hz step covers 12px and surfaces are
    /// infinitely thin lines, so a point test tunnels straight through them.
    ///
    /// Tests `solid`, not `extent`: he must not land on a rounded corner where nothing is
    /// drawn, and he must still land on a window that is completely hidden behind another.
    public func supportBelow(x: CGFloat, from y0: CGFloat, to y1: CGFloat) -> Surface? {
        let lo = min(y0, y1), hi = max(y0, y1)
        return surfaces
            .filter { s in
                s.y >= lo && s.y <= hi && s.solid.contains { $0.contains(x) }
            }
            // Highest surface wins; ties break to the frontmost window.
            .max { a, b in (a.y, -a.z) < (b.y, -b.z) }
    }

    /// The frontmost window whose face contains this point. Nil in open air, and nil for
    /// the menu bar and the floor, which have no face.
    public func faceContaining(_ p: CGPoint) -> Surface? {
        surfaces
            .filter { s in s.rect.map { $0.contains(p) } ?? false }
            .min { $0.z < $1.z }
    }

    /// Everything strictly in front of the perch. He rests ON his perch, so his body
    /// occupies the band above it, which belongs to whatever is behind. He is therefore
    /// just in front of his perch and behind everything in front of it.
    public func occluders(above z: Int, intersecting r: CGRect) -> [CGRect] {
        occluders.filter { $0.isRealWindow && $0.z < z && $0.rect.intersects(r) }.map(\.rect)
    }
}

// MARK: - Interval subtraction (pure)

/// Removes `cut` from every span. The one piece of real algorithmic content in the world model.
public func subtract(_ spans: [ClosedRange<CGFloat>],
                     _ cut: ClosedRange<CGFloat>) -> [ClosedRange<CGFloat>] {
    spans.flatMap { s -> [ClosedRange<CGFloat>] in
        guard s.overlaps(cut) else { return [s] }
        var out: [ClosedRange<CGFloat>] = []
        if s.lowerBound < cut.lowerBound { out.append(s.lowerBound...cut.lowerBound) }
        if cut.upperBound < s.upperBound { out.append(cut.upperBound...s.upperBound) }
        return out
    }
}

extension ClosedRange where Bound == CGFloat {
    public var length: CGFloat { upperBound - lowerBound }
}

// MARK: - Building the skyline (pure)

public enum World {

    /// Turns a raw window list into walkable terrain. Pure: this is the entire test surface.
    /// Is a fullscreen Space covering this screen?
    ///
    /// Full-width bands whose union covers the screen from its bottom EDGE up to the menu bar
    /// line. The bottom edge, not `visibleFrame.minY`, is what separates fullscreen from
    /// merely maximized: fullscreen owns the Dock band and zoom does not.
    public static func somethingFullscreen(in raw: [RawWindow], screen: ScreenGeometry,
                                           ownPID: pid_t) -> Bool {
        let f = screen.frame
        let tol = Feel.World.coplanarTolerance
        var bare = [f.minY...screen.visibleFrame.maxY]
        for w in raw where w.layer == 0 && w.pid != ownPID
            && w.alpha >= Feel.World.minWindowAlpha
            && w.rect.minX <= f.minX + tol && w.rect.maxX >= f.maxX - tol {
            bare = subtract(bare, w.rect.minY...w.rect.maxY)
        }
        return bare.allSatisfy { $0.length <= tol }
    }

    public static func build(windows: [RawWindow],
                             screen: ScreenGeometry,
                             ownPID: pid_t) -> Skyline {
        // Cheapest rejections first.
        let visible = windows.filter { w in
            w.pid != ownPID
                && w.alpha >= Feel.World.minWindowAlpha
                && w.rect.width >= 1 && w.rect.height >= 1
                && w.rect.intersects(screen.frame)
        }

        let fromWindows = visible.enumerated().map { Occluder(rect: $1.rect, z: $0, layer: $1.layer) }

        // The notch is a hardware cutout with no pixels behind it, so anything drawn there is
        // invisible. Modelling it as a permanent occluder in front of everything (z = -2, ahead
        // of even the menu bar's -1, because it is physically in front of everything) means the
        // mask that already exists does the work: the part of him inside the cutout is clipped
        // away and only the part outside shows. That is what makes peeking out of it real,
        // rather than a trick that depends on him being a black cat against a black bezel.
        //
        // `layer: 0` is load-bearing, not decoration: `occluders(above:intersecting:)` filters on
        // `isRealWindow`, so at any other layer this would be silently ignored.
        //
        // Deliberately NOT in `fromWindows`, which is what `carve` reads. That array is named
        // for where it comes from rather than for what it holds, so appending to the wrong one
        // is a visible mistake rather than a natural-looking one. The notch covers no surface's
        // top edge (its underside is the menu bar line, and the bar's own hole is cut
        // structurally out of `solid` below), so letting it carve walkable spans would delete
        // ground for no reason beyond which array it happened to be added to.
        //
        // It is extended DOWN to the menu bar line first. `safeAreaInsets.top` and the menu
        // bar's own height disagree by a point on real hardware (measured 37 against 38 on an
        // M2), so the cutout's underside sits one point ABOVE the line he walks on. That leaves
        // a one-point seam of live pixels under the hole, and a cat standing in it (crossing the
        // tunnel, or asleep in the den) shows as a thin orange line under the notch.
        //
        // Extending the occluder cannot hide anything it should not: everything drawn under
        // there hangs BELOW the bar line by construction (the tail, the dangling body, the head
        // and paws), and the seam is the only thing between the two numbers.
        let occluders = screen.notch.map { n -> [Occluder] in
            let bottom = min(n.minY, screen.visibleFrame.maxY)
            let sealed = CGRect(x: n.minX, y: bottom, width: n.width, height: n.maxY - bottom)
            return [Occluder(rect: sealed, z: -2, layer: 0)] + fromWindows
        } ?? fromWindows
        let screenSpan = screen.visibleFrame.minX...screen.visibleFrame.maxX

        /// Where he can stand and still be drawn whole, as opposed to where the desktop
        /// happens to extend.
        ///
        /// The outer edges of the display are as real a boundary as the notch is. Running
        /// `solid` flush to them lets him plant at x=5 on a 1920pt screen, a third of him off
        /// the panel, peeking over the left edge with only his tail still on it. This is
        /// `solid` only. `extent` is the perch anchor space and must not shrink for anything.
        ///
        /// Falls back to the full span on a screen too narrow to inset, which cannot happen on
        /// real hardware but must not produce an inverted range if it ever does.
        let standable = screenSpan.length > Feel.Shape.clearance * 2
            ? (screenSpan.lowerBound + Feel.Shape.clearance)...(screenSpan.upperBound - Feel.Shape.clearance)
            : screenSpan

        /// Cuts every occluder in front of `z` that overlaps the cat standing at `y`.
        ///
        /// **Against his body, not against the line under his feet.** He is
        /// `Feel.Shape.height` tall and the renderer masks him wherever a front window meets
        /// that box, but this tested only whether an occluder straddled `y` itself, so a
        /// window covering 31 of his 32 points reported him fully visible:
        ///
        ///     front.minY = ledge + 0.4  ->  spans said visible, 31.6 of his 32pt covered
        ///
        /// `spans` is the mind's only answer to "can he be seen": `isHidden` is a straight
        /// `spans.contains(x)`, and it feeds `hiddenFor` and the ten-second recovery. Reported
        /// visible, `hiddenFor` stays pinned at zero and the recovery never runs, which is
        /// exactly the lost-cat failure that block exists to prevent, and it does not
        /// self-correct because nothing else ever revises the answer.
        func carve(_ initial: [ClosedRange<CGFloat>], y: CGFloat, z: Int) -> [ClosedRange<CGFloat>] {
            var spans = initial
            for o in fromWindows where o.isRealWindow && o.z < z {
                // `>` and not `>=` on the lower edge: coplanar top edges must not erase each
                // other. The upper edge is his head, so a window hanging into his body counts.
                guard o.rect.minY < y + Feel.Shape.height,
                      o.rect.maxY > y + Feel.World.coplanarEpsilon else { continue }
                guard o.rect.minX <= o.rect.maxX else { continue }
                spans = subtract(spans, o.rect.minX...o.rect.maxX)
            }
            return spans.filter { $0.length >= Feel.World.minStandWidth }
        }

        /// The notch is a hole in the SCREEN, not a hole in the menu bar.
        ///
        /// The bar is not the only ledge at that height. A fullscreen window's top edge sits
        /// *exactly* on the menu bar line on a notched Mac, runs the full width of the screen,
        /// and the covered-screen retreat puts him there. Standing anywhere under the cutout
        /// draws him into a region with no pixels behind it, and a whole cat reduces to a
        /// sliver of tail.
        ///
        /// So the rule belongs to any ledge a standing cat would reach into it from, and is
        /// the same rule the bar already had: a hole in `solid`, which `isGap` reads as a wall,
        /// so he stops at the lip rather than walking into nothing.
        func punchNotch(_ spans: [ClosedRange<CGFloat>], at y: CGFloat) -> [ClosedRange<CGFloat>] {
            guard let notch = screen.notch,
                  y < notch.maxY, y + Feel.Shape.height > notch.minY else { return spans }
            return subtract(spans, notch.minX...notch.maxX)
        }

        var surfaces: [Surface] = []

        // Menu bar. Always present, effectively never occluded (z = -1), but the notch is a
        // genuine hole in it: a hardware cutout with no pixels behind it. Cutting it out of
        // `solid` is what stops him walking through the doorway and disappearing.
        // **He has to fit in whatever strip he is standing on.**
        //
        // He stands on this line with a foot anchor of 0, so his body occupies the strip ABOVE
        // it, and that strip is only as tall as the menu bar. A notched Mac's is 38pt and he
        // fits. A plain one is 24-25pt through Sequoia and about 31pt on Tahoe, and at
        // `Shape.height` he does not: his ears are drawn off the top of the display.
        //
        // Inside a FULLSCREEN Space this line is synthetic and must stay exactly at the top,
        // coplanar with the fullscreen window's own top edge, or he reads that edge as a
        // separate ledge and crouches and jumps at it forever. `visibleFrame.maxY ==
        // frame.maxY` is true both there and with the menu bar merely auto-hidden, and the
        // geometry alone cannot tell them apart, so ask the window list, which is already in
        // hand. That distinction is why an earlier unconditional clamp had to be reverted.
        // Two cases keep the line exactly where the system puts it. A fullscreen Space, per
        // above. And a NOTCHED display, where this line is the notch's lower lip: the cutout,
        // the den, the doorways and the tunnel are all measured from it, so moving it two
        // points to buy headroom quietly breaks all of them (`theNotchsLowerLipIsTheMenuBarLine`
        // says so). A notch strip is 38pt anyway, which he fits.
        let fullscreen = World.somethingFullscreen(in: windows, screen: screen, ownPID: ownPID)
        let menuY = fullscreen || screen.notch != nil
            ? screen.visibleFrame.maxY
            : min(screen.visibleFrame.maxY, screen.frame.maxY - Feel.Shape.height)
        let barSolid = punchNotch([standable], at: menuY)
            .filter { $0.length >= Feel.World.minStandWidth }
        surfaces.append(Surface(id: .menuBar, z: -1, y: menuY, extent: screenSpan,
                                solid: barSolid, spans: barSolid, targetable: true, rect: nil))

        // Normal windows are the only platform candidates.
        for (i, w) in visible.enumerated() where w.layer == 0 {
            let inset = Feel.World.cornerInset
            // Clipped in y as well as in x. The window list is global across every display,
            // and `snapshot` flips it against the PRIMARY, so a window straddling onto a
            // taller neighbouring screen has a top edge above this one's. Unclipped that
            // became walkable ground off the top of the panel: he can reach it with an
            // ordinary ~190pt jump, and then he is grounded somewhere he is never drawn, with
            // the click dead zone parked up there with him. It stays an occluder either way.
            guard w.rect.width >= Feel.World.minStandWidth + 2 * inset, w.rect.height >= 20,
                  w.rect.maxY <= screen.frame.maxY else { continue }
            let extent = w.rect.minX...w.rect.maxX
            let start = subtract([(w.rect.minX + inset)...(w.rect.maxX - inset)],
                                 // clip to where he is drawable by cutting everything outside it
                                 screen.frame.minX - 1e6 ... standable.lowerBound)
            let solid = punchNotch(subtract(start, standable.upperBound ... screen.frame.maxX + 1e6),
                                   at: w.rect.maxY)
                .filter { $0.length >= Feel.World.minStandWidth }
            surfaces.append(Surface(id: .window(w.id), z: i, y: w.rect.maxY, extent: extent,
                                    solid: solid, spans: carve(solid, y: w.rect.maxY, z: i),
                                    targetable: true, rect: w.rect))
        }

        // Floor. visibleFrame.minY already sits at the Dock's top edge when the Dock is
        // pinned, so floor and "Dock shelf" collapse into one surface. The exception is an
        // auto-hidden Dock that is currently revealed: without this he'd be masked away
        // entirely and it would look like a crash.
        // The Dock process also owns a FULL-SCREEN layer-20 window (its hit-testing
        // surface). Matching on owner+layer alone picks that one up and puts the floor at
        // the top of the screen, so he falls forever. Both extra conditions are load-bearing.
        let revealedDock = visible.first {
            $0.layer == 20 && $0.owner == "Dock"
                && $0.rect.minY <= screen.frame.minY + 1                // resting on the bottom edge
                && $0.rect.height < screen.frame.height * 0.25          // Dock-shaped, not screen-shaped
        }?.rect.maxY
        let floorY = max(screen.visibleFrame.minY, revealedDock ?? -.greatestFiniteMagnitude)
        // The floor's `solid` is deliberately NOT carved. A maximized window's rect starts
        // at visibleFrame.minY, which IS floorY, so carving deletes the entire floor and
        // leaves him with a two-node world. The desktop is still under Chrome, it just
        // cannot be seen, which is what `spans` is for.
        surfaces.append(Surface(id: .floor, z: .max, y: floorY, extent: screenSpan,
                                solid: [standable],
                                spans: carve([standable], y: floorY, z: .max),
                                targetable: true, rect: nil))

        return Skyline(surfaces: surfaces, occluders: occluders, screen: screen)
    }
}

// MARK: - Hysteresis

/// Window lists jitter. This smooths appearance and disappearance so he doesn't flicker.
public struct WorldTracker {
    private var missCount: [SurfaceID: Int] = [:]
    private var age: [SurfaceID: Int] = [:]
    private var lastKnown: [SurfaceID: Surface] = [:]
    private var holdOffLeft = 0

    /// Surfaces that became targetable on the most recent `ingest`, in the order they were
    /// seen. Refreshed every ingest, so a reader that skips a poll misses the event.
    ///
    /// Reported when they become TARGETABLE rather than when they first appear. `targetable`
    /// already exists to stop him chasing menus and sheets, which come and go inside a poll or
    /// two, so the glance inherits that filtering rather than growing its own copy of it. At
    /// the usual 10Hz that is a 200ms delay, which is nothing for a look.
    public private(set) var justAppeared: [SurfaceID] = []

    public init() {}

    /// Ignore disappearances for the next `polls` ingests. For a Space change, where the
    /// whole window list turns over at once and ordinary two-poll hysteresis is nowhere
    /// near deep enough. Misses are not counted while it holds, so the world he had before
    /// the switch survives intact rather than expiring on the first poll after.
    public mutating func holdOff(polls: Int) {
        holdOffLeft = max(holdOffLeft, polls)
    }

    public mutating func ingest(_ fresh: Skyline) -> Skyline {
        var out: [Surface] = []
        var seen = Set<SurfaceID>()

        // Read before the newcomers are aged, because it gates their reporting as well as
        // the misses below: a Space change replaces the whole cast at once, and the other
        // Space's furniture crossing the age threshold together is not news. Reported, it
        // would hand the mind a `windowOpened` per switch (0.30 of arousal, `canTravel`,
        // two inside a half-life is a trip), which is exactly what app switches are
        // deliberately barred from doing, smuggled in through the window channel. The new
        // cast crosses `minAgePolls` while the hold is still counting, since the hold is
        // deeper by design, so keeping quiet during it is what stops it.
        let holding = holdOffLeft > 0
        if holding { holdOffLeft -= 1 }

        justAppeared.removeAll(keepingCapacity: true)
        for var s in fresh.surfaces {
            seen.insert(s.id)
            missCount[s.id] = 0
            let a = (age[s.id] ?? 0) + 1
            age[s.id] = a
            s.targetable = a >= Feel.World.minAgePolls
            // Exactly on the transition, so it reports once rather than on every poll after.
            if a == Feel.World.minAgePolls, !holding { justAppeared.append(s.id) }
            lastKnown[s.id] = s
            out.append(s)
        }

        // Re-insert recently vanished surfaces so a one-frame dropout doesn't drop him.
        for (id, surface) in lastKnown where !seen.contains(id) {
            if holding {
                out.append(surface)
                continue
            }
            let misses = (missCount[id] ?? 0) + 1
            missCount[id] = misses
            if misses < Feel.World.vanishConfirmPolls {
                out.append(surface)
            } else {
                lastKnown[id] = nil
                age[id] = nil
                missCount[id] = nil
            }
        }

        return Skyline(surfaces: out, occluders: fresh.occluders, screen: fresh.screen)
    }
}

// MARK: - The one impure function

#if canImport(AppKit)
extension World {
    /// The only system call in the world model. ~298µs with 19 windows on an M-series Mac.
    public static func snapshot(flipOrigin: CGFloat) -> [RawWindow] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return list.compactMap { w in
            guard let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = w[kCGWindowLayer as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"]
            else { return nil }
            // CGWindowList is top-left origin against the PRIMARY display. NSScreen.main
            // means "screen with the key window" and would be a silent multi-monitor offset.
            return RawWindow(id: id, pid: pid, layer: layer,
                             rect: CGRect(x: x, y: flipOrigin - (y + height), width: width, height: height),
                             alpha: w[kCGWindowAlpha as String] as? Double ?? 1,
                             owner: w[kCGWindowOwnerName as String] as? String ?? "")
        }
    }
}
#endif
