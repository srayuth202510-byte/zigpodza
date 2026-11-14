#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Auto-detect Zig binary if not in PATH
if ! command -v zig >/dev/null 2>&1; then
    for candidate in \
        "$HOME/.config/Code - OSS/User/globalStorage/ziglang.vscode-zig/zig/x86_64-linux-0.13.0/zig" \
        "$HOME/.config/Code/User/globalStorage/ziglang.vscode-zig/zig/x86_64-linux-0.13.0/zig" \
        "$HOME/.local/opt/zig-0.13.0/zig" \
        "$HOME/.local/bin/zig" \
        "/usr/local/bin/zig"; do
        if [[ -x "$candidate" ]]; then
            export PATH="$(dirname "$candidate"):$PATH"
            break
        fi
    done
fi

echo "==> [1/4] Checking Zig test suite (unit, security, mock-socket, leak detection)..."
if command -v zig >/dev/null 2>&1; then
    zig build test
    echo "    OK: zig build test passed with zero detected memory leaks."

    echo "==> [2/4] Building ReleaseSafe binary and checking ELF hardening..."
    zig build -Doptimize=ReleaseSafe
    BIN="./zig-out/bin/zigpod"
    if [[ -x "$BIN" ]] && command -v readelf >/dev/null 2>&1; then
        if readelf -lW "$BIN" | awk '/GNU_STACK/ { if ($0 ~ /RWE/) exit 1 }'; then
            echo "    OK: Non-executable stack (GNU_STACK)."
        else
            echo "    FAIL: Executable stack (RWE) detected in $BIN!" >&2
            exit 1
        fi
        if readelf -lW "$BIN" | awk '$1 == "LOAD" && $7 ~ /RWE/ { exit 1 }'; then
            echo "    OK: No RWX PT_LOAD segments."
        else
            echo "    FAIL: RWX PT_LOAD segment detected in $BIN!" >&2
            exit 1
        fi
        readelf -h "$BIN" | awk -F: '/Type:/ { gsub(/^[ \t]+/, "", $2); print "    ELF Type: " $2 }'
    fi
else
    echo "    WARN: 'zig' is not installed in PATH; skipped zig build test & ELF checks."
    if [[ "${CI:-}" == "true" || "${1:-}" == "--require-zig" ]]; then
        exit 1
    fi
fi

echo "==> [3/4] Checking repository file permissions and log files..."
for log_file in system.log error.log; do
    if [[ -e "$log_file" ]]; then
        perms="$(stat -c '%a' "$log_file" 2>/dev/null || stat -f '%Lp' "$log_file")"
        echo "    $log_file permissions: $perms"
        if [[ "${perms: -1}" =~ [2367] ]]; then
            echo "    FAIL: $log_file is world-writable ($perms)!" >&2
            exit 1
        fi
    fi
done

echo "==> [4/4] Checking optional Balor toolkit integration..."
BALOR_BIN="${BALOR_BIN:-/usr/local/bin/balorsh}"
BALOR_DATA="${BALORSH_DATA_DIR:-/opt/balorsh/data}"
if [[ -x "$BALOR_BIN" && -d "$BALOR_DATA" ]]; then
    echo "    Found balorsh at $BALOR_BIN (data: $BALOR_DATA)."
    echo "    Available stacks: $("$BALOR_BIN" list 2>/dev/null | tr '\n' ' ' || echo 'unknown')"
    echo "    Tip: Run '$BALOR_BIN llm' (loganalyst/blueteam) to audit system.log & error.log."
else
    echo "    Info: balorsh data directory not initialized or not accessible in current environment."
fi
if [[ -x "$ROOT_DIR/scripts/balor-security-audit.sh" ]]; then
    echo "    $("$ROOT_DIR/scripts/balor-security-audit.sh" --offline --quiet)"
fi

echo "Security check completed."
