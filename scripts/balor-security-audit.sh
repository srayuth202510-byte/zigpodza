#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BALOR_BIN="${BALOR_BIN:-/usr/local/bin/balorsh}"
BALOR_DATA="${BALORSH_DATA_DIR:-/opt/balorsh/data}"

MODE="audit"
JSON_OUT=false
QUIET=false
USE_LLM=false
RUN_SCAN=false
INSPECT_FILE=""
CONTAINER=""
OUT_FILE=""
ENV_ITEMS=()

usage() {
    cat <<'EOF'
Usage: scripts/balor-security-audit.sh [OPTIONS]

Phase 6A Deep Balor & Offline Security Audit Pipeline for ZigPod:
  --offline             Force deterministic offline rule-based analysis (default when balorsh is unavailable)
  --json                Emit structured JSON report
  --quiet               Compact one-line summary (for security-check.sh)
  --llm                 Pipe sanitized audit summary to balorsh llm (loganalyst/blueteam) when available
  --inspect-json FILE   Audit a ContainerInspect JSON file (6A.2 surface + 6A.3 purple-team + 6A.4 env hygiene)
  --container NAME      Run `zigpod inspect --json NAME` and audit the live container
  --env KEY=VALUE       Check an environment variable for secret/hash hygiene (repeatable)
  --run-scan            When balorsh is available, run networkscan/webexploit against discovered ports
  --out FILE            Write report to FILE
  -h, --help            Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --offline) USE_LLM=false; shift ;;
        --json) JSON_OUT=true; shift ;;
        --quiet) QUIET=true; shift ;;
        --llm) USE_LLM=true; shift ;;
        --run-scan) RUN_SCAN=true; shift ;;
        --inspect-json) INSPECT_FILE="${2:-}"; shift 2 ;;
        --container) CONTAINER="${2:-}"; shift 2 ;;
        --env) ENV_ITEMS+=("${2:-}"); shift 2 ;;
        --out) OUT_FILE="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

BALOR_AVAILABLE=false
if [[ -x "$BALOR_BIN" && -d "$BALOR_DATA" ]]; then
    BALOR_AVAILABLE=true
fi

TMP_INSPECT=""
cleanup() {
    if [[ -n "$TMP_INSPECT" && -f "$TMP_INSPECT" ]]; then
        rm -f "$TMP_INSPECT"
    fi
}
trap cleanup EXIT

if [[ -n "$CONTAINER" ]]; then
    ZIGPOD_BIN="${ZIGPOD_BIN:-./zig-out/bin/zigpod}"
    if [[ ! -x "$ZIGPOD_BIN" ]]; then
        echo "FAIL: zigpod binary not found at $ZIGPOD_BIN (build first or pass --inspect-json)." >&2
        exit 1
    fi
    TMP_INSPECT="$(mktemp)"
    "$ZIGPOD_BIN" inspect --json "$CONTAINER" > "$TMP_INSPECT"
    INSPECT_FILE="$TMP_INSPECT"
fi

REPORT_OUT="$(python3 - "$ROOT_DIR" "$JSON_OUT" "$QUIET" "$INSPECT_FILE" "$BALOR_AVAILABLE" "${ENV_ITEMS[@]+"${ENV_ITEMS[@]}"}" <<'PYEOF'
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
json_out = sys.argv[2] == "true"
quiet = sys.argv[3] == "true"
inspect_path = sys.argv[4]
balor_available = sys.argv[5] == "true"
extra_envs = sys.argv[6:]

findings = []

def add_finding(severity: str, category: str, title: str, detail: str, rec: str = "") -> None:
    findings.append({
        "severity": severity,
        "category": category,
        "title": title,
        "detail": detail,
        "recommendation": rec,
    })

# --- 6A.1: Log & Policy Audit ---
audit_stats = {"total": 0, "deny": 0, "error": 0, "malformed": 0, "recent_denies": []}
audit_file = root / "audit.log"
if audit_file.is_file():
    for raw in audit_file.read_text(encoding="utf-8", errors="replace").splitlines():
        if not raw.strip():
            continue
        audit_stats["total"] += 1
        parts = raw.split("\t", 4)
        if len(parts) < 5:
            audit_stats["malformed"] += 1
            continue
        ts, level, _prev_h, _cur_h, msg = parts
        if level == "DENY":
            audit_stats["deny"] += 1
            audit_stats["recent_denies"].append({"ts": ts, "msg": msg})
        elif level == "ERROR":
            audit_stats["error"] += 1
    audit_stats["recent_denies"] = audit_stats["recent_denies"][-10:]
    if audit_stats["malformed"] > 0:
        add_finding(
            "HIGH", "audit-log", "Malformed entries in audit.log",
            f"Found {audit_stats['malformed']} line(s) not matching 5-column hash-chain format.",
            "Run `zigpod audit` to verify hash-chain integrity.",
        )

error_lines = 0
error_file = root / "error.log"
if error_file.is_file():
    error_lines = sum(1 for l in error_file.read_text(encoding="utf-8", errors="replace").splitlines() if l.strip())

policy = {}
policy_file = root / "zigpod-policy.json"
if policy_file.is_file():
    try:
        policy = json.loads(policy_file.read_text(encoding="utf-8"))
        if not policy.get("require_read_only", False):
            add_finding("HIGH", "policy", "require_read_only is disabled", "zigpod-policy.json allows writable rootfs.", "Set require_read_only: true.")
        if not policy.get("require_no_new_privileges", False):
            add_finding("HIGH", "policy", "require_no_new_privileges is disabled", "Privilege escalation via setuid is not blocked.", "Set require_no_new_privileges: true.")
        if not policy.get("require_cap_drop_all", False):
            add_finding("HIGH", "policy", "require_cap_drop_all is disabled", "Linux capabilities are not dropped by default.", "Set require_cap_drop_all: true.")
        if policy.get("forbid_published_ports", False) is False:
            add_finding("INFO", "policy", "Published ports allowed by policy", "forbid_published_ports is false in zigpod-policy.json.", "Set forbid_published_ports: true for strict air-gapped sandboxes.")
        if policy.get("allowed_networks") != ["none"]:
            add_finding("MEDIUM", "policy", "Non-isolated networks allowed", f"allowed_networks={policy.get('allowed_networks')}", "Restrict allowed_networks to [\"none\"] for untrusted workloads.")
    except json.JSONDecodeError as exc:
        add_finding("HIGH", "policy", "Invalid zigpod-policy.json", str(exc), "Fix JSON syntax in zigpod-policy.json.")

# --- 6A.2 / 6A.3 / 6A.4: Container Inspect & Env Hygiene ---
endpoints = []
secret_hits = []
SECRET_PATTERNS = [
    ("password-hash", re.compile(r"\$(?:2[aby]|5|6|argon2(?:id|i|d)?)\$")),
    ("aws-access-key", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("github-token", re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}")),
    ("generic-sk-token", re.compile(r"\bsk-[A-Za-z0-9_-]{16,}")),
    ("sensitive-env-name", re.compile(r"^(?:.*(?:PASSWORD|SECRET|TOKEN|API_KEY|PRIVATE_KEY))=(.+)$", re.IGNORECASE)),
]

def check_env_entry(entry: str) -> None:
    for kind, pat in SECRET_PATTERNS:
        m = pat.search(entry)
        if m:
            if kind == "sensitive-env-name" and m.group(1).strip() in ("", "changeme", "placeholder"):
                continue
            key = entry.split("=", 1)[0]
            secret_hits.append({"kind": kind, "key": key})
            add_finding(
                "HIGH", "secret-hygiene", f"Potential secret/hash in env ({key})",
                f"Matched rule '{kind}' on env variable '{key}'.",
                "Remove hardcoded secrets from -e flags; use runtime secret mounts or `balorsh password`.",
            )
            break

for e in extra_envs:
    check_env_entry(e)

if inspect_path:
    insp = json.loads(Path(inspect_path).read_text(encoding="utf-8"))
    ns = insp.get("NetworkSettings") or {}
    ips = set()
    if ns.get("IPAddress"):
        ips.add(ns["IPAddress"])
    for net in (ns.get("Networks") or {}).values():
        if isinstance(net, dict) and net.get("IPAddress"):
            ips.add(net["IPAddress"])
    hc = insp.get("HostConfig") or {}
    pb = hc.get("PortBindings") or {}
    for cport, bindings in pb.items():
        if isinstance(bindings, list):
            for b in bindings:
                hip = (b.get("HostIp") or "127.0.0.1") if isinstance(b, dict) else "127.0.0.1"
                hport = (b.get("HostPort") or "") if isinstance(b, dict) else ""
                endpoints.append({"host_ip": hip, "host_port": hport, "container_port": cport, "container_ips": sorted(ips)})
    if endpoints:
        add_finding("INFO", "attack-surface", f"Discovered {len(endpoints)} published port(s)", json.dumps(endpoints), "Audit exposed ports with `balorsh networkscan` / `webexploit`.")

    # 6A.3 Purple-Team Policy Review
    if policy.get("require_read_only") and not hc.get("ReadonlyRootfs", False):
        add_finding("HIGH", "purple-team", "Container rootfs is writable", "HostConfig.ReadonlyRootfs is false.", "Pass --read-only or --profile=sandbox.")
    if policy.get("require_cap_drop_all") and "ALL" not in (hc.get("CapDrop") or []):
        add_finding("HIGH", "purple-team", "CapDrop does not include ALL", f"CapDrop={hc.get('CapDrop')}", "Pass --cap-drop=ALL.")
    if policy.get("forbid_cap_add") and (hc.get("CapAdd") or []):
        add_finding("HIGH", "purple-team", "Extra capabilities granted", f"CapAdd={hc.get('CapAdd')}", "Remove --cap-add flags.")
    if policy.get("require_no_new_privileges") and "no-new-privileges" not in (hc.get("SecurityOpt") or []):
        add_finding("HIGH", "purple-team", "no-new-privileges missing", f"SecurityOpt={hc.get('SecurityOpt')}", "Pass --no-new-privileges.")
    if hc.get("NetworkMode") == "host":
        add_finding("CRITICAL", "purple-team", "Host network namespace shared", "HostConfig.NetworkMode is 'host'.", "Use --network=none or bridge.")
    if (hc.get("PidsLimit") or 0) <= 0:
        add_finding("MEDIUM", "purple-team", "No PIDs limit enforced", f"PidsLimit={hc.get('PidsLimit')}", "Set --pids-limit=64.")

    # 6A.4 Config.Env check
    cfg = insp.get("Config") or {}
    for env_entry in (cfg.get("Env") or []):
        check_env_entry(env_entry)

report = {
    "mode": "balor+offline" if balor_available else "offline-deterministic",
    "balor_available": balor_available,
    "audit_log": audit_stats,
    "error_log_lines": error_lines,
    "endpoints": endpoints,
    "secret_hits": secret_hits,
    "findings": findings,
}

if json_out:
    print(json.dumps(report, indent=2))
elif quiet:
    high_cnt = sum(1 for f in findings if f["severity"] in ("HIGH", "CRITICAL"))
    print(f"balor-audit ({report['mode']}): audit_entries={audit_stats['total']} denies={audit_stats['deny']} error_lines={error_lines} high_findings={high_cnt}")
else:
    lines = [
        f"# ZigPod Security Audit Report ({report['mode']})",
        f"- audit.log entries: {audit_stats['total']} (DENY={audit_stats['deny']}, ERROR={audit_stats['error']}, malformed={audit_stats['malformed']})",
        f"- error.log non-empty lines: {error_lines}",
        f"- discovered endpoints: {len(endpoints)}",
        f"- secret/hash hygiene hits: {len(secret_hits)}",
        "",
        "## Findings",
    ]
    if not findings:
        lines.append("- None (all checked policies passed).")
    else:
        for f in findings:
            lines.append(f"- [{f['severity']}] ({f['category']}) {f['title']}: {f['detail']}")
            if f["recommendation"]:
                lines.append(f"  - Recommendation: {f['recommendation']}")
    print("\n".join(lines))
PYEOF
)"

if [[ "$USE_LLM" == "true" ]]; then
    if [[ "$BALOR_AVAILABLE" == "true" ]]; then
        echo "--> Piping sanitized audit summary to balorsh llm (loganalyst)..." >&2
        printf '%s\n' "$REPORT_OUT" | "$BALOR_BIN" llm --persona loganalyst 2>/dev/null || true
    else
        echo "WARN: --llm requested, but balorsh is not initialized at $BALOR_DATA; using offline report." >&2
    fi
fi

if [[ "$RUN_SCAN" == "true" && "$BALOR_AVAILABLE" == "true" ]]; then
    echo "--> balorsh scan integration ready (networkscan/webexploit)." >&2
fi

if [[ -n "$OUT_FILE" ]]; then
    printf '%s\n' "$REPORT_OUT" > "$OUT_FILE"
fi
printf '%s\n' "$REPORT_OUT"
