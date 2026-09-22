# Plan template

Write `PLAN_FILE` from the template below. The execution protocol (dispatch, loop, review, git, journal) is **not** written into the plan: it ships as `.to-do/_tools/protocol.md`, copied with the scripts. Never re-type or edit it — what differs for this project goes to plan §4 **Overrides** or §5.

- §1–§3 and §5 are authored for the feature.
- §4 is generated from the resolved routing (`routing.md` + preflight results): real model IDs and harnesses, no `latest`, no unresolved placeholder. Rows: every routed role, scout, test-writer, review reader and review arbiter included.
- The plan must be executable by an orchestrator in **any** harness with shell access: never name a harness-specific tool; describe the action ("run a shell command", "spawn a subagent").

`````markdown
# <Feature title>

> Executed by an orchestrator agent: read `.to-do/_tools/protocol.md` first, then run it on this plan. Routing verified <YYYY-MM-DD> on <OS / shell>.

## 1. Goal
<2–4 lines: problem, outcome, non-goals.>

**Overall success criteria** — judged by the final review (protocol §2 step 7); the plan is not done before they all pass.
- [ ] G1 — <end-to-end, crosses parts: the user-visible flow works from entry point to stored result>
- [ ] G2 — <measurable, checkable, atomic>
- [ ] G3 — Full test suite, lint and typecheck pass: `<commands>`

## 2. Codebase brief
- **Stack**: <…>
- **Layout**: <paths that matter>
- **Commands**: install `<…>` · build `<…>` · test `<…>` · single test `<…>` · lint `<…>` · typecheck `<…>`
- **Conventions**: <observed rules, one line each>
- **Imitate**: <reference files>
- **Do not touch**: <paths>
- **Agent instructions**: `AGENTS.md` is the single source of project rules — every worker's harness loads it (`CLAUDE.md` and `GEMINI.md` only import it). <MULTI_PROVIDER_REPO `report` or `off`: replace with what exists and which workers do not see it — their briefs must then carry the rules.>

## 3. Parts

| # | Part | Type | Major | Depends on | Parallel-safe with | Weight |
|---|---|---|---|---|---|---|
| P1 | <name> | backend | yes | — | — | 20 |

Major = sub-plan written first (protocol §2). Minor = one task, one self-contained brief.

### P1 — <name>
- **Objective**: <what must be true when done>
- **Scope**: in `<paths>` · out `<paths>`
- **Contracts**: <exact shapes other parts rely on, if any>
- **Hard pieces** (complex-* only): [lead] <…> · [lead][critical] <dangerous: auth, payments, migration…> · [cont] <…>
- **Success criteria**: c1 <atomic: one observable behaviour, positive wording> · c2 <…>
- **Tests first**: <c1, c2 → `<test paths>`, single test `<command>`> | no — <reason>
- **Verify**: `<command>`

## 4. Routing and variables (verified <YYYY-MM-DD>)

| Task type / role | Worker model | Channel | Harness | Model argument |
|---|---|---|---|---|
| <type> | <model name> | <subscription \| api-key \| openrouter> | <claude \| codex \| agy \| gemini \| opencode> | `<exact ID for that harness>` |

| Variable | Value |
|---|---|
| `PLAN` | `<plan-name>` |
| `BRANCH` | `feat/<plan-name>` |
| `SHELL` | <bash \| powershell> — flavour that ran preflight; use the other one if this machine lacks it |
| `ORCHESTRATOR` | <model> in <harness> — <**required** \| preferred: any harness with shell access can run this plan (STRICT_HOST off, or substituted)> |
| `GATE` | <resolved Jev model \| `off`> |
| `CODEGRAPH` | <`off` \| `<binary>` · project `<graph project name>` · indexed <YYYY-MM-DD> · refresh: `<index command>`> |
| `AGENT_FILES` | <instruction files the planner created or changed: `AGENTS.md`, `CLAUDE.md`, `GEMINI.md` … \| none> |

<Only if CODEGRAPH is not off> **Code graph queries**: <the exact find-symbols · callers / callees · read-one-symbol · diff-impact commands from references/code-graph.md, project name filled in>

**Prompting notes** <routed workers only>
- <model>: <2–3 rules and worker caveats from references/providers.md>

**Substitutions**: <none | role: primary → alternate (reason)>

**Overrides**: <none | provider drift found at preflight: corrected flag, prompting rule or gate rule — it wins over protocol.md>

## 5. Risks & open questions
- <risk → mitigation>
- <a protocol rule that cannot apply to this project, and why>
`````
