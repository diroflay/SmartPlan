# SmartPlan

**Smartly plan a multi-provider agentic workflow to achieve your next implementation task**

`/smart-plan` prepare you a plan that the best model for each task implements, with every task tested and reviewed by a different model. 
You get better code for fewer tokens, and you never have to babysit the agent.

It is compatible with all majors harnesses. Improve your agents coding skills by smartly planning your next feature implementation.

| | |
|---|---|
| **Harnesses** | Claude Code · Codex CLI · Gemini CLI · Antigravity CLI · opencode · any agent that supports [Agent Skills](https://agentskills.io) |
| **Providers** | Anthropic · OpenAI · Google · DeepSeek · GLM · Qwen · OpenRouter |
| **OS** | Windows (PowerShell 5.1+) · macOS · Linux (bash 3.2+) |

## Install

**Claude Code** (marketplace)

```
/plugin marketplace add diroflay/SmartPlan
/plugin install smart-plan@smartplan
```

**Any harness** (skills installer)

```
npx skills add diroflay/SmartPlan
```

**Manual**: copy `skills/smart-plan/` to `~/.agents/skills/smart-plan/` and link it where your harness looks. See [INSTALL.md](skills/smart-plan/INSTALL.md).

## How to work with it

One skill, two steps: ask for a plan, then ask any agent to implement it. The plan is executed by an **orchestrator** that never codes. It sends each task to the best model for that job across providers, gets every task reviewed independently, commits, and reports progress.

```
/smart-plan Add OAuth login with Google and GitHub. Sessions in Redis, 7-day expiry. Keep the existing email login working. No new frontend framework.
```
```
Implement the plan @.to-do/oauth-login.md
```

### Step 1 — Ask for a plan

Describe the feature, what you expect and the constraints. The skill scans the codebase, designs the parts and writes `.to-do/<plan-name>.md`.

| Harness | Command |
|---|---|
| Claude Code · Antigravity CLI | `/smart-plan <feature, expectations, constraints>` |
| Codex CLI | `$smart-plan <feature, expectations, constraints>` |
| Gemini CLI | `Use the smart-plan skill: <feature, expectations, constraints>` |
| opencode, others | ask for the `smart-plan` skill by name |

Examples:

```
/smart-plan Add OAuth login with Google and GitHub. Sessions in Redis, 7-day expiry.
Keep the existing email login working. No new frontend framework.
```

Result:

```
✅ Smart Plan Created
- File: .to-do/oauth-login.md
- Parts: 4 (auth-backend — complex-backend — 40, session-store — backend — 20, ...)
- Routing: backend → gpt-6-astra, frontend → qwen flash, review → Jev gate + reader
- Parallel-safe: session-store ∥ login-ui
```

Read the plan. Adjust it if you want. Nothing has been implemented yet.

### Step 2 — Ask an agent to implement it

Open any harness and give the plan to the agent. It becomes the orchestrator.

```
Implement the plan @.to-do/oauth-login.md
```

The plan carries its own tooling in `.to-do/_tools/`, so it runs from any clone and any harness, even where the skill is not installed. Resume an interrupted run with the same message: the journal in `.to-do/<plan-name>/journal.md` says where it stopped.

Watch the workers from a second terminal, no tokens spent:

```bash
bash .to-do/_tools/status.sh .to-do/oauth-login
```
```powershell
powershell -ExecutionPolicy Bypass -File .to-do\_tools\status.ps1 .to-do\oauth-login
```

## How it runs

The orchestrator holds the whole picture and never writes code. Workers see only their brief.

1. **Scout** — a cheap model maps the files and lines for each part.
2. **Tests first** — the orchestrator lists the tests, a separate model codes them, then they are frozen.
3. **Best model per task** — strong lead model for hard and dangerous code, cheap model for the rest.
4. **Double review** — a calibrated gate (Jev) and a cheap reader judge every task. Disagreement goes to a strong arbiter. Fails go back to the worker, max two rounds.
5. **Commit per part** — journal and progress updated.
6. **Final review** — whole feature checked end to end: suite, lint, typecheck, wiring between parts.

Why it works: nobody grades their own work, expensive models only where they matter, same plan and scripts on every OS and harness.

## Configure

Edit one file: `skills/smart-plan/routing.md`. Roles → models, alternates, and these switches:

| Setting | Default | Meaning |
|---|---|---|
| `ON_MISSING` | `abort` | `fallback` uses the next reachable model |
| `REQUIRE_OPENROUTER` | `on` | OpenRouter key mandatory as safety net for quota failures |
| `REQUIRE_CODEGRAPH` | `off` | `on` for very large repos |
| `STRICT_HOST` | `on` | planner and orchestrator must be the routed model |
| `MULTI_PROVIDER_REPO` | `on` | makes project rules reach every provider's workers (`AGENTS.md` as single source) |
| `SMOKE_TEST` | `on` | one tiny request per routed model at preflight |

## Requirements

- `git`, plus the CLIs of the providers you route to (`claude`, `codex`, `gemini` or `agy`, `opencode`)
- API keys or subscriptions for those providers, `TYPESAFE_API_KEY` for the Jev review gate
- `curl` for the gate

Preflight tells you what is missing and how to install it:

```bash
bash skills/smart-plan/scripts/preflight.sh check
```
```powershell
powershell -ExecutionPolicy Bypass -File skills\smart-plan\scripts\preflight.ps1 check
```

## Layout

```
.claude-plugin/         plugin + marketplace manifests
skills/smart-plan/
  SKILL.md              the skill (standard Agent Skills frontmatter)
  routing.md            who does what — the only file to edit
  references/           preflight, providers, plan template, multi-provider repo
  scripts/              preflight · dispatch · status · jev · review (.sh + .ps1) + protocol.md
  adapters/             optional Gemini CLI slash command
  agents/openai.yaml    Codex CLI metadata
  INSTALL.md            manual install and test record
```

## License

MIT
