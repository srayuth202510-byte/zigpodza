---
name: zigpod-wrapper
description: |
  Workspace guide for building, testing, extending, and troubleshooting the
  ZigPod Podman/Docker-compatible CLI written in pure Zig.
---

# ZigPod Workspace Skill

Use this skill when working inside the `zigpodza` repository to build, test, extend, or troubleshoot `zigpod`.

## Architecture & Modules

- `src/main.zig` — Entry point, argument parsing, config/logger initialization, command dispatch, and error reporting.
- `src/cli.zig` — Docker-style CLI parser (`run`, `ps`, `images`, `pull`, `stop`, `rm`, `logs`, `version`, `help`) and global flags (`-v/--verbose`, `--socket`, `-h/--help`, `--version`).
- `src/config.zig` — Resolves `socket_path` (flag → `$ZIGPOD_SOCKET` → `$CONTAINER_HOST`/`$DOCKER_HOST` → `$XDG_RUNTIME_DIR/podman/podman.sock` → `/run/podman/podman.sock`) and `log_dir` (`$ZIGPOD_LOG_DIR` → `.`).
- `src/http.zig` — Minimal HTTP/1.1 client over a Unix domain socket supporting `Content-Length` and `Transfer-Encoding: chunked`.
- `src/podman_api.zig` — Podman/Docker v1.40 REST API request/response structs, endpoints, and multiplexed log stream demuxer.
- `src/log.zig` — ISO-8601 UTC timestamped logger writing all levels to `system.log` and errors to `error.log`.
- `src/utils.zig` — Shared formatting helpers (`shortId`, `formatSize`).

## Build & Test Workflow

```bash
# Run all unit tests
zig build test

# Build debug binary
zig build

# Build optimized release binary (./zig-out/bin/zigpod)
zig build -Doptimize=ReleaseSafe

# Install binary to /usr/local/bin/zigpod
./scripts/install.sh
```

## Extending with New Subcommands

1. Add the subcommand union variant and flag parsing in `src/cli.zig`, plus unit tests covering valid and invalid invocations.
2. Define JSON request/response structs and the REST endpoint function in `src/podman_api.zig` (using `.ignore_unknown_fields = true` on response parsing).
3. Wire the command in `dispatch` inside `src/main.zig`.
4. Update `cli.usage` in `src/cli.zig` and `README.md`.
5. Run `zig build test` and `zig build` to verify compilation and tests.

## Troubleshooting

- **SocketNotFound / DaemonNotRunning**: Ensure Podman API socket is running (`systemctl --user start podman.socket` or `podman system service -t 0`) or pass `--socket /path/to/podman.sock`.
- **PermissionDenied**: Verify user permissions on `/run/podman/podman.sock` or switch to rootless `$XDG_RUNTIME_DIR/podman/podman.sock`.
- **Inspect Logs**: Check `system.log` for full command traces and `error.log` for failed HTTP calls and socket errors, or run with `-v/--verbose`.
