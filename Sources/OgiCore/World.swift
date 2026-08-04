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
    /// Splitting this from `spans` is the fix for three separate bugs. He used to be able
    /// to stand on a rounded corner where no window is drawn; a maximized window used to
    /// delete the floor outright; and the notch was not a hole, so he walked through the
    /// cutout and vanished.
    public var solid: [ClosedRange<CGFloat>]
    /// Where he is currently visible: `solid` minus everything in front. Governs where he
    /// *prefers* to be. **Never used to decide whether he falls** — see `Skyline`.
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
    /// Defined once because getting it wrong has already caused three separate bugs, all
    /// with the same root cause: **the Dock process owns a full-screen layer-20 window**
    /// in addition to the visible Dock. It straddles every surface and sits in front of
    /// everything, so counting it as geometry variously put the floor at the top of the
    /// screen, masked him away entirely, and carved every walkable span down to nothing.
    ///
    /// Menus, popovers, sheets and tooltips are excluded for a second reason: they are
    /// above our window level, so they already occlude him for real, and they are
    /// transient — a walkable ledge should not evaporate because someone opened a menu.
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
        // invisible. Modelling it as a permanent occluder in front of everything — z = -2, ahead
        // of even the menu bar's -1, because it is physically in front of everything — means the
        // mask that already exists does the work: the part of him inside the cutout is clipped
        // away and only the part outside shows. That is what makes peeking out of it real,
        // rather than a trick that only worked while he was a black cat against a black bezel.
        //
        // `layer: 0` is load-bearing, not decoration: `occluders(above:intersecting:)` filters on
        // `isRealWindow`, so at any other layer this would be silently ignored.
        //
        // Deliberately NOT in `fromWindows`, which is what `carve` reads — and that array is
        // named for where it comes from rather than for what it holds, so that appending to the
        // wrong one is a visible mistake rather than a natural-looking one. The notch covers no
        // surface's top edge (its underside is the menu bar line, and the bar's own hole is cut
        // structurally out of `solid` below), so letting it carve walkable spans would delete
        // ground for no reason beyond which array it happened to be added to.
        let occluders = screen.notch.map { [Occluder(rect: $0, z: -2, layer: 0)] + fromWindows }
            ?? fromWindows
        let screenSpan = screen.visibleFrame.minX...screen.visibleFrame.maxX

        /// Cuts every occluder in front of `z` whose body straddles the line at `y`.
        func carve(_ initial: [ClosedRange<CGFloat>], y: CGFloat, z: Int) -> [ClosedRange<CGFloat>] {
            var spans = initial
            for o in fromWindows where o.isRealWindow && o.z < z {
                // `>` and not `>=`: coplanar top edges must not erase each other.
                guard o.rect.minY <= y, o.rect.maxY > y + Feel.World.coplanarEpsilon else { continue }
                guard o.rect.minX <= o.rect.maxX else { continue }
                spans = subtract(spans, o.rect.minX...o.rect.maxX)
            }
            return spans.filter { $0.length >= Feel.World.minStandWidth }
        }

        var surfaces: [Surface] = []

        // Menu bar. Always present, effectively never occluded (z = -1), but the notch is a
        // genuine hole in it: a hardware cutout with no pixels behind it. Cutting it out of
        // `solid` is what stops him walking through the doorway and disappearing.
        let menuY = screen.visibleFrame.maxY
        var barSolid = [screenSpan]
        if let notch = screen.notch {
            barSolid = subtract(barSolid, notch.minX...notch.maxX)
        }
        barSolid = barSolid.filter { $0.length >= Feel.World.minStandWidth }
        surfaces.append(Surface(id: .menuBar, z: -1, y: menuY, extent: screenSpan,
                                solid: barSolid, spans: barSolid, targetable: true, rect: nil))

        // Normal windows are the only platform candidates.
        for (i, w) in visible.enumerated() where w.layer == 0 {
            let inset = Feel.World.cornerInset
            guard w.rect.width >= Feel.World.minStandWidth + 2 * inset, w.rect.height >= 20 else { continue }
            let extent = w.rect.minX...w.rect.maxX
            let start = subtract([(w.rect.minX + inset)...(w.rect.maxX - inset)],
                                 // clip to the visible screen by cutting everything outside it
                                 screen.frame.minX - 1e6 ... screen.visibleFrame.minX)
            let solid = subtract(start, screen.visibleFrame.maxX ... screen.frame.maxX + 1e6)
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
        // at visibleFrame.minY, which IS floorY, so carving deleted the entire floor and
        // left him with a two-node world. The desktop is still under Chrome; you just
        // cannot see it, which is what `spans` is for.
        surfaces.append(Surface(id: .floor, z: .max, y: floorY, extent: screenSpan,
                                solid: [screenSpan],
                                spans: carve([screenSpan], y: floorY, z: .max),
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
        // would hand the mind a `windowOpened` per switch — 0.30 of arousal, `canTravel`,
        // two inside a half-life is a trip — which is exactly what app switches were
        // deliberately barred from doing, smuggled in through the window channel. The new
        // cast crosses `minAgePolls` while the hold is still counting, since the hold is
        // deeper by design, so keeping quiet during it is the whole fix.
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
