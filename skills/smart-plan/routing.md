# Routing — edit this file to change who does what

The only file to edit to add, remove or swap a model or provider. Preflight checks exactly what this table needs; §4 of every plan is generated from it.

## Policy

- `ON_MISSING: abort` — if any **primary** below is unreachable, write no plan and report what is missing. Set to `fallback` to use the first reachable alternate instead (the report then lists every substitution).
- `CHANNEL_ORDER: subscription > api-key > openrouter` — cheapest first (price check: `references/harness-internals.md` § Channel prices).
- `REQUIRE_OPENROUTER: on` — a valid OpenRouter key and the `opencode` bridge must be available even when every subscription works (it is the safety net for quota failures mid-plan). Missing → abort, whatever `ON_MISSING` says. Set `off` to make OpenRouter optional.
- `REQUIRE_CODEGRAPH: off` — scout and reviewers explore with search and read (measured cheaper on a mid-size repo: `references/harness-internals.md` § Measurements). Set `on` for a very large repo or monorepo: the tool named under **Code graph** below must then be installed — missing → abort, whatever `ON_MISSING` says.
- `STRICT_HOST: on` — the planner and the orchestrator must **be** the routed model: the skill aborts if another model runs it, and the plan tells any other orchestrator to stop. With `ON_MISSING: fallback`, or `off` here, the running model (`host`) is accepted and reported as a substitution.
- `MULTI_PROVIDER_REPO: on` — once the plan is written, the skill makes the project rules reach the workers of every provider (`references/multi-provider.md`). Set `report` to change nothing and list what is missing, `off` to skip.
- `SMOKE_TEST: on` — preflight sends one tiny "reply OK" request per routed model. Set `off` to check logins and model lists only.

## Roles

`latest` = resolved live at preflight to the newest general-purpose model of that family (no vision / experimental / dated snapshots). `host` = the model and harness running the skill or the plan.

| Role | Primary | Alternates (in order) | Notes |
|---|---|---|---|
| planner | anthropic: fable | openai: gpt-6-astra · google: pro latest · host | writes the plan; must be the model running the skill (`STRICT_HOST`) |
| orchestrator | anthropic: fable | openai: gpt-6-astra · google: pro latest · host | never codes; must be the model running the plan (`STRICT_HOST`) |
| backend | openai: gpt-6-astra | anthropic: opus · google: pro latest | |
| complex-backend [lead] | openai: gpt-6-astra | anthropic: opus | hardest pieces only |
| complex-backend [cont] | deepseek: latest | zai: glm latest · google: flash latest | cheap continuation |
| frontend | qwen: flash latest | zai: glm latest · google: flash latest | |
| complex-frontend [lead] | anthropic: opus | google: pro latest · openai: gpt-6-astra | hardest pieces only |
| complex-frontend [cont] | qwen: flash latest | qwen: max latest · zai: glm latest · google: flash latest | cheap continuation; `max` when the continuation is still hard |
| critical pieces | the [lead] model of the piece's layer | that row's alternates | dangerous code (list: `SKILL.md` Phase 2): always [lead], never [cont], even inside a non-complex part; review = gate + reader **and** the arbiter |
| test-writer | anthropic: sonnet | openai: gpt-5.6-sol · google: flash latest | codes the orchestrator's test list before implementation — an executant, it designs nothing; never the same model as the part's implementer — else first alternate |
| scout | deepseek: flash latest | qwen: flash latest · google: flash latest | writes the context pack of a part; read-only — about half a cent per scout. Paid on purpose: never a free model |
| review gate | typesafe: jev-latest | none — set to `off` to review with the reader alone | typed, calibrated answers about the diff, one call per review; reasoning-heavy checks go to the reader |
| review reader | deepseek: flash latest | openai: gpt-5.6-luna · qwen: flash latest · google: flash latest | cheap model paired with the gate on **every** review: reads the diff and its surroundings, writes the defect lines; never the author's model — else first alternate |
| review arbiter | strongest routed model from a provider other than the author | | only when gate and reader disagree, on ESCALATE, and as extra judge for [critical] tasks and the final review once gate and reader pass |
| other | cheapest routed model | | docs, config, chores |

## Providers

How each provider is reached. Model arguments and prompting rules: `references/providers.md`. Checks: `references/preflight.md`.

| Provider | Harness (CLI) | Subscription channel | API-key channel | OpenRouter slug prefix |
|---|---|---|---|---|
| anthropic | `claude` | Claude Pro/Max login | `ANTHROPIC_API_KEY` | `anthropic/` |
| openai | `codex` | ChatGPT login | `CODEX_API_KEY` / `OPENAI_API_KEY` | `openai/` |
| google | `agy` (Antigravity CLI) or `gemini` (Gemini CLI) | `agy`: Google AI plan login · `gemini`: Code Assist Standard/Enterprise only | `GEMINI_API_KEY`, or Vertex AI env | `google/` |
| deepseek | `opencode` | none | `DEEPSEEK_API_KEY` (`deepseek/…`) | `deepseek/` |
| zai | `opencode` | GLM Coding Plan (`zai-coding-plan/…`) | `ZHIPU_API_KEY` (`zai/…`) | `z-ai/` |
| qwen | `opencode` | Alibaba Token Plan (`alibaba-token-plan/…`, `ALIBABA_TOKEN_PLAN_API_KEY`) — the Alibaba *Coding* Plan does not serve the Qwen 3.8 models | `DASHSCOPE_API_KEY` (`alibaba/…`) | `qwen/` |
| typesafe | HTTP API (`curl`) | none | `TYPESAFE_API_KEY` | not available |
| *any other* | `opencode` | — | provider's key via `opencode auth login` | `<author>/` |

## Code graph

| Tool | Binary | Install | Commands |
|---|---|---|---|
| codebase-memory-mcp | `codebase-memory-mcp` | https://github.com/DeusData/codebase-memory-mcp/releases — unpack the binary of your OS onto `PATH` (its `install` sub-command and install scripts also register an MCP server in every coding agent found: not needed here) | `references/code-graph.md` |

**Swap the tool**: change this row, rewrite `references/code-graph.md` with the new tool's CLI commands, and run the scripts with env `SP_CODEGRAPH=<binary>` (preflight looks for that binary; read-only Claude workers are allowed to run it). The tool must work from a plain shell on every OS — no MCP client.

**Add a provider**: add a Providers row (if it is reachable through `opencode` or OpenRouter, the last row already covers it), then reference it in Roles as `<provider>: <model>`. No other file changes.
