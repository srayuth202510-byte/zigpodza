#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BALOR_BIN="${BALOR_BIN:-/usr/local/bin/balorsh}"
BALOR_DATA="${BALORSH_DATA_DIR:-/opt/balorsh/data}"
OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"

MODE="audit"
JSON_OUT=false
QUIET=false
USE_LLM=false
RUN_SCAN=false
SCAN_DEEP=false
INSPECT_FILE=""
CONTAINER=""
OUT_FILE=""
PERSONA="loganalyst"
SCAN_TIMEOUT="${SCAN_TIMEOUT:-120}"
LLM_TIMEOUT="${LLM_TIMEOUT:-600}"
OUT_DIR=""
ENV_ITEMS=()

usage() {
    cat <<'EOF'
Usage: scripts/balor-security-audit.sh [OPTIONS]

Phase 6A Deep Balor & Offline Security Audit Pipeline for ZigPod:
  --offline             Force deterministic offline rule-based analysis only
                        (disables --llm and --run-scan; default when balorsh is unavailable)
  --json                Emit structured JSON report
  --quiet               Compact one-line summary (for security-check.sh)
  --llm                 Generate a live Incident & Threat Report via Ollama
                        (balor:<persona>; deterministic offline report when Ollama is down)
  --persona NAME        balor persona model to use: loganalyst|blueteam|purpleteam|redteam|base
                        (default: loganalyst; created from Modelfile.<persona> on demand)
  --inspect-json FILE   Audit a ContainerInspect JSON file (6A.2 surface + 6A.3 purple-team + 6A.4 env hygiene)
  --container NAME      Run `zigpod inspect --json NAME` and audit the live container
  --env KEY=VALUE       Check an environment variable for secret/hash hygiene (repeatable)
  --run-scan            Execute real scanners (nmap -sV, whatweb) against discovered endpoints
  --scan-deep           Additionally run nikto and gobuster on HTTP endpoints (slow)
  --scan-timeout SECS   Per-tool timeout for live scans (default: 120)
  --llm-timeout SECS    Timeout for the Ollama inference step (default: 600)
  --out FILE            Write final report to FILE
  -h, --help            Show this help

Environment:
  OLLAMA_URL            Ollama API endpoint (default: http://127.0.0.1:11434)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --offline) USE_LLM=false; RUN_SCAN=false; shift ;;
        --json) JSON_OUT=true; shift ;;
        --quiet) QUIET=true; shift ;;
        --llm) USE_LLM=true; shift ;;
        --persona) PERSONA="${2:-}"; shift 2 ;;
        --run-scan) RUN_SCAN=true; shift ;;
        --scan-deep) SCAN_DEEP=true; shift ;;
        --scan-timeout) SCAN_TIMEOUT="${2:-120}"; shift 2 ;;
        --llm-timeout) LLM_TIMEOUT="${2:-600}"; shift 2 ;;
        --inspect-json) INSPECT_FILE="${2:-}"; shift 2 ;;
        --container) CONTAINER="${2:-}"; shift 2 ;;
        --env) ENV_ITEMS+=("${2:-}"); shift 2 ;;
        --out) OUT_FILE="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$PERSONA" in
    loganalyst|blueteam|purpleteam|redteam|base) ;;
    *) echo "Unknown persona: $PERSONA (expected loganalyst|blueteam|purpleteam|redteam|base)" >&2; exit 2 ;;
esac

BALOR_AVAILABLE=false
if [[ -x "$BALOR_BIN" && -d "$BALOR_DATA" ]]; then
    BALOR_AVAILABLE=true
fi

TMP_INSPECT=""
TMP_EP=""
TMP_SCAN_TARGETS=""
TMP_SCAN_RAW=""
TMP_REPORT=""
cleanup() {
    for f in "$TMP_INSPECT" "$TMP_EP" "$TMP_SCAN_TARGETS" "$TMP_SCAN_RAW" "$TMP_REPORT"; do
        if [[ -n "$f" && -f "$f" ]]; then
            rm -f "$f"
        fi
    done
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

TMP_EP="$(mktemp)"
TMP_REPORT="$(mktemp)"

python3 - "$ROOT_DIR" "$JSON_OUT" "$QUIET" "$INSPECT_FILE" "$BALOR_AVAILABLE" "$TMP_EP" "${ENV_ITEMS[@]+"${ENV_ITEMS[@]}"}" > "$TMP_REPORT" <<'PYEOF'
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
log_dir = Path(os.environ.get("ZIGPOD_LOG_DIR") or root)
json_out = sys.argv[2] == "true"
quiet = sys.argv[3] == "true"
inspect_path = sys.argv[4]
balor_available = sys.argv[5] == "true"
ep_path = sys.argv[6]
extra_envs = sys.argv[7:]

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
audit_file = log_dir / "audit.log"
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
        if level == "DENY" or msg.startswith("DENY rule="):
            audit_stats["deny"] += 1
            audit_stats["recent_denies"].append({"ts": ts, "msg": msg})
        if level == "ERROR":
            audit_stats["error"] += 1
    audit_stats["recent_denies"] = audit_stats["recent_denies"][-10:]
    if audit_stats["malformed"] > 0:
        add_finding(
            "HIGH", "audit-log", "Malformed entries in audit.log",
            f"Found {audit_stats['malformed']} line(s) not matching 5-column hash-chain format.",
            "Run `zigpod audit` to verify hash-chain integrity.",
        )

error_lines = 0
error_file = log_dir / "error.log"
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

def identify_hash_types(value: str) -> list:
    """4b: exact hash-type identification via hashid (balorsh password stack input)."""
    if not shutil.which("hashid"):
        return []
    try:
        out = subprocess.run(
            ["hashid", value], capture_output=True, text=True, timeout=10
        ).stdout
    except Exception:
        return []
    types = []
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("[+]"):
            name = line[3:].strip()
            if name and name.lower() != "unknown hash":
                types.append(name)
    return types

def check_env_entry(entry: str) -> None:
    for kind, pat in SECRET_PATTERNS:
        m = pat.search(entry)
        if m:
            if kind == "sensitive-env-name" and m.group(1).strip() in ("", "changeme", "placeholder"):
                continue
            key = entry.split("=", 1)[0]
            value = entry.split("=", 1)[1] if "=" in entry else entry
            hash_types = identify_hash_types(value) if kind == "password-hash" else []
            hit = {"kind": kind, "key": key}
            if hash_types:
                hit["hash_types"] = hash_types
            secret_hits.append(hit)
            detail = f"Matched rule '{kind}' on env variable '{key}'."
            if hash_types:
                detail += f" hashid identified: {', '.join(hash_types)}."
            add_finding(
                "HIGH", "secret-hygiene", f"Potential secret/hash in env ({key})",
                detail,
                "Remove hardcoded secrets from -e flags; use runtime secret mounts or `balorsh password` (hashid) for exact hash typing.",
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
    import ipaddress
    for cport, bindings in pb.items():
        if isinstance(bindings, list):
            for b in bindings:
                hip = (b.get("HostIp") or "127.0.0.1") if isinstance(b, dict) else "127.0.0.1"
                hport = str(b.get("HostPort") or "") if isinstance(b, dict) else ""
                try:
                    ipaddress.IPv4Address(hip)
                    port_num = int(hport, 10)
                    if not (1 <= port_num <= 65535):
                        raise ValueError("port out of range")
                except ValueError:
                    add_finding(
                        "HIGH", "attack-surface", "Malformed or unsafe PortBindings entry",
                        f"Rejected invalid HostIp='{hip}' or HostPort='{hport}' for {cport}.",
                        "Ensure PortBindings use valid IPv4 literals and ports 1..65535.",
                    )
                    continue
                endpoints.append({"host_ip": hip, "host_port": str(port_num), "container_port": cport, "container_ips": sorted(ips)})
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

Path(ep_path).write_text(json.dumps(endpoints), encoding="utf-8")

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

REPORT_OUT="$(cat "$TMP_REPORT")"

scan_count=0
if [[ "$RUN_SCAN" == "true" ]]; then
    if [[ ! -s "$TMP_EP" || "$(cat "$TMP_EP")" == "[]" ]]; then
        echo "WARN: --run-scan requested but no endpoints discovered (pass --inspect-json or --container)." >&2
    else
        TMP_SCAN_RAW="$(mktemp)"
        TMP_SCAN_TARGETS="$(mktemp)"
        python3 - "$TMP_EP" > "$TMP_SCAN_TARGETS" <<'PYEOF'
import json, sys
from pathlib import Path
for e in json.loads(Path(sys.argv[1]).read_text()):
    if e.get("host_port"):
        print(f"{e.get('host_ip') or '127.0.0.1'}|{e['host_port']}|{e.get('container_port','')}")
PYEOF
        while IFS='|' read -r sip sport _cport; do
            [[ -z "$sport" ]] && continue
            scan_count=$((scan_count + 1))
            surl="http://${sip}:${sport}"
            {
                echo "### target ${sip}:${sport}"
                if command -v nmap >/dev/null 2>&1; then
                    echo "--- nmap -Pn -sV -p ${sport} --open ${sip}"
                    timeout "$SCAN_TIMEOUT" nmap -Pn -sV -p "$sport" --open "$sip" 2>&1 | head -40 || true
                else
                    echo "--- nmap not installed, skipped"
                fi
                if command -v whatweb >/dev/null 2>&1; then
                    echo "--- whatweb ${surl}"
                    timeout "$SCAN_TIMEOUT" whatweb "$surl" --no-errors 2>&1 | sed -e 's/\x1b\[[0-9;]*m//g' | head -20 || true
                else
                    echo "--- whatweb not installed, skipped"
                fi
                if [[ "$SCAN_DEEP" == "true" ]]; then
                    if command -v nikto >/dev/null 2>&1; then
                        echo "--- nikto -h ${surl}"
                        timeout "$SCAN_TIMEOUT" nikto -h "$surl" -nolookup -nossl -ask no 2>&1 | sed -e 's/\x1b\[[0-9;]*m//g' | head -60 || true
                    else
                        echo "--- nikto not installed, skipped"
                    fi
                    if command -v gobuster >/dev/null 2>&1 && [[ -f /usr/share/wordlists/dirb/common.txt ]]; then
                        echo "--- gobuster dir -u ${surl} -w /usr/share/wordlists/dirb/common.txt"
                        timeout "$SCAN_TIMEOUT" gobuster dir -u "$surl" -w /usr/share/wordlists/dirb/common.txt -q 2>&1 | head -40 || true
                    else
                        echo "--- gobuster or wordlist not available, skipped"
                    fi
                fi
                echo
            } >> "$TMP_SCAN_RAW"
        done < "$TMP_SCAN_TARGETS"

        if [[ "$JSON_OUT" == "true" && -s "$TMP_SCAN_RAW" ]]; then
            python3 - "$TMP_REPORT" "$TMP_SCAN_RAW" <<'PYEOF'
import json, sys
from pathlib import Path
rep_path, raw_path = Path(sys.argv[1]), Path(sys.argv[2])
rep = json.loads(rep_path.read_text(encoding="utf-8"))
rep["scans"] = {"target_count": len(rep.get("endpoints", [])), "raw": raw_path.read_text(encoding="utf-8")}
rep_path.write_text(json.dumps(rep, indent=2) + "\n", encoding="utf-8")
PYEOF
        elif [[ "$JSON_OUT" != "true" && -s "$TMP_SCAN_RAW" ]]; then
            {
                echo ""
                echo "## Live Scan Results (${scan_count} target(s))"
                echo ""
                cat "$TMP_SCAN_RAW"
            } >> "$TMP_REPORT"
            REPORT_OUT="$(cat "$TMP_REPORT")"
        fi
    fi
fi

LLM_REPORT_PATH=""
if [[ "$USE_LLM" == "true" ]]; then
    if ! command -v ollama >/dev/null 2>&1; then
        echo "WARN: --llm requested but ollama is not installed; using offline report." >&2
    else
        if ! curl -s --max-time 2 "$OLLAMA_URL/api/version" >/dev/null 2>&1; then
            echo "--> Starting Ollama server in background..." >&2
            nohup ollama serve > /tmp/zigpod-ollama-serve.log 2>&1 &
            _started=false
            for _ in $(seq 1 20); do
                if curl -s --max-time 1 "$OLLAMA_URL/api/version" >/dev/null 2>&1; then
                    _started=true
                    break
                fi
                sleep 1
            done
            if [[ "$_started" != "true" ]]; then
                echo "WARN: Ollama server did not come up; using offline report (see /tmp/zigpod-ollama-serve.log)." >&2
            fi
        fi
        if curl -s --max-time 2 "$OLLAMA_URL/api/version" >/dev/null 2>&1; then
            export OLLAMA_HOST="$OLLAMA_URL"
            if ! ollama list 2>/dev/null | grep -q "balor:$PERSONA"; then
                MODELF="$BALOR_DATA/llm/modelfiles/Modelfile.$PERSONA"
                if [[ -f "$MODELF" ]]; then
                    echo "--> Creating balor:$PERSONA model (first run only)..." >&2
                    ollama create "balor:$PERSONA" -f "$MODELF" >/dev/null 2>&1 || true
                else
                    echo "WARN: Modelfile not found: $MODELF" >&2
                fi
            fi
            if ollama list 2>/dev/null | grep -q "balor:$PERSONA"; then
                PROMPT_BODY="${REPORT_OUT}"
                if [[ -n "$TMP_SCAN_RAW" && -s "$TMP_SCAN_RAW" ]]; then
                    PROMPT_BODY="${PROMPT_BODY}

--- LIVE SCAN OUTPUT ---
$(cat "$TMP_SCAN_RAW")"
                fi
                PROMPT_BODY="$(printf '%s' "$PROMPT_BODY" | head -c 12000)"
                LLM_OUT="$(printf '%s\n' "Analyze the following ZigPod security audit report and scan output. Produce an Incident & Threat Report: [TYPE] -> [TECHNICAL SUMMARY] -> [HYPOTHESES & VECTORS] -> [NEXT STEPS & COMMANDS] -> [RECOMMENDATIONS] for zigpod-policy.json hardening.

${PROMPT_BODY}" | timeout "$LLM_TIMEOUT" ollama run "balor:$PERSONA" 2>/dev/null || true)"
                if [[ -n "${LLM_OUT//[[:space:]]/}" ]]; then
                    mkdir -p "$BALOR_DATA/llm/logs"
                    LLM_REPORT_PATH="$BALOR_DATA/llm/logs/analysis_zigpod_$(LC_ALL=C date +%Y%m%d_%H%M%S).txt"
                    {
                        echo "ZigPod Incident & Threat Report"
                        echo "date: $(date)"
                        echo "persona: balor:$PERSONA"
                        echo "source: scripts/balor-security-audit.sh"
                        echo "=========================================="
                        echo ""
                        echo "$LLM_OUT"
                    } > "$LLM_REPORT_PATH"
                    if [[ "$JSON_OUT" == "true" ]]; then
                        python3 - "$TMP_REPORT" "$LLM_REPORT_PATH" <<'PYEOF'
import json, sys
from pathlib import Path
rep_path, llm_path = Path(sys.argv[1]), Path(sys.argv[2])
rep = json.loads(rep_path.read_text(encoding="utf-8"))
rep["llm_report_path"] = str(llm_path)
rep_path.write_text(json.dumps(rep, indent=2) + "\n", encoding="utf-8")
PYEOF
                    else
                        {
                            echo ""
                            echo "## Incident & Threat Report (balor:$PERSONA)"
                            echo "- Saved to: $LLM_REPORT_PATH"
                            echo ""
                            echo "$LLM_OUT"
                        } >> "$TMP_REPORT"
                    fi
                    REPORT_OUT="$(cat "$TMP_REPORT")"
                else
                    echo "WARN: Ollama produced no output within ${LLM_TIMEOUT}s; using offline report." >&2
                fi
            else
                echo "WARN: balor:$PERSONA model unavailable; using offline report." >&2
            fi
        fi
    fi
fi

REPORT_OUT="$(cat "$TMP_REPORT")"

if [[ -n "$OUT_FILE" ]]; then
    printf '%s\n' "$REPORT_OUT" > "$OUT_FILE"
fi
printf '%s\n' "$REPORT_OUT"
