---
name: bug-hunter
description: |
  Systematic bug-detection, memory-leak auditing, and security verification workflow
  for ZigPod using the Obsidian Knowledge Vault (docs/vault/), automated static
  checks (scripts/auto-audit.sh), Zig test suite, logs, and optional balorsh analysis.
---

# ZigPod Bug-Hunter Workflow

Use this skill whenever diagnosing an error, reviewing code changes, or auditing memory/security invariants.

## 1. Consult the Obsidian Knowledge Vault

Read or search `docs/vault/` first with `rg`:
- `docs/vault/00-Index.md` — Knowledge graph & quick queries
- `docs/vault/Architecture-Map.md` — Module ownership & trust boundaries
- `docs/vault/Bug-Playbook.md` — Known bug patterns (`BUG-001`..`BUG-041`)
- `docs/vault/Security-And-Memory-Checklist.md` — Mandatory invariants

```bash
rg -n "#bug-pattern|#memory-safety|#security-gate" docs/vault/
```

## 2. Run Automated Detectors

```bash
# Static anti-pattern + invariant checks + security-check
./scripts/auto-audit.sh

# Full Zig test + ELF hardening check (requires zig >= 0.13.0)
./scripts/security-check.sh --require-zig
```

## 3. Inspect Logs

- Check `error.log` for failed HTTP calls, invalid identifiers, invalid request paths, or audit failures.
- Check `system.log` for full execution traces and audit history.

## 4. Optional Balor (`balorsh`) Security Review

If `/usr/local/bin/balorsh` and `/opt/balorsh/data` are configured on the host:
- Use `balorsh llm` (`loganalyst` / `blueteam` persona) to analyze `system.log` and `error.log`.
- Use `balorsh networkscan` / `webexploit` against any container services exposed via ZigPod.

## 5. Record New Findings

Whenever a new bug class or regression is discovered:
1. Add a failing unit test using `std.testing.allocator` in the affected `src/*.zig` file.
2. Fix the root cause and verify `./scripts/auto-audit.sh` passes.
3. Document a new `BUG-NNN` entry in `docs/vault/Bug-Playbook.md` and link it to `docs/vault/Security-And-Memory-Checklist.md`.
