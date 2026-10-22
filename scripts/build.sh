#!/usr/bin/env bash
# Build a Termux-native CLIProxyAPI from upstream source with the three
# stdlib patches applied via `go build -overlay`.
#
# Works identically on a CI runner and on the device. Nothing in here
# mutates GOROOT, so an interrupted build cannot corrupt the toolchain.
#
# Usage: build.sh [upstream-ref]      (default: latest release tag)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/router-for-me/CLIProxyAPI.git}"
UPSTREAM_REF="${1:-}"
WORKDIR="${WORKDIR:-$PWD/.work}"
DIST="${DIST:-$REPO_ROOT/dist}"
PREFIX_BAKED="${PREFIX_BAKED:-/data/data/com.termux/files/usr}"
GOARM64_LEVEL="${GOARM64_LEVEL:-v9.0,lse,crypto}"

log() { printf '>> %s\n' "$*" >&2; }

# ---------------------------------------------------------------- resolve ref
if [ -z "$UPSTREAM_REF" ]; then
  log "resolving latest upstream release tag"
  UPSTREAM_REF="$(
    curl -fsSL --max-time 30 https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])'
  )"
fi
[ -n "$UPSTREAM_REF" ] || { echo "FATAL: could not resolve upstream ref" >&2; exit 1; }
log "upstream ref: $UPSTREAM_REF"

# ------------------------------------------------------------------- checkout
mkdir -p "$WORKDIR"
SRC="$WORKDIR/src"
if [ -d "$SRC/.git" ]; then
  log "reusing existing checkout"
  git -C "$SRC" fetch --tags --force --depth 1 origin "$UPSTREAM_REF" >/dev/null 2>&1 || true
else
  log "cloning (shallow)"
  rm -rf "$SRC"
  git clone --quiet --depth 1 --branch "$UPSTREAM_REF" "$UPSTREAM_URL" "$SRC"
fi
git -C "$SRC" checkout --quiet "$UPSTREAM_REF" 2>/dev/null || true
UPSTREAM_SHA="$(git -C "$SRC" rev-parse --short=12 HEAD)"
log "upstream commit: $UPSTREAM_SHA"

# -------------------------------------------------------------------- overlay
OVL="$WORKDIR/overlay"
rm -rf "$OVL"
log "generating stdlib overlay"
python3 "$REPO_ROOT/scripts/make-overlay.py" \
  --goroot "$(go env GOROOT)" \
  --prefix "$PREFIX_BAKED" \
  --out "$OVL"

# ---------------------------------------------------------------------- build
EXTRA_LDFLAGS=""
if [ -f "$REPO_ROOT/VERSION_BUILD" ]; then
  EXTRA_LDFLAGS="-X main.Version=$(cat "$REPO_ROOT/VERSION_BUILD")"
fi

log "building (CGO_ENABLED=0 GOOS=linux GOARCH=arm64 GOARM64=$GOARM64_LEVEL)"
(
  cd "$SRC"
  CGO_ENABLED=0 GOOS=linux GOARCH=arm64 GOARM64="$GOARM64_LEVEL" \
  go build -buildvcs=false -trimpath \
    -overlay "$OVL/overlay.json" \
    -ldflags="-s -w \
      ${EXTRA_LDFLAGS:+-X main.Version=$UPSTREAM_REF-termux} \
      -X main.Commit=$UPSTREAM_SHA \
      -X main.BuildDate=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    -o "$WORKDIR/cli-proxy-api" ./cmd/server
)

# --------------------------------------------------------------------- verify
log "verifying artifact"
bash "$REPO_ROOT/scripts/verify.sh" "$WORKDIR/cli-proxy-api" "$PREFIX_BAKED"

# -------------------------------------------------------------------- package
mkdir -p "$DIST"
STAGE="$WORKDIR/stage/cliproxyapi-termux"
rm -rf "$WORKDIR/stage"
mkdir -p "$STAGE"

install -m 0755 "$WORKDIR/cli-proxy-api" "$STAGE/cli-proxy-api"
install -m 0755 "$REPO_ROOT/wrapper/cliproxy" "$STAGE/cliproxy"
printf '%s\n' "$UPSTREAM_REF" > "$STAGE/UPSTREAM_REF"
printf '%s\n' "$UPSTREAM_SHA" > "$STAGE/UPSTREAM_SHA"
printf '%s\n' "$UPSTREAM_REF-termux" > "$STAGE/VERSION"

(
  cd "$STAGE"
  sha256sum cli-proxy-api > SHA256SUMS
)

TARBALL="cliproxyapi-termux_${UPSTREAM_REF}_aarch64.tar.gz"
rm -f "$DIST/$TARBALL" "$DIST/$TARBALL.sha256"
(
  cd "$WORKDIR/stage"
  tar czf "$DIST/$TARBALL" cliproxyapi-termux
)
(
  cd "$DIST"
  sha256sum "$TARBALL" > "$TARBALL.sha256"
)

log "built: $DIST/$TARBALL"
cat "$DIST/$TARBALL.sha256"

# Emit machine-readable summary for CI steps / the wrapper's release notes.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "upstream_ref=$UPSTREAM_REF"
    echo "upstream_sha=$UPSTREAM_SHA"
    echo "tarball=$TARBALL"
    echo "sha256=$(cut -d' ' -f1 "$DIST/$TARBALL.sha256")"
  } >> "$GITHUB_OUTPUT"
fi
