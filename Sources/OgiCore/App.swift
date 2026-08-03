#if canImport(AppKit)
import AppKit

@MainActor
public final class OgiApp: NSObject, NSApplicationDelegate {

    private var overlay: Overlay!
    private var statusItem: NSStatusItem!
    private var tracker = WorldTracker()
    private var skyline = Skyline(surfaces: [], occluders: [],
                                  screen: ScreenGeometry(frame: .zero, visibleFrame: .zero, notch: nil))
    private var cat = CatState(position: .zero)
    private var gaze = Gaze()

    private var accumulator: TimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    private var lastPoll: CFTimeInterval = 0
    private var flipOrigin: CGFloat = 0
    private var ownPID = getpid()

    /// M0 only. Prints the answers to the four questions research could not settle.
    private var probeFired = false
    private var wasOverHim = false

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)

        guard let screen = NSScreen.main else { return }
        flipOrigin = NSScreen.screens[0].frame.maxY

        setupStatusItem()

        overlay = Overlay(screen: screen)
        overlay.onTick = { [weak self] t in self?.tick(t) }
        overlay.onClick = { p, onCat in
            // With the cursor poll driving ignoresMouseEvents, every click that reaches us
            // should be on him. An onCat=false here means the hit rect and the poll disagree.
            print("[probe] click at \(Int(p.x)),\(Int(p.y)) onCat=\(onCat)")
        }

        poll(force: true)
        // Drop him in from above the middle of the screen so the first thing he does is fall.
        // OGI_START="x,y" overrides it. M0 scaffolding: the fall is the behaviour that
        // matters most and it needs to be droppable onto a known window to be testable.
        var start = CGPoint(x: screen.frame.midX, y: screen.frame.maxY - 60)
        if let env = ProcessInfo.processInfo.environment["OGI_START"] {
            let parts = env.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 { start = CGPoint(x: parts[0], y: parts[1]) }
        }
        cat = CatState(position: start)
        overlay.start()

        let g = ScreenGeometry(screen)
        print("[ogi] screen=\(g.frame) visible=\(g.visibleFrame) notch=\(g.notch.map { "\($0)" } ?? "none")")
    }

    private func setupStatusItem() {
        // LSUIElement means no Dock icon, which is the point, but it also means no obvious
        // way to quit. The most common complaint about desktop pets in the wild is literally
        // "how do i remove it", so the way out exists before anyone else ever runs this.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🐈‍⬛"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit Ogi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    // MARK: - The one clock

    private func tick(_ now: CFTimeInterval) {
        if lastTick == 0 { lastTick = now; return }

        // The world poll is a gate inside the display link, not a Timer. When the link
        // pauses on screen lock, polling stops for free.
        let hz = NSEvent.pressedMouseButtons != 0 ? Feel.World.dragPollHz : Feel.World.pollHz
        if now - lastPoll >= 1.0 / hz { poll(force: false); lastPoll = now }

        // Clamp is NOT optional: without it the first tick after the link resumes from
        // screen lock integrates a multi-hour delta and launches him into orbit.
        accumulator += min(now - lastTick, Feel.Timing.maxFrameDelta)
        lastTick = now

        var steps = 0
        while accumulator >= Feel.Timing.fixedDT {
            steps += 1
            let before = cat.support
            cat = Cat.step(cat, world: skyline, dt: Feel.Timing.fixedDT)
            if before != cat.support { logSupportChange(from: before) }   // M0 probe
            accumulator -= Feel.Timing.fixedDT
        }

        // He looks at your cursor. The strongest aliveness signal that exists.
        let head = CGPoint(x: cat.position.x,
                           y: cat.position.y + Feel.Shape.height * Feel.Eyes.heightFraction)
        gaze.step(target: lookDirection(from: head, to: NSEvent.mouseLocation),
                  dt: CGFloat(Feel.Timing.fixedDT * Double(steps)))

        let h = heightAboveGround()
        overlay.render(cat, gaze: gaze, heightAboveGround: h,
                       occluders: skyline.occluders(above: perchZ(),
                                                    intersecting: hitRect().insetBy(dx: -40, dy: -h - 40)))

        let overHim = hitRect().contains(NSEvent.mouseLocation)
        overlay.setInteractive(overHim)
        if overHim != wasOverHim {   // M0 probe, delete with the rest
            print("[probe] cursor \(overHim ? "entered" : "left") him -> " +
                  "window \(overHim ? "now swallows clicks" : "is click-through")")
            wasOverHim = overHim
        }
        fireProbeOnce()
    }

    /// Where a click counts as touching him. Padded, because a 46x34 cat is a small target.
    private func hitRect() -> CGRect {
        CGRect(x: cat.position.x - Feel.Shape.width / 2, y: cat.position.y,
               width: Feel.Shape.width, height: Feel.Shape.height).insetBy(dx: -6, dy: -6)
    }

    private func poll(force: Bool) {
        guard let screen = NSScreen.main else { return }
        let raw = World.snapshot(flipOrigin: flipOrigin)
        let fresh = World.build(windows: raw, screen: ScreenGeometry(screen), ownPID: ownPID)
        skyline = tracker.ingest(fresh)
    }

    /// His depth in the window stack, which decides what is allowed to occlude him.
    ///
    /// He rests ON his perch, so his body occupies the band above it, which geometrically
    /// belongs to whatever is behind. He is therefore just in front of his perch and behind
    /// everything in front of it. Windows *behind* his perch never occlude him, even where
    /// they overlap his body — that is the case a naive "mask against every overlapping
    /// window" gets wrong.
    private func perchZ() -> Int {
        switch cat.support {
        case .grounded(let p):
            return skyline.surface(p.id)?.z ?? .max
        case .falling:
            // Use the surface he is heading for, so his depth stays stable through a fall.
            // He vanishes behind a frontmost window mid-drop and re-emerges below it.
            return skyline.supportBelow(x: cat.position.x, from: cat.position.y,
                                        to: -.greatestFiniteMagnitude)?.z ?? .max
        }
    }

    /// Distance to whatever is under him, for the contact shadow.
    private func heightAboveGround() -> CGFloat {
        if case .grounded = cat.support { return 0 }
        guard let below = skyline.supportBelow(x: cat.position.x,
                                               from: cat.position.y,
                                               to: -.greatestFiniteMagnitude) else { return 0 }
        return max(0, cat.position.y - below.y)
    }

    // MARK: - M0 probe

    private func logSupportChange(from before: Support) {
        switch (before, cat.support) {
        case (.grounded(let p), .falling):
            print("[probe] FALL — \(p.id) went away under him at y=\(Int(cat.position.y))")
        case (.falling, .grounded(let p)):
            print("[probe] LAND on \(p.id) at y=\(Int(cat.position.y)) " +
                  "squash=\(String(format: "%.2f", cat.squash)) (\(cat.activity))")
        default: break
        }
    }

    private func fireProbeOnce() {
        guard !probeFired, case .grounded(let perch) = cat.support else { return }
        probeFired = true
        let walkable = skyline.surfaces.filter { $0.id != .floor && $0.id != .menuBar }
        print("""
        [probe] landed on \(perch.id) after \(skyline.surfaces.count) surfaces built
        [probe] window surfaces: \(walkable.count), occluders: \(skyline.occluders.count)
        [probe] click on empty space to test click-through; use the menu bar cat to quit
        """)
    }
}
#endif
