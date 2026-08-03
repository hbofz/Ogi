// Segments a flat-background reference sheet into individual transparent sprites.
//
// ponytail: CoreGraphics rather than Pillow/OpenCV. No pip install, no vendored dependency,
// and it is a build-time tool that never ships. Run with: swift Tools/extract-sprites.swift <sheet.png> <outDir>
//
// The sheet is a flat cream background with dark cat poses on it, so "not background" is a
// single colour-distance test and the rest is one flood fill.
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: extract-sprites <sheet.png> <outDir> [minHeight] [maxHeight]")
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

@inline(__always) func isInk(_ i: Int) -> Bool {
    if isSkin(i) { return false }
    let (r, g, b) = rgb(i)
    let d = abs(r - bg.0) + abs(g - bg.1) + abs(b - bg.2)
    return d > 60
}

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
            if isInk(si) {
                cropped[di] = px[si * 4]; cropped[di + 1] = px[si * 4 + 1]
                cropped[di + 2] = px[si * 4 + 2]; cropped[di + 3] = 255
            }
        }
    }
    // Scrub the sheet's ground rule. A few of its pixels touch the paws, so they survive
    // the pre-merge filter and come out as a bright line welded under the cat.
    for y in max(0, bh - 5)..<bh {
        var filled = 0
        for x in 0..<bw where cropped[(y * bw + x) * 4 + 3] > 0 { filled += 1 }
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
