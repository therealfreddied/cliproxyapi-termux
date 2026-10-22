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
#   7. build version      - the expected tag must be grafted in by -X
#
# Check 7 exists because a build once shipped with `Version: dev`: the
# ldflags -X was emitted conditionally, so it silently never applied. The
# binary worked perfectly but the launcher could not tell what version it
# was, which breaks update detection and rollback. Never again.
#
# Check 7 is a STATIC string check, not an execution. CI runs on x86_64 and
# cannot execute an aarch64 binary (exec format error), so running the
# artifact to read its banner would fail the build for the wrong reason.
# `-X main.Version=` embeds the value in the binary, so its literal
# presence is proof the flag applied.
#
# NO PIPELINES INTO `grep -q`. `grep -q` exits at the first match, the
# writer dies of SIGPIPE, and with `set -o pipefail` the pipeline reports
# failure even though the match succeeded. That produced a false FAIL on a
# known-good binary, and worse, false PASSES on the inverted checks
# (`... | grep -q X && die` silently stops firing). Every check below
# therefore captures output first and matches with `case`, or greps a
# regular file.
#
# Usage: verify.sh <binary> [prefix] [expected-version]
set -uo pipefail

BIN="${1:?usage: verify.sh <binary> [prefix] [expected-version]}"
PREFIX_BAKED="${2:-/data/data/com.termux/files/usr}"
EXPECTED_VER="${3:-}"
fail=0

bad() { printf '   %-30s FAIL\n' "$1" >&2; fail=1; }
ok()  { printf '   %-30s ok\n' "$1" >&2; }

[ -f "$BIN" ] || { echo "FATAL: no such binary: $BIN" >&2; exit 1; }

# Capture once; reused by several checks.
FILE_OUT="$(file "$BIN" 2>/dev/null || true)"
PROG_OUT="$(readelf -l "$BIN" 2>/dev/null || true)"
DYN_OUT="$(readelf -d "$BIN" 2>/dev/null || true)"
STR_OUT="$(strings -a "$BIN" 2>/dev/null || true)"

# --- 3. arch / ELF -----------------------------------------------------------
case "$FILE_OUT" in
  *"ELF 64-bit LSB"*"ARM aarch64"*) ok "arch aarch64" ;;
  *) bad "arch aarch64"; printf '      got: %s\n' "${FILE_OUT:-<none>}" >&2 ;;
esac

# --- 1. static (no interpreter) ---------------------------------------------
case "$PROG_OUT" in
  *INTERP*) bad "static (INTERP present)" ;;
  "")       bad "static (unreadable ELF)" ;;
  *)        ok "static" ;;
esac

# --- 2. no dynamic deps ------------------------------------------------------
case "$DYN_OUT" in
  *NEEDED*) bad "no DT_NEEDED" ;;
  *)        ok "no DT_NEEDED" ;;
esac

# --- 4/5/6. baked patch strings ---------------------------------------------
check_string() {
  local label="$1" needle="$2"
  case "$STR_OUT" in
    *"$needle"*) ok "$label" ;;
    *)           bad "$label" ;;
  esac
}
check_string "resolv.conf path" "$PREFIX_BAKED/etc/resolv.conf"
check_string "CA bundle path"   "$PREFIX_BAKED/etc/tls/cert.pem"
check_string "temp dir path"    "$PREFIX_BAKED/tmp"

# --- 7. build version (static check, no execution) ---------------------------
if [ -n "$EXPECTED_VER" ]; then
  case "$STR_OUT" in
    *"$EXPECTED_VER"*) ok "build version ($EXPECTED_VER)" ;;
    *)
      bad "build version ($EXPECTED_VER)"
      printf '      version literal absent - the -X ldflag did not apply.\n' >&2
      printf '      Go would default this to "dev" and break update detection.\n' >&2
      ;;
  esac
else
  case "$STR_OUT" in
    *"Version: dev"*) bad "build version (defaulted to dev)" ;;
    *)                ok "build version (unchecked)" ;;
  esac
fi

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "FATAL: artifact verification failed - refusing to ship." >&2
  echo "       A binary that passes build but fails here will look fine" >&2
  echo "       and break at runtime on the device." >&2
  exit 1
fi

echo "   ALL CHECKS PASSED" >&2
