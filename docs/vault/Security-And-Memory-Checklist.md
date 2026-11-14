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
- [ ] `http.decodeChunked` ใช้ `std.math.add`, ตรวจ `max_response_bytes`, และตรวจ trailer `\r\n`
- [ ] `podman_api.zig` เรียก `validateIdentifier` กับทุก `id` และ `name` ที่สร้าง URL
- [ ] `podman_api.demuxLogs` ใช้ `std.math.add` และ fallback เมื่อ frame ไม่สมบูรณ์

## 3. Logging & Operations

- [ ] บันทึกรายละเอียดระบบลง [system.log](../../system.log) และข้อผิดพลาดลง [error.log](../../error.log)
- [ ] `system.log` และ `error.log` ไม่เป็น world-writable (`o+w`)
- [ ] Release binary (`zig build -Doptimize=ReleaseSafe`) ไม่มี executable stack (`GNU_STACK` ต้องไม่เป็น `RWE`) และไม่มี `RWX` PT_LOAD segment
