#!/usr/bin/env python3
"""Print denylist tokens that appear in a file other than as a source path.

A match is exempt only when the token is immediately preceded by "/" and
immediately followed by ".swift". Every other occurrence is reported.
The denylist is one literal token per line. Blank lines and lines whose
first non-whitespace character is "#" are ignored.

Usage: fixture-scan-match.py <denylist> <file> [label]
Also scans label, when given, with the same rule (a bundle-relative path).
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


def has_disallowed_match(data: bytes, token: str) -> bool:
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


def main(argv: list[str]) -> int:
    if len(argv) not in (3, 4):
        sys.stderr.write("usage: fixture-scan-match.py <denylist> <file> [label]\n")
        return 2
    denylist = Path(argv[1])
    target = Path(argv[2])
    blobs = [target.read_bytes()]
    if len(argv) == 4:
        blobs.append(argv[3].encode("utf-8"))
    for token in load_tokens(denylist):
        if any(has_disallowed_match(blob, token) for blob in blobs):
            print(token)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
