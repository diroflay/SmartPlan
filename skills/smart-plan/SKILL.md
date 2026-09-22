---
name: smart-plan
description: Creates a multi-provider implementation plan for a feature and saves it to .to-do/. The plan tells an orchestrator agent how to dispatch coding work to the best model per task type across providers (Anthropic, OpenAI, Google, DeepSeek, GLM, Qwen, OpenRouter), review each task independently, commit, journal and report progress. Use when the user asks for a smart plan, a multi-agent or multi-model plan, or invokes smart-plan with a feature request. Not for an ordinary implementation plan, and not for executing or resuming a plan.
compatibility: Needs shell access and git. Uses whichever of these CLIs the routing requires - claude, codex, agy or gemini, opencode - plus curl for the Jev review gate.
metadata:
  version: "1.0.0"
---

# Smart Plan

Write `.to-do/<plan-name>.md`: a plan executed later by an **orchestrator agent** that never codes — it dispatches each task to the worker model that is strongest for it, across providers, and has every task independently reviewed.

Harness-neutral: runs in any agent that supports Agent Skills and can run shell commands. Tool names differ per harness; instructions here describe actions ("run a shell command", "read the file", "search the codebase").

## Input

`USER_PROMPT` = the feature request: everything the user wrote when invoking this skill (in Claude Code: `$ARGUMENTS`). If that is empty, or still shows the literal text `$ARGUMENTS`, use the user's latest message. No feature request at all → ask for one and stop.

## Files (paths relative to this skill's folder)

| File | Read |
|---|---|
| `routing.md` | Phase 0 — who does what; the only file users edit |
| `references/preflight.md` | Phase 0 — checks, smoke tests, help-then-abort, Abort Report |
| `references/providers.md` | Phase 0 and 3 — model arguments, prompting notes and worker caveats per provider |
| `references/plan-template.md` | Phase 3 |
| `references/multi-provider.md` | Phase 4 — only when the repository is not already compatible |
| `references/code-graph.md` | only when `REQUIRE_CODEGRAPH` is on |
| `references/harness-internals.md` | only for the preflight refresh step, or to fix a script |
| `scripts/*.sh` · `*.ps1` | **run, never read**: `preflight`, `dispatch`, `status`, `jev`, `review` |
| `scripts/protocol.md` | the execution protocol the orchestrator follows — read only when a project constraint may conflict with it (no test setup, no branch workflow…) or the refresh step found drift in a gate or dispatch rule |

Output: `PLAN_FILE` = `.to-do/<plan-name>.md` in the project (kebab-case name from the feature) and the tools folder `.to-do/_tools/`. Do not create `.to-do/<plan-name>/`; the orchestrator does.

Never hand-write harness commands, timeouts or stdin plumbing — they differ per OS. Use the scripts (flavour: `references/preflight.md` §0).

## Workflow

### Phase 0 — Preflight
Read `routing.md`, then follow `references/preflight.md` to its end. Abort = output the Abort Report, write nothing, stop — and only after helping the user fix what is missing. Never print a secret, never ask for one in the chat.

### Phase 1 — Codebase scan (quick, token-frugal)
Give workers the rules of this codebase, not a tour of it. Search before you read; read line ranges, not whole files (`REQUIRE_CODEGRAPH` on: the code graph for structure). Read only: `AGENTS.md` / `CLAUDE.md` / `GEMINI.md` / README / CONTRIBUTING, manifests, lint / format / test config, top-level layout, and one or two representative files per layer the feature touches. Extract:
- stack and versions that matter; layout relevant to the feature
- exact commands: install, build, test (suite and single test), lint, typecheck
- conventions actually observed: naming, error handling, data / state patterns, test style and location, styling, i18n
- reference files to imitate; do-not-touch zones and generated files

### Phase 2 — Design
- Think hard about the approach and the split into parts. Add what prevents failure: edge cases, migrations, contracts between parts, risky unknowns.
- Describe **goals, behaviour, constraints and contracts** — not the implementation. Workers decide how. Code or pseudo-code only for a contract that must be exact (API shape, schema, event name).
- Split into **parts** ordered by dependency. Per part: objective, scope (paths in / out), type (`backend` | `complex-backend` | `frontend` | `complex-frontend` | `other`), dependencies, measurable success criteria, verify command, weight, major yes / no.
- **Major** part = any `complex-*` part, a part that needs several tasks, or one that builds a contract other parts rely on. The orchestrator writes a self-contained sub-plan before each major part. A minor part is a single task run from one self-contained brief — no sub-plan — so give it enough detail in the plan to be briefed directly.
- Mark a part `complex-*` only if it has genuinely hard pieces (architecture, concurrency, tricky algorithm or state, cross-cutting contract) **or dangerous ones**. Name which pieces are **[lead]** (expensive model) and which are **[cont]** (cost-efficient model continuing on the lead's pattern).
- **Dangerous = [lead][critical]**, however simple it looks: auth, permissions, payments, secrets, crypto, data migration or deletion, a public contract others depend on. A bug there costs data or money, so it never goes to a [cont] model and its review also goes to the arbiter.
- Success criteria must be checkable by a command or by reading a diff. Every part has them; the overall plan has them. Give each an ID (`c1`, `c2`…) and make it **atomic**: one observable behaviour, positive wording, no "and / or" — a failed criterion must tell by itself what to fix.
- **Overall success criteria** are not the sum of the parts: at least one end-to-end criterion that crosses parts (the user-visible flow working from entry point to stored result) plus the full suite / lint / typecheck commands. The orchestrator's final review judges exactly these.
- **Tests first**: per part, say which criteria get tests written before implementation (paths, framework, single-test command). `no — <reason>` only when the project has no test setup for that layer or the criterion is not testable by code (pure styling, config).
- Weights sum to 100 — the orchestrator's progress % is then deterministic.
- Parallel-safe only if file scopes are disjoint **and** no shared contract under construction, migration, lockfile or generated artefact. When unsure: sequential.

### Phase 3 — Write the plan
1. Copy every file of `scripts/` — `.gitattributes` included — into `.to-do/_tools/` of the project (overwrite older copies; keep LF line endings on the `.sh` files). The plan then carries its tooling and protocol and runs from any clone, on any OS, even where this skill is not installed.
2. Write the plan from `references/plan-template.md`, with `references/providers.md` for plan §4.

### Phase 4 — Multi-provider repository
Each harness loads only its own instruction file: rules kept in `CLAUDE.md` alone never reach a Codex, Gemini or opencode worker. Policy `MULTI_PROVIDER_REPO` = `off` → skip. Otherwise run `preflight agents`: `RESULT compatible` → report `already compatible`; else follow `references/multi-provider.md`. Then fill **Agent instructions** (plan §2) and `AGENT_FILES` (plan §4). Run no git command.

### Phase 5 — Report
Output the Report below.

## Rules
- The plan is for agents: unambiguous goals, low token cost, no narrative. Tables and bullets over prose.
- Plan §4 holds real, verified model IDs — no `latest`, no unresolved placeholder.
- Never copy, re-type or edit `protocol.md` into the plan. A protocol rule that cannot apply to this project → say so in plan §5 instead of silently dropping it.
- Never put a permission-bypass or sandbox-bypass flag in a plan.
- Do not start implementing. Do not create branches, sub-plans or the journal. In the project, outside `.to-do/`, the only files this skill may write are the agent instruction files of Phase 4 (`AGENTS.md`, `CLAUDE.md`, `GEMINI.md`).

## Report

```
# ✅ Smart Plan Created

- **File**: .to-do/<plan-name>.md
- **Planned by**: <model> in <harness> <(routed planner was …) if different>
- **Parts**: <n> (<name — type — weight>, …)
- **Routing**: <role → model via channel>, … · Review: <gate + reader, arbiter>
- **Substitutions**: <none | role: primary → alternate (reason)>
- **Provider drift**: <none | harness or model: what changed vs the snapshot | not checked (no web access)>
- **Parallel-safe**: <pairs | none>
- **Multi-provider repo**: <already compatible | created: <files> · changed: <files> (content moved verbatim) | report only | off> · Gaps needing your yes: <none | skills / commands / subagents / MCP / rules / permissions: one line each with the fix>

## Topic
<one or two lines>

## Open questions
- <only if any>
```
