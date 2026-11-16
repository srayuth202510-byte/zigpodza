# ZigPod

**ZigPod** เป็นโปรแกรม CLI ภาษา Zig ที่ทำงานในลักษณะเดียวกับ `podman` / `docker` โดยสื่อสารกับ **Podman REST API (Docker-compatible v1.40)** ผ่าน Unix domain socket ด้วย standard library ของ Zig ล้วน ๆ (ไม่พึ่งพา external library)

A minimal Docker/Podman-compatible CLI written in pure Zig (`>= 0.17.1`) that communicates with the Podman REST API over a Unix domain socket.

---

## Architecture

```mermaid
flowchart TD
    CLI["src/main.zig + src/cli.zig\n(Arg parsing & dispatch)"] --> CFG["src/config.zig\n(Socket & log dir resolution)"]
    CLI --> POL["src/policy.zig + zigpod-policy.json\n(Fail-closed sandbox guardrails)"]
    CLI --> API["src/podman_api.zig + src/podman_types.zig\n(Podman/Docker v1.40 REST API)"]
    POL --> API
    API --> HTTP["src/http.zig\n(HTTP/1.1, chunked streaming & 101 upgrade)"]
    HTTP --> SOCK[("Podman Socket\n/run/podman/podman.sock")]
    CLI --> LOG["src/log.zig + src/utils.zig\n(system.log, error.log & audit.log)"]
    API --> LOG
```

---

## Project Structure

```text
zigpodza/
├─ src/
│  ├─ main.zig         # CLI entry point, dispatch & error/DENY reporting
│  ├─ cli.zig          # Subcommand & flag parser
│  ├─ config.zig       # Socket path & log directory resolution
│  ├─ demo.zig         # 18-case fail-closed ALLOW/DENY self-test suite
│  ├─ http.zig         # HTTP/1.1 Unix-socket client (Content-Length, chunked streaming, 101 upgrade, RawTermGuard)
│  ├─ podman_types.zig # Podman/Docker v1.40 DTO structs, JSON serializers & stats calculators
│  ├─ podman_api.zig   # Docker/Podman v1.40 API endpoints, security validators & LogDemuxer
│  ├─ podman_build.zig # Deterministic ustar build-context archiver & POST /v1.40/build client
    │  ├─ podman_pods.zig  # Libpod /v4.0.0/libpod/pods lifecycle endpoints
    │  ├─ podman_transfer.zig # search/save/load/export/import tar-stream transfer endpoints
│  ├─ policy.zig       # --profile=sandbox & zigpod-policy.json pre-flight engine
│  ├─ log.zig          # Timestamped file logger (system.log, error.log & SHA-256 hash-chained audit.log)
│  └─ utils.zig        # Formatting helpers (shortId, formatSize)
├─ scripts/
│  ├─ auto-audit.sh      # Static memory & security invariant checks
│  ├─ bug-dashboard.py   # Bug tracking dashboard generator & local web UI
│  ├─ check-ci-parity.py # CI workflow, Makefile, CLI, vault & README parity verifier
│  ├─ graph-query.py     # Offline Knowledge Graph CLI
│  ├─ install.sh         # Build ReleaseSafe binary and install to PATH
│  ├─ knowledge-sync.py  # Automatic Knowledge Graph, Bug-Dashboard & hook/pre-commit drift sync
│  ├─ security-check.sh  # Run leak/security tests, ELF hardening, and optional balorsh check
│  └─ smoke.sh           # 4-stage parity, graph, static audit, and mock-daemon E2E test suite
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
├─ zigpod-policy.json  # Fail-closed sandbox security policy guardrails
├─ projectplan.md      # Initial design document
├─ audit.log           # SHA-256 hash-chained tamper-evident audit log
├─ system.log          # Runtime system & info/debug/warn/error/deny log
├─ error.log           # Runtime error-only log
└─ LICENSE             # MIT License
```

---

## Prerequisites

- **Zig** `0.17.1` or newer (the code uses the `std.Io` interface introduced after 0.13; older compilers cannot build it). `make` and `scripts/` locate a suitable toolchain automatically via `scripts/find-zig.sh`, even when an older `zig` is first on `PATH`.
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

# Run with the fail-closed sandbox profile (enforces zigpod-policy.json guardrails)
zigpod run --rm --profile=sandbox alpine:3.20 id

# Run an interactive TTY shell inside a container
zigpod run --rm -it alpine:3.20 sh

# Run a container in the background with a name
zigpod run -d --name demo-alpine alpine:3.20 sleep 60

# List containers (-a includes stopped containers, --json outputs structured JSON)
zigpod ps
zigpod ps -a
zigpod ps -a --json
zigpod images --json

# Fetch or stream container logs (-f follows live output)
zigpod logs demo-alpine
zigpod logs -f demo-alpine

# Snapshot or stream container CPU, memory, and PID resource usage (--json for automation)
zigpod stats --no-stream
zigpod stats --no-stream demo-alpine
zigpod stats --json demo-alpine

# List running processes inside a container or send an allow-listed signal
zigpod top demo-alpine
zigpod kill -s SIGTERM demo-alpine

# Manage named volumes, container networks, and check daemon/disk status
zigpod volume ls
zigpod volume create app-data
zigpod volume inspect app-data
zigpod volume rm app-data
zigpod network ls
zigpod network create --driver bridge --internal iso-net
zigpod network inspect iso-net
zigpod network rm -f iso-net
zigpod system ping
zigpod system df
zigpod system prune -f

# Inspect a container or image (state, IP, mounts, hardening limits)
zigpod inspect demo-alpine
zigpod inspect alpine:3.20

# Run a command in a live container or attach to a running container's stdio (-i/-t/-it)
zigpod exec demo-alpine ls -la
zigpod exec -it demo-alpine sh
zigpod attach -it demo-alpine

# Copy files/directories between host and container (two-pass Tar-Slip & symlink-safe)
zigpod cp ./config.json demo-alpine:/etc/app/
zigpod cp demo-alpine:/var/log/app.log ./app.log

# Verify the SHA-256 hash-chained audit log (plain or structured JSON with DENY telemetry)
zigpod audit
zigpod audit --json

# Tag, history, and commit images
zigpod tag alpine:3.20 myrepo/app:v1
zigpod history alpine:3.20
zigpod commit -m "snapshot" -a "alice" demo-alpine myrepo/snap:v2

# Search a registry, then move image/container tarballs in and out of the daemon
zigpod search alpine
zigpod save -o /srv/images/alpine.tar alpine:3.20
zigpod load -i /srv/images/alpine.tar
zigpod export -o /srv/images/rootfs.tar demo-alpine
zigpod import /srv/images/rootfs.tar myrepo/app:v2

# Pause, unpause, rename, restart, stop, and remove a container or image
zigpod pause demo-alpine
zigpod unpause demo-alpine
zigpod rename demo-alpine demo-renamed
zigpod restart -t 5 demo-renamed
zigpod stop demo-renamed
zigpod start demo-renamed
zigpod rm -f demo-renamed
zigpod rmi alpine:3.20
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
- Container/image inspect (`inspect` → `GET /containers/{id}/json` แล้ว fallback `GET /images/{name}/json`) พร้อม `validateResourceRef()` ป้องกัน request-line injection (`src/podman_api.zig`)
- Exec (`exec` → `POST /containers/{id}/exec` + `POST /exec/{id}/start` + `GET /exec/{id}/json`) ทั้งโหมดปกติและ interactive TTY (`101 Switching Protocols` + `RawTermGuard`), demultiplex output, propagation ของ exit code และ validation ของ exec ID (`src/podman_api.zig`)
- Container resource stats (`stats --no-stream` → `GET /containers/{id}/stats?stream=false`), streaming `pullImage`, `logs -f` (`LogDemuxer`), และ `attachContainer` (`src/podman_api.zig`, `src/podman_types.zig`)
- Sandbox security profile (`--profile=sandbox`), `zigpod-policy.json` pre-flight guardrails (`src/policy.zig`), `dispatch()` orphan cleanup (`BUG-012`) และ `DENY` audit JSON telemetry (`src/main.zig`, `src/log.zig`)
- Image/container transfer endpoints (`search` → `GET /images/search`, `save` → `GET /images/{ref}/get`, `export` → `GET /containers/{id}/export`, `load`/`import` → `POST /images/load`) พร้อม fail-closed host-path policy กับไฟล์ local และ blocking timeout สำหรับ tar transfer (`src/podman_transfer.zig`)
- Pod lifecycle endpoints (`pod create|ps|stop|rm`) ครบ happy/error/malformed/boundary path (`src/podman_pods.zig`)
- Mock Unix-socket request framing helpers (`readHttpRequest`, `ScriptedReply`) (`src/podman_test_helpers.zig`)
- Deterministic PRNG property & fuzz tests สำหรับ `parseResponse`/`decodeChunked`, `demuxLogs`/`LogDemuxer`, `parseMemoryBytes`/`cli.parse`, และ `verifyAuditFile`/`writeAuditJson`

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
  - `podman_api.validateResourceRef` (BUG-017) จำกัด `inspect` target ให้เป็น image/container reference เท่านั้น (ตัด space, control char, `?`, `#`) เพื่อป้องกัน HTTP request-line injection
  - `podman_api.createExec`/`startExec`/`startExecInteractive`/`inspectExec` (BUG-018) ตรวจ container ID, `--user`, `--workdir` และ exec ID ที่ได้จาก daemon ก่อนนำไปประกอบ URL, demultiplex output stream และคืนค่า exit code ของคำสั่ง
  - `policy.applySandboxDefaults` / `policy.checkRunPolicy` (BUG-019) บังคับค่าเริ่มต้นแบบ fail-closed สำหรับ `--profile=sandbox` และตรวจเพดานทุกข้อกับ `zigpod-policy.json` แบบ pre-flight ก่อนคุยกับ daemon พร้อมบันทึก `Logger.deny` ลง hash-chained `audit.log`
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
- `--profile=sandbox`: Apply fail-closed sandbox defaults (`--read-only`, `--no-new-privileges`, `--cap-drop=ALL`, `--network=none`, `--pids-limit=64`, `--memory=256m`, `--cpus=1`, bounded `/tmp` tmpfs) and enforce `zigpod-policy.json` (`max_nano_cpus`, `max_memory_bytes`, `max_pids_limit`)
- `--policy <FILE>`: Enforce a custom `zigpod-policy.json` guardrail file pre-flight
- `--cpus <N>`: CPU quota (`HostConfig.NanoCpus`, up to `64.0` or `policy.max_nano_cpus` in sandbox)
- `--env-file <FILE>`: Load `KEY=VALUE` environment entries from a verified non-symlink regular host file before pre-flight secret checks (repeatable)
- `-l, --label <KEY=VALUE>`: Attach container labels (`Labels`, repeatable)
- `--entrypoint <CMD>`: Override container image entrypoint (`Entrypoint`)
- `--hostname <NAME>`: Set RFC-1123 container hostname (`Hostname`, max 64 chars)
- `--restart <POLICY>`: Restart policy (`no`, `always`, `unless-stopped`, `on-failure[:N]`)
- `--shm-size <SIZE>`: Size of `/dev/shm` (`HostConfig.ShmSize`, up to 64 GiB or `policy.max_shm_bytes` in sandbox)
- `--ulimit <NAME=SOFT[:HARD]>`: Set container rlimit against an allow-list (`nofile`, `nproc`, `fsize`, `core`, `memlock`, `stack`, `data`, `cpu`, `as`, repeatable)
- `--init`: Run a minimal init process as PID 1 inside the container (`HostConfig.Init`)
- `--health-cmd <CMD>` / `--health-interval <DUR>`: Configure container healthcheck (`Healthcheck.Test` and `Interval` with `ms`/`s`/`m`/`h`)
- `zigpod compose up|down|ps [-f FILE]`: Pure-Zig Compose-lite stack manager with `depends_on` topological sorting, cycle rejection, and sandbox policy checks
- `-i, --interactive` / `-t, --tty` (`-it`): Attach interactive stdin and allocate a pseudo-TTY over HTTP `101 Switching Protocols`

```bash
zigpod run --rm -m 64m --pids-limit 32 --cpus 0.5 --read-only --no-new-privileges -l env=prod --hostname api-1 --restart on-failure:2 alpine:3.20 echo ok
zigpod run --rm --profile=sandbox alpine:3.20 echo sandbox-ok
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

#### Inspecting Containers & Images (`inspect`)

`zigpod inspect TARGET` tries `GET /containers/{id}/json` first and falls back to `GET /images/{name}/json` on `404`, printing a stable subset of fields: id, name, image, created, state/exit code, IP address, `WorkingDir`/`User`, `HostConfig` hardening limits (`NetworkMode`, `ReadonlyRootfs`, `Memory`, `PidsLimit`, `AutoRemove`, `CapDrop`/`CapAdd`, `SecurityOpt`), and mounts. `podman_api.validateResourceRef` (BUG-017) accepts image-reference characters (`/`, `:`, `@`) but rejects spaces, control characters, `?`, and `#` so the target cannot alter the HTTP request line.

#### Running Commands in a Live Container (`exec`)

`zigpod exec [OPTIONS] CONTAINER CMD...` creates an exec instance (`POST /containers/{id}/exec`), starts it (`POST /exec/{id}/start`), demultiplexes the Docker stream to stdout/stderr (or upgrades to HTTP `101 Switching Protocols` with `RawTermGuard` when `-i`/`-t`/`-it` is specified), then reads `GET /exec/{id}/json` and propagates the command's exit code as the CLI exit status. `-e/--env`, `-u/--user`, and `-w/--workdir` are validated with the same validators as `run`; the daemon-allocated exec ID is re-validated with `validateIdentifier` before it is reused in a URL (BUG-018). The start call uses the blocking socket timeout so long-running commands are not cut off.

### Built-In 18-Case Fail-Closed Self-Test (`zigpod demo`)

Run the deterministic 18-case `ALLOW`/`DENY` verification suite locally (no running Podman daemon required):

```bash
zigpod demo
# or via Makefile:
make demo
```

### Tamper-Evident Audit Log (`zigpod audit`)

In addition to `system.log` and `error.log`, `Logger` maintains a SHA-256 hash-chained `audit.log` and records security policy violations as structured `DENY` events. Verify chain integrity or export JSON telemetry for `balorsh` / SIEM analysis with:

```bash
zigpod audit                    # checks audit.log in configured log_dir
zigpod audit /path/to.log       # checks a specific audit log file
zigpod audit --json             # outputs structured JSON with valid/entries/deny_events/deny_records
```

### Verification & Offline Knowledge Graph CLI

Use the top-level [Makefile](Makefile) and verification scripts to keep builds, CI, docs, and static checks in sync:

```bash
make verify          # run tests, security gate, ReleaseSafe build, demo, E2E smoke, parity, graph update
make test-one T=compose   # run only tests matching a substring (-Dtest-filter)
make check-ci        # verify CI workflow, Makefile, CLI, vault docs, and README parity
make e2e             # run scripts/smoke.sh (mock Unix socket + hardened run + audit tamper test)
make real-e2e        # run scripts/podman-e2e.sh against a live Podman daemon (skips if unavailable)
ZIGPOD_TRACE=1 zigpod --verbose ps   # print @errorReturnTrace() stack on unexpected failures
python3 scripts/graph-query.py update
python3 scripts/graph-query.py query "memory"
python3 scripts/graph-query.py explain verifyAuditFile
python3 scripts/graph-query.py path BUG-002 cli.zig
make triage ERR=InvalidShmSize   # map error/rule to throw sites, BUG-NNN, and matching tests
make debug-logs N=15             # summarize top errors in error.log and recent audit DENY events

# Bug Tracking Dashboard (CLI / Obsidian Note / Web UI)
make bugs            # terminal summary of tracked bugs, module tests, and security gates
make dashboard       # update docs/vault/Bug-Dashboard.md & .zig-cache/bug-dashboard.html
make knowledge-sync  # auto-sync graph/dashboard + detect unrecorded src/ BUG-NNN/validator/error gaps
make distill-lessons # distill error.log + Bug-Playbook patterns into docs/vault/Lessons-Learned.md
make install-hooks   # activate tracked .githooks/pre-commit (pairs with .agents/hooks.json Stop hook)
make dashboard-serve # start local web UI on http://127.0.0.1:8765
python3 scripts/bug-dashboard.py summary --json
```
