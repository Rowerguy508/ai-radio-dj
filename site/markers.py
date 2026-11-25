#!/usr/bin/env python3
"""Fail if an [owner] or [PENDING] marker shows on any page.

Scans every .html under site/ (or the files given). Looks at what a reader or a link
preview sees: element text (not tags, comments, <script> or <style>), plus alt, title,
aria-label and placeholder attributes, <title>, and meta description/og/twitter content.
Tags are removed without adding a space, and entities are decoded, so "&#91;owner",
"&lbrack;PENDING" and "[own<b>er" are all caught. Case-insensitive.
Prints file:line: marker for each hit; exits 1 if there are any.
"""
import html, re, sys
from pathlib import Path

MARKER = re.compile(r"\[\s*(owner|pending)\b[^\]]{0,80}\]?", re.I | re.S)
SKIP_BLOCK = re.compile(r"<!--.*?-->|<(script|style)\b.*?</\1\s*>", re.I | re.S)
TAG = re.compile(r"<[^>]*>", re.S)
ATTR = re.compile(r"""\b(alt|title|aria-label|placeholder|content)\s*=\s*("([^"]*)"|'([^']*)')""", re.I)
SHOWN_META = re.compile(r"""<meta\b[^>]*\b(name|property)\s*=\s*["'](description|og:[^"']*|twitter:[^"']*)["']""", re.I)

def visible(src):
    """Return [(text, source_offset_of_each_char)] for visible text and shown attributes."""
    chars, offs = [], []
    i = 0
    for m in re.finditer(SKIP_BLOCK.pattern + "|" + TAG.pattern, src, re.I | re.S):
        for k in range(i, m.start()):
            chars.append(src[k]); offs.append(k)
        tag = m.group(0)
        if not tag.startswith("<!--") and not re.match(r"<(script|style)\b", tag, re.I):
            is_meta = tag.lower().startswith("<meta")
            for a in ATTR.finditer(tag):
                if a.group(1).lower() == "content" and not (is_meta and SHOWN_META.search(tag)):
                    continue
                start = m.start() + a.start(2) + 1
                val = a.group(3) if a.group(3) is not None else a.group(4)
                chars.append("\n"); offs.append(start)          # attribute values stand alone
                for k, ch in enumerate(val):
                    chars.append(ch); offs.append(start + k)
                chars.append("\n"); offs.append(start)
        i = m.end()
    for k in range(i, len(src)):
        chars.append(src[k]); offs.append(k)
    # Decode entities while keeping an offset per decoded char.
    text, toffs, j = [], [], 0
    raw = "".join(chars)
    for m in re.finditer(r"&(#\d+|#x[0-9a-f]+|[a-z][a-z0-9]*);?", raw, re.I):
        for k in range(j, m.start()):
            text.append(raw[k]); toffs.append(offs[k])
        dec = html.unescape(m.group(0))
        for ch in dec:
            text.append(ch); toffs.append(offs[m.start()])
        j = m.end()
    for k in range(j, len(raw)):
        text.append(raw[k]); toffs.append(offs[k])
    return "".join(text), toffs

def scan(path):
    src = path.read_text(encoding="utf-8")
    text, offs = visible(src)
    hits = []
    for m in MARKER.finditer(text):
        line = src.count("\n", 0, offs[m.start()]) + 1
        hits.append((line, " ".join(m.group(0).split())))
    return hits

def main(argv):
    here = Path(__file__).resolve().parent
    files = [Path(a) for a in argv] or sorted(here.rglob("*.html"))
    total = 0
    for f in files:
        for line, marker in scan(f):
            total += 1
            name = f.relative_to(here) if f.is_relative_to(here) else f
            print(f"{name}:{line}: {marker}")
    return 1 if total else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
