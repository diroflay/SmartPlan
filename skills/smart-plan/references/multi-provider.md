# Multi-provider repository (Phase 4)

Each harness loads **its own** instruction file at startup. This phase makes the project rules reach the workers of every provider, from one file. Policy `MULTI_PROVIDER_REPO` (`routing.md`): `on` = do it · `report` = change nothing, list what is missing (§3 actions and §5 gaps) · `off` = skip. `preflight agents` prints the state per folder (`LAYOUT` rows = the "Found" column of §3) and what §5 must report (`GAP` rows). States: `none` · `claude-only` · `gemini-only` · `agents-only` · `no-import` (also: a bridge file missing) · `vendor-only` (`CLAUDE.md` + `GEMINI.md`, no `AGENTS.md`: apply the `CLAUDE.md`-only row, then treat `GEMINI.md` as a non-importing vendor file) · `agents-invalid` (`AGENTS.md` empty or holding an `@` import: make it pass §4) · `symlink` · `compatible`.

Status legend: **[verified]** = executed on 2026-09-21, Windows 11 (Git Bash + Windows PowerShell 5.1), with a codeword planted in the instruction files and each harness asked for it without file access · **[docs]** = vendor's official docs, not executed.

## 1. What each harness loads at startup

| Harness | Loads | Does not load |
|---|---|---|
| Claude Code (`claude`) | `CLAUDE.md`, `.claude/CLAUDE.md`, `CLAUDE.local.md`, `.claude/rules/*.md`; expands `@path` imports (4 hops) [verified 2.1.278: `@AGENTS.md` import]. `AGENTS.md` directly **only when no `CLAUDE.md` exists** on the path [verified], v2.1.277+ | `AGENTS.md` next to a `CLAUDE.md` that does not import it · `AGENTS.md` at all on Amazon Bedrock, with telemetry disabled, with hooks disabled, or before 2.1.277 [docs] · `AGENTS.override.md`, `.agents/` |
| Codex CLI (`codex`) | `AGENTS.override.md` then `AGENTS.md`, from the git root down to the working directory, concatenated; **32 KiB in total** (`project_doc_max_bytes`); empty files skipped [verified 0.154: `AGENTS.md`] | `CLAUDE.md`, `GEMINI.md` [verified]. No `@` imports: `AGENTS.md` is plain text. Other names only through `project_doc_fallback_filenames` in the **user's** `~/.codex/config.toml` |
| Gemini CLI (`gemini`) | `GEMINI.md` (global, workspace, then just-in-time in sub-folders); expands `@./path.md` imports (5 levels) [docs — not installed here] | `AGENTS.md`, unless `context.fileName` lists it in `.gemini/settings.json` [docs] |
| Antigravity CLI (`agy`) | root `AGENTS.md` and root `GEMINI.md` — **in print mode only when the repository is passed with `--add-dir`** (the dispatch scripts do it) [verified 1.2.7: without the flag, neither file is loaded, from bash and from PowerShell]. Both files present, `GEMINI.md` = import line: rules loaded once [verified] | `.agents/rules/*.md` in print mode [verified 1.2.7 — the docs say otherwise, the IDE may differ] · `CLAUDE.md` |
| opencode (`opencode`) | `AGENTS.md`, walking up from the working directory; `CLAUDE.md` only as a fallback when there is no `AGENTS.md` [verified 1.18.30: `AGENTS.md` wins, the `CLAUDE.md` next to it is ignored]; extra files through `instructions` in `opencode.json` [docs] | `GEMINI.md`. No `@` imports in `AGENTS.md` |

Also reading `AGENTS.md` natively (agents.md, 2026-09-21): Cursor, GitHub Copilot coding agent, Windsurf, Zed, Jules, Aider (`read: AGENTS.md`), Amp, Devin, Junie, goose, Warp, RooCode, Kilo Code.

## 2. Target layout

```
AGENTS.md   the single source: every shared rule, plain Markdown, no imports
CLAUDE.md   line 1: @AGENTS.md      then only what is Claude Code-specific (may be nothing)
GEMINI.md   line 1: @./AGENTS.md    then only what is Gemini-specific (may be nothing)
```

- **Real files, never symlinks**: a symlink needs admin rights or Developer Mode on Windows, and git checks it out there as a one-line text file.
- Each bridge uses its vendor's documented import form (`@AGENTS.md` for Claude Code, `@./AGENTS.md` for Gemini CLI). The import sits on its own line, outside any code block.
- The `CLAUDE.md` bridge is needed even though recent Claude Code reads `AGENTS.md` alone: it covers Bedrock / telemetry-off sessions and older versions, and it is where Claude-only lines go. The `GEMINI.md` bridge avoids touching anyone's `settings.json`.
- Same rule in every sub-folder that has its own instruction file (monorepo packages).

## 3. What to do, by starting state (per folder holding an instruction file; always the repository root)

| Found | Action |
|---|---|
| none of the three | Write `AGENTS.md` from the Phase 1 scan — the facts of plan §2 (stack, layout, exact commands, observed conventions, files to imitate, do-not-touch), ≤ 60 lines, only what was observed. Add both bridges. |
| `CLAUDE.md` only | **Move** its shared content to a new `AGENTS.md`, verbatim. Keep in `CLAUDE.md`: line 1 `@AGENTS.md`, then the Claude-only lines (slash commands, subagents, hooks, `.claude/` paths, permission modes, its `@path` imports). Add the `GEMINI.md` bridge. |
| `GEMINI.md` only | Mirror of the row above (`@./AGENTS.md`; Gemini-only lines stay). Add the `CLAUDE.md` bridge. |
| `AGENTS.md` only | Add the two bridges. Touch nothing else. |
| `AGENTS.md` + `CLAUDE.md` (or `GEMINI.md`) that does not import it | Put the import on line 1 of the vendor file. Then remove from the vendor file the lines that are **identical** in `AGENTS.md`; move to `AGENTS.md` the shared lines it lacks. Two lines that contradict each other: change neither — list them under Open questions. |
| vendor file is a symlink to `AGENTS.md` | Leave it; report it with the Windows caveat. Replace it by a bridge file only with the user's yes. |
| target layout already in place | Nothing. Report `already compatible`. |

Rules for every row:
- **Verbatim, nothing lost**: moved text is moved byte for byte — no rewording, no summarising, no reordering inside a section. Every line of the old files ends up in exactly one of the new ones.
- An `@path` import found in the moved content stays in its vendor file (below line 1), and `AGENTS.md` gets a plain sentence instead — `Also read: <path> — <what it holds>` — because Codex and opencode do not expand imports.
- Unsure whether a line is vendor-specific → it is shared: move it to `AGENTS.md`.
- Never touch personal or override files: `CLAUDE.local.md`, `AGENTS.override.md`, anything in the user's home folder, any `settings.json` / `config.toml`.
- Never write a secret, a key or a machine-specific absolute path into an instruction file.
- No git command: the files are left uncommitted for the user to read; the protocol has the orchestrator commit them (plan variable `AGENT_FILES`).

## 4. Deterministic checks (after writing — no model call)

- `AGENTS.md` exists, is not empty (Codex skips empty files) and contains no `@` import line.
- First non-empty line of `CLAUDE.md` is exactly `@AGENTS.md`; of `GEMINI.md`, `@./AGENTS.md`.
- None of the three is a symlink created by this phase.
- Size: all `AGENTS.md` files from the root to the deepest folder ≤ 32 KiB together (Codex truncates beyond); root `AGENTS.md` ≤ 12 000 characters (limit reported for Antigravity — unofficial) and preferably ≤ 200 lines (Claude Code's adherence target). Over → do not trim: report it, with the largest sections.
- Line count before = line count after across the files of a moved folder (bridge lines excluded).

## 5. Beyond instruction files — detect and report, change nothing without the user's yes

These differ in format, can carry secrets, or need a copy that can drift. The plan does not depend on them (workers are driven by the dispatch scripts), so they are reported as gaps with the fix, one line each.

| Found | Who misses it | Fix to propose |
|---|---|---|
| skills in `<repo>/.claude/skills/` only | Codex, Gemini CLI, `agy` (they read `<repo>/.agents/skills/`; opencode reads both) | make `.agents/skills/<name>/` the canonical folder and keep `.claude/skills/<name>/` as a copy (or a link on a single-OS team); standard frontmatter only |
| skills in `<repo>/.agents/skills/` only | Claude Code (reads `.claude/skills/` only) | same, the other way round |
| custom commands (`.claude/commands/`, `.gemini/commands/*.toml`, `.codex/prompts/`) | every other harness | turn the ones the team uses into Agent Skills |
| subagents (`.claude/agents/*.md`, `.codex/agents/*.toml`, `.gemini/agents/*.md`, `.agents/agents/*.md`) | every other harness — four formats, not convertible line for line | none needed for a plan; port by hand the ones the team wants everywhere |
| MCP servers (`.mcp.json` for Claude Code · `mcpServers` in `.gemini/settings.json` · `[mcp_servers]` in Codex `config.toml` · `mcp` in `opencode.json` · `agy mcp add`) | every other harness | list the server names only; the user re-declares them per harness — never copy a header, token or env value |
| rule files of other tools holding rules absent from `AGENTS.md` (`.cursorrules`, `.cursor/rules/`, `.github/copilot-instructions.md`, `.windsurfrules`, `.clinerules`) | the routed workers | propose moving the shared rules into `AGENTS.md` |
| permission rules in one harness only (`.claude/settings.json` deny list, `opencode.json` `permission`) | the others | say which protections do not apply to which workers |

## Sources (official, reachable 2026-09-21)

Claude Code https://code.claude.com/docs/en/memory (§ AGENTS.md) · https://code.claude.com/docs/en/skills · Codex https://learn.chatgpt.com/docs/agent-configuration/agents-md · Gemini CLI https://geminicli.com/docs/cli/gemini-md · https://geminicli.com/docs/reference/memport · https://geminicli.com/docs/reference/configuration · Antigravity https://antigravity.google/docs/rules-workflows · https://antigravity.google/docs/cli/best-practices · opencode https://opencode.ai/docs/rules · https://opencode.ai/docs/skills · the standard https://agents.md
