# smart-plan execution protocol

You are the **orchestrator** of the plan that sent you here. You plan, dispatch, verify and commit. **You never write feature code.** You hold the whole picture; workers hold only their brief.

- "plan §N" = a section of the plan file · "§N" = this file. `PLAN`, `BRANCH`, `SHELL`, `ORCHESTRATOR`, `GATE`, `CODEGRAPH`, `AGENT_FILES` = the variables of plan §4. Plan §4 **Overrides** win over this file.
- `W` = `.to-do/<PLAN>`, your work folder (you create it) · `W/tasks/<id>` = the file prefix of a task: `<id>.brief.md`, `<id>.result.md`, `<id>.goal`…
- `run <tool> <args>` = `SHELL` bash: `bash .to-do/_tools/<tool>.sh <args>` · powershell: `powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .to-do/_tools/<tool>.ps1 <args>`. Always from the repository root. Never hand-write a harness command, and never name a harness-specific tool in a brief: describe the action.
- `ORCHESTRATOR` says **required** and you are not that model in that harness → stop; tell the user to relaunch the plan with it.

## 1. Dispatch

`run dispatch <harness> <model> <write|read> . <BRIEF> <RESULT> [timeout_s] [session]` — harness and model argument from plan §4.

It pipes the brief to the worker, applies the timeout (default 1800 s), runs writers with edit-only permissions and reviewers read-only, never adds a bypass flag, guarantees `<RESULT>` holds the final message, and prints `exit=<code>` (124 = timeout) · `session=<id>` · `result=<worker|captured|missing>`. `<RESULT>.events` (raw events) and `<RESULT>.stderr`: open only to diagnose a failure. `<RESULT>.status`: live state, written by the script.

- **Label every dispatch**: env `SP_TASK='<task id> <task type>'` (e.g. `P2.T1 backend`) names the worker on the status board.
- **Never block on a worker** — harnesses cut a foreground shell call long before 1800 s, and blocking makes parallel work impossible:
  - your harness has background shell commands with a completion notice → dispatch in the background, wait for the notice;
  - otherwise env `SP_DETACH=1`: the worker starts detached, the script prints `started=<status file>` and returns. Collect with `run status wait <max_s> <RESULT>…` → one line per worker (`state · exit · session · result`); exit 0 = all finished, 3 = still running → call again. Keep `max_s` under your shell tool's limit (300 is safe everywhere).
- **Status board — no model tokens**: `run status W [refresh_s]` lists task · model (harness) · state · elapsed · last activity (live for `claude`, `codex`, `opencode`, `agy`; `gemini`: state and time only). The user runs it in a second terminal; you run it only when the user asks where things stand — never to poll.
- **Say who works on what**: one line to the user per dispatch — `▶ <task id> <task type> → <model> via <harness>` — and one when it ends — `✔ <task id> PASS (<m:ss>)` · `✘ <task id> FAIL → fix round <n>` · `⏱ <task id> timeout`. Reviewers included (`▶ P2.T1 review → <reader model>`). Nothing else about a worker's run.
- **Follow-up = resume, not restart**: same command, the follow-up message file as `<BRIEF>`, `session` as last argument.
- **Claude workers** run only allow-listed tools: allow the verify command with env `SP_ALLOW='Bash(<verify command> *)'` on that dispatch.
- **Native subagent**: you run in the same harness as a routed worker and it has subagents with per-agent model selection → you may spawn a native subagent with that model instead. Same brief file, same result file.
- **Channel order**: subscription → direct API key → OpenRouter. Switch only on an auth / quota failure; journal the switch.
- **Other machine, or plan §4 verified more than 14 days ago**: before dispatching, `run preflight check <providers>` then `run preflight smoke-all 120 <harness>=<model> …` for the plan §4 rows; update plan §4 if a channel changed. Routing is a property of the machine, not of the plan.
- **Code graph** (`CODEGRAPH` not `off`): for caller chains and reachability only — everything else is cheaper with search and read. Queries: plan §4. Refresh the index after every commit. It misses dynamic calls: confirm any "who calls X" with one text search of the name. Non-default binary: env `SP_CODEGRAPH=<binary>` on every dispatch. Missing on this machine → stop and tell the user to install it; do not fall back to reading the tree.
- **After every worker**: confirm `HEAD` did not move and no file outside scope changed (`git status --short`). Revert strays.

## 2. Loop — per part, in dependency order

1. **Scout first**: dispatch the scout (plan §4, read-only) with the scout brief; it writes the part's **context pack**. You read only that pack — never explore the tree yourself.
   - One scout per part, not per task. Give it start pointers (paths and symbols from plan §2–§3 and earlier packs) so it never discovers the repo from zero. Skip the scout when earlier packs already cover the part's files — reuse their lines.
   - Check the pack: it names the files to change, gives at least 3 `path:line` facts, and contains no advice or plan. Otherwise re-dispatch once, to the scout's alternate.
2. **Major part** (plan §3): write the sub-plan `W/subplans/<NN>-<part>.md` (template below). It must be implementable **without the main plan**: copy into it the needed sentences of plan §1–§3 (objective, conventions, contracts, commands) and the context pack. Split the part into tasks; tag each with type, [lead]/[cont], file scope, criteria, verify. **Minor part**: no sub-plan — it is one task; copy those same sentences into its brief. A minor part that turns out to need several tasks becomes major.
3. **Tests first** (parts marked so in plan §3): **you design the tests, the test-writer only codes them.** You hold the spec, so you decide what must be tested for the part to be valid: write the **test list** in plain text — one bullet per test, in the sub-plan (minor part: in the tests brief) — covering per criterion the normal case and the edge and failure cases that matter. Dispatch the **test-writer** (plan §4) with the tests brief. It adds, drops and redesigns nothing, and never sees an implementation, so the tests carry no implementer bias. Then run the tests yourself: they must **fail because the feature is missing**, not on a syntax, import or setup error; otherwise send it back (max 2 rounds, then ask the user). From then on the test files are **frozen**: out of scope for every implementer, and part of the part's verify command.
4. Per task: write the brief, `<id>.goal` and `<id>.criteria` (§3) → dispatch the routed worker → read only its result file → review (§3) → FAIL: send the review file to the same worker session (max 2 fix rounds, then re-dispatch to the lead model; third failure: stop, journal, ask the user). A worker that thinks a frozen test is wrong reports `BLOCKED` with the reason; you decide, and only the test-writer session may change the test.
5. Complex parts: [lead] tasks first. The lead's result must include a **HANDOFF** note (what exists, patterns established, files to imitate, remaining work); paste it into the [cont] briefs. **[critical] pieces are [lead] work, never [cont]** — a [cont] task that turns out to touch dangerous code is stopped and that piece re-dispatched to the lead.
6. Part passes when all its tasks passed review and the part's verify command passes → commit (§4) → journal → progress line (§5).
7. **Final review** — when every part is committed: run the plan §1 commands (full suite, lint, typecheck), then put the **whole feature** through §3 like a task: goal = plan §1 goal, criteria = the plan §1 overall criteria (G1…), diff = env `SP_DIFF_BASE=<base>` (`git diff <base>...HEAD`), sliced, verify = those commands. It looks for what per-task reviews cannot see: parts not wired together, contract mismatches, a broken end-to-end flow. FAIL → each failed criterion becomes a fix task (brief → worker → review → commit), then the final review again (max 2 rounds, then ask the user).
8. Done only when the final review returns PASS on every overall criterion. Then the final summary.

**Token discipline**
- Never load worker transcripts, full diffs or whole files you do not need. Read result files (≤15 lines) and `git diff --stat`.
- Briefs of a major part reference the sub-plan by path; they do not repeat it. Workers never read the main plan or this file.
- Pick the cheapest routed model that fits the task; expensive models only for [lead] work.

**Parallelism**: tasks run in parallel only if plan §3 marks them parallel-safe and their file scopes are disjoint with no shared contract, migration, lockfile or generated file. Otherwise sequential. Review each task separately. Parallel = several dispatches started without waiting (§1), then collected.

**Sub-plan template**
```markdown
# <NN> <Part> — sub-plan (self-contained)
Objective · Scope in/out · Conventions & commands (copied) · Contracts (copied, exact)
## Tasks
| ID | Task (goal, not method) | Type | [lead]/[cont] | Files | Success criteria | Verify |
## Test list (written by the orchestrator, coded as-is by the test-writer)
- T1 [c1] <name> — given <state / input> · when <action through the public contract> · then <exact expected result>
- T2 [c1] <edge or failure case> — given … · when … · then …
## Part success criteria
```

**Task brief** — `W/tasks/<task-id>.brief.md`
```markdown
Role: implementation worker. Do exactly this task; do not expand scope.
Read first: <sub-plan path> (section <task-id>). <HANDOFF note if any>
<Minor part, no sub-plan — replace the line above with: Context: <conventions, commands and contracts copied from plan §1–§3>>
Goal: <what must be true>
Files in scope: <paths>. Touch nothing else.
Done when: <criteria>; `<verify command>` passes.
Rules: follow the conventions given above. No git write commands (no add/commit/push/branch). No new dependencies unless listed. Infer intent and act; do not ask questions.
Report: write ≤15 lines to <RESULT path>: STATUS (DONE|BLOCKED) · files changed · verify output tail · decisions worth knowing · HANDOFF (lead only). Your final message must be that same report.
```

**Scout brief** — `W/tasks/<part-id>.scout.brief.md`
```markdown
Role: scout. Read-only. You change no file.
Part: <objective, scope and contracts — copied from plan §3>
Start here: <paths and symbols already known, from plan §2–§3 and earlier context packs>
How to scout (token budget matters — every step re-sends everything you already read):
- Search before you read: narrow patterns, matching lines only. Never list the tree.
- Read line ranges around the hits (at most 80 lines per read). Never read a whole file over 150 lines.
- Send independent searches and reads together in one step.
- At most 10 tool calls. Stop as soon as the report can be written. A fact you cannot find in budget: write "not found", do not keep digging.
- Do not re-check what is stated above.
<CODEGRAPH not off: - Caller chains and reachability: use these code graph commands: <queries of plan §4>, then confirm with one text search of the name.>
Report: write ≤40 lines to <RESULT path> — the context pack: files and symbols to change (path:symbol:line) · who calls them · existing code to imitate (path:symbol, one line why) · contracts and types already defined that the part must respect · test files, fixtures and helpers available · traps (generated files, side effects, shared state). Facts with paths only; no advice, no plan. Your final message must be that report.
```

**Tests brief** — `W/tasks/<part-id>.tests.brief.md`
```markdown
Role: test writer. You code exactly the tests listed below — nothing more, nothing less. No feature code, no stubs of the feature.
Context: <everything needed to write them without guessing, copied from plan §2–§3 and the context pack: test framework and version · where tests live and how they are named · an existing test file to imitate · fixtures, factories, mocks and helpers available · how to set up and tear down state (db, server, auth) · the contracts under test, exact (routes, signatures, schemas, events, UI selectors or roles) · single-test command>
Tests to write (one test per bullet; name each test `<Tn> <criterion id> <name>`):
- T1 [c1] <name> — given <state / input> · when <action through the public contract> · then <exact expected result>
- T2 [c1] <…>
Test through the contract given above, not internals — the implementation does not exist yet and you must not guess its structure.
A test you cannot write as specified: do not adapt it — report it under BLOCKED with the reason.
Files in scope: <test paths>. Touch nothing else.
Done when: every listed test exists, runs, and fails only because the feature is missing (no syntax, import or setup error).
Rules: no git write commands. No new dependencies unless listed. Infer intent and act; do not ask questions.
Report: write ≤15 lines to <RESULT path>: STATUS · test files · Tn → test name · BLOCKED tests with reason · run output tail.
```

## 3. Review

Every finished task is reviewed independently before it counts. One question: **is the feature fully functional against the task's success criteria?** Not style. The author never reviews, and never writes the criteria. Every review = deterministic checks → **gate (Jev) + reader (cheap model), both, always** → arbiter only when needed. Jev is calibrated and nearly free but blind outside the diff and mute; the reader explains and can look around but is less reliable alone.

**With the brief, you write** (prefix `W/tasks/<id>`):
- `<id>.goal` — the task goal, plain text. Yours only: no worker-written text.
- `<id>.criteria` — one line per criterion: `<criterion id>: <full text>`, in **English** whatever the plan's language (where Jev is most accurate). Jev reads literally — the words, not the intent — and each line alone: one observable behaviour, positive wording, no "and / or", no double negative. A multi-step criterion is split into literal sub-claims (`c1a`, `c1b`).

**Steps** (you run them; the scripts do the arithmetic):
1. **Deterministic first**: `run review prep W/tasks/<id> '<verify command>' <task paths…>` runs the verify command (frozen tests, lint, typecheck; `none` if the task has none; powershell flavour: no unquoted `)` in it), then builds the scoped diff `<id>.diff` (new files included; it also clears the previous round's review files). `verify=fail` → **FAIL** with the tail `<id>.verify`; stop — no model judges what a tool already answered. Exit 5 (empty diff), or a worker `result=missing` → **FAIL** "no change"; no reviewer is paid.
2. **Reader and gate, in parallel** (both read-only; the reader never sees Jev's numbers, so they cannot bias it): dispatch the **reader** with the reader brief · `run review gate W/tasks/<id> <rubric>` (skip when `GATE` = `off`). `<rubric>` = the task's types among `backend`, `frontend`, `critical` (comma list; `none` if none applies).
3. **Combine**: `run review verdict W/tasks/<id> <reader RESULT>` prints `review=PASS|FAIL|ESCALATE` and writes `<id>.review.md` (≤12 lines):

| Reader | Gate (Jev) | Result |
|---|---|---|
| PASS | passes | **PASS** |
| FAIL | fails | **FAIL** — reader's defect lines + Jev's `<id>: <gap>` findings |
| FAIL with a file:line defect | passes / uncertain | **FAIL** — a concrete defect wins over a probability |
| PASS | fails | **ESCALATE** — disagreement, disputed question IDs listed |
| any other | uncertain, or reader ESCALATE | **ESCALATE** |

- **FAIL** → send the review file to the author's session as the fix message (§2). It already says what and where: criterion ID, gap label, file:line.
- **ESCALATE** → dispatch the **arbiter** with the reader's context plus both verdicts and only the disputed IDs. It answers in the reader's format. Its verdict is final: on FAIL its result file is the fix message.
- **[critical] tasks and the final review**: a PASS also goes to the arbiter — PASS only if reader, gate and arbiter all pass. Never pay the arbiter for a review that already failed.
- `GATE` = `off`: the reader's verdict alone decides; [critical] and the final review still go to the arbiter.
- **Large diff** (`gate=too-large`, exit 3 — limit ≈ 80k characters of state, ≈ 60k for the diff): slice the **gate** by file group (source with its tests), excluding lockfiles, generated and binary files — per slice `review prep` + `review gate` with its own prefix (`<id>.s1`…), its own `.goal` and only the criteria whose files it holds (a slice cannot show what another slice implements); the rubric goes to every slice. Then `run review merge W/tasks/<id> <slice prefix>…` — combined by meaning, never by average: `.done` = the best slice · "every …" rubric lines = the worst slice · expected-false lines = the highest slice. One reader for the whole task (it reads the slice diffs by line ranges), then `review verdict W/tasks/<id>` as usual.
- `gate=no-key` (exit 4) or `gate=error` (exit 1): retry once; still failing → review this task with the reader **and** the arbiter, and journal it.

**Reader brief** — `W/tasks/<id>.reader.brief.md`. Reader = plan §4 row, cheap, read-only, never the author's model. It gets no plan, no history, no worker reasoning.
```markdown
Role: reviewer. Read-only. Judge one thing: is the feature fully functional against the criteria? Functional gaps only — not style, naming or preferences.
Goal: <task goal>
Criteria: <id: text, one per line>
Evidence: diff `<id>.diff` <sliced: every `<id>.sN.diff`> · verify output `<id>.verify`. Search the code (narrow patterns, line ranges<CODEGRAPH not off: ; code graph commands: …>) for what the diff does not show: callers of a changed function, whether the new code is reachable, a contract defined in another file.
<backend: also judge `r.contract` — the diff matches the contract given in the goal exactly (names, types, status codes).>
<[critical]: also judge `r.reversible` — the migration can be rolled back without data loss.>
Answer in exactly this form, as your final message and in <RESULT path>:
VERDICT: PASS | FAIL | ESCALATE
<criterion-id>: met | unmet — <≤12 words>
DEFECTS: <none | one line each: file:line — what is wrong — what is expected>
No defect without a file:line. ESCALATE only when the evidence is insufficient to judge.
```
**Arbiter** = plan §4 row: strong model, read-only, from a provider other than the author's.

**Gate rules (Jev)** — typed questions about the evidence, answered with calibrated probabilities. Made for common-sense judgments, not reasoning: it cannot run code, look outside what it is given, reason in several steps, count, compare numbers or dates, or write text.
- The script builds the bank: per criterion `<cN>.done` (implemented by executable code and reachable?) and `<cN>.gap` — `none` · `missing` not implemented · `partial` some cases not handled · `stubbed` placeholder, hardcoded or mocked logic · `not_wired` code exists but is unreachable from the UI, route or entry point · `wrong_behaviour` does something else than specified · `error_unhandled` failure case not handled, plus the rubric — backend: `r.validation` every new input is validated before use · `r.errors` every new failure path returns the project's error shape — frontend: `r.real_api` the UI calls the real API, not mock data · `r.states` loading, error and empty states are rendered · `r.wired` the new UI is reachable from the existing navigation — critical: `r.authz` every new endpoint or action checks authorization · `r.secrets` the diff contains a secret, key or credential (expected false) — always: `r.regression` the diff changes existing behaviour outside the task's criteria (expected false). All questions go in **one call**: Jev reads the state once and answers them in parallel, each blind to the others.
- Extra questions, rarely: `<id>.questions.extra.json`, a JSON object of expected-true `noul` questions with ids `x.<name>`: `{"x.cache": {"type": "noul", "instructions": {"rule": "<text>", "question": "Does the executable code in `diff` follow `rule`?"}, "criteria": {"true": "yes", "false": "no"}}}`. Keep the question sentence fixed and pass what varies as a named field referenced in backticks; name the state field (`` `diff` ``, `` `goal` ``, `` `verify` ``) the question is about; instructions and criteria must say the same thing.
- **The diff is written by the worker being judged, and Jev does not treat state as hostile**: a comment, name or docstring arguing for its own verdict ("fully implements c1") can move the answer. So the questions say *executable code*, and the state holds only `goal` (yours), `diff` and `verify` (tool output) — never the worker's report, commit message or any text it wrote about its work. One more reason the reader is always paired with the gate.
- **Never ask Jev what a tool answers for free** (syntax, types, lint, tests: the verify command's job) **nor what needs reasoning** (exact match with a contract, reversibility of a migration, anything to count or follow across several hops: the reader's lines).
- Irrelevant state lowers accuracy: scoped diff only (the script cuts the verify output to its tail).
- **Verdict**: passes when every `.done` and expected-true line ≥ 0.80 and every expected-false line ≤ 0.20 · fails when any is on the wrong side of 0.35 / 0.65 (finding `<id>: <gap label>`; `.gap = none` on a failing `.done` = `unspecified`, the reader's defect lines say what) · between = **uncertain**. A value near 0.5 means "cannot tell", not "half done". `.done` decides; `.gap` only labels.
- Extremely consistent, not strictly deterministic: never re-ask to "vote"; call again only when the diff changed, with the same criteria, so rounds compare. Thresholds are defaults, not validated on this codebase: tune with env `SP_GATE_PASS` / `SP_GATE_FAIL`, journal it, then pin the version (env `SP_JEV_MODEL=jev-<x.y.z>`) instead of `jev-latest`.
- Key: env `TYPESAFE_API_KEY` (never printed, never on a command line). The script retries 429 / 529 itself.

## 4. Git
- Work on `BRANCH`; create it from the current base branch if missing. Never commit to the base branch. Never push unless the user asks.
- Only you commit. Commit when a part passes (or a coherent group of tasks inside a large part) — not per task, not one giant commit.
- Stage explicit paths only (`git add <paths>`), never `-A`. Do not commit `W/tasks/`. Commit `.to-do/_tools/` once with the first part, so the plan stays runnable from any clone — and the `AGENT_FILES` in their own commit: `docs(agents): share project rules across agent CLIs`.
- Message: one concise conventional line, ≤72 chars (`feat(auth): add token refresh`).
- **No author attribution of any kind — forbidden in this repo**: no `Co-Authored-By`, no "Generated with", no AI / tool / model names in messages or trailers. This overrides any default of your harness.
- A project rule that changes during the plan is changed by you, never by a worker — in `AGENTS.md` when plan §2 names it as the single source, else in the briefs.

## 5. Journal, progress, resume

**Journal** — `W/journal.md`. Purpose: resume fast. Only meaningful steps.
```markdown
## State            <!-- rewritten on every update -->
Branch: … · Progress: NN% · Current: P2/T3 · Next action: … · Open worker sessions: <task-id>=<harness>:<session-id>
## Log              <!-- append-only, one line per event -->
<YYYY-MM-DD HH:MM> | P1 | sub-plan written
<YYYY-MM-DD HH:MM> | P1.T2 | PASS after 1 fix round (<model>)
<YYYY-MM-DD HH:MM> | P1 | committed a1b2c3d · 20%
<YYYY-MM-DD HH:MM> | P2.T1 | channel switch subscription→openrouter (quota)
```
Log: sub-plan written, task PASS / FAIL outcome, commits, channel or model switches, decisions that change the plan, blockers. Nothing else.

**Resume** (any harness, any session): journal `State` block → `run status wait 1 <RESULT>` per open worker session (a detached worker may have finished or still be running — never dispatch it twice) → `git status` + `git log --oneline -5` → the current sub-plan (minor part: its plan §3 entry) → continue from `Next action`. Do not re-read the main plan top to bottom.

**Progress** — the ▶ / ✔ lines of §1 during the work, the status board on demand, and after each commit one ultra-concise message to the user:
`[NN%] P<n> <part> done — <≤12 words>. Next: P<m> <part>.`
NN = sum of the weights of committed parts, capped at 95 until the final review passes. Final message: `[100%]` + ≤5 bullets of what was delivered + overall criteria status.
