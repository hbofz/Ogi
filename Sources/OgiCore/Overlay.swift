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

    public func render(_ cat: CatState, pose: Body.Pose, gaze: Gaze,
                       heightAboveGround: CGFloat, occluders: [CGRect]) {
        view.apply(cat, pose: pose, gaze: gaze,
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
        for l in [root, maskContainer, maskShape, shadowLayer, bodyLayer, eyesLayer, pupilLayer] { l.actions = noActions }

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
        for l in [root, maskContainer, maskShape, shadowLayer, bodyLayer, eyesLayer, pupilLayer] { l.contentsScale = s }
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

    func apply(_ cat: CatState, pose: Body.Pose, gaze: Gaze,
               heightAboveGround h: CGFloat, occluders: [CGRect]) {
        let bodyRect = CGRect(x: cat.position.x - Feel.Shape.width / 2, y: cat.position.y,
                              width: Feel.Shape.width, height: Feel.Shape.height)
        // The shadow separates from him as he rises, so the box has to follow it down.
        let shadowRect = CGRect(x: cat.position.x - Feel.Shape.width,
                                y: cat.position.y - h - 12,
                                width: Feel.Shape.width * 2, height: 24)
        let padded = bodyRect.union(shadowRect).insetBy(dx: -8, dy: -8)

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
        let lean = -cat.lean * Feel.Physics.maxLean * cat.facing
        let clip = Sprites.clip(for: cat.activity, dangling: pose.dangling,
                                hurrying: cat.hurrying)
        let idx = Sprites.index(clip, activity: cat.activity,
                                walkPhase: pose.walkPhase, elapsed: cat.activityElapsed)
        let size = Sprites.size(clip, idx)
        bodyLayer.anchorPoint = CGPoint(x: 0.5, y: Sprites.footAnchor(clip))
        bodyLayer.contents = Sprites.image(clip, idx)
        // Nearest-neighbour: these are pixel art, and smoothing turns crisp edges to mush.
        bodyLayer.magnificationFilter = .nearest
        bodyLayer.minificationFilter = .trilinear
        bodyLayer.path = nil
        bodyLayer.bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        bodyLayer.transform = CATransform3DConcat(
            CATransform3DMakeScale(s.width * cat.facing, s.height, 1),
            CATransform3DMakeRotation(lean, 0, 0, 1))

        // Live pupils, dropped into the empty amber socket the artwork leaves for them.
        //
        // This was tried once before and removed, because back then every frame had a pupil
        // already painted in: the only way to move one was to repaint the whole socket first,
        // and a drawn-on ellipse never matched a hand-drawn eye. The fix was in the art, not
        // here. Sheets drawn to docs/ART-BRIEF.md have a flat featureless socket, so there is
        // nothing to paint over and nothing to mismatch — hence no `eyesLayer` fill at all.
        //
        // Clips that predate the brief keep their drawn eyes. Painting a second pupil on top
        // of an existing one is exactly the failure that got this removed the first time, so
        // the switch is per clip and each sheet lights up as it is redrawn.
        eyesLayer.path = nil
        let sockets = Sprites.isCurrentArt(clip) ? Sprites.eyes(clip, idx) : []
        if sockets.isEmpty || cat.activity == .sleep || cat.activity == .curl {
            pupilLayer.path = nil        // asleep: the drawn closed eyes are correct
        } else {
            let pupils = CGMutablePath()
            for unit in sockets {
                let r = CGRect(x: unit.minX * size.width, y: unit.minY * size.height,
                               width: unit.width * size.width, height: unit.height * size.height)
                // The pupil rides inside its own socket rather than on top of the whole head,
                // so it stays put when the socket is small or partly hidden. Width and height
                // are taken from the socket separately: a cat's pupil is a vertical slit, and
                // one radius off the smaller dimension draws a disc that fills the whole eye.
                let rx = r.width * Feel.Eyes.pupilWidth / 2
                let ry = r.height * Feel.Eyes.pupilHeight / 2
                let travelX = max(r.width / 2 - rx, 0), travelY = max(r.height / 2 - ry, 0)
                let c = CGPoint(x: r.midX + gaze.offset.x * travelX * cat.facing,
                                y: r.midY + gaze.offset.y * travelY)
                // Blink closes the socket vertically, and the pupil closes with it.
                let lidY = ry * max(gaze.lid, 0.05)
                pupils.addEllipse(in: CGRect(x: c.x - rx, y: c.y - lidY,
                                             width: rx * 2, height: lidY * 2))
            }
            pupilLayer.path = pupils
        }
        // The pupil layer has to carry the body's exact geometry, or the pupils slide off his
        // face the moment he squashes, leans or turns around.
        pupilLayer.anchorPoint = bodyLayer.anchorPoint
        pupilLayer.bounds = bodyLayer.bounds
        pupilLayer.position = bodyLayer.position
        pupilLayer.transform = bodyLayer.transform

        applyOcclusion(occluders, in: padded)

        CATransaction.commit()
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

    // M0 probe: does per-pixel alpha hit testing still work on this macOS?
    // If a click on empty space reaches us, Apple's 26.3-era regression is present here.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        overlay?.click(p, onCat: true)
        overlay?.drag(.began, p)
    }

    override func mouseDragged(with event: NSEvent) {
        overlay?.drag(.moved, convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        overlay?.drag(.ended, convert(event.locationInWindow, from: nil))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
#endif
