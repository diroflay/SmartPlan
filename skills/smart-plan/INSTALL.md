# smart-plan — Install & Use (v1.2.0)

Single-provider twin of `smart-plan-multi`: same workflow, protocol and scripts, every coding role on **one** provider — Anthropic (`claude`) or OpenAI (`codex`). An [Agent Skill](https://agentskills.io/specification) with standard frontmatter only. This file is for humans.

## Install

Windows (PowerShell, no admin needed for junctions):
```powershell
Copy-Item -Recurse .\smart-plan "$HOME\.agents\skills\smart-plan"
New-Item -ItemType Junction -Path "$HOME\.claude\skills\smart-plan" -Target "$HOME\.agents\skills\smart-plan"
```
macOS / Linux:
```bash
mkdir -p ~/.agents/skills ~/.claude/skills
cp -R ./smart-plan ~/.agents/skills/smart-plan
ln -s ~/.agents/skills/smart-plan ~/.claude/skills/smart-plan
```
Codex reads `~/.agents/skills/` itself; Claude Code needs the link. Restart the harness after installing.

## Invoke

| Harness | How |
|---|---|
| Claude Code | `/smart-plan <feature request>` → Anthropic routing |
| Codex CLI | `$smart-plan <feature request>` → OpenAI routing |

The provider follows the model running the skill (`PROVIDER: host` in `routing.md`). By default (`STRICT_HOST: on`) that model must be the routed planner: Opus in Claude Code, newest Astra in Codex.

## Configure

Edit `routing.md` only: provider, models per role, abort vs fallback, OpenRouter safety net (off by default), smoke test.

## Requirements

`git`, `claude` or `codex` logged in (or its API key), `TYPESAFE_API_KEY` + `curl` only if you answer yes to Jev (asked each run, `USE_JEV` in `routing.md`). `opencode` only for the OpenRouter channel. `preflight check` says what is missing.

## Test record

Script tests: `smart-plan-multi/INSTALL.md`.

| Date | What ran | Result |
|---|---|---|
| 2026-09-30 · Windows 11 · Git Bash | `preflight smoke-all` on every routed model: `claude` → `fable`, `opus`, `sonnet`, `haiku` · `codex` → `gpt-6-astra`, `gpt-6-sol`, `gpt-6-luna` | pass |

**Not tested**: an end-to-end plan generated and executed with this skill; the OpenRouter channel for Anthropic / OpenAI slugs. Prices: `references/harness-internals.md` § Channel prices.
