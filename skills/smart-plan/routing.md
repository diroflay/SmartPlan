# Routing — edit this file to change who does what

Every coding role goes to **one provider**: Anthropic (`claude`) or OpenAI (`codex`). Preflight checks exactly what the chosen column needs; §4 of every plan is generated from it. For several providers in one plan, use the `smart-plan-multi` skill.

## Policy

- `PROVIDER: host` — the provider of the model running the skill: a Claude model → `anthropic`, a GPT model → `openai`, anything else → ask the user which of the two (non-interactive run: abort). Set `anthropic` or `openai` to force it. A provider named in the feature request (`provider=openai`) wins for that run.
- `USE_JEV: ask` — at Phase 0 the skill asks the user one yes / no question: use the Jev review gate? **yes** → gate on, `TYPESAFE_API_KEY` required · **no** → no Jev at all, plan `GATE` = `off` (`scripts/protocol.md` §3). Non-interactive run → no. Set `yes` or `no` to stop asking.
- `ON_MISSING: abort` — if any **primary** of the chosen column is unreachable, write no plan and report what is missing. Set to `fallback` to use the first reachable alternate of the same column instead (the report then lists every substitution). Never falls back to the other provider.
- `CHANNEL_ORDER: subscription > api-key > openrouter` — cheapest first (price check: `references/harness-internals.md` § Channel prices).
- `REQUIRE_OPENROUTER: off` — OpenRouter is an optional third channel to the same models (quota safety net, through the `opencode` bridge). Set `on` to make a valid OpenRouter key and `opencode` mandatory: missing → abort, whatever `ON_MISSING` says.
- `REQUIRE_CODEGRAPH: off` — scout and reviewers explore with search and read (measured cheaper on a mid-size repo: `references/harness-internals.md` § Measurements). Set `on` for a very large repo or monorepo: the tool named under **Code graph** below must then be installed — missing → abort, whatever `ON_MISSING` says.
- `STRICT_HOST: on` — the planner and the orchestrator must **be** the routed model (enforced: `references/preflight.md` §5). Set `off` to accept the running model (`host`).
- `MULTI_PROVIDER_REPO: on` — once the plan is written, the skill makes the project rules reach the chosen provider's workers, and any harness that may run the plan (`references/multi-provider.md`). Set `report` to change nothing and list what is missing, `off` to skip.
- `SMOKE_TEST: on` — preflight sends one tiny "reply OK" request per routed model. Set `off` to check logins and model lists only.

## Roles

Cell = primary, then alternates in order. `latest` = resolved live at preflight to the newest general-purpose model of that tier (`preflight models codex <tier>`). `host` = the model running the skill or the plan. **Never write a version number here**: a family or tier + `latest` (or a Claude alias: `fable`, `opus`, `sonnet`, `haiku`) stays right when a new model ships; preflight resolves the exact ID into plan §4.

| Role | anthropic (`claude`) | openai (`codex`) | Notes |
|---|---|---|---|
| planner | opus · fable · host | astra latest · host | writes the plan (`STRICT_HOST`) |
| orchestrator | opus · fable · host | astra latest · host | never codes (`STRICT_HOST`) |
| backend | sonnet · opus | sol latest · astra latest | |
| complex-backend [lead] | opus · fable | astra latest | hardest pieces only |
| complex-backend [cont] | sonnet · opus | sol latest · astra latest | cheap continuation; first alternate when the continuation is still hard |
| frontend | sonnet · opus | sol latest · astra latest | |
| complex-frontend [lead] | opus · fable | astra latest | hardest pieces only |
| complex-frontend [cont] | sonnet · opus | sol latest · astra latest | cheap continuation; first alternate when the continuation is still hard |
| critical pieces | the [lead] model of the piece's layer | the [lead] model of the piece's layer | dangerous code (list: `SKILL.md` Phase 2): always [lead], never [cont], even inside a non-complex part; review = gate + reader **and** the arbiter |
| test-writer | haiku · sonnet | luna latest · sol latest | codes the orchestrator's test list before implementation — an executant, it designs nothing; never the same model as the part's implementer — else first alternate |
| scout | sonnet · haiku | luna latest · sol latest | writes the context pack of a part; read-only |
| review gate | typesafe: jev-latest | typesafe: jev-latest | only if `USE_JEV` is yes: typed, calibrated answers about the diff, one call per review |
| review reader | sonnet · haiku | luna latest · sol latest | cheap model paired with the gate on **every** review; never the author's model — else first alternate |
| review arbiter | opus · fable | astra latest | strongest model that is not the author's; when the author is already the strongest, the same model in a fresh read-only session with none of the author's history. Only when gate and reader disagree, on ESCALATE, and as extra judge for [critical] tasks and the final review once gate and reader pass |
| other | haiku · sonnet | luna latest | docs, config, chores |

## Providers

How each provider is reached. Model arguments and prompting rules: `references/providers.md`. Checks: `references/preflight.md`.

| Provider | Harness (CLI) | Subscription channel | API-key channel | OpenRouter slug prefix |
|---|---|---|---|---|
| anthropic | `claude` | Claude Pro/Max login | `ANTHROPIC_API_KEY` | `anthropic/` |
| openai | `codex` | ChatGPT login | `CODEX_API_KEY` / `OPENAI_API_KEY` | `openai/` |
| typesafe (only if `USE_JEV` is yes) | HTTP API (`curl`) | none | `TYPESAFE_API_KEY` | not available |

## Code graph

| Tool | Binary | Install | Commands |
|---|---|---|---|
| codebase-memory-mcp | `codebase-memory-mcp` | https://github.com/DeusData/codebase-memory-mcp/releases — unpack the binary of your OS onto `PATH` (its `install` sub-command and install scripts also register an MCP server in every coding agent found: not needed here) | `references/code-graph.md` |

**Swap the tool**: change this row, rewrite `references/code-graph.md` with the new tool's CLI commands, and run the scripts with env `SP_CODEGRAPH=<binary>` (preflight looks for that binary; read-only Claude workers are allowed to run it).
