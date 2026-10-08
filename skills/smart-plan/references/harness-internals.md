# Harness internals — what the scripts do, and the evidence behind the skill

Read only for the preflight refresh step (`preflight.md` §4), to fix a script after a harness change, or to re-check a price or a measurement. Plans call `scripts/dispatch.(sh|ps1)`, which implements these commands (`SKILL.md`).

Status legend: **[verified]** = executed through the scripts on Windows 11 (Git Bash, Windows PowerShell 5.1, PowerShell 7), dates per section · **[docs]** = from the vendor's official docs, not executed (harness not installed or no key) — the smoke test shows at once if it no longer matches.

## Universal dispatch contract

| Step | Rule |
|---|---|
| Input | The brief file is piped on **stdin** (byte-exact; on Windows through `cmd.exe` redirection, not the PowerShell pipeline, which re-encodes). Never a long prompt as an argument. |
| Output | The worker writes its ≤15-line report to the result path named in the brief **and** the script captures the final message itself (output flag or event log). Either one is enough. |
| Session | The session ID is captured from the JSON output and journaled. Follow-ups resume that session. |
| Limits | The script applies the timeout itself: `timeout` → `gtimeout` → built-in watchdog; PowerShell kills the whole process tree. One coherent task per run. |
| Visibility | The script keeps `<RESULT>.status` up to date (`task` from env `SP_TASK`, harness, model, `state` = running → done / failed / timeout, then exit, session, result) and asks every harness that can for a **streamed** event log (`<RESULT>.events`). `status.(sh|ps1)` turns both into a board without spending a model token. |
| Blocking | Harness shell tools cut long calls (Claude Code: 10 min) well under the 1800 s dispatch timeout: background shell, or env `SP_DETACH=1` (the script re-launches itself detached and returns) then `status.(sh|ps1) wait <max_s> <RESULT>…`. |
| Permissions | Writers get the narrowest mode that allows file edits in the workspace. Reviewers run read-only. No bypass flag (`SKILL.md` § Rules). A harness that cannot edit headlessly under the user's settings: route that model through another channel and say so. |
| Git | Workers never run git write commands. The orchestrator checks `HEAD` and `git status --short` after each run. |

Portability handled by the scripts: no dependency on `timeout`, `jq` or Node (Node if present, else `grep` / `sed`; PowerShell parses JSON natively), bash 3.2 compatible (stock macOS), ASCII-only PowerShell that runs on stock 5.1, paths with spaces, non-git folders.

## Anthropic — Claude Code (`claude`) [verified read-only 2.1.285, 2026-09-30; write mode per docs]

| | |
|---|---|
| Write task | `claude -p --model <opus\|fable\|sonnet\|haiku\|full-id> --permission-mode acceptEdits --allowedTools "Bash(<verify command> *)" --output-format stream-json --verbose < <BRIEF> > <RESULT>.events` |
| Read-only | `claude -p --model <id> --permission-mode dontAsk --allowedTools "Read" "Grep" "Glob" "Bash(git diff *)" "Bash(git status *)" "Bash(<code-graph binary> *)" --output-format stream-json --verbose < <BRIEF>` [verified] |
| Result / session | last event (`"type":"result"`): fields `result` and `session_id` [verified]. `stream-json` needs `--verbose` in `-p` mode; it is what makes the run visible live (one `assistant` event per tool call or text). |
| Resume | `--resume <session_id>`, the follow-up on stdin |
| Auth check | `claude auth status` → JSON `loggedIn`, `authMethod`, `subscriptionType` [verified] |
| Caveats | No `--bare` with a subscription (it ignores the login and requires an API key). `-p` denies any tool not allow-listed, so the verify command is allowed explicitly (`SP_ALLOW`). `--max-turns N` and `--max-budget-usd` cap runaway runs (not passed by the scripts). |

**Native subagents** (orchestrator in Claude Code): spawn a subagent and pass the model per invocation (`opus`, `sonnet`, `haiku`, `fable`, or a full ID); reusable definitions in `.claude/agents/<name>.md` (frontmatter `name`, `description`, `tools`, `model`). Read-only reviewer: restrict `tools` to read / search tools.

## OpenAI — Codex CLI (`codex`) [verified 0.156.1, 2026-09-30]

| | |
|---|---|
| Write task | `codex exec -m <model> -C "<repo>" -s workspace-write --json -o <RESULT> - < <BRIEF> > <RESULT>.events` [docs for `workspace-write`; command shape verified read-only] |
| Read-only | same with `-s read-only` [verified] |
| Result / session | `-o` file holds the final message; session ID = `thread_id` of the `thread.started` event [verified] |
| Resume | `codex exec resume <thread_id> -m <model> -c sandbox_mode=<read-only\|workspace-write> --json -o <RESULT> - < <FOLLOW-UP>` — `resume` has no `-s`: without the `-c` override the turn runs under the config default sandbox (openai/codex#40149) [flags per `--help` 0.154; effect of the override not executed] |
| Auth check | `codex login status` → exit 0 + "Logged in using ChatGPT" [verified]; models available to the login: `codex debug models` [verified, debug command — may change; ~359 KB on one line: read it only through `preflight models codex`] |
| Caveats | `exec` defaults to a read-only sandbox: edits need `-s workspace-write`. `--full-auto` is deprecated. `codex mcp-server` was removed in 0.154 — use `codex exec`. Outside a git repo add `--skip-git-repo-check`. Windows: the native sandbox needs a one-time elevated setup. |

**Native subagents** (orchestrator in Codex): stable, on by default (`spawn_agent`, `wait_agent`, `send_input`… — tool names not re-confirmed). Reusable definitions: `.codex/agents/<name>.toml` with `name`, `description`, `developer_instructions`, optional `model`, `model_reasoning_effort`, `sandbox_mode`. Codex delegates only when told to — name the agent explicitly. Subagents inherit the parent's sandbox. Custom providers must speak the Responses API, so non-OpenAI models are reached by shelling out, not as Codex subagents.

## Bridge — opencode (`opencode`)

| | |
|---|---|
| Write task | `opencode run -m <provider/model> --dir "<repo>" --auto --format json < <BRIEF> > <RESULT>.events` [verified] |
| Read-only | omit `--auto`; the brief tells the worker it must not edit |
| Result / session | every event carries `sessionID`; the final message is the last `"type":"text"` event (`part.text`) [verified]. Without `--format json`, stdout is the final message. |
| Resume | `opencode run -s <sessionID> --format json < <FOLLOW-UP>` [verified] |
| Auth check | `opencode auth list` (stored credentials) [verified]; model IDs: `opencode models` [verified] — without a provider's credential its models are not listed |
| Caveats | **No `-f` to attach the brief**: `-f` is an array flag and swallows the message (`File not found`), and message + `-f` hangs without a TTY [verified 1.18.30]. `--auto` approves everything not explicitly denied — deny rules belong in `opencode.json` (`providers.md`). `--variant` sets reasoning effort. |

## Jev (TypeSafe AI) — vendor facts behind `protocol.md` §3 [request builder verified against a local mock on bash, PowerShell 5.1 and 7 — live API not executed: no key on the authoring machine]

- Versioned ID this snapshot was written for: `jev-1.13.0`. Launched 2026-09-15; every accuracy claim is still TypeSafe's own.
- Consistency: vendor measure ±0.01 on a probability between identical calls — hence "never re-ask to vote" and a dead band between pass and fail.
- Billed on input tokens only ($0.042 per 1M): an extra question costs almost nothing, extra state costs accuracy.
- API limit: 32k tokens for the state plus the longest question (64k with all questions). Script limit `SP_JEV_MAX_BYTES` = 80 000 characters (≈ 25k tokens of code).
- Response: one answer per question ID — `noul` = a probability 0–1 (no confidence field); `choice` = the option, per-option probabilities, `confidence`. A Choice always elects a winner and is not bound to agree with the Noul. Thresholds are per question type: never reuse a Noul threshold on a Choice `confidence`.
- Question design: `instructions` and each `criteria` value accept a string, an object or an array. An option confused with its neighbour gets an object: `{"description": "…", "not_for": "…", "examples": ["…"]}`. One claim per question, positive wording, no "and / or", no double negative; English is where Jev is most accurate; naming the state field in backticks lowers indirection.
- The fixed question sentences and the rubric live in `scripts/review.(sh|ps1)`; change them there, in both flavours.
- Official skill `typesafe-ai/skills`: question-design guidance, no caller — optional, used only to refresh these rules.
- Ideas left out on purpose: a Choice over line IDs to locate a gap; the Score primitive.
- Beyond the official docs: community guide https://dev.to/valyuai/how-to-use-jev-a-practical-guide-to-typesafes-system-one-model-g5e · review CLIs https://github.com/manojlds/jev-review and https://github.com/devagrawal09/jev-code · reference gist https://gist.github.com/pjburnhill/adf8d28efcad9df037bfdece178ef965

## Channel prices (checked 2026-09-30, $ per 1M tokens in / out — re-check at each refresh)

By tier, for the version that was latest on that date; a newer version may cost differently. Routing never pins these versions.

| Model | Official key | OpenRouter (default host) | Subscription |
|---|---|---|---|
| fable 5.1 · opus 5.5 · sonnet 5.5 · haiku 5.5 | 10 / 50 · 4 / 20 · 2 / 10 · 0.10 / 0.50 (haiku: prompts > 100k tokens bill 5×; checked 2026-10-08) | same | Claude Pro / Max |
| gpt-6-astra · gpt-6-sol · gpt-6-luna | 10 / 50 · 2 / 10 · 0.10 / 0.50 (sol: prompts > 272k tokens bill 2× in / 1.5× out) | same | ChatGPT plan |

## Model choice (checked 2026-09-30 — why the routing is what it is; re-check at each refresh)

- **opus** ≥ fable on nearly every coding / agentic benchmark at 40 % of the price (AA Intelligence #1, Coding Agent Index #1 = 66, WebDev arena #1, best CodeRabbit review 8/13) → planner, orchestrator, [lead], arbiter. **fable** only as alternate.
- **sonnet** ≈ **sol** (same price): sonnet has the best Terminal-Bench 4.0 of all (70.6) but the most output tokens per task measured by AA (~193k); sol ≈ astra on DeepSWE at ~1/5 the cost. Both = routine coding, never [lead].
- **luna**: AA Intelligence 37 at $0.07 per task — about 4× cheaper than any other cheap model at similar quality → scout, reader, chores. Context window not published.
- **haiku 5.5** (2026-10-07, checked 2026-10-08): AA Intelligence 43 (top small model, 13 below sonnet), Terminal-Bench 4.0 39.2 vs sonnet 70.6, HLE with tools 57.4 vs 64.5, AA-Omniscience hallucination 40 % vs luna 77 %, ~$0.21 per task at max effort in AA's runs (~3× luna; dispatch leaves the default `medium`). 1M context, adaptive thinking only (no `budget_tokens`, no custom temperature). Too weak for agentic coding → scout, reader, test-writer, chores; never implementer, [lead] or arbiter. The `haiku` alias is 5.5 only on the Anthropic API and Claude plans with Claude Code ≥ 2.1.293 (Bedrock / Vertex / Foundry: still 4.5) — preflight checks both. Sources: anthropic.com/claude-haiku-5-5, platform.claude.com/docs/en/models/haiku-5-5/overview, the-decoder.com (AA figures).
- Caveats: many scores are vendor-reported; SWE-bench Verified is contaminated; METR and SWE-rebench had not measured these models on that date. Sources: artificialanalysis.ai (leaderboards, articles on Sonnet 5.5, Opus 5.5, GPT-6 Astra, GPT-6 Sol / Luna), arena.ai/leaderboard/code/webdev, coderabbit.ai/blog/sonnet-5-5-model-review, anthropic.com/claude-sonnet-5-5, learn.chatgpt.com/docs/models.

OpenRouter adds no markup per token but charges **5.5 % on every credit purchase**, so at equal list price the official key is 5.5 % cheaper.

## Measurements

- **Free models** (2026-09-21, scouts on pallets/flask): of six `:free` OpenRouter models, 3 gave a usable pack, 1 a thin one, 1 stopped without a report, 1 was refused with HTTP 429; they share 50–1 000 requests / day, and free endpoints may log or train on the code they are sent.
- **Code graph** (2026-09-21, pallets/flask — 236 files, 18k Python lines; scout = a cheap model via opencode, same brief with and without the graph, one run each): localized change — graph 147k input tokens / $0.0065 vs search-and-read 103k / $0.0042; cross-cutting caller chain — graph 254k / $0.0093 vs 143k / $0.0057. Context packs of equal quality. On a repo this size the graph saved **nothing**: a modern agent's own search and read tools are already frugal, and the model used the graph *in addition to* them. The vendor's "120× fewer tokens" is measured against reading whole files. Expect a benefit only on large repos or monorepos, where search results explode — not measured here.

## Sources (official — used by the preflight refresh step; all reachable 2026-09-20)

| Provider | Docs | Repo (releases, examples) |
|---|---|---|
| Anthropic | https://code.claude.com/docs/en/headless · https://code.claude.com/docs/en/sub-agents | https://github.com/anthropics/claude-code |
| OpenAI | https://developers.openai.com/codex | https://github.com/openai/codex |
| opencode | https://opencode.ai/docs | https://github.com/anomalyco/opencode |
| OpenRouter | https://openrouter.ai/docs | — |
| TypeSafe (Jev) | https://docs.typesafe.ai/llms.txt (index; add `.md` to any page path) · limits and price: `/models.md` · known weaknesses: `/model-jaggedness/jev-1.13.md` | https://github.com/typesafe-ai/skills |
| Code graph | — | https://github.com/DeusData/codebase-memory-mcp |

Versions this snapshot was verified against: `preflight.md` §4 (`claude`: read-only runs).
