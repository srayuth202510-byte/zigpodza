# Zig 0.17 Compiler Gotchas & Pre/Post-Edit Checklist

> Distilled from `error.log` diagnostics, `docs/vault/Bug-Playbook.md` (`BUG-001`–`BUG-045`), and the
> 0.13 → 0.17.1 migration. The minimum toolchain is pinned in `build.zig.zon` (`minimum_zig_version`);
> always build through `make` / `scripts/find-zig.sh` so a stale older `zig` on `PATH` is never used.

1. **Exhaustive `switch` Updates Across Modules (`switch must handle all possibilities`)**:
   - When adding a `cli.Command` variant in `src/cli_types.zig` or changing error sets from `std.Io`/`podman_types.zig`, inspect and update every corresponding `switch` site (`dispatch` and `reportFailure` in `src/main.zig`, `Parsed.deinit` in `src/cli_types.zig`, `src/demo.zig`) in the same edit batch.
   - When adding a dedicated `ApiError` variant in `src/podman_types.zig`, always add its `logger.deny(...)` branch in `src/main.zig` (`reportFailure`) so audit telemetry classifies each domain accurately (`BUG-041`).

2. **Strict Shadowing & Unused Mutable Variable Rules**:
   - Zig forbids shadowing outer declarations, captures (`v`, `f`), function parameters of an enclosing function (e.g. a nested `fn visit(alloc: ...)` inside a function that already has `alloc`), and primitive type names (`u1`, `u8`, etc.). Choose distinct names.
   - Use `const` by default; only declare `var` when the variable is actually reassigned.

3. **Module-Split Error Set Referencing**:
   - `ApiError` is defined in `src/podman_types.zig` and re-exported by `src/podman_api.zig`. Submodules (such as `src/podman_validate.zig`, `src/podman_transfer.zig`, `src/compose.zig`) must import `podman_types.zig` and reference `types.ApiError` (or `pod.ApiError` in `src/main.zig`).

4. **Explicit `std.Io` Everywhere (no hidden global I/O)**:
   - Every filesystem, socket, clock, sleep, and randomness call takes an `io: std.Io`. Runtime code gets it from `http.Client.io` (`const io = client.io;`), `log.Logger.io`, or an explicit `io` parameter threaded from `main`.
   - Tests use `std.testing.io` and `std.testing.environ`. **Never** reference `std.testing.io` from code reachable at runtime (e.g. `src/demo.zig` runs as `zigpod demo`); it is a compile error outside `zig build test`.
   - Environment variables come from `std.process.Environ` (`environ.getPosix(...)` / `environ.getAlloc(...)`), passed from `main`'s `std.process.Init.Minimal`. `std.posix.getenv` and `std.process.getEnvVarOwned` no longer exist.
   - `main` uses `Init.Minimal` + its own `std.heap.DebugAllocator` + `std.Io.Threaded` so a leak still turns into exit status 1 (the default `std.process.Init` gpa only *reports* leaks).

5. **Removed / Renamed std APIs (use the project helpers)**:
   - `std.fs.cwd()`/`std.fs.Dir`/`std.fs.File` → `std.Io.Dir.cwd()`/`std.Io.Dir`/`std.Io.File`; methods take `io` (`openFile(io, …)`, `createDir(io, name, .default_dir)`, `createDirPath(io, …)`, `statFile(io, p, .{})`, `symLink(io, …)`, `deleteTree(io, …)`). **`std.Io.Dir.rename(old_dir, old, new_dir, new, io)` takes `io` last.**
   - `std.net` → `std.Io.net`: `UnixAddress.init(p)` then `.listen(io, .{})` / `.connect(io)`; `Server.accept(io)` returns a `Stream` directly (no `.stream` field); `Stream.close(io)`; raw handle is `stream.socket.handle`.
   - `std.posix.{pipe,write,close,fstat,realpath}` are gone → `utils.pipe`, `utils.writeFd`, `utils.closeFd`, `log.statxFd`, `utils.realpath`.
   - `std.time.{milliTimestamp,nanoTimestamp,timestamp,sleep}` → `utils.milliTimestamp(io)` / `std.Io.Clock.*.now(io)` / `std.Io.sleep(io, .fromNanoseconds(n), .awake)`.
   - `std.crypto.random` → `io.random(&buf)` (CSPRNG).
   - `std.tar.iterator(reader)` → `std.tar.Iterator.init(&file_reader.interface, …)`; copy entry bodies with `iter.streamRemaining(f, writer)`.
   - `std.json.stringify(v, opts, writer)` → `std.json.Stringify.value(v, opts, *std.Io.Writer)`; `stringifyAlloc` → `Stringify.valueAlloc`.
   - `std.ascii.indexOfIgnoreCase` → `std.ascii.findIgnoreCase`; `std.debug.dumpStackTrace(builtin trace)` → `std.debug.dumpErrorReturnTrace(&t)`.
   - `std.Io.net.IpAddress.parseIp4` replaces `std.net.Address.parseIp4`.

6. **Allocation-Size Traps (panic: "free … mismatches allocation")**:
   - `Dir.realPathFileAlloc` returns `[:0]u8`. Coercing it to `[]u8` (returning it from a `![]u8` function, storing in a `[]u8` field) and freeing later is a size mismatch. Use `utils.realpathAlloc(io, dir, path, alloc)` which returns an exact-length `[]u8`.
   - `Dir.readFileAlloc(io, p, alloc, .limited(n))` uses an unbuffered reader that fails with `StreamTooLong` when **exactly `n`** bytes are read. Pass `.limited(max + 1)` to keep "at most `max`" semantics, or use `utils.readFileToEndAlloc(io, file, alloc, max)` (maps to `error.FileTooBig`).

7. **ArrayList & Writers**:
   - `std.ArrayList(T)` is unmanaged: declare `var x: std.ArrayList(T) = .empty;` and pass the allocator to `append`/`appendSlice`/`toOwnedSlice`/`deinit`. Helpers that append (`appendQueryEncoded`, `writeTarHeader`, `writePad`, `writeTarTrailer`) take the allocator explicitly. `std.array_list.Managed` is deprecated — do not add new uses.
   - Output sinks are `*std.Io.Writer`. In tests use `var out: std.Io.Writer.Allocating = .init(alloc); defer out.deinit();`, pass `&out.writer`, and read `out.written()`.
   - CLI stdout/stderr in `main` are **unbuffered** `std.Io.File.Writer.initStreaming(…, &.{})` so streaming commands (`logs -f`, `attach`, `stats`) flush immediately; if you add a buffer you must `flush()` on every path.
   - Format strings are type-checked strictly: `{?d}` on a non-optional is a compile error; arrays need `&` to coerce to slices (`&rep("a", 10)`).

8. **Mandatory Pre-Edit & Post-Edit Workflow**:
   - **Before editing `src/*.zig`**: Check relevant entries in `docs/vault/Bug-Playbook.md` and `docs/vault/Security-And-Memory-Checklist.md` (`rg` first).
   - **While editing**: Pair temporary/entry allocations with `errdefer` placed safely relative to slice cleanup `defer` (Zig LIFO, `BUG-029`, `BUG-035`, `BUG-038`), use bounded `poll`/`http.socket.writeAllWithTimeout` on sockets (`BUG-032`, `BUG-037`), and back new paths with `std.testing.allocator` tests (including OOM / malformed input cases).
   - **After editing**: Run `./scripts/auto-audit.sh` and `make debug-test` (or `make ci` before finishing/committing).
