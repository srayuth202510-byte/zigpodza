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
for mod in src/main.zig src/cli.zig src/cli_specs.zig src/cli_types.zig src/completion.zig src/compose.zig src/config.zig src/http.zig src/http_parser.zig src/http_types.zig src/podman_api.zig src/podman_build.zig src/podman_pods.zig src/podman_transfer.zig src/podman_test_helpers.zig src/podman_types.zig src/podman_validate.zig src/podman_logs.zig src/podman_images.zig src/podman_system.zig src/log.zig src/policy.zig; do
    if has_match "std\.testing\.allocator" "$mod"; then
        pass "std.testing.allocator present in $mod."
    else
        fail "Missing std.testing.allocator tests in $mod."
    fi
done

# 4b. Require root test blocks to reference all submodules (BUG-022 / BUG-023)
if has_match "_ = pods;" "src/main.zig" && has_match "_ = build_mod;" "src/main.zig" && has_match "_ = transfer;" "src/main.zig" && has_match "_ = compose;" "src/main.zig" && has_match "_ = types;" "src/podman_api.zig" && has_match "_ = th;" "src/podman_api.zig"; then
    pass "Root test blocks reference pods, build_mod, transfer, compose, types, and th (BUG-022/BUG-023)."
else
    fail "Missing submodule reference in test blocks of src/main.zig or src/podman_api.zig (see BUG-022/BUG-023)."
fi
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

# 7. Require socket timeout polling, hardening config, audit verification, and 18-case demo
if has_match "waitReadable" "src/http.zig" && has_match "verifyAuditFile" "src/log.zig" && has_match "ReadonlyRootfs" "src/podman_api.zig" && has_match "runSelfTest" "src/demo.zig" && has_match "std\.testing\.allocator" "src/demo.zig"; then
    pass "Timeout poll, HostConfig hardening, audit hash-chain verification, and 18-case demo present."
else
    fail "Missing timeout, HostConfig hardening, verifyAuditFile, or runSelfTest/testing.allocator in src/demo.zig."
fi

# 8. Require parity script executable
if [ -x "$ROOT_DIR/scripts/check-ci-parity.py" ] && [ -x "$ROOT_DIR/scripts/graph-query.py" ] && [ -x "$ROOT_DIR/scripts/smoke.sh" ]; then
    pass "Verification scripts (check-ci-parity.py, graph-query.py, smoke.sh) are executable."
else
    fail "Verification scripts missing executable (+x) permission."
fi

# 8b. Require optional-slot pre-flight cleanup & project free in compose (BUG-038)
if has_match "\?pod\.validate\.MergedEnv" "src/compose.zig" && has_match "@memset\(resolved_envs, null\)" "src/compose.zig" && has_match "defer alloc\.free\(project\);" "src/compose.zig"; then
    pass "Nullable topological cleanup and loadComposeFile project defer enforced (BUG-038)."
else
    fail "Missing nullable pre-flight cleanup or defer alloc.free(project) in src/compose.zig (see BUG-038)."
fi

# 8c. Forbid piping compose output directly to grep -q & enforce Makefile subshell grouping (BUG-039)
if has_match 'compose .+\|[[:space:]]*grep -q' "scripts/smoke.sh" || has_match 'compose .+\|[[:space:]]*grep -q' "scripts/podman-e2e.sh" || ! has_match '\{ for p in .*echo zig; \}' "Makefile"; then
    fail "Found unsafe direct compose pipe to grep -q in E2E scripts or ungrouped Makefile fallback (see BUG-039)."
else
    pass "No unsafe direct compose pipe to grep -q and Makefile ZIG fallback uses { ...; } (BUG-039)."
fi

# 8d. Forbid silent error swallowing in hardened compose/transfer test modules (BUG-040)
if has_match 'else \|_\| \{\}' "src/compose.zig" || has_match 'else \|_\| \{\}' "src/podman_transfer.zig"; then
    fail "Found silent 'else |_| {}' error swallowing in src/compose.zig or src/podman_transfer.zig (see BUG-040)."
else
    pass "No silent 'else |_| {}' swallowing in src/compose.zig or src/podman_transfer.zig (BUG-040)."
fi

# 8e. Require dedicated InvalidShmSize error variant and audit deny rule (BUG-041)
if has_match "InvalidShmSize" "src/podman_types.zig" && has_match "return ApiError\.InvalidShmSize;" "src/podman_validate.zig" && has_match "api\.validateShmSize" "src/main.zig"; then
    pass "Dedicated ApiError.InvalidShmSize and api.validateShmSize telemetry enforced (BUG-041)."
else
    fail "Missing InvalidShmSize variant or api.validateShmSize deny rule (see BUG-041)."
fi

# 8f. Forbid raw request body logging (BUG-024) and ensure runtime logs stay ignored
if ! has_match 'body=\{s\}' "src/" && has_match '^system\.log$' ".gitignore" && has_match '^error\.log$' ".gitignore" && has_match '^audit\.log$' ".gitignore"; then
    pass "No raw 'body={s}' request logging and runtime logs are gitignored (BUG-024)."
else
    fail "Found raw 'body={s}' logging in src/ or missing runtime log rules in .gitignore (see BUG-024)."
fi

# 8g. Require symlink-resolved host mount check & post-strip cp symlink check (BUG-025 / BUG-026)
if has_match 'validateHostPathSymlinks' "src/podman_validate.zig" && has_match 'validateTarSymlinkTarget\(rel,' "src/podman_transfer.zig"; then
    pass "Symlink-aware host mount validation and post-strip cp symlink validation enforced (BUG-025/BUG-026)."
else
    fail "Missing symlink-aware host mount check or post-strip cp symlink validation (see BUG-025/BUG-026)."
fi

# 8h. Require O_NOFOLLOW + fchmod(0o640) on logs and trust/value checks on zigpod.toml (BUG-031 / BUG-033)
if has_match '\.NOFOLLOW = true' "src/log.zig" && has_match 'fchmod\(fd, 0o640\)' "src/log.zig" && has_match 'InsecureConfigFile' "src/config.zig"; then
    pass "O_NOFOLLOW/0640 log hardening and trusted zigpod.toml verification enforced (BUG-031/BUG-033)."
else
    fail "Missing O_NOFOLLOW/fchmod in src/log.zig or InsecureConfigFile guard in src/config.zig (see BUG-031/BUG-033)."
fi

# 8i. Require HostConfig.PortBindings re-validation and non-panicking port key serialization (BUG-034)
if has_match 'hc\.PortBindings' "src/podman_api.zig" && ! has_match 'bufPrint\(&key_buf.*catch unreachable' "src/podman_types.zig"; then
    pass "HostConfig.PortBindings re-validated and safe port key serialization active (BUG-034)."
else
    fail "Missing HostConfig.PortBindings validation or unsafe catch unreachable remains (see BUG-034)."
fi

# 8j. Require fail-closed compose property parsing, service network wiring, and partial-up rollback (BUG-027 / BUG-028 / BUG-029)
if has_match 'isServiceListKey\(' "src/compose.zig" && has_match 'NetworkingConfig' "src/compose.zig" && has_match 'com\.docker\.compose\.network' "src/compose.zig" && has_match 'rollbackComposeUp' "src/compose.zig"; then
    pass "Compose fail-closed list/scalar parsing, network attachment, and rollback enforced (BUG-027/BUG-028/BUG-029)."
else
    fail "Missing fail-closed compose parser guards, service network attachment, or up rollback (see BUG-027/BUG-028/BUG-029)."
fi

# 8k. Require write-path audit tail repair under lock and shared complete-entry verification (BUG-030 / BUG-036)
REPAIR_CALLS=0
if command -v rg >/dev/null 2>&1; then
    REPAIR_CALLS="$(rg -c 'repairAuditTail\(f\);' "src/log.zig" 2>/dev/null || echo 0)"
else
    REPAIR_CALLS="$(grep -Ec 'repairAuditTail\(f\);' "src/log.zig" 2>/dev/null || echo 0)"
fi
if [[ "$REPAIR_CALLS" -ge 2 ]] && has_match 'evaluateAuditContent' "src/log.zig" && has_match 'parseAuditFields\(' "src/log.zig"; then
    pass "Audit write-path tail repair (init+log) and shared complete-entry verification enforced (BUG-030/BUG-036)."
else
    fail "Missing write-path audit tail repair in Logger.log or shared complete-entry verification (see BUG-030/BUG-036)."
fi

# 8l. Require interactive poll timeout checks, build entry errdefer/OOM test, and bounded socket writes (BUG-032 / BUG-035 / BUG-037)
if ! has_match '_\s*=\s*(try\s+)?std\.posix\.poll\(' "src/" && has_match 'interactive_timeout_ms' "src/http_types.zig" && has_match 'interactiveTimeoutMs\(' "src/podman_api.zig"; then
    pass "All std.posix.poll results are checked and interactive sessions enforce bounded timeout (BUG-032)."
else
    fail "Found discarded std.posix.poll result in src/ or missing interactive_timeout_ms deadline (see BUG-032)."
fi

if has_match 'errdefer alloc\.free\(name\);' "src/podman_build.zig" && has_match 'checkAllAllocationFailures' "src/podman_build.zig" && ! has_match '\.name\s*=\s*try\s+alloc\.dupe' "src/podman_build.zig"; then
    pass "Build context entry allocation uses explicit errdefer and OOM regression coverage (BUG-035)."
else
    fail "Inline .name alloc.dupe without errdefer or missing OOM test in src/podman_build.zig (see BUG-035)."
fi

if has_match 'pub fn writeAllWithTimeout\(' "src/http.zig" && has_match 'try writeAllWithTimeout\(' "src/http.zig" && has_match 'try http\.writeAllWithTimeout\(' "src/podman_api.zig" && ! has_match 'try stream\.writeAll\(' "src/http.zig" && ! has_match 'try stream\.writeAll\(' "src/podman_api.zig"; then
    pass "Socket writes enforce writeAllWithTimeout across http.zig and podman_api.zig (BUG-037)."
else
    fail "Missing writeAllWithTimeout guard or unguarded 'try stream.writeAll' remains (see BUG-037)."
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
