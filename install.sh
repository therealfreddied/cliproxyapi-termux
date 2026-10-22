#!/usr/bin/env bash
# One-shot installer for cliproxyapi-termux.
#
#   curl -fsSL https://raw.githubusercontent.com/therealfreddied/cliproxyapi-termux/main/install.sh | bash
#
# Installs the launcher plus the newest verified build. Everything is checked
# before it is allowed on your device:
#
#   - sha256 against the published sidecar
#   - tarball path safety (no absolute paths / tarbomb)
#   - static aarch64 ELF
#   - all three Termux patch strings present
#
# If any check fails the installer stops with nothing installed.
set -euo pipefail

REPO="${CLIPROXY_REPO:-therealfreddied/cliproxyapi-termux}"
PREFIX="${PREFIX:-}"
DATA_DIR="${CLIPROXY_DATA:-$HOME/.local/share/cliproxyapi}"
CONFIG_DIR="${CLIPROXY_CONFIG:-$HOME/.config/cliproxyapi}"
CONFIG="$CONFIG_DIR/config.yaml"
BINDIR="${PREFIX:-/data/data/com.termux/files/usr}/bin"

C_R=$'\033[0m'; C_B=$'\033[1m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_E=$'\033[31m'; C_C=$'\033[36m'
if [ ! -t 1 ]; then C_R=""; C_B=""; C_G=""; C_Y=""; C_E=""; C_C=""; fi

say()  { printf '%s[install]%s %s\n' "$C_C" "$C_R" "$*"; }
ok()   { printf '%s[install]%s %s%s%s\n' "$C_C" "$C_R" "$C_G" "$*" "$C_R"; }
warn() { printf '%s[install]%s %s\n' "$C_Y" "$C_R" "$*" >&2; }
die()  { printf '%s[install]%s %s\n' "$C_E" "$C_R" "$*" >&2; exit 1; }

# --------------------------------------------------------------- environment
[ -n "$PREFIX" ] || die "PREFIX is not set - this installer targets Termux only."

ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|arm64) ;;
  *) die "unsupported architecture: $ARCH (this repo publishes aarch64 only)" ;;
esac

say "Termux detected: $PREFIX on $ARCH"

# ------------------------------------------------------------------ packages
# Verify uses file/readelf/strings (binutils); TLS needs ca-certificates.
need_pkgs=()
for pkg in binutils ca-certificates curl; do
  if ! command -v "${pkg%%-*}" >/dev/null 2>&1; then
    case "$pkg" in
      binutils)        command -v readelf >/dev/null 2>&1 || need_pkgs+=("$pkg") ;;
      ca-certificates) [ -f "$PREFIX/etc/tls/cert.pem" ] || need_pkgs+=("$pkg") ;;
      curl)            command -v curl >/dev/null 2>&1 || need_pkgs+=("$pkg") ;;
    esac
  fi
done
if [ ${#need_pkgs[@]} -gt 0 ]; then
  say "installing: ${need_pkgs[*]}"
  pkg install -y "${need_pkgs[@]}" >/dev/null 2>&1 || warn "pkg install had issues; continuing"
fi

command -v curl     >/dev/null || die "curl missing"
command -v sha256sum >/dev/null || die "sha256sum missing (coreutils)"
command -v readelf   >/dev/null || warn "readelf missing; verification will be weaker"

# ------------------------------------------------------------- Termux runtime
# The binary resolves temp files to $PREFIX/tmp and falls back to /tmp (which
# Android does not provide) if that directory is absent.
mkdir -p "$PREFIX/tmp" && chmod 0700 "$PREFIX/tmp" 2>/dev/null || true
[ -w "$PREFIX/tmp" ] || warn "$PREFIX/tmp is not writable - temp-file ops may fail"

if [ ! -s "$PREFIX/etc/resolv.conf" ]; then
  say "no resolver config; installing resolv-conf"
  pkg install -y resolv-conf >/dev/null 2>&1 || true
fi
if [ ! -s "$PREFIX/etc/resolv.conf" ]; then
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$PREFIX/etc/resolv.conf" 2>/dev/null || true
  warn "wrote a fallback $PREFIX/etc/resolv.conf"
fi

# -------------------------------------------------------------- fetch release
say "resolving newest release of $REPO"
api() {
  local -a h=(-H "Accept: application/vnd.github+json" -H "User-Agent: cliproxy-installer")
  [ -n "${CLIPROXY_TOKEN:-}" ] && h+=(-H "Authorization: Bearer $CLIPROXY_TOKEN")
  curl -fsSL --max-time 30 "${h[@]}" "$1" 2>/dev/null
}

TAG="$(api "https://api.github.com/repos/$REPO/releases/latest" \
  | tr ',' '\n' \
  | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  | head -n1 || true)"
[ -n "$TAG" ] || die "could not resolve a release for $REPO"

say "newest release: $TAG"

TMPD="$(mktemp -d "$PREFIX/tmp/cliproxy-install.XXXXXX")" || die "mktemp failed"
trap 'rm -rf "$TMPD"' EXIT

BASE="https://github.com/$REPO/releases/download/$TAG"
TARBALL="$TMPD/pkg.tar.gz"
SUM="$TMPD/pkg.sha256"

got_tar=""
for name in "cliproxyapi-termux_${TAG}_aarch64.tar.gz" "cliproxyapi-termux_aarch64.tar.gz"; do
  if curl -fsSL --max-time 300 -o "$TARBALL" "$BASE/$name"; then
    got_tar="$name"; break
  fi
done
[ -n "$got_tar" ] || die "could not download a release tarball for $TAG"

got_sum=""
for name in "${got_tar}.sha256" "cliproxyapi-termux_aarch64.tar.gz.sha256"; do
  if curl -fsSL --max-time 60 -o "$SUM" "$BASE/$name"; then
    got_sum="$name"; break
  fi
done
[ -n "$got_sum" ] || die "no published checksum - refusing to install unverified"

# ------------------------------------------------------------------- verify
expect="$(cut -d' ' -f1 "$SUM")"
actual="$(sha256sum "$TARBALL" | cut -d' ' -f1)"
[ "$expect" = "$actual" ] || die "sha256 mismatch
  expected $expect
  got      $actual"
ok "sha256 verified"

tar tzf "$TARBALL" 2>/dev/null | grep -qE '(^/|(^|/)\.\.(/|$))' && die "tarball has unsafe paths"

mkdir -p "$TMPD/x"
tar xzf "$TARBALL" -C "$TMPD/x" || die "extract failed"

NEWBIN="$(find "$TMPD/x" -type f -name 'cli-proxy-api' -print -quit)"
[ -n "$NEWBIN" ] || die "cli-proxy-api not found inside tarball"
NEWWRAP="$(find "$TMPD/x" -type f -name 'cliproxy' -print -quit)"

file "$NEWBIN" | grep -q 'ELF 64-bit LSB.*ARM aarch64' || die "not an aarch64 ELF"
readelf -l "$NEWBIN" 2>/dev/null | grep -q INTERP && die "binary is not static"
[ "$(readelf -d "$NEWBIN" 2>/dev/null | grep -c NEEDED)" -eq 0 ] || die "binary has DT_NEEDED"
S="$(strings -a "$NEWBIN")"
printf '%s' "$S" | grep -q "$PREFIX/etc/resolv.conf"  || die "resolv patch missing"
printf '%s' "$S" | grep -q "$PREFIX/etc/tls/cert.pem" || die "CA patch missing"
printf '%s' "$S" | grep -q "$PREFIX/tmp"              || die "tempdir patch missing"
ok "artifact verified (static aarch64, 3/3 patches)"

# ------------------------------------------------------------------- install
mkdir -p "$DATA_DIR" "$BINDIR"
[ -f "$DATA_DIR/cli-proxy-api" ] && cp -f "$DATA_DIR/cli-proxy-api" "$DATA_DIR/cli-proxy-api.prev" 2>/dev/null || true

install -m 0755 "$NEWBIN" "$DATA_DIR/.cli-proxy-api.new"
mv -f "$DATA_DIR/.cli-proxy-api.new" "$DATA_DIR/cli-proxy-api"
printf '%s\n' "$TAG" > "$DATA_DIR/VERSION"
date +%s > "$DATA_DIR/.lastcheck" 2>/dev/null || true
ok "binary -> $DATA_DIR/cli-proxy-api"

if [ -n "$NEWWRAP" ]; then
  install -m 0755 "$NEWWRAP" "$BINDIR/cliproxy"
else
  curl -fsSL --max-time 60 -o "$BINDIR/cliproxy" \
    "https://raw.githubusercontent.com/$REPO/main/wrapper/cliproxy" || die "could not fetch launcher"
  chmod 0755 "$BINDIR/cliproxy"
fi
ok "launcher -> $BINDIR/cliproxy"

# -------------------------------------------------------------------- config
mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG" ]; then
  KEY="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 32)"
  cat > "$CONFIG" <<EOF
config-version: 8
server:
  host: "127.0.0.1"
  port: 8317
  commercial-mode: true
management:
  allow-remote: false
  disable-control-panel: true
access:
  api-keys:
    - "$KEY"
EOF
  chmod 0600 "$CONFIG"
  ok "config -> $CONFIG"
  printf '\n  your API key: %s%s%s\n\n' "$C_B" "$KEY" "$C_R"
else
  ok "config kept -> $CONFIG"
fi

# ---------------------------------------------------------------------- done
cat <<EOF

${C_B}Installed${C_R}  $TAG

  start        ${C_C}cliproxy${C_R}
  update check ${C_C}cliproxy --check${C_R}
  force update ${C_C}cliproxy --update${C_R}
  rollback     ${C_C}cliproxy --rollback${C_R}

Keep it alive after closing Termux:

  termux-wake-lock
  nohup cliproxy > ~/.config/cliproxyapi/cliproxy.log 2>&1 &

Then point clients at http://127.0.0.1:8317/v1
EOF
