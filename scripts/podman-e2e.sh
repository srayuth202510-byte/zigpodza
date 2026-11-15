#!/bin/sh
set -eu

# Live Podman daemon end-to-end verification for ZigPod.
# Auto-discovers a reachable Podman Unix socket (ZIGPOD_SOCKET, XDG_RUNTIME_DIR,
# /run/podman/podman.sock) or tries launching an ephemeral rootless
# `podman system service`. Exits 0 with [SKIP] if no Podman daemon is reachable
# unless ZIGPOD_REQUIRE_REAL_PODMAN=1 is set.

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

BIN="${ZIGPOD_BIN:-./zig-out/bin/zigpod}"
ZIG_DEFAULT="/home/mitsword/.config/Code - OSS/User/globalStorage/ziglang.vscode-zig/zig/x86_64-linux-0.13.0/zig"
if [ -n "${ZIG:-}" ]; then
    ZIG_BIN="$ZIG"
elif command -v zig >/dev/null 2>&1; then
    ZIG_BIN=$(command -v zig)
elif [ -x "$ZIG_DEFAULT" ]; then
    ZIG_BIN="$ZIG_DEFAULT"
else
    ZIG_BIN=""
fi

if [ ! -x "$BIN" ]; then
    if [ -z "$ZIG_BIN" ]; then
        echo "[FAIL] $BIN missing and zig compiler not found" >&2
        exit 1
    fi
    "$ZIG_BIN" build -Doptimize=ReleaseSafe
fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/zigpod-real-e2e.XXXXXX")
SVC_PID=""
SOCK=""
NET_NAME="zigpod-e2e-net-$$"
CTR_NAME="zigpod-e2e-ctr-$$"

cleanup() {
    if [ -n "$SOCK" ] && [ -x "$BIN" ]; then
        "$BIN" --socket "$SOCK" rm -f "$CTR_NAME" >/dev/null 2>&1 || true
        "$BIN" --socket "$SOCK" network rm -f "$NET_NAME" >/dev/null 2>&1 || true
    fi
    if [ -n "$SVC_PID" ]; then
        kill "$SVC_PID" >/dev/null 2>&1 || true
        wait "$SVC_PID" >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

probe_socket() {
    cand="$1"
    [ -S "$cand" ] || return 1
    "$BIN" --socket "$cand" system ping >/dev/null 2>&1
}

find_socket() {
    if [ -n "${ZIGPOD_SOCKET:-}" ] && probe_socket "$ZIGPOD_SOCKET"; then
        SOCK="$ZIGPOD_SOCKET"
        return 0
    fi
    if [ -n "${XDG_RUNTIME_DIR:-}" ] && probe_socket "$XDG_RUNTIME_DIR/podman/podman.sock"; then
        SOCK="$XDG_RUNTIME_DIR/podman/podman.sock"
        return 0
    fi
    uid=$(id -u)
    if probe_socket "/run/user/$uid/podman/podman.sock"; then
        SOCK="/run/user/$uid/podman/podman.sock"
        return 0
    fi
    if probe_socket "/run/podman/podman.sock"; then
        SOCK="/run/podman/podman.sock"
        return 0
    fi
    return 1
}

if ! find_socket; then
    if command -v podman >/dev/null 2>&1; then
        SVC_SOCK="$TMP_DIR/podman.sock"
        podman system service --time=60 "unix://$SVC_SOCK" >/dev/null 2>"$TMP_DIR/podman-service.log" &
        SVC_PID=$!
        i=0
        while [ "$i" -lt 25 ]; do
            if probe_socket "$SVC_SOCK"; then
                SOCK="$SVC_SOCK"
                break
            fi
            sleep 0.2
            i=$((i + 1))
        done
    fi
fi

if [ -z "$SOCK" ]; then
    MSG="[SKIP] live Podman daemon socket unreachable (set ZIGPOD_SOCKET or start 'podman system service')"
    if [ -f "$TMP_DIR/podman-service.log" ] && [ -s "$TMP_DIR/podman-service.log" ]; then
        SVC_ERR=$(head -n 1 "$TMP_DIR/podman-service.log")
        MSG="$MSG: $SVC_ERR"
    fi
    if [ "${ZIGPOD_REQUIRE_REAL_PODMAN:-0}" = "1" ]; then
        echo "[FAIL] $MSG" >&2
        exit 1
    fi
    echo "$MSG"
    exit 0
fi

echo "[INFO] using Podman socket: $SOCK"
TEST_IMG="${ZIGPOD_TEST_IMAGE:-alpine:3.20}"

export ZIGPOD_LOG_DIR="$TMP_DIR/logs"
mkdir -p "$ZIGPOD_LOG_DIR"

"$BIN" --socket "$SOCK" system ping | grep -q "OK"
"$BIN" --socket "$SOCK" version >/dev/null

if ! "$BIN" --socket "$SOCK" images --json | grep -q "$TEST_IMG"; then
    echo "[INFO] pulling $TEST_IMG..."
    "$BIN" --socket "$SOCK" pull "$TEST_IMG" >/dev/null
fi

# 1. Network create -> ls -> inspect -> rm lifecycle
"$BIN" --socket "$SOCK" network create --driver bridge --internal "$NET_NAME" >/dev/null
"$BIN" --socket "$SOCK" network ls | grep -q "$NET_NAME"
"$BIN" --socket "$SOCK" network inspect "$NET_NAME" | grep -q "$NET_NAME"
"$BIN" --socket "$SOCK" network rm -f "$NET_NAME" >/dev/null

# 2. Hardened container run (-d) with --cpus, --env-file, -l, --hostname, --restart
cat > "$TMP_DIR/e2e.env" <<'EOF'
# Real E2E env file
E2E_ENV_MARKER=zigpod_live_ok
EOF

RUN_ID=$("$BIN" --socket "$SOCK" run -d \
    --name "$CTR_NAME" \
    --cpus 0.5 \
    --env-file "$TMP_DIR/e2e.env" \
    -l app=zigpod-e2e \
    --hostname e2e-box \
    --restart on-failure:1 \
    "$TEST_IMG" sh -c "echo \$E2E_ENV_MARKER && sleep 20")
[ -n "$RUN_ID" ]

INSPECT_JSON=$("$BIN" --socket "$SOCK" inspect "$CTR_NAME" --json)
echo "$INSPECT_JSON" | grep -q "e2e-box"
echo "$INSPECT_JSON" | grep -q "zigpod-e2e"
echo "$INSPECT_JSON" | grep -q "500000000"

# 3. Bidirectional container cp
printf 'zigpod-cp-payload\n' > "$TMP_DIR/upload.txt"
"$BIN" --socket "$SOCK" cp "$TMP_DIR/upload.txt" "$CTR_NAME:/tmp" >/dev/null
mkdir -p "$TMP_DIR/out"
"$BIN" --socket "$SOCK" cp "$CTR_NAME:/tmp/upload.txt" "$TMP_DIR/out/downloaded.txt" >/dev/null
grep -q "zigpod-cp-payload" "$TMP_DIR/out/downloaded.txt"

# 4. attach & logs & cleanup
echo "zigpod_live_ok" >/dev/null
"$BIN" --socket "$SOCK" logs "$CTR_NAME" | grep -q "zigpod_live_ok"
printf 'exit\n' | "$BIN" --socket "$SOCK" attach "$CTR_NAME" >/dev/null 2>&1 || true
"$BIN" --socket "$SOCK" stop "$CTR_NAME" >/dev/null
"$BIN" --socket "$SOCK" rm -f "$CTR_NAME" >/dev/null

# 5. Sandbox profile pass + fail-closed CPU ceiling check
"$BIN" --socket "$SOCK" run --rm --profile=sandbox "$TEST_IMG" echo sandbox-live-ok | grep -q "sandbox-live-ok"
if "$BIN" --socket "$SOCK" run --profile=sandbox --cpus 2 "$TEST_IMG" echo denied >/dev/null 2>&1; then
    echo "[FAIL] expected --profile=sandbox --cpus 2 to fail pre-flight" >&2
    exit 1
fi

# 6. Hash-chained audit log verification
"$BIN" audit --json >/dev/null

echo "[PASS] scripts/podman-e2e.sh passed against real Podman daemon"
