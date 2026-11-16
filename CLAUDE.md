# ZigPod

กฎโปรเจกต์ทั้งหมดอยู่ใน @AGENTS.md (อ่านก่อนแก้ `src/*.zig`) และ `.agents/rules/`

- Toolchain: Zig >= 0.17.1 (`minimum_zig_version` ใน `build.zig.zon`) ให้ build ผ่าน `make` / `scripts/find-zig.sh` เสมอ ห้ามเรียก `zig` เปล่า ๆ ถ้าไม่แน่ใจว่าเป็นเวอร์ชันไหน
- ทดสอบ: `make debug-test` ระหว่างแก้ และ `make ci` ก่อน commit
- หลังแก้ `src/`: `./scripts/auto-audit.sh` และ `./scripts/security-check.sh --require-zig`
- I/O ทุกจุดต้องรับ `std.Io` ที่ส่งมาจาก `main` ห้ามใช้ `std.testing.io` ในโค้ด runtime (ดู `.agents/rules/zig-0.17-gotchas.md`)

<!-- rtk-instructions v2 -->
# Command output

Command output here is condensed to save tokens, keeping every signal and
dropping costly noise. Treat it as the complete result: run commands
normally, and batch related commands into one call to avoid extra turns.
Truncated results state their recovery path in their own output. Re-run a
command as `rtk bypass <cmd>` only when its result is unusable: empty when
output was clearly expected, contradicting its exit code, or garbled.

Delegation commands (they hand work to a cheaper model; the files never enter your context):
- `rtk bulk-read --question "..." <paths...>`
- `rtk code-write --spec "..." --reference <file> --target <file>`
<!-- /rtk-instructions -->
