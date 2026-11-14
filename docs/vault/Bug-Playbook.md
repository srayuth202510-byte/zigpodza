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

---

## BUG-006: Missing `ripgrep` (`rg`) on CI Runners Causing `auto-audit.sh` Failure `#bug-pattern` `#security-gate`

- **Symptom**: บน CI runner (เช่น GitHub Actions `ubuntu-latest`) การรัน `scripts/auto-audit.sh` ล้มเหลวด้วย `./scripts/auto-audit.sh: line 49: rg: command not found` (exit code `1`) แม้ unit test และ build จะผ่านครบ
- **Root Cause**: `scripts/auto-audit.sh` เรียก `rg` โดยตรงโดยไม่มี fallback เมื่อไม่มี binary `rg` ทำให้เกิด exit code `127`: ตรวจเชิงบวก (`if rg -q ...`) ล้มเหลวทั้งหมด และตรวจเชิงลบ (`if rg -n ... >/dev/null 2>&1`) ซ่อน stderr จนกลายเป็น false-pass
- **Fix**:
  - เพิ่ม helper `has_match()` ใน [scripts/auto-audit.sh](../../scripts/auto-audit.sh) ให้ใช้ `rg -q` เป็นหลักและ fallback เป็น `grep -REq` เมื่อไม่มี `rg`
  - เพิ่ม step ติดตั้ง `ripgrep` ใน [ci.yml](../../.github/workflows/ci.yml)
- **Prevention Rule**: สคริปต์ตรวจอัตโนมัติที่รันบน CI ต้องตรวจ `command -v <tool>` พร้อม fallback หรือติดตั้ง dependency ใน [ci.yml](../../.github/workflows/ci.yml) ให้ครบ และทดสอบกรณีไม่มีเครื่องมือด้วย

---

## BUG-007: Half-Enforced Socket Timeout (Wait/Pull Fail Early or Hang Forever) `#bug-pattern` `#security-gate`

- **Symptom**: `zigpod run` แบบ attached ล้มเหลวด้วย `Error.Timeout` เมื่อ container ทำงานเกิน 30 วินาที (Podman `POST /containers/{id}/wait` จะไม่ส่ง response จนกว่า container จะจบ) ในทางกลับกัน หาก daemon ส่งข้อมูลชุดแรกแล้วค้างกลางทาง (เช่น `pull` ระหว่าง network หลุดแต่ยังไม่ปิด connection) `readAllAlloc` จะ block ตลอดกาลโดยไม่มี timeout
- **Root Cause**: ใน [src/http.zig](../../src/http.zig) เดิม `Client.request` เรียก `waitReadable` (poll) เพียง**ครั้งเดียวก่อน byte แรก** แล้วส่งต่อให้ `readAllAlloc` อ่านจน EOF โดยไม่มีการ poll อีก — timeout ถูกบังคับเฉพาะ "รอ byte แรก" เท่านั้น และ `waitContainer`/`pullImage` ใช้ default timeout 30s ทั้งที่ endpoint เหล่านี้ตั้งใจให้เงียบนาน
- **Fix**:
  - เพิ่ม `readAllWithTimeout` ใน [src/http.zig](../../src/http.zig) ที่ poll ก่อน**ทุกการอ่าน** (ไม่ใช่แค่ครั้งแรก) จนกว่าจะได้ EOF พร้อม enforce `max_response_bytes`
  - เพิ่ม `Client.requestWithTimeout` และ `http.blocking_timeout_ms` (12 ชม.) สำหรับ endpoint ที่ block ตาม external event
  - `waitContainer` และ `pullImage` ใน [src/podman_api.zig](../../src/podman_api.zig) ใช้ `requestWithTimeout(..., blocking_timeout_ms)`
  - เพิ่มเทส regression: stream ที่ค้างกลาง body ต้องได้ `Error.Timeout` ภายใน timeout สั้น ๆ และ server ที่ตอบช้ากว่า default timeout ต้องผ่านเมื่อใช้ long timeout
- **Prevention Rule**: ห้ามอ่าน socket โดยไม่ poll ก่อนทุกครั้ง; endpoint ที่ block ตาม external event ต้องประกาศ timeout ของตัวเอง (`blocking_timeout_ms`) ไม่ใช่ยืม default 30s ของ request ทั่วไป

---

## BUG-008: Crash-Interrupted Audit Tail Poisons the Whole Hash Chain `#bug-pattern` `#memory-safety`

- **Symptom**: หากกระบวนการตายกลางการเขียนบรรทัดสุดท้ายของ `audit.log` (partial line ไม่มี `\n`) การรันครั้งถัดไปจะ fallback ไป genesis hash ทำให้ทุก entry ใหม่มี `prev_hash` ไม่ตรงกับท้ายไฟล์ และ `zigpod audit` รายงาน `AuditTampered` **ทั้งไฟล์** แม้ไม่มีใครแก้ไข
- **Root Cause**: `readLastAuditHash` เดิม parse บรรทัดสุดท้ายแบบไม่แยกแยะ "บรรทัดที่ยังไม่ commit" (hash ไม่ครบ 64 ตัว → genesis) จาก "การ tamper จริง" และ `verifyAuditFile` ถือว่าทุก segment เป็น entry ที่ commit แล้ว
- **Fix**:
  - เพิ่ม `repairAuditTail` ใน [src/log.zig](../../src/log.zig): ตอน `Logger.init` ใต้ flock ให้ truncate บรรทัดสุดท้ายที่ไม่สมบูรณ์ออกก่อน append ต่อ
  - `verifyAuditFile` ข้าม segment สุดท้ายที่ไม่มี `\n` ปิดท้าย (ไม่นับเป็น entry และไม่รายงาน tamper) — บรรทัดกลางไฟล์ที่ malformed ยังคง fail ตามเดิม
  - เพิ่มเทส: partial tail ต้องไม่ทำ verify ล้มเหลว และ init ครั้งถัดไปต้อง repair แล้วต่อ chain ได้
- **Prevention Rule**: ระบบ hash-chain ต้องแยกพฤติกรรม "uncommitted tail" (crash) ออกจาก "tampering" เสมอ และต้อง repair ตอน re-open ภายใต้ lock

---

## BUG-009: Concurrent Logger Writers Fork the Audit Hash Chain `#bug-pattern` `#memory-safety`

- **Symptom**: เมื่อรัน zigpod มากกว่าหนึ่ง process พร้อมกัน (เช่น `run` ค้างไว้แล้วเปิดอีก terminal) ทุก process อ่าน `last_hash` เดียวกันตอน init แล้วเขียนแทรกสลับกัน ทำให้ `prev_hash` ของ entry ไม่ตรงกับบรรทัดก่อนหน้าจริง และ `zigpod audit` รายงาน tampered ทั้งไฟล์
- **Root Cause**: `O_APPEND` (src/log.zig `openAppend`) กัน overwrite ได้ แต่ไม่กัน hash-chain desync: hash ถูกคำนวณจาก state ในหน่วยความจำของแต่ละ process ไม่ใช่ state จริงล่าสุดของไฟล์
- **Fix**:
  - เพิ่ม `lockAudit`/`unlockAudit` (`std.posix.flock` `LOCK.EX`/`LOCK.UN`) ใน [src/log.zig](../../src/log.zig)
  - ทุกครั้งที่เขียน audit: lock → re-read chain head จากไฟล์ (`lastHashFromFd`) → คำนวณ hash → append → unlock
  - `Logger.init` ก็ทำ repair + อ่าน hash ใต้ lock เช่นกัน
  - เพิ่มเทส: logger สองตัวเขียนสลับกันแล้ว `verifyAuditFile` ต้องผ่านครบทุก entry
- **Prevention Rule**: โครงสร้าง hash-chained ที่เขียนจากหลาย process ต้องอ่าน state ล่าสุดใต้ exclusive lock ทุกครั้งก่อนคำนวณ hash ถัดไป ห้ามพึ่ง state ในหน่วยความจำ

---

## BUG-010: Unchecked Add in `decodeChunked` Depends on Short-Circuit Order `#bug-pattern` `#security-gate`

- **Symptom**: ตรวจพบตอน code review: `out.items.len + size > max_response_bytes` ใน [src/http.zig](../../src/http.zig) ใช้ `+` ธรรมดาแทน `std.math.add` — ตอนนี้ปลอดภัยเพราะเงื่อนไข `size > max_response_bytes` ถูกประเมินก่อนแล้ว short-circuit ออก (ยืนยันด้วย repro: chunk size `FFFFFFFFFFFFFFFF` ตัดทิ้งด้วย `InvalidResponse` ไม่ panic) แต่ถ้า refactor สลับลำดับเงื่อนไข จะกลายเป็น integer overflow panic ใน Debug/ReleaseSafe ทันทีเมื่อ chunk ก่อนหน้ามีข้อมูลอยู่แล้ว
- **Root Cause**: กฎของ BUG-004 ("ทุกขนาด/offset ต้องผ่าน `std.math.add`") ถูกทำให้ "ผ่านแบบบังเอิญ" จาก evaluation order ของ `or` แทนที่จะถูกบังคับด้วย checked arithmetic โดยตรง
- **Fix**: เปลี่ยนเป็น `const projected = std.math.add(usize, out.items.len, size) catch return Error.InvalidResponse;` ก่อนเช็ค `max_response_bytes`
- **Prevention Rule**: ห้ามพึ่ง short-circuit order เพื่อกัน integer overflow — คำนวณขนาดที่มาจาก socket ต้องใช้ `std.math.add` ตั้งแต่บรรทัดแรก ไม่ว่าเงื่อนไขข้างเคียงจะ "ช่วย" ก็ตาม

---

## BUG-011: Locale-Dependent (Buddhist Era) Timestamps in Shell Scripts `#bug-pattern`

- **Symptom**: ใน `system.log` พบ timestamp สองปฏิทินปนกัน: entry จาก `scripts/auto-audit.sh` เป็นปี พ.ศ. (`2569-...`) ขณะที่ entry จาก Zig Logger เป็น ค.ศ. (`2026-...`) ทำให้ sort/grep ตามเวลาเพี้ยนและ dashboard parse ผิด
- **Root Cause**: เครื่อง dev ตั้ง `LC_TIME=th_TH.UTF-8` ทำให้ `date -u '+%Y...'` คืนปี Buddhist Era (ปีจริงของระบบเป็น ค.ศ. ถูกต้อง) ส่วน Zig `writeTimestamp` คำนวณจาก epoch เสมอ
- **Fix**: เปลี่ยนเป็น `TIMESTAMP="$(LC_ALL=C date -u '+%Y-%m-%dT%H:%M:%SZ')"` ใน [scripts/auto-audit.sh](../../scripts/auto-audit.sh)
- **Prevention Rule**: สคริปต์ที่เขียน log ร่วมกับ runtime ต้อง pin locale (`LC_ALL=C`) เมื่อ format timestamp และต้อง cross-check รูปแบบกับ entry จาก runtime อื่นในไฟล์เดียวกัน

---

## BUG-012: Missing Cleanup Paths in the `run` Container Lifecycle `#bug-pattern` `#reliability`

- **Symptom**: (1) `startContainer` ล้มเหลวหลัง `createContainer` สำเร็จ → container ถูกสร้างค้างเป็น orphan (2) `zigpod run --rm` แบบ attached: ถ้า `fetchLogs` ล้มเหลว container ไม่ถูกลบตามที่ผู้ใช้สั่ง (3) `id` ที่ได้จาก `createContainer` ไม่เคยถูก free ใน `dispatch` (ปลอดภัยเพราะ arena แต่ขัด contract "caller frees" ใน [[Architecture-Map]])
- **Root Cause**: `dispatch` ใน [src/main.zig](../../src/main.zig) ใช้ `try` ตรง ๆ ทุก step โดยไม่มี cleanup path; `AutoRemove` ถูกตั้งเฉพาะเมื่อ detach (เพื่อไม่ให้ daemon ลบ container ก่อน fetchLogs) แต่ไม่มี best-effort removal เมื่อ pipeline สะดุด
- **Fix**:
  - `startContainer` fail → best-effort `removeContainer(force=true)` ทิ้งก่อนคืน error
  - `fetchLogs` fail เมื่อมี `--rm` → best-effort `removeContainer` (container จบแล้วหลัง wait) ก่อนคืน error
  - เพิ่ม `defer client.allocator.free(id)` ให้ตรง contract
- **Prevention Rule**: lifecycle ที่สร้าง resource บน daemon ต้องมี best-effort cleanup ทุก failure path หลังจุดที่ resource เกิดขึ้น และ ownership ของ allocation ต้องตรงกับเอกสารเสมอ

---

## BUG-013: World-Readable Log Files `#bug-pattern` `#security-gate`

- **Symptom**: `system.log` / `error.log` / `audit.log` ถูกสร้างด้วย mode `0644` — ผู้ใช้อื่นบนเครื่องอ่านได้ ทั้งที่มี container/image IDs, ชื่อ image และข้อความ error จาก daemon
- **Root Cause**: `openAppend` ใน [src/log.zig](../../src/log.zig) ใช้ `0o644`; เช็กลิสต์เดิมบังคับแค่ "ไม่ world-writable" จึงไม่มีใครสังเกต
- **Fix**: ลด mode เป็น `0o640` และ `chmod 640` ไฟล์ที่มีอยู่แล้วใน repository
- **Prevention Rule**: ไฟล์ log/audit ที่สร้างใหม่ต้องใช้ `0o640` ขึ้นไป (group-readable ได้ แต่ห้าม other-readable/world-writable) และ `security-check.sh` ต้องรายงาน mode ปัจจุบันทุกครั้ง

---

## BUG-014: Host Bind Mount Without a Fail-Closed Path Policy `#bug-pattern` `#security-gate`

- **Symptom**: ระหว่างทำ Phase 1 (`-v`/`--volume`) หากส่ง `SRC:DST` เข้าไปใน `Mounts` ตรง ๆ จะสามารถ bind-mount `/`, `/etc`, `/proc`, `/sys`, `/run`, `/var/run/docker.sock`, `/root`, หรือ path ที่มี `..` ได้ ทำให้ container (หรือ AI agent ที่ขับ CLI) อ่าน/เขียนไฟล์ระบบ host, ขโมย container-engine socket แล้วยกระดับสิทธิ์ หรือแก้ `/etc` เพื่อ persistence
- **Root Cause**: เดิม CLI ไม่รองรับ `-v` จึงไม่มีจุดตรวจ; การเพิ่ม mount โดยไม่มี policy จะเปิดช่องโหว่ path traversal + dangerous-host-path ทันที (จัดอยู่ในคลาสเดียวกับ BUG-005 แต่เป็นฝั่ง host filesystem)
- **Fix**:
  - เพิ่ม `podman_api.makeMount()` + `validateHostPath()` / `validateVolumeName()` / `validateContainerPath()` ใน [src/podman_api.zig](../../src/podman_api.zig): source/target ต้องเป็น absolute, ห้าม `..`/`.`/`//`/trailing-slash/control-char, ยาว ≤ 4096
  - บล็อก subtree ของ `/`, `/etc`, `/proc`, `/sys`, `/dev`, `/boot`, `/run`, `/var/run`, `/var/lib/docker`, `/var/lib/containers`, `/root`
  - default เป็น read-only; allow-list ของ `/etc` (`localtime`, `timezone`, `hosts`, `resolv.conf`, `nsswitch.conf`, `hostname`) ต้อง `:ro` เท่านั้น
  - `createContainer` re-validate `Mounts` แบบ defense-in-depth ก่อน stringify JSON
  - เพิ่มเทส DENY ครบ (traversal, dangerous roots, rw-on-`/etc`) และ smoke E2E ตรวจว่า `-v /etc:/data` ถูกปฏิเสธก่อนถึง daemon
- **Prevention Rule**: ทุก field ที่อ้างถึง **path บน host** (mounts, volumes, อนาคต `build` context / `--env-file`) ต้องผ่าน validator แบบ fail-closed ที่ absolute+no-traversal+denylist และ default เป็นสิทธิ์ต่ำสุด (read-only) เสมอ — ห้าม serialize ค่าดิบลง request

## BUG-015: Port Publishing Without a Fail-Closed Port Policy `#bug-pattern` `#security-gate`

- **Symptom**: ระหว่างทำ Phase 1 (`-p`/`--publish`) หากส่ง port mapping เข้าไปใน `ExposedPorts`/`HostConfig.PortBindings` ตรง ๆ จะสามารถประกาศพอร์ตนอกช่วง (`0`, `>65535`) ที่ daemon ตีความเป็นค่าอื่น, ใส่ protocol แปลกปลอม, หรือใส่ host address ที่ไม่ใช่ IP จริง (เช่น hostname ภายนอก) ทำให้เกิด binding ที่คาดไม่ถึงและขยาย attack surface โดยไม่ตั้งใจ
- **Root Cause**: เดิม CLI ไม่รองรับ `-p` จึงไม่มีจุดตรวจ; การ parse port string แบบหลวมแล้ว serialize ดิบจะเกิด mismatch ระหว่างสิ่งที่ผู้ใช้ตั้งใจกับสิ่งที่ daemon bind (จัดอยู่ในคลาสเดียวกับ BUG-005/014 แต่เป็นฝั่ง network surface)
- **Fix**:
  - เพิ่ม `podman_api.makePortMapping()` + `validatePortMapping()` ใน [src/podman_api.zig](../../src/podman_api.zig): container/host port ต้องอยู่ใน `1..65535`, proto allow-list `tcp`/`udp`/`sctp`, host address (ถ้ามี) ต้องผ่าน `std.net.Address.parseIp4`
  - `src/cli.zig` parse เฉพาะรูปแบบ `CONTAINER`, `CONTAINER/proto`, `HOST:CONTAINER[/proto]`, `IPV4:HOST:CONTAINER[/proto]`; เกิน 3 field หรือ port 0/เกินช่วง/proto แปลก → `InvalidValue`
  - `ExposedPorts`/`PortBindings` serialize ด้วย custom `jsonStringify` โดย bind เฉพาะ entry ที่มี host port และใช้ `HostPort` เป็น string ตาม Docker schema
  - `createContainer` re-validate `ExposedPorts` แบบ defense-in-depth ก่อน stringify JSON
  - เพิ่มเทส DENY ครบ (port 0, proto แปลก, IP ผิดรูป) และ smoke E2E ตรวจว่า `-p 0:80` ถูกปฏิเสธก่อนถึง daemon
- **Prevention Rule**: ทุก field ที่อ้างถึง **network endpoint** (ports, อนาคต `--network`, `--hostname`) ต้องผ่าน validator แบบ allow-list (range + protocol + IP literal) และตรวจซ้ำในชั้น API (defense-in-depth) ก่อน serialize — ห้าม serialize ค่าดิบลง request
