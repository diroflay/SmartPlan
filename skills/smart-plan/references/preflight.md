# Preflight

Prove that every model in `routing.md` is reachable **from this machine, today**. The checks are scripted so they behave the same on every OS — do not improvise them.

## 0. Pick the script flavour (once, reuse everywhere)

| You can run | Use | Notes |
|---|---|---|
| `bash` (Linux, macOS, WSL, Git Bash) | `scripts/*.sh` | bash 3.2+; no `timeout`, `jq` or Node required |
| PowerShell only (Windows without bash) | `scripts/*.ps1` | Windows PowerShell 5.1+ or PowerShell 7+; run with `-NoProfile -NonInteractive -ExecutionPolicy Bypass -File` |

Test with `bash --version`. The flavour that works is the plan's `SHELL` variable. Run the scripts from the project root (the git check uses the current directory).

## 1. Collect facts

`preflight check <providers>` — comma-separated list of every provider named in the Roles table of `routing.md`, e.g. `check anthropic,openai,deepseek,zai,qwen,typesafe`.

Output, tab-separated: `STATUS  item  detail  fix` with STATUS = `OK` | `MISSING` | `INFO`, plus one `CHANNEL  <provider>  <subscription|api-key|openrouter|none|unverified-login>` line per provider — already in `CHANNEL_ORDER`. Secrets are never printed; keys show as present / missing. On Windows the PowerShell flavour also sees User- and Machine-scope variables that the current process cannot.

`CHANNEL none` = provider unreachable. `unverified-login` (Google: no auth-status command exists) = decided by the smoke test.

## 2. Resolve `latest`

Per `latest` in the routing, list the family on the chosen channel with `preflight models <harness> [regex]` — it prints matching model IDs only, one per line (`opencode`, `codex`, `agy`; `claude` and `gemini` print their aliases). **Never run a harness's own model listing**: `codex debug models` alone is ~90k tokens. Pick the newest general-purpose model: highest version; skip vision, experimental and dated snapshots; skip previews when a stable exists; keep the requested tier. The exact ID must appear in the list. Record ID + channel + date.

## 3. Smoke test (when `SMOKE_TEST: on`)

`preflight smoke-all <timeout_s> <harness>=<model> [<harness>=<model> …]` — every distinct routed model on its chosen channel, in one call: the pairs run in parallel (120 s is a good timeout). Each gets "Reply with exactly: OK" through the real dispatch path, read-only, in a temp folder. One row per pair: `OK` = reachable; on failure the row carries the harness's own error (not logged in · model not available to this login · 402 / 429 quota or credit · `timeout`). Exit 0 = all OK. An OK is cached for 24 h (`(cached …)` in the row; env `SP_SMOKE_CACHE_H=0` forces a real call); failures are never cached. Single model: `preflight smoke <harness> <model> [timeout_s]`.

- A subscription channel fails → smoke the next channel before declaring the model missing.
- Skip the model that is running this skill — it is evidently reachable.
- Jev has no harness: if `typesafe` is routed and its key is present, smoke it with `jev <questions.json> <response.json> note=<file>` — one question `{"q": {"type": "noul", "instructions": "Is `note` non-empty?", "criteria": {"true": "yes", "false": "no"}}}`, any one-line text file as state — and expect `http=200`; note the versioned `model` of the response. The script builds the body and passes the key itself: never hand-write the `curl` call, never put the key on a command line.
- Code graph, only when `REQUIRE_CODEGRAPH` is on (`references/code-graph.md`; non-default binary: env `SP_CODEGRAPH=<binary>`): index the project — it must answer `status: indexed` — and record the returned project name for plan §4.

## 4. Refresh provider knowledge (routed harnesses only, token-frugal)

`providers.md`, `harness-internals.md` and `scripts/protocol.md` are dated snapshots. Refresh a routed harness or model family when **any** of these is true:
- its installed version (`<cli> --version`) differs from the snapshot's (2026-09-21): `codex` 0.154 · `agy` 1.2.7 · `opencode` 1.18.30 · `claude` 2.1.278 · `gemini` docs only · `codebase-memory-mcp` 0.11.0 · Jev `jev-1.13.0`;
- its smoke test failed for a reason other than login / quota;
- the resolved model is a family or major version the prompting notes do not name;
- the last refresh is older than 30 days — last refresh = the later of the snapshot date and the date in `~/.cache/smart-plan/refreshed`. After a refresh, write today's date (`YYYY-MM-DD`) there (the only file this skill writes outside the project), so an unchanged machine is not refreshed on every run.

How: `<cli> --help` (and the sub-command's `--help`) first — local and exact. Then the official sources of `harness-internals.md` § Sources: headless / non-interactive mode, subagents, the model's prompting guide, release notes and examples. Read only the pages for what changed. No web access: say so in the Report and rely on the smoke test.

Jev: refresh when the versioned ID of the smoke response differs from the one above. Load the official TypeSafe skill if installed (else the index in § Sources) and re-read only the models, primitives and jaggedness pages. Never load that skill per task: the question rules are already distilled in the protocol and the review script.

Then: write each correction (flag, prompting rule, gate rule) into the plan's §4 **Overrides**, list each drift in the Report under `Provider drift`, and — if a script flag is wrong — stop and report it rather than hand-writing a harness command in the plan.

## 5. Decide

If the outcome is **abort**, do §6 first: an abort is final only after the user had the chance to fix what is missing.

- `ON_MISSING: abort` and any primary unreachable → **abort**.
- `ON_MISSING: fallback` → substitute the first reachable alternate; list every substitution in the Report and plan §4. Abort only if a role has no reachable model at all.
- A `MISSING git` line is always fatal: the protocol needs branches, diffs and commits.
- `REQUIRE_OPENROUTER: on` → a `MISSING openrouter.key` or `MISSING openrouter.bridge` line is fatal, even if every routed model is reachable by subscription and whatever `ON_MISSING` says. (`check` always emits both lines.)
- `REQUIRE_CODEGRAPH: on` → a `codegraph … not installed` line, or a failed indexing, is fatal in the same way. `off` → ignore the `codegraph` line and skip the indexing.
- `STRICT_HOST: on` with `ON_MISSING: abort` → identify the model running this skill (your own model identity; if unsure, the harness's model / status command). Not the routed **planner** → abort, Fix = relaunch the skill in the routed harness with that model selected (e.g. `claude --model fable`). The routed **orchestrator** must also be reachable like any other primary (check + smoke, skipped if it is the running model). Otherwise (`fallback`, or `STRICT_HOST: off`): continue as `host` and report the substitution.

## 6. Help first, abort second

Never abort on the first failed check:

1. Output the missing-items table (columns of the Abort Report); Fix = the script's `fix` column completed by the table below.
2. Ask the user, in one question: **fix now** (you wait, then re-check) · **use fallbacks** (only if alternates exist: continue as with `ON_MISSING: fallback` for this run, substitutions listed in the Report) · **abort**.
3. Fix now — who does what:
   - **A tool to install** (a CLI, the code-graph binary): propose the install command for this OS and run it **only after the user says yes**. Never silently, never with elevated rights, never through a script that changes other tools' configuration.
   - **A login** (`claude auth login`, `codex login`, `opencode auth login`, `agy`): interactive, so the user runs it — give the exact command (in Claude Code they can type `! <command>` to run it in this session).
   - **An API key**: say where to create it and which environment variable to set, for their shell (`export NAME=…` in the shell profile · PowerShell: `[Environment]::SetEnvironmentVariable('NAME','…','User')`, then a new terminal). **Never ask for the key in the chat, never write it to a file of the project, never print it.**
4. When the user says it is done: re-run `check` (and the failed smoke tests, `SP_SMOKE_CACHE_H=0`) — once per round, at most 3 rounds.
5. Still missing, or the user chose abort, or no answer is possible (non-interactive run): output the Abort Report and stop. Nothing is written.

| Missing | Create / install | Then |
|---|---|---|
| `claude` | https://code.claude.com/docs (installer per OS) | `claude auth login` |
| `codex` | `npm i -g @openai/codex` | `codex login` |
| `opencode` | `npm i -g opencode-ai` | `opencode auth login` → OpenRouter |
| `agy` / `gemini` | Antigravity CLI installer · `npm i -g @google/gemini-cli` | sign in on first run |
| OpenRouter key | https://openrouter.ai/keys | `opencode auth login`, or env `OPENROUTER_API_KEY` |
| Jev key | https://typesafe.ai (console → API keys) | env `TYPESAFE_API_KEY`, or set the review gate to `off` in `routing.md` — `check` validates it with `GET /v1/models` (no token spent) |
| official TypeSafe skill (`INFO typesafe.skill`, **optional, never fatal**) | Claude Code: `claude plugin marketplace add typesafe-ai/skills`, then `claude plugin install typesafe@typesafe-ai` · other agents: `npx skills add typesafe-ai/skills --skill typesafe-ai` (interactive: the user runs it and picks the agent). One method only. Offer it once, install **only after a yes** — it adds a plugin to the user's agent | nothing to re-check. It is design guidance, not a caller: the scripts stay the only way a plan calls Jev. Used only by the §4 refresh |
| DeepSeek / Z.ai / Alibaba key (optional: cheaper than OpenRouter) | https://platform.deepseek.com · https://z.ai/manage-apikey · https://modelstudio.console.alibabacloud.com | `opencode auth login`, or the env var of `routing.md` § Providers |
| code graph (only if `REQUIRE_CODEGRAPH: on`) | release archive → binary on `PATH` (`routing.md` § Code graph) | re-run `check` |
| git repository | `git init` (ask first: it changes the folder) | re-run `check` |

## Abort Report

```
# ⛔ Smart Plan Aborted — missing access

| Role(s) | Model | What is missing | Fix |
|---|---|---|---|
| review gate | jev-latest | TYPESAFE_API_KEY not set | set it, or set the review gate to `off` in routing.md |
| all (safety net) | OpenRouter | no OPENROUTER_API_KEY and no opencode credential | `opencode auth login`, or set `OPENROUTER_API_KEY` |
| planner | fable | skill is running on <model> | relaunch in Claude Code with Fable selected |

Checked OK: <short list>
No plan was written.
```
