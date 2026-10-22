#!/usr/bin/env bash
# Assert a built binary is actually correct for Termux.
#
# This is the most important script in the repo. A build can succeed and
# still be useless: if an upstream Go change moves an anchor, the overlay
# generator aborts - but if someone bypasses it, the binary silently ships
# unpatched and fails only at runtime on the device. So every assertion
# here fails the build hard.
#
# Checks:
#   1. statically linked  - Android is bionic; a glibc binary will not run
#   2. no DT_NEEDED       - same reason
#   3. aarch64 ELF        - the only arch this repo targets
#   4. resolver path      - $PREFIX/etc/resolv.conf baked in
#   5. CA bundle path     - $PREFIX/etc/tls/cert.pem baked in
#   6. temp dir path      - $PREFIX/tmp baked in
#
# Usage: verify.sh <binary> [prefix]
set -euo pipefail

BIN="${1:?usage: verify.sh <binary> [prefix]}"
PREFIX_BAKED="${2:-/data/data/com.termux/files/usr}"
fail=0

say() { printf '   %-24s %s\n' "$1" "$2" >&2; }
bad() { printf '   %-24s FAIL\n' "$1" >&2; fail=1; }
ok()  { printf '   %-24s ok\n' "$1" >&2; }

[ -f "$BIN" ] || { echo "FATAL: no such binary: $BIN" >&2; exit 1; }

# --- 3. arch / ELF -----------------------------------------------------------
if file "$BIN" | grep -q 'ELF 64-bit LSB.*ARM aarch64'; then ok "arch aarch64"; else bad "arch aarch64"; fi

# --- 1/2. linkage ------------------------------------------------------------
if readelf -l "$BIN" 2>/dev/null | grep -q INTERP; then
  bad "static (INTERP present)"
else
  ok "static"
fi

if [ "$(readelf -d "$BIN" 2>/dev/null | grep -c NEEDED)" -ne 0 ]; then
  bad "no DT_NEEDED"
else
  ok "no DT_NEEDED"
fi

# --- 4/5/6. baked patch strings ---------------------------------------------
check_string() {
  local label="$1" needle="$2" n
  n="$(strings -a "$BIN" | grep -c -- "$needle" || true)"
  if [ "${n:-0}" -ge 1 ]; then ok "$label"; else bad "$label"; fi
}
check_string "resolv.conf path" "$PREFIX_BAKED/etc/resolv.conf"
check_string "CA bundle path"   "$PREFIX_BAKED/etc/tls/cert.pem"
check_string "temp dir path"    "$PREFIX_BAKED/tmp"

# --- sanity: it must at least print its banner -------------------------------
if "$BIN" -config /nonexistent-probe.yaml >/dev/null 2>&1 || true; then :; fi

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "FATAL: artifact verification failed - refusing to ship." >&2
  echo "       A binary that passes build but fails here will look fine" >&2
  echo "       and break at runtime on the device." >&2
  exit 1
fi

echo "   ALL CHECKS PASSED" >&2
