#!/usr/bin/env python3
"""Turns the icon artwork into icon/Ogi.icns.

    python3 Tools/make-icon.py icon/icon-source.png

The artwork arrives as a rounded square drawn on a flat background, which is not the same thing
as an icon: macOS needs the area outside that rounded square to be TRANSPARENT, or the app shows
a pale square behind itself in a dark Dock.

The mask is taken from the picture rather than computed. A superellipse of the right radius would
be a guess about a curve somebody else drew, and being a pixel out leaves a bright rim; a flood
fill inward from the four corners stops exactly where the artwork starts, whatever its shape.

No third-party libraries: the Mac's system python has no PIL. PNG in, PNG out, then `iconutil`.
"""
import os, struct, subprocess, sys, zlib

# The sizes an .iconset must contain. macOS picks between them by context: 16 and 32 are Finder
# lists and the menu bar, 512@2x is Quick Look and the App Store.
SIZES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
WHITE = 240          # a channel at or above this counts as background
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read_png(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"{path} is not a PNG"
    pos, idat, w, h, depth, colour = 8, b"", 0, 0, 0, 0
    while pos < len(data):
        n = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h, depth, colour = struct.unpack(">IIBB", body[:10])
        elif kind == b"IDAT":
            idat += body
        pos += 12 + n
    assert depth == 8 and colour in (2, 6), f"{path}: need 8-bit RGB or RGBA, got depth {depth} type {colour}"
    stride = w * (4 if colour == 6 else 3)
    raw = zlib.decompress(idat)
    out, prev = bytearray(), bytearray(stride)
    bpp = 4 if colour == 6 else 3
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        out += line
        prev = line
    if colour == 2:                                   # widen RGB to RGBA
        rgba = bytearray(w * h * 4)
        for i in range(w * h):
            rgba[i*4:i*4+3] = out[i*3:i*3+3]
            rgba[i*4+3] = 255
        out = rgba
    return w, h, out


def write_png(path, w, h, px):
    raw = b"".join(b"\x00" + bytes(px[y * w * 4:(y + 1) * w * 4]) for y in range(h))
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))
    open(path, "wb").write(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b""))


def clear_outside(w, h, px):
    """Flood fill inward from the corners, turning the background transparent.

    Connected rather than by colour: the cat's muzzle and paws are near enough to white that
    keying on the colour alone punches holes straight through him.
    """
    seen = bytearray(w * h)
    stack = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]
    cleared = 0
    while stack:
        x, y = stack.pop()
        if not (0 <= x < w and 0 <= y < h):
            continue
        i = y * w + x
        if seen[i]:
            continue
        r, g, b = px[i*4], px[i*4+1], px[i*4+2]
        if r < WHITE or g < WHITE or b < WHITE:
            continue
        seen[i] = 1
        px[i*4+3] = 0
        cleared += 1
        stack += [(x+1, y), (x-1, y), (x, y+1), (x, y-1)]
    return cleared


def scale(w, h, px, size):
    """Box-average down to `size`. Averaging in straight RGBA would drag the transparent
    background's colour into the edge pixels, so colour is weighted by alpha."""
    out = bytearray(size * size * 4)
    for oy in range(size):
        y0, y1 = oy * h // size, max(oy * h // size + 1, (oy + 1) * h // size)
        for ox in range(size):
            x0, x1 = ox * w // size, max(ox * w // size + 1, (ox + 1) * w // size)
            r = g = b = a = n = 0
            for y in range(y0, y1):
                for x in range(x0, x1):
                    i = (y * w + x) * 4
                    al = px[i+3]
                    r += px[i] * al; g += px[i+1] * al; b += px[i+2] * al
                    a += al; n += 1
            o = (oy * size + ox) * 4
            if a:
                out[o], out[o+1], out[o+2] = r // a, g // a, b // a
            out[o+3] = a // n
    return out


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "icon/icon-source.png")
    w, h, px = read_png(src)
    print(f"source {w}x{h}")
    print(f"background cleared: {clear_outside(w, h, px)} px")

    iconset = os.path.join(REPO, "icon/Ogi.iconset")
    os.makedirs(iconset, exist_ok=True)
    for size, scaleFactor in SIZES:
        edge = size * scaleFactor
        name = f"icon_{size}x{size}{'@2x' if scaleFactor == 2 else ''}.png"
        write_png(os.path.join(iconset, name), edge, edge, scale(w, h, px, edge))
        print(f"  {name:22} {edge}x{edge}")

    icns = os.path.join(REPO, "icon/Ogi.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
    print(f"\n{icns}  ({os.path.getsize(icns) // 1024}KB)")


if __name__ == "__main__":
    main()
