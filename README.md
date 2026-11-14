# ZigPod

**ZigPod** เป็นโปรแกรม CLI ภาษา Zig ที่ทำงานในลักษณะเดียวกับ `podman` / `docker` โดยสื่อสารกับ **Podman REST API (Docker-compatible v1.40)** ผ่าน Unix domain socket ด้วย standard library ของ Zig ล้วน ๆ (ไม่พึ่งพา external library)

A minimal Docker/Podman-compatible CLI written in pure Zig (`>= 0.13.0`) that communicates with the Podman REST API over a Unix domain socket.

---

## Architecture

```mermaid
flowchart TD
    CLI["src/main.zig + src/cli.zig\n(Arg parsing & dispatch)"] --> CFG["src/config.zig\n(Socket & log dir resolution)"]
    CLI --> API["src/podman_api.zig\n(Podman/Docker v1.40 REST API)"]
    API --> HTTP["src/http.zig\n(HTTP/1.1 over Unix socket)"]
    HTTP --> SOCK[("Podman Socket\n/run/podman/podman.sock")]
    CLI --> LOG["src/log.zig + src/utils.zig\n(system.log & error.log)"]
    API --> LOG
```

---

## Project Structure

```text
zigpodza/
├─ src/
│  ├─ main.zig         # CLI entry point, dispatch & error reporting
│  ├─ cli.zig          # Subcommand & flag parser
│  ├─ config.zig       # Socket path & log directory resolution
│  ├─ http.zig         # Minimal HTTP/1.1 Unix-socket client (Content-Length & chunked)
│  ├─ podman_api.zig   # Docker/Podman v1.40 API structs & endpoints
│  ├─ log.zig          # Timestamped file logger (system.log & error.log)
│  └─ utils.zig        # Formatting helpers (shortId, formatSize)
├─ scripts/
│  ├─ install.sh         # Build ReleaseSafe binary and install to PATH
│  └─ security-check.sh  # Run leak/security tests, ELF hardening, and optional balorsh check
├─ examples/
│  └─ demo.sh          # End-to-end sample workflow script
├─ .github/workflows/
│  └─ ci.yml           # GitHub Actions CI (test & release build)
├─ .agents/skills/
│  └─ zigpod-wrapper/SKILL.md
├─ build.zig           # Zig build configuration
├─ build.zig.zon       # Zig package manifest
├─ Dockerfile          # Multi-stage Alpine container image
├─ zigpod.toml         # Sample runtime settings reference
├─ projectplan.md      # Initial design document
├─ system.log          # Runtime system & info/debug/warn/error log
├─ error.log           # Runtime error-only log
└─ LICENSE             # MIT License
```

---

## Prerequisites

- **Zig** `0.13.0` or newer
- **Podman** with the API socket active:
  - Rootless: `systemctl --user enable --now podman.socket`
  - Rootful: `sudo systemctl enable --now podman.socket`
  - Manual: `podman system service -t 0`

---

## Build & Installation

```bash
# Build debug binary
zig build

# Build optimized release binary (./zig-out/bin/zigpod)
zig build -Doptimize=ReleaseSafe

# Or use the installer script (defaults to PREFIX=/usr/local)
./scripts/install.sh
```

---

## Usage Examples

```bash
# Show help or version
zigpod --help
zigpod --version
zigpod version

# Pull an image
zigpod pull alpine:3.20

# List local images
zigpod images

# Run a container (attached, auto-removed after logs are printed)
zigpod run --rm -e GREETING=hello alpine:3.20 sh -c 'echo "$GREETING from zigpod"'

# Run a container in the background with a name
zigpod run -d --name demo-alpine alpine:3.20 sleep 60

# List containers (-a includes stopped containers)
zigpod ps
zigpod ps -a

# Fetch container logs
zigpod logs demo-alpine

# Stop and remove a container
zigpod stop demo-alpine
zigpod rm -f demo-alpine
```

### Global Options

- `-v, --verbose` — แสดงข้อความระดับ `INFO` / `DEBUG` บน stderr ด้วย
- `--socket PATH` — ระบุ path ของ Unix socket เอง (รองรับทั้ง `/path/to.sock` และ `unix:///path/to.sock`)
- `-h, --help` — แสดงวิธีใช้งาน
- `--version` — แสดงเวอร์ชันของ client

---

## Configuration & Logging

### Socket Resolution Order

1. `--socket PATH`
2. `$ZIGPOD_SOCKET`
3. `$CONTAINER_HOST` หรือ `$DOCKER_HOST` (หากขึ้นต้นด้วย `unix://`)
4. `$XDG_RUNTIME_DIR/podman/podman.sock` (ถ้ามีไฟล์อยู่จริง)
5. `/run/podman/podman.sock`

### Log Files (`system.log` & `error.log`)

- บันทึกไฟล์ลงใน `$ZIGPOD_LOG_DIR` หรือโฟลเดอร์ปัจจุบัน (`.`) โดยอัตโนมัติ
- **`system.log`**: บันทึกทุกเหตุการณ์ (`DEBUG`, `INFO`, `WARN`, `ERROR`) พร้อมเวลา UTC แบบ ISO-8601
- **`error.log`**: บันทึกเฉพาะข้อความระดับ `ERROR` เพื่อให้ตรวจสอบข้อผิดพลาดได้ทันที

---

## Running Tests

```bash
zig build test
```

ชุด unit test ครอบคลุม:
- CLI argument/flag parsing และ error-path leak check (`src/cli.zig`)
- Configuration & socket URI stripping (`src/config.zig`)
- HTTP/1.1 response parsing (`Content-Length` และ `Transfer-Encoding: chunked`), malformed chunked/CRLF injection rejection และ mock Unix-socket round-trip (`src/http.zig`)
- File logger & UTC timestamp formatting (`src/log.zig`)
- Helper formatting (`src/utils.zig`)
- Container ID/name validation, Docker stream log demultiplexing, JSON response deserialization และ mock Unix-socket end-to-end lifecycle (`src/podman_api.zig`)

---

## Security & Memory Testing

- **Memory Leak Detection**:
  - ทุก `test` block ใช้ `std.testing.allocator` เพื่อตรวจจับ memory leak, double-free และ invalid free โดยอัตโนมัติ
  - ใน runtime (`src/main.zig`) ใช้ `std.heap.GeneralPurposeAllocator` และตรวจสอบ `gpa.deinit() == .leak` ก่อนออกจากโปรแกรม
- **Input & Protocol Hardening**:
  - `http.validateRequestTarget` ป้องกัน CRLF/header injection และ whitespace ใน HTTP request path
  - `http.decodeChunked` ใช้ checked arithmetic (`std.math.add`) และตรวจสอบ CRLF trailer ของทุก chunk เพื่อป้องกัน integer overflow และ out-of-bounds read
  - `podman_api.validateIdentifier` ป้องกัน path traversal (`..`, `/`) และ query/header injection บน container ID และ name
- **Automated Security Check Script**:

```bash
./scripts/security-check.sh
```

- **Optional Balor (`balorsh`) Integration**:
  - หากติดตั้ง `balorsh` (`/usr/local/bin/balorsh` / `/opt/balorsh`) สามารถใช้ `balorsh llm` (persona `loganalyst` / `blueteam`) เพื่อวิเคราะห์ไฟล์ `system.log` และ `error.log` รวมถึงใช้ `balorsh networkscan` / `webexploit` ทดสอบ container service ที่เปิดพอร์ตผ่าน ZigPod ได้

---

## Extending the CLI

1. เพิ่ม variant ใน `Command` และ parser logic ใน [src/cli.zig](src/cli.zig)
2. เพิ่ม request/response struct และฟังก์ชัน HTTP endpoint ใน [src/podman_api.zig](src/podman_api.zig)
3. เชื่อมต่อ subcommand ในฟังก์ชัน `dispatch` ของ [src/main.zig](src/main.zig)
4. เพิ่ม unit test ในโมดูลที่เกี่ยวข้องแล้วรัน `zig build test`


## Hardening, Self-Test, Audit & Knowledge Graph

### Container Hardening Flags (`zigpod run`)

Apply defense-in-depth limits in `HostConfig` when launching containers:

- `-m, --memory <SIZE>`: Memory limit (`b`, `k`, `m`, `g` suffixes supported with checked `std.math.mul`)
- `--pids-limit <N>`: Maximum container process count
- `--read-only`: Mount the container root filesystem read-only (`ReadonlyRootfs`)
- `--no-new-privileges`: Set `SecurityOpt: ["no-new-privileges"]`

```bash
zigpod run --rm -m 64m --pids-limit 32 --read-only --no-new-privileges alpine:3.20 echo ok
```

### Built-In 14-Case Fail-Closed Self-Test (`zigpod demo`)

Run the deterministic 14-case `ALLOW`/`DENY` verification suite locally (no running Podman daemon required):

```bash
zigpod demo
# or via Makefile:
make demo
```

### Tamper-Evident Audit Log (`zigpod audit`)

In addition to `system.log` and `error.log`, `Logger` maintains a SHA-256 hash-chained `audit.log`. Verify chain integrity with:

```bash
zigpod audit              # checks audit.log in configured log_dir
zigpod audit /path/to.log # checks a specific audit log file
```

### Verification & Offline Knowledge Graph CLI

Use the top-level [Makefile](Makefile) and verification scripts to keep builds, CI, docs, and static checks in sync:

```bash
make verify          # run tests, security gate, ReleaseSafe build, demo, E2E smoke, parity, graph update
make check-ci        # verify CI workflow, Makefile, CLI, vault docs, and README parity
make e2e             # run scripts/smoke.sh (mock Unix socket + hardened run + audit tamper test)
python3 scripts/graph-query.py update
python3 scripts/graph-query.py query "memory"
python3 scripts/graph-query.py explain verifyAuditFile
python3 scripts/graph-query.py path BUG-002 cli.zig
```
