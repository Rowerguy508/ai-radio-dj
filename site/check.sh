#!/usr/bin/env bash
# Static checks for site/: every internal link and asset resolves, in-page anchors exist,
# vercel.json parses, no [owner]/[PENDING] marker is visible, and nothing secret-looking is committed. No network, no build.
# Usage: site/check.sh   (from anywhere)
set -euo pipefail
cd "$(dirname "$0")"
fail=0
err() { echo "FAIL: $*"; fail=1; }

# Map a site path (cleanUrls) to a file under site/.
resolve() {
  local p="${1%%[?#]*}"
  [ "$p" = "/" ] && p="/index.html"
  p="${p#/}"
  if [ -f "$p" ]; then echo "$p"; elif [ -f "$p.html" ]; then echo "$p.html"; elif [ -f "$p/index.html" ]; then echo "$p/index.html"; fi
}

links=0
for f in *.html; do
  # href/src/content values that point inside the site.
  while IFS= read -r ref; do
    links=$((links + 1))
    case "$ref" in
      "#") ;;  # placeholder link (App Store TODO), allowed
      "#"*) grep -q "id=\"${ref#\#}\"" "$f" || err "$f: anchor $ref has no target" ;;
      https://onairly.app/*) [ -n "$(resolve "${ref#https://onairly.app}")" ] || err "$f: $ref does not resolve" ;;
      /*) [ -n "$(resolve "$ref")" ] || err "$f: $ref does not resolve" ;;
      http://*) err "$f: insecure link $ref" ;;
      https://*|mailto:*) ;;
      *) [ -e "$ref" ] || err "$f: relative $ref does not resolve" ;;
    esac
  done < <(grep -oE '(href|src)="[^"]*"' "$f" | sed -E 's/^[a-z]+="//; s/"$//')
  grep -q '<html lang="en">' "$f" || err "$f: missing <html lang>"
  grep -q '<meta name="description"' "$f" || err "$f: missing meta description"
  grep -q 'property="og:title"' "$f" || err "$f: missing og:title"
  grep -q '<main id="main"' "$f" || err "$f: missing <main id=main>"
  if grep -oE '<img [^>]*>' "$f" | grep -vq 'alt='; then err "$f: <img> without alt"; fi
done

for css in *.css; do
  while IFS= read -r ref; do
    links=$((links + 1))
    [ -n "$(resolve "$ref")" ] || err "$css: url($ref) does not resolve"
  done < <(grep -oE 'url\("?[^")]+"?\)' "$css" | sed -E 's/^url\("?//; s/"?\)$//')
done

for p in /privacy /support / ; do [ -n "$(resolve "$p")" ] || err "route $p missing"; done
[ -f 404.html ] || err "404.html missing"
python3 -c 'import json,sys; d=json.load(open("vercel.json")); sys.exit(0 if d.get("cleanUrls") is True else 1)' || err "vercel.json invalid or cleanUrls not true"

# privacy.html and support.html must match Sentinel's docs/site/*.md word for word.
python3 render-copy.py --check >/dev/null || err "privacy/support out of date with docs/site/*.md (run site/render-copy.py)"

# No [owner] or [PENDING] marker may show on the live site: visible text and shown attributes
# of every page, case-insensitive, entity-decoded, and across tags (see markers.py).
if ! marker_hits="$(python3 markers.py)"; then
  err "$(printf '%s\n' "$marker_hits" | grep -c .) visible [owner]/[PENDING] marker(s):"; printf '%s\n' "$marker_hits" | sed 's/^/  /'
fi

# The site is live: no page may carry noindex or the old draft banner.
if grep -lE 'name="robots"[^>]*noindex|draft-banner' *.html >/dev/null; then
  err "noindex or draft banner still present in: $(grep -lE 'name="robots"[^>]*noindex|draft-banner' *.html | tr '\n' ' ')"
fi

# Secret-looking strings in text files (fonts and images skipped).
secret_re='(sk-[A-Za-z0-9_-]{16,}|sk_(live|test)_[A-Za-z0-9]{10,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{30,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}|(api[_-]?key|secret|token|password|bearer)["'"'"' ]*[:=]["'"'"' ]*[A-Za-z0-9_\-]{12,})'
if grep -rIniE --exclude=check.sh "$secret_re" . >/dev/null; then
  err "secret-looking string found:"; grep -rIinoE --exclude=check.sh "$secret_re" . | sed -E 's/(:[0-9]+:).{0,6}.*/\1 [redacted match]/'
fi

if [ "$fail" -eq 0 ]; then
  echo "OK: $(ls *.html | wc -l) pages, $links internal/external refs checked, routes /, /privacy, /support and 404 present, vercel.json cleanUrls, privacy/support match docs/site/*.md, no visible [owner]/[PENDING] markers, no noindex or draft banner, no secret-looking strings."
fi
exit "$fail"
