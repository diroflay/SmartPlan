# Code graph — `codebase-memory-mcp` (read only when `REQUIRE_CODEGRAPH` is on)

[verified 0.11.0 on Windows 11: Git Bash and Windows PowerShell 5.1, native binary, no WSL]

Tool and binary are set in `routing.md` § Code graph (env `SP_CODEGRAPH` for the scripts). One static binary for Windows, macOS and Linux (amd64 / arm64), 160+ languages, MIT, fully local. Used through its **CLI**, so it works from any harness with a shell — no MCP client, no per-harness setup, none of the 7k+ tokens of MCP tool descriptions per session. Worth it only on a very large repo or monorepo (measurement: `harness-internals.md`).

| Action | Command (always `cli --quiet`: without it a log line pollutes the output) |
|---|---|
| Index / refresh | `codebase-memory-mcp cli --quiet index_repository --repo-path <absolute root, forward slashes>` → JSON with `project`, `nodes`, `edges`, `status: indexed` |
| Project name | `codebase-memory-mcp cli --quiet list_projects` (name = the root path with separators turned into `-`) |
| Overview | `codebase-memory-mcp cli --quiet get_architecture --project <p>` |
| Find symbols | `codebase-memory-mcp cli --quiet search_graph --project <p> --name-pattern '<regex>' --label <Function\|Method\|Class>` → qualified name, file, lines, in / out degree |
| Callers / callees | `codebase-memory-mcp cli --quiet trace_path --project <p> --function-name <name> --direction <inbound\|outbound\|both> --depth 3` |
| Read one symbol | `codebase-memory-mcp cli --quiet get_code_snippet --project <p> --qualified-name <qn from search_graph>` |
| Diff → affected symbols | `codebase-memory-mcp cli --quiet detect_changes --project <p> --scope impact --direction inbound --depth 2` [flags from `--help`, not executed] |

- Every tool lists its flags with `codebase-memory-mcp cli <tool> --help`. Use flags, never the raw-JSON argument form (shell quoting differs per OS).
- The index lives in `~/.cache/codebase-memory-mcp/`, outside the repo. `CBM_CACHE_DIR` must point to a private folder: a shared temp folder is refused on Windows (ACL check).
- Never run `codebase-memory-mcp install` from a plan: it edits the configuration of every coding agent on the machine.
- The graph misses dynamic calls (e.g. `current_app.make_response(…)` reached through a proxy): "who calls X" is always confirmed with one text search of the name (protocol §1).

**Into the plan**: variable `CODEGRAPH` (binary · project name returned by the Index command · date · the Index command as refresh) and the **Code graph queries** line of plan §4 — Find symbols, Callers / callees, Read one symbol, Diff → affected symbols, project name filled in.
