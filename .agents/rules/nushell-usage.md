# Nushell Usage & Optimization Guidelines for Agents

Guidelines for executing shell commands and data queries via Nushell:

1. **Subprocess Invocation Standards**:
   - When executing Nushell code through `run_command`, always execute with:
     ```bash
     nu --error-style plain -n -c '<command>'
     ```
   - `--error-style plain`: Strips ANSI color sequences and decorative formatting from error diagnostics.
   - `-n` (`--no-config-file`): Ensures clean, deterministic, and fast evaluation without user config side-effects.

2. **Token Economy & Output Formats**:
   - **Never emit decorative ASCII tables**: Nushell's default interactive table view consumes excessive LLM tokens. Always pipe tabular results into:
     - `| to md` (preferred for readable Markdown tables)
     - `| to json -r` (for structured JSON consumption)
     - `| to yaml` (for hierarchical configuration data)
   - When previewing lines or logs, slice efficiently (e.g. `open error.log | lines | last 50 | to text`).

3. **Pipelines, Streams & Error Handling**:
   - For commands with expected non-zero exits or separate error streams, pipe into `| complete` to receive a structured record `{ stdout, stderr, exit_code }`.
   - Use `;` (or `and` / `or`) for sequence chaining instead of Bash `&&` / `||`.
   - Set environment variables via `$env.KEY = "value"` instead of Bash `export`.

4. **Data Inspection & Config Files**:
   - Prefer Nushell native `open <file>` (auto-parses `.json`, `.toml`, `.yaml`, `.csv`) over external parsers like `jq`, `awk`, or `sed`.
   - Example: `open zigpod-policy.json | get rules | to json -r`

5. **Project Invariants (ZigPod)**:
   - For code and text search, continue using `rg` (`rg <pattern>` / `rg --files`) as required by project global rules.
   - Native build and audit scripts (`zig test`, `zig build`, `./scripts/auto-audit.sh`, `./scripts/security-check.sh`) remain standard executables and are run directly.
