// The behavioural harness for v2b. It asserts nothing on its own: it runs the real `Cat.step`
// loop over real desktop layouts and reports where he actually goes, which is the only way to
// see a mind that is subtly boring rather than broken.
//
// The v2a lesson, from its own handoff: eight of fifteen tasks failed first review because a
// test asserted the mechanism EXISTED rather than that it FIRED. A wrong scoring weight will
// not freeze him or skip a clip; it will just make him dull, and nothing anywhere will fail.
// So every v2b behaviour gets an assertion here, over a simulated run, on top of its unit test.
//
// OGI_PROBE=1 swift test --filter PROBE     (it takes ~30s, so it is off by default)
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
    print("\n=== \(title): \(runs) runs x \(Int(seconds))s ===")
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

/// B1's acceptance, calm half. A unit test can only show that a stimulus produces a glance;
/// this shows that a window opening on a running cat actually reaches him, over and over,
/// while he is busy doing other things.
@Test(.enabled(if: ProcessInfo.processInfo.environment["OGI_PROBE"] != nil))
func PROBE_heLooksAtWindowsThatOpen() {
    let dt = Feel.Timing.fixedDT
    var noticed = 0, opened = 0
    for run in 0..<40 {
        let world = realDesktop()
        var cat = CatState(position: CGPoint(x: 400 + CGFloat(run % 5) * 100, y: 1205))
        cat.support = .grounded(Perch(id: .menuBar, dx: cat.position.x))
        var sawGlance = false
        for tick in 0..<(120 * 600) {
            // A window opens every 60 simulated seconds.
            if tick % (120 * 60) == 0, tick > 0 {
                cat.stimulus = Stimulus(kind: .windowOpened, at: CGPoint(x: 1500, y: 700))
                opened += 1
                sawGlance = false
            }
            cat = Cat.step(cat, world: world, dt: dt)
            if cat.lookingAt != nil, !sawGlance { noticed += 1; sawGlance = true }
        }
    }
    let rate = Double(noticed) / Double(max(opened, 1))
    print(String(format: "glanced at %.1f%% of windows that opened", rate * 100))
    #expect(rate >= 0.90, "he ignored more than one window in ten")
}

/// B1's acceptance, roused half.
///
/// Measured against the windows that opened **while he was free to act**, not against every
/// window. Most openings land while he is already on a trip, and the rule that a stimulus never
/// re-targets a trip already underway is deliberate, so counting those as misses would be
/// measuring how busy he happens to be rather than whether the gate works. The absolute rate is
/// printed for information: it came out at 27.8% roused against 0% calm, which is the honest
/// on-screen figure for how often a window opening actually moves him.
@Test(.enabled(if: ProcessInfo.processInfo.environment["OGI_PROBE"] != nil))
func PROBE_aRousedCatGoesToLook() {
    let dt = Feel.Timing.fixedDT
    func rates(arousal: Double) -> (all: Double, whenFree: Double) {
        var approached = 0, opened = 0, free = 0
        for run in 0..<40 {
            let world = realDesktop()
            var cat = CatState(position: CGPoint(x: 400 + CGFloat(run % 5) * 100, y: 1205))
            cat.support = .grounded(Perch(id: .menuBar, dx: cat.position.x))
            for tick in 0..<(120 * 600) {
                cat.arousal = arousal            // held, so the measurement is about the gate
                if tick % (120 * 60) == 0, tick > 0 {
                    let wasFree = cat.intent == nil
                    cat.stimulus = Stimulus(kind: .windowOpened, at: CGPoint(x: 650, y: 1110))
                    opened += 1
                    if wasFree { free += 1 }
                    cat = Cat.step(cat, world: world, dt: dt)
                    // Matched on the exact destination the promotion computes, not merely on the
                    // surface. Boredom picks a uniform x on that same window often enough to
                    // register as a chase otherwise, which showed up as a calm cat "chasing" one
                    // window in 360 and is a coincidence rather than a behaviour.
                    let promoted = Cat.nearestSpanX(to: 650, in: world.surface(.window(1))?.spans ?? [])
                    if wasFree, cat.intent?.destination == .window(1),
                       cat.intent?.destinationX == promoted { approached += 1 }
                    continue
                }
                cat = Cat.step(cat, world: world, dt: dt)
            }
        }
        return (Double(approached) / Double(max(opened, 1)),
                Double(approached) / Double(max(free, 1)))
    }
    let calm = rates(arousal: 0)
    let roused = rates(arousal: 1)
    print(String(format: "approach rate: calm %.1f%%  roused %.1f%% (%.1f%% of those he was free for)",
                 calm.all * 100, roused.all * 100, roused.whenFree * 100))
    #expect(calm.all == 0, "a calm cat chased a window")
    #expect(roused.whenFree >= 0.90,
            "a roused and idle cat ignored a window he could have gone to look at")
    #expect(roused.all > 0.20, "a roused cat almost never actually moves; the dial is decorative")
}

/// B4's acceptance, in two independent halves.
///
/// This probe took three attempts and the failures were all in the measurement, so the reasons
/// are worth keeping. Sampling one moment ("the first tick his intent goes nil near the cursor")
/// caught him in the single-tick gap before the yield rule acts. Matching the exact destination
/// on the menu bar missed him coming to the equivalent spot on whichever surface he was actually
/// standing on, which is the same behaviour. And a cursor inside the notch has no spot beside it
/// at all, which is a property of the cutout rather than of him.
///
/// What the feature actually claims is simpler than any of those, so that is what is measured:
/// **he spends more of his time near your cursor when it has gone still than when it has not.**
@Test(.enabled(if: ProcessInfo.processInfo.environment["OGI_PROBE"] != nil))
func PROBE_heComesToYourCursorAndYourClicksStillWork() {
    let dt = Feel.Timing.fixedDT

    /// Fraction of the run spent within a body length of the cursor, and the longest unbroken
    /// stretch spent directly under it.
    func measure(cursorGoesStill: Bool) -> (near: Double, worstSit: Double) {
        var nearTicks = 0, totalTicks = 0
        var worstSit = 0.0
        for run in 0..<40 {
            let world = realDesktop()
            guard let bar = world.surface(.menuBar) else { continue }
            // Clear of the notch, which has no "beside" to offer.
            let startX = 300 + CGFloat(run % 8) * 40
            var cat = CatState(position: CGPoint(x: startX, y: bar.y))
            cat.support = .grounded(Perch(id: .menuBar, dx: startX))
            let cursor = CGPoint(x: startX + 250, y: bar.y)
            var sitting = 0.0

            for _ in 0..<(120 * 300) {
                cat.cursor = cursor
                // The whole independent variable: has it settled, or is it still moving?
                cat.cursorStill = cursorGoesStill ? cat.cursorStill + dt : 0
                cat = Cat.step(cat, world: world, dt: dt)

                totalTicks += 1
                if abs(cat.position.x - cursor.x) < 60, abs(cat.position.y - cursor.y) < 40 {
                    nearTicks += 1
                }
                let rect = CGRect(x: cat.position.x - Feel.Shape.width / 2, y: cat.position.y,
                                  width: Feel.Shape.width, height: Feel.Shape.height)
                sitting = rect.contains(cursor) ? sitting + dt : 0
                worstSit = max(worstSit, sitting)
            }
        }
        return (Double(nearTicks) / Double(max(totalTicks, 1)), worstSit)
    }

    let moving = measure(cursorGoesStill: false)
    let still = measure(cursorGoesStill: true)
    print(String(format: "near your cursor: %.1f%% of the time when it is still, %.1f%% when it is not",
                 still.near * 100, moving.near * 100))
    print(String(format: "longest spell directly under the pointer: %.2fs still, %.2fs moving",
                 still.worstSit, moving.worstSit))

    #expect(still.near > moving.near * 2,
            "a cursor going still barely changes where he spends his time; the behaviour is not firing")

    // He gets off within a beat rather than instantly, and that is the yield rule walking rather
    // than teleporting: the step aside is Shape.width/2 + cursorGap minus his overshoot, about
    // 31pt, which at walkSpeed 46 through accel 220 is roughly a second, plus the tick he takes
    // to notice. Two and a half seconds is that with room, and anything beyond it means he has
    // settled under the pointer rather than passing through.
    #expect(still.worstSit < 2.5,
            "he sat under the pointer for \(still.worstSit)s rather than moving aside")
}

/// What actually happens when you open two windows next to each other, the way a person does.
///
/// The existing roused-half probe HELD arousal at 1 to isolate the gate. That measures the gate
/// and not the mechanic: in real use arousal has to be earned by the openings themselves, and
/// whether it reaches the threshold depends on the gap between them, on how much it decayed,
/// and on whether he happened to be free at that moment. This measures the whole path.
@Test(.enabled(if: ProcessInfo.processInfo.environment["OGI_PROBE"] != nil))
func PROBE_openingTwoWindowsTheWayAPersonDoes() {
    let dt = Feel.Timing.fixedDT
    for gap in [2.0, 5.0, 10.0, 20.0] {
        var went = 0, freeAtSecond = 0
        for run in 0..<60 {
            let world = realDesktop()
            let startX = 300 + CGFloat(run % 10) * 120
            var cat = CatState(position: CGPoint(x: startX, y: 1205))
            cat.support = .grounded(Perch(id: .menuBar, dx: startX))
            // Settle him into ordinary life first, so his state is realistic rather than fresh.
            for _ in 0..<(120 * 30) { cat = Cat.step(cat, world: world, dt: dt) }

            let first = Int(120 * 5), second = first + Int(120 * gap)
            for tick in 0..<(120 * 120) {
                if tick == first {
                    cat.stimulus = Stimulus(kind: .windowOpened, at: CGPoint(x: 650, y: 1110))
                }
                if tick == second {
                    // Only a cat who was FREE and then set off counts. Counting the end state
                    // alone credits an ordinary boredom trip that happened to pick window(1),
                    // which is one surface in four.
                    let wasFree = cat.intent == nil
                    if wasFree { freeAtSecond += 1 }
                    cat.stimulus = Stimulus(kind: .windowOpened, at: CGPoint(x: 650, y: 1110))
                    cat = Cat.step(cat, world: world, dt: dt)
                    if wasFree, cat.intent?.destination == .window(1) { went += 1 }
                    continue
                }
                cat = Cat.step(cat, world: world, dt: dt)
            }
        }
        print(String(format: "two windows %.0fs apart: he went over %d/60 (free to act %d/60)",
                     gap, went, freeAtSecond))
    }
}
