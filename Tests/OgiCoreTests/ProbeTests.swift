// The behavioural harness for v2b. It asserts nothing on its own: it runs the real `Cat.step`
// loop over real desktop layouts and reports where he actually goes, which is the only way to
// see a mind that is subtly boring rather than broken.
//
// The v2a lesson, from its own handoff: eight of fifteen tasks failed first review because a
// test asserted the mechanism EXISTED rather than that it FIRED. A wrong scoring weight will
// not freeze him or skip a clip; it will just make him dull, and nothing anywhere will fail.
// So every v2b behaviour gets an assertion here, over a simulated run, on top of its unit test.
//
// OGI_PROBE=1 swift test --filter PROBE     — it takes ~30s, so it is off by default.
import Testing
import Foundation
import CoreGraphics
@testable import OgiCore

private let probeScreen = ScreenGeometry(
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1243),
    visibleFrame: CGRect(x: 0, y: 90, width: 1920, height: 1115),
    notch: CGRect(x: 856, y: 1206, width: 208, height: 37))

/// Captured live on 2026-08-04 from his actual screen.
private func realDesktop() -> Skyline {
    World.build(windows: [
        RawWindow(id: 1, pid: 100, layer: 0,
                  rect: CGRect(x: 254, y: 192, width: 847, height: 918),
                  alpha: 1, owner: "Ghostty"),
        RawWindow(id: 2, pid: 101, layer: 0,
                  rect: CGRect(x: 1167, y: 588, width: 580, height: 385),
                  alpha: 1, owner: "Terminal"),
    ], screen: probeScreen, ownPID: 999)
}

/// A busier desktop, for contrast.
private func busyDesktop() -> Skyline {
    World.build(windows: [
        RawWindow(id: 1, pid: 100, layer: 0, rect: CGRect(x: 254, y: 192, width: 847, height: 918),
                  alpha: 1, owner: "Ghostty"),
        RawWindow(id: 2, pid: 101, layer: 0, rect: CGRect(x: 1167, y: 588, width: 580, height: 385),
                  alpha: 1, owner: "Terminal"),
        RawWindow(id: 3, pid: 102, layer: 0, rect: CGRect(x: 60, y: 700, width: 500, height: 300),
                  alpha: 1, owner: "Safari"),
        RawWindow(id: 4, pid: 103, layer: 0, rect: CGRect(x: 1300, y: 150, width: 500, height: 300),
                  alpha: 1, owner: "Notes"),
    ], screen: probeScreen, ownPID: 999)
}

private func bareDesktop() -> Skyline {
    World.build(windows: [], screen: probeScreen, ownPID: 999)
}

private func name(_ id: SurfaceID) -> String {
    switch id {
    case .menuBar: return "menuBar"
    case .floor: return "floor"
    case .window(let w): return "window(\(w))"
    }
}

private struct Run {
    var decisions: [(from: SurfaceID, to: SurfaceID, dist: CGFloat)] = []
    /// Intents whose destination surface he was standing on when the intent ended.
    var arrived = 0
    var dwell: [String: Double] = [:]          // seconds grounded on each surface
    var activitySeconds: [String: Double] = [:]
    var movingSeconds: Double = 0
    var stillSeconds: Double = 0
    var endedOn: String = "?"
}

/// One session. `seconds` of simulated time at the real fixed timestep.
private func simulate(_ world: Skyline, seconds: Double, startAt: CGPoint,
                      startPerch: SurfaceID) -> Run {
    let dt = Feel.Timing.fixedDT
    var cat = CatState(position: startAt)
    guard let s0 = world.surface(startPerch) else { return Run() }
    cat.support = .grounded(Perch(id: startPerch, dx: startAt.x - s0.extent.lowerBound))
    var r = Run()
    var lastIntent: Intent?
    var lastGrounded: SurfaceID = startPerch

    for _ in 0..<Int(seconds / dt) {
        let before = cat
        cat = Cat.step(cat, world: world, dt: dt)

        // A decision is an intent appearing where there was none, or changing destination.
        let changed = lastIntent?.destination != cat.intent?.destination
            || abs((lastIntent?.destinationX ?? -1e9) - (cat.intent?.destinationX ?? -1e9)) > 0.01
        if changed {
            // The intent that just ended: did he reach the surface it named?
            if let old = lastIntent, case .grounded(let p) = cat.support, p.id == old.destination {
                r.arrived += 1
            }
            if let i = cat.intent, case .grounded(let p) = before.support {
                r.decisions.append((from: p.id, to: i.destination,
                                    dist: abs(i.destinationX - before.position.x)))
            }
        }
        lastIntent = cat.intent

        if case .grounded(let p) = cat.support {
            r.dwell[name(p.id), default: 0] += dt
            lastGrounded = p.id
        }
        r.activitySeconds["\(cat.activity)", default: 0] += dt
        if cat.isMoving { r.movingSeconds += dt } else { r.stillSeconds += dt }
    }
    r.endedOn = name(lastGrounded)
    return r
}

private func report(_ title: String, _ world: Skyline, runs: Int, seconds: Double) {
    print("\n=== \(title) — \(runs) runs x \(Int(seconds))s ===")
    for s in world.surfaces {
        print(String(format: "  surface %-12@ y=%6.0f spans=%d solidLen=%.0f",
                     name(s.id) as NSString, s.y, s.spans.count,
                     s.solid.reduce(0) { $0 + $1.length }))
    }

    var dwell: [String: Double] = [:]
    var toCount: [String: Int] = [:]
    var acts: [String: Double] = [:]
    var moving = 0.0, still = 0.0
    var endedOn: [String: Int] = [:]
    var dists: [CGFloat] = []
    var sameSurface = 0, total = 0
    var perRunDecisions: [Int] = []
    var matrix: [String: Int] = [:]
    var arrived = 0

    for i in 0..<runs {
        // Start each run somewhere different so the result is not an artifact of one start.
        let starts: [(CGPoint, SurfaceID)] = [
            (CGPoint(x: 400, y: 1205), .menuBar),
            (CGPoint(x: 1500, y: 1205), .menuBar),
            (CGPoint(x: 600, y: 1110), .window(1)),
            (CGPoint(x: 900, y: 90), .floor),
        ]
        var (p, id) = starts[i % starts.count]
        // Snap y to the real surface.
        if let s = world.surface(id) {
            p.y = s.y
            if !s.solid.contains(where: { $0.contains(p.x) }),
               let x = Cat.nearestSpanX(to: p.x, in: s.solid) { p.x = x }
        } else { (p, id) = (CGPoint(x: 400, y: 1205), .menuBar) }

        let r = simulate(world, seconds: seconds, startAt: p, startPerch: id)
        for (k, v) in r.dwell { dwell[k, default: 0] += v }
        for (k, v) in r.activitySeconds { acts[k, default: 0] += v }
        moving += r.movingSeconds; still += r.stillSeconds
        endedOn[r.endedOn, default: 0] += 1
        perRunDecisions.append(r.decisions.count)
        arrived += r.arrived
        for d in r.decisions {
            toCount[name(d.to), default: 0] += 1
            matrix["\(name(d.from)) -> \(name(d.to))", default: 0] += 1
            dists.append(d.dist)
            if d.from == d.to { sameSurface += 1 }
            total += 1
        }
    }

    let wall = Double(runs) * seconds
    print("  -- time --")
    print(String(format: "  moving %.1f%%   still %.1f%%", moving / wall * 100, still / wall * 100))
    print("  -- where he spends it (%% of grounded time) --")
    let dwellTotal = dwell.values.reduce(0, +)
    for (k, v) in dwell.sorted(by: { $0.value > $1.value }) {
        print(String(format: "  %-12@ %5.1f%%", k as NSString, v / dwellTotal * 100))
    }
    print("  -- destinations chosen --")
    for (k, v) in toCount.sorted(by: { $0.value > $1.value }) {
        print(String(format: "  %-12@ %5.1f%%  (n=%d)", k as NSString,
                     Double(v) / Double(max(total, 1)) * 100, v))
    }
    print(String(format: "  same-surface strolls: %.1f%% of decisions", Double(sameSurface) / Double(max(total, 1)) * 100))
    print("  -- from -> to (decisions) --")
    for (k, v) in matrix.sorted(by: { $0.value > $1.value }) {
        print(String(format: "  %-26@ %5d  (%.1f%% of all)", k as NSString, v,
                     Double(v) / Double(max(total, 1)) * 100))
    }
    print(String(format: "  intents that reached their destination surface: %.1f%%",
                 Double(arrived) / Double(max(total, 1)) * 100))
    let sorted = dists.sorted()
    if !sorted.isEmpty {
        print(String(format: "  trip distance: median %.0fpt  p90 %.0fpt  max %.0fpt",
                     Double(sorted[sorted.count / 2]),
                     Double(sorted[min(sorted.count - 1, sorted.count * 9 / 10)]),
                     Double(sorted.last!)))
    }
    print(String(format: "  decisions per minute: %.2f", Double(total) / (wall / 60)))
    print("  -- ended the run on --")
    for (k, v) in endedOn.sorted(by: { $0.value > $1.value }) {
        print("  \(k): \(v)/\(runs)")
    }
    print("  -- activity (%% of time) --")
    for (k, v) in acts.sorted(by: { $0.value > $1.value }) where v / wall > 0.005 {
        print(String(format: "  %-12@ %5.1f%%", k as NSString, v / wall * 100))
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["OGI_PROBE"] != nil))
func PROBE_currentBehaviour() {
    report("his real desktop (Ghostty + Terminal)", realDesktop(), runs: 40, seconds: 600)
    report("a busier desktop (4 windows)", busyDesktop(), runs: 40, seconds: 600)
    report("a bare desktop", bareDesktop(), runs: 40, seconds: 600)
}

/// Task 1's acceptance. Baseline before the fix, measured 2026-08-04 over 40 x 600s:
/// `floor -> menuBar` was 49.1% of every decision, and 47.4% of intents reached the surface
/// they named. Both are properties of a whole simulated run and cannot be asserted from a
/// single call to `nextMove`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["OGI_PROBE"] != nil))
func PROBE_heDoesNotPaceTowardTheUnreachable() {
    var impossible = 0, total = 0, arrived = 0
    for i in 0..<40 {
        let starts: [(CGPoint, SurfaceID)] = [
            (CGPoint(x: 400, y: 1205), .menuBar), (CGPoint(x: 900, y: 90), .floor),
        ]
        var (p, id) = starts[i % starts.count]
        let world = bareDesktop()
        if let s = world.surface(id) { p.y = s.y }
        let r = simulate(world, seconds: 600, startAt: p, startPerch: id)
        arrived += r.arrived
        for d in r.decisions {
            total += 1
            if d.from == .floor && d.to == .menuBar { impossible += 1 }
        }
    }
    let impossibleRate = Double(impossible) / Double(max(total, 1))
    let arrivalRate = Double(arrived) / Double(max(total, 1))
    print(String(format: "impossible %.1f%%  arrived %.1f%%", impossibleRate * 100, arrivalRate * 100))
    #expect(impossibleRate == 0, "he still sets out for the menu bar from the floor")
    #expect(arrivalRate >= 0.80, "under 80% of his intents reach the surface they named")
}
