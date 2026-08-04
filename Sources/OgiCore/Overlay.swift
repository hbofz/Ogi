#if canImport(AppKit)
import AppKit
import QuartzCore

/// The window, the layer tree, and the clock. All AppKit lives here.
public enum DragPhase: Sendable { case began, moved, ended }

@MainActor
public final class Overlay {

    public var onTick: ((CFTimeInterval) -> Void)?
    /// Set by M0's click-through probe. See `OgiView.mouseDown`.
    public var onClick: ((NSPoint, Bool) -> Void)?
    public var onDrag: ((DragPhase, CGPoint) -> Void)?

    private let window: NSWindow
    private let view: OgiView

    public init(screen: NSScreen) {
        view = OgiView(frame: CGRect(origin: .zero, size: screen.frame.size))

        window = NSWindow(contentRect: screen.frame,
                          styleMask: .borderless,
                          backing: .buffered,
                          defer: false)
        window.contentView = view
        window.isOpaque = false
        window.backgroundColor = .clear
        // Mandatory. A shadow on a transparent window paints a grey rectangular halo.
        window.hasShadow = false
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        // 25 = kCGStatusWindowLevel. Above the menu bar (24) so he can perch on it, below
        // menus (101) so he never draws over an open File menu, below drag images (500).
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // Click-through is driven by `setInteractive`, not by per-pixel alpha hit testing.
        // See the note there. Default to swallowing nothing.
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()

        view.overlay = self
    }

    public var windowNumber: Int { window.windowNumber }

    /// The display changed shape under him. Without this the window keeps the old
    /// configuration's size and he is drawn outside it, which looks exactly like a crash.
    public func setFrame(_ r: CGRect) {
        window.setFrame(r, display: false)
        view.frame = CGRect(origin: .zero, size: r.size)
    }

    public func start() { view.startLink() }

    /// You left. Stop the clock entirely rather than ticking at a low rate: a paused
    /// display link is zero wakeups, and "you lock the screen and all polling suspends" is
    /// a stated behaviour, not an optimisation.
    public func suspend() { view.setPaused(true) }
    public func resume() { view.setPaused(false) }

    /// Asks the system to call us less often when he is settled.
    ///
    /// Honest caveat: this genuinely lowers the callback rate on ProMotion, and is ignored
    /// on a fixed-refresh display, where the link still fires at 60Hz and we simply do less
    /// per fire. Real zero comes from `suspend()`.
    public func setPreferredRate(_ hz: Double) { view.setPreferredRate(hz) }

    private var interactive = false

    /// The whole click-through mechanism: swallow mouse events only while the cursor is
    /// actually over him, and pass everything else straight through.
    ///
    /// AppKit is supposed to make this free — non-opaque windows get per-pixel alpha hit
    /// testing, so clicks land on opaque pixels and fall through transparent ones with no
    /// code at all. Apple broke that in macOS 26.3 RC, shipped a fix, and it regressed
    /// again. **Measured broken on 26.5.1**: clicks on empty space were reaching this
    /// window, which would make Ogi swallow every click on the screen.
    ///
    /// ponytail: this poll is the ONLY mechanism, not a fallback behind a version check.
    /// It is correct on every macOS, costs one property read per frame from a cursor
    /// position we already sample, and deletes an entire branch plus the version-sniffing
    /// heuristic that would decide between them. The known cost is a race: flipping on the
    /// frame the cursor arrives means a click inside ~16ms of touching him can be missed.
    /// Fine for petting a cat. Revisit only if petting feels unresponsive.
    public func setInteractive(_ wanted: Bool) {
        guard wanted != interactive else { return }
        interactive = wanted
        window.ignoresMouseEvents = !wanted
    }

    public func render(_ cat: CatState, pose: Body.Pose, gaze: Gaze, frame: Sprites.Frame,
                       heightAboveGround: CGFloat, occluders: [CGRect]) {
        view.apply(cat, pose: pose, gaze: gaze, frame: frame,
                   heightAboveGround: heightAboveGround, occluders: occluders)
    }

    fileprivate func tick(_ t: CFTimeInterval) { onTick?(t) }
    fileprivate func click(_ p: NSPoint, onCat: Bool) { onClick?(p, onCat) }
    fileprivate func drag(_ phase: DragPhase, _ p: CGPoint) { onDrag?(phase, p) }
}

@MainActor
final class OgiView: NSView {
    fileprivate weak var overlay: Overlay?

    private let root = CALayer()
    /// Everything that can be occluded lives inside this, so one mask covers them all.
    /// Sized to him rather than to the screen: a screen-sized CAShapeLayer mask would
    /// rasterise a ~38MB alpha texture every time a window moves.
    private let maskContainer = CALayer()
    private let maskShape = CAShapeLayer()
    private let shadowLayer = CAShapeLayer()
    private let bodyLayer = CAShapeLayer()
    private let eyesLayer = CAShapeLayer()
    private let pupilLayer = CAShapeLayer()
    private let zzzLayer = CAShapeLayer()
    private var link: CADisplayLink?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.isOpaque = false

        // Kill implicit animations ONCE, at construction. Skipping this is the number-one
        // bug writing a pet on Core Animation: every property assignment silently gets a
        // 0.25s animation, the physics turns to mush, and it reads as a physics bug.
        let noActions: [String: CAAction] = [
            "position": NSNull(), "bounds": NSNull(), "path": NSNull(),
            "transform": NSNull(), "mask": NSNull(), "opacity": NSNull(),
            "fillColor": NSNull(), "contents": NSNull(),
        ]
        for l in [root, maskContainer, maskShape, shadowLayer, bodyLayer, eyesLayer, pupilLayer, zzzLayer] { l.actions = noActions }

        bodyLayer.fillColor = NSColor(srgbRed: 0.043, green: 0.043, blue: 0.051, alpha: 1).cgColor
        // The rim light. On a light background the fill carries the contrast and this
        // vanishes; on a dark background the fill vanishes and this carries it. On any
        // background at least one of the two has contrast, with zero knowledge of it.
        //
        // Calibrated against a pure-black terminal, which is the worst case: the rim is
        // the ONLY thing visible there, so it has to carry him alone. 0.22 was too faint.
        bodyLayer.strokeColor = NSColor.white.withAlphaComponent(0.45).cgColor
        bodyLayer.lineWidth = 1.25

        shadowLayer.fillColor = NSColor.black.cgColor

        // Warm off-white. Pure white reads clinical.
        eyesLayer.fillColor = NSColor(srgbRed: 0.949, green: 0.941, blue: 0.910, alpha: 1).cgColor

        maskContainer.addSublayer(shadowLayer)
        maskContainer.addSublayer(bodyLayer)
        pupilLayer.fillColor = NSColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 1).cgColor
        maskContainer.addSublayer(eyesLayer)
        maskContainer.addSublayer(pupilLayer)
        // Drawn rather than lettered: a Z is a three-segment polyline, and a stroked path scales
        // with him and stays crisp where a font would not at this size. It also has to be code
        // rather than art — the cutter flood-fills connected ink, so a Z drawn into a sheet would
        // come back as its own blob and either be discarded or split the frame.
        zzzLayer.fillColor = nil
        zzzLayer.lineJoin = .round
        zzzLayer.lineCap = .round
        maskContainer.addSublayer(zzzLayer)
        root.addSublayer(maskContainer)
        layer?.addSublayer(root)
        updateScale()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Bottom-left origin everywhere, so NSScreen → skyline → layer tree is one coordinate
    /// system with exactly one conversion, at the CGWindowList boundary.
    override var isFlipped: Bool { false }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    private func updateScale() {
        let s = window?.backingScaleFactor ?? 2
        for l in [root, maskContainer, maskShape, shadowLayer, bodyLayer, eyesLayer, pupilLayer, zzzLayer] { l.contentsScale = s }
    }

    func startLink() {
        link?.invalidate()
        let l = displayLink(target: self, selector: #selector(step(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 60, preferred: 60)
        // .common, not .default: in .default the link stalls while a menu is tracking and
        // the cat freezes mid-fall when someone opens a menu.
        l.add(to: .main, forMode: .common)
        link = l
    }

    private var requestedRate: Double = 60

    func setPreferredRate(_ hz: Double) {
        guard let link, abs(requestedRate - hz) > 0.5 else { return }
        requestedRate = hz
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: Float(max(hz * 0.5, 1)), maximum: 60, preferred: Float(hz))
    }

    func setPaused(_ paused: Bool) {
        guard link?.isPaused != paused else { return }
        link?.isPaused = paused
    }

    @objc private func step(_ l: CADisplayLink) {
        overlay?.tick(l.targetTimestamp)
    }

    func apply(_ cat: CatState, pose: Body.Pose, gaze: Gaze, frame: Sprites.Frame,
               heightAboveGround h: CGFloat, occluders: [CGRect]) {
        // The REAL drawn rect, not a nominal 52x34. Building the mask box from the nominal
        // size cropped the top of his head whenever an occluder existed.
        let bodyRect = frame.rect(at: cat.position)
        let size = frame.size
        // The shadow separates from him as he rises, so the box has to follow it down.
        let shadowRect = CGRect(x: cat.position.x - size.width / 2 - 12,
                                y: cat.position.y - h - 12,
                                width: size.width + 24, height: 24)
        // The z's rise well above his head, and `applyOcclusion` masks everything to this rect,
        // so leaving them out of it means they vanish the moment any window overlaps him —
        // which is most of the time, since he sleeps on a window edge.
        let sleepRect = cat.activity == .sleep
            ? CGRect(x: cat.position.x - size.width, y: cat.position.y,
                     width: size.width * 2, height: size.height * 2.4)
            : bodyRect
        let padded = bodyRect.union(shadowRect).union(sleepRect).insetBy(dx: -8, dy: -8)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        maskContainer.frame = padded
        let origin = padded.origin   // children are positioned relative to the container

        // Anchor at the feet so squash keeps them planted.
        bodyLayer.position = CGPoint(x: cat.position.x - origin.x, y: cat.position.y - origin.y)
        // Squash, plus a lean into the motion of whatever he is standing on. Rotating
        // about the feet (the anchor point) is what makes it read as bracing rather than
        // sliding: his paws stay put and his body tips.
        // Squash, a lean into whatever is carrying him, and a mirror for facing.
        // Rotating about the feet is what makes the lean read as bracing rather than
        // sliding: his paws stay put and his body tips.
        let s = cat.scale
        // The flip only. `turn` is drawn as the transition right -> left, so its mirror is
        // inverted from every other clip. See `Sprites.mirror`.
        let mirror = Sprites.mirror(frame.clip, facing: cat.facing)
        // The lean is NOT the mirror. The rotation is concatenated after the flip, so it is in
        // screen space: which way he braces against a moving platform depends on which way he
        // is pointing, and nothing about how his sheet happens to be drawn.
        let lean = -cat.lean * Feel.Physics.maxLean * cat.facing
        bodyLayer.anchorPoint = CGPoint(x: 0.5, y: frame.anchor)
        bodyLayer.contents = Sprites.image(frame.clip, frame.index)
        // Nearest-neighbour: these are pixel art, and smoothing turns crisp edges to mush.
        bodyLayer.magnificationFilter = .nearest
        bodyLayer.minificationFilter = .trilinear
        bodyLayer.path = nil
        bodyLayer.bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        bodyLayer.transform = CATransform3DConcat(
            CATransform3DMakeScale(s.width * mirror, s.height, 1),
            CATransform3DMakeRotation(lean, 0, 0, 1))

        // No live pupils. The drawn frames carry their own eyes and that is deliberate for
        // now: painting a tracking pupil needs an empty socket in the artwork, and the sheets
        // are drawn with the eye complete. Gaze is still computed and still passed in, so this
        // is a decision about rendering rather than a capability that was thrown away.
        eyesLayer.path = nil
        pupilLayer.path = nil

        drawSleepiness(cat, size: size, in: padded)

        applyOcclusion(occluders, in: padded)

        CATransaction.commit()
    }

    /// The drifting "z"s while he is asleep.
    ///
    /// Procedural for the same reason the tail and the shadow are: they need to drift and fade
    /// on their own clock rather than repeat in lockstep with a 3-frame breathing loop, and a
    /// z drawn into a sheet would be flood-filled by the cutter as a separate blob anyway.
    ///
    /// Three of them, evenly staggered across one rise, so there is always one faint near the
    /// top and one just appearing. Each grows and fades as it goes, which reads as distance.
    private func drawSleepiness(_ cat: CatState, size: CGSize, in padded: CGRect) {
        guard cat.activity == .sleep else {
            zzzLayer.path = nil
            return
        }
        typealias f = Feel.Sleepiness
        let h = size.height
        // Start just above his head. He sleeps curled with his head at the *back* of the
        // sprite, so this is against his facing rather than with it — the sheet mirrors with
        // `facing`, and his nose ends up on whichever side his tail is not.
        let origin = CGPoint(x: cat.position.x - padded.minX - h * 0.30 * cat.facing,
                             y: cat.position.y - padded.minY + h * 0.52)

        let path = CGMutablePath()
        for i in 0..<f.count {
            // Each z is offset a fraction of a rise ahead of the last, and the whole thing
            // wraps, so this is one clock rather than three independent ones.
            let t = ((cat.activityElapsed / f.riseSeconds) + Double(i) / Double(f.count))
                .truncatingRemainder(dividingBy: 1)
            let p = CGFloat(t)
            let glyph = h * f.glyphHeight * (1 + p * f.growth)
            let x = origin.x - h * f.driftSide * p * cat.facing
            let y = origin.y + h * f.driftHeight * p
            // A capital Z is exactly three strokes, so it is three lines rather than a font.
            let w = glyph * 0.72
            path.move(to: CGPoint(x: x, y: y + glyph))
            path.addLine(to: CGPoint(x: x + w, y: y + glyph))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + w, y: y))
        }
        zzzLayer.path = path
        zzzLayer.frame = CGRect(origin: .zero, size: padded.size)
        zzzLayer.lineWidth = max(1, h * 0.028)
        zzzLayer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        // Fade the whole group in and out with the newest z, so nothing pops into existence.
        let lead = (cat.activityElapsed / f.riseSeconds).truncatingRemainder(dividingBy: 1)
        zzzLayer.opacity = f.peakOpacity * Float(min(1, sin(lead * .pi) * 1.6 + 0.35))
    }

    /// Clips him to the region not covered by windows in front of his perch. This is the
    /// thing no other desktop pet does, and the reason he reads as being *in* your screen
    /// rather than pasted on top of it.
    private func applyOcclusion(_ occluders: [CGRect], in padded: CGRect) {
        let relevant = occluders.filter { $0.intersects(padded) }
        guard !relevant.isEmpty else {
            // ~95% of frames. Skips mask rasterisation entirely.
            maskContainer.mask = nil
            return
        }

        let local = CGRect(origin: .zero, size: padded.size)
        var region = CGPath(rect: local, transform: nil)
        for r in relevant {
            let o = r.offsetBy(dx: -padded.minX, dy: -padded.minY)
            // Real boolean subtraction, NOT an even-odd compound path. Even-odd looks
            // right until two occluders overlap, at which point the intersection has an
            // odd crossing count and renders *filled* — he'd show through the overlap.
            // Overlapping windows are the normal case.
            region = region.subtracting(
                CGPath(roundedRect: o,
                       cornerWidth: Feel.World.windowCornerRadius,
                       cornerHeight: Feel.World.windowCornerRadius, transform: nil))
        }
        maskShape.frame = local
        maskShape.path = region
        maskContainer.mask = maskShape
    }

    // Screen-global, not view-local: the cat's world position is screen-global and the
    // overlay's origin is not guaranteed to be (0, 0).
    override func mouseDown(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        overlay?.click(p, onCat: true)
        overlay?.drag(.began, p)
    }

    override func mouseDragged(with event: NSEvent) {
        overlay?.drag(.moved, NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        overlay?.drag(.ended, NSEvent.mouseLocation)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
#endif
