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
    /// Full top-edge extent. This is the perch anchor, and it does NOT shrink when
    /// another window is raised over part of it.
    public var extent: ClosedRange<CGFloat>
    /// The subspans actually visible right now. Governs where he chooses to walk.
    /// Never used to decide whether he falls — see `Skyline`.
    public var spans: [ClosedRange<CGFloat>]
    public var targetable: Bool
}

public struct Occluder: Sendable {
    public let rect: CGRect
    public let z: Int
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
    public func supportBelow(x: CGFloat, from y0: CGFloat, to y1: CGFloat) -> Surface? {
        let lo = min(y0, y1), hi = max(y0, y1)
        return surfaces
            .filter { s in
                s.y >= lo && s.y <= hi && s.extent.contains(x)
            }
            // Highest surface wins; ties break to the frontmost window.
            .max { a, b in (a.y, -a.z) < (b.y, -b.z) }
    }

    /// Everything strictly in front of the perch. He rests ON his perch, so his body
    /// occupies the band above it, which belongs to whatever is behind. He is therefore
    /// just in front of his perch and behind everything in front of it.
    public func occluders(above z: Int, intersecting r: CGRect) -> [CGRect] {
        occluders.filter { $0.z < z && $0.rect.intersects(r) }.map(\.rect)
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

        let occluders = visible.enumerated().map { Occluder(rect: $1.rect, z: $0) }
        let screenSpan = screen.visibleFrame.minX...screen.visibleFrame.maxX

        /// Cuts every occluder in front of `z` whose body straddles the line at `y`.
        func carve(_ initial: [ClosedRange<CGFloat>], y: CGFloat, z: Int) -> [ClosedRange<CGFloat>] {
            var spans = initial
            for o in occluders where o.z < z {
                // `>` and not `>=`: coplanar top edges must not erase each other.
                guard o.rect.minY <= y, o.rect.maxY > y + Feel.World.coplanarEpsilon else { continue }
                guard o.rect.minX <= o.rect.maxX else { continue }
                spans = subtract(spans, o.rect.minX...o.rect.maxX)
            }
            return spans.filter { $0.length >= Feel.World.minStandWidth }
        }

        var surfaces: [Surface] = []

        // Menu bar. Always present, effectively never occluded.
        let menuY = screen.visibleFrame.maxY
        surfaces.append(Surface(id: .menuBar, z: -1, y: menuY, extent: screenSpan,
                                spans: [screenSpan], targetable: true))

        // Normal windows are the only platform candidates.
        for (i, w) in visible.enumerated() where w.layer == 0 {
            let inset = Feel.World.cornerInset
            guard w.rect.width >= Feel.World.minStandWidth + 2 * inset, w.rect.height >= 20 else { continue }
            let extent = w.rect.minX...w.rect.maxX
            let start = subtract([(w.rect.minX + inset)...(w.rect.maxX - inset)],
                                 // clip to the visible screen by cutting everything outside it
                                 screen.frame.minX - 1e6 ... screen.visibleFrame.minX)
            let clipped = subtract(start, screen.visibleFrame.maxX ... screen.frame.maxX + 1e6)
            let spans = carve(clipped, y: w.rect.maxY, z: i)
            surfaces.append(Surface(id: .window(w.id), z: i, y: w.rect.maxY,
                                    extent: extent, spans: spans, targetable: true))
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
        surfaces.append(Surface(id: .floor, z: .max, y: floorY, extent: screenSpan,
                                spans: carve([screenSpan], y: floorY, z: .max), targetable: true))

        return Skyline(surfaces: surfaces, occluders: occluders, screen: screen)
    }
}

// MARK: - Hysteresis

/// Window lists jitter. This smooths appearance and disappearance so he doesn't flicker.
public struct WorldTracker {
    private var missCount: [SurfaceID: Int] = [:]
    private var age: [SurfaceID: Int] = [:]
    private var lastKnown: [SurfaceID: Surface] = [:]

    public init() {}

    public mutating func ingest(_ fresh: Skyline) -> Skyline {
        var out: [Surface] = []
        var seen = Set<SurfaceID>()

        for var s in fresh.surfaces {
            seen.insert(s.id)
            missCount[s.id] = 0
            let a = (age[s.id] ?? 0) + 1
            age[s.id] = a
            s.targetable = a >= Feel.World.minAgePolls
            lastKnown[s.id] = s
            out.append(s)
        }

        // Re-insert recently vanished surfaces so a one-frame dropout doesn't drop him.
        for (id, surface) in lastKnown where !seen.contains(id) {
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
