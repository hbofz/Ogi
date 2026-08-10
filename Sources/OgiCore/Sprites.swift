#if canImport(AppKit)
import AppKit

/// The drawn cat: 154 frames across thirty-two animations, generated and hand-cut.
///
/// The count in that line is a signpost and drifts as sheets are added.
/// `Clip.allCases.count` is the truth.
///
/// Physics, terrain, occlusion, squash and facing are not coupled to how he is drawn, which is
/// what lets the renderer change without touching any of them.
///
/// **Every frame in an animation shares one vertical band**, aligned on the source sheet's own
/// ground line, rather than being cropped tight to its own ink. That is what preserves the air
/// in a jump: crop each frame individually and an airborne cat gets re-planted on the ground,
/// so a crouch and a leap render at exactly the same height. See `Tools/extract-sprites.swift`.
@MainActor
public enum Sprites {

    /// Ordered frames per animation. Names match the files in Resources/Sprites.
    public enum Clip: String, Sendable, CaseIterable {
        case walk, idle, jump, land, fall, run, alert, sitdown, held, sleep, groom, curl, cling
        case lookDown, peek, turn, shake
        case climbUp
        case lounge, stretch
        case peer
        case zap, vibe, droop, curious
        // The notch and the call.
        case callTalk, callWork, callFull
        case denSleep, hang, peerDown
        // Your hand on him.
        case stroked

        var count: Int {
            switch self {
            case .walk: 6
            case .jump: 6
            case .run: 8
            case .fall: 6
            case .land: 3
            case .sitdown: 5
            case .sleep: 3
            case .idle: 4
            case .held: 4
            case .alert: 3
            case .groom: 6
            case .curl: 5
            case .cling: 4
            case .climbUp: 6
            case .lookDown: 4
            case .peek: 4
            case .turn: 4
            case .shake: 4
            case .lounge: 4
            case .stretch: 5
            case .peer: 4
            // zap is 5, not the sheet's 6: its first frame is a neutral STANDING pose, so
            // a sitting cat would pop upright before the jolt. The clip opens on the jolt,
            // which is what a surprise looks like.
            case .zap: 5
            case .vibe, .droop, .curious: 6
            case .callTalk: 6
            case .callWork, .callFull: 4
            case .denSleep, .peerDown: 4
            case .hang: 6
            case .stroked: 5
            }
        }

        /// Frames per second. Deliberately low: a slightly-lower framerate reads as
        /// handmade, while 60fps sprite motion reads as a screensaver.
        var fps: Double {
            switch self {
            case .walk: 10
            case .run: 14
            case .land: 14      // impacts are quick
            case .fall: 12
            case .jump: 12
            case .idle, .sleep: 2.5   // breathing, not action
            case .sitdown: 8
            case .held: 3
            case .alert: 1.2
            case .groom: 8
            case .curl: 6
            case .cling: 4      // a slow scrabble, not a flail
            // DERIVED, not chosen, so it cannot drift from the speed it has to match. The sheet
            // is six frames covering `climbStride` of wall, so the rate is however many strides
            // per second he is actually climbing, times six. At clingClimbSpeed 110 and a 55pt
            // stride that is 12fps.
            //
            // A rate picked by hand drifts silently: a sheet played against a speed it was not
            // drawn for is a blur of legs, and nothing fails. Tying the two numbers together is
            // the only fix that stays fixed.
            case .climbUp:
                Double(Feel.Physics.clingClimbSpeed / Feel.Shape.climbStride) * 6
            case .lookDown: 6   // head over the side in half a second, then he holds
            case .peek: 5       // creeping out of the doorway; slower than he ever walks
            case .turn: 12      // a pivot is quick
            case .shake: 12     // a shudder, not a wobble
            case .lounge: 2.5   // breathing, like idle and sleep: he is watching, not doing
            case .stretch: 5    // a bow and a yawn take a second; the last frame holds
            case .peer: 2.5     // a nosy look over a lip: glances and a blink, nothing more
            case .zap: 10       // a gag is quick; the settled last frame holds
            case .vibe: 4       // a groove, looping until the spell ends
            case .droop: 5      // powering down decelerates into the flat last frame
            case .curious: 6    // a head-tilt has to read; the settled last frame holds
            // Fast enough that the mouth reads as speech rather than a twitch. The head bob
            // is what actually carries it at his size, and it moves on the same clock.
            case .callTalk: 6
            // Typing. Two paws alternating, so a full cycle is four frames and this is about
            // three keystrokes a second, which is a cat pretending to work rather than a
            // person actually working.
            case .callWork, .callFull: 8
            case .denSleep: 2.5   // breathing and a tail, like sleep, which is what it is
            case .hang: 6         // a rep takes two thirds of a second
            case .peerDown: 4     // a nosy look down, a shade quicker than peer's 2.5
            // A cat pushing his head up into your hand does it slowly. Faster than the
            // breathing clips because this is a motion rather than a breath, and slower than
            // anything he does on purpose, because the whole pose is him not doing anything.
            case .stroked: 4
            }
        }

        var loops: Bool {
            switch self {
            // groom loops: a cat washing does it for a while, and the sheet's last frame
            // returns to the sitting pose it started from, so the seam is invisible.
            // cling loops: he holds on until he lets go.
            // lounge loops: a sprawl is a spell, and its breath cycles back to frame 1.
            // vibe loops: he grooves until the spell ends, and its last frame returns to
            // the first's pose so the seam is invisible.
            // The three call clips loop: he is on the call until you are not, and each sheet's
            // last frame returns to the first's pose so the seam is invisible.
            // denSleep loops: it is the sleep clip with a tail, and it breathes.
            // hang loops, but only its tail. See `index`, where frames 0 and 1 are him
            // lowering himself over the lip and play once.
            // peerDown loops: a nosy look is a spell, like peer's.
            case .walk, .run, .idle, .sleep, .held, .alert, .groom, .cling, .climbUp,
                 .lounge, .peer, .vibe,
            // stroked loops: he keeps pushing his head up into your hand for as long as your
            // hand keeps going, and the last frame settles back toward the first's pose.
                 .callTalk, .callWork, .callFull, .denSleep, .hang, .peerDown, .stroked: true
            // curl settles into the sleep pose and holds it until sleep takes over.
            // lookDown holds its last frame too: he leans out over the lip and stays there
            // while he thinks. The hold IS the tell, so it must not cycle back to standing.
            // peek holds too: it ends with his front half out and upright, which is exactly the
            // pose the walk starts from. Looping it would put him back on his chest.
            // turn holds too: it ends on him facing the other way, which is exactly where the
            // walk that follows picks up. Looping it would spin him.
            // shake runs once and settles: the last frame is a cat standing normally again,
            // which is what hands off to idle. Looping it would be a cat with a nervous tic.
            // stretch too: it ends standing neutral, the idle handoff, and a looping bow
            // would be a cat doing calisthenics.
            case .jump, .land, .fall, .sitdown, .curl, .lookDown, .peek, .turn, .shake,
                 .stretch, .zap, .droop, .curious: false
            }
        }
    }

    /// Everything about what is on screen this instant: which drawing, at what size, and
    /// where it attaches to his world position.
    ///
    /// One source of truth, because `App` and `Overlay` both need it and a fixed box does not
    /// fit: the sprite is normalised on eye width and is often larger, so a stale hit rect
    /// makes petting miss him, and the occlusion mask is built in these same coordinates, so
    /// the same box silently crops the top of his head.
    public struct Frame: Sendable {
        public let clip: Clip
        public let index: Int
        public let size: CGSize
        /// Fraction up the frame where he attaches. 0 = his feet, 0.95 = his nape.
        public let anchor: CGFloat
        /// Drawn one way up and rendered the other. See `Sprites.flipsVertically`.
        public let flippedY: Bool

        /// Where this frame lands on screen for a cat standing at `p`.
        ///
        /// The flip pivots on the anchor, so the drawn content ends up on the opposite side of
        /// it and the box has to follow. Getting this wrong is not cosmetic: `Overlay` builds
        /// the occlusion mask in this rect's coordinates, so a box on the wrong side of him
        /// clips the wrong half, and the hit rect for petting comes from here too.
        public func rect(at p: CGPoint) -> CGRect {
            CGRect(x: p.x - size.width / 2,
                   y: p.y - size.height * (flippedY ? 1 - anchor : anchor),
                   width: size.width, height: size.height)
        }
    }

    public static func frame(for cat: CatState, pose: Body.Pose) -> Frame {
        let c = clip(for: cat.activity, dangling: pose.dangling, hurrying: cat.hurrying,
                     rig: cat.rig, inDen: cat.inDen)
        let i = index(c, activity: cat.activity,
                      walkPhase: pose.walkPhase, elapsed: cat.activityElapsed)
        return Frame(clip: c, index: i, size: size(c, i), anchor: footAnchor(c),
                     flippedY: flipsVertically(c))
    }

    // Everything in this app runs on the main actor, so a plain cache needs no lock.
    private static var cache: [String: CGImage] = [:]

    /// Where the drawings actually are, which is not where SwiftPM thinks it left them.
    ///
    /// **`Bundle.module` cannot be trusted inside an `.app`.** The accessor SwiftPM generates
    /// looks in `Bundle.main.bundleURL` (the `.app` directory itself) and then falls back to
    /// a hard-coded absolute build path. Inside an app bundle, resources belong under
    /// `Contents/Resources`, so the first candidate never matches and the second is a path on
    /// the machine that built it.
    ///
    /// It fails two ways, and both of them ship. On the machine that built it the fallback path
    /// exists, so macOS asks a cat that requests no permissions for access to whatever folder
    /// it sits in. On every other Mac neither path exists and the accessor calls `fatalError`,
    /// so the app crashes for everyone who did not build it.
    ///
    /// So: ask the app bundle first, and keep `.module` for `swift test` and `swift run`, where
    /// it is correct and where `Bundle.main` is the test runner. Evaluated once, and lazily,
    /// which matters: merely *touching* `.module` when the resources are absent is the crash.
    static let resources: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Ogi_OgiCore.bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return .module
    }()

    public static func image(_ clip: Clip, _ index: Int) -> CGImage? {
        let name = "\(clip.rawValue)\(min(max(index, 0), clip.count - 1))"
        if let c = cache[name] { return c }
        guard let url = resources.url(forResource: name, withExtension: "png",
                                      subdirectory: "Sprites")
                ?? resources.url(forResource: name, withExtension: "png"),
              let data = try? Data(contentsOf: url),
              let src = NSImage(data: data),
              let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        cache[name] = cg
        return cg
    }

    /// Which animation a given behaviour plays.
    ///
    /// `rig` and `inDen` are the two cases where one behaviour has more than one drawing.
    /// A call is one state wearing one of three sets of equipment, and sleeping is one state
    /// drawn differently in the one place his body is invisible. Both are passed in rather
    /// than split into extra `Activity` cases, because neither changes what he is *doing*.
    public static func clip(for activity: Activity, dangling: Bool, hurrying: Bool = false,
                            rig: CatState.Rig? = nil, inDen: Bool = false) -> Clip {
        if dangling { return .held }
        switch activity {
        case .onCall:
            switch rig {
            case .talk:      return .callTalk
            case .work:      return .callWork
            case .full:      return .callFull
            // Unreachable: `Cat.step` only sets `.onCall` when `rig` is non-nil. `alert` is the
            // honest fallback rather than a crash, since it is the pose the call replaced.
            case .none:      return .alert
            }
        case .hang:                 return .hang
        case .peerDown:             return .peerDown
        case .walk:                 return hurrying ? .run : .walk
        case .turn:                 return .turn
        case .edgeLook:             return .lookDown
        case .peek:                 return .peek
        case .crouch:               return .jump      // the wind-up frames
        case .airborne:             return .jump
        // Both ways he leaves the ground without choosing to: his platform vanished, or you
        // dropped him. The fall sheet is the righting reflex, so it covers both.
        case .slip, .righting:      return .fall
        case .cling:                return .cling
        case .climb:                return .climbUp
        case .scruffed:             return .held
        // A drop that rattles him gets its own picture, so the squash is not the only thing
        // telling it apart from a step down off a window edge.
        case .landHard:             return .shake
        case .land:                 return .land
        case .sit:                  return .sitdown
        case .curl:                 return .curl
        // Asleep in the den, his body is inside the cutout and masked away, so the whole of
        // the animation you can see is a tail hanging below the bar line and swaying.
        case .sleep:                return inDen ? .denSleep : .sleep
        case .lounge:               return .lounge
        case .stretch:              return .stretch
        case .peer:                 return .peer
        case .zap:                  return .zap
        case .vibe:                 return .vibe
        case .droop:                return .droop
        case .curious:              return .curious
        case .stroked:              return .stroked
        case .alert, .brace:        return .alert
        case .groom:                return .groom
        case .idle:                 return .idle
        }
    }

    /// Where in the animation to be.
    ///
    /// Locomotion is driven by the gait phase so the paws do not skate; everything else runs
    /// off its own elapsed time. Non-looping clips hold their last frame.
    public static func index(_ clip: Clip, activity: Activity,
                             walkPhase: CGFloat, elapsed: TimeInterval) -> Int {
        switch clip {
        case .walk, .run:
            return Int(walkPhase * CGFloat(clip.count)) % clip.count
        case .jump where activity == .crouch:
            // Hold on the coiled frame for the whole 100ms wind-up.
            return 1
        case .jump:
            // Skip the wind-up frames; he is already in the air.
            let n = clip.count - 2
            return 2 + min(n - 1, Int(elapsed * clip.fps))
        case .zap:
            // The buzz loops before the recovery plays: one straight pass reads as a
            // flicker rather than a shock. The three jolt frames cycle for zapBuzzSeconds,
            // then the shake and the pleased finish run once and the last frame holds.
            let buzzFrames = 3
            if elapsed < Feel.Timing.zapBuzzSeconds {
                return Int(elapsed * clip.fps) % buzzFrames
            }
            let after = Int((elapsed - Feel.Timing.zapBuzzSeconds) * clip.fps)
            return min(buzzFrames + after, clip.count - 1)
        case .hang:
            // Frames 0 and 1 are him lowering himself over the lip, and they play once. The
            // rep is frames 2 to 5 and loops. Same shape as `jump`, which skips its own
            // wind-up frames for exactly the same reason: a prefix that is a transition
            // rather than part of the cycle.
            let raw = Int(elapsed * clip.fps)
            guard raw >= lowerInFrames else { return raw }
            return lowerInFrames + (raw - lowerInFrames) % (clip.count - lowerInFrames)
        default:
            let raw = Int(elapsed * clip.fps)
            return clip.loops ? raw % clip.count : min(raw, clip.count - 1)
        }
    }

    /// How many frames of `hang` are him getting into it rather than doing it. Named because
    /// `index` and `theHangLowersInBeforeItLoops` both need the same number.
    static let lowerInFrames = 2

    /// Clips drawn one way up and rendered the other.
    ///
    /// Exactly one, and it is a correction rather than a technique. `peerDown` was specified as
    /// a head hanging *down* over an edge and generated as a head peeking *up* over one, with
    /// the paws below the face. Placement cannot cover for that: the top of his head on the lip
    /// reads as what it is, a right-way-up cat poking out from under the notch rather than one
    /// draped over the edge looking down at you.
    ///
    /// Flipping it costs one transform and turns the drawing into the pose it was asked for:
    /// paws over the lip at the top, head hanging below them, upside down, the way a cat
    /// actually looks over the front of a shelf.
    ///
    /// The flip is about `footAnchor`, so that anchor has to be the part that stays put: his
    /// paws, at the very bottom of the ink as drawn.
    static func flipsVertically(_ clip: Clip) -> Bool { clip == .peerDown }

    /// How far to turn a drawing, in radians, for the edge of the cutout he is hanging off.
    ///
    /// **Takes the clip as well as the side, and that is the whole point.** `CatState.notchSide`
    /// outlives the pose it belongs to, so a renderer that read it alone rotated *everything*.
    /// He left the notch still lying on his side and sat turned on a window's title bar.
    /// Only the clip that can be hung off an edge may be turned by this.
    ///
    /// Positive is counter-clockwise, so the head going out to the LEFT is the negative turn.
    static func turn(_ clip: Clip, side: CatState.NotchSide) -> CGFloat {
        guard flipsVertically(clip) else { return 0 }
        switch side {
        case .below: return 0
        case .left:  return -.pi / 2
        case .right: return .pi / 2
        }
    }

    /// Which way to flip the drawing: +1 for the sheet as drawn, -1 mirrored.
    ///
    /// Normally just `facing`, because every sheet is drawn facing right and mirrored when he
    /// faces left. **`turn` is the one clip whose mirror is inverted**, because for a turn the
    /// transition IS the content: it can only be drawn once, as right -> left, so playing it as
    /// drawn turns him LEFT and mirroring it turns him right. `facing` is already the
    /// DESTINATION throughout a turn, so the flag is the opposite of it.
    ///
    /// This is here rather than inline in `Overlay` because it cannot be checked by eye in a
    /// headless test and getting it backwards is invisible in a still frame: he would pivot
    /// away from wherever he is about to walk. `theTurnIsTheOneClipWhoseMirrorIsInverted` pins
    /// the rule and `theTurnSheetIsDrawnRightToLeft` pins the premise to the actual pixels.
    public static func mirror(_ clip: Clip, facing: CGFloat) -> CGFloat {
        clip == .turn ? -facing : facing
    }

    /// Where his feet are, as a fraction up from the bottom of the frame.
    ///
    /// Most sheets are drawn with a ground line, so the bottom of the band IS the floor. The
    /// exception is `held`, where nothing touches the ground: he is gripped by the scruff, so
    /// he attaches at the nape of his neck. Anchoring him at the bottom would hang him by the
    /// tail. Measured off the sheet at 0.952-0.960 across its four frames.
    ///
    /// Measure this whenever an airborne clip is redrawn: it is a property of the sheet, not of
    /// the animation. A sheet whose cat never reaches the bottom of his own band needs an entry
    /// here, or anchoring at the floor leaves him hovering.
    static func footAnchor(_ clip: Clip) -> CGFloat {
        switch clip {
        case .held: return 0.95     // gripped by the scruff, near the top
        // Same situation as `held`: nothing touches the ground, so the point held fixed at
        // `cat.position` is his grip on the wall: his raised front paws, near the top. Every
        // automatic bottom-of-ink reading finds his HANGING TAIL instead and would dangle him
        // upside down off the window.
        //
        // Read off the four cut frames by finding his front paws in each: 0.75-0.85, 0.90-0.97,
        // 0.85-0.95, 0.80-0.90 of the way up the 628px band. 0.875 centres that. The bottom of
        // the range rides him 30-60px low on frames 1 and 2, a visible bob against the wall on
        // a 4fps loop.
        //
        // Unconfirmed on screen. Look at him on a real window and adjust; do not "correct" it
        // from a measured ink box, which finds the tail every time.
        case .cling: return 0.875
        // The same grip on the same wall, so the same anchor. These two MUST agree: he switches
        // between them the moment he decides to go up rather than hang, and a different anchor
        // would snap him up or down the face at that instant. `theClimbAndTheClingHangFromTheSamePoint`
        // pins them together.
        case .climbUp: return 0.875
        // Hanging off the notch's lower lip by his front paws. Same situation as `cling`:
        // the fixed point is his grip, not his feet, and a bottom-of-ink reading would find
        // his dangling back legs and hang him upside down under the menu bar.
        //
        // Measured off the cut sheet: the top of the ink sits 11px into a 598px band on five
        // of the six frames and 0px on the pulled-up one, so his paws are at 0.982-1.0 and
        // this is the low end of that. `theHangGripsAtTheTopOfItsBand` holds it to the sheet.
        case .hang: return 0.982
        // His two paws hook over the notch's bottom lip and his head hangs below them, upside
        // down. The sheet is drawn the other way up and flipped at render time
        // (`flipsVertically`), and the flip pivots on this anchor, so it has to be the part
        // that must not move, which is his paws.
        //
        // They sit at the very bottom of the ink in every frame (row 411 of a 413px band, and
        // 411 on all four), so this is a shade off the floor. Everything else in the drawing is
        // above them before the flip and below them after it, which is the whole trick.
        case .peerDown: return 0.005
        // Curled asleep inside the cutout with his tail hanging out of it. His body is above
        // the bar line and masked; the tail below it is the entire animation you can see. The
        // anchor is therefore where the body stops and the tail starts, so that the bar line
        // falls exactly there.
        //
        // Row 248 of a 500px band, and it is row 248 on all four frames: the sheet holds his
        // body still to the pixel while the tail swings, which is what it was asked for.
        case .denSleep: return 0.504
        default:    return 0
        }
    }

    /// Where his eyes are in a given frame, in unit coordinates (0..1 from the bottom-left
    /// of the sprite).
    ///
    /// Found rather than authored, so it keeps working on any sheet dropped in later without
    /// anyone annotating it. This is load-bearing rather than cosmetic: `clipScale` normalises
    /// every animation on eye width, so a clip whose eyes are not found renders at the wrong
    /// size, and it does that silently.
    ///
    /// The eye is whatever stands furthest from the fur, and which direction that is depends on
    /// the cat. On a black cat with white eyes they are the brightest thing on him. The ginger
    /// tabby in `art/character.png` inverts it: a mid-value orange whose near-black eyes are the
    /// darkest thing on him. Matching both is what lets sheets be replaced one at a time.
    ///
    /// Which of the two applies is decided from the fur rather than configured, so a new sheet
    /// still needs no annotation.
    public static func eyes(_ clip: Clip, _ index: Int) -> [CGRect] {
        let key = "\(clip.rawValue)\(index)"
        if let e = eyeCache[key] { return e }
        guard let img = image(clip, index) else { return [] }
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }

        /// White eyes, as the black cat has.
        func isPale(_ i: Int) -> Bool {
            px[i * 4 + 3] > 128 && px[i * 4] > 200 && px[i * 4 + 1] > 200 && px[i * 4 + 2] > 200
        }
        /// Near-black eyes, as the ginger tabby has. Dark *and neutral*: his outline is dark
        /// too, but warm (r≈128 against g≈48), so requiring the red channel down with the rest
        /// keeps the outline out. His cream belly and paws stop short of `isPale` for the same
        /// kind of reason: their blue channel never reaches it.
        func isInky(_ i: Int) -> Bool {
            px[i * 4 + 3] > 128 && px[i * 4] < 80 && px[i * 4 + 1] < 80 && px[i * 4 + 2] < 90
        }

        var ink = 0, inky = 0
        for i in 0..<(w * h) where px[i * 4 + 3] > 128 {
            ink += 1
            if isInky(i) { inky += 1 }
        }

        // Which test finds the eye depends on the cat, so ask the fur. A black cat is almost
        // entirely inky (88% of his pixels), which means his eyes cannot be the dark ones; a
        // ginger tabby is barely inky at all, so his eyes are exactly the dark ones.
        //
        // This has to be a choice rather than the union of both tests. Matching either one in
        // a single flood fill merges a white eye into the black fur it sits against, and the
        // combined blob is then the whole animal: `walk`, `jump` and `sitdown` found no eyes
        // at all that way, and `held` found twenty.
        let eyesAreInky = inky * 2 < ink
        func isEye(_ i: Int) -> Bool { eyesAreInky ? isInky(i) : isPale(i) }

        var seen = [Bool](repeating: false, count: w * h)

        var found: [CGRect] = []
        for start in 0..<(w * h) where !seen[start] && isEye(start) {
            var minX = w, maxX = 0, minY = h, maxY = 0, count = 0
            var stack = [start]; seen[start] = true
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                count += 1
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                    let j = ny * w + nx
                    if !seen[j] && isEye(j) { seen[j] = true; stack.append(j) }
                }
            }
            // Whiskers and highlights are thin; an eye is a chunky blob.
            guard count > 12, maxX - minX > 2, maxY - minY > 2 else { continue }
            // An eye is roughly as tall as it is wide. A *closed* eyelid is a long flat line,
            // and being long it can win on area over the open eye beside it: on `curl` a
            // 37x14 lid beat a 19x21 eye, and the clip rendered at nearly half the right size
            // because clipScale divides by that width. Rejecting flat blobs changes nothing on
            // ten of the twelve clips and fixes the two it should.
            guard (maxY - minY + 1) * 20 >= (maxX - minX + 1) * 11 else { continue }
            // An eye is a feature, not the animal. Without this the dark test would match the
            // whole of a black cat as one blob and hand back his entire silhouette as an eye,
            // which is both wrong and the largest thing on the frame, so it would win.
            guard count * 6 < ink else { continue }
            // On the white-eyed sheets his paws and chest have white in them too, and they
            // were being drawn as extra eyes on his leg. Eyes live in the head, which is in
            // the upper half of the frame, including when he is upside down mid-fall,
            // because the frames are drawn head-up.
            //
            // Scoped to that palette, because it is only ever approximately true and the dark
            // test does not need it: a leaping cat's head is not in the top half of his own
            // bounding box (his arched back and tail are above it), so any tighter version of
            // this guard throws away the real eyes on `jump`.
            guard eyesAreInky || (minY + maxY) / 2 < h / 2 else { continue }
            // CGImage y runs downward; the layer works bottom-up.
            found.append(CGRect(x: CGFloat(minX) / CGFloat(w),
                                y: 1 - CGFloat(maxY) / CGFloat(h),
                                width: CGFloat(maxX - minX + 1) / CGFloat(w),
                                height: CGFloat(maxY - minY + 1) / CGFloat(h)))
        }
        // Biggest first, so the near eye leads when a frame only shows part of the far one.
        found.sort { $0.width * $0.height > $1.width * $1.height }
        let result = Array(found.prefix(2))
        eyeCache[key] = result
        return result
    }

    private static var eyeCache: [String: [CGRect]] = [:]

    /// How much to scale a clip so he is the same size in all of them.
    ///
    /// The source sheets were generated separately and drew him at quite different sizes
    /// (the walk band is 158px tall and the sit band is 287px), so one global scale made him
    /// visibly shrink the moment he started walking.
    ///
    /// Normalised on **eye width**, because it is the one feature present and consistent in
    /// every frame regardless of pose: a crouching cat is legitimately shorter than a
    /// sitting one, so height cannot be the reference, but his eyes are always his eyes.
    ///
    /// Measured across every frame and taken as the **median**, not from the first frame that
    /// happens to have one. A single frame is a bad sample: his eye narrows when he turns his
    /// head and closes when he blinks, so one unlucky frame set the size of a whole animation.
    /// Reading frame 0 alone had `idle` 44% and `run` 42% off their own medians, which is him
    /// visibly changing size the moment he starts moving. The median ignores those outliers.
    ///
    /// Then corrected per sheet, because eye WIDTH is only half a measurement and a handful of
    /// sheets disagree about the other half. See `sheetCorrection`.
    static func clipScale(_ clip: Clip) -> CGFloat {
        if let s = scaleCache[clip.rawValue] { return s }
        // Some sheets cannot be measured by their eyes at all, and are given their band height
        // outright instead. See `bandHeight` for which and why.
        if let target = bandHeight(clip), let img = image(clip, 0) {
            let s = target / CGFloat(img.height)
            scaleCache[clip.rawValue] = s
            return s
        }
        var scale: CGFloat = 1
        var widths: [CGFloat] = []
        for i in 0..<clip.count {
            guard let img = image(clip, i), let eye = eyes(clip, i).first else { continue }
            let widthPx = eye.width * CGFloat(img.width)
            // Blinking and sleeping frames have them closed; a sliver is not a measurement.
            guard widthPx > 2 else { continue }
            widths.append(widthPx)
        }
        if !widths.isEmpty {
            widths.sort()
            scale = Feel.Shape.referenceEyeWidth / widths[widths.count / 2] * sheetCorrection(clip)
        }
        scaleCache[clip.rawValue] = scale
        return scale
    }

    /// On-screen band height, in points, for the sheets whose eyes cannot be used as the
    /// yardstick. Nil means eye width, which is every other clip.
    ///
    /// **Different failures land here**, and it is worth keeping them straight because they
    /// suggest different fixes if a sheet is ever redrawn.
    ///
    /// *Drawn head-on* (`peer`, `peerDown`, `hang`): his eyes are stylistically huge from the
    /// front, so dividing a fixed reference width by the measured eye renders the whole clip
    /// tiny. `peer` proved it by arriving at nine points tall. The rule is "a front view must
    /// bring its own yardstick", not "no front views".
    ///
    /// *Wearing a dark prop* (`callTalk`, `callWork`, `callFull`): `eyes()` finds whatever
    /// contrasts hardest with the fur, and on a ginger cat that is whatever is darkest. A matte
    /// dark-grey headset sits against his eye and a matte dark-grey laptop sits under his paw,
    /// and both are darker and far bigger than he is. Measured, `callTalk`'s "eye" came back as
    /// **126x172** (the headset) and `callWork`'s as **314x191** (the laptop), rendering both
    /// clips at **three points tall**. The `count * 6 < ink` guard in `eyes()` is meant to stop
    /// exactly this and does not, because a laptop really is under a sixth of the drawing.
    ///
    /// **So: any future sheet with a dark prop on it belongs here from the start.** Do not try
    /// to teach `eyes()` the difference. A prop drawn beside his eye in his eye's own colour is
    /// not separable by contrast, which is the only signal that function has.
    ///
    /// Every number is a **tune-by-eye knob**, sized so the cat matches the cat in the
    /// side-view clips. None has been seen on screen.
    static func bandHeight(_ clip: Clip) -> CGFloat? {
        switch clip {
        case .peer:     Feel.Shape.peerHeight
        case .peerDown: Feel.Shape.peerDownHeight
        case .hang:     Feel.Shape.hangHeight
        case .callTalk: Feel.Shape.callTalkHeight
        case .callWork, .callFull: Feel.Shape.callDeskHeight
        // *Eyes closed* (`denSleep`): the third way this measurement fails. A shut lid is a
        // wide flat blob, so dividing the reference width by it renders the clip short: 17pt
        // of tail out of the notch on screen, which reads as a stub.
        case .denSleep: Feel.Shape.denSleepHeight
        // Eyes closed again, and this time by construction: the whole point of the pose is
        // that he has them squeezed shut.
        case .stroked:  Feel.Shape.strokedHeight
        default:        nil
        }
    }

    /// A per-sheet correction on top of the eye-width normalisation, for the sheets that drew
    /// his eye WIDE.
    ///
    /// Eye width is only half a measurement, and across the sheets his eye is not one shape. On
    /// the ones that render correctly it is a tall almond: `idle` 37x54, `walk` 17x25, `sitdown`
    /// 21x31, `alert` 32x48, `groom` 22x31, `run` 13x19, every one of them between 1.38 and 1.50
    /// tall for its width. On these five it comes back much rounder: `lookDown` 34x34, `stretch`
    /// 30x26, `turn` 39x42, `shake` 32x35, `peek` 31x37. Dividing a fixed number by that
    /// inflated width renders the whole clip small, and silently: his body shrinks when he peeks.
    ///
    /// The correction is `sqrt(1.45 / aspect)`, the family's shape over the sheet's own, on
    /// the square root because the error is spread across both axes. Checked against
    /// `all-clips` with every clip drawn at true scale on one baseline, which is the only
    /// instrument that applies here.
    ///
    /// It is a **list and not a formula** on purpose, even though the numbers came from one.
    /// A round eye means two different things and only one of them is this: on `sleep` (18x21),
    /// `curl` (19x21) and `vibe` (33x34) it is a *closed* eye, which is small in both
    /// directions, so their widths are already short and the same formula would inflate a cat
    /// who is the right size. Applying it everywhere made the sleeping cat visibly too big.
    /// Nothing in the pixels separates a squint from a round eye, so the split is a judgement
    /// and is written down as one.
    ///
    /// Re-measure whenever one of these sheets is regenerated. `theWideEyedSheetsRenderAsOneCat`
    /// fails if a new sheet drifts out of the family.
    static func sheetCorrection(_ clip: Clip) -> CGFloat {
        switch clip {
        case .peek:     1.10    // eye 31x37, aspect 1.19
        case .lookDown: 1.20    // eye 34x34, aspect 1.00
        case .turn:     1.16    // eye 39x42, aspect 1.08
        case .shake:    1.15    // eye 32x35, aspect 1.09
        case .stretch:  1.29    // eye 30x26, aspect 0.87
        default:        1
        }
    }

    private static var scaleCache: [String: CGFloat] = [:]

    /// Aspect-correct size. Frames within a clip already share a vertical band, so this keeps
    /// him a consistent height across an animation.
    public static func size(_ clip: Clip, _ index: Int) -> CGSize {
        guard let img = image(clip, index) else {
            return CGSize(width: Feel.Shape.width, height: Feel.Shape.height)
        }
        let s = Feel.Shape.spriteScale * clipScale(clip)
        return CGSize(width: CGFloat(img.width) * s, height: CGFloat(img.height) * s)
    }
}
#endif
