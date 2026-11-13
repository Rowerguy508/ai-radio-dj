#!/usr/bin/env bash
# Shared path and name rules for the self-hosted Mac CI scripts.
# Sourced, not executed.
#
# claudio-mini and claudio-mini-2 are two runners, one macOS user. Isolation is
# the sanitized runner name under a single directory prefix, not a separate
# account. Nothing here reads or writes a job token, keychain item, or other
# credential. The only files under the prefix are DerivedData, the walkthrough
# video, and non-secret state (simulator UDIDs and process ids). -Fry

# One fixed prefix. ci_rm_rf_under is the only recursive delete, and it refuses
# a target that does not start with this prefix after symlink resolution.
ci_fixed_prefix() {
  printf '%s/ci-host' "${HOME:?HOME must be set}"
}

# Replace every byte outside [A-Za-z0-9_-] with '_', so the result is one
# path component. Slash, space, and dot cannot survive.
ci_sanitize() {
  LC_ALL=C printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9_-' '_'
}

ci_assert_token() {
  case "$2" in
    ''|*[!A-Za-z0-9_-]*)
      echo "::error::$1 is empty or not safe as a path component" >&2
      return 1
      ;;
  esac
}

ci_runner() {
  if [ -z "${RUNNER_NAME:-}" ]; then
    echo "::error::RUNNER_NAME is empty. Self-hosted CI will not share DerivedData, recordings, or simulators between runners on this Mac." >&2
    return 1
  fi
  local sanitized
  sanitized=$(ci_sanitize "$RUNNER_NAME") || return 1
  ci_assert_token "RUNNER_NAME" "$sanitized" || return 1
  printf '%s' "$sanitized"
}

ci_job() {
  local sanitized
  sanitized=$(ci_sanitize "$1") || return 1
  ci_assert_token "JOB" "$sanitized" || return 1
  printf '%s' "$sanitized"
}

# role is dd (DerivedData) or rec (recordings and non-secret job state).
ci_role_root() {
  local prefix
  prefix=$(ci_fixed_prefix)
  case "$1" in
    dd) printf '%s/ci-dd' "$prefix" ;;
    rec) printf '%s/ci-rec' "$prefix" ;;
    *)
      echo "::error::unknown CI directory role: $1" >&2
      return 1
      ;;
  esac
}

ci_runner_root() {
  local role_root
  role_root=$(ci_role_root "$1") || return 1
  ci_assert_token "RUNNER_NAME" "$2" || return 1
  printf '%s/%s' "$role_root" "$2"
}

ci_job_dir() {
  local runner_root
  runner_root=$(ci_runner_root "$1" "$2") || return 1
  ci_assert_token "JOB" "$3" || return 1
  printf '%s/%s' "$runner_root" "$3"
}

# ci-$runner-$run-$attempt-$job-phone|pad
# Attempt and job keep two jobs of one run from sharing a name when they use
# the same runner one after the other. Cleanup does not look this name up;
# it deletes the UDID simctl clone printed.
ci_clone_name() {
  local runner run_id attempt job role
  runner=$(ci_sanitize "$1") || return 1
  run_id=$(ci_sanitize "$2") || return 1
  attempt=$(ci_sanitize "$3") || return 1
  job=$(ci_sanitize "$4") || return 1
  role=$(ci_sanitize "$5") || return 1
  ci_assert_token "RUNNER_NAME" "$runner" || return 1
  ci_assert_token "GITHUB_RUN_ID" "$run_id" || return 1
  ci_assert_token "GITHUB_RUN_ATTEMPT" "$attempt" || return 1
  ci_assert_token "JOB" "$job" || return 1
  case "$role" in
    phone|pad) ;;
    *)
      echo "::error::simulator role must be phone or pad" >&2
      return 1
      ;;
  esac
  printf 'ci-%s-%s-%s-%s-%s' "$runner" "$run_id" "$attempt" "$job" "$role"
}

ci_canon_dir() {
  (CDPATH='' cd -- "$1" && pwd -P)
}

# Delete $3 only when it is strictly inside this runner's dd or rec directory,
# and that directory is inside the fixed prefix. The prefix is computed from
# the role and the sanitized runner; the caller does not supply it.
ci_rm_rf_under() {
  local role=$1 runner=$2 target=$3
  local fixed prefix canon_fixed canon_prefix home_canon parent base canon_target
  ci_assert_token "RUNNER_NAME" "$runner" || return 1
  fixed=$(ci_fixed_prefix)
  prefix=$(ci_runner_root "$role" "$runner") || return 1
  case "$target" in
    "$prefix"/*) ;;
    *)
      echo "::error::refusing to delete $target; it does not start with $prefix/" >&2
      return 1
      ;;
  esac
  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    return 0
  fi
  if [ ! -d "$fixed" ] || [ ! -d "$prefix" ]; then
    echo "::error::refusing to delete; fixed prefix is missing: $prefix" >&2
    return 1
  fi
  canon_fixed=$(ci_canon_dir "$fixed") || return 1
  canon_prefix=$(ci_canon_dir "$prefix") || return 1
  home_canon=$(ci_canon_dir "$HOME") || return 1
  case "$canon_fixed" in
    "$home_canon"/ci-host) ;;
    *)
      echo "::error::refusing to delete; fixed prefix resolved to $canon_fixed" >&2
      return 1
      ;;
  esac
  case "$canon_prefix" in
    "$canon_fixed"/ci-dd/"$runner"|"$canon_fixed"/ci-rec/"$runner") ;;
    *)
      echo "::error::refusing to delete; runner prefix resolved to $canon_prefix" >&2
      return 1
      ;;
  esac
  parent=$(dirname -- "$target")
  base=$(basename -- "$target")
  case "$base" in
    ''|.|..)
      echo "::error::refusing to delete $target" >&2
      return 1
      ;;
  esac
  canon_target="$(ci_canon_dir "$parent")/$base" || return 1
  case "$canon_target" in
    "$canon_fixed"/*) ;;
    *)
      echo "::error::refusing to delete $canon_target; it does not start with $canon_fixed/" >&2
      return 1
      ;;
  esac
  case "$canon_target" in
    "$canon_prefix"/*) ;;
    *)
      echo "::error::refusing to delete $canon_target; it does not start with $canon_prefix/" >&2
      return 1
      ;;
  esac
  rm -rf -- "$canon_target"
}

# Direct children of this runner's directory, older than a day. No job runs
# that long. Other runners are outside the prefix this passes to ci_rm_rf_under.
ci_sweep_stale() {
  local role=$1 runner=$2
  local prefix old
  ci_assert_token "RUNNER_NAME" "$runner" || return 1
  prefix=$(ci_runner_root "$role" "$runner") || return 1
  [ -d "$prefix" ] || return 0
  while IFS= read -r old; do
    [ -n "$old" ] || continue
    ci_rm_rf_under "$role" "$runner" "$old" || return 1
  done < <(find -P "$prefix" -mindepth 1 -maxdepth 1 -mmin +1440 -print)
}
