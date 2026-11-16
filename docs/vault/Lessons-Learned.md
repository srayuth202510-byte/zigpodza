---
tags:
  - lessons-learned
  - bug-pattern
  - zig-0.17
  - error-analysis
aliases:
  - ZigPod Lessons Learned
status: active
---

# ZigPod Distilled Bug & Error Lessons

กลับไปที่ [[00-Index]] · คลังบั๊ก [[Bug-Playbook]] · เช็กลิสต์ [[Security-And-Memory-Checklist]] · แดชบอร์ด [[Bug-Dashboard]]

> สร้าง/อัปเดตเมื่อสั่ง `python3 scripts/knowledge-sync.py --distill` (`make distill-lessons`) โดยกรอง hook/build wrapper noise ออกจาก [error.log](../../error.log) และผสานกับ [[Bug-Playbook]] + `.agents/rules/*.md`

## Snapshot Summary

| Metric | Value |
| :--- | :--- |
| Tracked Playbook Bugs | **45** |
| Analyzed `error.log` Lines | **18759** (17867 wrapper/hook noise lines filtered) |
| Allocator Leak Sightings (`[gpa]`) | **10** |
| Unique Compiler Diagnostics | **62** |
| Unique Domain `error.*` Variants | **39** |

## Bug-Playbook Pattern Themes (`BUG-001`–`BUG-NNN`)

| Tag | Count | Focus Area |
| :--- | ---: | :--- |
| `#bug-pattern` | 45 | All recorded recurring defect classes |
| `#security-gate` | 26 | Fail-closed validation, path/symlink/URL/timeout & audit integrity |
| `#memory-safety` | 7 | Allocator discipline, chain consistency & pointer/bounds safety |
| `#reliability` | 7 | Lifecycle cleanup/rollback, compose parity, tests & E2E scripts |
| `#memory-leak` | 4 | UAF/OOM/non-sequential cleanup leaks under std.testing.allocator |
| `#concurrency` | 1 | Tracked invariant |

## Top Zig Compiler & Leak Diagnostics (`error.log`)

| Hits | Normalized Diagnostic | Coverage |
| ---: | :--- | :--- |
| 168 | `error: switch must handle all possibilities` | Covered ([zig-0.17-gotchas.md](../../.agents/rules/zig-0.17-gotchas.md)) |
| 75 | `error: local variable is never mutated` | Covered ([zig-0.17-gotchas.md](../../.agents/rules/zig-0.17-gotchas.md)) |
| 66 | `error: use of undeclared identifier 'ApiError'` | Covered ([zig-0.17-gotchas.md](../../.agents/rules/zig-0.17-gotchas.md)) |
| 64 | `error: capture shadows declaration of 'v'` | Covered ([zig-0.17-gotchas.md](../../.agents/rules/zig-0.17-gotchas.md)) |
| 64 | `error: local constant shadows declaration of 'v'` | Covered ([zig-0.17-gotchas.md](../../.agents/rules/zig-0.17-gotchas.md)) |
| 35 | `error: name shadows primitive 'u1'` | Covered ([zig-0.17-gotchas.md](../../.agents/rules/zig-0.17-gotchas.md)) |
| 25 | `error: expected type '[]u8', found '[]const u8'` | Covered ([zig-0.17-gotchas.md](../../.agents/rules/zig-0.17-gotchas.md)) |
| 23 | `<zig-stdlib>/json/stringify.zig: error: expected type 'error{OutOfMemory}!void', found '@typeInfo(@typeInfo(@TypeOf(podman_types.ExposedPort` | Covered ([zig-0.17-gotchas.md](../../.agents/rules/zig-0.17-gotchas.md)) |
| 23 | `<zig-stdlib>/json/stringify.zig: error: expected type 'error{OutOfMemory}!void', found '@typeInfo(@typeInfo(@TypeOf(podman_types.PortBinding` | Covered ([zig-0.17-gotchas.md](../../.agents/rules/zig-0.17-gotchas.md)) |
| 21 | `error: expected 5 argument(s), found 4` | Candidate for `/learn` |
| 20 | `error: capture 'f' shadows capture from outer scope` | Covered ([zig-0.17-gotchas.md](../../.agents/rules/zig-0.17-gotchas.md)) |
| 16 | `error: expected type '*array_list.ArrayListAligned(u8,null)', found 'io.GenericWriter(*array_list.ArrayListAligned(u8,null),error{OutOfMemor` | Covered ([zig-0.17-gotchas.md](../../.agents/rules/zig-0.17-gotchas.md)) |
| 10 | `[gpa] memory address leaked` | Covered ([memory-and-security.md](../../.agents/rules/memory-and-security.md)) |
| 6 | `Segmentation fault` | Covered ([memory-and-security.md](../../.agents/rules/memory-and-security.md)) |
| 1 | `thread 27678 panic: reached unreachable code` | Candidate for `/learn` |

## Top Domain Error Variants (`error.<Name>`)

| Hits | Error Variant | Coverage |
| ---: | :--- | :--- |
| 53 | `error.InvalidHostPath` | Covered (Vault / Rules) |
| 47 | `error.InvalidPort` | Covered (Vault / Rules) |
| 46 | `error.PodmanApiError` | Candidate for `/learn` |
| 46 | `error.NotFound` | Covered (Vault / Rules) |
| 46 | `error.InvalidIdentifier` | Covered (Vault / Rules) |
| 46 | `error.InvalidMountTarget` | Candidate for `/learn` |
| 46 | `error.InvalidNetwork` | Candidate for `/learn` |
| 46 | `error.InvalidWorkdir` | Candidate for `/learn` |
| 46 | `error.InvalidUser` | Candidate for `/learn` |
| 46 | `error.InvalidCapability` | Candidate for `/learn` |
| 46 | `error.InvalidSignal` | Candidate for `/learn` |
| 46 | `error.InvalidCpuLimit` | Covered (Vault / Rules) |
| 46 | `error.InvalidHostname` | Candidate for `/learn` |
| 46 | `error.InvalidRestartPolicy` | Candidate for `/learn` |
| 46 | `error.InvalidLabel` | Candidate for `/learn` |

## Frequent Regression Test Failures During Fixes

| Hits | Test Name |
| ---: | :--- |
| 12 | `log.test.repro: BUG-036 verifyAuditFile and writeAuditJson do not skip complete final entry missing newline` |
| 11 | `compose.test.repro: BUG-027 scalar list values parsed and long-syntax volume maps rejected` |
| 8 | `compose.test.repro: BUG-028 compose service networks attach container and set compose network label` |
| 8 | `compose.test.repro: BUG-029 compose up rolls back created containers and networks on partial failure` |
| 8 | `log.test.repro: BUG-030 Logger.log repairs partial tail under lock without re-init` |
| 4 | `podman_transfer.test.scanCpArchive rejects hardlink escapes, oversized PAX headers, and truncated tar streams` |
| 4 | `podman_validate.test.BUG-025 repro: validateHostPath and makeMount reject symlinks to denied paths` |
| 3 | `podman_transfer.test.BUG-026 repro: cpFromContainer rejects symlink escape exposed after common-root strip` |
| 3 | `config.test.BUG-033 repro: world-writable or symlinked zigpod.toml must be rejected` |
| 2 | `main.test.dispatch handles extended run flags (--cpus, --env-file, --label, --entrypoint, --hostname, --restart), network CRUD, attach, and cp` |

## Distillation Candidates for `/learn`

> [!note] Unmapped Error Signatures
> - `error: expected 5 argument(s), found 4` — not yet referenced in `.agents/rules/*.md` or `docs/vault/`
> - `thread 27678 panic: reached unreachable code` — not yet referenced in `.agents/rules/*.md` or `docs/vault/`
> - `error.PodmanApiError` — not yet referenced in `.agents/rules/*.md` or `docs/vault/`
> - `error.InvalidMountTarget` — not yet referenced in `.agents/rules/*.md` or `docs/vault/`
> - `error.InvalidNetwork` — not yet referenced in `.agents/rules/*.md` or `docs/vault/`
> - `error.InvalidWorkdir` — not yet referenced in `.agents/rules/*.md` or `docs/vault/`
> - `error.InvalidUser` — not yet referenced in `.agents/rules/*.md` or `docs/vault/`
> - `error.InvalidCapability` — not yet referenced in `.agents/rules/*.md` or `docs/vault/`
> - `error.InvalidSignal` — not yet referenced in `.agents/rules/*.md` or `docs/vault/`
> - `error.InvalidHostname` — not yet referenced in `.agents/rules/*.md` or `docs/vault/`
