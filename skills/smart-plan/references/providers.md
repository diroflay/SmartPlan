# Providers — what goes into plan §4

Per provider: the model-argument form for the routing table, and the prompting rules and worker caveats to copy into **Prompting notes** — routed workers only.

Name models by family or tier (`opus`, `sonnet`, `astra`, `luna`); version rule: `routing.md` § Roles. Never route a `:free` model.

## Anthropic — `claude`
- **Model argument**: alias `fable` | `opus` | `sonnet` | `haiku` — each alias already points to the latest model of its tier on the Anthropic API and Claude plans (on Bedrock, Vertex and Foundry the aliases lag behind: check `preflight models claude`). No full versioned ID.
- **Prompting**: a worker starts with zero history — name files, interfaces and criteria in the brief. Ask for a compact return ("return only what's needed"). Reviewers: "report gaps against the criteria, not style"; a reviewer asked to find problems always finds some.
- **Caveat**: headless Claude runs only allow-listed tools — the verify command must be allowed per dispatch (`SP_ALLOW`, protocol §1).

## OpenAI — `codex`
- **Model argument**: the slug listed by `preflight models codex` for the routed tier (`astra latest` → the newest `gpt-*-astra`).
- **Prompting (GPT Astra / Sol / Luna)**: state done-criteria explicitly, including "run it and fix what fails" if wanted. Do **not** ask for a plan, preamble or status updates — it can stop the run early. Add "infer intent, bias to action, do not ask questions" (a question in headless mode is a wasted run). Do not micro-prescribe testing steps; use pointers ("see `architecture.md` for boundaries") rather than a blanket "read X first". Avoid conflicts between brief and `AGENTS.md`; state that the brief wins. Ask for a concise final summary with file paths.
- **Caveat**: on Windows the native sandbox needs a one-time elevated setup before a write task works.

## OpenRouter channel — `opencode` (optional)
Only when the chosen provider's subscription and key both fail, or `REQUIRE_OPENROUTER: on`. Same model, other door: the prompting rules of its provider above still apply.
- **Model argument**: `openrouter/anthropic/<slug>` or `openrouter/openai/<slug>`; the exact ID must appear in `preflight models opencode <regex>`.
- **Caveat**: write mode approves everything not explicitly denied — the project should keep deny rules in `opencode.json`: `{"permission":{"bash":{"*":"allow","git push*":"deny","git commit*":"deny","rm -rf*":"deny"}}}`. Absent → list it under Open questions.

## TypeSafe — Jev (review gate)
No harness: called by `scripts/review.(sh|ps1)` through `scripts/jev.(sh|ps1)`. Plan variable `GATE` = `jev-latest` followed by the versioned ID seen at the preflight smoke (e.g. `jev-latest (jev-1.13.0)`), or `off`. Its rules live in `protocol.md` §3.
