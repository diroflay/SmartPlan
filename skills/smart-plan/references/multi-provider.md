# Multi-harness repository (Phase 4)

Each harness loads **its own** instruction file at startup. This phase makes the project rules reach the workers of the chosen provider, and any harness that may run the plan, from one file. Policy `MULTI_PROVIDER_REPO` (`routing.md`): `on` = do it · `report` = change nothing, list what is missing (§3 actions and §5 gaps) · `off` = skip.

`preflight agents` prints a `LAYOUT` row per folder (state = the "Found" column of §3), `GAP` rows for §5, then `RESULT`. It also expects a `GEMINI.md` bridge and applies Antigravity's 12000-character `AGENTS.md` limit: `no-import` naming only `GEMINI.md` (its 4th field lists the bridges lacking the import), the `size` gap on 12000 characters, and a `RESULT work-needed` due only to these count as compatible here. `RESULT compatible` → report `already compatible`.

Status legend: **[verified]** = executed on 2026-09-21, Windows 11 (Git Bash + Windows PowerShell 5.1), with a codeword planted in the instruction files and each harness asked for it without file access · **[docs]** = vendor's official docs, not executed.

## 1. What each harness loads at startup

| Harness | Loads | Does not load |
|---|---|---|
| Claude Code (`claude`) | `CLAUDE.md`, `.claude/CLAUDE.md`, `CLAUDE.local.md`, `.claude/rules/*.md`; expands `@path` imports (4 hops) [verified 2.1.278: `@AGENTS.md` import]. `AGENTS.md` directly **only when no `CLAUDE.md` exists** on the path [verified], v2.1.277+ | `AGENTS.md` next to a `CLAUDE.md` that does not import it · `AGENTS.md` at all on Amazon Bedrock, with telemetry disabled, with hooks disabled, or before 2.1.277 [docs] · `AGENTS.override.md`, `.agents/` |
| Codex CLI (`codex`) | `AGENTS.override.md` then `AGENTS.md`, from the git root down to the working directory, concatenated; **32 KiB in total** (`project_doc_max_bytes`); empty files skipped [verified 0.154: `AGENTS.md`] | `CLAUDE.md` [verified]. No `@` imports: `AGENTS.md` is plain text |
| opencode (`opencode`, OpenRouter channel) | `AGENTS.md`, walking up from the working directory; `CLAUDE.md` only as a fallback when there is no `AGENTS.md` [verified 1.18.30] | No `@` imports in `AGENTS.md` |

## 2. Target layout

```
AGENTS.md   the single source: every shared rule, plain Markdown, no imports
CLAUDE.md   line 1: @AGENTS.md      then only what is Claude Code-specific (may be nothing)
GEMINI.md   only if present — line 1: @./AGENTS.md, then only its vendor-specific lines. Never create it.
```

- **Real files, never symlinks**: a symlink needs admin rights or Developer Mode on Windows, and git checks it out there as a one-line text file.
- The import sits on its own line, outside any code block.
- The `CLAUDE.md` bridge is needed even though recent Claude Code reads `AGENTS.md` alone: it covers Bedrock / telemetry-off sessions and older versions.
- Same rule in every sub-folder that has its own instruction file (monorepo packages).

## 3. What to do, by starting state (per folder holding an instruction file; always the repository root)

"Vendor file" = `CLAUDE.md`, or an existing `GEMINI.md`.

| Found | Action |
|---|---|
| `none` | Write `AGENTS.md` from the Phase 1 scan — the facts of plan §2 (stack, layout, exact commands, observed conventions, files to imitate, do-not-touch), ≤ 60 lines, only what was observed. Add the `CLAUDE.md` bridge. |
| `claude-only` · `gemini-only` · `vendor-only` | **Move** the shared content of the vendor file(s) to a new `AGENTS.md`, verbatim. Keep in each: the import on line 1, then its vendor-only lines (slash commands, subagents, hooks, vendor paths, permission modes, its `@path` imports). Add the `CLAUDE.md` bridge if missing. |
| `agents-only` | Add the `CLAUDE.md` bridge. Touch nothing else. |
| `no-import` (vendor file does not import `AGENTS.md`) | Put the import on line 1 of the vendor file. Then remove from it the lines that are **identical** in `AGENTS.md`; move to `AGENTS.md` the shared lines it lacks. Two lines that contradict each other: change neither — list them under Open questions. |
| `agents-invalid` | `AGENTS.md` empty or holding an `@` import: make it pass §4. |
| `symlink` | Leave it; report it with the Windows caveat. Replace it by a bridge file only with the user's yes. |
| `compatible` | Nothing. |

Rules for every row:
- **Verbatim, nothing lost**: moved text is moved byte for byte — no rewording, no summarising, no reordering inside a section. Every line of the old files ends up in exactly one of the new ones.
- An `@path` import found in the moved content stays in its vendor file (below line 1), and `AGENTS.md` gets a plain sentence instead — `Also read: <path> — <what it holds>` — because Codex and opencode do not expand imports.
- Unsure whether a line is vendor-specific → it is shared: move it to `AGENTS.md`.
- Never touch personal or override files: `CLAUDE.local.md`, `AGENTS.override.md`, anything in the user's home folder, any `settings.json` / `config.toml`.
- Never write a secret, a key or a machine-specific absolute path into an instruction file.
- No git command: the files are left uncommitted for the user to read; the protocol has the orchestrator commit them (plan variable `AGENT_FILES`).

## 4. Deterministic checks (after writing — no model call)

- `AGENTS.md` exists, is not empty (Codex skips empty files) and contains no `@` import line.
- First non-empty line of `CLAUDE.md` is exactly `@AGENTS.md`; of an existing `GEMINI.md`, `@./AGENTS.md`.
- None of them is a symlink created by this phase.
- Size: all `AGENTS.md` files from the root to the deepest folder ≤ 32 KiB together (Codex truncates beyond); root `AGENTS.md` preferably ≤ 200 lines (Claude Code's adherence target). Over → do not trim: report it, with the largest sections.
- Line count before = line count after across the files of a moved folder (bridge lines excluded).

## 5. Beyond instruction files — detect and report, change nothing without the user's yes

The plan does not depend on these (workers are driven by the dispatch scripts). Report each `GAP` row as one line with its fix:

| `GAP` | Fix to propose |
|---|---|
| `skills` | make `.agents/skills/<name>/` canonical (Codex reads it; opencode reads both) and keep `.claude/skills/<name>/` as a copy (or a link on a single-OS team); standard frontmatter only |
| `commands` | turn the ones the team uses into Agent Skills |
| `subagents` | none needed for a plan; port by hand the ones the team wants everywhere |
| `mcp` | list the server names only; the user re-declares them per harness — never copy a header, token or env value |
| `rules` (other tools' rule files) | propose moving the shared rules into `AGENTS.md` |
| `permissions` | say which protections do not apply to which workers |
| `size` | ignore; §4 checks the Codex limit |

## Sources (official, reachable 2026-09-21)

Claude Code https://code.claude.com/docs/en/memory (§ AGENTS.md) · https://code.claude.com/docs/en/skills · Codex https://learn.chatgpt.com/docs/agent-configuration/agents-md · opencode https://opencode.ai/docs/rules · https://opencode.ai/docs/skills · the standard https://agents.md
