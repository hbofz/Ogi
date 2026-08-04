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
    private var tail = TailSim()
    private let signals = Signals()
    private var sense = Sensations()
    private var walkPhase: CGFloat = 0
    private var crouchAmount: CGFloat = 0

    private var accumulator: TimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    private var lastPoll: CFTimeInterval = 0
    private var lastRender: CFTimeInterval = 0
    /// Ticks once a second while he is deeply asleep, so the display link can be stopped
    /// outright instead of firing 60 times a second to decide it has nothing to do.
    private var slumberTimer: DispatchSourceTimer?
    private var flipOrigin: CGFloat = 0
    private var ownPID = getpid()

    /// The screen the overlay was built for. `NSScreen.main` means "screen with the key
    /// window" and changes when you click an app on another display, which silently
    /// rebuilt the entire skyline against different geometry every poll.
    private var homeScreen: NSScreen!
    /// ...and the same screen by display ID, because AppKit rebuilds the `NSScreen` array on
    /// every reconfiguration. The pinned object survives as a stale husk whose `frame` no
    /// longer describes anything, so it has to be re-resolved rather than retained.
    private var homeDisplay: CGDirectDisplayID?

    /// OGI_DEBUG=1 narrates what he is doing. Off, he is silent.
    private let debug = ProcessInfo.processInfo.environment["OGI_DEBUG"] != nil
    private var wasOverHim = false
    private var lastActivity: Activity = .idle

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)

        guard let screen = NSScreen.main else { return }
        homeScreen = screen
        homeDisplay = OgiApp.displayID(screen)
        flipOrigin = NSScreen.screens[0].frame.maxY

        setupStatusItem()

        overlay = Overlay(screen: screen)
        overlay.onTick = { [weak self] t in self?.tick(t) }
        overlay.onDrag = { [weak self] phase, point in self?.handleDrag(phase, point) }
        overlay.onClick = { [weak self] p, onCat in
            // With the cursor poll driving ignoresMouseEvents, every click that reaches us
            // should be on him. onCat=false means the hit rect and the poll disagree.
            self?.log("click at \(Int(p.x)),\(Int(p.y)) onCat=\(onCat)")
        }

        // Waking is the one failure that would be fatal: a cat who never comes back is a
        // hung app. So the 1Hz idle check is backed up by workspace events — any app
        // launch, activation or Space change revives him regardless.
        for name: NSNotification.Name in [NSWorkspace.didActivateApplicationNotification,
                                          NSWorkspace.didLaunchApplicationNotification,
                                          NSWorkspace.activeSpaceDidChangeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.leaveSlumber()
                    // A Space change replaces every window on screen at once. Held, he keeps
                    // the world he had until the new one has arrived; unheld, he reads the
                    // turnover as every platform vanishing and falls.
                    if name == NSWorkspace.activeSpaceDidChangeNotification {
                        self.tracker.holdOff(polls: Feel.World.spaceChangeHoldOffPolls)
                    }
                }
            }
        }

        // The displays changed shape. Not waking him for it is deliberate: the window and the
        // geometry are rebuilt where he sleeps, and he finds out when he next opens his eyes.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }

        signals.onWake = { [weak self] in
            guard let self else { return }
            // He was asleep too: stretch and shake off before resuming.
            self.leaveSlumber()
            self.lastTick = 0
            self.overlay.resume()
        }

        if debug {
            // Lets the harness exercise the goodbye. A hang on quit would be the worst bug
            // in the app, and clicking a menu bar item is not automatable without granting
            // Accessibility, which this app refuses to ask for even in tests.
            DistributedNotificationCenter.default().addObserver(
                forName: .init("com.ogi.debug.quit"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.goHomeAndQuit() }
            }
        }

        poll(force: true)
        cat = arrival(on: screen)
        overlay.start()

        let g = ScreenGeometry(screen)
        log("screen=\(g.frame) visible=\(g.visibleFrame) notch=\(g.notch.map { "\($0)" } ?? "none")")
    }

    /// Optional, and deliberately not defaulted: a screen whose ID cannot be read must match
    /// nothing. Falling back to 0 makes every unreadable screen equal to every other one, so
    /// a single failed bridge silently pins him to whichever unreadable screen comes first.
    private static func displayID(_ s: NSScreen) -> CGDirectDisplayID? {
        s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// A display was connected, disconnected, or changed resolution. Every cached piece of
    /// screen geometry is now a lie: the overlay window is sized for the old configuration
    /// and he is drawn outside it, `flipOrigin` belongs to a primary display that may not be
    /// the primary any more, and `homeScreen` is a stale `NSScreen` — worse than out of date,
    /// because AppKit has already replaced the object and its frame feeds `World.build`,
    /// which builds a world with nothing to stand on out of degenerate geometry.
    private func screensChanged() {
        guard overlay != nil, !NSScreen.screens.isEmpty else { return }
        // His display if it is still attached; otherwise he moves in with whatever is left.
        // `homeDisplay` is NOT reassigned to the fallback: a monitor going to sleep, a KVM
        // flip and an input-source change all arrive as a disconnect followed by a reconnect,
        // and repinning here would move him to the laptop permanently on the first one.
        let screen = homeDisplay.flatMap { id in NSScreen.screens.first { OgiApp.displayID($0) == id } }
            ?? NSScreen.main ?? NSScreen.screens[0]
        homeScreen = screen
        flipOrigin = NSScreen.screens[0].frame.maxY     // the primary display can be a new one
        overlay.setFrame(screen.frame)
        poll(force: true)
        cat = OgiApp.reseat(cat, into: screen.visibleFrame)
        // The doorway he came out of may not be on this screen any more. Better an instant
        // goodbye than an eight-second walk toward an x that no longer exists.
        if let h = homeX, !(screen.visibleFrame.minX...screen.visibleFrame.maxX).contains(h) {
            homeX = nil
        }
        // He is not woken for this. If he was asleep the world is rebuilt around him and he
        // finds out when he next opens his eyes; one redraw keeps the picture honest until
        // then, without restarting the clock.
        renderNow()
        log("screens changed -> \(screen.frame)")
    }

    /// Where he goes when the desktop moves out from under him. Unplug a display and the
    /// point he is standing at can stop existing: he slips off a perch that got shorter,
    /// falls past a floor whose `solid` does not contain him, and falls forever off the edge
    /// of the world. Pure and static so the one branch in it is testable without an
    /// NSApplication.
    ///
    /// Both axes, in both directions. Below is not the harmless side: a built-in display
    /// arranged *under* an external one has a negative frame origin, so unplugging the
    /// external leaves him at a y beneath the new desktop — and `Skyline.supportBelow` only
    /// ever searches downward, so the floor above him can never catch him.
    static func reseat(_ cat: CatState, into visible: CGRect) -> CatState {
        let margin = Feel.Shape.width / 2
        let x = min(max(cat.position.x, visible.minX + margin), visible.maxX - margin)
        let y = min(max(cat.position.y, visible.minY), visible.maxY)
        guard x != cat.position.x || y != cat.position.y else { return cat }
        var s = cat
        s.position = CGPoint(x: x, y: y)
        // Whatever he was standing on was measured against geometry that is gone, so the
        // perch cannot survive the move. Drop him and let the ordinary fall find him ground.
        s.support = .falling
        s.velocity = .zero
        s.activity = .airborne
        s.activityElapsed = 0
        s.intent = nil
        s.lastPerchOrigin = nil
        return s
    }

    /// First launch: the notch opens and a cat walks out. That is the entire onboarding.
    private func arrival(on screen: NSScreen) -> CatState {
        // OGI_START="x,y" drops him somewhere specific instead. Test scaffolding.
        if let env = ProcessInfo.processInfo.environment["OGI_START"] {
            let parts = env.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 {
                return CatState(position: CGPoint(x: parts[0], y: parts[1]))
            }
        }

        let g = ScreenGeometry(screen)
        guard let notch = g.notch, let bar = skyline.surface(.menuBar) else {
            // No notch, or no menu bar to walk out onto: he simply drops in.
            return CatState(position: CGPoint(x: screen.frame.midX, y: screen.frame.maxY - 60))
        }

        let c = OgiApp.arrival(notch: notch, bar: bar, screenMaxX: screen.frame.maxX)
        homeX = c.position.x        // the doorway he came out of is the one he goes back into
        return c
    }

    /// He steps out of the doorway, not out of the middle of it. The notch is a hardware
    /// cutout with no pixels behind it, which is precisely why it is a hole in the menu
    /// bar's `solid`: standing at its centre is standing on nothing, and he falls on the
    /// first tick. So he starts on its lip, with the rest of him overhanging the cutout —
    /// where `World.build`'s permanent notch occluder masks him away — creeps out, and walks
    /// into the lit strip. Peeking out of the hole, achieved with the geometry rather than in
    /// spite of it. (The version of this that placed him at `notch.midX` worked only while the
    /// walk consulted `extent`; against `solid` it is a cat standing on nothing.)
    ///
    /// Pure and static so the launch placement is testable without an NSApplication.
    static func arrival(notch: CGRect, bar: Surface, screenMaxX: CGFloat) -> CatState {
        // Out the side with more room, and far enough to clear the cutout entirely.
        let goRight = (screenMaxX - notch.maxX) > notch.minX
        let doorway = goRight ? notch.maxX : notch.minX
        var c = CatState(position: CGPoint(x: doorway, y: bar.y))
        c.support = .grounded(Perch(id: .menuBar, dx: doorway - bar.extent.lowerBound))
        // Half of him is inside the cutout, where the notch occluder masks him away, so what
        // is on screen is a cat coming out of the hole rather than one appearing beside it.
        // `Cat.step` holds the walk until the clip has played.
        c.activity = .peek
        c.activityElapsed = 0
        let out = goRight ? notch.maxX + Feel.Shape.width : notch.minX - Feel.Shape.width
        c.intent = Intent(destination: .menuBar, destinationX: out, move: .walk(out))
        c.facing = goRight ? 1 : -1
        c.restLeft = Feel.Timing.restMin
        return c
    }

    /// Where he goes to be gone. Nil on a Mac with no notch.
    private var homeX: CGFloat?
    private var leaving = false

    /// The edge of the cutout on *his* side of it. `homeX` is fixed at launch to the one he
    /// came out of, and the two are only the same while he stays on that side.
    static func doorway(from x: CGFloat, toward homeX: CGFloat, on bar: Surface) -> CGFloat {
        // Already standing on it. Not a formality: the lip is where the wall branch parks him
        // after every bump, and the runs either side of the cutout are closed, so asking which
        // way to walk from a boundary he already occupies picks the run *behind* him and sends
        // him to the far end of the screen.
        guard x != homeX else { return homeX }
        return Cat.edgeAhead(from: x, facing: x < homeX ? 1 : -1, on: bar) ?? homeX
    }

    private func setupStatusItem() {
        // LSUIElement means no Dock icon, which is the point, but it also means no obvious
        // way to quit. The most common complaint about desktop pets in the wild is literally
        // "how do i remove it", so the way out exists before anyone else ever runs this.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🐈‍⬛"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit Ogi", action: #selector(goHomeAndQuit), keyEquivalent: "q"))
        menu.items.last?.target = self
        statusItem.menu = menu
    }

    /// A goodbye, not a process termination. He walks back into the notch and it closes
    /// behind him.
    @objc private func goHomeAndQuit() {
        guard let homeX, !leaving, case .grounded = cat.support else {
            NSApp.terminate(nil)
            return
        }
        leaving = true
        overlay.resume()
        leaveSlumber()
        cat.listening = false
        cat.repose = .awake
        let bar = skyline.surface(.menuBar)
        // He steps onto the bar wherever he happens to be — unless that is under the notch,
        // which is a hole in it. From there there is nothing to step onto, so he is already
        // at the doorway as far as the walk home is concerned.
        let startX = bar?.solid.contains { $0.contains(cat.position.x) } == true ? cat.position.x : homeX
        cat.support = .grounded(Perch(id: .menuBar, dx: startX - (bar?.extent.lowerBound ?? 0)))
        cat.position = CGPoint(x: startX, y: bar?.y ?? cat.position.y)
        // He goes in the near side of the doorway, not the side he came out of. Sending him
        // to the far one routes him across the cutout, which is a wall: he would stop at the
        // lip and quitting would sit there for the whole eight seconds below.
        let goingTo = bar.map { OgiApp.doorway(from: startX, toward: homeX, on: $0) } ?? homeX
        self.homeX = goingTo        // the arrival check in `tick` has to match where he went
        cat.intent = Intent(destination: .menuBar, destinationX: goingTo, move: .walk(goingTo))
        log("going home")
        // Never hang on the way out. Generous enough to cover the longest walk home from
        // anywhere on a wide screen, because quitting must never wait on the animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { NSApp.terminate(nil) }
    }

    // MARK: - The one clock

    private func tick(_ now: CFTimeInterval) {
        if lastTick == 0 { lastTick = now; return }

        sense = signals.sample(now: now)

        // Advance the clock BEFORE any early return, or a path that skips it steps the
        // physics zero times and he stands frozen while the world moves around him.
        //
        // The clamp is NOT optional either: without it the first tick after the display
        // link resumes from screen lock integrates a multi-hour delta and launches him
        // into orbit.
        accumulator += min(now - lastTick, Feel.Timing.maxFrameDelta)
        lastTick = now

        if leaving {
            // On the way out he ignores the machine entirely and just walks home.
            stepPhysics(now)
            renderNow()
            if let homeX, abs(cat.position.x - homeX) < Feel.Physics.arrivalSlop * 2 {
                log("home")
                NSApp.terminate(nil)
            }
            return
        }
        // Restless mode keeps him awake as well as impatient, or he simply sits down after
        // 30s of you not touching the machine and there is nothing to watch.
        cat.repose = Feel.Timing.restless ? .awake : Repose.from(idleSeconds: sense.idleSeconds)
        cat.listening = sense.micLive
        cat.languor = sense.languor

        // You locked the screen, so he goes home and everything suspends. This is the
        // manifesto's "all polling suspends", and it costs one early return.
        if sense.asleep {
            overlay.suspend()   // resumed by Signals.onWake, never from in here
            return
        }

        // Deep sleep. `preferredFrameRateRange` is honoured on ProMotion and IGNORED on a
        // fixed-refresh display, where the link keeps firing 60 times a second and we
        // merely do less per fire. Since the battery cost of a desktop pet is wakeups
        // rather than pixels, "less work per wakeup" is not the fix — stopping is.
        if cat.repose == .asleep, !cat.isMoving, cat.intent == nil {
            enterSlumber()
            return
        }
        overlay.setPreferredRate(renderRate())

        // The world poll is a gate inside the display link, not a Timer.
        let hz = pollRate()
        if now - lastPoll >= 1.0 / hz { poll(force: false); lastPoll = now }

        // The render-rate ladder. The real battery cost of a desktop pet is processor
        // wakeups, not pixels: RunCat draws complaints at 4 wakeups/second, and a naive
        // 60Hz display link is fifteen times worse. So when he is settled and nothing is
        // moving, we stop doing work entirely rather than redrawing an unchanged cat.
        let interval = 1.0 / renderRate()
        guard cat.isMoving || now - lastRender >= interval else { return }
        lastRender = now

        stepPhysics(now)
        renderNow()

        // While he is held the window must keep swallowing events even if the cursor
        // outruns him, or a fast drag drops him the instant it leaves his hit rect.
        var overHim = hitRect().contains(NSEvent.mouseLocation)
        if case .held = cat.support { overHim = true }
        overlay.setInteractive(overHim)
        if overHim != wasOverHim {
            log("cursor \(overHim ? "entered" : "left") him -> " +
                "window \(overHim ? "swallows clicks" : "is click-through")")
            wasOverHim = overHim
        }
        if cat.activity != lastActivity {
            log("\(lastActivity) -> \(cat.activity) at x=\(Int(cat.position.x)) y=\(Int(cat.position.y))")
            lastActivity = cat.activity
        }
    }

    private func log(_ m: String) { if debug { print("[ogi] \(m)") } }

    // MARK: - Being handled

    private var dragSamples: [(t: CFTimeInterval, p: CGPoint)] = []

    private func handleDrag(_ phase: DragPhase, _ point: CGPoint) {
        switch phase {
        case .began:
            guard hitRect().contains(point) else { return }
            cat = Cat.grab(cat, at: point)
            dragSamples = [(CACurrentMediaTime(), point)]
            log("scruffed")
        case .moved:
            guard case .held = cat.support else { return }
            cat.support = .held(point)
            dragSamples.append((CACurrentMediaTime(), point))
            if dragSamples.count > 6 { dragSamples.removeFirst() }
        case .ended:
            guard case .held = cat.support else { return }
            // Throw velocity from the last few samples, not from the final pair: a single
            // frame of jitter at release otherwise launches him across the screen.
            var v = CGVector.zero
            if let first = dragSamples.first, let last = dragSamples.last {
                let dt = last.t - first.t
                if dt > 0.001 {
                    v = CGVector(dx: (last.p.x - first.p.x) / CGFloat(dt),
                                 dy: (last.p.y - first.p.y) / CGFloat(dt))
                }
            }
            cat = Cat.release(cat, throwVelocity: v, world: skyline)
            dragSamples = []
            log("released, righting")
        }
    }

    /// Advances everything that is computed rather than simulated: the gait cycle, the
    /// crouch blend, and the tail.
    private func buildPose(dt: CGFloat) -> Body.Pose {
        var pose = Body.Pose()

        let walking = cat.activity == .walk
        pose.stride = walking ? 1 : 0
        if walking {
            // Gait speed follows the speed he is actually moving at, so the feet do not skate.
            // Against the constant it used to read, the wind-up and the coast to a halt would
            // both be moonwalks, and a trot would have been one all along.
            walkPhase += dt * abs(cat.perchSpeed) / Feel.Shape.strideLength
            walkPhase = walkPhase.truncatingRemainder(dividingBy: 1)
        }
        pose.walkPhase = walkPhase

        // Blend into and out of the crouch rather than snapping, so the wind-up reads.
        let wantCrouch: CGFloat = cat.activity == .crouch ? 1 : 0
        crouchAmount += (wantCrouch - crouchAmount) * min(1, dt * 18)
        pose.crouch = crouchAmount

        switch cat.support {
        case .falling: pose.airborne = true
        case .held: pose.airborne = true; pose.dangling = true
        case .clinging: pose.airborne = true    // nothing under his feet, but not dangling
        case .grounded: break
        }
        pose.righting = cat.righting
        pose.earAngle = cat.activity == .landHard ? -0.35 : 0

        // The tail is simulated in body space, so it inherits the mirror and the squash for
        // free and never needs unwinding from the world transform.
        tail.step(base: Body.tailBase(pose), dt: dt)
        pose.tail = tail.points
        return pose
    }

    private var lastSteps = 1

    private func stepPhysics(_ now: CFTimeInterval) {
        var steps = 0
        while accumulator >= Feel.Timing.fixedDT {
            steps += 1
            let before = cat.support
            cat = Cat.step(cat, world: skyline, dt: Feel.Timing.fixedDT)
            if before != cat.support { logSupportChange(from: before) }
            accumulator -= Feel.Timing.fixedDT
        }
        lastSteps = max(steps, 1)
    }

    /// The rect he is actually drawn in, this frame. Set by `renderNow`, read by hit
    /// testing, so the thing you click is the thing you see.
    private var drawnRect: CGRect = .zero

    private func renderNow() {
        let dt = CGFloat(Feel.Timing.fixedDT * Double(lastSteps))
        let pose = buildPose(dt: dt)
        let frame = Sprites.frame(for: cat, pose: pose)
        drawnRect = frame.rect(at: cat.position)

        // He looks at your cursor. The strongest aliveness signal that exists.
        let head = CGPoint(x: cat.position.x,
                           y: cat.position.y + Feel.Shape.height * Feel.Eyes.heightFraction)
        gaze.step(target: lookDirection(from: head, to: NSEvent.mouseLocation), dt: dt)

        let h = heightAboveGround()
        overlay.render(cat, pose: pose, gaze: gaze, frame: frame, heightAboveGround: h,
                       occluders: skyline.occluders(above: perchZ(),
                                                    intersecting: hitRect().insetBy(dx: -40, dy: -h - 40)))
    }

    /// Where a click counts as touching him. Padded, because he is a small target.
    private func hitRect() -> CGRect {
        (drawnRect == .zero ? CGRect(x: cat.position.x - Feel.Shape.width / 2,
                                     y: cat.position.y,
                                     width: Feel.Shape.width, height: Feel.Shape.height)
                            : drawnRect).insetBy(dx: -6, dy: -6)
    }

    /// Stops the clock entirely and watches for your return once a second. One wakeup a
    /// second is ~600k a week, comfortably under what the Dock itself costs.
    private func enterSlumber() {
        guard slumberTimer == nil else { return }
        overlay.suspend()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(400))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let idle = CGEventSource.secondsSinceLastEventType(
                .hidSystemState, eventType: CGEventType(rawValue: ~0)!)
            guard Repose.from(idleSeconds: idle) != .asleep else { return }
            self.leaveSlumber()
        }
        t.resume()
        slumberTimer = t
        log("asleep — display link stopped, watching at 1Hz")
    }

    private func leaveSlumber() {
        guard slumberTimer != nil else { return }
        slumberTimer?.cancel()
        slumberTimer = nil
        lastTick = 0            // do not integrate the whole nap in one step
        overlay.resume()
        log("awake")
    }

    /// Burst while a mouse button is down, because a dragged window's position otherwise
    /// arrives as a 100ms staircase and he strobes along it.
    private func pollRate() -> Double {
        if NSEvent.pressedMouseButtons != 0 { return Feel.World.dragPollHz }
        switch cat.repose {
        case .awake, .sitting: return Feel.World.pollHz
        case .curled: return 4
        case .asleep: return 1
        }
    }

    private func renderRate() -> Double {
        if cat.isMoving { return 60 }
        switch cat.repose {
        case .awake: return 30
        case .sitting: return 12
        case .curled: return 8
        case .asleep: return 4
        }
    }

    private func poll(force: Bool) {
        guard let screen = homeScreen else { return }
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
        case .clinging(let g):
            // In front of the window he is gripping, behind everything in front of it.
            // Exactly the perch rule.
            return skyline.surface(g.id)?.z ?? .max
        case .falling:
            // Use the surface he is heading for, so his depth stays stable through a fall.
            // He vanishes behind a frontmost window mid-drop and re-emerges below it.
            return skyline.supportBelow(x: cat.position.x, from: cat.position.y,
                                        to: -.greatestFiniteMagnitude)?.z ?? .max
        case .held:
            return -1   // in your hand, in front of everything
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
            // A deliberate jump is also grounded -> falling, so distinguish them or every
            // launch reads as his window having been closed.
            log(cat.activity == .airborne
                ? "JUMP from \(p.id) at y=\(Int(cat.position.y))"
                : "FALL — \(p.id) went away under him at y=\(Int(cat.position.y))")
        case (.falling, .grounded(let p)):
            log("LAND on \(p.id) at y=\(Int(cat.position.y)) " +
                "squash=\(String(format: "%.2f", cat.squash))")
        default: break
        }
    }

}
#endif
