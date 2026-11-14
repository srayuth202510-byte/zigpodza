---
tags:
  - bug-pattern
  - postmortem
  - memory-safety
  - security-gate
aliases:
  - Bug Playbook
status: active
---

# Bug Playbook & Prevention Rules

กลับไปที่ [[00-Index]] · ดูแผนผังระบบที่ [[Architecture-Map]]

บันทึก bug จริงที่พบและแก้ไขในโปรเจกต์ เพื่อใช้เป็นฐานความรู้สำหรับ [[Security-And-Memory-Checklist]] และ `scripts/auto-audit.sh`

---

## BUG-001: Error Set Mismatch on `std.net.connectUnixSocket` `#bug-pattern`

- **Symptom**: `zig build test` บน Zig 0.13.0 ล้มเหลว: `'error.AccessDenied' not a member of destination error set`
- **Root Cause**: `std.net.connectUnixSocket` ใน Zig 0.13.0 คืน `error.PermissionDenied` ไม่ได้รวม `error.AccessDenied`
- **Fix**: เปลี่ยน [src/http.zig](../../src/http.zig) ให้ match เฉพาะ `error.PermissionDenied => Error.PermissionDenied`
- **Prevention Rule**: ตรวจสอบ error union ของ stdlib เวอร์ชันเป้าหมาย (Zig `0.13.0`) และรัน `zig build test` ใน CI ทุกครั้ง

---

## BUG-002: `ArenaAllocator` in Tests Hiding Memory Leaks `#bug-pattern` `#memory-safety`

- **Symptom**: เทสใน `cli.zig` และ `config.zig` เดิมใช้ `ArenaAllocator` (หรือ `page_allocator` แบบ global) ซึ่งไม่เคยรายงาน leak
- **Root Cause**: `ArenaAllocator` กวาดคืนทีเดียว ทำให้ตรวจไม่พบกรณีลืม `deinit` หรือคืนหน่วยความจำไม่ครบใน error path
- **Fix**:
  - เพิ่ม `Parsed.deinit` ใน [src/cli.zig](../../src/cli.zig) และ `Config.deinit` ใน [src/config.zig](../../src/config.zig)
  - เปลี่ยนทุก `test` block ให้ใช้ `std.testing.allocator` โดยตรง พร้อมเทส error path ที่จอง memory ไปแล้วบางส่วน
- **Prevention Rule**: ห้ามใช้ `page_allocator` หรือ `ArenaAllocator` ใน `test` blocks; `scripts/auto-audit.sh` ตรวจบล็อก pattern นี้โดยอัตโนมัติ

---

## BUG-003: Sub-slice Pointer Returned from Owned Env Buffer `#bug-pattern` `#memory-safety`

- **Symptom**: `resolveSocket` ใน [src/config.zig](../../src/config.zig) เดิมคืน `stripUnixScheme(s)` ซึ่งชี้เข้าไปกลาง buffer ที่ `getEnv` จองไว้
- **Root Cause**: หาก caller เรียก `allocator.free(socket_path)` บน sub-slice ที่ไม่ได้เริ่มที่ address แรกของ allocation จะเกิด panic/invalid free หรือ leak buffer ระหว่างทางจาก `getEnv`
- **Fix**: free buffer ชั่วคราวของ `getEnv` ด้วย `defer allocator.free(s)` และ `allocator.dupe` ค่าที่ตัด prefix แล้วให้เป็น owned slice ที่เป็นอิสระ
- **Prevention Rule**: ทุกฟังก์ชันที่คืน slice ให้ caller ต้องคืน owned allocation เต็มก้อน หรือระบุ lifetime อย่างชัดเจนและมี `deinit` คู่กัน

---

## BUG-004: Integer Overflow & OOB Read in Chunked / Frame Decoders `#bug-pattern` `#security-gate`

- **Symptom**: `decodeChunked` และ `demuxLogs` เดิมใช้ `pos + size` และ `pos += size + 2` โดยไม่ตรวจ overflow หรือ trailer `\r\n`
- **Root Cause**: ค่า chunk size ขนาดใหญ่ (เช่น `FFFFFFFFFFFFFFFF`) หรือ payload ที่ขาด `\r\n` อาจทำให้ `pos` ทะลุ `data.len` แล้ว panic ใน `std.mem.indexOfPos`
- **Fix**:
  - ใช้ `std.math.add` ทุกจุดใน `decodeChunked` ([src/http.zig](../../src/http.zig)) และ `demuxLogs` ([src/podman_api.zig](../../src/podman_api.zig))
  - ตรวจ `max_response_bytes` และตรวจยืนยัน `"\r\n"` ท้ายทุก chunk พร้อม unit tests เคส malformed
- **Prevention Rule**: ทุกขนาด/offset ที่มาจาก socket หรือไฟล์ภายนอกต้องผ่าน `std.math.add` และ bounds check เสมอ

---

## BUG-005: Path Traversal & CRLF Injection via Container ID / Path `#bug-pattern` `#security-gate`

- **Symptom**: ค่า `id` หรือ `name` เช่น `../containers` หรือ `id\r\nX-Evil: 1` สามารถแทรกเข้า URL path หรือ HTTP request line ได้
- **Root Cause**: ไม่มีการ validate input ก่อน `allocPrint` เข้า path และ HTTP request line
- **Fix**:
  - เพิ่ม `podman_api.validateIdentifier` ใน [src/podman_api.zig](../../src/podman_api.zig)
  - เพิ่ม `http.validateRequestTarget` ใน [src/http.zig](../../src/http.zig)
- **Prevention Rule**: ทุก endpoint ที่รับ identifier จาก CLI ต้องเรียก `validateIdentifier` และ `Client.request` ต้องเรียก `validateRequestTarget`
