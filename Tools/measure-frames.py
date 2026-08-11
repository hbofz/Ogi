#!/usr/bin/env python3
"""Measure cut sprite frames without any third-party libraries.

The Mac's system python has no PIL and no PyObjC, and doing this inside a debug-mode Swift test
takes minutes because the inner loop is not optimised. So: a minimal RGBA8 PNG decoder, which is
all these frames ever are.

    python3 Tools/measure-frames.py <directory-of-cut-frames>

It reads a directory of already-cut PNG frames, which `extract-sprites.swift` produces.
The source sheets themselves are not in this repository.

Reports, per frame: the ink box, where the topmost and bottommost ink sits as a fraction of the
frame (which is what `footAnchor` wants), and the horizontal centroid of the top and bottom
bands, so a clip can be checked for drift against whichever end of the cat is holding on.
"""
import sys, zlib, struct, glob, os


def read_rgba(path):
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', f'{path} is not a PNG'
    pos, idat, w, h, depth, color = 8, b'', 0, 0, 0, 0
    while pos < len(data):
        (length,) = struct.unpack('>I', data[pos:pos + 4])
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if kind == b'IHDR':
            w, h, depth, color = struct.unpack('>IIBB', body[:10])
        elif kind == b'IDAT':
            idat += body
        elif kind == b'IEND':
            break
        pos += 12 + length
    assert depth == 8 and color == 6, f'{path}: expected 8-bit RGBA, got depth={depth} color={color}'
    raw = zlib.decompress(idat)
    stride, out, prev = w * 4, bytearray(w * h * 4), bytearray(w * 4)
    p = 0
    for y in range(h):
        f = raw[p]; p += 1
        line = bytearray(raw[p:p + stride]); p += stride
        if f == 1:
            for i in range(4, stride): line[i] = (line[i] + line[i - 4]) & 255
        elif f == 2:
            for i in range(stride): line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                a = line[i - 4] if i >= 4 else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i - 4] if i >= 4 else 0
                c = prev[i - 4] if i >= 4 else 0
                b = prev[i]
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 255
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return w, h, out


def measure(path):
    w, h, px = read_rgba(path)
    minX, maxX, minY, maxY = w, -1, h, -1
    rows = []
    for y in range(h):
        xs = [x for x in range(w) if px[(y * w + x) * 4 + 3] > 128]
        rows.append(xs)
        if xs:
            minY = min(minY, y); maxY = max(maxY, y)
            minX = min(minX, xs[0]); maxX = max(maxX, xs[-1])
    if maxY < 0:
        return None
    band = max(4, (maxY - minY + 1) // 12)

    def centroid(ys):
        tot = [x for y in ys for x in rows[y]]
        return sum(tot) / len(tot) if tot else 0

    return dict(
        w=w, h=h,
        inkW=maxX - minX + 1, inkH=maxY - minY + 1,
        top=minY, bottom=maxY,
        # footAnchor is measured from the TOP of the frame downward, as Sprites uses it.
        topFrac=minY / h, bottomFrac=(maxY + 1) / h,
        topCentre=centroid(range(minY, min(minY + band, h))),
        bottomCentre=centroid(range(max(maxY - band + 1, 0), maxY + 1)),
    )


d = sys.argv[1]
files = sorted(glob.glob(os.path.join(d, '*.png')))
print(f"{'frame':<10}{'frame px':>10}{'ink':>12}{'top':>7}{'bottom':>8}"
      f"{'topFrac':>9}{'botFrac':>9}{'topCx':>8}{'botCx':>8}")
rows = []
for f in files:
    m = measure(f)
    if not m:
        print(f'{os.path.basename(f):<10} EMPTY'); continue
    rows.append(m)
    print(f"{os.path.basename(f):<10}{m['w']}x{m['h']:<6}{m['inkW']}x{m['inkH']:<7}"
          f"{m['top']:>7}{m['bottom']:>8}{m['topFrac']:>9.3f}{m['bottomFrac']:>9.3f}"
          f"{m['topCentre']:>8.1f}{m['bottomCentre']:>8.1f}")

if rows:
    def spread(key):
        vals = [r[key] for r in rows]
        return max(vals) - min(vals)
    print(f"\ndrift across the clip:")
    print(f"  top of ink      {spread('top'):>6.0f} px   <- his grip, if he is hanging")
    print(f"  bottom of ink   {spread('bottom'):>6.0f} px   <- his feet, if he is standing")
    print(f"  top centroid    {spread('topCentre'):>6.1f} px")
    print(f"  bottom centroid {spread('bottomCentre'):>6.1f} px")
    print(f"  ink width       {spread('inkW'):>6.0f} px")
    print(f"  ink height      {spread('inkH'):>6.0f} px")
