#if canImport(AppKit)
import AppKit

@MainActor
public final class OgiApp: NSObject, NSApplicationDelegate {

    private var overlay: Overlay!
    private var statusItem: NSStatusItem!
    private var tracker = WorldTracker()
    /// The last raw snapshot, kept so an app activation can be mapped to one of its windows
    /// by pid. `Surface` deliberately does not carry a pid.
    private var lastRaw: [RawWindow] = []
    /// Whether the desktop he launched into has been reported as new yet. See `poll`.
    private var sawLaunchWorld = false
    /// When `cursorStill` was last advanced. `tick` has no fixed rate, so this is measured
    /// against the clock rather than counted in ticks.
    private var lastCursorSample: CFTimeInterval = 0
    /// Edge-triggered: the retreat fires when the world BECOMES fullscreen, not on every poll
    /// for as long as it stays that way.
    private var wasFullscreen = false
    /// The previous power sample, for the plug-in edge. Nil until the first sample.
    private var wasCharging: Bool?
    /// ...and the previous battery percentage, for the crossing-below-20 edge.
    private var lastPercent: Int?
    private var skyline = Skyline(surfaces: [], occluders: [],
                                  screen: ScreenGeometry(frame: .zero, visibleFrame: .zero, notch: nil))
    private var cat = CatState(position: .zero)
    private var gaze = Gaze()
    private let signals = Signals()
    private var sense = Sensations()
    private var walkPhase: CGFloat = 0

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
    /// window" and changes when you click an app on another display, which would silently
    /// rebuild the entire skyline against different geometry every poll.
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
        // Line-buffered, or redirecting the narration to a file gets you the first 4KB and
        // nothing else until the process exits cleanly, and a GUI app being watched is one you
        // kill. Watching it on the machine is what finds the real bugs, so the instrument has
        // to survive being switched off.
        if debug { setvbuf(stdout, nil, _IOLBF, 0) }

        guard let screen = NSScreen.main else { return }
        homeScreen = screen
        homeDisplay = OgiApp.displayID(screen)
        flipOrigin = NSScreen.screens[0].frame.maxY

        setupStatusItem()

        overlay = Overlay(screen: screen)
        overlay.onTick = { [weak self] t in self?.tick(t) }
        overlay.onDrag = { [weak self] phase, point in self?.handleDrag(phase, point) }
        overlay.onClick = { [weak self] p, onCat in
            // With the cursor poll driving ignoresMouseEvents, every click that arrives should
            // be on him. onCat=false means the hit rect and the poll disagree.
            self?.log("click at \(Int(p.x)),\(Int(p.y)) onCat=\(onCat)")
        }

        // Waking is the one failure that would be fatal: a cat who never comes back is a
        // hung app. So the 1Hz idle check is backed up by workspace events: any app
        // launch, activation or Space change revives him regardless.
        for name: NSNotification.Name in [NSWorkspace.didActivateApplicationNotification,
                                          NSWorkspace.didLaunchApplicationNotification,
                                          NSWorkspace.activeSpaceDidChangeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] note in
                // Read out of the notification here rather than inside the isolated block: an
                // NSNotification is not Sendable and cannot cross the boundary, but a pid is.
                let switchedTo = (note.userInfo?[NSWorkspace.applicationUserInfoKey]
                                    as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.leaveSlumber()
                    // A Space change replaces every window on screen at once. Held, he keeps
                    // the world he had until the new one has arrived; unheld, he reads the
                    // turnover as every platform vanishing and falls.
                    if name == NSWorkspace.activeSpaceDidChangeNotification {
                        self.tracker.holdOff(polls: Feel.World.spaceChangeHoldOffPolls)
                    } else if let pid = switchedTo,
                              let w = self.lastRaw.first(where: {
                                  $0.pid == pid && $0.layer == 0
                              }) {
                        // Cats notice when you move rooms. The activated app is matched to one
                        // of its windows through the last raw snapshot, because `Surface`
                        // deliberately does not carry a pid and adding one would be a second
                        // copy of something the snapshot already knows.
                        self.cat.receive(Stimulus(kind: .appSwitched,
                                                  at: CGPoint(x: w.rect.midX, y: w.rect.maxY)))
                        self.log("you switched to \(w.owner)")
                    }
                }
            }
        }

        // The machine is going to sleep, so he settles first. Same stimulus as the fullscreen
        // retreat: the destination is home either way and only the prompt differs.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.headHome(because: "machine is sleeping, heading home")
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
            // He was asleep too: stretch and shake off before resuming. Set here as well as
            // in leaveSlumber, because a lock-and-unlock suspends the overlay without ever
            // entering slumber, and coming back deserves the same greeting.
            self.cat.owed = .stretch
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
            // Lets the harness fire the zap without touching the power cable, which cannot be
            // scripted.
            DistributedNotificationCenter.default().addObserver(
                forName: .init("com.ogi.debug.zap"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.cat.owed = .zap
                    self?.log("debug zap owed")
                }
            }
            // ...and the same for the notch behaviours, for a sharper reason than
            // convenience. **A screenshot cannot show what the notch hides**: `screencapture`
            // fills the cutout with the wallpaper, so a cat drawn inside it looks correct in
            // the PNG and is invisible on the real panel. Every one of these has to be judged
            // by a person looking at the hardware, and waiting for boredom to roll a hang at a
            // doorway is not a way to do that. `notch=<hang|peer|den|cross>`.
            DistributedNotificationCenter.default().addObserver(
                forName: .init("com.ogi.debug.notch"), object: nil, queue: .main) { [weak self] n in
                // Read off the notification BEFORE hopping actors: `Notification` is not
                // Sendable and capturing one in a main-actor closure is a data race. A String
                // is.
                let what = n.object as? String
                MainActor.assumeIsolated {
                    guard let self, let what else { return }
                    self.forceNotchBehaviour(what)
                }
            }
        }

        poll(force: true)
        cat = arrival(on: screen)
        overlay.start()

        let g = ScreenGeometry(screen)
        log("screen=\(g.frame) visible=\(g.visibleFrame) notch=\(g.notch.map { "\($0)" } ?? "none")")
    }

    /// Puts him into one of the notch behaviours on demand, for OGI_DEBUG builds only.
    ///
    /// Not a shortcut around the real triggers (they are tested) but the only way a person
    /// can *look* at these. Three of the four are invisible to `screencapture` by construction,
    /// since the cutout comes back as wallpaper in a PNG, so judging them means being sat in
    /// front of the machine when they run.
    private func forceNotchBehaviour(_ what: String) {
        guard let notch = skyline.screen.notch, let bar = skyline.surface(.menuBar) else {
            log("debug notch: no notch on this screen")
            return
        }
        // "wake" is the one command that must not reposition him or clear `inNotch`: the whole
        // point is to watch what he does on coming out of the den, which is the swing-out.
        if what == "wake" {
            debugRepose = nil
            leaveSlumber()
            log("debug wake, owed \(cat.owed.map { "\($0)" } ?? "nothing")")
            return
        }

        overlay.resume()
        leaveSlumber()
        debugRepose = nil
        debugCall = nil
        cat.repose = .awake
        cat.intent = nil
        cat.inNotch = false
        cat.notchSide = .below
        cat.notchLift = 0

        func stand(at x: CGFloat) {
            cat.position = CGPoint(x: x, y: bar.y)
            cat.support = .grounded(Perch(id: .menuBar, dx: x - bar.extent.lowerBound))
            cat.perchSpeed = 0
        }

        switch what {
        case "hang", "peer":
            stand(at: notch.midX)
            cat.inNotch = true
            cat.facing = -1
            cat.activity = what == "hang" ? .hang : .peerDown
        // The two side placements: a quarter turn onto a VERTICAL edge of the cutout, paws on
        // the edge and head out sideways into the lit strip of menu bar beside the hole. His
        // world position is that point on the edge, halfway up the notch band.
        case "peerL", "peerR":
            let onLeft = what == "peerL"
            stand(at: onLeft ? notch.minX : notch.maxX)
            cat.inNotch = true
            cat.facing = onLeft ? -1 : 1
            cat.notchSide = onLeft ? .left : .right
            cat.notchLift = notch.height * Feel.Notch.sidePeekHeight
            cat.activity = .peerDown
        case "den":
            stand(at: notch.midX)
            cat.inNotch = true
            // Pinned, not merely set: `tick` re-derives `repose` from your idle time on every
            // frame, so this has to outlast the next one. Cleared by any other debug command.
            debugRepose = .asleep
            cat.repose = .asleep
            cat.activity = .sleep
        // The three call rigs, without needing a call. `Signals` re-derives both flags every
        // tick from the real devices, so these have to be pinned the way the den is.
        case "talk", "work", "full":
            stand(at: notch.minX - Feel.Shape.clearance * 2)
            debugCall = (mic: what != "work", camera: what != "talk")
            cat.activity = .onCall
        case "cross":
            stand(at: notch.minX)
            cat.facing = 1
            cat.intent = Intent(destination: .menuBar,
                                destinationX: notch.maxX + Feel.Shape.clearance * 4,
                                move: .crossNotch(notch.maxX))
            cat.activity = .walk
        default:
            log("debug notch: unknown '\(what)'")
            return
        }
        cat.activityElapsed = 0
        log("debug notch \(what) at x=\(cat.position.x)")
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
    /// the primary any more, and `homeScreen` is a stale `NSScreen`, worse than out of date,
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
        // ...and this screen may have a doorway he has never been told about. `homeX` was
        // written only by `arrival` and the goodbye, and cleared here, so it was decided once
        // at launch and could only ever be lost. Launch on an external, unplug it, and he
        // spends the rest of the session on a notched built-in with no home: the retreats and
        // the quit walk go to the status item instead of into the den beside him.
        if homeX == nil, let notch = ScreenGeometry(screen).notch,
           let bar = skyline.surface(.menuBar) {
            let goRight = (screen.frame.maxX - notch.maxX) > notch.minX
            let doorway = goRight ? notch.maxX : notch.minX
            if bar.solid.contains(where: { $0.contains(doorway) }) { homeX = doorway }
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
    /// external leaves him at a y beneath the new desktop, and `Skyline.supportBelow` only
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
        guard let bar = skyline.surface(.menuBar) else {
            // Nothing up there to stand on at all. He drops in and finds his own floor.
            return CatState(position: CGPoint(x: screen.frame.midX, y: screen.frame.maxY - 60))
        }
        // No notch, so no doorway: he starts standing on the bar instead of falling past it.
        guard let notch = g.notch else {
            return OgiApp.arrivalOnBar(bar: bar, near: screen.frame.midX)
        }

        let c = OgiApp.arrival(notch: notch, bar: bar, screenMaxX: screen.frame.maxX)
        homeX = c.position.x        // the doorway he came out of is the one he goes back into
        return c
    }

    /// He steps out of the doorway, not out of the middle of it. The notch is a hardware
    /// cutout with no pixels behind it, which is precisely why it is a hole in the menu
    /// bar's `solid`: standing at its centre is standing on nothing, and he falls on the
    /// first tick. So he starts on its lip, with the rest of him overhanging the cutout
    /// (where `World.build`'s permanent notch occluder masks him away), creeps out, and walks
    /// into the lit strip. Peeking out of the hole, achieved with the geometry rather than in
    /// spite of it.
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

    /// A Mac with no notch, which is every Mac except a 2021-or-later MacBook Pro or a
    /// 2022-or-later Air, plus every external display and every clamshell. He has no doorway
    /// to come out of, so he simply starts standing on the menu bar.
    ///
    /// **This branch used to drop him in mid-air and strand him for the session.** The guard
    /// above unwrapped the bar and then threw it away, spawning him at `frame.maxY - 60` with
    /// `support` defaulting to `.falling`. The bar sits at `visibleFrame.maxY`, at most ~38pt
    /// below `frame.maxY`, so that spawn was ALWAYS strictly below the only thing up there,
    /// and `Skyline.supportBelow` searches downward only. On a bare desktop he fell straight
    /// past it onto the Dock line and stayed: a jump clears ~190pt against a ~1000pt climb,
    /// with no window face to climb. His whole first impression was a cat dropping out of the
    /// sky and never moving again.
    ///
    /// Pure and static so the launch placement is testable without an NSApplication, like
    /// `arrival(notch:bar:screenMaxX:)` beside it.
    static func arrivalOnBar(bar: Surface, near x: CGFloat) -> CatState {
        // Onto pixels, not merely into the extent: the bar's `solid` already excludes the
        // rounded corners and anything off-screen.
        let x = Cat.nearestSpanX(to: x, in: bar.solid)
            ?? min(max(x, bar.extent.lowerBound), bar.extent.upperBound)
        var c = CatState(position: CGPoint(x: x, y: bar.y))
        c.support = .grounded(Perch(id: .menuBar, dx: x - bar.extent.lowerBound))
        c.restLeft = Feel.Timing.restMin
        return c
    }

    /// The notch doorway he came out of. Nil on a Mac with no notch. `effectiveHomeX` is
    /// what the retreats and the goodbye actually use.
    private var homeX: CGFloat?
    private var leaving = false
    /// OGI_DEBUG only. Holds `repose` and the two call signals against the per-tick
    /// re-derivation, so a forced state can be looked at for longer than one frame. Both are
    /// nil in every shipping build.
    private var debugRepose: Repose?
    private var debugCall: (mic: Bool, camera: Bool)?

    /// Where he goes to be gone. The notch doorway when he came out of one; under his own
    /// menu bar item otherwise, because that is the one piece of him always in the bar and
    /// it is where you click to quit. Nil only when there is no bar at all, in which case
    /// retreats do nothing and quitting is instant.
    private var effectiveHomeX: CGFloat? {
        if let homeX { return homeX }
        guard let bar = skyline.surface(.menuBar) else { return nil }
        let icon = statusItem?.button?.window?.frame.midX
        // Clamped to standing room, so the walk home never aims at a lip.
        return Cat.standingRoom(near: icon ?? bar.extent.upperBound, in: bar.spans)
    }

    /// Where he WAITS when he goes home: beside the doorway rather than in it.
    ///
    /// The notch is a hardware hole with no pixels behind it, so a cat centred on its lip has
    /// everything past that lip simply not drawn, and a retreat parked there leaves half of him
    /// missing for as long as it lasts, which on a covered screen is the whole film. He stops a
    /// body-width short, with all of him on lit pixels, and `Cat.denDoor` reaches that far so he
    /// still holds the den pose when he gets there.
    ///
    /// `goHomeAndQuit` deliberately does NOT use this. Leaving means going *into* the hole, and
    /// so does the launch emergence: both are motion, which reads as a doorway. Only stopping
    /// there reads as a bug.
    ///
    /// Pure and static so both lips are testable without an NSApplication.
    static func denX(_ home: CGFloat, notch: CGRect?) -> CGFloat {
        guard let notch else { return home }
        // Only the two lips are doorways; anywhere else on the bar there is no hole to stand
        // out of, and shifting him would just be an unexplained 26pt of drift.
        if abs(home - notch.minX) < 1 { return notch.minX - Feel.Shape.clearance }
        if abs(home - notch.maxX) < 1 { return notch.maxX + Feel.Shape.clearance }
        return home
    }

    /// The edge of the cutout on *his* side of it, or `homeX` itself when no lip lies on the
    /// way, which is every notchless Mac, where home is mid-run and the edge ahead is the
    /// screen corner. `homeX` is fixed at launch to the doorway he came out of, and the two
    /// are only the same while he stays on that side.
    static func doorway(from x: CGFloat, toward homeX: CGFloat, on bar: Surface) -> CGFloat {
        // Already standing on it. Not a formality: the lip is where the wall branch parks him
        // after every bump, and the runs either side of the cutout are closed, so asking which
        // way to walk from a boundary he already occupies picks the run *behind* him and sends
        // him to the far end of the screen.
        guard x != homeX else { return homeX }
        guard let edge = Cat.edgeAhead(from: x, facing: x < homeX ? 1 : -1, on: bar),
              x < homeX ? edge < homeX : edge > homeX
        else { return homeX }
        return edge
    }

    private func setupStatusItem() {
        // LSUIElement means no Dock icon, which is the point, but it also means no obvious
        // way to quit. The most common complaint about desktop pets in the wild is literally
        // "how do i remove it", so the way out exists from the start.
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
        guard let home = effectiveHomeX, !leaving, case .grounded = cat.support else {
            NSApp.terminate(nil)
            return
        }
        leaving = true
        overlay.resume()
        leaveSlumber()
        cat.listening = false
        cat.repose = .awake
        let bar = skyline.surface(.menuBar)
        // He steps onto the bar wherever he happens to be, unless that is under the notch,
        // which is a hole in it. From there there is nothing to step onto, so he is already
        // at the doorway as far as the walk home is concerned.
        let startX = bar?.solid.contains { $0.contains(cat.position.x) } == true ? cat.position.x : home
        cat.support = .grounded(Perch(id: .menuBar, dx: startX - (bar?.extent.lowerBound ?? 0)))
        cat.position = CGPoint(x: startX, y: bar?.y ?? cat.position.y)
        // He goes in the near side of the doorway, not the side he came out of. Sending him
        // to the far one routes him across the cutout, which is a wall: he would stop at the
        // lip and quitting would sit there for the whole eight seconds below.
        let goingTo = bar.map { OgiApp.doorway(from: startX, toward: home, on: $0) } ?? home
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
        // `debugRepose` is set only by the notch harness, and only in OGI_DEBUG builds. This
        // line rewrites `repose` every frame from your HID idle time, and under OGI_RESTLESS
        // with `.awake` unconditionally, so a forced state has to override both or it never
        // survives a tick.
        cat.repose = debugRepose
            ?? (Feel.Timing.restless ? .awake
                : Repose.from(idleSeconds: sense.idleSeconds, scale: slumberScale))
        cat.listening = debugCall?.mic ?? sense.micLive
        // The camera lives in the notch. This is what bars him from his own den for the length
        // of a call, and what puts the headphones on him.
        cat.onCamera = debugCall?.camera ?? sense.cameraLive
        // Typing hard enough that the kind thing is to stay out of your way. Two thresholds, or
        // he flickers in and out of the pose at every pause for breath.
        cat.typingHard = cat.typingHard
            ? sense.typingRate > Feel.Mind.typingCalm
            : sense.typingRate > Feel.Mind.typingAlert
        cat.languor = sense.languor
        // The performances. Power arriving is the zap, an audio device is the groove, something
        // on the cable is curiosity, and the battery going properly low is the power-down.
        // All edges only App can see; each first sample
        // records rather than fires, so a Mac that launches plugged in does not open with
        // a jolt.
        if let was = wasCharging, sense.charging != was {
            log("power \(sense.charging ? "arrived -> zap owed" : "left")")
            if sense.charging { cat.owed = .zap }
        }
        wasCharging = sense.charging
        if sense.audioArrived { cat.owed = .vibe; log("new ears -> vibe owed") }
        if sense.usbArrived { cat.owed = .curious; log("something on the cable -> curious owed") }
        if let p = sense.batteryPercent, let was = lastPercent, p < 20, was >= 20,
           !sense.charging {
            cat.owed = .droop
            log("battery crossed \(p)% -> droop owed")
        }
        lastPercent = sense.batteryPercent ?? lastPercent

        // Cats approach when you go still, so how long it has NOT moved is the signal.
        //
        // Measured against `now` rather than counted in ticks: `tick` runs at whatever the
        // render-rate ladder is doing, from 60Hz down to 4, so a per-tick increment would make
        // sixty seconds mean fifteen to a settled cat.
        let pointer = NSEvent.mouseLocation
        let moved = cat.cursor.map { hypot(pointer.x - $0.x, pointer.y - $0.y) > 2 } ?? true
        cat.cursorStill = moved ? 0 : cat.cursorStill + (now - lastCursorSample)
        lastCursorSample = now
        cat.cursor = pointer

        // You locked the screen, so he goes home and everything suspends. This is the
        // "all polling suspends" rule, and it costs one early return.
        if sense.asleep {
            // Stop the purr on the way out. This returns 60-odd lines above the stroke's edge
            // check, which is the only thing that ever ends a continuous purr, and a continuous
            // purr has `purrTapsLeft = .max`, so its own self-cancel is about 1.2e10 seconds
            // away. `suspend()` only stops the display link, and the link is what would have
            // run the edge check, so a screen locked mid-stroke left the timer buzzing the
            // trackpad until the machine woke. `strokeTravel` decays inside `Cat.step`, which
            // this return also skips, so the state could not lapse out of it either.
            purr(false)
            overlay.suspend()   // resumed by Signals.onWake, never from in here
            return
        }

        // Deep sleep. `preferredFrameRateRange` is honoured on ProMotion and IGNORED on a
        // fixed-refresh display, where the link keeps firing 60 times a second and each fire
        // merely does less. Since the battery cost of a desktop pet is wakeups rather than
        // pixels, "less work per wakeup" is not the fix, stopping is.
        if cat.repose == .asleep, !cat.isMoving, cat.intent == nil {
            // One last frame, and then the clock stops.
            //
            // Returning here without stepping and drawing would mean **the sleep pose is never
            // rendered at all**: the last thing on screen stays whatever the previous tick drew.
            // Falling asleep at the doorway has to move him *into* the cutout and swap the sheet
            // for `denSleep`, and both of those happen inside `Cat.step`, so skipping it makes
            // the den unreachable.
            //
            // Costs one step and one draw, once, on the tick he settles. The zero-wakeup
            // guarantee is untouched: `enterSlumber` still stops the display link outright and
            // this branch cannot run twice, being guarded by `slumberTimer`.
            if slumberTimer == nil {
                stepPhysics(now)
                renderNow()
            }
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
        // moving, the work stops entirely rather than redrawing an unchanged cat.
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
        // He purrs for exactly as long as he is being petted. Edge-triggered off the pose
        // rather than off `beingStroked`, so the buzz and the drawing can never disagree:
        // whatever bars him from the pose (a show, the freeze, being carried) bars the purr.
        //
        // **A counted burst is exempt, and without that exemption it never played.** A tap
        // starts eight taps from `handleDrag(.ended)`, but `Cat.pet` puts him in `.alert`, not
        // `.stroked`: a poke is not a stroke and is not drawn as one. So one tick later this
        // line read "purring, but not being stroked" and cancelled the burst it had never
        // started. `pet` also zeroes `squashElapsed`, which makes him `isMoving` and pins the
        // tick at full rate, so the cancel landed inside 16-33ms against a 40ms tap interval:
        // one tap of the eight, every click, on every Mac. `Feel.Mind.petPurrTaps` was dead.
        if !purrBurst, (cat.activity == .stroked) != purring { purr(cat.activity == .stroked) }
    }

    // MARK: - The purr

    private var purrTimer: DispatchSourceTimer?
    private var purrTapsLeft = 0
    /// A counted burst is running and owns the trackpad until it has spent its taps. The
    /// stroke's edge check has to leave it alone: see the note there.
    private var purrBurst = false
    private var purring: Bool { purrTimer != nil }

    /// A purr through the trackpad. `taps: nil` runs until stopped.
    ///
    /// **Its own timer rather than the tick**, which is the whole reason this is not four
    /// lines. The render ladder drops a settled cat to 4Hz and slumber stops the display link
    /// outright, and a cat you reach over and pet is precisely a settled one. Driven off
    /// `tick` the purr would be a handful of thuds, or nothing at all.
    ///
    /// On a Mac without a Force Touch trackpad this silently does nothing, which is correct:
    /// there is no fallback that would be better than no fallback.
    private func purr(_ on: Bool, taps: Int? = nil) {
        purrTimer?.cancel()
        purrTimer = nil
        purrBurst = on && taps != nil
        guard on else { return }
        purrTapsLeft = taps ?? .max
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: Feel.Mind.purrTapInterval)
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                self.purrTapsLeft -= 1
                if self.purrTapsLeft <= 0 { self.purr(false) }
            }
        }
        t.resume()
        purrTimer = t
    }

    private let logStart = CACurrentMediaTime()
    private func log(_ m: String) {
        if debug {
            print(String(format: "[ogi +%07.2f] %@", CACurrentMediaTime() - logStart, m))
        }
    }

    // MARK: - Being handled

    private var dragSamples: [(t: CFTimeInterval, p: CGPoint)] = []
    /// Where the press started, while it is still a press. Nil once it becomes a grab.
    private var pressStart: CGPoint?

    private func handleDrag(_ phase: DragPhase, _ point: CGPoint) {
        switch phase {
        case .began:
            guard hitRect().contains(point) else { return }
            // Not a grab yet. A click is a pet: the scruffing waits until your hand actually
            // moves, so a tap never reads as rough handling.
            pressStart = point
            dragSamples = [(CACurrentMediaTime(), point)]
        case .moved:
            if let start = pressStart {
                guard hypot(point.x - start.x, point.y - start.y) > Feel.Mind.grabSlop else {
                    return
                }
                pressStart = nil
                cat = Cat.grab(cat, at: point)
                log("scruffed")
            }
            guard case .held = cat.support else { return }
            cat.support = .held(point)
            dragSamples.append((CACurrentMediaTime(), point))
            if dragSamples.count > 6 { dragSamples.removeFirst() }
        case .ended:
            if pressStart != nil {
                pressStart = nil
                dragSamples = []
                // A tap gets a burst of the same purr a stroke gets a stream of. Guarded by the
                // same fact `Cat.pet` guards on: mid-air and mid-carry it returns him untouched,
                // and a buzz for a pet that did not land is a lie you can feel.
                if case .grounded = cat.support { purr(true, taps: Feel.Mind.petPurrTaps) }
                cat = Cat.pet(cat, at: point)
                log("petted")
                return
            }
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

    /// Advances the gait cycle, the one pose input that is computed rather than simulated.
    private func buildPose(dt: CGFloat) -> Body.Pose {
        var pose = Body.Pose()
        if cat.activity == .walk {
            // Gait speed follows the speed he is actually moving at, so the feet do not skate.
            // Against a constant the wind-up and the coast to a halt are both moonwalks, and a
            // trot is one throughout.
            //
            // Per gait, because a trot's stride is more than twice a stroll's: one shared length
            // makes the distance-driven phase correct in ground covered and wrong in frame rate,
            // which over-cranks the run sheet 2.25x.
            let stride = cat.hurrying ? Feel.Shape.runStrideLength : Feel.Shape.strideLength
            walkPhase += dt * abs(cat.perchSpeed) / stride
            walkPhase = walkPhase.truncatingRemainder(dividingBy: 1)
        }
        pose.walkPhase = walkPhase
        if case .held = cat.support { pose.dangling = true }
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
        // Where he is DRAWN, which during a notch pose is not where he is: the lift up the
        // cutout wall and the quarter turn onto its side both move the picture. Computed
        // here from the same helper `Overlay` pivots on, because when this worked it out
        // independently the two disagreed and the click box missed the drawing entirely.
        drawnRect = Sprites.drawnBox(frame, at: cat.position,
                                     lift: cat.notchLift, side: cat.notchSide)
        // The simulation's copy of the drawn rect, so the yield guard measures the same box
        // that swallows clicks. One frame stale at worst, which is what the click poll costs
        // anyway.
        cat.drawnBox = drawnRect

        // He looks at your cursor. The strongest aliveness signal that exists.
        let head = CGPoint(x: cat.position.x,
                           y: cat.position.y + Feel.Shape.height * Feel.Eyes.heightFraction)
        // Normally he watches you. `lookingAt` is set for a beat when something else happens,
        // and the decision about which lives in `Cat.step` rather than here so it is testable.
        gaze.step(target: lookDirection(from: head, to: cat.lookingAt ?? NSEvent.mouseLocation),
                  dt: dt)

        let h = heightAboveGround()
        overlay.render(cat, pose: pose, gaze: gaze, frame: frame, heightAboveGround: h,
                       occluders: skyline.occluders(above: perchZ(),
                                                    intersecting: hitRect().insetBy(dx: -40, dy: -h - 40)))
    }

    /// Where a click counts as touching him. Padded, because he is a small target. This is
    /// `Cat.hisBox` exactly (same rect, same pad), so the box he yields to and the box that
    /// swallows clicks cannot drift apart.
    private func hitRect() -> CGRect {
        (drawnRect == .zero ? CGRect(x: cat.position.x - Feel.Shape.width / 2,
                                     y: cat.position.y,
                                     width: Feel.Shape.width, height: Feel.Shape.height)
                            : drawnRect).insetBy(dx: -Feel.Shape.hitPad, dy: -Feel.Shape.hitPad)
    }

    /// The idle ladder he is currently on.
    ///
    /// A covered screen settles him faster: five minutes to sleep rather than ten. See
    /// `Feel.Notch.coveredSlumberScale` for why that is the situation and not a shortcut.
    ///
    /// **Both ends of the slumber have to read this, and one of them used to not.** The tick
    /// armed the slumber on the covered ladder while the watchdog below decided he was done
    /// on the default one, so with a film up and idle between five and ten minutes the two
    /// took turns undoing each other: `enterSlumber` stops the display link, the watchdog
    /// calls `leaveSlumber` a second later, the next tick puts him straight back under. About
    /// three hundred link suspends, renders and timer pairs, every time anyone watched
    /// anything fullscreen, and nothing visible on screen to say so.
    private var slumberScale: Double {
        Repose.timeScale * (cat.screenCovered ? Feel.Notch.coveredSlumberScale : 1)
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
            guard Repose.from(idleSeconds: idle, scale: self.slumberScale) != .asleep else { return }
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
        // He was asleep too: one stretch before life resumes, unless he spent the nap in the
        // notch, in which case he swings out of it and does a couple of pull-ups instead.
        //
        // Waking in the den is the better trigger for the hang. Through a boredom roll it also
        // needs him standing within 35pt of a doorway, which almost never coincides; waking up
        // there is the one moment both are true by construction, which turns a rare accident
        // into the thing you see every time you come back to a film.
        cat.owed = cat.inNotch ? .hang : .stretch
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
        lastRaw = raw
        let fresh = World.build(windows: raw, screen: ScreenGeometry(screen), ownPID: ownPID)
        skyline = tracker.ingest(fresh)
        // The simulation's copy of where home is, for the covered-screen standing order. The
        // waiting spot, not the doorway: the standing order is a place to *stay*.
        cat.homeX = waitingSpot

        // New furniture. He looks at the first one: a stimulus is one-shot and two arriving in
        // the same poll would mean the second silently overwrote the first, so taking the first
        // makes that choice visible rather than accidental.
        //
        // Not the world he woke up to. Everything is new at launch, the floor and the menu bar
        // included, and all of it crosses the age threshold on the same poll, so the FIRST
        // non-empty report is exactly the launch world and nothing in it can be news.
        if sawLaunchWorld, let id = tracker.justAppeared.first, let s = skyline.surface(id) {
            let x = s.solid.first.map { ($0.lowerBound + $0.upperBound) / 2 } ?? s.extent.lowerBound
            cat.receive(Stimulus(kind: .windowOpened, at: CGPoint(x: x, y: s.y)))
            log("noticed a window at \(Int(x)),\(Int(s.y))")
        }
        if !tracker.justAppeared.isEmpty { sawLaunchWorld = true }

        // An app went fullscreen and his whole world is about to be covered, so he retreats to
        // the notch. Read off the raw snapshot rather than off the skyline, because a fullscreen
        // window is ITSELF a walkable surface: its top edge sits above the menu bar, so "his
        // furniture disappeared" is the wrong question and would miss the case entirely.
        //
        // Edge-triggered. Level-triggered it would re-issue the retreat on every poll for as
        // long as the window stayed fullscreen, which is a cat who cannot be anywhere else.
        let fullscreen = OgiApp.somethingFullscreen(in: raw, screen: ScreenGeometry(screen),
                                                    ownPID: ownPID)
        if fullscreen != wasFullscreen { log("screen \(fullscreen ? "covered" : "clear")") }
        if fullscreen, !wasFullscreen {
            headHome(because: "something went fullscreen, heading home")
        }
        wasFullscreen = fullscreen
        // Level-triggered where the retreat is edge-triggered, because they answer different
        // questions: the retreat is "go now", this is "keep to yourself while it lasts".
        cat.screenCovered = fullscreen
    }

    /// Send him home, if there is a home. The stimulus point is the doorway on the menu bar
    /// LINE: the x routes him and the y is what his eyes flick to, so it must not be y=0, the
    /// bottom of the screen, which is a retreating cat glancing at the floor. One helper because
    /// the two retreats (fullscreen, machine sleep) are the same act with a different prompt.
    private func headHome(because reason: String) {
        guard let home = waitingSpot else { return }
        cat.receive(Stimulus(kind: .goHome,
                             at: CGPoint(x: home, y: skyline.screen.visibleFrame.maxY)))
        log(reason)
    }

    /// `effectiveHomeX`, stood clear of the cutout. What both retreats and the covered-screen
    /// standing order aim at; the goodbye still aims at the doorway itself.
    private var waitingSpot: CGFloat? {
        effectiveHomeX.map { OgiApp.denX($0, notch: skyline.screen.notch) }
    }

    /// Is his screen given over to one app?
    ///
    /// **Not** "is there one window covering ~all of the frame", which is false of every real
    /// fullscreen Space. Measured live (M2, notched, macOS 26.5.1, 1920x1243pt) while sitting
    /// on one:
    ///
    /// - a settled fullscreen window is 1920x**1205**. It stops at the menu bar line and
    ///   leaves the 38pt notch strip bare, so it covers 96.9% of the frame and fails a 98%
    ///   test. The only window that passes is the 1920x1243 one macOS shows for ~0.7s during
    ///   the zoom animation, which is why a coverage test catches *entering* fullscreen and
    ///   misses swiping to a Space that is already fullscreen.
    /// - a fullscreen app is not even one window. Chrome's is four full-width bands (1083,
    ///   158, 81 and 41 tall); the tallest is 87% of the screen on its own.
    ///
    /// What IS true of all of them: full-width bands whose union covers the screen from its
    /// bottom edge up to the menu bar line. The bottom **edge**, not `visibleFrame.minY`, is
    /// what separates fullscreen from merely maximized (fullscreen owns the Dock band, zoom
    /// does not), and the menu bar line is the top because the strip above it is the notch,
    /// which fullscreen deliberately leaves bare.
    ///
    /// Full width is not an approximation either: every window in every fullscreen Space
    /// measured was exactly screen-wide. It is also what keeps the GLOBAL window list honest,
    /// since a fullscreen window on another display spans none of this screen's x.
    ///
    /// Pure and static so the multi-display cases are testable without an NSApplication.
    static func somethingFullscreen(in raw: [RawWindow], screen: ScreenGeometry,
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

    /// His depth in the window stack, which decides what is allowed to occlude him.
    ///
    /// He rests ON his perch, so his body occupies the band above it, which geometrically
    /// belongs to whatever is behind. He is therefore just in front of his perch and behind
    /// everything in front of it. Windows *behind* his perch never occlude him, even where
    /// they overlap his body. That is the case a naive "mask against every overlapping
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

    // MARK: - Probe

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
