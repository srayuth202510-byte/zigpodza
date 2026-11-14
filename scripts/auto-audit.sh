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
for mod in src/main.zig src/cli.zig src/cli_specs.zig src/config.zig src/http.zig src/http_parser.zig src/podman_api.zig src/podman_validate.zig src/podman_logs.zig src/podman_images.zig src/podman_system.zig src/log.zig src/policy.zig; do
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

if has_match "try validateIdentifier\(" "src/"; then
    pass "validateIdentifier() enforced in src/podman_*.zig."
else
    fail "validateIdentifier() is not called in src/podman_*.zig."
fi

# 5b. Require the fail-closed host bind-mount policy (BUG-014)
if has_match "pub fn validateHostPath\(" "src/" && has_match "try validateHostPath\(" "src/"; then
    pass "validateHostPath() fail-closed host mount policy enforced in src/podman_*.zig."
else
    fail "Missing validateHostPath() host mount policy in src/podman_*.zig (see BUG-014)."
fi

# 5c. Require the fail-closed port-publishing policy (BUG-015)
if has_match "pub fn validatePortMapping\(" "src/" && has_match "try validatePortMapping\(" "src/"; then
    pass "validatePortMapping() fail-closed port policy enforced in src/podman_*.zig."
else
    fail "Missing validatePortMapping() port policy in src/podman_*.zig (see BUG-015)."
fi

# 5d. Require the fail-closed network/identity/capability policy (BUG-016)
if has_match "pub fn validateNetworkMode\(" "src/" && has_match "pub fn validateCapability\(" "src/" && has_match "try validateNetworkMode\(" "src/"; then
    pass "validateNetworkMode()/validateCapability() fail-closed identity policy enforced in src/podman_*.zig."
else
    fail "Missing validateNetworkMode()/validateCapability() identity policy in src/podman_*.zig (see BUG-016)."
fi

# 5e. Require the inspect resource-reference guard (BUG-017)
if has_match "pub fn validateResourceRef\(" "src/" && has_match "try validateResourceRef\(" "src/"; then
    pass "validateResourceRef() inspect path guard enforced in src/podman_*.zig."
else
    fail "Missing validateResourceRef() inspect path guard in src/podman_*.zig (see BUG-017)."
fi

# 5f. Require the exec lifecycle validation (BUG-018)
if has_match "pub fn createExec\(" "src/podman_api.zig" && has_match "pub fn startExec\(" "src/podman_api.zig" && has_match "try validateIdentifier\(exec_id\)" "src/podman_api.zig"; then
    pass "createExec()/startExec() validate the exec ID and identity fields in src/podman_api.zig."
else
    fail "Missing createExec()/startExec() validation in src/podman_api.zig (see BUG-018)."
fi

# 5g. Require the fail-closed sandbox policy engine & DENY telemetry (BUG-019)
if has_match "pub fn checkRunPolicy\(" "src/policy.zig" && has_match "pub fn writeAuditJson\(" "src/log.zig" && has_match "logger\.deny\(" "src/main.zig"; then
    pass "checkRunPolicy(), writeAuditJson(), and logger.deny() enforced (BUG-019)."
else
    fail "Missing sandbox policy guard or DENY audit telemetry (see BUG-019)."
fi

# 6. Require checked arithmetic in parsers & decoders
if has_match "std\.math\.add" "src/http_parser.zig" && has_match "std\.math\.add" "src/podman_logs.zig" && has_match "std\.math\.mul" "src/cli_specs.zig"; then
    pass "Checked arithmetic (std.math.add/mul) active in chunk/frame decoders and CLI memory parser."
else
    fail "Missing checked arithmetic in src/http_parser.zig, src/podman_logs.zig, or src/cli_specs.zig."
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
