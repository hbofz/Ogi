// The notch, and the call.
import Testing
import Foundation
import CoreGraphics
@testable import OgiCore

// The real geometry of a notched Mac, and the relationship the whole branch rests on:
// `notch.minY` IS the menu bar line. Measured on a 1920x1243 display with a 38pt strip.
private let barY: CGFloat = 1205
private let notch = CGRect(x: 860, y: barY, width: 200, height: 38)
private let screen = ScreenGeometry(
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1243),
    visibleFrame: CGRect(x: 0, y: 90, width: 1920, height: 1115),
    notch: notch)

/// Built through `World.build` rather than hand-assembled, so `punchNotch` really does cut the
/// hole and these tests are measuring the shipping geometry rather than a fixture's idea of it.
private func notchedWorld(_ windows: [RawWindow] = []) -> Skyline {
    World.build(windows: windows, screen: screen, ownPID: 0)
}

private let dt = Feel.Timing.fixedDT

private func onBar(at x: CGFloat, world: Skyline) -> CatState {
    let bar = world.surface(.menuBar)!
    var c = CatState(position: CGPoint(x: x, y: bar.y))
    c.support = .grounded(Perch(id: .menuBar, dx: x - bar.extent.lowerBound))
    c.activity = .idle
    return c
}

// MARK: - The premise

@Test func theNotchsLowerLipIsTheMenuBarLine() {
    // Everything here follows from this one fact, so it is pinned rather than assumed. If it
    // ever stops being true, "hang from the notch" means hanging from somewhere else.
    let world = notchedWorld()
    let bar = world.surface(.menuBar)!
    #expect(abs(bar.y - notch.minY) < 0.001,
            "the bar is at \(bar.y) and the notch's underside at \(notch.minY)")
}

@Test func theCutoutIsAHoleInTheBarAndNotInTheWorld() {
    let world = notchedWorld()
    let bar = world.surface(.menuBar)!
    #expect(!bar.solid.contains { $0.contains(notch.midX) },
            "he could stand under the cutout, where nothing is drawn")
    #expect(bar.solid.contains { $0.contains(notch.minX) }, "the left lip is not standable")
    #expect(bar.solid.contains { $0.contains(notch.maxX) }, "the right lip is not standable")
}

// MARK: - The tunnel

@Test func theCrossingWalksToTheDoorwayFirst() {
    let world = notchedWorld()
    let bar = world.surface(.menuBar)!
    let cat = onBar(at: 200, world: world)
    let move = Cat.nextMove(from: cat, on: bar, toward: .menuBar, x: 1500, world: world)
    #expect(move == .walk(notch.minX), "got \(String(describing: move))")
}

@Test func atTheDoorwayHeStepsIn() {
    let world = notchedWorld()
    let bar = world.surface(.menuBar)!
    let cat = onBar(at: notch.minX, world: world)
    let move = Cat.nextMove(from: cat, on: bar, toward: .menuBar, x: 1500, world: world)
    #expect(move == .crossNotch(notch.maxX), "got \(String(describing: move))")
}

@Test func aDestinationOnHisOwnSideIsJustAWalk() {
    // The crossing must not fire for every walk along the bar, only when the cutout is
    // strictly between the two ends.
    let world = notchedWorld()
    let bar = world.surface(.menuBar)!
    let cat = onBar(at: 200, world: world)
    let move = Cat.nextMove(from: cat, on: bar, toward: .menuBar, x: 600, world: world)
    #expect(move == .walk(600), "got \(String(describing: move))")
}

@Test func aNotchlessMacHasNoTunnel() {
    let plain = ScreenGeometry(frame: screen.frame, visibleFrame: screen.visibleFrame, notch: nil)
    let world = World.build(windows: [], screen: plain, ownPID: 0)
    let bar = world.surface(.menuBar)!
    let cat = onBar(at: 200, world: world)
    #expect(Cat.notchCrossing(from: cat.position.x, to: 1500, on: bar, world: world) == nil)
}

@Test func heDoesNotFallWhileInsideTheTunnel() {
    // The whole exemption. `solid` has no ground under the cutout, and the `.grounded` branch
    // drops anyone standing where there is none — which is every tick of a crossing.
    let world = notchedWorld()
    var cat = onBar(at: notch.minX, world: world)
    cat.intent = Intent(destination: .menuBar, destinationX: 1500, move: .crossNotch(notch.maxX))
    var everAirborne = false
    for _ in 0..<(120 * 3) {
        cat = Cat.step(cat, world: world, dt: dt)
        if case .grounded = cat.support {} else { everAirborne = true }
    }
    #expect(!everAirborne, "he fell through the camera housing")
}

@Test func theCrossingComesOutTheFarSide() {
    let world = notchedWorld()
    var cat = onBar(at: notch.minX, world: world)
    cat.intent = Intent(destination: .menuBar, destinationX: 1500, move: .crossNotch(notch.maxX))
    for _ in 0..<(120 * 20) { cat = Cat.step(cat, world: world, dt: dt) }
    #expect(cat.position.x > notch.maxX,
            "he is still at \(cat.position.x), on the near side of a \(notch.maxX) lip")
}

@Test func theSqueezeIsSlowerThanAStroll() {
    // The tell for "he is squeezing past hardware" is entirely in the speed, so it is pinned.
    let world = notchedWorld()
    var cat = onBar(at: notch.minX, world: world)
    cat.intent = Intent(destination: .menuBar, destinationX: 1500, move: .crossNotch(notch.maxX))
    let start = cat.position.x
    for _ in 0..<120 { cat = Cat.step(cat, world: world, dt: dt) }
    let covered = cat.position.x - start
    #expect(covered < Feel.Physics.walkSpeed,
            "he crossed \(covered)pt in a second, which is not a squeeze")
    #expect(covered > Feel.Physics.walkSpeed * 0.3, "he barely moved: \(covered)pt in a second")
}

// MARK: - The camera

@Test func aLiveCameraTurnsHimOutOfTheDoorway() {
    // The camera lives in the cutout. He does not get to wait in it while it runs, because the
    // call pose is the one he will hold for the whole call and half of it would be in the hole.
    let world = notchedWorld()
    var cat = onBar(at: notch.minX - Feel.Shape.clearance, world: world)
    cat.onCamera = true
    for _ in 0..<10 { cat = Cat.step(cat, world: world, dt: dt) }
    #expect(cat.position.x < notch.minX - Feel.Shape.clearance,
            "he is still in the doorway at \(cat.position.x)")
    #expect(cat.activity == .onCall)
}

@Test func aLiveCameraNeverSummonsHim() {
    // A place is barred; he is never fetched. If your call starts while he is at the far end of
    // the screen he simply puts the headphones on where he is — anything else would be a
    // scripted trip, and would fight the election that decides where he goes.
    let world = notchedWorld()
    var cat = onBar(at: 200, world: world)
    cat.onCamera = true
    for _ in 0..<(120 * 10) { cat = Cat.step(cat, world: world, dt: dt) }
    #expect(abs(cat.position.x - 200) < 1, "he walked to \(cat.position.x)")
    #expect(cat.intent == nil, "he set off somewhere during your call")
}

@Test func theRigAssembles() {
    var cat = CatState(position: .zero)
    #expect(cat.rig == nil)
    cat.listening = true
    #expect(cat.rig == .talk)
    cat.onCamera = true
    #expect(cat.rig == .full)
    cat.listening = false
    #expect(cat.rig == .work)
}

@MainActor
@Test func eachRigDrawsItsOwnSheet() {
    #expect(Sprites.clip(for: .onCall, dangling: false, rig: .talk) == .callTalk)
    #expect(Sprites.clip(for: .onCall, dangling: false, rig: .work) == .callWork)
    #expect(Sprites.clip(for: .onCall, dangling: false, rig: .full) == .callFull)
}

@Test func typingStillLooksLikeTyping() {
    // The defect this branch closes: a hot mic and a burst of typing shared the `alert`
    // drawing, so "ears up means your mic is hot" had stopped being true. They must not
    // converge again.
    let world = notchedWorld()
    var typing = onBar(at: 400, world: world)
    typing.typingHard = true
    typing = Cat.step(typing, world: world, dt: dt)
    #expect(typing.activity == .alert)

    var mic = onBar(at: 400, world: world)
    mic.listening = true
    mic = Cat.step(mic, world: world, dt: dt)
    #expect(mic.activity == .onCall)
}

@Test func theFreezeStillStopsHimTravelling() {
    // What the freeze actually guarantees. `callTalk` has him yapping, so "completely still"
    // moved to "goes nowhere", and this is the half that must not move.
    let world = notchedWorld()
    var cat = onBar(at: 400, world: world)
    cat.intent = Intent(destination: .menuBar, destinationX: 700, move: .walk(700))
    cat.listening = true
    for _ in 0..<(120 * 5) { cat = Cat.step(cat, world: world, dt: dt) }
    #expect(abs(cat.position.x - 400) < 1, "he moved to \(cat.position.x) mid-call")
    #expect(cat.perchSpeed == 0)
    #expect(cat.intent?.destinationX == 700, "the call ate where he was going")
}

@Test func aBurstOfSiriIsNotACall() {
    // `corespeechd` takes the microphone in bursts well under a second, so the raw read is true
    // several times an hour with nobody on a call. Unfiltered, that is a flicker in and out of
    // the call pose.
    var gate = Settling()
    let settle = Feel.Mind.deviceSettleSeconds
    var t = 100.0

    // A half-second grab, sampled at the 4Hz the real poll uses. Never believed.
    var armedDuringBlip = false
    for _ in 0..<2 {
        armedDuringBlip = gate.update(true, now: t, settle: settle) || armedDuringBlip
        t += 0.25
    }
    #expect(!armedDuringBlip, "a half-second blip armed the tell")
    let afterBlip = gate.update(false, now: t, settle: settle)
    #expect(!afterBlip)

    // A real call: held past the settle, and then it arms.
    t = 200
    var armed = false
    for _ in 0..<20 {
        armed = gate.update(true, now: t, settle: settle)
        t += 0.25
    }
    #expect(armed, "a five-second call never registered")

    // ...and it drops the instant the stream closes. Arming late costs a second and a half of
    // a tell macOS already gives you; clearing late leaves him in a headset after you hang up.
    let hungUp = gate.update(false, now: t, settle: settle)
    #expect(!hungUp)
}

// MARK: - The den

@Test func asleepAtTheDoorwayHeSleepsInsideTheCutout() {
    let world = notchedWorld()
    var cat = onBar(at: notch.minX - Feel.Shape.clearance, world: world)
    cat.repose = .asleep
    cat.activity = .sleep
    for _ in 0..<10 { cat = Cat.step(cat, world: world, dt: dt) }
    #expect(cat.inDen, "he stayed outside his own den")
    #expect(abs(cat.position.x - notch.midX) < 1, "he is at \(cat.position.x), not in the hole")
}

@Test func aCoveredScreenPutsHimToBedInTheNotch() {
    // The scenario the den was really for: a film in fullscreen, nothing to do, nowhere to be.
    // The covered-screen standing order already walks him to the doorway while he is awake; the
    // question is whether the 10-minute idle timer then finds him there.
    //
    // The ordering is what makes it work, and it is not obvious: the sleep gate returns long
    // before the standing order runs, so he can only ever go to bed in the den by ARRIVING
    // there first and falling asleep afterwards. A cat who fell asleep on a window edge stays
    // on the window edge.
    let world = notchedWorld([
        RawWindow(id: 1, pid: 100, layer: 0, rect: CGRect(x: 0, y: 90, width: 1920, height: 1115),
                  alpha: 1, owner: "Chrome"),
    ])
    var cat = onBar(at: 300, world: world)
    cat.screenCovered = true
    cat.homeX = notch.minX
    // The retreat, as `OgiApp.headHome` sends it: aimed at the doorway itself. The
    // covered-screen standing order alone is not enough and is not meant to be — it only asks
    // that he be up top, and he already is.
    cat.receive(Stimulus(kind: .goHome, at: CGPoint(x: notch.minX, y: world.surface(.menuBar)!.y)))

    // The film is on and he heads for the doorway.
    for _ in 0..<(120 * 120) { cat = Cat.step(cat, world: world, dt: dt) }
    #expect(Cat.denDoor(cat, on: world.surface(.menuBar)!) != nil,
            "he never made it to the doorway; he is at \(cat.position.x)")

    // ...and then you stop touching the machine.
    cat.repose = .asleep
    for _ in 0..<(120 * 5) { cat = Cat.step(cat, world: world, dt: dt) }
    #expect(cat.inDen, "he slept on the doorstep instead of going in")
    #expect(abs(cat.position.x - notch.midX) < 1)
}

@Test func wakingUpInTheDenIsAHangRatherThanAStretch() {
    // The other half of the film: you come back, and he swings out of the notch and does a
    // couple of pull-ups before getting on with the day. `App.leaveSlumber` owes the hang; what
    // is checked here is that the state machine lets it happen — the exit that pulls him out of
    // the cutout runs before the owed show is consumed, so an owed hang has to survive it.
    let world = notchedWorld()
    var cat = onBar(at: notch.midX, world: world)
    cat.inNotch = true
    cat.repose = .asleep
    cat.activity = .sleep
    cat = Cat.step(cat, world: world, dt: dt)
    #expect(cat.inDen, "fixture: he should be asleep in the den")

    // You move the mouse. `leaveSlumber` does these two things.
    cat.repose = .awake
    cat.owed = .hang

    var sawHang = false
    for _ in 0..<(120 * 2) {
        cat = Cat.step(cat, world: world, dt: dt)
        if cat.activity == .hang { sawHang = true }
        guard case .grounded = cat.support else {
            Issue.record("he dropped out of the notch on waking, at \(cat.position)")
            return
        }
    }
    #expect(sawHang, "he woke up and did not swing out; he is \(cat.activity)")

    // ...and it still ends properly. Not "back on a lip and staying there", which is flaky one
    // run in four: once he is awake at a doorway, boredom can start another notch pose, and
    // being at `notch.midX` is then correct rather than broken. The invariant that actually
    // holds is the one the ground test enforces: he is always either on standable ground or
    // legitimately inside the cutout.
    for _ in 0..<(120 * 10) {
        cat = Cat.step(cat, world: world, dt: dt)
        let standable = world.surface(.menuBar)!.solid.contains { $0.contains(cat.position.x) }
        guard case .grounded = cat.support else { continue }
        #expect(standable || cat.insideNotch,
                "he is grounded at \(cat.position.x), which is neither standable nor the cutout")
    }
}

@MainActor
@Test func aFilmWalksHimToTheDoorEvenIfHeIsAlreadyUpTop() {
    // Fullscreen Chrome, and he fell asleep in the ordinary curl on some arbitrary spot
    // instead of going into the notch.
    //
    // The cause was that the standing order asked only that he be "up top", which being
    // anywhere on the menu bar satisfies. No goHome stimulus is sent here on purpose — that is
    // the case that used to work — so this is the *other* route: already up there when the film
    // starts, or wandered along the bar afterwards.
    let world = notchedWorld([
        RawWindow(id: 1, pid: 100, layer: 0, rect: CGRect(x: 0, y: 90, width: 1920, height: 1115),
                  alpha: 1, owner: "Chrome"),
    ])
    var cat = onBar(at: 300, world: world)
    cat.screenCovered = true
    cat.homeX = OgiApp.denX(notch.minX, notch: notch)

    for _ in 0..<(120 * 180) { cat = Cat.step(cat, world: world, dt: dt) }
    #expect(abs(cat.position.x - cat.homeX!) < Feel.Physics.arrivalSlop * 3,
            "he is still at \(cat.position.x) with a film on, not at the door")
    #expect(Cat.denDoor(cat, on: world.surface(.menuBar)!) != nil)

    // ...and the ladder then finds him there, which is the only way into the den.
    cat.repose = .asleep
    for _ in 0..<(120 * 5) { cat = Cat.step(cat, world: world, dt: dt) }
    #expect(cat.inDen, "he slept on the bar instead of in the notch")
}

@MainActor
@Test func heSettlesAtTheDoorRatherThanPacingAtIt() {
    // The other half: once he is there the standing order must stop asking, or a film is a cat
    // walking on the spot for two hours.
    let world = notchedWorld([
        RawWindow(id: 1, pid: 100, layer: 0, rect: CGRect(x: 0, y: 90, width: 1920, height: 1115),
                  alpha: 1, owner: "Chrome"),
    ])
    let home = OgiApp.denX(notch.minX, notch: notch)
    var cat = onBar(at: home, world: world)
    cat.screenCovered = true
    cat.homeX = home

    // Distance covered *walking* only. The notch poses move him without walking — into the
    // middle of the cutout and back out to a lip — and that is the branch doing its job, not
    // pacing. What must not happen is him treading the bar.
    var walked: CGFloat = 0
    var last = cat.position.x
    for _ in 0..<(120 * 120) {
        cat = Cat.step(cat, world: world, dt: dt)
        if cat.activity == .walk { walked += abs(cat.position.x - last) }
        last = cat.position.x
    }
    #expect(walked < Feel.Shape.width,
            "he walked \(Int(walked))pt at the door over two minutes of film")
}

@Test func heDoesNotFallOutOfTheDenHeIsAsleepIn() {
    let world = notchedWorld()
    var cat = onBar(at: notch.minX - Feel.Shape.clearance, world: world)
    cat.repose = .asleep
    cat.activity = .sleep
    for _ in 0..<(120 * 60) {
        cat = Cat.step(cat, world: world, dt: dt)
        guard case .grounded = cat.support else {
            Issue.record("he dropped out of the den at \(cat.position)")
            return
        }
    }
    #expect(cat.inDen)
}

@Test func wakingUpTakesHimOutOfTheDen() {
    // `inDen` exempts him from the ground test, so a stale one is a cat standing on nothing.
    let world = notchedWorld()
    var cat = onBar(at: notch.minX - Feel.Shape.clearance, world: world)
    cat.repose = .asleep
    cat.activity = .sleep
    for _ in 0..<10 { cat = Cat.step(cat, world: world, dt: dt) }
    #expect(cat.inDen, "fixture: he should be in the den")

    cat.repose = .awake
    cat = Cat.step(cat, world: world, dt: dt)
    #expect(!cat.inDen, "he is awake and still exempt from gravity")
}

@Test func aLiveCameraKeepsHimOutOfTheDenEvenAsleep() {
    let world = notchedWorld()
    var cat = onBar(at: notch.minX - Feel.Shape.clearance, world: world)
    cat.repose = .asleep
    cat.activity = .sleep
    cat.onCamera = true
    for _ in 0..<10 { cat = Cat.step(cat, world: world, dt: dt) }
    #expect(!cat.inDen, "he crawled in on top of the running camera")
}

@MainActor
@Test func theDenSleepSheetOnlyPlaysInTheDen() {
    #expect(Sprites.clip(for: .sleep, dangling: false, inDen: false) == .sleep)
    #expect(Sprites.clip(for: .sleep, dangling: false, inDen: true) == .denSleep)
}

// MARK: - Hanging and looking down

@Test func theNotchIdeasEndOnSolidGround() {
    // Both put his position inside the cutout, which is only legal while `insideNotch` says so.
    // If the way out did not also move him, the tick after would drop him.
    for idea in [Activity.hang, .peerDown] {
        let world = notchedWorld()
        var cat = onBar(at: notch.midX, world: world)
        cat.activity = idea
        cat.inNotch = true                    // as the idea branch sets it
        cat.facing = -1                       // he came in from the left lip
        cat.activityElapsed = Cat.inPlaceHold(idea)! + 1
        cat = Cat.step(cat, world: world, dt: dt)

        let bar = world.surface(.menuBar)!
        #expect(bar.solid.contains { $0.contains(cat.position.x) },
                "\(idea) left him at \(cat.position.x), which is not standable")
        #expect(cat.activity == .land, "\(idea) did not hand off to the pull-up")

        // ...and he stays up. This is the assertion the ordering bug would have failed: the
        // general in-place hold used to catch these first and settle him without moving him.
        for _ in 0..<(120 * 3) { cat = Cat.step(cat, world: world, dt: dt) }
        guard case .grounded = cat.support else {
            Issue.record("\(idea) dropped him a moment after it ended: \(cat.position)")
            return
        }
    }
}

@Test func anInterruptTakesHimOutOfTheNotchRatherThanDroppingHim() {
    // The trapdoor `inNotch` exists to close. While the exemption was derived from `activity`,
    // anything that swapped the activity out from under him — the mic, the cursor, waking —
    // evaporated it, and the next tick's ground test ran before anything could catch him. He
    // fell out of the hole onto the desktop, wearing a laptop.
    for interrupt in ["mic", "camera", "typing", "waking"] {
        let world = notchedWorld()
        var cat = onBar(at: notch.midX, world: world)
        cat.activity = .hang
        cat.inNotch = true
        cat.facing = -1
        cat = Cat.step(cat, world: world, dt: dt)

        switch interrupt {
        case "mic":    cat.listening = true
        case "camera": cat.onCamera = true
        case "typing": cat.typingHard = true
        default:       cat.repose = .asleep
        }

        for _ in 0..<(120 * 3) {
            cat = Cat.step(cat, world: world, dt: dt)
            guard case .grounded = cat.support else {
                Issue.record("the \(interrupt) dropped him out of the notch at \(cat.position)")
                return
            }
        }
        let bar = world.surface(.menuBar)!
        // Asleep is the one interrupt that is allowed to keep him in there: that is the den.
        if interrupt == "waking" {
            #expect(cat.inDen, "he should have simply gone to sleep in the den")
        } else {
            #expect(!cat.inNotch, "the \(interrupt) left him marked as still inside the cutout")
            #expect(bar.solid.contains { $0.contains(cat.position.x) },
                    "the \(interrupt) left him at \(cat.position.x), which is not standable")
        }
    }
}

@Test func hangingDoesNotFall() {
    let world = notchedWorld()
    var cat = onBar(at: notch.midX, world: world)
    cat.activity = .hang
    cat.inNotch = true
    for _ in 0..<Int(Feel.Notch.hangSeconds * 100) {
        cat = Cat.step(cat, world: world, dt: dt)
        guard case .grounded = cat.support else {
            Issue.record("he let go at \(cat.position)")
            return
        }
    }
}

@MainActor
@Test func onlyTheNotchPoseIsEverTurned() {
    // The quarter turn was read off `notchSide` alone, which outlives the pose, so he walked
    // away from the cutout still lying on his side and sat rotated on a Finder title bar.
    // Every other drawing must be immune to that flag.
    for clip in Sprites.Clip.allCases where clip != .peerDown {
        for side in [CatState.NotchSide.left, .right, .below] {
            #expect(Sprites.turn(clip, side: side) == 0,
                    "\(clip.rawValue) can be turned by a flag that is not about it")
        }
    }
    #expect(Sprites.turn(.peerDown, side: .left) != 0)
    #expect(Sprites.turn(.peerDown, side: .right) != 0)
    #expect(Sprites.turn(.peerDown, side: .below) == 0)
}

@Test func boredomAtALipReachesAllThreeNotchPoses() {
    // The hang, the look down, and the sideways lean out of his own wall. All three come from
    // one branch, so this is really asking that none of them is unreachable: a structure that
    // is right with a number that makes part of it dead.
    let world = notchedWorld()
    let bar = world.surface(.menuBar)!
    var seen: Set<String> = []
    for _ in 0..<300 {
        var cat = onBar(at: notch.minX - Feel.Shape.clearance, world: world)
        let den = Cat.denDoor(cat, on: bar)!
        Cat.enterNotch(&cat, on: bar, notch: notch, out: den.out)
        seen.insert("\(cat.activity)/\(cat.notchSide)")
    }
    #expect(seen.contains("hang/below"), "he never hangs")
    #expect(seen.contains("peerDown/below"), "he never looks down")
    #expect(seen.contains("peerDown/left"), "he never leans out of the side he is standing at")
    #expect(!seen.contains("peerDown/right"),
            "he leaned out of the far wall, across the hole he is standing next to")
}

@Test func theSidePeekLeansOutOfTheWallHeIsStandingAt() {
    // From the RIGHT lip he must lean right, into the strip on that side. Leaning the other way
    // would put his head inside the cutout, where there are no pixels, and he would vanish.
    let world = notchedWorld()
    let bar = world.surface(.menuBar)!
    var cat = onBar(at: notch.maxX + Feel.Shape.clearance, world: world)
    let den = Cat.denDoor(cat, on: bar)!
    for _ in 0..<200 {
        var c = cat
        Cat.enterNotch(&c, on: bar, notch: notch, out: den.out)
        if c.notchSide == .below { continue }
        #expect(c.notchSide == .right)
        #expect(abs(c.position.x - notch.maxX) < 1)
        #expect(c.notchLift > 0, "the side peek was drawn down on the menu bar line")
        cat = c
        break
    }
}

@Test func aCoveredScreenPutsHimToSleepInFiveMinutesRatherThanTen() {
    // With a film up there is nowhere to go, the election is gated off entirely, and ten
    // minutes of a cat waiting in a doorway is ten minutes of nothing.
    let covered = Repose.timeScale * Feel.Notch.coveredSlumberScale
    #expect(Repose.from(idleSeconds: 299, scale: covered) != .asleep)
    #expect(Repose.from(idleSeconds: 301, scale: covered) == .asleep)
    // ...and an uncovered screen is untouched.
    #expect(Repose.from(idleSeconds: 301) != .asleep)
    #expect(Repose.from(idleSeconds: 601) == .asleep)
}

@Test func leavingTheNotchPutsHimBackTheRightWayUp() {
    let world = notchedWorld()
    var cat = onBar(at: notch.midX, world: world)
    cat.activity = .peerDown
    cat.inNotch = true
    cat.notchSide = .left
    cat.notchLift = 24
    cat.facing = -1
    cat.activityElapsed = Cat.inPlaceHold(.peerDown)! + 1
    cat = Cat.step(cat, world: world, dt: dt)
    #expect(cat.notchSide == .below, "he left the cutout still on his side")
    #expect(cat.notchLift == 0, "he left the cutout still floating above the bar")
}

// MARK: - The sheets

@MainActor
@Test func theHangGripsAtTheTopOfItsBand() {
    // He hangs by his front paws, so the point pinned to his world position is the top of the
    // drawing and not the bottom. Anchored at the floor he would dangle by his back legs from
    // the menu bar.
    #expect(Sprites.footAnchor(.hang) > 0.9,
            "hang anchors at \(Sprites.footAnchor(.hang)), which is not his grip")
    // And the sheet has to agree: his paws must really be the top of the ink.
    var tops: [CGFloat] = []
    for i in 0..<Sprites.Clip.hang.count {
        guard let img = Sprites.image(.hang, i) else { continue }
        tops.append(CGFloat(img.height))
    }
    #expect(tops.allSatisfy { $0 == tops.first }, "the hang frames do not share one band")
}

@MainActor
@Test func theHangLowersInBeforeItLoops() {
    // Frames 0 and 1 are him going over the lip and play once; 2 to 5 are the rep and cycle.
    // A plain loop would have him climbing back over the edge every two thirds of a second.
    let c = Sprites.Clip.hang
    let n = Sprites.lowerInFrames
    for f in 0..<n {
        let t = (Double(f) + 0.5) / c.fps
        #expect(Sprites.index(c, activity: .hang, walkPhase: 0, elapsed: t) == f)
    }
    // Well past the prefix, he must never return to it.
    for step in 0..<40 {
        let t = (Double(n) + Double(step) + 0.5) / c.fps
        let i = Sprites.index(c, activity: .hang, walkPhase: 0, elapsed: t)
        #expect(i >= n, "the hang went back to its lowering-in frames at \(t)s")
        #expect(i < c.count)
    }
}

@MainActor
@Test func theDenSleepAnchorSitsWhereHisTailStarts() {
    // His body is above the bar line and masked away; his tail hangs below it. So his world
    // position has to be the join between the two, or the notch clips the wrong half of him.
    let a = Sprites.footAnchor(.denSleep)
    #expect(a > 0.4 && a < 0.6, "denSleep anchors at \(a), which is not the base of his body")
}

@MainActor
@Test func theFrontFacingAndProppedSheetsBringTheirOwnYardstick() {
    // `eyes()` finds whatever contrasts hardest with the fur. Drawn head-on his eyes are huge;
    // drawn with a dark headset or a dark laptop, the PROP is what it finds — measured, the
    // laptop came back as a 314x191 "eye" and rendered the clip three points tall. Neither is
    // fixable inside `eyes()`, so both classes are normalised on band height instead.
    for clip in [Sprites.Clip.peer, .peerDown, .hang, .callTalk, .callWork, .callFull] {
        #expect(Sprites.bandHeight(clip) != nil,
                "\(clip.rawValue) is still being sized by an eye it cannot measure")
    }
    // ...and the two desk sheets must stay the same size as each other, or he changes size
    // when you put your headphones on halfway through a call.
    #expect(Sprites.bandHeight(.callWork) == Sprites.bandHeight(.callFull))
}

@MainActor
@Test func everyNewSheetHasAllItsFrames() {
    for clip in [Sprites.Clip.callTalk, .callWork, .callFull, .denSleep, .hang, .peerDown] {
        for i in 0..<clip.count {
            #expect(Sprites.image(clip, i) != nil, "\(clip.rawValue)\(i) is missing")
        }
    }
}

/// The covered-screen retreat used to sit above every in-place hold in `standing`, so the
/// notch poses it exists to produce were cancelled on the tick after they started. Its own
/// test is "more than 9pt from the den door" and `enterNotch` puts him at `notch.midX`, which
/// is 130pt away by construction, so it could never be satisfied from inside the hole.
@MainActor
@Test(arguments: [Activity.hang, .peerDown])
func aNotchPoseRunsItsFullLengthWithAFilmUp(pose: Activity) {
    let world = World.build(windows: [], screen: screen, ownPID: 99)
    let hold = Cat.inPlaceHold(pose)!

    func heldFor(covered: Bool) -> TimeInterval {
        var s = CatState(position: CGPoint(x: notch.midX, y: notch.minY))
        s.support = .grounded(Perch(id: .menuBar,
                                    dx: notch.midX - world.surface(.menuBar)!.extent.lowerBound))
        s.inNotch = true
        s.homeX = notch.minX - 26
        s.screenCovered = covered
        s.activity = pose
        s.activityElapsed = 0
        var t: TimeInterval = 0
        for _ in 0..<Int((hold + 2) / dt) {
            s = Cat.step(s, world: world, dt: dt)
            if s.activity != pose { break }
            t += dt
        }
        return t
    }

    let uncovered = heldFor(covered: false)
    let covered = heldFor(covered: true)
    #expect(uncovered > hold - 0.1, "\(pose) does not run its length even uncovered")
    let msg = "\(pose) lasted \(String(format: "%.3f", covered))s of \(hold)s with a film up: the retreat cancelled the pose it exists to produce"
    #expect(covered > hold - 0.1, Comment(rawValue: msg))
}

/// Picking him out of the notch used to keep `inNotch`, `notchSide` and `notchLift` set for
/// the whole carry: the `.held` branch returns early and `standing` bails unless he is
/// grounded, so nothing cleared them. He dangled a `notchLift` above the cursor, and on
/// touchdown `standing`'s first act, `leaveNotch`, fired against whatever he had landed on and
/// threw him back to the notch lip.
@MainActor
@Test func pickingHimOutOfTheNotchDoesNotTeleportHimOnLanding() {
    let world = World.build(windows: [], screen: screen, ownPID: 99)
    var s = CatState(position: CGPoint(x: notch.midX, y: notch.minY))
    s.support = .grounded(Perch(id: .menuBar,
                                dx: notch.midX - world.surface(.menuBar)!.extent.lowerBound))
    s.inNotch = true
    s.notchLift = 24.7
    s.activity = .hang

    s = Cat.grab(s, at: CGPoint(x: 700, y: 900))
    #expect(!s.inNotch, "still flagged as in the notch while being carried")
    #expect(s.notchLift == 0, "drawn \(s.notchLift)pt above the cursor while carried")

    let dropX: CGFloat = 300
    s = Cat.release(s, throwVelocity: .zero, world: world)
    s.position = CGPoint(x: dropX, y: 900)
    for _ in 0..<Int(4 / dt) { s = Cat.step(s, world: world, dt: dt) }

    #expect(abs(s.position.x - dropX) < 200,
            Comment(rawValue: "dropped at \(Int(dropX)) and ended at \(Int(s.position.x)): "
                    + "the notch exit fired on a surface he never came from"))
}

/// The crossing takes about seven seconds. Freezing partway through (typing hard, or a call
/// starting) used to park him inside the cutout, which is a permanent occluder, so he was
/// invisible for as long as the freeze lasted. On a call that is the whole call, and the
/// camera eviction cannot reach him because `denDoor` asks `edgeAhead`, which is nil inside
/// the hole in `solid`.
@MainActor
@Test func freezingMidCrossingDoesNotParkHimInTheCutout() {
    let world = World.build(windows: [], screen: screen, ownPID: 99)
    let bar = world.surface(.menuBar)!
    var s = CatState(position: CGPoint(x: notch.minX - 10, y: bar.y))
    s.support = .grounded(Perch(id: .menuBar, dx: notch.minX - 10 - bar.extent.lowerBound))
    s.intent = Intent(destination: .menuBar, destinationX: notch.maxX + 10,
                      move: .crossNotch(notch.maxX + 10))
    s.facing = 1

    // Walk him into the tunnel, then freeze him there.
    for _ in 0..<Int(2 / dt) {
        s = Cat.step(s, world: world, dt: dt)
        if s.position.x > notch.minX + 20 { break }
    }
    #expect(s.insideNotch, "he never got into the tunnel, so this proves nothing")

    s.typingHard = true
    for _ in 0..<Int(20 / dt) { s = Cat.step(s, world: world, dt: dt) }

    #expect(!s.insideNotch,
            Comment(rawValue: "frozen at x=\(Int(s.position.x)), inside the cutout, invisible"))
    #expect(bar.solid.contains { $0.contains(s.position.x) },
            "frozen somewhere the bar has no pixels behind it")
}

/// `peerDownSeconds` and `hiddenPatience` are both 10, and a `.below` peer-down stands at
/// `notch.midX`, which is not in `bar.spans`, so `hiddenFor` and `activityElapsed` accrued the
/// same dt on the same ticks and came out bit-identical. The hidden branch is tested first and
/// uses `>=` while the pose's own exit uses `>`, so it won every time and the pull-up back over
/// the lip never played for half of all peer-downs.
@MainActor
@Test func theBelowPeerDownEndsWithItsOwnPullUp() {
    let world = World.build(windows: [], screen: screen, ownPID: 99)
    var s = CatState(position: CGPoint(x: notch.midX, y: notch.minY))
    s.support = .grounded(Perch(id: .menuBar,
                                dx: notch.midX - world.surface(.menuBar)!.extent.lowerBound))
    s.inNotch = true
    s.notchSide = .below
    s.activity = .peerDown
    s.activityElapsed = 0

    var ended: Activity = .peerDown
    for _ in 0..<Int((Feel.Notch.peerDownSeconds + 2) / dt) {
        s = Cat.step(s, world: world, dt: dt)
        if s.activity != .peerDown { ended = s.activity; break }
    }
    #expect(ended == .land,
            Comment(rawValue: "peerDown ended as \(ended), not the pull-up: the hidden branch "
                    + "beat it by one comparison"))
}
