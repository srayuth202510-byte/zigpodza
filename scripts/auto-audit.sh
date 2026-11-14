#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

HOOK_MODE=false
if [[ "${1:-}" == "--hook" ]]; then
    HOOK_MODE=true
    cat >/dev/null || true
fi

TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
FAILURES=0
REPORT=""

fail() {
    FAILURES=$((FAILURES + 1))
    REPORT+="FAIL: $1"$'\n'
}

pass() {
    REPORT+="OK: $1"$'\n'
}

# 1. Forbid page_allocator in src/ (hides leaks in tests/runtime)
if rg -n "page_allocator" src/ >/dev/null 2>&1; then
    fail "Found forbidden 'page_allocator' in src/ (see docs/vault/Bug-Playbook.md BUG-002)."
else
    pass "No 'page_allocator' usage in src/."
fi

# 2. Forbid ignoring GeneralPurposeAllocator.deinit() leak checks
if rg -n "defer _ = gpa\.deinit" src/ >/dev/null 2>&1; then
    fail "Found ignored 'gpa.deinit()' in src/main.zig."
else
    pass "GPA leak check is enforced."
fi

# 3. Forbid BUG-001 regression (error.AccessDenied on connectUnixSocket)
if rg -n "error\.AccessDenied" src/http.zig >/dev/null 2>&1; then
    fail "Found 'error.AccessDenied' in src/http.zig (Zig 0.13 connectUnixSocket uses PermissionDenied; see BUG-001)."
else
    pass "No BUG-001 AccessDenied mismatch in src/http.zig."
fi

# 4. Require std.testing.allocator in every heap-allocating module
for mod in src/cli.zig src/config.zig src/http.zig src/podman_api.zig src/log.zig; do
    if rg -q "std\.testing\.allocator" "$mod"; then
        pass "std.testing.allocator present in $mod."
    else
        fail "Missing std.testing.allocator tests in $mod."
    fi
done

# 5. Require input/protocol validation gates
if rg -q "try validateRequestTarget\(" src/http.zig; then
    pass "validateRequestTarget() enforced in src/http.zig."
else
    fail "validateRequestTarget() is not called in src/http.zig."
fi

if rg -q "try validateIdentifier\(" src/podman_api.zig; then
    pass "validateIdentifier() enforced in src/podman_api.zig."
else
    fail "validateIdentifier() is not called in src/podman_api.zig."
fi

# 6. Require checked arithmetic in decoders
if rg -q "std\.math\.add" src/http.zig && rg -q "std\.math\.add" src/podman_api.zig; then
    pass "Checked arithmetic (std.math.add) active in chunk/frame decoders."
else
    fail "Missing std.math.add in src/http.zig or src/podman_api.zig."
fi

# 7. Run security-check.sh (includes zig build test & ELF hardening when zig is installed)
SEC_OUT=""
if SEC_OUT="$("$ROOT_DIR/scripts/security-check.sh" 2>&1)"; then
    pass "scripts/security-check.sh completed cleanly."
else
    fail "scripts/security-check.sh failed: $SEC_OUT"
fi

# Record result in system.log and error.log
if [[ "$FAILURES" -eq 0 ]]; then
    printf "%s [INFO] auto-audit passed (hook=%s)\n" "$TIMESTAMP" "$HOOK_MODE" >> "$ROOT_DIR/system.log"
else
    printf "%s [ERROR] auto-audit detected %d failure(s) (hook=%s)\n" "$TIMESTAMP" "$FAILURES" "$HOOK_MODE" >> "$ROOT_DIR/system.log"
    printf "%s [ERROR] auto-audit detected %d failure(s):\n%s" "$TIMESTAMP" "$FAILURES" "$REPORT" >> "$ROOT_DIR/error.log"
fi

if [[ "$HOOK_MODE" == "true" ]]; then
    printf "{}\n"
    if [[ "$FAILURES" -ne 0 ]]; then
        printf "%s" "$REPORT" >&2
        exit 1
    fi
    exit 0
fi

printf "%s" "$REPORT"
if [[ -n "$SEC_OUT" ]]; then
    printf "\n--- security-check output ---\n%s\n" "$SEC_OUT"
fi

if [[ "$FAILURES" -ne 0 ]]; then
    exit 1
fi
