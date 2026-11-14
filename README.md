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

# Bind-mount a host directory read-only (default) and a writable cache
zigpod run --rm -v /srv/data:/data -v /srv/cache:/cache:rw alpine:3.20 ls /data

# Mount a Podman-managed named volume
zigpod run --rm -v myvol:/var/lib/data alpine:3.20 ls /var/lib/data

# Publish container ports (TCP by default, repeatable, IPv4 host address optional)
zigpod run --rm -p 8080:80 -p 127.0.0.1:9000:9000/udp alpine:3.20 sleep 1

# Run with a hardened network/identity profile
zigpod run --rm --network none -w /work -u 1000:1000 --cap-drop ALL --cap-add NET_BIND_SERVICE alpine:3.20 id

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
- Host bind-mount policy validator (`validateHostPath`), bind/volume mount classification และ `Mounts` JSON serialization (`src/podman_api.zig`)
- Port-publishing validator (`validatePortMapping`), `ExposedPorts`/`PortBindings` JSON serialization และ CLI `-p` parsing (`src/cli.zig`, `src/podman_api.zig`)
- Network/identity/capability validators (`validateNetworkMode`, `validateWorkdir`, `validateUser`, `validateCapability`) และ CLI `--network`/`-w`/`-u`/`--cap-*` parsing (`src/cli.zig`, `src/podman_api.zig`)

---

## Security & Memory Testing

- **Memory Leak Detection**:
  - ทุก `test` block ใช้ `std.testing.allocator` เพื่อตรวจจับ memory leak, double-free และ invalid free โดยอัตโนมัติ
  - ใน runtime (`src/main.zig`) ใช้ `std.heap.GeneralPurposeAllocator` และตรวจสอบ `gpa.deinit() == .leak` ก่อนออกจากโปรแกรม
- **Input & Protocol Hardening**:
  - `http.validateRequestTarget` ป้องกัน CRLF/header injection และ whitespace ใน HTTP request path
  - `http.decodeChunked` ใช้ checked arithmetic (`std.math.add`) และตรวจสอบ CRLF trailer ของทุก chunk เพื่อป้องกัน integer overflow และ out-of-bounds read
  - `podman_api.validateIdentifier` ป้องกัน path traversal (`..`, `/`) และ query/header injection บน container ID และ name
  - `podman_api.validateHostPath` (BUG-014) บังคับ **fail-closed host mount policy**: บล็อกการ bind-mount `/`, `/etc`, `/proc`, `/sys`, `/dev`, `/boot`, `/run`, `/var/run`, `/var/lib/docker`, `/var/lib/containers`, `/root` และบังคับ default `:ro` สำหรับ sensitive paths
  - `podman_api.validatePortMapping` (BUG-015) ปฏิเสธพอร์ตนอกช่วง `1..65535`, โปรโตคอลที่ไม่อยู่ใน allow-list (`tcp`/`udp`/`sctp`) และ host address ที่ไม่ใช่ IPv4 literal ก่อนส่งคำขอไปยัง daemon
  - `podman_api.validateNetworkMode` / `validateWorkdir` / `validateUser` / `validateCapability` (BUG-016) จำกัด `--network` เป็น allow-list, บังคับ `--workdir` เป็น absolute traversal-free path, ตรวจรูปแบบ `--user` และปฏิเสธชื่อ capability ที่ไม่ใช่ `ALL`/uppercase ก่อนส่งคำขอไปยัง daemon
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
- `-v, --volume SRC:DST[:ro|rw]`: Bind-mount a host path or named volume (repeatable, default **read-only**)
- `-p, --publish [IP:]HOST:CONTAINER[/tcp|udp|sctp]`: Publish a container port (repeatable)
- `--network <MODE>`: Network mode, one of `none`, `bridge`, `host`, `pasta`, `slirp4netns` (`HostConfig.NetworkMode`)
- `-w, --workdir <PATH>`: Container working directory (`WorkingDir`)
- `-u, --user <USER[:GROUP]>`: Run as user (and optional group) (`User`)
- `--cap-drop <CAP>` / `--cap-add <CAP>`: Drop/add a Linux capability, repeatable (`HostConfig.CapDrop` / `CapAdd`)

```bash
zigpod run --rm -m 64m --pids-limit 32 --read-only --no-new-privileges alpine:3.20 echo ok
```

#### Host Path Policy Validator (`-v`)

`podman_api.validateHostPath` (BUG-014) is fail-closed. Every `-v` source is validated **before** any request reaches the daemon:

- Sources starting with `/` are treated as **bind mounts**; anything else is a **named volume** (name must be alphanumeric, `-`, `_`, `.`).
- Both host source and container target must be absolute, traversal-free (`..`/`.`/`//`/trailing-slash rejected), control-char-free, and ≤ 4096 bytes.
- Bind mounts default to **read-only**; pass `:rw` to opt out.
- The following host subtrees are always rejected: `/`, `/etc` (except a read-only allow-list of `/etc/localtime`, `/etc/timezone`, `/etc/hosts`, `/etc/resolv.conf`, `/etc/nsswitch.conf`, `/etc/hostname`), `/proc`, `/sys`, `/dev`, `/boot`, `/run`, `/var/run`, `/var/lib/docker`, `/var/lib/containers`, and `/root`.
- Sensitive allow-listed `/etc` files may only be mounted read-only (`:rw` is rejected).

#### Port Publishing Policy (`-p`)

`podman_api.validatePortMapping` (BUG-015) validates every `-p` mapping **before** any request reaches the daemon:

- Accepted forms: `CONTAINER`, `CONTAINER/proto`, `HOST:CONTAINER[/proto]`, and `IPV4:HOST:CONTAINER[/proto]` (the host address must be a valid IPv4 literal).
- Container and host ports must be in `1..65535`; the protocol allow-list is `tcp` (default), `udp`, and `sctp`.
- Container ports are emitted in `ExposedPorts` (`{"80/tcp":{}}`); mappings with an explicit host port also populate `HostConfig.PortBindings` (`{"80/tcp":[{"HostIp":"127.0.0.1","HostPort":"8080"}]}`).

#### Network, Identity & Capability Policy (`--network` / `-w` / `-u` / `--cap-*`)

`podman_api.validateNetworkMode`, `validateWorkdir`, `validateUser`, and `validateCapability` (BUG-016) validate every identity/network flag **before** any request reaches the daemon:

- `--network` is restricted to the allow-list `none`, `bridge`, `host`, `pasta`, and `slirp4netns`; arbitrary values are rejected so the daemon never receives unexpected network configuration.
- `-w/--workdir` reuses the container-path policy: absolute, traversal-free (`..`/`.`/`//`/trailing-slash rejected), control-char-free, and ≤ 4096 bytes.
- `-u/--user` accepts `USER` or `USER:GROUP`, where each field is alphanumeric plus `_`, `-`, `.` and does not start with `-`/`.`.
- `--cap-drop`/`--cap-add` accept `ALL` or an uppercase `[A-Z][A-Z0-9_]*` capability name (e.g. `NET_ADMIN`); lowercase names and injection characters are rejected.
- `createContainer` re-validates all of these (defense in depth) before serializing the request.

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

# Bug Tracking Dashboard (CLI / Obsidian Note / Web UI)
make bugs            # terminal summary of tracked bugs, module tests, and security gates
make dashboard       # update docs/vault/Bug-Dashboard.md & .zig-cache/bug-dashboard.html
make dashboard-serve # start local web UI on http://127.0.0.1:8765
python3 scripts/bug-dashboard.py summary --json
```
