---
tags:
  - security-gate
  - memory-safety
  - checklist
aliases:
  - Security and Memory Checklist
status: active
---

# Security & Memory Safety Checklist

กลับไปที่ [[00-Index]] · ดูบันทึกบั๊กที่ [[Bug-Playbook]]

> [!danger] Mandatory Invariants
> รายการด้านล่างถูกบังคับตรวจโดยสคริปต์อัตโนมัติ:
> - [scripts/auto-audit.sh](../../scripts/auto-audit.sh) (Static anti-pattern & invariant checks)
> - [scripts/security-check.sh](../../scripts/security-check.sh) (Zig tests + ELF hardening + log permissions + optional Balor check)

## 1. Memory Safety Gates `#memory-safety`

- [ ] `src/main.zig` ตรวจ `gpa.deinit() == .leak` และไม่ละทิ้งด้วย `defer _ = gpa.deinit();`
- [ ] ห้ามใช้ `std.heap.page_allocator` ใน `src/`
- [ ] โมดูลที่มีการจอง heap (`cli.zig`, `config.zig`, `http.zig`, `podman_api.zig`, `log.zig`) ต้องมีเทสที่ใช้ `std.testing.allocator`
- [ ] Error paths ที่มี `ArrayList` / temporary allocation ต้องมี `errdefer` และมี unit test พิสูจน์ว่าไม่ leak

## 2. Protocol & Input Security Gates `#security-gate`

- [ ] `http.Client.request` เรียก `validateRequestTarget(path)` ก่อนเชื่อมต่อ socket
- [ ] `http.Client.request` ใช้ `waitReadable` (`std.posix.poll`) บังคับ `timeout_ms` ไม่ให้ค้างถาวร
- [ ] การอ่าน response ทุก chunk ต้องผ่าน poll (`readAllWithTimeout`) ไม่ใช่เฉพาะ byte แรก (BUG-007)
- [ ] `waitContainer` / `pullImage` ใช้ `blocking_timeout_ms` ไม่ใช่ default 30s (BUG-007)
- [ ] `http.decodeChunked` ใช้ `std.math.add` ทุกการคำนวณขนาดรวมทั้ง projected total, ตรวจ `max_response_bytes`, และตรวจ trailer `\r\n` (BUG-010)
- [ ] `podman_api.zig` เรียก `validateIdentifier` กับทุก `id` และ `name` ที่สร้าง URL
- [ ] `podman_api.demuxLogs` ใช้ `std.math.add` และ fallback เมื่อ frame ไม่สมบูรณ์
- [ ] Hardening flags (`-m`/`--memory`, `--pids-limit`, `--read-only`, `--no-new-privileges`) ใช้ checked `std.math.mul` และส่งผ่าน `HostConfig`
- [ ] Host bind mounts (`-v`) ผ่าน `podman_api.makeMount()` → `validateHostPath()` (fail-closed: บล็อก `/`, `/etc`, `/proc`, `/sys`, `/dev`, `/boot`, `/run`, `/var/run`, `/var/lib/docker`, `/var/lib/containers`, `/root`) และ default เป็น read-only (BUG-014)
- [ ] Sensitive `/etc` allow-list (`localtime`, `timezone`, `hosts`, `resolv.conf`, `nsswitch.conf`, `hostname`) ต้อง mount แบบ read-only เท่านั้น
- [ ] Container mount target ผ่าน `validateContainerPath()` (absolute, traversal-free) และ `createContainer` re-validate `Mounts` แบบ defense-in-depth
- [ ] Lifecycle `run` มี best-effort cleanup: start fail → force-remove; `--rm` + fetchLogs fail → remove (BUG-012)

## 3. Logging, Tamper Evidence & Operations

- [ ] บันทึกรายละเอียดระบบลง [system.log](../../system.log) และข้อผิดพลาดลง [error.log](../../error.log)
- [ ] `audit.log` เชื่อมแต่ละบรรทัดด้วย SHA-256 hash chain และตรวจจับการแก้ไขได้ด้วย `zigpod audit` (`verifyAuditFile`)
- [ ] การเขียน `audit.log` ใช้ `flock` + re-read chain head จากไฟล์ทุกครั้ง กัน multi-process desync (BUG-009)
- [ ] Partial tail จาก crash ต้องถูก repair ตอน init และ `verifyAuditFile` ต้องไม่รายงานเป็น tampering (BUG-008)
- [ ] `system.log` และ `error.log` ไม่เป็น world-writable (`o+w`) และ log ใหม่ต้องเป็น `0640` (BUG-013)
- [ ] Timestamp จากทุกผู้เขียน log (Zig + shell scripts) ต้องเป็น ค.ศ. UTC — สคริปต์ต้อง pin `LC_ALL=C` (BUG-011)
- [ ] `zigpod demo` ผ่านครบ 14 cases (fail-closed ALLOW/DENY) โดยใช้ `std.testing.allocator` ไม่ leak
- [ ] CI / `Makefile` / Vault parity ผ่าน `python3 scripts/check-ci-parity.py`, `scripts/smoke.sh`, และ `scripts/graph-query.py`
- [ ] Release binary (`zig build -Doptimize=ReleaseSafe`) ไม่มี executable stack (`GNU_STACK` ต้องไม่เป็น `RWE`) และไม่มี `RWX` PT_LOAD segment
