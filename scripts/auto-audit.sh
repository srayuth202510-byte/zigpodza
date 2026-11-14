#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

HOOK_MODE=false
if [[ "${1:-}" == "--hook" ]]; then
    HOOK_MODE=true
    cat >/dev/null || true
fi

# BUG-011: force the C locale so the timestamp is always Gregorian UTC.
# Under e.g. LC_TIME=th_TH.UTF-8 a bare `date +%Y` yields the Buddhist Era
# year, which would mix two calendars inside system.log.
TIMESTAMP="$(LC_ALL=C date -u '+%Y-%m-%dT%H:%M:%SZ')"
FAILURES=0
REPORT=""

fail() {
    FAILURES=$((FAILURES + 1))
    REPORT+="FAIL: $1"$'\n'
}

pass() {
    REPORT+="OK: $1"$'\n'
}

has_match() {
    local pattern="$1"
    local target="$2"
    if command -v rg >/dev/null 2>&1; then
        rg -q -- "$pattern" "$target"
    else
        grep -REq -- "$pattern" "$target"
    fi
}

# 1. Forbid page_allocator in src/ (hides leaks in tests/runtime)
if has_match "page_allocator" "src/"; then
    fail "Found forbidden 'page_allocator' in src/ (see docs/vault/Bug-Playbook.md BUG-002)."
else
    pass "No 'page_allocator' usage in src/."
fi

# 2. Forbid ignoring GeneralPurposeAllocator.deinit() leak checks
if has_match "defer _ = gpa\.deinit" "src/"; then
    fail "Found ignored 'gpa.deinit()' in src/main.zig."
else
    pass "GPA leak check is enforced."
fi

# 3. Forbid BUG-001 regression (error.AccessDenied on connectUnixSocket)
if has_match "error\.AccessDenied" "src/http.zig"; then
    fail "Found 'error.AccessDenied' in src/http.zig (Zig 0.13 connectUnixSocket uses PermissionDenied; see BUG-001)."
else
    pass "No BUG-001 AccessDenied mismatch in src/http.zig."
fi

# 4. Require std.testing.allocator in every heap-allocating module
for mod in src/cli.zig src/config.zig src/http.zig src/podman_api.zig src/log.zig; do
    if has_match "std\.testing\.allocator" "$mod"; then
        pass "std.testing.allocator present in $mod."
    else
        fail "Missing std.testing.allocator tests in $mod."
    fi
done

# 5. Require input/protocol validation gates
if has_match "try validateRequestTarget\(" "src/http.zig"; then
    pass "validateRequestTarget() enforced in src/http.zig."
else
    fail "validateRequestTarget() is not called in src/http.zig."
fi

if has_match "try validateIdentifier\(" "src/podman_api.zig"; then
    pass "validateIdentifier() enforced in src/podman_api.zig."
else
    fail "validateIdentifier() is not called in src/podman_api.zig."
fi

# 5b. Require the fail-closed host bind-mount policy (BUG-014)
if has_match "pub fn validateHostPath\(" "src/podman_api.zig" && has_match "try validateHostPath\(" "src/podman_api.zig"; then
    pass "validateHostPath() fail-closed host mount policy enforced in src/podman_api.zig."
else
    fail "Missing validateHostPath() host mount policy in src/podman_api.zig (see BUG-014)."
fi

# 5c. Require the fail-closed port-publishing policy (BUG-015)
if has_match "pub fn validatePortMapping\(" "src/podman_api.zig" && has_match "try validatePortMapping\(" "src/podman_api.zig"; then
    pass "validatePortMapping() fail-closed port policy enforced in src/podman_api.zig."
else
    fail "Missing validatePortMapping() port policy in src/podman_api.zig (see BUG-015)."
fi

# 5d. Require the fail-closed network/identity/capability policy (BUG-016)
if has_match "pub fn validateNetworkMode\(" "src/podman_api.zig" && has_match "pub fn validateCapability\(" "src/podman_api.zig" && has_match "try validateNetworkMode\(" "src/podman_api.zig"; then
    pass "validateNetworkMode()/validateCapability() fail-closed identity policy enforced in src/podman_api.zig."
else
    fail "Missing validateNetworkMode()/validateCapability() identity policy in src/podman_api.zig (see BUG-016)."
fi

# 6. Require checked arithmetic in parsers & decoders
if has_match "std\.math\.add" "src/http.zig" && has_match "std\.math\.add" "src/podman_api.zig" && has_match "std\.math\.mul" "src/cli.zig"; then
    pass "Checked arithmetic (std.math.add/mul) active in chunk/frame decoders and CLI memory parser."
else
    fail "Missing checked arithmetic in src/http.zig, src/podman_api.zig, or src/cli.zig."
fi

# 7. Require socket timeout polling, hardening config, audit verification, and 14-case demo
if has_match "waitReadable" "src/http.zig" && has_match "verifyAuditFile" "src/log.zig" && has_match "ReadonlyRootfs" "src/podman_api.zig" && has_match "runSelfTest" "src/demo.zig" && has_match "std\.testing\.allocator" "src/demo.zig"; then
    pass "Timeout poll, HostConfig hardening, audit hash-chain verification, and 14-case demo present."
else
    fail "Missing timeout, HostConfig hardening, verifyAuditFile, or runSelfTest/testing.allocator in src/demo.zig."
fi

# 8. Require parity script executable
if [ -x "$ROOT_DIR/scripts/check-ci-parity.py" ] && [ -x "$ROOT_DIR/scripts/graph-query.py" ] && [ -x "$ROOT_DIR/scripts/smoke.sh" ]; then
    pass "Verification scripts (check-ci-parity.py, graph-query.py, smoke.sh) are executable."
else
    fail "Verification scripts missing executable (+x) permission."
fi

# 9. Run security-check.sh (includes zig build test & ELF hardening when zig is installed)
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
