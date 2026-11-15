#!/usr/bin/env python3
"""Verify parity across CI workflow, Makefile, CLI sources, vault docs, and README."""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

REQUIRED_FILES = [
    "AGENTS.md",
    "README.md",
    "Makefile",
    "build.zig",
    ".github/workflows/ci.yml",
    "scripts/auto-audit.sh",
    "scripts/security-check.sh",
    "scripts/smoke.sh",
    "scripts/podman-e2e.sh",
    "scripts/graph-query.py",
    "scripts/bug-dashboard.py",
    "scripts/check-ci-parity.py",
    "docs/vault/00-Index.md",
    "docs/vault/Architecture-Map.md",
    "docs/vault/Bug-Playbook.md",
    "docs/vault/Bug-Dashboard.md",
    "docs/vault/Security-And-Memory-Checklist.md",
    "src/main.zig",
    "src/cli.zig",
    "src/cli_specs.zig",
    "src/cli_types.zig",
    "src/completion.zig",
    "src/compose.zig",
    "src/config.zig",
    "src/demo.zig",
    "src/http.zig",
    "src/http_parser.zig",
    "src/http_types.zig",
    "src/log.zig",
    "src/podman_api.zig",
    "src/podman_build.zig",
    "src/podman_images.zig",
    "src/podman_logs.zig",
    "src/podman_pods.zig",
    "src/podman_system.zig",
    "src/podman_test_helpers.zig",
    "src/podman_transfer.zig",
    "src/podman_types.zig",
    "src/podman_validate.zig",
    "src/policy.zig",
    "src/utils.zig",
]

EXECUTABLES = [
    "scripts/auto-audit.sh",
    "scripts/security-check.sh",
    "scripts/smoke.sh",
    "scripts/podman-e2e.sh",
    "scripts/graph-query.py",
    "scripts/bug-dashboard.py",
    "scripts/check-ci-parity.py",
]

MAKEFILE_TARGETS = [
    "help",
    "build",
    "test",
    "test-one",
    "test-adv",
    "demo",
    "e2e",
    "real-e2e",
    "check-ci",
    "verify",
    "ci",
    "query",
    "path",
    "explain",
    "triage",
    "debug-logs",
    "graph-update",
    "bugs",
    "dashboard",
    "dashboard-serve",
    "debug-test",
    "clean",
]

CLI_SUBCOMMANDS = [
    "run",
    "ps",
    "images",
    "pull",
    "stop",
    "rm",
    "logs",
    "version",
    "audit",
    "demo",
    "search",
    "save",
    "load",
    "export",
    "import",
    "attach",
    "cp",
    "compose",
]

HARDENING_FLAGS = [
    "--memory",
    "--pids-limit",
    "--read-only",
    "--no-new-privileges",
    "--cpus",
    "--env-file",
    "--label",
    "--entrypoint",
    "--hostname",
    "--restart",
    "--shm-size",
    "--ulimit",
    "--init",
    "--health-cmd",
    "--health-interval",
]

CI_COMMANDS = [
    "zig build test",
    "zig build -Doptimize=ReleaseSafe",
    "./scripts/security-check.sh --require-zig",
    "scripts/check-ci-parity.py",
    "scripts/graph-query.py",
    "scripts/smoke.sh",
]


def main() -> int:
    errors: list[str] = []

    for rel in REQUIRED_FILES:
        if not (ROOT / rel).is_file():
            errors.append(f"missing required file: {rel}")

    for rel in EXECUTABLES:
        p = ROOT / rel
        if p.exists() and not os.access(p, os.X_OK):
            errors.append(f"script is not executable (+x): {rel}")

    if errors:
        for err in errors:
            print(f"[FAIL] {err}", file=sys.stderr)
        return 1

    makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
    for target in MAKEFILE_TARGETS:
        if not re.search(rf"(?m)^{re.escape(target)}\s*:", makefile):
            errors.append(f"Makefile missing target '{target}'")

    ci_yml = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
    for marker in CI_COMMANDS:
        if marker not in ci_yml:
            errors.append(f".github/workflows/ci.yml missing step marker '{marker}'")

    cli_src = (ROOT / "src/cli.zig").read_text(encoding="utf-8")
    main_src = (ROOT / "src/main.zig").read_text(encoding="utf-8")
    readme = (ROOT / "README.md").read_text(encoding="utf-8")

    for sub in CLI_SUBCOMMANDS:
        if sub not in cli_src:
            errors.append(f"src/cli.zig missing subcommand '{sub}'")
        if f".{sub}" not in main_src:
            errors.append(f"src/main.zig missing dispatch handling for '.{sub}'")
        if sub not in readme:
            errors.append(f"README.md missing documentation for subcommand '{sub}'")

    for flag in HARDENING_FLAGS:
        if flag not in cli_src:
            errors.append(f"src/cli.zig missing hardening flag '{flag}'")
        if flag not in readme:
            errors.append(f"README.md missing documentation for flag '{flag}'")

    for marker in ("make verify", "make real-e2e", "zigpod demo", "zigpod audit", "graph-query.py"):
        if marker not in readme:
            errors.append(f"README.md missing reference '{marker}'")

    bug_playbook = (ROOT / "docs/vault/Bug-Playbook.md").read_text(encoding="utf-8")
    for bug_id in ("BUG-001", "BUG-002", "BUG-003", "BUG-004", "BUG-005", "BUG-006"):
        if bug_id not in bug_playbook:
            errors.append(f"docs/vault/Bug-Playbook.md missing '{bug_id}'")

    if errors:
        for err in errors:
            print(f"[FAIL] {err}", file=sys.stderr)
        return 1

    print("[PASS] check-ci-parity: CI workflow, Makefile, CLI, vault, and README are in sync.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
