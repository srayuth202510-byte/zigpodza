#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${PREFIX:-/usr/local}"
BIN_DIR="${PREFIX}/bin"

cd "$ROOT_DIR"

echo "Building zigpod (ReleaseSafe)..."
zig build -Doptimize=ReleaseSafe

echo "Installing zigpod to ${BIN_DIR}/zigpod..."
if [ -w "$BIN_DIR" ] 2>/dev/null || [ ! -e "$BIN_DIR" ] && [ -w "$(dirname "$BIN_DIR")" ]; then
    mkdir -p "$BIN_DIR"
    install -m 0755 zig-out/bin/zigpod "${BIN_DIR}/zigpod"
else
    sudo mkdir -p "$BIN_DIR"
    sudo install -m 0755 zig-out/bin/zigpod "${BIN_DIR}/zigpod"
fi

echo "Installed: $(command -v zigpod || echo "${BIN_DIR}/zigpod")"
