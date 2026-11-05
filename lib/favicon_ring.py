#!/usr/bin/env python3
# Ring favicons in a workspace's accent color: the app's own icon shrunk to the
# middle, with an anti-aliased ring around it (the same color as the VS Code
# title bar and the `ws list` swatch). Pure stdlib.
#
#   favicon_ring.py <#rrggbb> <outroot> <app>:<srcdir> [<app>:<srcdir> ...]
#
# Writes <outroot>/<app>/{favicon.ico,favicon-16x16.png,favicon-32x32.png,
# apple-touch-icon.png} from <srcdir>'s PNGs of the same names; an icon it can't
# read becomes a plain ring. Used by `ws serve` (browser tabs) and by
# hooks.example/post-create/t3-project.sh (the T3 Code project icon).
import struct, sys, zlib, os

def chunk(tag, data):
    return (struct.pack('>I', len(data)) + tag + data
            + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff))

def encode_png(rows, size):                           # rows: RGBA bytearrays
    raw = b''.join(b'\x00' + bytes(r) for r in rows)
    ihdr = struct.pack('>IIBBBBB', size, size, 8, 6, 0, 0, 0)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr)
            + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))

def ico_wrapping(png_bytes, size):                    # ICO with embedded PNG
    header = struct.pack('<HHH', 0, 1, 1)
    entry = struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32,
                        len(png_bytes), 22)
    return header + entry + png_bytes

def decode_png(path):
    """8-bit gray/RGB/palette/RGBA, non-interlaced -> (RGBA rows, w, h)."""
    b = open(path, 'rb').read()
    if b[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('not a png')
    pos, idat, plte, trns, hdr = 8, b'', b'', b'', None
    while pos < len(b):
        ln = int.from_bytes(b[pos:pos + 4], 'big')
        tag, c = b[pos + 4:pos + 8], b[pos + 8:pos + 8 + ln]
        if tag == b'IHDR': hdr = struct.unpack('>IIBBBBB', c)
        elif tag == b'PLTE': plte = c
        elif tag == b'tRNS': trns = c
        elif tag == b'IDAT': idat += c
        pos += 12 + ln
    w, h, depth, ctype, _, _, inter = hdr
    if depth != 8 or inter != 0 or ctype not in (0, 2, 3, 6):
        raise ValueError('unsupported png variant')
    bpp = {0: 1, 2: 3, 3: 1, 6: 4}[ctype]
    raw, stride = zlib.decompress(idat), w * bpp
    prev, lines, p = bytearray(stride), [], 0
    for _ in range(h):                                # undo PNG filters
        f, line = raw[p], bytearray(raw[p + 1:p + 1 + stride]); p += 1 + stride
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            up = prev[i]
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + up) & 255
            elif f == 3: line[i] = (line[i] + ((a + up) >> 1)) & 255
            elif f == 4:
                c0 = prev[i - bpp] if i >= bpp else 0
                pa, pb, pc = abs(up - c0), abs(a - c0), abs(a + up - 2 * c0)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc
                                      else up if pb <= pc else c0)) & 255
        lines.append(line); prev = line
    rows = []
    for y in range(h):
        row, line = bytearray(), lines[y]
        for x in range(w):
            if ctype == 6:   row += line[x * 4:x * 4 + 4]
            elif ctype == 2: row += line[x * 3:x * 3 + 3] + b'\xff'
            elif ctype == 0: row += bytes([line[x]] * 3) + b'\xff'
            else:
                i = line[x]
                row += bytes(plte[i * 3:i * 3 + 3])
                row += bytes([trns[i] if i < len(trns) else 255])
        rows.append(row)
    return rows, w, h

def resize(rows, w, h, n):                            # bilinear -> n x n
    out = []
    for y in range(n):
        sy = max(0.0, (y + 0.5) * h / n - 0.5)
        y0 = min(h - 1, int(sy)); y1 = min(h - 1, y0 + 1); fy = sy - y0
        row = bytearray()
        for x in range(n):
            sx = max(0.0, (x + 0.5) * w / n - 0.5)
            x0 = min(w - 1, int(sx)); x1 = min(w - 1, x0 + 1); fx = sx - x0
            for c in range(4):
                row.append(round(
                    rows[y0][x0 * 4 + c] * (1 - fx) * (1 - fy)
                    + rows[y0][x1 * 4 + c] * fx * (1 - fy)
                    + rows[y1][x0 * 4 + c] * (1 - fx) * fy
                    + rows[y1][x1 * 4 + c] * fx * fy))
        out.append(row)
    return out

def badge(size, rgb, src):
    """App logo centered inside an anti-aliased workspace-color ring."""
    canvas = [bytearray(size * 4) for _ in range(size)]
    thick = max(2, round(size / 10))
    if src is not None:
        gap = max(1, size // 16)
        inner = size - 2 * (thick + gap)
        logo, off = resize(*src, inner), thick + gap
        for y in range(inner):
            canvas[off + y][off * 4:(off + inner) * 4] = logo[y]
    cx = (size - 1) / 2
    r_out = size / 2 - 0.5
    r_in = r_out - thick
    for y in range(size):
        for x in range(size):
            d = ((x - cx) ** 2 + (y - cx) ** 2) ** 0.5
            cov = (min(1.0, max(0.0, r_out - d + 0.5))
                   * min(1.0, max(0.0, d - r_in + 0.5)))
            if cov <= 0:
                continue
            i, sa = x * 4, round(cov * 255)          # ring over canvas
            da = canvas[y][i + 3] * (255 - sa) // 255
            fa = sa + da
            for c in range(3):
                canvas[y][i + c] = (rgb[c] * sa + canvas[y][i + c] * da) // fa
            canvas[y][i + 3] = fa
    return canvas

color, outroot = sys.argv[1].lstrip('#'), sys.argv[2]
rgb = tuple(int(color[i:i + 2], 16) for i in (0, 2, 4))
for spec in sys.argv[3:]:
    app, srcdir = spec.split(':', 1)
    outdir = os.path.join(outroot, app)
    os.makedirs(outdir, exist_ok=True)
    for name, size in (('favicon-16x16.png', 16), ('favicon-32x32.png', 32),
                       ('apple-touch-icon.png', 180)):
        src = None
        path = os.path.join(srcdir, name)
        if os.path.isfile(path):
            try:
                src = decode_png(path)
            except Exception:
                src = None                            # fall back: plain circle
        data = encode_png(badge(size, rgb, src), size)
        with open(os.path.join(outdir, name), 'wb') as fh:
            fh.write(data)
        if size == 32:
            with open(os.path.join(outdir, 'favicon.ico'), 'wb') as fh:
                fh.write(ico_wrapping(data, 32))
