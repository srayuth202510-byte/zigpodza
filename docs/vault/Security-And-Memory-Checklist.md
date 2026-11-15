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
- [ ] โมดูลที่มีการจอง heap (`main.zig`, `cli.zig`, `config.zig`, `http.zig`, `podman_api.zig`, `log.zig`, `policy.zig`) ต้องมีเทสที่ใช้ `std.testing.allocator`
- [ ] ห้ามเก็บ slice ที่อ้างอิงข้อมูลใน `std.json.Parsed(T)` ข้ามขอบเขตบล็อกที่มี `defer parsed.deinit()` (BUG-020)
- [ ] Error paths ที่มี `ArrayList` / temporary allocation ต้องมี `errdefer` และมี unit test พิสูจน์ว่าไม่ leak
- [ ] Slice/array ที่ populate ตาม index แบบไม่เรียงลำดับ (เช่น `topoSortServices`) ต้องใช้ nullable slots (`?T` + `@memset(..., null)`) และ caller/callee ownership ต้องตรง doc comment (BUG-038)
- [ ] ห้ามฝังการจองหน่วยความจำ (`alloc.dupe`) ไว้ภายใน argument list ของฟังก์ชันที่อาจคืน error — ต้องมี `errdefer` ชัดเจน (BUG-035)
- [ ] `repairAuditTail` ต้องทำงานใน **write path** ของ `audit.log` ภายใต้ `lockAudit` และห้าม truncate ทับ entry 5-field สมบูรณ์ที่ขาดเพียง `\n` (BUG-030, BUG-036)
- [ ] `compose up` ต้องติดตาม container หลัง `createContainer` สำเร็จ (ก่อน `startContainer`) และเฉพาะ network ที่สร้างใหม่ในรอบนั้น พร้อม `errdefer rollbackComposeUp` หลัง slice cleanup `defer` (BUG-029)
- [ ] `appendDupPort`, `appendDupVolume`, `appendDupLabel` ใน `compose.zig` ต้อง transfer ownership ก่อน append (`catch` free) และไม่คง function-level `errdefer` ที่ชี้ไปยัง pointer ที่ append เข้า `list.items` แล้ว ป้องกัน double free เมื่อ `toOwnedSlice` เกิด OOM (BUG-044)

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
- [ ] Published ports (`-p`) ผ่าน `podman_api.makePortMapping()` → `validatePortMapping()` (fail-closed: port `1..65535`, proto `tcp`/`udp`/`sctp`, host address ต้องเป็น IPv4 literal) และ `createContainer` re-validate `ExposedPorts` แบบ defense-in-depth (BUG-015)
- [ ] Network/identity/capabilities (`--network`, `-w`, `-u`, `--cap-drop`/`--cap-add`) ผ่าน `validateNetworkMode()` (allow-list `none`/`bridge`/`host`/`pasta`/`slirp4netns`), `validateWorkdir()` (absolute traversal-free), `validateUser()` (`USER[:GROUP]`) และ `validateCapability()` (`ALL`/uppercase) และ `createContainer` re-validate แบบ defense-in-depth (BUG-016)
- [ ] `inspect TARGET` ผ่าน `validateResourceRef()` ก่อนประกอบ URL path ตัด space/control char/`?`/`#` เพื่อกัน request-line injection (BUG-017)
- [ ] `exec` ตรวจ container ID/`--user`/`--workdir` และ exec ID จาก daemon ก่อนประกอบ `/exec/{id}/start` กับ `/exec/{id}/json`; demultiplex output และคืนค่า exit code (BUG-018)
- [ ] `--profile=sandbox` และ `--policy` ผ่าน `policy.applySandboxDefaults()` + `policy.checkRunPolicy()` แบบ pre-flight ก่อนคุยกับ socket และบันทึก `logger.deny()` ลง `audit.log` พร้อมตรวจด้วย `zigpod audit --json` (`writeAuditJson`) (BUG-019)
- [ ] Validation domain ใหม่ต้องมี `ApiError` และ `api.<validator>` deny rule เฉพาะของตัวเอง (ห้าม reuse ข้าม flag เช่น `InvalidShmSize`) และ unit/mock tests ต้องใช้ `std.testing.expectError` + `Content-Length` จาก `body.len` (BUG-040, BUG-041)
- [ ] คำสั่ง tar transfer (`save`, `load`, `export`, `import`) ใน `podman_transfer.zig` ตรวจ `realpathAlloc` + regular file (กัน symlink escape), เขียน output แบบ atomic เมื่อ 2xx สำเร็จเท่านั้น, และส่ง `application/x-tar` สำหรับ upload (BUG-023)
- [ ] Lifecycle `run` มี best-effort cleanup: start fail → force-remove; `--rm` + fetchLogs fail → remove (BUG-012)
- [ ] Request body ที่อาจบรรจุ credential (`Env`, `Cmd`, `Labels`) ต้อง redact ก่อน log และไฟล์ log ต้องไม่ถูก track ใน git (BUG-024)
- [ ] Host bind mount (`-v`) ต้องผ่าน **realpath** (`realpathAlloc`) และ deny-list ต้องถูกตรวจซ้ำบน path ที่ resolve แล้ว ไม่ใช่เฉพาะรูปแบบข้อความ (BUG-025)
- [ ] Tar symlink target ต้อง validate ซ้ำหลัง common-root strip / path transform ทุกครั้ง (BUG-026)
- [ ] `createContainer` ต้อง re-validate `HostConfig.PortBindings` เช่นเดียวกับ `ExposedPorts` และห้ามใช้ `catch unreachable` ใน path ที่ข้อมูลมาจากภายนอก (BUG-034)
- [ ] ทุกการเรียก `std.posix.poll` ต้องตรวจค่าที่คืนมา — `0` = timeout ต้องกลายเป็น `Error.Timeout` ไม่ใช่ no-op (BUG-032)
- [ ] ทุก `writeAll` บน socket ต้องมี deadline เท่ากับฝั่งอ่าน (BUG-037)
- [ ] ไฟล์ log/audit ต้องเปิดแบบ fail-closed: `O_NOFOLLOW` (ห้าม symlink) + `fchmod 0o640` หลังเปิด ไม่พึ่งแค่ mode argument ตอน create และ `zigpod.toml` ต้องเป็นไฟล์ธรรมดาของ UID ปัจจุบัน ไม่มีสิทธิ์ `g+w`/`o+w` พร้อม validate `socket_path` (BUG-031, BUG-033)
- [ ] `verifyAuditFile` และ `writeAuditJson` ใช้ `evaluateAuditContent`/`parseAuditFields` ร่วมกัน แยก uncommitted tail ด้วยความสมบูรณ์ของเนื้อหา (5 field + hash 64 hex) และทดสอบ corrupt ถึงไบต์สุดท้าย `\n` ใน fuzz (BUG-036)
- [ ] `compose.yaml` parser fail-closed (`InvalidComposeSyntax`) สำหรับ unsupported property, scalar/block/inline `{...}`, และ long-syntax `- type: bind`; service `networks:` ต้องประกาศอยู่ใน `networks:`, ไม่ขัดกับ `network_mode:`, ตรวจ `policy.isNetworkAllowed`, และส่งผ่าน `NetworkingConfig.EndpointsConfig` + label `com.docker.compose.network` โดยคง allow-list ของ `validateNetworkMode` ครบ (BUG-016, BUG-027, BUG-028)
- [ ] ทุก entry point ที่รับ image reference (`pullImage`, `createContainer`, CLI run dispatch, Compose parser) ต้องผ่าน `validateResourceRef` แบบ pre-flight (BUG-043)
- [ ] การ forward duplex stream ใน `pumpBidirectional` ต้องส่ง `std.posix.shutdown(stream.handle, .send)` เมื่อ stdin EOF/error ป้องกัน container init process แขวนรอ input (BUG-042)
- [ ] `restartContainer` เมื่อ `timeout_secs > 3600` ต้องคืน `ApiError.InvalidTimeout` และ map เป็น `"api.restartContainer"` deny telemetry (ห้าม alias เป็น `InvalidIdentifier`) (BUG-045)

## 3. Logging, Tamper Evidence & Operations

- [ ] บันทึกรายละเอียดระบบลง [system.log](../../system.log) และข้อผิดพลาดลง [error.log](../../error.log)
- [ ] `audit.log` เชื่อมแต่ละบรรทัดด้วย SHA-256 hash chain และตรวจจับการแก้ไขได้ด้วย `zigpod audit` (`verifyAuditFile`)
- [ ] การเขียน `audit.log` ใช้ `flock` + re-read chain head จากไฟล์ทุกครั้ง กัน multi-process desync (BUG-009)
- [ ] Partial tail จาก crash ต้องถูก repair ตอน init และ `verifyAuditFile` ต้องไม่รายงานเป็น tampering (BUG-008)
- [ ] `system.log` และ `error.log` ไม่เป็น world-writable (`o+w`) และ log ใหม่ต้องเป็น `0640` (BUG-013)
- [ ] Timestamp จากทุกผู้เขียน log (Zig + shell scripts) ต้องเป็น ค.ศ. UTC — สคริปต์ต้อง pin `LC_ALL=C` (BUG-011)
- [ ] `zigpod demo` ผ่านครบ 18 cases (fail-closed ALLOW/DENY) โดยใช้ `std.testing.allocator` ไม่ leak
- [ ] CI / `Makefile` / Vault parity ผ่าน `python3 scripts/check-ci-parity.py`, `scripts/smoke.sh`, และ `scripts/graph-query.py`
- [ ] สคริปต์ E2E (`scripts/*.sh`) ต้อง capture multi-line output ลงตัวแปรก่อน `grep -q` (ห้าม pipe ตรงจนเกิด `BrokenPipe` ตัดตอน `compose down`) และ `Makefile` fallback ต้องครอบ `{ ...; }` (BUG-039)
- [ ] Release binary (`zig build -Doptimize=ReleaseSafe`) ไม่มี executable stack (`GNU_STACK` ต้องไม่เป็น `RWE`) และไม่มี `RWX` PT_LOAD segment
