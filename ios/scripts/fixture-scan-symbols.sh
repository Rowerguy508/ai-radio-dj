# Shared nm | swift-demangle helper for the fixture scan.
# Sourced by the bundle and SwiftPM scripts. Does not change shell options.

# Write demangled `nm -a` output for a Mach-O or ELF image to dest.
# Returns 0 on success, 1 when swift demangle is missing or fails,
# 2 when nm cannot read the file.
fixture_nm_demangle() {
  local file=$1 dest=$2 nm_out demangler
  nm_out=$(mktemp)
  if ! nm -a "$file" > "$nm_out" 2>/dev/null; then
    rm -f "$nm_out"
    : > "$dest"
    return 2
  fi
  if [[ ! -s "$nm_out" ]]; then
    rm -f "$nm_out"
    : > "$dest"
    return 0
  fi
  if command -v xcrun >/dev/null 2>&1 && xcrun --find swift-demangle >/dev/null 2>&1; then
    demangler=(xcrun swift-demangle)
  elif command -v swift >/dev/null 2>&1; then
    demangler=(swift demangle)
  else
    rm -f "$nm_out"
    echo "FAIL: swift demangle is required to scan symbols" >&2
    return 1
  fi
  if ! "${demangler[@]}" < "$nm_out" > "$dest"; then
    rm -f "$nm_out"
    return 1
  fi
  rm -f "$nm_out"
  return 0
}
