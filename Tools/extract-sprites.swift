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
            let xOverlap = b.minX <= m.maxX + 5 && m.minX <= b.maxX + 5
            let yOverlap = b.minY <= m.maxY + 5 && m.minY <= b.maxY + 5
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

let kept = merged.filter {
    let bh = $0.maxY - $0.minY + 1, bw = $0.maxX - $0.minX + 1
    return bh >= minH && bh <= maxH && bw >= 20 && $0.count > 400
}.sorted { ($0.minY / 60, $0.minX) < ($1.minY / 60, $1.minX) }

// Every frame in a sheet gets the SAME vertical extent, aligned on the sheet's own ground
// line. Cropping each frame tight to its ink would throw away exactly the information that
// makes a jump read as a jump: an airborne cat would be re-planted on the ground, and a
// crouch and a leap would render at identical heights.
let sheetTop = kept.map(\.minY).min() ?? 0
let sheetBottom = kept.map(\.maxY).max() ?? 0
print("found \(merged.count) blobs, kept \(kept.count), shared band y=\(sheetTop)...\(sheetBottom)")

let out = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

for (n, blob) in kept.enumerated() {
    var b = blob
    b.minY = sheetTop
    b.maxY = sheetBottom
    let bw = b.maxX - b.minX + 1, bh = b.maxY - b.minY + 1
    var cropped = [UInt8](repeating: 0, count: bw * bh * 4)
    for y in 0..<bh {
        for x in 0..<bw {
            let si = (b.minY + y) * w + (b.minX + x)
            let di = (y * bw + x) * 4
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
