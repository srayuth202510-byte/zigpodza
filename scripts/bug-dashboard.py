#!/usr/bin/env python3
"""Hybrid Bug Tracking & Security Gate Dashboard for ZigPod.

Aggregates bug patterns from docs/vault/Bug-Playbook.md, module unit tests &
allocator invariants from src/*.zig, static security gates, and runtime logs
(system.log, error.log, audit.log).

Usage:
  scripts/bug-dashboard.py [summary] [--json]
  scripts/bug-dashboard.py generate [--json]
  scripts/bug-dashboard.py serve [--host 127.0.0.1] [--port 8765]
"""

from __future__ import annotations

import argparse
import html
import http.server
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
PLAYBOOK_PATH = ROOT / "docs" / "vault" / "Bug-Playbook.md"
DASHBOARD_MD_PATH = ROOT / "docs" / "vault" / "Bug-Dashboard.md"
DASHBOARD_HTML_PATH = ROOT / ".zig-cache" / "bug-dashboard.html"
SRC_DIR = ROOT / "src"

BUG_HEADING_RE = re.compile(r"^##\s+(BUG-\d+):\s*(.+)$")
INLINE_TAG_RE = re.compile(r"\s*`?(#[a-zA-Z0-9_-]+)`?")
FILE_REF_RE = re.compile(
    r"(?:src/[A-Za-z0-9_.-]+\.zig|scripts/[A-Za-z0-9_.-]+\.(?:sh|py)|\.github/workflows/[A-Za-z0-9_.-]+\.yml)"
)
ZIG_PUB_RE = re.compile(r"^\s*pub\s+(?:fn|const)\s+([A-Za-z_][A-Za-z0-9_]*)")
ZIG_TEST_RE = re.compile(r'^\s*test\s+"([^"]+)"')


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.is_file() else ""


def clean_markdown_inline(text: str) -> str:
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"`\1`", text)
    return " ".join(text.split())


def parse_bugs(playbook_path: Path = PLAYBOOK_PATH) -> list[dict[str, Any]]:
    if not playbook_path.is_file():
        return []

    lines = playbook_path.read_text(encoding="utf-8").splitlines()
    raw_sections: list[tuple[str, str, list[str], int, int, int]] = []
    current: dict[str, Any] | None = None

    for idx, line in enumerate(lines, start=1):
        m = BUG_HEADING_RE.match(line)
        if m:
            if current is not None:
                raw_sections.append((
                    current["id"],
                    current["title"],
                    current["tags"],
                    current["line"],
                    current["start_idx"],
                    idx - 1,
                ))
            raw_title = m.group(2)
            tags = INLINE_TAG_RE.findall(raw_title)
            title = INLINE_TAG_RE.sub("", raw_title).strip()
            current = {
                "id": m.group(1),
                "title": title,
                "tags": tags or ["#bug-pattern"],
                "line": idx,
                "start_idx": idx,
            }

    if current is not None:
        raw_sections.append((
            current["id"],
            current["title"],
            current["tags"],
            current["line"],
            current["start_idx"],
            len(lines),
        ))

    bugs: list[dict[str, Any]] = []
    for bug_id, title, tags, start_line, start_idx, end_idx in raw_sections:
        block_lines = lines[start_idx:end_idx]
        block_text = "\n".join(block_lines)
        fields = {"symptom": "", "root_cause": "", "fix": "", "prevention": ""}
        active_key: str | None = None

        for raw in block_lines:
            s = raw.strip()
            if s.startswith("- **Symptom**:"):
                active_key = "symptom"
                fields["symptom"] = clean_markdown_inline(s.split(":", 1)[1].strip())
            elif s.startswith("- **Root Cause**:"):
                active_key = "root_cause"
                fields["root_cause"] = clean_markdown_inline(s.split(":", 1)[1].strip())
            elif s.startswith("- **Fix**:"):
                active_key = "fix"
                val = s.split(":", 1)[1].strip()
                fields["fix"] = clean_markdown_inline(val)
            elif s.startswith("- **Prevention Rule**:"):
                active_key = "prevention"
                fields["prevention"] = clean_markdown_inline(s.split(":", 1)[1].strip())
            elif s.startswith("- ") and active_key == "fix":
                piece = clean_markdown_inline(s[2:].strip())
                fields["fix"] = f"{fields['fix']}; {piece}".strip("; ")
            elif s == "---":
                active_key = None

        norm_block = block_text.replace("../../", "")
        files = list(dict.fromkeys(FILE_REF_RE.findall(norm_block)))
        all_exist = bool(files) and all((ROOT / f).exists() for f in files)
        bugs.append({
            "id": bug_id,
            "title": title,
            "tags": tags,
            "line": start_line,
            "cite": f"docs/vault/Bug-Playbook.md:{start_line}",
            "status": "Guarded" if all_exist else "Needs Check",
            "files": files,
            **fields,
        })

    return bugs


def parse_modules(src_dir: Path = SRC_DIR) -> list[dict[str, Any]]:
    modules: list[dict[str, Any]] = []
    for path in sorted(src_dir.glob("*.zig")):
        rel = path.relative_to(ROOT).as_posix()
        text = path.read_text(encoding="utf-8")
        lines = text.splitlines()
        pub_symbols = []
        tests = []
        for lineno, line in enumerate(lines, start=1):
            m_pub = ZIG_PUB_RE.match(line)
            if m_pub:
                pub_symbols.append({"name": m_pub.group(1), "cite": f"{rel}:{lineno}"})
            m_test = ZIG_TEST_RE.match(line)
            if m_test:
                tests.append({"name": m_test.group(1), "line": lineno, "cite": f"{rel}:{lineno}"})

        uses_testing_alloc = "std.testing.allocator" in text
        if path.name == "main.zig":
            alloc_gate = "gpa.deinit() != .leak" if "gpa.deinit() == .leak" in text else "missing gpa check"
        elif path.name == "utils.zig":
            alloc_gate = "stack-only (no heap)"
        else:
            alloc_gate = "std.testing.allocator" if uses_testing_alloc else "MISSING"

        modules.append({
            "name": path.name,
            "file": rel,
            "lines": len(lines),
            "pub_count": len(pub_symbols),
            "test_count": len(tests),
            "tests": tests,
            "uses_testing_allocator": uses_testing_alloc,
            "allocator_gate": alloc_gate,
        })
    return modules


def evaluate_static_gates() -> list[dict[str, Any]]:
    src_texts = {p.relative_to(ROOT).as_posix(): read_text(p) for p in sorted(SRC_DIR.glob("*.zig"))}
    all_src = "\n".join(src_texts.values())

    cli_txt = "\n".join(txt for path, txt in src_texts.items() if path.startswith("src/cli"))
    http_txt = "\n".join(txt for path, txt in src_texts.items() if path.startswith("src/http"))
    pod_txt = "\n".join(txt for path, txt in src_texts.items() if path.startswith("src/podman_"))
    log_txt = src_texts.get("src/log.zig", "")
    demo_txt = src_texts.get("src/demo.zig", "")

    req_execs = (
        "scripts/check-ci-parity.py",
        "scripts/graph-query.py",
        "scripts/knowledge-sync.py",
        "scripts/smoke.sh",
        ".githooks/pre-commit",
    )
    exec_ok = all((ROOT / s).is_file() and os.access(ROOT / s, os.X_OK) for s in req_execs)
    test_alloc_mods = ("src/cli.zig", "src/config.zig", "src/http.zig", "src/podman_api.zig", "src/log.zig", "src/demo.zig")

    gates = [
        ("No page_allocator in src/", "BUG-002", "page_allocator" not in all_src),
        ("GPA leak check enforced in main.zig", "BUG-002", "defer _ = gpa.deinit" not in all_src and "gpa.deinit() == .leak" in src_texts.get("src/main.zig", "")),
        ("No error.AccessDenied in http.zig", "BUG-001", "error.AccessDenied" not in http_txt),
        ("std.testing.allocator in heap modules", "BUG-002", all("std.testing.allocator" in src_texts.get(m, "") for m in test_alloc_mods)),
        ("validateRequestTarget() in http.zig", "BUG-005", "try validateRequestTarget(" in http_txt),
        ("validateIdentifier() in podman_api.zig", "BUG-005", "try validateIdentifier(" in pod_txt),
        ("Checked arithmetic std.math.add/mul", "BUG-004", "std.math.add" in http_txt and "std.math.add" in pod_txt and "std.math.mul" in cli_txt),
        ("Timeout poll, HostConfig hardening, audit chain & demo", "Security", all([
            "waitReadable" in http_txt,
            "verifyAuditFile" in log_txt,
            "ReadonlyRootfs" in pod_txt,
            "runSelfTest" in demo_txt,
        ])),
        ("Verification scripts executable (+x)", "BUG-006", exec_ok),
    ]
    return [{"name": name, "bug_ref": bug_ref, "passed": bool(ok)} for name, bug_ref, ok in gates]


def read_logs(tail_n: int = 12) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for name in ("system.log", "error.log", "audit.log"):
        p = ROOT / name
        if p.is_file():
            lines = p.read_text(encoding="utf-8", errors="replace").splitlines()
            mode = oct(p.stat().st_mode & 0o777)[2:]
            out[name] = {
                "exists": True,
                "lines": len(lines),
                "bytes": p.stat().st_size,
                "mode": mode,
                "tail": lines[-tail_n:],
            }
        else:
            out[name] = {"exists": False, "lines": 0, "bytes": 0, "mode": "-", "tail": []}
    return out


def build_report(include_logs: bool = True) -> dict[str, Any]:
    bugs = parse_bugs()
    modules = parse_modules()
    gates = evaluate_static_gates()

    guarded_bugs = sum(1 for b in bugs if b["status"] == "Guarded")
    passed_gates = sum(1 for g in gates if g["passed"])
    total_tests = sum(m["test_count"] for m in modules)

    report: dict[str, Any] = {
        "summary": {
            "total_bugs": len(bugs),
            "guarded_bugs": guarded_bugs,
            "module_count": len(modules),
            "unit_tests": total_tests,
            "gates_passed": passed_gates,
            "gates_total": len(gates),
        },
        "bugs": bugs,
        "modules": modules,
        "gates": gates,
    }
    if include_logs:
        report["logs"] = read_logs()
    return report


def render_markdown(report: dict[str, Any]) -> str:
    s = report["summary"]
    lines = [
        "---",
        "tags:",
        "  - dashboard",
        "  - bug-pattern",
        "  - memory-safety",
        "  - security-gate",
        "aliases:",
        "  - Bug Tracking Dashboard",
        "status: active",
        "---",
        "",
        "# ZigPod Bug Tracking & Security Dashboard",
        "",
        "กลับไปที่ [[00-Index]] · คู่มือบั๊กที่ [[Bug-Playbook]] · แผนผังระบบ [[Architecture-Map]] · เช็กลิสต์ [[Security-And-Memory-Checklist]]",
        "",
        "> สร้างอัตโนมัติจาก [scripts/bug-dashboard.py](../../scripts/bug-dashboard.py) (`make dashboard` / `make bugs` / `make dashboard-serve`)",
        "",
        "## Overview Metrics",
        "",
        "| Metric | Value |",
        "| :--- | :--- |",
        f"| Tracked Bug Patterns | **{s['total_bugs']}** ({s['guarded_bugs']} Guarded) |",
        f"| Zig Source Modules | **{s['module_count']}** |",
        f"| Unit & Integration Tests | **{s['unit_tests']}** |",
        f"| Static Security & Memory Gates | **{s['gates_passed']}/{s['gates_total']} PASS** |",
        "",
        "## Guard Coverage Map",
        "",
        "```mermaid",
        "flowchart LR",
        "    PLAYBOOK[\"[[Bug-Playbook]]\"] --> DASH[\"[[Bug-Dashboard]]\"]",
    ]

    for b in report["bugs"]:
        bid = b["id"].replace("-", "")
        lines.append(f"    {bid}[\"{b['id']}\"] --> SEC[\"[[Security-And-Memory-Checklist]]\"]")
        for f in b["files"][:2]:
            node = re.sub(r"[^A-Za-z0-9]", "_", f)
            lines.append(f"    {bid} --> {node}[\"{f}\"]")
    lines.extend(["```", "", "## Bug Pattern Registry", ""])
    lines.append("| ID | Title | Tags | Guarded Files | Status |")
    lines.append("| :--- | :--- | :--- | :--- | :--- |")
    for b in report["bugs"]:
        tags_str = " ".join(f"`{t}`" for t in b["tags"])
        files_str = ", ".join(f"[{Path(f).name}](../../{f})" for f in b["files"]) or "-"
        lines.append(
            f"| [{b['id']}](../../{b['cite'].replace(':', '#L')}) | {b['title']} | {tags_str} | {files_str} | **{b['status']}** |"
        )

    lines.extend(["", "## Module Test & Allocator Coverage", ""])
    lines.append("| Module | Lines | Public Decls | Unit Tests | Memory Gate |")
    lines.append("| :--- | ---: | ---: | ---: | :--- |")
    for m in report["modules"]:
        lines.append(
            f"| [{m['name']}](../../{m['file']}) | {m['lines']} | {m['pub_count']} | {m['test_count']} | `{m['allocator_gate']}` |"
        )

    lines.extend(["", "## Static Security & Memory Gates", ""])
    lines.append("| Gate | Bug Ref | Result |")
    lines.append("| :--- | :--- | :--- |")
    for g in report["gates"]:
        badge = "PASS" if g["passed"] else "FAIL"
        lines.append(f"| {g['name']} | {g['bug_ref']} | **{badge}** |")

    lines.extend(["", "## Tracked Bug Details", ""])
    for b in report["bugs"]:
        lines.append(f"### {b['id']} — {b['title']}")
        lines.append(f"- **Source**: [{b['cite']}](../../{b['cite'].replace(':', '#L')}) · **Status**: `{b['status']}`")
        if b["symptom"]:
            lines.append(f"- **Symptom**: {b['symptom']}")
        if b["root_cause"]:
            lines.append(f"- **Root Cause**: {b['root_cause']}")
        if b["fix"]:
            lines.append(f"- **Fix**: {b['fix']}")
        if b["prevention"]:
            lines.append(f"- **Prevention**: {b['prevention']}")
        lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def render_html(report: dict[str, Any]) -> str:
    safe_json = json.dumps(report, ensure_ascii=False).replace("</", "<\\/")
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ZigPod Bug Tracking &amp; Security Dashboard</title>
<style>
  :root {{
    --bg: #0f141c; --panel: #161d28; --border: #273244; --text: #e6edf3;
    --muted: #8b9bb0; --accent: #58a6ff; --ok: #3fb950; --warn: #d29922; --bad: #f85149;
  }}
  * {{ box-sizing: border-box; }}
  body {{ margin: 0; font-family: ui-sans-serif, system-ui, -apple-system, sans-serif; background: var(--bg); color: var(--text); line-height: 1.5; }}
  header {{ padding: 20px 28px; border-bottom: 1px solid var(--border); display: flex; flex-wrap: wrap; gap: 12px; align-items: center; justify-content: space-between; background: #121822; }}
  header h1 {{ margin: 0; font-size: 1.25rem; }}
  .sub {{ color: var(--muted); font-size: 0.9rem; }}
  main {{ max-width: 1220px; margin: 0 auto; padding: 22px 28px 48px; display: grid; gap: 22px; }}
  .kpis {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 14px; }}
  .kpi {{ background: var(--panel); border: 1px solid var(--border); border-radius: 10px; padding: 14px 16px; }}
  .kpi .label {{ color: var(--muted); font-size: 0.8rem; text-transform: uppercase; letter-spacing: .04em; }}
  .kpi .val {{ font-size: 1.65rem; font-weight: 700; margin-top: 4px; }}
  .card {{ background: var(--panel); border: 1px solid var(--border); border-radius: 10px; padding: 18px; }}
  .toolbar {{ display: flex; flex-wrap: wrap; gap: 10px; align-items: center; justify-content: space-between; margin-bottom: 14px; }}
  .filters {{ display: flex; flex-wrap: wrap; gap: 8px; }}
  input[type="search"] {{ background: var(--bg); color: var(--text); border: 1px solid var(--border); border-radius: 8px; padding: 8px 12px; min-width: 240px; }}
  button {{ background: #1f2937; color: var(--text); border: 1px solid var(--border); border-radius: 8px; padding: 7px 12px; cursor: pointer; font-size: 0.85rem; }}
  button.active {{ border-color: var(--accent); color: var(--accent); background: rgba(88, 166, 255, .12); }}
  button.primary {{ background: #1f6feb; border-color: #388bfd; font-weight: 600; }}
  table {{ width: 100%; border-collapse: collapse; font-size: 0.9rem; }}
  th, td {{ text-align: left; padding: 10px 8px; border-bottom: 1px solid var(--border); vertical-align: top; }}
  th {{ color: var(--muted); font-weight: 600; font-size: 0.8rem; text-transform: uppercase; }}
  .badge {{ display: inline-block; padding: 2px 8px; border-radius: 999px; font-size: 0.76rem; font-weight: 600; }}
  .ok {{ background: rgba(63,185,80,.15); color: var(--ok); }}
  .bad {{ background: rgba(248,81,73,.15); color: var(--bad); }}
  .tag {{ background: rgba(88,166,255,.12); color: var(--accent); margin-right: 4px; }}
  .grid-2 {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(360px, 1fr)); gap: 18px; }}
  .bar-bg {{ background: var(--bg); height: 8px; border-radius: 999px; overflow: hidden; margin-top: 6px; }}
  .bar-fill {{ background: var(--ok); height: 100%; }}
  pre {{ background: var(--bg); border: 1px solid var(--border); border-radius: 8px; padding: 12px; overflow-x: auto; font-size: 0.8rem; max-height: 240px; margin: 0; }}
  details summary {{ cursor: pointer; color: var(--accent); font-size: 0.85rem; }}
  .muted {{ color: var(--muted); font-size: 0.85rem; }}
</style>
</head>
<body>
<header>
  <div>
    <h1>ZigPod Bug Tracking &amp; Security Dashboard</h1>
    <div class="sub">Knowledge Vault + Unit Test Coverage + Static Security Gates + Runtime Logs</div>
  </div>
  <div style="display:flex;gap:8px;align-items:center;">
    <span id="audit-msg" class="muted"></span>
    <button class="primary" onclick="runAudit()">Run Auto-Audit</button>
  </div>
</header>
<main>
  <section class="kpis" id="kpis"></section>

  <section class="card">
    <div class="toolbar">
      <div class="filters" id="tag-filters"></div>
      <input type="search" id="search" placeholder="Search BUG-NNN, symptom, root cause, file...">
    </div>
    <table>
      <thead><tr><th>ID</th><th>Bug Pattern</th><th>Tags</th><th>Guarded Files</th><th>Status</th></tr></thead>
      <tbody id="bug-rows"></tbody>
    </table>
  </section>

  <section class="grid-2">
    <div class="card">
      <h2 style="margin-top:0;font-size:1.05rem;">Module Unit Tests &amp; Allocator Gates</h2>
      <div id="modules"></div>
    </div>
    <div class="card">
      <h2 style="margin-top:0;font-size:1.05rem;">Static Security &amp; Memory Gates</h2>
      <table>
        <thead><tr><th>Gate</th><th>Ref</th><th>Status</th></tr></thead>
        <tbody id="gates"></tbody>
      </table>
    </div>
  </section>

  <section class="card">
    <h2 style="margin-top:0;font-size:1.05rem;">Runtime Logs Tail</h2>
    <div class="grid-2" id="logs"></div>
  </section>
</main>
<script>
let DATA = {safe_json};
let activeTag = "ALL";
let searchQuery = "";

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}}[c]));

function render() {{
  const s = DATA.summary;
  document.getElementById("kpis").innerHTML = [
    ["Bug Patterns", `${{s.guarded_bugs}}/${{s.total_bugs}} Guarded`],
    ["Unit Tests", s.unit_tests],
    ["Zig Modules", s.module_count],
    ["Static Gates", `${{s.gates_passed}}/${{s.gates_total}} PASS`],
  ].map(([label, val]) => `<div class="kpi"><div class="label">${{esc(label)}}</div><div class="val">${{esc(val)}}</div></div>`).join("");

  const tags = ["ALL", ...new Set(DATA.bugs.flatMap(b => b.tags))];
  document.getElementById("tag-filters").innerHTML = tags.map(t =>
    `<button class="${{activeTag === t ? 'active' : ''}}" onclick="setTag('${{esc(t)}}')">${{esc(t)}}</button>`
  ).join("");

  const q = searchQuery.toLowerCase();
  const bugs = DATA.bugs.filter(b => {{
    const tagOk = activeTag === "ALL" || b.tags.includes(activeTag);
    const hay = `${{b.id}} ${{b.title}} ${{b.symptom}} ${{b.root_cause}} ${{b.fix}} ${{b.prevention}} ${{b.files.join(" ")}}`.toLowerCase();
    return tagOk && (!q || hay.includes(q));
  }});

  document.getElementById("bug-rows").innerHTML = bugs.map(b => `
    <tr>
      <td><strong>${{esc(b.id)}}</strong><div class="muted">${{esc(b.cite)}}</div></td>
      <td>
        <div><strong>${{esc(b.title)}}</strong></div>
        <details style="margin-top:4px;"><summary>Details (Symptom / Fix / Rule)</summary>
          <div class="muted" style="margin-top:6px;">
            <div><b>Symptom:</b> ${{esc(b.symptom)}}</div>
            <div><b>Root Cause:</b> ${{esc(b.root_cause)}}</div>
            <div><b>Fix:</b> ${{esc(b.fix)}}</div>
            <div><b>Prevention:</b> ${{esc(b.prevention)}}</div>
          </div>
        </details>
      </td>
      <td>${{b.tags.map(t => `<span class="badge tag">${{esc(t)}}</span>`).join("")}}</td>
      <td><code>${{esc(b.files.join(", ") || "-")}}</code></td>
      <td><span class="badge ${{b.status === 'Guarded' ? 'ok' : 'bad'}}">${{esc(b.status)}}</span></td>
    </tr>
  `).join("") || '<tr><td colspan="5" class="muted">No matching bug patterns.</td></tr>';

  const maxTests = Math.max(1, ...DATA.modules.map(m => m.test_count));
  document.getElementById("modules").innerHTML = DATA.modules.map(m => `
    <div style="margin-bottom:12px;">
      <div style="display:flex;justify-content:space-between;font-size:0.9rem;">
        <span><strong>${{esc(m.file)}}</strong> <span class="muted">(${{m.lines}} lines, ${{m.pub_count}} pub)</span></span>
        <span>${{m.test_count}} tests · <code>${{esc(m.allocator_gate)}}</code></span>
      </div>
      <div class="bar-bg"><div class="bar-fill" style="width:${{Math.round((m.test_count / maxTests) * 100)}}%"></div></div>
    </div>
  `).join("");

  document.getElementById("gates").innerHTML = DATA.gates.map(g => `
    <tr>
      <td>${{esc(g.name)}}</td>
      <td><code>${{esc(g.bug_ref)}}</code></td>
      <td><span class="badge ${{g.passed ? 'ok' : 'bad'}}">${{g.passed ? 'PASS' : 'FAIL'}}</span></td>
    </tr>
  `).join("");

  const logs = DATA.logs || {{}};
  document.getElementById("logs").innerHTML = Object.entries(logs).map(([name, info]) => `
    <div>
      <div style="display:flex;justify-content:space-between;margin-bottom:6px;">
        <strong>${{esc(name)}}</strong>
        <span class="muted">${{info.exists ? `${{info.lines}} lines · mode ${{esc(info.mode)}}` : 'not created yet'}}</span>
      </div>
      <pre>${{esc((info.tail || []).join("\\n") || "(empty)")}}</pre>
    </div>
  `).join("");
}}

function setTag(t) {{ activeTag = t; render(); }}
document.getElementById("search").addEventListener("input", (e) => {{ searchQuery = e.target.value; render(); }});

async function runAudit() {{
  const el = document.getElementById("audit-msg");
  if (location.protocol === "file:") {{
    el.textContent = "Start 'make dashboard-serve' to run live audit from browser.";
    return;
  }}
  el.textContent = "Running ./scripts/auto-audit.sh...";
  try {{
    const res = await fetch("/api/audit", {{ method: "POST" }});
    const payload = await res.json();
    DATA = payload.report;
    render();
    el.textContent = `auto-audit exit=${{payload.audit_exit}}`;
  }} catch (err) {{
    el.textContent = "Audit request failed: " + err;
  }}
}}

render();
</script>
</body>
</html>
"""


def print_cli_summary(report: dict[str, Any]) -> None:
    s = report["summary"]
    print("=== ZigPod Bug Tracking & Security Dashboard ===")
    print(
        f"Bugs: {s['guarded_bugs']}/{s['total_bugs']} Guarded | "
        f"Modules: {s['module_count']} | Unit Tests: {s['unit_tests']} | "
        f"Static Gates: {s['gates_passed']}/{s['gates_total']}"
    )
    print("\nBug Registry:")
    for b in report["bugs"]:
        files = ", ".join(b["files"]) if b["files"] else "-"
        print(f"  - [{b['status']}] {b['id']}: {b['title']} ({b['cite']}) -> {files}")

    print("\nModule Coverage:")
    for m in report["modules"]:
        print(f"  - {m['file']:<22} {m['lines']:>4} lines | {m['test_count']:>2} tests | gate: {m['allocator_gate']}")

    print("\nStatic Gates:")
    for g in report["gates"]:
        mark = "PASS" if g["passed"] else "FAIL"
        print(f"  - [{mark}] {g['name']} ({g['bug_ref']})")

    if "logs" in report:
        print("\nLogs:")
        for name, info in report["logs"].items():
            status = f"{info['lines']} lines (mode {info['mode']})" if info["exists"] else "absent"
            print(f"  - {name:<12} {status}")


class DashboardHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path in ("/", "/index.html"):
            body = render_html(build_report()).encode("utf-8")
            self._send(200, "text/html; charset=utf-8", body)
        elif self.path == "/api/status":
            body = json.dumps(build_report(), ensure_ascii=False).encode("utf-8")
            self._send(200, "application/json; charset=utf-8", body)
        else:
            self._send(404, "text/plain; charset=utf-8", b"Not Found")

    def do_POST(self) -> None:
        if self.path != "/api/audit":
            self._send(404, "text/plain; charset=utf-8", b"Not Found")
            return
        proc = subprocess.run(
            [str(ROOT / "scripts" / "auto-audit.sh")],
            cwd=str(ROOT),
            capture_output=True,
            text=True,
        )
        payload = {
            "audit_exit": proc.returncode,
            "audit_output": proc.stdout + proc.stderr,
            "report": build_report(),
        }
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self._send(200, "application/json; charset=utf-8", body)

    def _send(self, code: int, content_type: str, body: bytes) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
        return


def create_server(host: str = "127.0.0.1", port: int = 8765) -> http.server.ThreadingHTTPServer:
    return http.server.ThreadingHTTPServer((host, port), DashboardHandler)


def cmd_generate(as_json: bool) -> int:
    # Deterministic Markdown omits volatile runtime log counts; HTML includes full live logs.
    det_report = build_report(include_logs=False)
    DASHBOARD_MD_PATH.write_text(render_markdown(det_report), encoding="utf-8")

    live_report = build_report(include_logs=True)
    DASHBOARD_HTML_PATH.parent.mkdir(parents=True, exist_ok=True)
    DASHBOARD_HTML_PATH.write_text(render_html(live_report), encoding="utf-8")

    if as_json:
        print(json.dumps(live_report, indent=2, ensure_ascii=False))
    else:
        print_cli_summary(live_report)
        print(
            f"\nGenerated: {DASHBOARD_MD_PATH.relative_to(ROOT).as_posix()}, "
            f"{DASHBOARD_HTML_PATH.relative_to(ROOT).as_posix()}"
        )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="ZigPod Bug Tracking Dashboard")
    sub = parser.add_subparsers(dest="cmd")

    p_sum = sub.add_parser("summary", help="Print terminal dashboard summary")
    p_sum.add_argument("--json", action="store_true")

    p_gen = sub.add_parser("generate", help="Generate docs/vault/Bug-Dashboard.md and HTML dashboard")
    p_gen.add_argument("--json", action="store_true")

    p_srv = sub.add_parser("serve", help="Start local interactive web dashboard server")
    p_srv.add_argument("--host", default="127.0.0.1")
    p_srv.add_argument("--port", type=int, default=8765)

    args = parser.parse_args()
    cmd = args.cmd or "summary"

    if cmd == "summary":
        report = build_report(include_logs=True)
        if getattr(args, "json", False):
            print(json.dumps(report, indent=2, ensure_ascii=False))
        else:
            print_cli_summary(report)
        return 0
    if cmd == "generate":
        return cmd_generate(getattr(args, "json", False))
    if cmd == "serve":
        srv = create_server(args.host, args.port)
        actual_port = srv.server_address[1]
        print(f"ZigPod Bug Dashboard serving on http://{args.host}:{actual_port} (Ctrl+C to stop)")
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            print("\nShutting down dashboard server.")
        finally:
            srv.server_close()
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
