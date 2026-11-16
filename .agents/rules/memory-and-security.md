# Zig 0.17 Memory Safety & Security Invariants

1. **Zero Memory Leaks**:
   - Never use `std.heap.page_allocator` or a global `ArenaAllocator` inside `test { ... }` blocks; always pass `std.testing.allocator`.
   - Any struct that allocates memory owned by a caller (`cli.Parsed`, `config.Config`, `http.Response`) must expose a `deinit` method and free intermediate buffers via `defer` / `errdefer`.
   - Never ignore `debug_allocator.deinit()` (`std.heap.DebugAllocator`, formerly `GeneralPurposeAllocator`) in `src/main.zig`; fail with non-zero exit status if `.leak` is reported.
   - Free `realPathFileAlloc` results only as `[:0]u8`; when a resolved path is returned or stored as `[]u8`, allocate it with `utils.realpathAlloc` (exact length) to avoid allocator size-mismatch panics.

2. **Integer & Bounds Safety**:
   - Always use `std.math.add` (or checked arithmetic) when computing offsets/lengths from untrusted socket data (`decodeChunked` in `src/http.zig`, `demuxLogs` in `src/podman_api.zig`).
   - Enforce `max_response_bytes` before buffering or appending streamed payloads.

3. **Input, Parser & Protocol Validation**:
   - Call `http.validateRequestTarget(path)` inside `http.Client.request` before opening the socket.
   - Call `podman_api.validateIdentifier(...)` on every container ID or name before formatting REST API URLs.
   - Keep `validateNetworkMode` strictly restricted to the 5 built-in modes (`BUG-016`); attach user-defined compose `networks:` via `NetworkingConfig.EndpointsConfig` + `validateIdentifier`, verify every service network against `networks:` + `policy.isNetworkAllowed` (`BUG-028`), and fail closed (`InvalidComposeSyntax`) on unsupported keys, inline `{...}`, or `- key: val` long syntax (`BUG-027`).
   - Run `repairAuditTail(f)` in `Logger.log` under `lockAudit` (`BUG-030`), and keep `verifyAuditFile` and `writeAuditJson` on shared `evaluateAuditContent`/`parseAuditFields` logic (`BUG-036`).

4. **Zig 0.17 Compatibility** (see `.agents/rules/zig-0.17-gotchas.md`):
   - Socket connect failures surface as `error.PermissionDenied` (mapped to `http.Error.PermissionDenied`); never switch on `error.AccessDenied` in `src/http.zig` (`BUG-001`). Verify stdlib error sets when adding error switches.
   - All socket reads/writes go through `src/http_socket.zig` (`socketRead`/`socketWriteAll` with an absolute `.awake` `Deadline`) so the BUG-007/BUG-032/BUG-037 timeouts still hold under `std.Io`.
   - Bounded file reads must keep "at most N bytes" semantics: `readFileAlloc(..., .limited(N + 1))` or `utils.readFileToEndAlloc`.
   - Keep `scripts/auto-audit.sh` passing cleanly after every change.
