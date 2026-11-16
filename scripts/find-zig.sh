#!/bin/sh
# Prints the path of a Zig compiler that satisfies build.zig.zon's
# `minimum_zig_version` (falls back to plain `zig` when none is found).
#
# Search order: $ZIG, `zig` on PATH, then well-known install locations.
# A candidate is accepted only if `<zig> version` >= the minimum, so a stale
# toolchain earlier on PATH (e.g. an old 0.13.0 symlink) is skipped instead of
# producing confusing compile errors.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MIN=$(sed -n 's/.*\.minimum_zig_version = "\([^"]*\)".*/\1/p' "$ROOT/build.zig.zon")

version_ok() {
    v=$("$1" version 2>/dev/null) || return 1
    [ -n "$MIN" ] || return 0
    [ "$(printf '%s\n%s\n' "$MIN" "$v" | sort -V | head -n 1)" = "$MIN" ]
}

for p in \
    "${ZIG:-}" \
    "$(command -v zig 2>/dev/null || true)" \
    "$HOME/.local/opt/zig-x86_64-linux-$MIN/zig" \
    "/opt/zig-x86_64-linux-$MIN/zig" \
    "$HOME/.local/bin/zig" \
    "/usr/local/bin/zig"; do
    if [ -n "$p" ] && [ -x "$p" ] && version_ok "$p"; then
        echo "$p"
        exit 0
    fi
done
echo zig
