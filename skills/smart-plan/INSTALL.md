# smart-plan — Install & Use (v1.0.0)

An [Agent Skill](https://agentskills.io/specification) (open standard: Anthropic, OpenAI, Google and others). `SKILL.md` uses only standard frontmatter, so the same folder works in every harness. This file is for humans; agents do not need it.

## Install once, use everywhere

Keep one canonical copy and link it where a harness does not look there by itself.

| Harness | Discovers skills in | Action |
|---|---|---|
| canonical | `~/.agents/skills/smart-plan/` | copy this folder there |
| Codex CLI | `~/.agents/skills/`, `<repo>/.agents/skills/` | nothing |
| Gemini CLI | `~/.agents/skills/`, `~/.gemini/skills/`, `<repo>/.agents/skills/` | nothing |
| Antigravity CLI (`agy`) | `<repo>/.agents/skills/`, `~/.gemini/antigravity-cli/skills/` | link into the global folder (or install per repo) |
| Claude Code | `~/.claude/skills/`, `<repo>/.claude/skills/` — **not** `.agents/skills/` | link |

Windows (PowerShell, no admin needed for junctions):
```powershell
Copy-Item -Recurse .\smart-plan "$HOME\.agents\skills\smart-plan"
New-Item -ItemType Junction -Path "$HOME\.claude\skills\smart-plan" -Target "$HOME\.agents\skills\smart-plan"
New-Item -ItemType Junction -Path "$HOME\.gemini\antigravity-cli\skills\smart-plan" -Target "$HOME\.agents\skills\smart-plan"   # only if agy is installed
```
macOS / Linux:
```bash
mkdir -p ~/.agents/skills ~/.claude/skills
cp -R ./smart-plan ~/.agents/skills/smart-plan
ln -s ~/.agents/skills/smart-plan ~/.claude/skills/smart-plan
mkdir -p ~/.gemini/antigravity-cli/skills && ln -s ~/.agents/skills/smart-plan ~/.gemini/antigravity-cli/skills/smart-plan   # only if agy is installed
```
Per-project instead of per-user: put the folder in `<repo>/.agents/skills/` and link `<repo>/.claude/skills/smart-plan` to it. Restart the harness after installing.

## Invoke

| Harness | How |
|---|---|
| Claude Code | `/smart-plan <feature request>` |
| Codex CLI | `$smart-plan <feature request>` (or `/skills`) — implicit invocation is off (`agents/openai.yaml`) |
| Antigravity CLI | `/smart-plan <feature request>` |
| Gemini CLI | "Use the smart-plan skill: <feature request>" — or install `adapters/gemini-command.toml` as `~/.gemini/commands/smart-plan.toml` for `/smart-plan` |
| opencode and others | ask for the skill by name |

The planner is whichever model runs the skill, and by default (`STRICT_HOST: on`) it must be the routed one: invoke from Claude Code with Fable selected, otherwise the skill aborts. The same holds for the orchestrator when the plan is executed. An OpenRouter key is also mandatory by default (`REQUIRE_OPENROUTER: on`). Both switches are in `routing.md`.

## Configure

Edit `routing.md` only: roles → models, abort vs fallback, smoke test on/off, new providers.

## Works on every machine — how

Nothing OS-specific is left to the agent. Five script pairs (`preflight`, `dispatch`, `status`, `jev`, `review`) do the fragile parts, and every plan carries a copy — with the execution protocol `protocol.md` — in `.to-do/_tools/`, so a plan runs from any clone even where this skill is not installed.

| Machine | Scripts | Requirements |
|---|---|---|
| Linux, macOS, WSL, Git Bash | `scripts/*.sh` | bash 3.2+ (stock macOS is fine). No `jq`, no `timeout`, no Node needed. |
| Windows without bash | `scripts/*.ps1` | stock Windows PowerShell 5.1, or PowerShell 7+. Run with `-ExecutionPolicy Bypass -File`. |

Always required: `git`, plus the CLIs of the providers you route to (`preflight check` tells you which are missing and how to install them). `curl` only for the Jev review gate.

Optional (`REQUIRE_CODEGRAPH`, off by default — turn it on for a very large repo): the code-graph tool named in `routing.md` § Code graph — by default **`codebase-memory-mcp`**, one binary for Windows / macOS / Linux, MIT. Download the archive of your OS from https://github.com/DeusData/codebase-memory-mcp/releases, check it against `checksums.txt`, and put the binary on `PATH`. smart-plan uses only its CLI. Its install scripts and `install` sub-command also register an MCP server in every coding agent they detect — not needed here.

Routing is a property of the machine, not of the plan: on another machine, run `.to-do/_tools/preflight.(sh|ps1)` before executing a plan.

## Test record (2026-09-20)

| Environment | What ran | Result |
|---|---|---|
| Windows 11 · Git Bash (bash 5.3) | `dispatch.sh` new + resumed sessions with real models: Codex (`gpt-5.6-luna`, `gpt-6-astra`), opencode → OpenRouter (`deepseek-v4.1-flash`), Antigravity (`agy` 1.1.10); `preflight.sh check` + `smoke` (pass and fail cases); timeout, watchdog and no-Node `sed` paths | pass |
| Windows 11 · Windows PowerShell 5.1 and PowerShell 7.6 | `dispatch.ps1` new + resumed sessions (opencode, Codex, agy), UTF-8 brief, paths with spaces, 3 s timeout killing the process tree; `preflight.ps1 check` + `smoke` | pass |
| Linux · `bash:3.2` image (bash 3.2.57, BusyBox sed/grep/timeout — closest available proxy for stock macOS) | both `.sh` scripts, offline, with a fake harness: dispatch, resume, capture, timeout (BusyBox exit 143 → normalised to 124), watchdog, failure reporting | pass |
| Linux · `debian:stable-slim` (bash 5.2, GNU tools) | same suite | pass |
| Windows 11 · Git Bash, Windows PowerShell 5.1, PowerShell 7 (2026-09-20, v0.5) | `jev.sh` / `jev.ps1` against a local mock server: byte-exact JSON round-trip of a diff with quotes, backslashes, tabs, CRLF and UTF-8; 429 retry; size limit (exit 3); missing key (exit 4). `preflight check` codegraph row. opencode read-only worker running a shell command headlessly. Smoke: `claude` → `sonnet`, opencode → `qwen3.8-flash`, `qwen3.8-max-0902` | pass (qwen3.8-flash: 1 empty reply in 4 runs) |
| Windows 11 · Git Bash (2026-09-21, v0.6) | Scout brief on pallets/flask through `dispatch.sh`: `deepseek-v4.1-flash` with and without the code graph (2 tasks), token-frugal brief, six `:free` models | graph: no saving · frugal brief: 20k-token final context, $0.0045 · free models: 3 of 6 usable → not used |
| Windows 11 · Git Bash, Windows PowerShell 5.1, PowerShell 7 (2026-09-21, v0.7) | Status board and detached fan-out: four real workers started at once with `SP_DETACH=1` (Codex `gpt-5.6-luna`, opencode → `deepseek-v4.1-flash`, `claude` → `haiku`, `agy`), board read while they ran (live last activity for all four), collected with `status wait` (exit 3 while running, 0 when finished); `claude` and `agy` switched to streamed output — final message, session ID and `claude` resume still captured; timeout → `timeout` state; identical board from `status.sh`, `status.ps1` on 5.1 and on 7; preflight `smoke` for `claude` and `agy` through the patched scripts | pass — `agy` itself was unstable that day (HTTP 503, one hang until timeout), reported correctly as `failed` / `timeout` |
| Windows 11 · Git Bash + Windows PowerShell 5.1 (2026-09-21, v0.8) | Multi-provider repository (Phase 4). A codeword planted in the instruction files, each harness asked for it with file access forbidden: `claude` 2.1.278, `codex` 0.154, `opencode` 1.18.30, `agy` 1.2.7 on three layouts (`AGENTS.md` only · target layout · `.agents/rules/` only). Then end to end: a fresh `sonnet` worker applied `references/multi-provider.md` to a repo holding only a `CLAUDE.md` (shared rules, a Claude-only section, an `@` import, a Claude-only skill), and the four harnesses were asked again | pass — target layout produced, content moved verbatim, gaps reported without a change; all four load the shared rules exactly once, only `claude` sees the Claude-only lines. **Found and fixed**: `agy` in print mode loads no project rules without `--add-dir <repo>` (both dispatch scripts patched and re-run); `.agents/rules/` is not loaded by `agy` in print mode |
| Windows 11 · Git Bash (bash 5.3, with and without Node), Windows PowerShell 5.1, PowerShell 7.6 (2026-09-21, v0.9) | With a fake harness and a local mock Jev server — no paid call: codex resume now carries `-m` and `-c sandbox_mode=…` (argv checked; effect on a real resumed session **not run**); repo path with a trailing backslash; refusal of a double quote in any dispatch argument; no-Node JSON fallback on compact and pretty JSON; `preflight models` on the real `codex`, `opencode`, `agy` listings; `preflight smoke-all` (OK, fail, 3 s timeout, cache hit, `SP_SMOKE_CACHE_H=0`, stale entry, unwritable home); `preflight agents` on 17 fixture folders (every state except `symlink`, every GAP kind); new `review` script: `prep`, `gate`, `merge`, `verdict` — all 20 reader × gate combinations, slices, quotes / backslash / tab in a criterion, too-large, HTTP 500 | pass — twins print identical lines. Known: Windows PowerShell 5.1 `-File` rejects a bare `-` argument (use `none`) |
| Linux, macOS, bash 3.2 / BusyBox | `review.sh`, the v0.9 changes of `dispatch.sh` / `preflight.sh`, `status.sh` and the `SP_DETACH` path of `dispatch.sh` | **not run** (Docker daemon was off) — written to the same bash 3.2 / POSIX rules as the tested scripts |
| Spec | `npx skills-ref validate ./smart-plan` | valid (v0.4; not re-run since) |

Bugs these tests caught and fixed (v0.7): agy resolving relative paths next to the brief instead of the repository root (the prompt now names the root); agy returning an empty response whenever one action is auto-denied (documented in `references/harness-internals.md`).

Bugs these tests caught and fixed: opencode `-f` swallowing the prompt / hanging; agy ignoring stdin and its 5-minute default print timeout; GNU-only `sed \x1b`; BusyBox timeout exit code; PowerShell pipeline re-encoding briefs (now `cmd.exe` redirection).

**Not tested — be aware**
- **macOS itself** (no Mac available): covered only by the bash 3.2 / non-GNU container proxy. BSD `sed`/`grep` differences beyond that are possible.
- **`gemini` workers**: flags come from official docs; `gemini` is not installed here. `claude -p` ran read-only only (smoke `sonnet`, detached `haiku`). The smoke test exposes any mismatch on first use.
- **Write mode with real models**: real runs used read-only mode (no files to edit in a scratch folder); `workspace-write` / `accept-edits` / `--auto` flags are per docs and `--help`.
- **Jev live API**: the request builder and the key validation are tested against a mock only; request / response shape re-checked against the live API reference on 2026-09-21 (endpoint, body, answers, 429 / 529: all match). No key here to execute it, and the review thresholds are defaults, not validated.
- **Code graph**: `codebase-memory-mcp` 0.11.0 verified on Windows only (Git Bash + PowerShell 5.1: index, list, architecture, search, trace, snippet); `detect_changes` not executed; macOS / Linux binaries not run. Its token benefit was measured on one mid-size repo and was **negative** (see `references/harness-internals.md` § Measurements) — large repos not measured. v0.5 of the `.sh` scripts was not re-run in the Linux containers.
- **Multi-provider repository**: the `GEMINI.md` bridge (`@./AGENTS.md`) is per the Gemini CLI docs — `gemini` is not installed here. Only the "`CLAUDE.md` only" starting state was run end to end; the merge of an `AGENTS.md` with a non-importing `CLAUDE.md`, nested folders and the no-file case were not. The patched `agy` line of the dispatch scripts was run on Windows only.
- **v0.9 restructuring**: the plan now points to `.to-do/_tools/protocol.md` instead of carrying the protocol; no plan has been generated or executed with it yet.
- **An end-to-end plan**: the skill has not yet generated and executed a real plan.
