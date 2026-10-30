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
# git calls that take PREV put --end-of-options first (git >= 2.24); an older
# git rejects it, and that error builds.
#
# Anything we can't prove is a no-op fails OPEN (build): PREV unset, not a full
# 40-hex SHA, not in the shallow clone and not fetchable, not an ancestor of
# HEAD (force-push / rewritten history), services/aerodj-tts/vercel.json gone
# from HEAD, or any git error.
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
# Full lowercase 40-hex only. Git never reads a full object name as a ref, so a
# branch or tag named like an abbreviated SHA can't stand in for the commit.
[[ "$prev" =~ ^[0-9a-f]{40}$ ]] || build "VERCEL_GIT_PREVIOUS_SHA is not a full 40-hex commit SHA"

git rev-parse --git-dir >/dev/null 2>&1 || build "not inside a git checkout"
head="$(git rev-parse --verify --quiet 'HEAD^{commit}')" || build "cannot resolve HEAD"

# A pathspec that matches nothing makes git diff return 0 (skip). If the proxy
# folder is ever moved or renamed, build rather than skip forever.
[ -n "$(git ls-tree --name-only "$head" -- ':(top)services/aerodj-tts/vercel.json' 2>/dev/null)" ] \
  || build "services/aerodj-tts/vercel.json is not at HEAD (folder moved?)"

if ! git cat-file -e "${prev}^{commit}" 2>/dev/null; then
  # Vercel clones shallow (--depth=10); PREV may be older than that.
  # git diff only needs the two trees, so fetching that one commit is enough.
  fetch=(git -c protocol.version=2 fetch --quiet --no-tags --depth=1 --end-of-options origin "$prev")
  if command -v timeout >/dev/null 2>&1; then
    fetch=(timeout "$FETCH_TIMEOUT_S" "${fetch[@]}")
  fi
  GIT_TERMINAL_PROMPT=0 "${fetch[@]}" >/dev/null 2>&1 \
    || build "previous deploy ${prev:0:12} is not in the clone and fetching it failed"
  git cat-file -e "${prev}^{commit}" 2>/dev/null \
    || build "previous deploy ${prev:0:12} is still missing after fetch"
fi

# PREV must be in HEAD's history. If it isn't (force-push, rewritten or orphan
# history) the deployed code may not be what this diff assumes, so build.
# A shallow clone can't show ancestry across its boundary: deepen once, then
# re-check; still unproven => build.
prev="$(git rev-parse --verify --quiet "${prev}^{commit}")" || build "cannot resolve previous deploy as a commit"
if ! git merge-base --is-ancestor --end-of-options "$prev" "$head" 2>/dev/null; then
  if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
    deepen=(git -c protocol.version=2 fetch --quiet --no-tags --unshallow --end-of-options origin "$head")
    if command -v timeout >/dev/null 2>&1; then
      deepen=(timeout "$FETCH_TIMEOUT_S" "${deepen[@]}")
    fi
    GIT_TERMINAL_PROMPT=0 "${deepen[@]}" >/dev/null 2>&1 || true
  fi
  git merge-base --is-ancestor --end-of-options "$prev" "$head" 2>/dev/null \
    || build "previous deploy ${prev:0:12} is not an ancestor of HEAD (force-push or rewritten history)"
fi

git diff --quiet --end-of-options "$prev" "$head" -- "${WATCH_PATHS[@]}" 2>/dev/null
rc=$?
case "$rc" in
  0) skip "no changes under services/aerodj-tts/ since last deploy ${prev:0:12}" ;;
  1) build "services/aerodj-tts/ changed since last deploy ${prev:0:12}" ;;
  *) build "git diff failed (exit $rc)" ;;
esac
