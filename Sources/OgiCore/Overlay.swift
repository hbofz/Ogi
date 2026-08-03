#if canImport(AppKit)
import AppKit
import QuartzCore

/// The window, the layer tree, and the clock. All AppKit lives here.
@MainActor
public final class Overlay {

    public var onTick: ((CFTimeInterval) -> Void)?
    /// Set by M0's click-through probe. See `OgiView.mouseDown`.
    public var onClick: ((NSPoint, Bool) -> Void)?

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

    public func render(_ cat: CatState, gaze: Gaze, heightAboveGround: CGFloat, occluders: [CGRect]) {
        view.apply(cat, gaze: gaze, heightAboveGround: heightAboveGround, occluders: occluders)
    }

    fileprivate func tick(_ t: CFTimeInterval) { onTick?(t) }
    fileprivate func click(_ p: NSPoint, onCat: Bool) { onClick?(p, onCat) }
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
        for l in [root, maskContainer, maskShape, shadowLayer, bodyLayer, eyesLayer] { l.actions = noActions }

        bodyLayer.fillColor = NSColor(srgbRed: 0.043, green: 0.043, blue: 0.051, alpha: 1).cgColor
        // The rim light. On a light background the fill carries the contrast and this
        // vanishes; on a dark background the fill vanishes and this carries it. On any
        // background at least one of the two has contrast, with zero knowledge of it.
        //
        // Calibrated against a pure-black terminal, which is the worst case: the rim is
        // the ONLY thing visible there, so it has to carry him alone. 0.22 was too faint.
        bodyLayer.strokeColor = NSColor.white.withAlphaComponent(0.45).cgColor
        bodyLayer.lineWidth = 1.25
        bodyLayer.path = Body.placeholder()

        shadowLayer.fillColor = NSColor.black.cgColor

        // Warm off-white. Pure white reads clinical.
        eyesLayer.fillColor = NSColor(srgbRed: 0.949, green: 0.941, blue: 0.910, alpha: 1).cgColor

        maskContainer.addSublayer(shadowLayer)
        maskContainer.addSublayer(bodyLayer)
        maskContainer.addSublayer(eyesLayer)
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
        for l in [root, maskContainer, maskShape, shadowLayer, bodyLayer, eyesLayer] { l.contentsScale = s }
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

    @objc private func step(_ l: CADisplayLink) {
        overlay?.tick(l.targetTimestamp)
    }

    func apply(_ cat: CatState, gaze: Gaze, heightAboveGround h: CGFloat, occluders: [CGRect]) {
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
        bodyLayer.anchorPoint = CGPoint(x: 0.5, y: 0)
        bodyLayer.bounds = CGRect(x: -Feel.Shape.width / 2, y: 0,
                                  width: Feel.Shape.width, height: Feel.Shape.height)
        bodyLayer.position = CGPoint(x: cat.position.x - origin.x, y: cat.position.y - origin.y)
        // Squash, plus a lean into the motion of whatever he is standing on. Rotating
        // about the feet (the anchor point) is what makes it read as bracing rather than
        // sliding: his paws stay put and his body tips.
        let s = cat.scale
        let lean = -cat.lean * Feel.Physics.maxLean
        bodyLayer.transform = CATransform3DConcat(
            CATransform3DMakeScale(s.width, s.height, 1),
            CATransform3DMakeRotation(lean, 0, 0, 1))

        // Eyes ride the body but take only HALF the squash. Undeformed eyes on a squashed
        // body look pasted on; fully deformed ones look broken. Half is the animator's cheat.
        eyesLayer.anchorPoint = bodyLayer.anchorPoint
        eyesLayer.bounds = bodyLayer.bounds
        eyesLayer.position = bodyLayer.position
        eyesLayer.transform = CATransform3DConcat(
            CATransform3DMakeScale(1 + (s.width - 1) * 0.5, 1 + (s.height - 1) * 0.5, 1),
            CATransform3DMakeRotation(lean, 0, 0, 1))
        eyesLayer.path = Body.eyes(gaze: gaze)

        shadowLayer.position = CGPoint(x: cat.position.x - origin.x,
                                       y: cat.position.y - h - origin.y)
        shadowLayer.path = Body.shadow(width: Feel.Shape.width, height: h)
        shadowLayer.opacity = Float(Body.shadowOpacity(height: h))

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
        let hit = bodyLayer.frame.insetBy(dx: -8, dy: -8).contains(p)
        overlay?.click(p, onCat: hit)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
#endif
