#!/usr/bin/env python3
"""Tests for compare-iphone-screenshots.py (Linux or macOS, standard library only).

The key cases: a change inside the status-bar mask is ignored, a change on the
first row below it fails. Images are written with every PNG filter type, because
a masked row changes the *filtered* bytes of the row under it (Up, Average, Paeth).
"""
import importlib.util
import os
import struct
import subprocess
import sys
import tempfile
import zlib

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "compare-iphone-screenshots.py")
spec = importlib.util.spec_from_file_location("cmp", SCRIPT)
cmp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cmp)


def pixel(x, y):
    return ((x * 7 + y * 3) & 0xFF, (x * 13) & 0xFF, (y * 5) & 0xFF)


def make(w, h):
    return [bytearray(b for x in range(w) for b in pixel(x, y)) for y in range(h)]


def filtered(row, prev, ftype, bpp=3):
    out = bytearray(len(row))
    for i, v in enumerate(row):
        a = row[i - bpp] if i >= bpp else 0
        b = prev[i]
        c = prev[i - bpp] if i >= bpp else 0
        if ftype == 0:
            pred = 0
        elif ftype == 1:
            pred = a
        elif ftype == 2:
            pred = b
        elif ftype == 3:
            pred = (a + b) >> 1
        else:
            p = a + b - c
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
        out[i] = (v - pred) & 0xFF
    return bytes([ftype]) + bytes(out)


def write_png(path, rows, ftype, extra_chunk=b""):
    h, w = len(rows), len(rows[0]) // 3

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

    if ftype == 0:
        raw = b"".join(b"\x00" + bytes(r) for r in rows)
    else:
        prev, parts = bytes(len(rows[0])), []
        for r in rows:
            parts.append(filtered(r, prev, ftype))
            prev = r
        raw = b"".join(parts)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)))
        if extra_chunk:
            f.write(chunk(b"tEXt", extra_chunk))
        f.write(chunk(b"IDAT", zlib.compress(raw)))
        f.write(chunk(b"IEND", b""))


def poke(rows, y, x=5):
    rows = [bytearray(r) for r in rows]
    rows[y][x * 3] ^= 0xFF
    return rows


FAILURES = []


def check(label, got, want):
    status = "ok  " if got == want else "FAIL"
    print(f"{status} {label}: got {got!r}, want {want!r}")
    if got != want:
        FAILURES.append(label)


def run(base_rows, head_rows, name, ftype=0, head_ftype=None, head_extra=b"", drop_head=False):
    with tempfile.TemporaryDirectory() as tmp:
        base, head = os.path.join(tmp, "base"), os.path.join(tmp, "head")
        os.makedirs(base)
        os.makedirs(head)
        write_png(os.path.join(base, name), base_rows, ftype)
        if not drop_head:
            write_png(os.path.join(head, name), head_rows,
                      ftype if head_ftype is None else head_ftype, head_extra)
        # An iPad shot is never compared, even when it changes.
        write_png(os.path.join(base, "open-studio_iPad-Air.png"), make(4, 4), 0)
        write_png(os.path.join(head, "open-studio_iPad-Air.png"), poke(make(4, 4), 0, 0), 0)
        with open(os.devnull, "w") as quiet:
            return subprocess.call([sys.executable, SCRIPT, base, head], stdout=quiet)


def main():
    # Real CI device: iPhone 16e, 1170x2532 @3x, safe-area top 47 pt -> 141 rows.
    check("16e mask is 47pt x 3", cmp.mask_rows(1170, 2532), 141)
    check("17 Pro mask is 62pt x 3", cmp.mask_rows(1206, 2622), 186)
    check("SE mask is 20pt x 2", cmp.mask_rows(750, 1334), 40)
    check("landscape iPhone has no mask", cmp.mask_rows(2532, 1170), 0)

    w, h = 1170, 2532
    base = make(w, h)
    name = "closed-compact_iPhone-16e.png"
    check("16e identical", run(base, base, name), 0)
    check("16e metadata-only change passes", run(base, base, name, head_extra=b"Comment\x00x"), 0)
    check("16e change on row 0 (status bar) ignored", run(base, poke(base, 0), name), 0)
    check("16e change on last masked row 140 ignored", run(base, poke(base, 140), name), 0)
    check("16e change on row 141, just below the mask, fails", run(base, poke(base, 141), name), 1)
    check("16e change on last row fails", run(base, poke(base, h - 1, w - 1), name), 1)
    check("16e same pixels, different filter, passes", run(base, base, name, ftype=0, head_ftype=2), 0)
    check("16e Paeth: change on row 140 ignored", run(base, poke(base, 140), name, ftype=4), 0)
    check("16e Paeth: change on row 141 fails", run(base, poke(base, 141), name, ftype=4), 1)
    check("missing head shot fails", run(base, base, name, drop_head=True), 1)

    land = make(h, w)
    lname = "iphone-landscape_iPhone-16e.png"
    check("landscape change on row 0 fails", run(land, poke(land, 0), lname), 1)
    check("size change fails", run(base, land, name), 1)

    # Every filter type, in-process, at a small size registered for the test only
    # (mask = 3 x 5 = 15 rows), so the matrix stays fast in pure Python.
    tiny = make(30, 60)
    tname = "tiny_iPhone-Test.png"
    cmp.STATUS_BAR_STRIP[(30, 60)] = (3, 5)
    with tempfile.TemporaryDirectory() as tmp:
        b, hd = os.path.join(tmp, "b.png"), os.path.join(tmp, "h.png")
        for ftype in range(5):
            write_png(b, tiny, ftype)
            write_png(hd, poke(tiny, 14, 9), ftype)
            check(f"filter {ftype}: row 14 ignored", cmp.compare(b, hd), None)
            write_png(hd, poke(tiny, 15, 9), ftype)
            check(f"filter {ftype}: row 15 fails", cmp.compare(b, hd),
                  "pixels differ below the 15px status-bar mask: rows 15-15 (1 rows), columns 9-9")
        # A shorter head whose remaining rows all match must still fail on size.
        cmp.STATUS_BAR_STRIP[(30, 59)] = (3, 5)
        write_png(b, tiny, 0)
        write_png(hd, tiny[:-1], 0)
        check("cropped head fails on size", cmp.compare(b, hd), "size changed 30x60 -> 30x59")
        del cmp.STATUS_BAR_STRIP[(30, 59)]
    del cmp.STATUS_BAR_STRIP[(30, 60)]
    check("unknown size fails", run(tiny, tiny, tname), 1)

    if FAILURES:
        print(f"{len(FAILURES)} failed: {FAILURES}")
        return 1
    print("all compare-iphone-screenshots tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
