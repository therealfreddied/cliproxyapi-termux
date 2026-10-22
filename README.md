# cliproxyapi-termux

Termux-native builds of [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) for **aarch64 Android**, with a launcher that checks for updates and offers to install them.

```
[cliproxy] A new update (v8.0.39) is available!
[cliproxy] Would you like to update now? [Y/n]:
```

---

## Why this repo exists

Upstream ships **no Android build**, and neither aarch64 Linux asset works on Termux as-is:

| Upstream asset | Why it fails |
|---|---|
| `CLIProxyAPI_*_linux_aarch64.tar.gz` | Dynamically linked against glibc (`interpreter /lib/ld-linux-aarch64.so.1`). Android uses bionic, so it will not execute at all. |
| `CLIProxyAPI_*_linux_aarch64_no-plugin.tar.gz` | **Static, so it runs** — but then breaks on the first network call, because three stdlib paths are wrong for Android. |

That second case is the trap: it launches, prints its version banner, and looks healthy until it needs DNS or TLS.

## The three patches

Every build in this repo applies all three. Each is proven present in the artifact before it is allowed to publish.

### 1. DNS — `net/dnsclient_unix.go`

Go hardcodes `/etc/resolv.conf`. Android has no writable `/etc`; Termux keeps its resolver config at `$PREFIX/etc/resolv.conf`. The `open()` fails, `dnsReadConfig` falls back to:

```go
var defaultNS = []string{"127.0.0.1:53", "[::1]:53"}
```

Nothing listens there in the Termux sandbox, so **every DNS lookup fails**. This is the real reason "Go binaries don't work in Termux" — and it is a *compile-time* path, so `GODEBUG=netdns=go` and `CGO_ENABLED` tricks cannot fix it.

`→ $PREFIX/etc/resolv.conf`

### 2. TLS — `crypto/x509/root_linux.go`

`certFiles` lists only glibc distro paths. Termux's `ca-certificates` installs to `$PREFIX/etc/tls/cert.pem`, which is not in that list, so TLS verification fails even once DNS works.

`→ prepend $PREFIX/etc/tls/cert.pem as the first entry`

### 3. Temp dir — `os/file_unix.go` `tempDir()`

```go
dir := Getenv("TMPDIR")
if dir == "" {
    if runtime.GOOS == "android" {
        dir = "/data/local/tmp"
    } else {
        dir = "/tmp"        // ← what we get, since we build GOOS=linux
    }
}
```

Because these are built with `GOOS=linux`, the `android` branch never applies and the fallback is `/tmp`, which Android does not provide.

`→ $PREFIX/tmp, Stat-guarded so a normal Linux host still gets /tmp`

The guard matters: it means **one binary is correct on both Termux and a regular Linux box**. A hardcoded path would be wrong everywhere else.

## How patches are applied

Via `go build -overlay`, **not** by editing GOROOT.

My first attempt mutated the toolchain and restored it with a `trap`. That is a corrupted Go install waiting to happen if a build is ever interrupted. `-overlay` makes the compiler read replacement files from a separate directory, so:

- GOROOT is never written to
- an interrupted build cannot damage the toolchain
- the identical script runs on CI and on the device

```
go build -overlay overlay.json ...
```

`scripts/make-overlay.py` generates the tree and **aborts if any anchor is missing** — if upstream Go reshuffles those files, the build fails loudly instead of silently shipping an unpatched binary.

## Build configuration

```
GOOS=linux          # NOT android
GOARCH=arm64
CGO_ENABLED=0       # static; also selects pluginhost's !cgo stub
GOARM64=v9.0,lse,crypto
-ldflags="-s -w"
-trimpath
```

**Why not `GOOS=android`:** it produces a PIE needing `/system/bin/linker64`, and `net/conf.go` has `case "android": return true` in `preferCgo` — so it wants the cgo resolver that a static build does not have.

**`GOARM64`:** note that `dotprod` is **not** a valid suffix (verified: `v9.0,lse,crypto,dotprod` is rejected). `v9.0,lse,crypto` is a safe floor that still emits native LDADD/CAS atomics. Snapdragon 8 Gen 2 (S23 baseline) is ARMv9.2-A, so this is comfortably within range.

**Toolchain pinning:** CI uses Go **1.27.3**, matching the Termux `golang` package, so a CI build and an on-device build are byte-comparable in behaviour.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/therealfreddied/cliproxyapi-termux/main/install.sh | bash
```

The installer verifies before writing anything:

1. sha256 against the published sidecar
2. tarball path safety (no absolute paths / tarbomb)
3. static aarch64 ELF
4. all three patch strings present

If any check fails, it stops with **nothing installed**.

Then:

```bash
cliproxy                 # launch (checks for updates first)
termux-wake-lock         # before backgrounding
nohup cliproxy > ~/.config/cliproxyapi/cliproxy.log 2>&1 &
```

## Launcher

| Command | Effect |
|---|---|
| `cliproxy` | launch, checking for updates first |
| `cliproxy --check` | report installed vs latest, exit |
| `cliproxy --update` | update if newer |
| `cliproxy --yes` | never prompt |
| `cliproxy --no-update` | skip the check this run |
| `cliproxy --force` | reinstall even if current |
| `cliproxy --rollback` | restore the previous binary |
| `cliproxy --version` | print installed version |
| `cliproxy --uninstall` | remove binary and state (keeps config) |

**Safety properties:**

- update checks are throttled (default 6h) via `.lastcheck`
- **non-interactive runs never auto-update** — a `nohup` service will not silently restart into a new version; needs `--yes`
- swap is an atomic `mv`, previous binary kept as `cli-proxy-api.prev`
- a failed update leaves the installed version untouched

## Repo automation

`.github/workflows/build-termux.yml` runs every 6 hours:

1. resolve newest upstream release tag
2. skip if that version is already published
3. checkout upstream source at that tag
4. generate overlay + patch stdlib
5. cross-compile static aarch64
6. **verify all three patches are present — fail closed**
7. publish a GitHub Release with tarball + sha256
8. commit the patched stdlib snapshot back to `snapshot/`

Upstream ships fast (v8.0.31 → v8.0.38 in one week, sometimes twice daily), hence the schedule rather than webhooks.

## Layout

```
scripts/make-overlay.py    generate patched stdlib tree + overlay.json
scripts/build.sh           resolve ref, checkout, overlay, build, verify, package
scripts/verify.sh          hard assertions (static, aarch64, 3/3 patches)
wrapper/cliproxy           launcher with self-update + rollback
install.sh                 one-shot installer
snapshot/                  committed patched stdlib (updated by CI)
```

## Caveats

- **aarch64 only.** No armv7 or x86_64 artifacts.
- **61 MB binary.** `-s -w` is already applied upstream; the TUI (bubbletea/lipgloss) and embedded model catalogs are not behind build tags, so they cannot be dropped without forking.
- **Do not UPX it.** It shrinks on disk but decompresses into RAM at exec — the wrong trade for a long-running daemon on a phone.
- **Android 12+ phantom-process killing** can reap background processes despite `termux-wake-lock`. Enable the phantom-process-killer toggle for Termux and keep the wake-lock.
- **Plugin support is absent** by design (`CGO_ENABLED=0`). Dynamic library plugins need cgo.

## Licence

The build scripts and wrapper here are MIT. CLIProxyAPI itself is MIT, by
[router-for-me](https://github.com/router-for-me/CLIProxyAPI) — all upstream
copyright remains with its authors. This repo only repackages it for Termux.
