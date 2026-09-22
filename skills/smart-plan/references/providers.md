# Providers — what goes into plan §4

Per provider: the model-argument form for the routing table, and the prompting rules and worker caveats to copy into **Prompting notes** — routed workers only. Workers are always run by `scripts/dispatch.(sh|ps1)`; how the scripts drive each harness, sources, prices and measurements: `harness-internals.md` (not needed to write a plan). A harness that cannot edit headlessly under the user's settings: route that model through another channel and say so — never a bypass flag.

## Anthropic — `claude`
- **Model argument**: alias `fable` | `opus` | `sonnet` | `haiku`, or a full ID.
- **Prompting**: a worker starts with zero history — name files, interfaces and criteria in the brief. Ask for a compact return ("return only what's needed"). Reviewers: "report gaps against the criteria, not style"; a reviewer asked to find problems always finds some.
- **Caveat**: headless Claude runs only allow-listed tools — the verify command must be allowed per dispatch (`SP_ALLOW`, protocol §1).

## OpenAI — `codex`
- **Model argument**: the slug listed by `preflight models codex` (e.g. `gpt-6-astra`).
- **Prompting (GPT-6 Astra / GPT-5.6)**: state done-criteria explicitly, including "run it and fix what fails" if wanted. Do **not** ask for a plan, preamble or status updates — it can stop the run early. Add "infer intent, bias to action, do not ask questions" (a question in headless mode is a wasted run). Do not micro-prescribe testing steps; use pointers ("see `architecture.md` for boundaries") rather than a blanket "read X first". Avoid conflicts between brief and `AGENTS.md`; state that the brief wins. Ask for a concise final summary with file paths.
- **Caveat**: on Windows the native sandbox needs a one-time elevated setup before a write task works.

## Google — `agy` (Antigravity CLI) or `gemini` (Gemini CLI)
Since 2026-06-18 consumer Google AI plans (Pro / Ultra / free) work only with `agy`; `gemini` needs a paid `GEMINI_API_KEY`, Vertex AI, or a Code Assist Standard / Enterprise licence. Use whichever is installed **and** authenticated; if both, the subscription channel.
- **Model argument**: resolve live. `agy`: a slug from `preflight models agy`, or `auto`. `gemini`: aliases `pro` | `flash` | `auto` are safer than hard-coded IDs. Hints (2026-09-17): `gemini-3.8-flash` (stable, agentic coding), `gemini-3.1-pro-preview`.
- **Prompting (Gemini 3.x)**: direct, concise instructions; drop verbose chain-of-thought scaffolding. Context first, the instruction **last**. One delimiter style (Markdown headings or XML-style tags, not both). Do not lower temperature (can cause loops). Terse by default — ask explicitly for a detailed output. Never "think step by step"; reasoning is set by the thinking level.
- **Caveats (`agy`)**: any auto-denied action empties the final response (`result=missing`, exit 0) — tell agy workers in the brief not to run shell commands they do not need. Headless shell commands need an allow-rule in the user's `agy` settings, so the worker can edit but may be unable to run the verify command: the review runs it (protocol §3). Same verify caveat for `gemini` (`auto_edit` approves edits only).

## opencode bridge — DeepSeek, GLM, Qwen, OpenRouter, any other provider
- **Model argument**: OpenRouter `openrouter/<author>/<slug>` · DeepSeek direct `deepseek/<id>` · GLM Coding Plan `zai-coding-plan/<id>` · Z.ai pay-as-you-go `zai/<id>` · Alibaba direct `alibaba/<id>` (`DASHSCOPE_API_KEY`, international; `alibaba-cn/` for the China region) · Alibaba Token Plan `alibaba-token-plan/<id>`. The exact ID must appear in `preflight models opencode <regex>`.
  Hints (2026-09-20, verified): `openrouter/deepseek/deepseek-v4.1-flash`, `openrouter/z-ai/glm-5.3`, `openrouter/qwen/qwen3.8-flash`, `openrouter/qwen/qwen3.8-max-0902` (qwen flash gave 1 empty smoke reply in 4 — retry a smoke once before declaring it missing). Direct-key hints (2026-09-21, from models.dev, not executed): `deepseek/deepseek-flash`, `zai/glm-5.3`, `alibaba/qwen3.8-flash`, `alibaba/qwen3.8-max`.
- **Prompting (DeepSeek, GLM, Qwen and other cost-efficient models)**: smaller, tightly bounded tasks. List the exact files. Point to the lead's code as the pattern to imitate. Literal instructions and "do not expand scope". Thinking is always on — never "think step by step". Prefer resuming the session over restating context (GLM keeps its reasoning across turns; DeepSeek cache hits are ~50× cheaper than misses, so keep a stable brief prefix). On OpenRouter host quality varies (third-party hosts may be quantized): if tool calls misbehave, switch host or channel before blaming the brief.
- **Caveat**: write mode approves everything not explicitly denied — the project should keep deny rules in `opencode.json`: `{"permission":{"bash":{"*":"allow","git push*":"deny","git commit*":"deny","rm -rf*":"deny"}}}`. Absent → list it under Open questions.

## TypeSafe — Jev (review gate)
No harness: called by `scripts/review.(sh|ps1)` through `scripts/jev.(sh|ps1)`. Plan variable `GATE` = the routed model (`jev-latest`, or a pinned version) followed by the versioned ID seen at the preflight smoke (e.g. `jev-latest (jev-1.13.0)`), or `off`. Its rules live in `protocol.md` §3.

## Free models are not used
Decision 2026-09-21 (tested: unreliable, rate-limited, may log or train on the code). Never route a `:free` model.
