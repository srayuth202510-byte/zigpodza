# ZigPod Project Agent Rules

กฎการทำงานประจำโปรเจกต์ ZigPod (Pure Zig Podman/Docker-compatible CLI):

1. **เริ่มต้นจาก Knowledge Vault (`docs/vault/`)**:
   - ดูภาพรวมโมดูล, ownership และ trust boundary ที่ `docs/vault/00-Index.md` และ `docs/vault/Architecture-Map.md`
   - ตรวจสอบประวัติ bug ที่เคยเกิดที่ `docs/vault/Bug-Playbook.md` ก่อนแก้ไขไฟล์ `src/*.zig`
   - เมื่อพบบั๊กใหม่ที่เกิดซ้ำได้ ให้เพิ่มรายการ `BUG-NNN` ใน `docs/vault/Bug-Playbook.md`

2. **การค้นหาโค้ดและไฟล์**:
   - ใช้ `rg` (`rg <pattern> [path]` / `rg --files`) เป็นหลักเสมอ

3. **มาตรฐาน Memory & Tests (บังคับ)**:
   - ทุก unit test ที่มีการจองหน่วยความจำต้องใช้ `std.testing.allocator` เพื่อตรวจจับ memory leak, double-free และ invalid free (ห้ามใช้ `page_allocator` หรือ `ArenaAllocator` ใน `test` blocks)
   - โค้ด runtime ใน `src/main.zig` ต้องตรวจผลจาก `gpa.deinit() == .leak` และไม่ปล่อยผ่าน
   - ทุกโมดูลต้องมีเทสทั้ง happy path, error path, malformed input และ boundary conditions

4. **กลไกจับผิดอัตโนมัติ (ต้องรันหลังแก้โค้ด)**:
   - หลังแก้ไขไฟล์ใน `src/` ต้องรัน `./scripts/auto-audit.sh` (และ `./scripts/security-check.sh --require-zig` เมื่อมี `zig`) เพื่อยืนยันว่าไม่ละเมิด invariants
   - ปฏิบัติตามกฎการเขียน test, mock server, error mapping และ shell E2E เพิ่มเติมใน `.agents/rules/testing-and-shell-safety.md` (ป้องกัน `BUG-038`–`BUG-041`)
   - ปฏิบัติตามข้อควรระวังของคอมไพเลอร์ Zig 0.13 และเช็กลิสต์ก่อน/หลังแก้โค้ดใน `.agents/rules/zig-0.13-gotchas.md`

5. **Logging**:
   - ระบบบันทึกรายละเอียดการทำงานลง `system.log` และบันทึกเฉพาะ error ลง `error.log`
