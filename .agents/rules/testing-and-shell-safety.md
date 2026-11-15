# Testing, Lifecycle Cleanup & Shell E2E Safety Rules

1. **No Silent Error Swallowing in Tests**:
   - Use `try std.testing.expectError(error.ExactError, ...)` instead of `if (...) ... else |_| {}` or empty `catch {}`.
   - Never hand-calculate hardcoded HTTP `Content-Length` integers in mock responses; format them dynamically with `std.fmt.comptimePrint` / `std.fmt.allocPrint` using `body.len`.
   - Keep `poll` timeouts + atomic stop flags in mock server threads so early client errors cannot deadlock `thread.join()`.

2. **Non-Sequential Cleanup, `errdefer` LIFO & Ownership Contracts**:
   - Whenever indexing arrays out of order (e.g., `topoSortServices` `order`), initialize slots to `null` (`[]?T` + `@memset(..., null)`) and free every non-null slot in `defer`.
   - Match doc comments accurately to allocator ownership (`dupe` vs ownership transfer) and back `load*` helpers with `std.testing.allocator` tests.
   - When pairing a rollback `errdefer` (`rollbackComposeUp`) with tracked `ArrayList`s, register the memory-free `defer`s BEFORE `errdefer rollback...` (Zig LIFO guarantees rollback sees live container/network names), append created containers immediately after `create` (before `start`), and clean up locally via `catch` before ownership transfers into the slice so later errors never double-free.
   - Include `buf.len - 1` (final `\n`) in byte-corruption fuzz tests (`log.zig` `BUG-036`) so EOF truncation/mutation bugs are caught automatically.

3. **Dedicated Error & Audit Classification**:
   - Give each validation domain its own `ApiError` variant and `"api.<validator>"` audit rule in `reportFailure` (never alias e.g. `--shm-size` to `InvalidCpuLimit`).

4. **Shell & Makefile Safety (`scripts/*.sh`, `Makefile`)**:
   - Capture multi-line or state-mutating CLI output (`OUT=$("$BIN" ...)`) before `grep -q`; never run `"$BIN" compose ... | grep -q ...`, which triggers `BrokenPipe` and aborts teardown.
   - Wrap multi-command shell fallbacks in `{ ...; }` inside `$(shell ...)` expressions.
