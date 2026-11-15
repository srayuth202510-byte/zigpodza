# Zig 0.13 Compiler Gotchas & Pre/Post-Edit Checklist

> Distilled from `error.log` diagnostics and `docs/vault/Bug-Playbook.md` (`BUG-001`–`BUG-041`).

1. **Exhaustive `switch` Updates Across Modules (`switch must handle all possibilities`)**:
   - When adding a `cli.Command` variant in `src/cli_types.zig` or changing error sets from `std.fs`/`std.posix`/`podman_types.zig`, inspect and update every corresponding `switch` site (`dispatch` and `reportFailure` in `src/main.zig`, `Parsed.deinit` in `src/cli_types.zig`, `src/demo.zig`) in the same edit batch.
   - When adding a dedicated `ApiError` variant in `src/podman_types.zig`, always add its `logger.deny(...)` branch in `src/main.zig` (`reportFailure`) so audit telemetry classifies each domain accurately (`BUG-041`).

2. **Strict Shadowing & Unused Mutable Variable Rules**:
   - Zig 0.13 forbids shadowing outer declarations, captures (`v`, `f`), and primitive type names (`u1`, `u8`, etc.). Choose distinct local and capture names.
   - Use `const` by default; only declare `var` when the variable is actually reassigned.

3. **Module-Split Error Set Referencing**:
   - `ApiError` is defined in `src/podman_types.zig` and re-exported by `src/podman_api.zig`. Submodules (such as `src/podman_validate.zig`, `src/podman_transfer.zig`, `src/compose.zig`) must import `podman_types.zig` and reference `types.ApiError` (or `pod.ApiError` in `src/main.zig`).

4. **Zig 0.13 `std.json.stringify` Writer Error Set**:
   - Custom `pub fn jsonStringify(self: ..., jw: anytype) !void` methods (`TmpfsBounds`, `PortBindings`, etc. in `src/podman_types.zig`) can only return writer errors (`error{OutOfMemory}!void`) and must **never** perform fallible validation or return `ApiError` inside `jsonStringify`.
   - Always run domain validation *before* calling `std.json.stringify` (e.g., in `makeMount`/`makePortMapping` and defense-in-depth inside `createContainer`, `BUG-034`).

5. **Mutable Slices vs Const Slices & Writer Signatures**:
   - Keep mutable buffers (`[]u8`) clearly separated from immutable slices (`[]const u8`).
   - Accept `writer: anytype` (passing `list.writer()`) in shared serialization/formatting helpers instead of hardcoding `*std.ArrayList(u8)`.

6. **Mandatory Pre-Edit & Post-Edit Workflow**:
   - **Before editing `src/*.zig`**: Check relevant entries in `docs/vault/Bug-Playbook.md` and `docs/vault/Security-And-Memory-Checklist.md` (`rg` first).
   - **While editing**: Pair temporary/entry allocations with `errdefer` placed safely relative to slice cleanup `defer` (Zig LIFO, `BUG-029`, `BUG-035`, `BUG-038`), use bounded `poll`/`writeAllWithTimeout` on sockets (`BUG-032`, `BUG-037`), and back new paths with `std.testing.allocator` tests (including OOM / malformed input cases).
   - **After editing**: Run `./scripts/auto-audit.sh` and `make debug-test` (or `make ci` before finishing/committing).
