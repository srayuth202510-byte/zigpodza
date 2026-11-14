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
"$BIN" demo | grep -q "14/14 cases passed"

SOCK="/tmp/zp-smoke-$$.sock"
REQ_LOG="$TMPDIR/captured-req.txt"
export ZP_SMOKE_SOCK="$SOCK"
export ZP_SMOKE_REQ="$REQ_LOG"

python3 - <<'PY' &
import os
import socket

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

# Expect 7 requests: create, start, wait, logs, delete (--rm), ps -a, inspect
with open(req_path, "wb") as out:
    for step in range(7):
        conn, _ = srv.accept()
        try:
            req = read_req(conn)
            out.write(req + b"\n---REQ---\n")
            out.flush()
            if b"/containers/create" in req:
                reply(conn, "201 Created", b'{"Id":"smoke1234567890ab"}')
            elif b"/start " in req:
                reply(conn, "204 No Content")
            elif b"/wait " in req:
                reply(conn, "200 OK", b'{"StatusCode":0}')
            elif b"/logs" in req:
                reply(conn, "200 OK", b"\x01\x00\x00\x00\x00\x00\x00\x03ok\n")
            elif req.startswith(b"DELETE "):
                reply(conn, "204 No Content")
            elif b"/containers/json" in req:
                reply(conn, "200 OK", b'[{"Id":"smoke1234567890ab","Image":"alpine:3.20","Status":"Up","Names":["/smoke"]}]')
            elif b"/json" in req and b"/containers/" in req:
                reply(conn, "200 OK", b'{"Id":"smoke1234567890ab","Name":"/smoke","Image":"alpine:3.20","State":{"Status":"exited","Running":false,"ExitCode":0},"Config":{"WorkingDir":"/work","User":"1000:1000"},"HostConfig":{"Memory":67108864,"PidsLimit":32,"ReadonlyRootfs":true,"NetworkMode":"none","CapDrop":["ALL"],"CapAdd":["NET_BIND_SERVICE"]},"NetworkSettings":{"IPAddress":"10.88.0.2"},"Mounts":[{"Type":"bind","Source":"/srv/data","Destination":"/data","RW":false}]}')
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

RUN_OUT=$("$BIN" --socket "$SOCK" run --rm -m 64m --pids-limit 32 --read-only --no-new-privileges -v /srv/data:/data -p 8080:80 -p 127.0.0.1:9000:9000/udp --network none -w /work -u 1000:1000 --cap-drop ALL --cap-add NET_BIND_SERVICE alpine:3.20 echo ok)
echo "$RUN_OUT" | grep -q "ok"
grep -q '"ReadonlyRootfs":true' "$REQ_LOG"
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

# Adversarial input must fail closed before reaching daemon.
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

rm -f "$SOCK"
wait "$SERVER_PID" || true
SERVER_PID=""

# Verify intact hash-chained audit.log and reject single-byte tamper.
"$BIN" audit "$ZIGPOD_LOG_DIR/audit.log" | grep -q "audit chain verified"

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

echo "[PASS] Compiled binary E2E, mock Podman hardening, and audit tampering detection passed."
