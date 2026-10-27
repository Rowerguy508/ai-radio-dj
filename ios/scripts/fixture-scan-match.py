#!/usr/bin/env python3
"""Print denylist tokens found in a linked image.

Inputs, in order:
  1. Raw bytes of the file. A token immediately preceded by "/" and
     immediately followed by ".swift" is a source path and is exempt.
  2. Optional label (a bundle-relative path), scanned with the same
     path exemption.
  3. Optional demangled symbol text (nm piped through swift demangle).
     Any occurrence fails. The path exemption does not apply here.

The denylist is one literal token per line. Blank lines and lines whose
first non-whitespace character is "#" are ignored.

Usage: fixture-scan-match.py <denylist> <file> [label] [demangled]
Prints one disallowed token per line. Exits 0 even when tokens match.
"""

import sys
from pathlib import Path


def load_tokens(path: Path) -> list[str]:
    tokens = []
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        tokens.append(stripped)
    return tokens


def has_disallowed_raw_match(data: bytes, token: str) -> bool:
    """True when token occurs other than as '/<token>.swift'."""
    needle = token.encode("utf-8")
    if not needle:
        return False
    suffix = b".swift"
    start = 0
    while True:
        index = data.find(needle, start)
        if index < 0:
            return False
        previous = data[index - 1 : index] if index else b""
        following = data[index + len(needle) : index + len(needle) + len(suffix)]
        if not (previous == b"/" and following == suffix):
            return True
        start = index + 1


def has_any_match(data: bytes, token: str) -> bool:
    needle = token.encode("utf-8")
    return bool(needle) and data.find(needle) >= 0


def main(argv: list[str]) -> int:
    if len(argv) not in (3, 4, 5):
        sys.stderr.write(
            "usage: fixture-scan-match.py <denylist> <file> [label] [demangled]\n"
        )
        return 2
    raw = Path(argv[2]).read_bytes()
    label = argv[3].encode("utf-8") if len(argv) >= 4 else None
    demangled = Path(argv[4]).read_bytes() if len(argv) == 5 else None
    for token in load_tokens(Path(argv[1])):
        hit = has_disallowed_raw_match(raw, token)
        if label is not None:
            hit = hit or has_disallowed_raw_match(label, token)
        if demangled is not None:
            hit = hit or has_any_match(demangled, token)
        if hit:
            print(token)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
