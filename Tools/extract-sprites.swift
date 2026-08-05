// Segments a flat-background reference sheet into individual transparent sprites.
//
// ponytail: CoreGraphics rather than Pillow/OpenCV. No pip install, no vendored dependency,
// and it is a build-time tool that never ships. Run with: swift Tools/extract-sprites.swift <sheet.png> <outDir>
//
// The sheet is a flat background with dark cat poses on it, so "not background" is a single
// colour-distance test and the rest is one flood fill.
import AppKit
import CoreGraphics

// MARK: - Chroma key
//
// Edge pixels are a blend of cat and background, and writing them fully opaque welds a bright
// rim around him — the pale halo on every sprite cut before this existed.
//
// Recovering their true coverage needs a real chroma key, and a chroma key needs a background
// the subject cannot reach. Distance from the background is NOT good enough: it cannot tell a
// light-coloured cat pixel from a half-covered edge pixel, and Ogi's white eyes sit 45 away
// from cream, so keying on distance renders them at alpha 17/255 and you see the wallpaper
// through his face. That failure is why this keys on a single channel instead.
//
// Ogi is black, warm grey, amber and white. In all of those, green is at or below the larger
// of red and blue — so against a pure-green sheet, `green - max(red, blue)` is exactly how
// much background is showing through and nothing else. Magenta does not work for this palette
// because white and amber both sit close to it; red would collide with the amber.

/// The dominant channel of a background colour, if it has one. `nil` for a neutral background
/// like the old cream sheets, which cannot be keyed and fall back to opaque edges.
func keyChannel(for bg: (Int, Int, Int)) -> (index: Int, range: Double)? {
    let c = [bg.0, bg.1, bg.2]
    let k = c.indices.max { c[$0] < c[$1] }!
    let range = Double(c[k] - c.indices.filter { $0 != k }.map { c[$0] }.max()!)
    // A key must dominate. Cream's channels sit within 16 of each other and key nothing.
    return range > 100 ? (k, range) : nil
}

/// Fraction of a pixel covered by the cat, 0...1.
func coverage(_ c: [Int], _ key: (index: Int, range: Double)?) -> Double {
    guard let key else { return 1 }
    let spill = Double(c[key.index] - c.indices.filter { $0 != key.index }.map { c[$0] }.max()!)
    return 1 - min(1, max(0, spill / key.range))
}

/// Divides the background back out of a blended pixel, returning premultiplied colour.
/// observed = bg·(1-a) + cat·a, and premultiplied is cat·a, so it is just a subtraction.
/// That despills the green off his edges for free.
func unblend(_ c: [Int], _ bg: (Int, Int, Int), _ a: Double) -> [Int] {
    let inv = 1 - a, b = [bg.0, bg.1, bg.2]
    return (0..<3).map { max(0, min(255, Int((Double(c[$0]) - Double(b[$0]) * inv).rounded()))) }
}

let args = CommandLine.arguments

// Every colour on Ogi has to survive the key opaque and unchanged, and every half-covered edge
// pixel has to come back at roughly half alpha with no background left in it. Run with:
//   swift Tools/extract-sprites.swift --self-check
if args.count == 2, args[1] == "--self-check" {
    let green = (0, 255, 0)
    let key = keyChannel(for: green)!
    let palette: [(String, [Int])] = [
        ("body black", [24, 24, 26]), ("body shading", [58, 54, 56]),
        ("warm grey", [96, 84, 82]),  ("ear pink", [150, 118, 120]),
        ("amber eye", [255, 176, 0]), ("eye white", [255, 255, 255]),
        ("whisker grey", [214, 210, 205]),
    ]
    assert(keyChannel(for: (248, 240, 232)) == nil, "cream must not be treated as a key")
    for (name, cat) in palette {
        let a = coverage(cat, key)
        assert(a > 0.99, "\(name): interior came back translucent at \(a)")
        assert(unblend(cat, green, a) == cat, "\(name): interior colour was altered")

        let half = (0..<3).map { Int((Double([green.0, green.1, green.2][$0]) + Double(cat[$0])) / 2) }
        let ha = coverage(half, key)
        assert(abs(ha - 0.5) < 0.2, "\(name): half-covered edge keyed to \(ha)")
        let straight = unblend(half, green, ha).map { Int(Double($0) / ha) }
        assert(straight[1] - max(straight[0], straight[2]) <= 4, "\(name): green survived the key")
    }
    print("self-check OK — \(palette.count * 2) cases")
    exit(0)
}

guard args.count >= 3 else {
    print("usage: extract-sprites <sheet.png> <outDir> [minHeight] [maxHeight]")
    print("       extract-sprites --self-check")
    exit(1)
}
let minH = args.count > 3 ? Int(args[3])! : 40
let maxH = args.count > 4 ? Int(args[4])! : 100_000

guard let src = NSImage(contentsOfFile: args[1]),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("could not read \(args[1])"); exit(1)
}
let w = cg.width, h = cg.height
print("sheet \(w)x\(h)")

// Redraw into a known RGBA8 buffer so pixel access is unambiguous.
var px = [UInt8](repeating: 0, count: w * h * 4)
px.withUnsafeMutableBytes { buf in
    let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                        bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
}

@inline(__always) func rgb(_ i: Int) -> (Int, Int, Int) {
    (Int(px[i * 4]), Int(px[i * 4 + 1]), Int(px[i * 4 + 2]))
}

// Background = the most common colour, which on these sheets is the cream field.
var histogram: [Int: Int] = [:]
for i in stride(from: 0, to: w * h, by: 7) {
    let (r, g, b) = rgb(i)
    histogram[(r / 8) << 16 | (g / 8) << 8 | (b / 8), default: 0] += 1
}
let bgKey = histogram.max { $0.value < $1.value }!.key
let bg = (((bgKey >> 16) & 0xFF) * 8, ((bgKey >> 8) & 0xFF) * 8, (bgKey & 0xFF) * 8)
print("background ≈ rgb\(bg)")

// Some sheets include a human hand holding the cat. Ogi is black and skin is warm, so a
// red-minus-blue test removes the hand and keeps everything else — including the white of
// his eyes, which is neutral and so survives.
let dropWarm = ProcessInfo.processInfo.environment["DROP_WARM"] != nil

@inline(__always) func isSkin(_ i: Int) -> Bool {
    guard dropWarm else { return false }
    let (r, g, b) = rgb(i)
    return r - b > 22 && r > 120
}

@inline(__always) func bgDistance(_ i: Int) -> Int {
    let (r, g, b) = rgb(i)
    return abs(r - bg.0) + abs(g - bg.1) + abs(b - bg.2)
}

@inline(__always) func isInk(_ i: Int) -> Bool {
    if isSkin(i) { return false }
    // 28, not 60. On a cream sheet his eyes are pure white, only 45 away from the background —
    // a threshold of 60 silently DELETED both of them and you saw the wallpaper through the
    // holes. Anything above ~20 still rejects sheet noise, on cream or on a magenta key.
    return bgDistance(i) > 28
}

let key = keyChannel(for: bg)
print(key.map { "key channel \(["R", "G", "B"][$0.index]), range \(Int($0.range))" }
      ?? "neutral background, opaque edges (halo will survive — see docs/ART-BRIEF.md)")

// Flood fill each connected blob of ink. Iterative: a recursive fill blows the stack on a
// 1500px sheet.
var seen = [Bool](repeating: false, count: w * h)
struct Blob { var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1, count = 0 }
var blobs: [Blob] = []

for start in 0..<(w * h) where !seen[start] && isInk(start) {
    var blob = Blob()
    var stack = [start]
    seen[start] = true
    while let i = stack.popLast() {
        let x = i % w, y = i / w
        blob.minX = min(blob.minX, x); blob.maxX = max(blob.maxX, x)
        blob.minY = min(blob.minY, y); blob.maxY = max(blob.maxY, y)
        blob.count += 1
        // 8-connected, so antialiased edges and whiskers stay attached to the body.
        for dy in -1...1 {
            for dx in -1...1 where dx != 0 || dy != 0 {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                let j = ny * w + nx
                if !seen[j] && isInk(j) { seen[j] = true; stack.append(j) }
            }
        }
    }
    blobs.append(blob)
}

// Drop furniture BEFORE merging, not after. Caption text and the ground rule under each
// pose sit within a few pixels of the cat, so merging first glues them on permanently.
blobs = blobs.filter { b in
    let bw = b.maxX - b.minX + 1, bh = b.maxY - b.minY + 1
    if bh < 22 && bw > bh * 3 { return false }          // ground rules and underlines
    if bh < 26 && b.count < 900 { return false }        // caption text
    return true
}
blobs.sort { $0.minX < $1.minX }
var merged: [Blob] = []
for b in blobs {
    var b = b
    var didMerge = true
    while didMerge {
        didMerge = false
        for (i, m) in merged.enumerated() {
            // 40, not the 5 this shipped with: the event sheets draw detached effects — a
            // bolt over his back, a note beside his ear, a "?" above his head — and at 5px
            // those cut as phantom frames. 40 clusters anything within half the mandated
            // 80px inter-frame gap, so effects weld to their cat and frames never weld to
            // each other. The furniture filter already ran, so captions cannot glue on.
            let xOverlap = b.minX <= m.maxX + 40 && m.minX <= b.maxX + 40
            let yOverlap = b.minY <= m.maxY + 40 && m.minY <= b.maxY + 40
            if xOverlap && yOverlap {
                b.minX = min(b.minX, m.minX); b.maxX = max(b.maxX, m.maxX)
                b.minY = min(b.minY, m.minY); b.maxY = max(b.maxY, m.maxY)
                b.count += m.count
                merged.remove(at: i)
                didMerge = true
                break
            }
        }
    }
    merged.append(b)
}

// FRAMES=N slices the sheet into N equal cells and pools ink by cell, ignoring blobs
// entirely. The generator does not always honour the 80px rule: droop came back with its
// frames close enough to TOUCH, one connected blob across the whole row, which no
// clustering tolerance can ever split. An evenly spaced row makes the cell assignment
// trivial and exact instead; the cost is that a whisker crossing a cell boundary is
// clipped at it, which on a crowded sheet was already lost.
if let n = ProcessInfo.processInfo.environment["FRAMES"].flatMap(Int.init) {
    merged = (0..<n).compactMap { i -> Blob? in
        // Inset each cell so a neighbour's paw poking over the boundary (the reason this
        // mode exists is exactly that the frames crowd) stays out of the box, and a noise
        // floor on rows and columns so a stray speck cannot stretch the shared band to the
        // whole sheet — which it did, and a full-height band is a full-height hit rect.
        let inset = (w / n) / 18
        let x0 = w * i / n + inset, x1 = w * (i + 1) / n - inset
        var rows = [Int](repeating: 0, count: h)
        var cols = [Int](repeating: 0, count: w)
        var b = Blob()
        for y in 0..<h {
            for x in x0..<x1 where isInk(y * w + x) {
                rows[y] += 1; cols[x] += 1; b.count += 1
            }
        }
        for y in 0..<h where rows[y] >= 6 { b.minY = min(b.minY, y); b.maxY = max(b.maxY, y) }
        for x in x0..<x1 where cols[x] >= 3 { b.minX = min(b.minX, x); b.maxX = max(b.maxX, x) }
        return b.count > 400 && b.maxY >= 0 && b.maxX >= 0 ? b : nil
    }
    print("FRAMES=\(n): pooled by equal cells")
}

// Left to right, and nothing else. This used to sort by `(minY / 60, minX)` to group a sheet
// into rows, and that silently reordered frames: the bucket is each blob's own ink top, which
// moves with the pose, so two frames side by side in the same row whose ink happened to
// straddle a 60px boundary came out swapped. It cost a walk cycle that played 1,2,4,3,5,6.
//
// Row grouping was never real support for grids anyway — the shared band below spans the whole
// sheet, so a second row would be given the first row's vertical extent. One row per sheet is
// the rule in docs/ART-BRIEF.md, and this now matches it honestly.
let kept = merged.filter {
    let bh = $0.maxY - $0.minY + 1, bw = $0.maxX - $0.minX + 1
    return bh >= minH && bh <= maxH && bw >= 20 && $0.count > 400
}.sorted { $0.minX < $1.minX }

// Every frame in a sheet gets the SAME vertical extent, aligned on the sheet's own ground
// line. Cropping each frame tight to its ink would throw away exactly the information that
// makes a jump read as a jump: an airborne cat would be re-planted on the ground, and a
// crouch and a leap would render at identical heights.
let sheetTop = kept.map(\.minY).min() ?? 0
let sheetBottom = kept.map(\.maxY).max() ?? 0

// GROUNDED=1 additionally pulls every frame down so its lowest paw rests on the sheet's floor.
//
// Rule 1 of docs/ART-BRIEF.md is that his feet share one ground line, and it says that matters
// more than the drawing does, because a frame drawn a few pixels high makes him bob no matter
// how good the art is. The generator gets it close and not exact: `land` came back with the
// standing frame sitting 16px above the squash frame's paws, which is him rising off the
// surface as he recovers from an impact.
//
// It is opt-in and must stay that way. Applying it to `fall` or `jump` would plant an airborne
// cat on a floor that is the entire point of those clips not having.
let groundAlign = ProcessInfo.processInfo.environment["GROUNDED"] != nil
if groundAlign {
    let feet = kept.map(\.maxY)
    let spread = (feet.max() ?? 0) - (feet.min() ?? 0)
    print("grounded: pulling \(kept.count) frames onto the floor, was \(spread)px of drift")
}
print("found \(merged.count) blobs, kept \(kept.count), shared band y=\(sheetTop)...\(sheetBottom)")

/// Where his planted paws are, horizontally: the centroid of the lowest band of ink in a frame.
///
/// The twin of the floor that `GROUNDED` already finds vertically, and it exists for the same
/// reason. Every frame used to be cropped tight to its own ink, so a clip whose silhouette
/// changes shape changed width, and since the renderer centres the frame on him, his BODY slid
/// inside the box as his tail moved. Measured across the shipped sheets: `sitdown` ran 468px
/// down to 223, `lookDown` 537 to 374, and `walk` 357 to 254, which is a 40% pulse on the clip
/// he plays most. Hamzah saw it as him getting smaller while looking over an edge, and as his
/// paws sliding back during the lean.
///
/// His paws are the right anchor because every grounded prompt in this project already demands
/// they stay put ("his four paws stay in exactly the same spot in all four frames"). His tail
/// is the thing that moves, and the tail is what was moving the box.
func pawCentre(_ b: Blob) -> Int {
    let band = max(4, (b.maxY - b.minY + 1) / 12)
    var sum = 0, count = 0
    for y in max(b.minY, b.maxY - band + 1)...b.maxY {
        for x in b.minX...b.maxX where isInk(y * w + x) { sum += x; count += 1 }
    }
    return count > 0 ? sum / count : (b.minX + b.maxX) / 2
}

// Anchored only when GROUNDED, for the same reason the floor is: an airborne cat has no planted
// paw, and the lowest ink on a falling frame is whatever limb happens to be trailing.
let anchors = kept.map { groundAlign ? pawCentre($0) : ($0.minX + $0.maxX) / 2 }
let leftOf = zip(kept, anchors).map { $1 - $0.minX }
let rightOf = zip(kept, anchors).map { $0.maxX - $1 }
let padLeft = leftOf.max() ?? 0
let commonWidth = padLeft + (rightOf.max() ?? 0) + 1
if groundAlign {
    let widths = kept.map { $0.maxX - $0.minX + 1 }
    print("anchored: \(commonWidth)px common width, was \(widths.min() ?? 0)-\(widths.max() ?? 0)px")
}

let out = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

for (n, blob) in kept.enumerated() {
    var b = blob
    // How far this frame's lowest paw sits above the sheet's floor. Sampling the source that
    // much higher up is what drops him onto it, and it is zero unless GROUNDED is set.
    let lift = groundAlign ? sheetBottom - b.maxY : 0
    // ...and the sideways twin of it: how far this frame's own ink starts from the shared
    // anchor. Zero drift for a clip whose paws really do stay put, which is the point.
    let shift = padLeft - leftOf[n]
    b.minY = sheetTop
    b.maxY = sheetBottom
    let inkWidth = b.maxX - b.minX + 1
    let bw = commonWidth, bh = b.maxY - b.minY + 1
    var cropped = [UInt8](repeating: 0, count: bw * bh * 4)
    for y in 0..<bh {
        for x in 0..<inkWidth {
            let sy = b.minY + y - lift
            guard sy >= 0, sy < h else { continue }
            let dx = x + shift
            guard dx >= 0, dx < bw else { continue }
            let si = sy * w + (b.minX + x)
            let di = (y * bw + dx) * 4
            guard isInk(si) else { continue }
            let (r, g, b) = rgb(si)
            let a = coverage([r, g, b], key)
            let premultiplied = unblend([r, g, b], bg, a)
            cropped[di]     = UInt8(premultiplied[0])
            cropped[di + 1] = UInt8(premultiplied[1])
            cropped[di + 2] = UInt8(premultiplied[2])
            cropped[di + 3] = UInt8(clamping: Int((255 * a).rounded()))
        }
    }
    // Scrub the sheet's ground rule. A few of its pixels touch the paws, so they survive
    // the pre-merge filter and come out as a bright line welded under the cat.
    for y in max(0, bh - 5)..<bh {
        var filled = 0
        for x in 0..<bw where cropped[(y * bw + x) * 4 + 3] > 128 { filled += 1 }
        if filled > bw * 6 / 10 {
            for x in 0..<bw { cropped[(y * bw + x) * 4 + 3] = 0 }
        }
    }

    let outImage = cropped.withUnsafeMutableBytes { buf -> CGImage? in
        CGContext(data: buf.baseAddress, width: bw, height: bh, bitsPerComponent: 8,
                  bytesPerRow: bw * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }
    guard let outImage else { continue }
    let url = out.appendingPathComponent(String(format: "%03d.png", n))
    let rep = NSBitmapImageRep(cgImage: outImage)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    print("  \(String(format: "%03d", n)): \(bw)x\(bh) at (\(b.minX),\(b.minY))")
}
