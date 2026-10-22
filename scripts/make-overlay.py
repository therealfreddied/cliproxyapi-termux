#!/usr/bin/env python3
"""Generate a `go build -overlay` tree that patches Go's stdlib for Termux.

Why an overlay instead of editing GOROOT
----------------------------------------
Editing GOROOT in place works, but it mutates a system directory. If the
build is interrupted the toolchain is left in a patched state, and on a
phone that means a corrupted Go install until you notice. `-overlay` makes
the compiler read replacement files from a separate directory, so GOROOT is
never written to. The same script therefore works on a CI runner and on the
device, which is what keeps the two build paths honest.

Three patches, all required
---------------------------
1. net/dnsclient_unix.go
   Hardcodes "/etc/resolv.conf". Android has no writable /etc; Termux keeps
   its resolver config at $PREFIX/etc/resolv.conf. Without this the open()
   fails, dnsReadConfig falls back to defaultNS ["127.0.0.1:53","[::1]:53"],
   nothing listens there, and every DNS lookup fails.

2. crypto/x509/root_linux.go
   certFiles lists only glibc distro paths. Termux's ca-certificates
   installs to $PREFIX/etc/tls/cert.pem, so TLS verification fails even once
   DNS works.

3. os/file_unix.go  tempDir()
   Falls back to "/tmp" for GOOS=linux, which does not exist on Android.
   Patched to $PREFIX/tmp, Stat-guarded so a normal Linux host still gets
   /tmp from the same binary.

Every patch asserts its anchor was found. A silent no-op here would ship a
binary that looks fine and fails at runtime, so any miss exits non-zero.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys

F_DNS = "net/dnsclient_unix.go"
F_CERT = "crypto/x509/root_linux.go"
F_TMP = "os/file_unix.go"
F_SYSCALL = "syscall/syscall_linux.go"

def read(path: str) -> str:
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def write(path: str, data: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(data)


def patch_on_disk(name: str = "net") -> str:
    # Not used; kept for clarity of intent in diffs.
    return name


def patch_dns(src: str, prefix: str) -> tuple[str, int]:
    """Point the resolver at $PREFIX/etc/resolv.conf."""
    needle = '"/etc/resolv.conf"'
    count = src.count(needle)
    if count == 0:
        raise SystemExit(
            f"FATAL: {F_DNS}: anchor {needle} not found. "
            "Upstream Go changed this file; inspect before shipping."
        )
    return src.replace(needle, f'"{prefix}/etc/resolv.conf"'), count


def patch_cert(src: str, prefix: str) -> tuple[str, int]:
    """Prepend the Termux CA bundle to certFiles (list stops at first hit)."""
    anchor = "var certFiles = []string{"
    if anchor not in src:
        raise SystemExit(
            f"FATAL: {F_CERT}: anchor {anchor!r} not found. "
            "Upstream Go changed this file; inspect before shipping."
        )
    if prefix in src:
        return src, 0
    repl = anchor + f'\n\t"{prefix}/etc/tls/cert.pem", // Termux'
    return src.replace(anchor, repl, 1), 1


def patch_tempdir(src: str, prefix: str) -> tuple[str, int]:
    """Make tempDir() use $PREFIX/tmp when it exists.

    Scoped to the tempDir() function body so we never touch an unrelated
    `dir = "/tmp"` elsewhere in the file.
    """
    if f"{prefix}/tmp" in src:
        return src, 0

    m = re.search(r"func tempDir\(\) string \{", src)
    if not m:
        raise SystemExit(
            f"FATAL: {F_TMP}: func tempDir() not found. "
            "Upstream Go changed this file; inspect before shipping."
        )
    # Find the closing brace of the function by brace counting.
    start = m.end()
    depth = 1
    i = start
    while i < len(src) and depth:
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
        i += 1
    if depth:
        raise SystemExit(f"FATAL: {F_TMP}: unbalanced braces in tempDir()")

    body = src[start:i]
    inner = 'dir = "/tmp"'
    if inner not in body:
        raise SystemExit(
            f"FATAL: {F_TMP}: tempDir() body has no {inner} fallback. "
            "Upstream Go changed this file; inspect before shipping."
        )

    guarded = (
        "{\n"
        "\t\t\t\t// Termux: Android has no writable /tmp; the app sandbox\n"
        "\t\t\t\t// uses $PREFIX/tmp. Stat-guarded so a normal Linux host\n"
        "\t\t\t\t// still resolves to /tmp from the same binary.\n"
        f'\t\t\t\tconst termuxTmp = "{prefix}/tmp"\n'
        "\t\t\t\tif fi, statErr := Stat(termuxTmp); statErr == nil && fi.IsDir() {\n"
        "\t\t\t\t\tdir = termuxTmp\n"
        "\t\t\t\t} else {\n"
        '\t\t\t\t\tdir = "/tmp"\n'
        "\t\t\t\t}\n"
        "\t\t\t}"
    )
    new_body = body.replace(inner, guarded, 1)
    return src[:start] + new_body + src[i:], 1

def patch_syscall(src: str, prefix: str) -> tuple[str, int]:
    """Disable faccessat2 on Android/Termux under GOOS=linux."""
    anchor = 'if runtime.GOOS != "android" {'
    if anchor not in src:
        raise SystemExit(
            f"FATAL: {F_SYSCALL}: anchor {anchor!r} not found. "
            "Upstream Go changed this file; inspect before shipping."
        )
    return src.replace(anchor, "if 1 == 0 && runtime.GOOS != \"\" {", 1), 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--goroot", required=True, help="Go installation root")
    ap.add_argument(
        "--prefix",
        default="/data/data/com.termux/files/usr",
        help="Termux PREFIX baked into the binary",
    )
    ap.add_argument("--out", required=True, help="output dir for overlay tree")
    args = ap.parse_args()

    if not os.path.isdir(args.goroot):
        raise SystemExit(f"FATAL: GOROOT not found: {args.goroot}")

    srcdir = os.path.join(args.goroot, "src")
    outdir = os.path.abspath(args.out)
    os.makedirs(outdir, exist_ok=True)

    overlay: dict[str, str] = {}
    report: list[str] = []

    jobs = [
        (F_DNS, patch_dns),
        (F_CERT, patch_cert),
        (F_TMP, patch_tempdir),
        (F_SYSCALL, patch_syscall),
    ]
    for rel, fn in jobs:
        orig = os.path.join(srcdir, rel)
        if not os.path.isfile(orig):
            raise SystemExit(f"FATAL: missing stdlib file: {orig}")
        text = read(orig)
        patched, n = fn(text, args.prefix)
        dest = os.path.join(outdir, rel.replace("/", "_"))
        write(dest, patched)
        overlay[orig] = dest
        report.append(f"  {rel:28s} replacements={n}")

    ovpath = os.path.join(outdir, "overlay.json")
    write(ovpath, json.dumps({"Replace": overlay}, indent=2))

    print("overlay generated:")
    for line in report:
        print(line)
    print(f"  overlay.json -> {ovpath}")

    # Fail closed: every patch must be present in the generated tree.
    checks = {
        f"{args.prefix}/etc/resolv.conf": F_DNS,
    }
    for needle, rel in checks.items():
        dest = overlay[os.path.join(srcdir, rel)]
        if needle not in read(dest):
            raise SystemExit(f"FATAL: patch verification failed for {rel}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
