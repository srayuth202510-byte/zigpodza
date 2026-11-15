#!/usr/bin/env sh
# End-to-end smoke verification script for ZigPod.
# Tests knowledge graph CLI, static audit gates, and (when zig or a built
# binary is present) compiled CLI behavior + mock Unix socket + audit tampering.

set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

TMPDIR=$(mktemp -d /tmp/zigpod-smoke-XXXXXX)
SERVER_PID=""
cleanup() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$TMPDIR"
}
trap cleanup EXIT INT TERM

echo "==> [1/4] CI/docs/Makefile parity"
python3 scripts/check-ci-parity.py

echo "==> [2/4] Offline Knowledge Graph CLI"
python3 scripts/graph-query.py update
python3 scripts/graph-query.py query "BUG-002" >/dev/null
python3 scripts/graph-query.py explain verifyAuditFile >/dev/null
python3 scripts/graph-query.py path bug:BUG-002 module:src/cli.zig >/dev/null
python3 scripts/bug-dashboard.py generate >/dev/null
[ -f .zig-cache/bug-dashboard.html ] && [ -f docs/vault/Bug-Dashboard.md ]
echo "[PASS] graph-query and bug-dashboard generation succeeded."

echo "==> [3/4] Static memory & security audit"
./scripts/auto-audit.sh

echo "==> [4/4] Runtime CLI & tamper-evident audit E2E"
BIN="$ROOT_DIR/zig-out/bin/zigpod"
if [ ! -x "$BIN" ]; then
    if command -v zig >/dev/null 2>&1; then
        zig build -Doptimize=ReleaseSafe
    else
        echo "[SKIP] 'zig' not installed and zig-out/bin/zigpod absent; skipping compiled binary E2E."
        exit 0
    fi
fi

export ZIGPOD_LOG_DIR="$TMPDIR/logs"
mkdir -p "$ZIGPOD_LOG_DIR"

"$BIN" --help | grep -q "audit"
"$BIN" --version | grep -q "zigpod version"
"$BIN" demo | grep -q "18/18 cases passed"

SOCK="$TMPDIR/smoke.sock"
REQ_LOG="$TMPDIR/captured-req.txt"
export ZP_SMOKE_SOCK="$SOCK"
export ZP_SMOKE_REQ="$REQ_LOG"

python3 - <<'PY' &
import io
import os
import socket
import tarfile

sock_path = os.environ["ZP_SMOKE_SOCK"]
req_path = os.environ["ZP_SMOKE_REQ"]
if os.path.exists(sock_path):
    os.unlink(sock_path)

srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(sock_path)
srv.listen(8)

def read_req(conn):
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = conn.recv(4096)
        if not chunk:
            break
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    cl = 0
    for line in head.decode("latin1").split("\r\n"):
        if line.lower().startswith("content-length:"):
            cl = int(line.split(":", 1)[1].strip())
    while len(rest) < cl:
        chunk = conn.recv(4096)
        if not chunk:
            break
        rest += chunk
    return head + b"\r\n\r\n" + rest[:cl]

def reply(conn, status, body=b""):
    hdr = f"HTTP/1.1 {status}\r\nContent-Length: {len(body)}\r\n\r\n".encode("ascii")
    conn.sendall(hdr + body)

# Expect 35 requests: create, start, wait, logs, delete (--rm), ps -a, inspect, exec-create, exec-start, exec-inspect, stats-list, stats-one, kill, top, volume-ls, network-ls, search, save, load, export, import, network-create, network-rm, attach, cp-put, cp-get, compose-up (5), compose-ps (1), compose-down (3)
with open(req_path, "wb") as out:
    for step in range(35):
        conn, _ = srv.accept()
        try:
            req = read_req(conn)
            out.write(req + b"\n---REQ---\n")
            out.flush()
            if b"/containers/create" in req:
                reply(conn, "201 Created", b'{"Id":"smoke1234567890ab"}')
            elif req.startswith(b"POST ") and b"/containers/" in req and b"/start" in req:
                reply(conn, "204 No Content")
            elif req.startswith(b"POST ") and b"/containers/" in req and b"/wait" in req:
                reply(conn, "200 OK", b'{"StatusCode":0}')
            elif req.startswith(b"POST ") and b"/containers/" in req and b"/kill?signal=SIGKILL" in req:
                reply(conn, "204 No Content")
            elif req.startswith(b"GET ") and b"/containers/" in req and b"/top" in req:
                reply(conn, "200 OK", b'{"Titles":["UID","PID","CMD"],"Processes":[["root","4321","sleep 60"]]}')
            elif req.startswith(b"GET ") and b"/v1.40/volumes HTTP/1.1" in req:
                reply(conn, "200 OK", b'{"Volumes":[{"Name":"app-data","Driver":"local"}]}')
            elif req.startswith(b"GET ") and b"/v1.40/networks HTTP/1.1" in req:
                reply(conn, "200 OK", b'[{"Id":"abcdef0123456789","Name":"podman","Driver":"bridge","Scope":"local"}]')
            elif b"/logs" in req:
                reply(conn, "200 OK", b"\x01\x00\x00\x00\x00\x00\x00\x03ok\n")
            elif req.startswith(b"DELETE "):
                reply(conn, "204 No Content")
            elif b"/containers/json" in req:
                reply(conn, "200 OK", b'[{"Id":"smoke1234567890ab","Image":"alpine:3.20","Status":"Up","Names":["/smoke"]}]')
            elif req.startswith(b"GET ") and b"/stats?stream=false" in req:
                reply(conn, "200 OK", b'{"id":"smoke1234567890ab","name":"/smoke","cpu_stats":{"cpu_usage":{"total_usage":200000000},"system_cpu_usage":2000000000,"online_cpus":2},"precpu_stats":{"cpu_usage":{"total_usage":100000000},"system_cpu_usage":1000000000},"memory_stats":{"usage":67108864,"limit":268435456,"stats":{"inactive_file":16777216}},"pids_stats":{"current":12}}')
            elif req.startswith(b"GET ") and b"/json HTTP/1.1" in req and b"/containers/" in req:
                reply(conn, "200 OK", b'{"Id":"smoke1234567890ab","Name":"/smoke","Image":"alpine:3.20","State":{"Status":"exited","Running":false,"ExitCode":0},"Config":{"WorkingDir":"/work","User":"1000:1000"},"HostConfig":{"Memory":67108864,"PidsLimit":32,"ReadonlyRootfs":true,"NetworkMode":"none","CapDrop":["ALL"],"CapAdd":["NET_BIND_SERVICE"]},"NetworkSettings":{"IPAddress":"10.88.0.2"},"Mounts":[{"Type":"bind","Source":"/srv/data","Destination":"/data","RW":false}]}')
            elif req.startswith(b"POST ") and b"/containers/" in req and b"/exec" in req:
                reply(conn, "201 Created", b'{"Id":"exec123"}')
            elif req.startswith(b"POST ") and b"/exec/" in req and b"/start" in req:
                reply(conn, "200 OK", b"\x01\x00\x00\x00\x00\x00\x00\x0Bhello-exec\n")
            elif req.startswith(b"GET ") and b"/exec/" in req and b"/json" in req:
                reply(conn, "200 OK", b'{"Running":false,"ExitCode":0}')
            elif req.startswith(b"GET ") and b"/images/search?term=alpine" in req:
                reply(conn, "200 OK", b'[{"Description":"A minimal container","IsOfficial":true,"Name":"alpine","StarCount":9000}]')
            elif req.startswith(b"GET ") and b"/images/alpine:3.20/get" in req:
                reply(conn, "200 OK", b"TAR-PAYLOAD-SAVE")
            elif req.startswith(b"POST ") and b"/images/load?quiet=0" in req:
                reply(conn, "200 OK", b'{"status":"Loaded image: alpine:3.20"}')
            elif req.startswith(b"GET ") and b"/export" in req:
                reply(conn, "200 OK", b"TAR-PAYLOAD-EXPORT")
            elif req.startswith(b"POST ") and b"/images/load?fromSrc=-&repo=" in req:
                reply(conn, "200 OK", b'{"status":"Imported"}')
            elif req.startswith(b"POST ") and b"/v1.40/networks/create" in req:
                reply(conn, "201 Created", b'{"Id":"net_smoke","Warning":""}')
            elif req.startswith(b"DELETE ") and b"/v1.40/networks/smoke-net?force=true" in req:
                reply(conn, "204 No Content", b"")
            elif req.startswith(b"POST ") and b"/v1.40/containers/c1/attach" in req:
                conn.sendall(b"HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\nattach-smoke-ok\n")
            elif req.startswith(b"PUT ") and b"/v1.40/containers/c1/archive" in req:
                reply(conn, "200 OK", b"")
            elif req.startswith(b"GET ") and b"/v1.40/containers/c1/archive" in req:
                bio = io.BytesIO()
                with tarfile.open(fileobj=bio, mode="w", format=tarfile.USTAR_FORMAT) as tf:
                    data = b"cp-smoke-from-ctr\n"
                    ti = tarfile.TarInfo("cp.txt")
                    ti.size = len(data)
                    ti.mode = 0o644
                    tf.addfile(ti, io.BytesIO(data))
                reply(conn, "200 OK", bio.getvalue())
            else:
                reply(conn, "404 Not Found", b'{"message":"unexpected"}')
        finally:
            conn.close()
srv.close()
PY
SERVER_PID=$!

# Wait briefly for socket creation
i=0
while [ ! -S "$SOCK" ] && [ "$i" -lt 40 ]; do
    sleep 0.05
    i=$((i + 1))
done
[ -S "$SOCK" ]

SMOKE_WORK=$(dirname "$SOCK")
ENV_FILE="$SMOKE_WORK/smoke.env"
cat > "$ENV_FILE" <<'EOF'
# Smoke env file
FROM_ENV_FILE=yes
EOF

RUN_OUT=$("$BIN" --socket "$SOCK" run --rm -m 64m --shm-size 32m --pids-limit 32 --cpus 0.5 --ulimit nofile=1024:2048 --init --health-cmd "true" --health-interval 10s --env-file "$ENV_FILE" -l app=smoke --entrypoint /bin/echo --hostname smoke-host --restart on-failure:2 --read-only --no-new-privileges -v /srv/data:/data -p 8080:80 -p 127.0.0.1:9000:9000/udp --network none -w /work -u 1000:1000 --cap-drop ALL --cap-add NET_BIND_SERVICE alpine:3.20 echo ok)
echo "$RUN_OUT" | grep -q "ok"
grep -q '"ReadonlyRootfs":true' "$REQ_LOG"
grep -q '"Init":true' "$REQ_LOG"
grep -q '"ShmSize":33554432' "$REQ_LOG"
grep -q '"Ulimits":\[{"Name":"nofile","Soft":1024,"Hard":2048}\]' "$REQ_LOG"
grep -q '"Healthcheck":{"Test":\["CMD-SHELL","true"\],"Interval":10000000000}' "$REQ_LOG"
grep -q '"NanoCpus":500000000' "$REQ_LOG"
grep -q '"FROM_ENV_FILE=yes"' "$REQ_LOG"
grep -q '"Labels":{"app":"smoke"}' "$REQ_LOG"
grep -q '"Entrypoint":\["/bin/echo"\]' "$REQ_LOG"
grep -q '"Hostname":"smoke-host"' "$REQ_LOG"
grep -q '"RestartPolicy":{"Name":"on-failure","MaximumRetryCount":2}' "$REQ_LOG"
grep -q '"Memory":67108864' "$REQ_LOG"
grep -q '"PidsLimit":32' "$REQ_LOG"
grep -q '"SecurityOpt":\["no-new-privileges"\]' "$REQ_LOG"
grep -q '"Mounts":\[{"Type":"bind","Source":"/srv/data","Target":"/data","ReadOnly":true}\]' "$REQ_LOG"
grep -q '"ExposedPorts":{"80/tcp":{},"9000/udp":{}}' "$REQ_LOG"
grep -q '"PortBindings":{"80/tcp":\[{"HostPort":"8080"}\],"9000/udp":\[{"HostIp":"127.0.0.1","HostPort":"9000"}\]}' "$REQ_LOG"
grep -q '"NetworkMode":"none"' "$REQ_LOG"
grep -q '"WorkingDir":"/work"' "$REQ_LOG"
grep -q '"User":"1000:1000"' "$REQ_LOG"
grep -q '"CapDrop":\["ALL"\]' "$REQ_LOG"
grep -q '"CapAdd":\["NET_BIND_SERVICE"\]' "$REQ_LOG"

PS_OUT=$("$BIN" --socket "$SOCK" ps -a)
echo "$PS_OUT" | grep -q "smoke1234567"

INSPECT_OUT=$("$BIN" --socket "$SOCK" inspect smoke1234567890ab)
echo "$INSPECT_OUT" | grep -q "10.88.0.2"
echo "$INSPECT_OUT" | grep -q "NetworkMode:"
echo "$INSPECT_OUT" | grep -q "/srv/data -> /data (bind, ro)"

EXEC_OUT=$("$BIN" --socket "$SOCK" exec smoke1234567890ab echo hello-exec)
echo "$EXEC_OUT" | grep -q "hello-exec"

STATS_OUT=$("$BIN" --socket "$SOCK" stats --no-stream)
echo "$STATS_OUT" | grep -q "20.00%"
echo "$STATS_OUT" | grep -q "48.0 MB / 256.0 MB"
echo "$STATS_OUT" | grep -q "12"

"$BIN" --socket "$SOCK" kill -s SIGKILL smoke1234567890ab
TOP_OUT=$("$BIN" --socket "$SOCK" top smoke1234567890ab)
echo "$TOP_OUT" | grep -q "4321"
VOL_OUT=$("$BIN" --socket "$SOCK" volume ls)
echo "$VOL_OUT" | grep -q "app-data"
NET_OUT=$("$BIN" --socket "$SOCK" network ls)
echo "$NET_OUT" | grep -q "podman"

SEARCH_OUT=$("$BIN" --socket "$SOCK" search alpine)
echo "$SEARCH_OUT" | grep -q "alpine"

SAVE_OUT=$("$BIN" --socket "$SOCK" save -o "$TMPDIR/save.tar" alpine:3.20)
echo "$SAVE_OUT" | grep -q "Saved alpine:3.20"
grep -q "TAR-PAYLOAD-SAVE" "$TMPDIR/save.tar"

LOAD_TAR="$TMPDIR/load.tar"
printf 'LOAD-TAR-PAYLOAD' > "$LOAD_TAR"
LOAD_OUT=$("$BIN" --socket "$SOCK" load -i "$LOAD_TAR")
echo "$LOAD_OUT" | grep -q "Loaded image: alpine:3.20"
grep -q "LOAD-TAR-PAYLOAD" "$REQ_LOG"

EXPORT_OUT=$("$BIN" --socket "$SOCK" export -o "$TMPDIR/export.tar" smoke1234567890ab)
echo "$EXPORT_OUT" | grep -q "Exported smoke1234567890ab"
grep -q "TAR-PAYLOAD-EXPORT" "$TMPDIR/export.tar"

IMPORT_TAR="$TMPDIR/import.tar"
printf 'IMPORT-TAR-PAYLOAD' > "$IMPORT_TAR"
IMPORT_OUT=$("$BIN" --socket "$SOCK" import "$IMPORT_TAR" "myrepo/app:v2")
echo "$IMPORT_OUT" | grep -q "Imported"
grep -q "IMPORT-TAR-PAYLOAD" "$REQ_LOG"

NET_CREATE_OUT=$("$BIN" --socket "$SOCK" network create --internal smoke-net)
echo "$NET_CREATE_OUT" | grep -q "net_smoke"
"$BIN" --socket "$SOCK" network rm -f smoke-net >/dev/null

ATTACH_OUT=$("$BIN" --socket "$SOCK" attach c1)
echo "$ATTACH_OUT" | grep -q "attach-smoke-ok"

CP_SRC="$SMOKE_WORK/cp-upload.txt"
CP_DST="$SMOKE_WORK/cp-download.txt"
printf 'CP-SMOKE-UPLOAD\n' > "$CP_SRC"
"$BIN" --socket "$SOCK" cp "$CP_SRC" c1:/tmp >/dev/null
grep -q "CP-SMOKE-UPLOAD" "$REQ_LOG"
"$BIN" --socket "$SOCK" cp c1:/tmp/cp.txt "$CP_DST" >/dev/null
grep -q "cp-smoke-from-ctr" "$CP_DST"

COMPOSE_FILE="$TMPDIR/compose.yaml"
cat > "$COMPOSE_FILE" <<'YAML'
name: smokecomp
networks:
  smokecomp_net:
    driver: bridge
    internal: true
services:
  web:
    image: alpine:3.20
    depends_on: [db]
    init: true
    shm_size: 32m
    mem_limit: 128m
  db:
    image: alpine:3.20
YAML
COMPOSE_UP_OUT=$("$BIN" --socket "$SOCK" compose up -f "$COMPOSE_FILE")
echo "$COMPOSE_UP_OUT" | grep -q "smokecomp_db_1"
echo "$COMPOSE_UP_OUT" | grep -q "smokecomp_web_1"
grep -q '"Init":true' "$REQ_LOG"
grep -q '"ShmSize":33554432' "$REQ_LOG"
COMPOSE_PS_OUT=$("$BIN" --socket "$SOCK" compose ps -f "$COMPOSE_FILE")
echo "$COMPOSE_PS_OUT" | grep -q "alpine:3.20"
grep -q "com.docker.compose.project%3Dsmokecomp" "$REQ_LOG"
COMPOSE_DOWN_OUT=$("$BIN" --socket "$SOCK" compose down -f "$COMPOSE_FILE")
echo "$COMPOSE_DOWN_OUT" | grep -q "smokecomp_web_1 removed"
echo "$COMPOSE_DOWN_OUT" | grep -q "smokecomp_db_1 removed"

# Adversarial input must fail closed before reaching daemon.
if "$BIN" --socket "$SOCK" kill -s SIGBAD smoke1234567890ab >/dev/null 2>&1; then
    echo "[FAIL] expected invalid kill signal (SIGBAD) to fail closed" >&2
    exit 1
fi
if "$BIN" --socket "$SOCK" volume create ../evil >/dev/null 2>&1; then
    echo "[FAIL] expected traversal volume name (../evil) to fail closed" >&2
    exit 1
fi
if "$BIN" --socket "$SOCK" rm ../evil >/dev/null 2>&1; then
    echo "[FAIL] expected path traversal container identifier to fail" >&2
    exit 1
fi

if "$BIN" --socket "$SOCK" run -v /etc:/data alpine:3.20 >/dev/null 2>&1; then
    echo "[FAIL] expected dangerous host bind mount (/etc) to fail closed" >&2
    exit 1
fi

if "$BIN" --socket "$SOCK" run -p 0:80 alpine:3.20 >/dev/null 2>&1; then
    echo "[FAIL] expected invalid published port (0:80) to fail closed" >&2
    exit 1
fi

if "$BIN" --socket "$SOCK" run --network bogus alpine:3.20 >/dev/null 2>&1; then
    echo "[FAIL] expected invalid network mode (bogus) to fail closed" >&2
    exit 1
fi

if "$BIN" --socket "$SOCK" save -o /etc/shadow alpine:3.20 >/dev/null 2>&1; then
    echo "[FAIL] expected dangerous save output path (/etc/shadow) to fail closed" >&2
    exit 1
fi

if "$BIN" --socket "$SOCK" run --shm-size 0 alpine:3.20 >/dev/null 2>&1; then
    echo "[FAIL] expected invalid --shm-size (0) to fail closed" >&2
    exit 1
fi

COMPOSE_DENY_FILE="$TMPDIR/compose-deny.yaml"
cat > "$COMPOSE_DENY_FILE" <<'YAML'
name: smokedeny
services:
  app:
    image: alpine:3.20
    mem_limit: 512m
YAML
if "$BIN" --socket "$SOCK" compose up --profile=sandbox -f "$COMPOSE_DENY_FILE" >/dev/null 2>&1; then
    echo "[FAIL] expected compose up --profile=sandbox exceeding memory limit to fail closed" >&2
    exit 1
fi

if "$BIN" --socket "$SOCK" load -i /root/../etc/passwd >/dev/null 2>&1; then
    echo "[FAIL] expected traversal load input path (..) to fail closed" >&2
    exit 1
fi

if "$BIN" --socket "$SOCK" import "$IMPORT_TAR" 'bad?x=1' >/dev/null 2>&1; then
    echo "[FAIL] expected invalid import reference (bad?x=1) to fail closed" >&2
    exit 1
fi

if "$BIN" --socket "$SOCK" run --profile=sandbox -m 512m alpine:3.20 >/dev/null 2>&1; then
    echo "[FAIL] expected sandbox profile memory limit excess (512m > 256m) to fail closed pre-flight" >&2
    exit 1
fi

if "$BIN" --socket "$SOCK" run --profile=sandbox --cpus 2 alpine:3.20 >/dev/null 2>&1; then
    echo "[FAIL] expected sandbox profile CPU limit excess (2 > 1) to fail closed pre-flight" >&2
    exit 1
fi

SECRET_ENV="$SMOKE_WORK/secret.env"
cat > "$SECRET_ENV" <<'EOF'
API_KEY=sk-1234567890abcdef123456
EOF
if "$BIN" --socket "$SOCK" run --profile=sandbox --env-file "$SECRET_ENV" alpine:3.20 >/dev/null 2>&1; then
    echo "[FAIL] expected --env-file secret in sandbox profile to fail closed pre-flight" >&2
    exit 1
fi

if "$BIN" --socket "$SOCK" run --cpus 0 alpine:3.20 >/dev/null 2>&1; then
    echo "[FAIL] expected --cpus 0 to fail pre-flight validation" >&2
    exit 1
fi

BAD_COMPOSE="$SMOKE_WORK/bad-compose.yaml"
cat > "$BAD_COMPOSE" <<'EOF'
services:
  web:
    image: alpine:3.20
    network_mode: host
EOF
if "$BIN" --socket "$SOCK" compose up -f "$BAD_COMPOSE" --profile=sandbox >/dev/null 2>&1; then
    echo "[FAIL] expected compose up --profile=sandbox with network_mode: host to fail pre-flight" >&2
    exit 1
fi

rm -f "$SOCK"
wait "$SERVER_PID" || true
SERVER_PID=""

# Verify intact hash-chained audit.log (both plain and --json) and reject single-byte tamper.
"$BIN" audit "$ZIGPOD_LOG_DIR/audit.log" | grep -q "audit chain verified"
AUDIT_JSON=$("$BIN" audit --json "$ZIGPOD_LOG_DIR/audit.log")
echo "$AUDIT_JSON" | grep -q '"valid":true'
echo "$AUDIT_JSON" | grep -q '"rule":"policy.max_memory_bytes"'

TAMPERED="$TMPDIR/audit-tampered.log"
cp "$ZIGPOD_LOG_DIR/audit.log" "$TAMPERED"
python3 - "$TAMPERED" <<'PY'
import sys
p = sys.argv[1]
data = bytearray(open(p, "rb").read())
assert len(data) > 4
data[-2] ^= 0x01
open(p, "wb").write(data)
PY

if "$BIN" audit "$TAMPERED" >/dev/null 2>&1; then
    echo "[FAIL] tampered audit.log unexpectedly passed verification" >&2
    exit 1
fi

# Exercise Phase 6A Balor offline audit pipeline (attack-surface + purple-team + secret hygiene).
SAMPLE_INSP="$TMPDIR/inspect.json"
cat >"$SAMPLE_INSP" <<'JSON'
{
  "Id": "smoke1234567890",
  "Config": {"Env": ["API_TOKEN=ghp_1234567890abcdefghij123456"]},
  "HostConfig": {
    "ReadonlyRootfs": false,
    "CapDrop": [],
    "PidsLimit": 0,
    "PortBindings": {"80/tcp": [{"HostIp": "127.0.0.1", "HostPort": "8080"}]}
  },
  "NetworkSettings": {"IPAddress": "10.88.0.2"}
}
JSON
BALOR_JSON=$("$ROOT_DIR/scripts/balor-security-audit.sh" --offline --inspect-json "$SAMPLE_INSP" --json)
echo "$BALOR_JSON" | grep -q '"github-token"'
echo "$BALOR_JSON" | grep -q '"purple-team"'
echo "$BALOR_JSON" | grep -q '"attack-surface"'
echo "$BALOR_JSON" | grep -q '"DENY rule=policy.max_memory_bytes'

echo "[PASS] Compiled binary E2E, mock Podman hardening, and audit tampering detection passed."
