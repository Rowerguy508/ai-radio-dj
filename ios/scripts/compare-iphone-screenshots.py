#!/usr/bin/env python3
"""Compare iPhone UI-test screenshots with the status bar masked.

    compare-iphone-screenshots.py BASE_DIR HEAD_DIR [--report FILE]

Every `*_iPhone-*.png` in BASE_DIR must exist in HEAD_DIR with the same size and
identical pixels everywhere except the status-bar strip. The workflow also sets a
`simctl status_bar` override before the shots are taken; this mask is the second
guard, so a clock, battery or signal glyph can never fail the gate on its own.

The strip is the device's portrait safe-area top inset (pt) times its scale, taken
from STATUS_BAR_STRIP below. The table is keyed by the screenshot's portrait pixel
size, so it follows whichever iPhone simulator the runner picks. Values are Apple's
safe-area insets as listed by useyourloaf.com "iPhone 17 Screen Sizes" (Oct 2025)
and the earlier posts in that series. A size missing from the table is an error,
not a guess: add the row.

Landscape iPhone shots get no mask. iOS hides the status bar on iPhone in landscape,
so there is nothing to mask and the whole image is compared.

Shots only in HEAD (a test added by the PR) are listed but do not fail. Shots only
in BASE fail: an iPhone screenshot disappeared. Python 3 standard library only.
"""
import argparse
import os
import struct
import sys
import zlib

# (portrait width px, portrait height px) -> (scale, portrait safe-area top inset in pt)
STATUS_BAR_STRIP = {
    (1320, 2868): (3, 62),  # iPhone 17 Pro Max, 16 Pro Max
    (1290, 2796): (3, 59),  # iPhone 16 Plus, 15 Pro Max, 15 Plus, 14 Pro Max
    (1284, 2778): (3, 47),  # iPhone 14 Plus, 13 Pro Max, 12 Pro Max
    (1260, 2736): (3, 68),  # iPhone Air
    (1242, 2688): (3, 44),  # iPhone 11 Pro Max, XS Max
    (1206, 2622): (3, 62),  # iPhone 17, 17 Pro, 16 Pro
    (1179, 2556): (3, 59),  # iPhone 16, 15 Pro, 15, 14 Pro
    (1170, 2532): (3, 47),  # iPhone 16e, 14, 13 Pro, 13, 12 Pro, 12
    (1125, 2436): (3, 44),  # iPhone 11 Pro, XS, X
    (1080, 2340): (3, 50),  # iPhone 13 mini, 12 mini
    (828, 1792): (2, 48),   # iPhone 11, XR
    (1242, 2208): (3, 20),  # iPhone 8 Plus (home button)
    (750, 1334): (2, 20),   # iPhone SE 2nd/3rd gen, 8 (home button)
}


class PNGError(Exception):
    pass


def mask_rows(width, height):
    """Rows to ignore at the top of a width x height iPhone screenshot."""
    if width > height:
        return 0  # landscape: no status bar on iPhone
    try:
        scale, top_pt = STATUS_BAR_STRIP[(width, height)]
    except KeyError:
        raise PNGError(f"no status-bar strip for a {width}x{height} iPhone screenshot; "
                       "add its scale and portrait safe-area top inset to STATUS_BAR_STRIP")
    return scale * top_pt


def read_png(path):
    """Return (width, height, bytes_per_pixel, filtered_scanlines)."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise PNGError(f"{path}: not a PNG")
    pos, idat, ihdr = 8, [], None
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat.append(body)
        elif kind == b"IEND":
            break
        pos += 12 + length
    if ihdr is None:
        raise PNGError(f"{path}: no IHDR")
    width, height, depth, color, _, _, interlace = ihdr
    channels = {0: 1, 2: 3, 4: 2, 6: 4}.get(color)
    if channels is None or depth not in (8, 16) or interlace != 0:
        raise PNGError(f"{path}: unsupported PNG (color type {color}, depth {depth}, "
                       f"interlace {interlace})")
    raw = zlib.decompress(b"".join(idat))
    bpp = channels * depth // 8
    if len(raw) != height * (1 + width * bpp):
        raise PNGError(f"{path}: truncated image data")
    return width, height, bpp, raw


def unfilter(width, height, bpp, raw):
    """Reconstructed scanlines (list of bytes), PNG filter types 0-4."""
    stride = width * bpp
    rows, prev, pos = [], bytes(stride), 0
    for _ in range(height):
        ftype, line = raw[pos], bytearray(raw[pos + 1:pos + 1 + stride])
        pos += 1 + stride
        if ftype == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif ftype == 2:
            line = bytearray((a + b) & 0xFF for a, b in zip(line, prev))
        elif ftype == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 0xFF
        elif ftype != 0:
            raise PNGError(f"bad filter type {ftype}")
        line = bytes(line)
        rows.append(line)
        prev = line
    return rows


def compare(base_path, head_path):
    """None if equal outside the mask, else a one-line reason."""
    bw, bh, bbpp, braw = read_png(base_path)
    hw, hh, hbpp, hraw = read_png(head_path)
    if (bw, bh) != (hw, hh):
        return f"size changed {bw}x{bh} -> {hw}x{hh}"
    skip = mask_rows(hw, hh)
    if bbpp == hbpp and braw == hraw:
        return None  # same pixels everywhere (metadata may differ)
    brows = unfilter(bw, bh, bbpp, braw)
    hrows = unfilter(hw, hh, hbpp, hraw)
    if bbpp != hbpp:
        return f"pixel format changed ({bbpp} -> {hbpp} bytes per pixel)"
    changed = [y for y in range(skip, hh) if brows[y] != hrows[y]]
    if not changed:
        return None
    xs = [x for y in changed for x in range(hw)
          if brows[y][x * hbpp:(x + 1) * hbpp] != hrows[y][x * hbpp:(x + 1) * hbpp]]
    return (f"pixels differ below the {skip}px status-bar mask: rows {changed[0]}-{changed[-1]} "
            f"({len(changed)} rows), columns {min(xs)}-{max(xs)}")


def iphone_shots(directory):
    return sorted(n for n in os.listdir(directory) if n.endswith(".png") and "_iPhone-" in n)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("base")
    ap.add_argument("head")
    ap.add_argument("--report", help="also write the result lines to this file")
    args = ap.parse_args(argv)

    base, head = iphone_shots(args.base), iphone_shots(args.head)
    if not base:
        print(f"error: no iPhone screenshots in {args.base}")
        return 2
    lines, failed = [], 0
    for name in base:
        if name not in head:
            lines.append(f"FAIL {name}: missing in head")
            failed += 1
            continue
        try:
            reason = compare(os.path.join(args.base, name), os.path.join(args.head, name))
        except PNGError as e:
            reason = str(e)
        if reason:
            lines.append(f"FAIL {name}: {reason}")
            failed += 1
        else:
            lines.append(f"ok   {name}")
    for name in head:
        if name not in base:
            lines.append(f"new  {name}: no baseline (added by this change)")
    lines.append(f"{len(base) - failed}/{len(base)} iPhone screenshots unchanged outside the status bar")
    out = "\n".join(lines)
    print(out)
    if args.report:
        with open(args.report, "w") as f:
            f.write(out + "\n")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
