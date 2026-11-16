#!/usr/bin/env python3
"""Automatic Knowledge Vault, Dashboard & Static Audit Synchronization for ZigPod.

Provides shared synchronization and drift detection for:
  --sync        Rebuild .zig-cache/knowledge-graph.json and docs/vault/Bug-Dashboard.md when needed
  --stop-hook   Antigravity Stop hook: sync deterministic knowledge and request continuation on unrecorded patterns
  --pre-commit  Git pre-commit hook: sync/auto-stage Bug-Dashboard.md and verify vault/audit parity before commit
  --distill     Analyze error.log + Bug-Playbook.md into docs/vault/Lessons-Learned.md (filters transient hook noise)
  --self-test   Run isolated temporary-repo tests covering pass, continue, loop-guard, distill, and pre-commit paths
"""

from __future__ import annotations

import argparse
from collections import Counter
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

DEFAULT_ROOT = Path(__file__).resolve().parent.parent

BUG_TAG_RE = re.compile(r"\bBUG-(\d{3,})\b")
VALIDATE_FN_RE = re.compile(r"\bpub\s+fn\s+(validate[A-Za-z0-9_]+)\s*\(")
INVALID_ERR_RE = re.compile(r"\b(Invalid[A-Z][A-Za-z0-9_]+)\b")
ZIG_STRING_RE = re.compile(r'"(?:\\.|[^"\\])*"')

KNOWLEDGE_GLOBS = (
    "docs/vault/*.md",
    ".agents/rules/*.md",
    "scripts/auto-audit.sh",
)

NOISE_LINE_RES = (
    re.compile(r"auto-audit detected \d+ failure\(s\):"),
    re.compile(r"^FAIL:\s*scripts/security-check\.sh failed:"),
    re.compile(r"^FAIL:\s*Missing executable "),
    re.compile(r"^\+\-\s*zig test "),
    re.compile(r"^(?:test|test transitive failure|\^|Build Summary:.*)$"),
    re.compile(r"^error: the following (?:build )?command failed"),
    re.compile(r"^==>\s*\[\d+/\d+\]"),
)
DIAG_FILE_RE = re.compile(r"(?:\S*/)?(src/[A-Za-z0-9_./]+\.zig):\d+:\d+:\s*(error:\s*.+)$")
STDLIB_DIAG_RE = re.compile(r"\S*/lib/std/([A-Za-z0-9_./]+\.zig):\d+:\d+:\s*(error:\s*.+)$")
GENERIC_ERR_RE = re.compile(r"^(?:\d{4}-\d{2}-\d{2}T\S+\s+\[ERROR\]\s+)?(?:FAIL:\s+.+|error:\s+.+)$")
LEAK_ADDR_RE = re.compile(r"\[gpa\]\s*\(err\):\s*memory address\s+0x[0-9a-fA-F]+\s+leaked")
TEST_FAIL_RE = re.compile(r"^error:\s*'([^']+)' failed:")
ERR_VARIANT_RE = re.compile(r"\berror\.([A-Z][A-Za-z0-9_]+)\b")

RULE_SIGNAL_HINTS: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"switch must handle all possibilities", re.I), ".agents/rules/zig-0.17-gotchas.md"),
    (re.compile(r"never mutated|shadows declaration|shadows primitive|shadows capture", re.I), ".agents/rules/zig-0.17-gotchas.md"),
    (re.compile(r"undeclared identifier 'ApiError'", re.I), ".agents/rules/zig-0.17-gotchas.md"),
    (re.compile(r"expected type 'error\{OutOfMemory\}!void'|jsonStringify|stringify\.zig", re.I), ".agents/rules/zig-0.17-gotchas.md"),
    (re.compile(r"expected type '\[\]u8', found '\[\]const u8'|GenericWriter|ArrayListAligned", re.I), ".agents/rules/zig-0.17-gotchas.md"),
    (re.compile(r"\[gpa\].*leaked|memory address leaked|Segmentation fault|mismatches allocation", re.I), ".agents/rules/memory-and-security.md"),
    (re.compile(r"no member named '(?:net|cwd|getenv|pipe|milliTimestamp|nanoTimestamp|stringify)'|StreamTooLong|testing\.io", re.I), ".agents/rules/zig-0.17-gotchas.md"),
)


def run_cmd(cmd: list[str], cwd: Path, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=cwd,
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
        check=check,
    )


def run_git(root: Path, args: list[str], check: bool = True) -> subprocess.CompletedProcess[str]:
    return run_cmd(["git", *args], cwd=root, check=check)


def has_head(root: Path) -> bool:
    return run_git(root, ["rev-parse", "--verify", "HEAD"], check=False).returncode == 0


def parse_git_status_paths(root: Path) -> set[str]:
    res = run_git(root, ["status", "--porcelain=v1", "-z"], check=False)
    if res.returncode != 0 or not res.stdout:
        return set()
    tokens = res.stdout.split("\0")
    paths: set[str] = set()
    idx = 0
    while idx < len(tokens):
        entry = tokens[idx]
        idx += 1
        if len(entry) < 4:
            continue
        status = entry[:2]
        path = entry[3:]
        if path:
            paths.add(path)
        if "R" in status or "C" in status:
            if idx < len(tokens) and tokens[idx]:
                paths.add(tokens[idx])
            idx += 1
    return paths


def parse_staged_paths(root: Path) -> set[str]:
    res = run_git(root, ["diff", "--cached", "--name-only", "-z", "--diff-filter=ACMR"], check=False)
    if res.returncode != 0 or not res.stdout:
        return set()
    return {p for p in res.stdout.split("\0") if p}


def is_zig_source(rel: str) -> bool:
    return rel.startswith("src/") and rel.endswith(".zig")


def is_vault_note(rel: str) -> bool:
    return rel.startswith("docs/vault/") and rel.endswith(".md")


def needs_graph_sync(paths: set[str], root: Path, force: bool) -> bool:
    if force:
        return True
    graph_script = root / "scripts" / "graph-query.py"
    graph_cache = root / ".zig-cache" / "knowledge-graph.json"
    if graph_script.is_file() and not graph_cache.is_file():
        return True
    return any(
        is_zig_source(p) or is_vault_note(p) or p == "scripts/graph-query.py"
        for p in paths
    )


def needs_dashboard_sync(paths: set[str], force: bool) -> bool:
    if force:
        return True
    return any(
        is_zig_source(p)
        or p in {"docs/vault/Bug-Playbook.md", "scripts/bug-dashboard.py"}
        for p in paths
    )


def sync_knowledge(
    root: Path,
    paths: set[str] | None = None,
    force: bool = False,
    stage_dashboard: bool = False,
) -> dict[str, Any]:
    changed_paths = parse_git_status_paths(root) if paths is None else paths
    actions: list[str] = []
    dashboard_updated = False
    dashboard_path = root / "docs" / "vault" / "Bug-Dashboard.md"
    before_bytes = dashboard_path.read_bytes() if dashboard_path.is_file() else b""

    dash_script = root / "scripts" / "bug-dashboard.py"
    if dash_script.is_file() and needs_dashboard_sync(changed_paths, force):
        res = run_cmd([sys.executable, str(dash_script), "generate"], cwd=root, check=False)
        if res.returncode != 0:
            raise RuntimeError(f"bug-dashboard.py generate failed: {res.stderr.strip() or res.stdout.strip()}")
        actions.append("bug-dashboard")

    after_bytes = dashboard_path.read_bytes() if dashboard_path.is_file() else b""
    if after_bytes != before_bytes:
        dashboard_updated = True
        changed_paths = set(changed_paths) | {"docs/vault/Bug-Dashboard.md"}

    if stage_dashboard and dashboard_path.is_file():
        diff_res = run_git(root, ["diff", "--quiet", "--", "docs/vault/Bug-Dashboard.md"], check=False)
        untracked_res = run_git(
            root,
            ["ls-files", "--others", "--exclude-standard", "--", "docs/vault/Bug-Dashboard.md"],
            check=False,
        )
        if dashboard_updated or diff_res.returncode != 0 or untracked_res.stdout.strip():
            run_git(root, ["add", "docs/vault/Bug-Dashboard.md"], check=True)
            actions.append("stage-dashboard")

    graph_script = root / "scripts" / "graph-query.py"
    if graph_script.is_file() and needs_graph_sync(changed_paths, root, force):
        res = run_cmd([sys.executable, str(graph_script), "update"], cwd=root, check=False)
        if res.returncode != 0:
            raise RuntimeError(f"graph-query.py update failed: {res.stderr.strip() or res.stdout.strip()}")
        actions.append("graph-update")

    return {"actions": actions, "dashboard_updated": dashboard_updated}


def strip_comments_and_strings(line: str) -> str:
    stripped = line.lstrip()
    if stripped.startswith("//") or stripped.startswith("\\\\"):
        return ""
    without_strings = ZIG_STRING_RE.sub('""', line)
    return without_strings.split("//", 1)[0]


def collect_added_src_lines(root: Path, staged_only: bool) -> list[str]:
    if staged_only:
        diff_args = ["diff", "--cached", "--unified=0", "--diff-filter=ACMR", "--", "src/"]
        res = run_git(root, diff_args, check=False)
        lines: list[str] = []
        if res.returncode == 0:
            for raw in res.stdout.splitlines():
                if raw.startswith("+") and not raw.startswith("+++ "):
                    lines.append(raw[1:])
        return lines

    lines = []
    if has_head(root):
        res = run_git(root, ["diff", "HEAD", "--unified=0", "--diff-filter=ACMR", "--", "src/"], check=False)
        if res.returncode == 0:
            for raw in res.stdout.splitlines():
                if raw.startswith("+") and not raw.startswith("+++ "):
                    lines.append(raw[1:])
        untracked = run_git(
            root,
            ["ls-files", "--others", "--exclude-standard", "--", "src/"],
            check=False,
        )
        for rel in untracked.stdout.splitlines():
            p = root / rel
            if is_zig_source(rel) and p.is_file():
                lines.extend(p.read_text(encoding="utf-8", errors="replace").splitlines())
    else:
        src_dir = root / "src"
        if src_dir.is_dir():
            for p in sorted(src_dir.glob("*.zig")):
                lines.extend(p.read_text(encoding="utf-8", errors="replace").splitlines())
    return lines


def collect_head_src_symbols(root: Path) -> tuple[set[str], set[str]]:
    if not has_head(root):
        return set(), set()
    files_res = run_git(root, ["ls-tree", "-r", "--name-only", "HEAD", "--", "src/"], check=False)
    if files_res.returncode != 0:
        return set(), set()

    validators: set[str] = set()
    invalids: set[str] = set()
    for rel in files_res.stdout.splitlines():
        if not is_zig_source(rel):
            continue
        blob = run_git(root, ["show", f"HEAD:{rel}"], check=False)
        if blob.returncode != 0:
            continue
        for line in blob.stdout.splitlines():
            code = strip_comments_and_strings(line)
            if not code:
                continue
            for m in VALIDATE_FN_RE.finditer(code):
                validators.add(m.group(1))
            for m in INVALID_ERR_RE.finditer(code):
                invalids.add(m.group(1))
    return validators, invalids


def read_repo_text(root: Path, rel: str, staged_only: bool) -> str:
    if staged_only:
        blob = run_git(root, ["show", f":{rel}"], check=False)
        if blob.returncode == 0:
            return blob.stdout
        return ""
    path = root / rel
    if path.is_file():
        return path.read_text(encoding="utf-8", errors="replace")
    return ""


def collect_knowledge_texts(root: Path, staged_only: bool) -> tuple[str, str, str]:
    playbook = read_repo_text(root, "docs/vault/Bug-Playbook.md", staged_only)
    vault_parts: list[str] = []
    corpus_parts: list[str] = []

    if staged_only:
        idx_res = run_git(root, ["ls-files", "--cached", "--", "docs/vault/", ".agents/rules/", "scripts/auto-audit.sh"], check=False)
        rel_files = sorted({p for p in idx_res.stdout.splitlines() if p})
    else:
        found: list[str] = []
        for pattern in KNOWLEDGE_GLOBS:
            for p in root.glob(pattern):
                if p.is_file():
                    found.append(p.relative_to(root).as_posix())
        rel_files = sorted(set(found))

    for rel in rel_files:
        if rel == "docs/vault/Lessons-Learned.md":
            continue
        txt = read_repo_text(root, rel, staged_only)
        if not txt:
            continue
        corpus_parts.append(txt)
        if rel in {
            "docs/vault/Architecture-Map.md",
            "docs/vault/Security-And-Memory-Checklist.md",
            "docs/vault/Bug-Playbook.md",
        }:
            vault_parts.append(txt)

    return playbook, "\n".join(vault_parts), "\n".join(corpus_parts)


def inspect_knowledge_gaps(root: Path, staged_only: bool = False) -> dict[str, list[str]]:
    added_lines = collect_added_src_lines(root, staged_only=staged_only)
    if not added_lines:
        return {"missing_bugs": [], "missing_validators": [], "missing_errors": []}

    head_validators, head_invalids = collect_head_src_symbols(root)
    playbook_text, vault_text, corpus_text = collect_knowledge_texts(root, staged_only=staged_only)

    added_bugs: set[str] = set()
    added_validators: set[str] = set()
    added_invalids: set[str] = set()

    for line in added_lines:
        for m in BUG_TAG_RE.finditer(line):
            added_bugs.add(f"BUG-{m.group(1)}")
        code = strip_comments_and_strings(line)
        if not code:
            continue
        for m in VALIDATE_FN_RE.finditer(code):
            added_validators.add(m.group(1))
        for m in INVALID_ERR_RE.finditer(code):
            added_invalids.add(m.group(1))

    documented_bugs = set(re.findall(r"(?m)^##\s+(BUG-\d{3,})\b", playbook_text))

    missing_bugs = sorted(b for b in added_bugs if b not in documented_bugs)
    missing_validators = sorted(
        fn for fn in added_validators if fn not in head_validators and fn not in vault_text
    )
    missing_errors = sorted(
        err for err in added_invalids if err not in head_invalids and err not in corpus_text
    )
    return {
        "missing_bugs": missing_bugs,
        "missing_validators": missing_validators,
        "missing_errors": missing_errors,
    }


def has_knowledge_gaps(gaps: dict[str, list[str]]) -> bool:
    return any(bool(v) for v in gaps.values())


def format_gap_reason(gaps: dict[str, list[str]]) -> str:
    parts: list[str] = []
    if gaps["missing_bugs"]:
        parts.append(
            "undocumented BUG IDs in docs/vault/Bug-Playbook.md: " + ", ".join(gaps["missing_bugs"])
        )
    if gaps["missing_validators"]:
        parts.append(
            "new public validators not yet documented in docs/vault/ (Architecture-Map.md, Security-And-Memory-Checklist.md, or Bug-Playbook.md): "
            + ", ".join(gaps["missing_validators"])
        )
    if gaps["missing_errors"]:
        parts.append(
            "new Invalid* errors not yet documented/guarded in docs/vault/, .agents/rules/, or scripts/auto-audit.sh: "
            + ", ".join(gaps["missing_errors"])
        )
    return (
        "Knowledge Auto-Sync found unrecorded changes in src/: "
        + "; ".join(parts)
        + ". Update the knowledge vault / rules / audit gate and regenerate the dashboard before finishing."
    )


def handle_stop_hook(root: Path, raw_stdin: str) -> tuple[dict[str, Any], int]:
    payload: dict[str, Any] = {}
    if raw_stdin.strip():
        try:
            loaded = json.loads(raw_stdin)
            if isinstance(loaded, dict):
                payload = loaded
            else:
                print("[WARN] knowledge-sync: expected JSON object on Stop stdin.", file=sys.stderr)
        except json.JSONDecodeError as exc:
            print(f"[WARN] knowledge-sync: invalid Stop stdin JSON: {exc}", file=sys.stderr)
            return {}, 0

    try:
        sync_knowledge(root, paths=None, force=False, stage_dashboard=False)
    except RuntimeError as exc:
        print(f"[WARN] knowledge-sync: {exc}", file=sys.stderr)
        return {}, 0

    if (
        payload.get("terminationReason") != "NO_TOOL_CALL"
        or bool(payload.get("continuationActive", False))
        or not bool(payload.get("fullyIdle", True))
        or bool(payload.get("error"))
    ):
        return {}, 0

    gaps = inspect_knowledge_gaps(root, staged_only=False)
    if has_knowledge_gaps(gaps):
        return {"decision": "continue", "reason": format_gap_reason(gaps)}, 0
    return {}, 0


def handle_pre_commit(root: Path, run_audit: bool = True) -> int:
    staged = parse_staged_paths(root)
    if not staged:
        return 0

    try:
        sync_res = sync_knowledge(root, paths=staged, force=False, stage_dashboard=True)
    except RuntimeError as exc:
        print(f"[FAIL] knowledge-sync pre-commit failed: {exc}", file=sys.stderr)
        return 1

    if sync_res["dashboard_updated"]:
        print("[INFO] knowledge-sync: regenerated and staged docs/vault/Bug-Dashboard.md")

    gaps = inspect_knowledge_gaps(root, staged_only=True)
    if has_knowledge_gaps(gaps):
        print(f"[FAIL] {format_gap_reason(gaps)}", file=sys.stderr)
        return 1

    if run_audit and any(
        p.startswith(("src/", "scripts/", "docs/vault/", ".agents/", ".githooks/", "Makefile", ".github/"))
        or p == "README.md"
        for p in staged
    ):
        parity_script = root / "scripts" / "check-ci-parity.py"
        if parity_script.is_file():
            res = run_cmd([sys.executable, str(parity_script)], cwd=root, check=False)
            if res.returncode != 0:
                sys.stderr.write(res.stdout + res.stderr)
                return res.returncode

        audit_script = root / "scripts" / "auto-audit.sh"
        if audit_script.is_file() and any(
            p.startswith(("src/", "scripts/", "docs/vault/", ".agents/", ".githooks/")) for p in staged
        ):
            res = run_cmd([str(audit_script)], cwd=root, check=False)
            if res.returncode != 0:
                sys.stderr.write(res.stdout + res.stderr)
                return res.returncode

    return 0


def is_noise_error_line(line: str) -> bool:
    s = line.strip()
    if not s:
        return True
    return any(pat.search(s) for pat in NOISE_LINE_RES)


def normalize_compiler_msg(msg: str, root: Path) -> str:
    clean = msg.replace(str(root), "<repo>")
    clean = re.sub(r"__anon_\d+", "__anon_N", clean)
    return clean[:140]


def normalize_diagnostic_line(line: str, root: Path) -> tuple[str, str] | None:
    s = line.strip()
    if is_noise_error_line(s):
        return None
    if LEAK_ADDR_RE.search(s):
        return ("leak", "[gpa] memory address leaked")
    if s.startswith("Segmentation fault at address "):
        return ("panic", "Segmentation fault")
    m_test = TEST_FAIL_RE.match(s)
    if m_test:
        return ("test_fail", m_test.group(1))
    m_std = STDLIB_DIAG_RE.search(s)
    if m_std:
        return ("compiler", normalize_compiler_msg(f"<zig-stdlib>/{m_std.group(1)}: {m_std.group(2)}", root))
    m_src = DIAG_FILE_RE.search(s)
    if m_src:
        return ("compiler", normalize_compiler_msg(m_src.group(2), root))
    if "panic:" in s.lower():
        clean = re.sub(r"0x[0-9a-fA-F]+", "0xADDR", s.replace(str(root), "<repo>"))
        return ("panic", clean[:140])
    if GENERIC_ERR_RE.match(s):
        clean = re.sub(r"^\d{4}-\d{2}-\d{2}T\S+\s+\[ERROR\]\s+", "", s)
        clean = clean.replace(str(root), "<repo>")
        if re.search(r"src/[A-Za-z0-9_./]+\.zig:\d+:\d+:", clean):
            clean = re.sub(r"src/[A-Za-z0-9_./]+\.zig:\d+:\d+:\s*", "", clean)
            return ("compiler", normalize_compiler_msg(clean, root))
        return ("runtime", clean[:140])
    return None


def analyze_error_log(root: Path) -> dict[str, Any]:
    err_path = root / "error.log"
    if not err_path.is_file():
        return {
            "exists": False,
            "total_lines": 0,
            "filtered_noise": 0,
            "compiler_counts": Counter(),
            "leak_count": 0,
            "panic_counts": Counter(),
            "test_fail_counts": Counter(),
            "variant_counts": Counter(),
        }

    lines = err_path.read_text(encoding="utf-8", errors="replace").splitlines()
    compiler_counts: Counter[str] = Counter()
    panic_counts: Counter[str] = Counter()
    test_fail_counts: Counter[str] = Counter()
    variant_counts: Counter[str] = Counter()
    leak_count = 0
    filtered_noise = 0

    for line in lines:
        for m in ERR_VARIANT_RE.finditer(line):
            variant_counts[f"error.{m.group(1)}"] += 1
        norm = normalize_diagnostic_line(line, root)
        if norm is None:
            filtered_noise += 1
            continue
        kind, sig = norm
        if kind == "compiler":
            compiler_counts[sig] += 1
        elif kind == "leak":
            leak_count += 1
        elif kind == "panic":
            panic_counts[sig] += 1
        elif kind == "test_fail":
            test_fail_counts[sig] += 1

    return {
        "exists": True,
        "total_lines": len(lines),
        "filtered_noise": filtered_noise,
        "compiler_counts": compiler_counts,
        "leak_count": leak_count,
        "panic_counts": panic_counts,
        "test_fail_counts": test_fail_counts,
        "variant_counts": variant_counts,
    }


def collect_playbook_summary(root: Path) -> dict[str, Any]:
    pb_path = root / "docs" / "vault" / "Bug-Playbook.md"
    if not pb_path.is_file():
        return {"total_bugs": 0, "tag_counts": Counter(), "bugs": []}
    text = pb_path.read_text(encoding="utf-8", errors="replace")
    tag_counts: Counter[str] = Counter()
    bugs: list[tuple[str, str]] = []
    for line in text.splitlines():
        if line.startswith("## BUG-"):
            m = re.match(r"^##\s+(BUG-\d+):\s*(.+)$", line)
            if m:
                bugs.append((m.group(1), m.group(2).strip()))
            for tag in re.findall(r"#[a-z0-9-]+", line):
                tag_counts[tag] += 1
    return {"total_bugs": len(bugs), "tag_counts": tag_counts, "bugs": bugs}


def load_rule_docs(root: Path) -> dict[str, str]:
    docs: dict[str, str] = {}
    for p in sorted((root / ".agents" / "rules").glob("*.md")):
        docs[p.relative_to(root).as_posix()] = p.read_text(encoding="utf-8", errors="replace")
    return docs


def classify_diagnostic_coverage(root: Path, sig: str, rule_docs: dict[str, str], vault_corpus: str) -> str:
    for pat, rel_doc in RULE_SIGNAL_HINTS:
        if pat.search(sig) and rel_doc in rule_docs:
            return f"Covered ([{Path(rel_doc).name}](../../{rel_doc}))"
    token = sig.removeprefix("error.")
    if token and (token in vault_corpus or any(token in txt for txt in rule_docs.values())):
        return "Covered (Vault / Rules)"
    return "Candidate for `/learn`"


def md_cell(text: str) -> str:
    return text.replace("|", "\\|").replace("`", "'")


def render_lessons_markdown(
    root: Path,
    err_stats: dict[str, Any],
    pb_summary: dict[str, Any],
    rule_docs: dict[str, str],
    vault_corpus: str,
) -> str:
    lines = [
        "---",
        "tags:",
        "  - lessons-learned",
        "  - bug-pattern",
        "  - zig-0.17",
        "  - error-analysis",
        "aliases:",
        "  - ZigPod Lessons Learned",
        "status: active",
        "---",
        "",
        "# ZigPod Distilled Bug & Error Lessons",
        "",
        "กลับไปที่ [[00-Index]] · คลังบั๊ก [[Bug-Playbook]] · เช็กลิสต์ [[Security-And-Memory-Checklist]] · แดชบอร์ด [[Bug-Dashboard]]",
        "",
        "> สร้าง/อัปเดตเมื่อสั่ง `python3 scripts/knowledge-sync.py --distill` (`make distill-lessons`) โดยกรอง hook/build wrapper noise ออกจาก [error.log](../../error.log) และผสานกับ [[Bug-Playbook]] + `.agents/rules/*.md`",
        "",
        "## Snapshot Summary",
        "",
        "| Metric | Value |",
        "| :--- | :--- |",
        f"| Tracked Playbook Bugs | **{pb_summary['total_bugs']}** |",
        f"| Analyzed `error.log` Lines | **{err_stats['total_lines']}** ({err_stats['filtered_noise']} wrapper/hook noise lines filtered) |",
        f"| Allocator Leak Sightings (`[gpa]`) | **{err_stats['leak_count']}** |",
        f"| Unique Compiler Diagnostics | **{len(err_stats['compiler_counts'])}** |",
        f"| Unique Domain `error.*` Variants | **{len(err_stats['variant_counts'])}** |",
        "",
        "## Bug-Playbook Pattern Themes (`BUG-001`–`BUG-NNN`)",
        "",
        "| Tag | Count | Focus Area |",
        "| :--- | ---: | :--- |",
    ]
    tag_focus = {
        "#bug-pattern": "All recorded recurring defect classes",
        "#security-gate": "Fail-closed validation, path/symlink/URL/timeout & audit integrity",
        "#memory-safety": "Allocator discipline, chain consistency & pointer/bounds safety",
        "#reliability": "Lifecycle cleanup/rollback, compose parity, tests & E2E scripts",
        "#memory-leak": "UAF/OOM/non-sequential cleanup leaks under std.testing.allocator",
    }
    for tag, count in pb_summary["tag_counts"].most_common():
        lines.append(f"| `{tag}` | {count} | {tag_focus.get(tag, 'Tracked invariant')} |")
    if not pb_summary["tag_counts"]:
        lines.append("| `-` | 0 | No Bug-Playbook headings found |")

    uncovered: list[str] = []
    lines.extend([
        "",
        "## Top Zig Compiler & Leak Diagnostics (`error.log`)",
        "",
        "| Hits | Normalized Diagnostic | Coverage |",
        "| ---: | :--- | :--- |",
    ])
    top_diags = list(err_stats["compiler_counts"].most_common(12))
    if err_stats["leak_count"]:
        top_diags.append(("[gpa] memory address leaked", err_stats["leak_count"]))
    for psig, pcnt in err_stats["panic_counts"].most_common(4):
        top_diags.append((psig, pcnt))
    top_diags.sort(key=lambda kv: kv[1], reverse=True)
    top_diags = top_diags[:15]
    for sig, cnt in top_diags:
        cov = classify_diagnostic_coverage(root, sig, rule_docs, vault_corpus)
        if cov.startswith("Candidate"):
            uncovered.append(sig)
        lines.append(f"| {cnt} | `{md_cell(sig)}` | {cov} |")
    if not top_diags:
        lines.append("| 0 | `No compiler/leak diagnostics in error.log` | - |")

    lines.extend([
        "",
        "## Top Domain Error Variants (`error.<Name>`)",
        "",
        "| Hits | Error Variant | Coverage |",
        "| ---: | :--- | :--- |",
    ])
    for var_name, cnt in err_stats["variant_counts"].most_common(15):
        cov = classify_diagnostic_coverage(root, var_name, rule_docs, vault_corpus)
        if cov.startswith("Candidate"):
            uncovered.append(var_name)
        lines.append(f"| {cnt} | `{md_cell(var_name)}` | {cov} |")
    if not err_stats["variant_counts"]:
        lines.append("| 0 | `No domain error.* tokens in error.log` | - |")

    if err_stats["test_fail_counts"]:
        lines.extend([
            "",
            "## Frequent Regression Test Failures During Fixes",
            "",
            "| Hits | Test Name |",
            "| ---: | :--- |",
        ])
        for tname, cnt in err_stats["test_fail_counts"].most_common(10):
            lines.append(f"| {cnt} | `{md_cell(tname)}` |")

    lines.extend(["", "## Distillation Candidates for `/learn`", ""])
    if uncovered:
        lines.append("> [!note] Unmapped Error Signatures")
        for item in uncovered[:10]:
            lines.append(f"> - `{md_cell(item)}` — not yet referenced in `.agents/rules/*.md` or `docs/vault/`")
    else:
        lines.append("All top recurring diagnostics and error variants above are covered by `.agents/rules/*.md` or `docs/vault/`.")

    return "\n".join(lines).rstrip() + "\n"


def distill_lessons(root: Path, output_path: Path | None = None) -> dict[str, Any]:
    target = (output_path if output_path is not None else root / "docs" / "vault" / "Lessons-Learned.md")
    if not target.is_absolute():
        target = root / target
    target.parent.mkdir(parents=True, exist_ok=True)

    err_stats = analyze_error_log(root)
    pb_summary = collect_playbook_summary(root)
    rule_docs = load_rule_docs(root)
    _, vault_corpus, _ = collect_knowledge_texts(root, staged_only=False)

    rendered = render_lessons_markdown(root, err_stats, pb_summary, rule_docs, vault_corpus)
    before = target.read_bytes() if target.is_file() else b""
    changed = rendered.encode("utf-8") != before
    if changed or not target.is_file():
        target.write_text(rendered, encoding="utf-8")

    graph_script = root / "scripts" / "graph-query.py"
    if graph_script.is_file():
        res = run_cmd([sys.executable, str(graph_script), "update"], cwd=root, check=False)
        if res.returncode != 0:
            raise RuntimeError(f"graph-query.py update failed: {res.stderr.strip() or res.stdout.strip()}")

    return {
        "output": target.relative_to(root).as_posix() if target.is_relative_to(root) else str(target),
        "updated": changed,
        "error_lines": err_stats["total_lines"],
        "filtered_noise": err_stats["filtered_noise"],
        "unique_compiler_diags": len(err_stats["compiler_counts"]),
        "unique_variants": len(err_stats["variant_counts"]),
        "total_bugs": pb_summary["total_bugs"],
    }


def _write_test_repo(tmp: Path) -> None:
    (tmp / "src").mkdir(parents=True, exist_ok=True)
    (tmp / "docs" / "vault").mkdir(parents=True, exist_ok=True)
    (tmp / ".agents" / "rules").mkdir(parents=True, exist_ok=True)
    (tmp / "scripts").mkdir(parents=True, exist_ok=True)

    (tmp / "src" / "demo.zig").write_text(
        'pub const DemoError = error{ExistingErr};\n'
        'pub fn validateExisting() !void {}\n'
        'test "ok" {}\n',
        encoding="utf-8",
    )
    (tmp / "docs" / "vault" / "Bug-Playbook.md").write_text(
        "# ZigPod Bug Playbook\n\n## BUG-001: Existing Bug\n",
        encoding="utf-8",
    )
    (tmp / "docs" / "vault" / "Architecture-Map.md").write_text(
        "# Arch\n`validateExisting`\n",
        encoding="utf-8",
    )
    (tmp / "docs" / "vault" / "Security-And-Memory-Checklist.md").write_text(
        "# Checklist\n",
        encoding="utf-8",
    )
    (tmp / "scripts" / "graph-query.py").write_text(
        "import sys\n"
        "from pathlib import Path\n"
        "if sys.argv[1:] == ['update']:\n"
        "    cache = Path('.zig-cache'); cache.mkdir(exist_ok=True)\n"
        "    (cache / 'knowledge-graph.json').write_text('{}', encoding='utf-8')\n",
        encoding="utf-8",
    )
    (tmp / "scripts" / "bug-dashboard.py").write_text(
        "import sys\n"
        "from pathlib import Path\n"
        "if sys.argv[1:] == ['generate']:\n"
        "    bugs = Path('docs/vault/Bug-Playbook.md').read_text(encoding='utf-8').count('## BUG-')\n"
        "    Path('docs/vault/Bug-Dashboard.md').write_text(f'# Dash {bugs}\\n', encoding='utf-8')\n",
        encoding="utf-8",
    )
    (tmp / "scripts" / "check-ci-parity.py").write_text("raise SystemExit(0)\n", encoding="utf-8")
    audit = tmp / "scripts" / "auto-audit.sh"
    audit.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    os.chmod(audit, 0o755)
    (tmp / "docs" / "vault" / "Bug-Dashboard.md").write_text("# Dash 1\n", encoding="utf-8")

    run_git(tmp, ["init", "-q"])
    run_git(tmp, ["config", "user.name", "Test"])
    run_git(tmp, ["config", "user.email", "test@example.com"])
    run_git(tmp, ["add", "."])
    run_git(tmp, ["commit", "-q", "-m", "init"])


def run_self_test() -> int:
    with tempfile.TemporaryDirectory(prefix="zigpod-ksync-test-") as td:
        repo = Path(td)
        _write_test_repo(repo)
        script = Path(__file__).resolve()

        # 1. Clean repo -> Stop hook allows stop & builds graph cache
        p1 = subprocess.run(
            [sys.executable, str(script), "--root", str(repo), "--stop-hook"],
            input=json.dumps({
                "terminationReason": "NO_TOOL_CALL",
                "continuationActive": False,
                "fullyIdle": True,
                "error": "",
            }),
            text=True,
            capture_output=True,
            check=True,
        )
        assert json.loads(p1.stdout) == {}, f"expected empty stop json, got {p1.stdout}"
        assert (repo / ".zig-cache" / "knowledge-graph.json").is_file()

        # 2. Unrecorded BUG-999, validator, and Invalid* error -> triggers continue
        (repo / "src" / "demo.zig").write_text(
            'pub const DemoError = error{ExistingErr, InvalidWidget};\n'
            '// BUG-999: validateWidget rejects bad widgets\n'
            'pub fn validateExisting() !void {}\n'
            'pub fn validateWidget() !void { return DemoError.InvalidWidget; }\n'
            'test "BUG-999" {}\n',
            encoding="utf-8",
        )
        p2 = subprocess.run(
            [sys.executable, str(script), "--root", str(repo), "--stop-hook"],
            input=json.dumps({
                "terminationReason": "NO_TOOL_CALL",
                "continuationActive": False,
                "fullyIdle": True,
                "error": "",
            }),
            text=True,
            capture_output=True,
            check=True,
        )
        d2 = json.loads(p2.stdout)
        assert d2.get("decision") == "continue", f"expected continue, got {p2.stdout}"
        for needle in ("BUG-999", "validateWidget", "InvalidWidget"):
            assert needle in d2["reason"], f"missing {needle} in reason: {d2}"

        # 3. continuationActive=True -> must NEVER loop
        p3 = subprocess.run(
            [sys.executable, str(script), "--root", str(repo), "--stop-hook"],
            input=json.dumps({
                "terminationReason": "NO_TOOL_CALL",
                "continuationActive": True,
                "fullyIdle": True,
            }),
            text=True,
            capture_output=True,
            check=True,
        )
        assert json.loads(p3.stdout) == {}, f"expected no-loop {{}}, got {p3.stdout}"

        # 4. Non-NO_TOOL_CALL or invalid JSON -> allows stop
        p4 = subprocess.run(
            [sys.executable, str(script), "--root", str(repo), "--stop-hook"],
            input="{not-json",
            text=True,
            capture_output=True,
            check=True,
        )
        assert json.loads(p4.stdout) == {}

        # 5. Pre-commit with unrecorded staged src/demo.zig -> blocks commit
        run_git(repo, ["add", "src/demo.zig"])
        p5 = subprocess.run(
            [sys.executable, str(script), "--root", str(repo), "--pre-commit"],
            text=True,
            capture_output=True,
            check=False,
        )
        assert p5.returncode != 0, "expected pre-commit to reject undocumented staged src changes"
        assert "BUG-999" in p5.stderr

        # 6. Document knowledge in Bug-Playbook + Architecture-Map -> pre-commit auto-stages Bug-Dashboard.md and passes
        (repo / "docs" / "vault" / "Bug-Playbook.md").write_text(
            "# ZigPod Bug Playbook\n\n## BUG-001: Existing Bug\n## BUG-999: Widget Guard (InvalidWidget)\n",
            encoding="utf-8",
        )
        (repo / "docs" / "vault" / "Architecture-Map.md").write_text(
            "# Arch\n`validateExisting` `validateWidget`\n",
            encoding="utf-8",
        )
        run_git(repo, ["add", "docs/vault/Bug-Playbook.md", "docs/vault/Architecture-Map.md"])
        p6 = subprocess.run(
            [sys.executable, str(script), "--root", str(repo), "--pre-commit"],
            text=True,
            capture_output=True,
            check=False,
        )
        assert p6.returncode == 0, f"expected pre-commit pass, got rc={p6.returncode} stderr={p6.stderr}"
        assert (repo / "docs" / "vault" / "Bug-Dashboard.md").read_text(encoding="utf-8") == "# Dash 2\n"
        staged_after = parse_staged_paths(repo)
        assert "docs/vault/Bug-Dashboard.md" in staged_after, f"Bug-Dashboard.md not auto-staged: {staged_after}"

        # 7. Stop hook now returns {} cleanly after documentation + dashboard sync
        p7 = subprocess.run(
            [sys.executable, str(script), "--root", str(repo), "--stop-hook"],
            input=json.dumps({
                "terminationReason": "NO_TOOL_CALL",
                "continuationActive": False,
                "fullyIdle": True,
            }),
            text=True,
            capture_output=True,
            check=True,
        )
        assert json.loads(p7.stdout) == {}, f"expected clean stop after docs, got {p7.stdout}"

        # 8. --distill filters noise, extracts Zig diagnostics/leaks/variants, and flags unmapped signatures
        (repo / "error.log").write_text(
            "\n".join([
                "2026-11-15T00:00:00Z [ERROR] auto-audit detected 1 failure(s):",
                "FAIL: scripts/security-check.sh failed: ==> [1/4] Checking Zig test suite",
                "/tmp/fake/src/demo.zig:10:5: error: switch must handle all possibilities",
                "[gpa] (err): memory address 0xdeadbeef leaked:",
                "error.InvalidBrandNewThing",
                "error.InvalidWidget",
            ]) + "\n",
            encoding="utf-8",
        )
        p8 = subprocess.run(
            [sys.executable, str(script), "--root", str(repo), "--distill"],
            text=True,
            capture_output=True,
            check=True,
        )
        d8 = json.loads(p8.stdout)
        assert d8["filtered_noise"] >= 2, f"expected noise filtered, got {d8}"
        assert d8["unique_compiler_diags"] == 1, f"expected 1 compiler diag, got {d8}"
        lessons_txt = (repo / "docs" / "vault" / "Lessons-Learned.md").read_text(encoding="utf-8")
        assert "switch must handle all possibilities" in lessons_txt
        assert "[gpa] memory address leaked" in lessons_txt
        assert "auto-audit detected" not in lessons_txt
        assert "InvalidBrandNewThing" in lessons_txt and "Candidate for `/learn`" in lessons_txt

    print("[PASS] knowledge-sync self-test: all 8 cases passed.")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="ZigPod automatic knowledge sync and drift-check CLI")
    p.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="Repository root directory")
    p.add_argument("--force", action="store_true", help="Force regeneration in --sync mode")
    p.add_argument("--output", type=Path, default=None, help="Output path for --distill")
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument("--sync", action="store_true", help="Sync knowledge graph and Bug-Dashboard.md")
    mode.add_argument("--distill", action="store_true", help="Distill error.log + Bug-Playbook.md into docs/vault/Lessons-Learned.md")
    mode.add_argument("--stop-hook", action="store_true", help="Handle Antigravity Stop lifecycle hook")
    mode.add_argument("--pre-commit", action="store_true", help="Handle Git pre-commit hook")
    mode.add_argument("--self-test", action="store_true", help="Run isolated self-tests")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    root = args.root.resolve()

    if args.self_test:
        return run_self_test()
    if args.sync:
        res = sync_knowledge(root, paths=None, force=args.force, stage_dashboard=False)
        gaps = inspect_knowledge_gaps(root, staged_only=False)
        res["knowledge_gaps"] = gaps
        print(json.dumps(res, ensure_ascii=False))
        return 0
    if args.distill:
        res = distill_lessons(root, output_path=args.output)
        print(json.dumps(res, ensure_ascii=False))
        return 0
    if args.stop_hook:
        out, code = handle_stop_hook(root, sys.stdin.read())
        print(json.dumps(out, ensure_ascii=False))
        return code
    if args.pre_commit:
        return handle_pre_commit(root)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
