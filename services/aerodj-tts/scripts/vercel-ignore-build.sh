#!/usr/bin/env bash
# Vercel "Ignored Build Step" for the aerodj-tts project (wired via
# ignoreCommand in ../vercel.json, which overrides the dashboard setting).
#
# Exit 0 = skip the build, exit 1 = build.
#
# Compares the commit being deployed against VERCEL_GIT_PREVIOUS_SHA, the SHA
# of the last successful deployment for this project and branch, so a push
# whose tip commit doesn't touch the proxy still builds when an earlier commit
# in the same push did (the 6307545 miss: its first parent 96aa006 changed
# the proxy, the tip only touched ray-do, and `HEAD^ HEAD` skipped Production).
#
# Anything we can't prove is a no-op fails OPEN (build): PREV unset, malformed,
# not in the shallow clone and not fetchable, or any git error.
#
# Vercel runs this from the project's Root Directory (services/aerodj-tts).
# The proxy is self-contained (own package.json, lockfile, tsconfig and
# vercel.json; nothing imports from outside it), so that folder is the only
# path its build depends on. ":(top)" makes the pathspec independent of cwd.
set -u

WATCH_PATHS=(":(top)services/aerodj-tts/")
FETCH_TIMEOUT_S="${IGNORE_BUILD_FETCH_TIMEOUT_S:-20}"

log() { echo "vercel-ignore-build: $*"; }
build() { log "BUILD - $1"; exit 1; }
skip() { log "SKIP - $1"; exit 0; }

prev="${VERCEL_GIT_PREVIOUS_SHA:-}"
[ -n "$prev" ] || build "VERCEL_GIT_PREVIOUS_SHA is unset (first deploy on this branch?)"
[[ "$prev" =~ ^[0-9a-fA-F]{7,64}$ ]] || build "VERCEL_GIT_PREVIOUS_SHA is not a commit SHA"

git rev-parse --git-dir >/dev/null 2>&1 || build "not inside a git checkout"
head="$(git rev-parse --verify --quiet 'HEAD^{commit}')" || build "cannot resolve HEAD"

if ! git cat-file -e "${prev}^{commit}" 2>/dev/null; then
  # Vercel clones shallow (--depth=10); PREV may be older than that.
  # git diff only needs the two trees, so fetching that one commit is enough.
  fetch=(git -c protocol.version=2 fetch --quiet --no-tags --depth=1 origin "$prev")
  if command -v timeout >/dev/null 2>&1; then
    fetch=(timeout "$FETCH_TIMEOUT_S" "${fetch[@]}")
  fi
  GIT_TERMINAL_PROMPT=0 "${fetch[@]}" >/dev/null 2>&1 \
    || build "previous deploy ${prev:0:12} is not in the clone and fetching it failed"
  git cat-file -e "${prev}^{commit}" 2>/dev/null \
    || build "previous deploy ${prev:0:12} is still missing after fetch"
fi

git diff --quiet "$prev" "$head" -- "${WATCH_PATHS[@]}" 2>/dev/null
rc=$?
case "$rc" in
  0) skip "no changes under services/aerodj-tts/ since last deploy ${prev:0:12}" ;;
  1) build "services/aerodj-tts/ changed since last deploy ${prev:0:12}" ;;
  *) build "git diff failed (exit $rc)" ;;
esac
