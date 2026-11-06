# From an agent harness

Every coding-agent harness we read (Pi, opencode, Codex CLI, hermes-agent,
Cline, Roo Code, aider, oh-my-pi) follows the same sensible rule against an
OpenAI-compatible server it was not written for: send nothing the server
was not declared to accept. So none of them sends a thinking control unless
you configure one, and most cannot express "thinking off" at all against a
custom endpoint. Two consequences: **the server's defaults are what your
harness runs at**, and a compaction (which six of the seven build as a new
conversation, a cold prefill of the whole history under the harness's own
output cap) runs at the model's `xhigh` effort. The [answer
room](token-budgets.md#token-budgets-and-why-an-empty-answer-means-you-ran-out) keeps that
from failing; these are the switches if you want it faster:

| harness | what it sends for thinking on a custom endpoint | to set effort or turn thinking off |
|---|---|---|
| **Pi** | `reasoning_effort` only with `"reasoning": true` in the model entry and a level other than off; nothing when off | `"reasoning": true, "thinkingLevelMap": {"off": "none"}` in the entry; a budget through `compat.thinkingTokenBudgetField: "thinking_budget"` (any of its three names works here) |
| **oh-my-pi** | as Pi: nothing when off | its own effort-map keys on the model entry, or the server variables |
| **opencode** | `reasoning_effort` low/medium/high when a variant is picked; no off variant for a custom provider | pick a variant, or `HALOGEN_REASONING_EFFORT` / `HALOGEN_ENABLE_THINKING=0` on the server |
| **Codex CLI** | `reasoning.effort` on `/v1/responses` only when `model_reasoning_effort` is set | `model_reasoning_effort = "medium"` in `config.toml` |
| **hermes-agent** | `reasoning_effort` when a level is set (`--reasoning`, `/reasoning`, `agent.reasoning_effort`), and it wins over the server's default. With no level, an install from 2026-11-05 sent nothing on the main turn, and Hermes' current source fills in `medium` unless its catalog marks the model non-reasoning. Its title generator sends `none` either way | `/reasoning <level>`, or the server variables when no level is sent; for the compaction summary, `extra_body: {enable_thinking: false}` under its auxiliary settings |
| **Cline** | `reasoning_effort` when set; "off" sends nothing outside its portable-provider list | set an effort, or the server variables |
| **Roo Code** | `reasoning_effort` (`none`..`high`) when the model info advertises reasoning effort; `disable` sends nothing | enable reasoning effort on the model and pick a level |
| **aider** | `--reasoning-effort` as `reasoning_effort`; `--thinking-tokens N` as `thinking: {budget_tokens}` | either flag; both are read here |

**Point the harness at this server as a provider, not as its own server.**
OpenCode has both: a provider entry in `opencode.json` (`"npm":
"@ai-sdk/openai-compatible"`, `"options": {"baseURL": "http://HOST:8731/v1"}`,
a model under `"models"`) is the one that reaches this server; `opencode
attach URL` and the `OPENCODE_SERVER` setting expect an OpenCode server and
probe `/global/health` and `/api/health`, which this server does not have
and should not answer (issue #91). hermes-agent's `/api/tags`, `/props` and
`/version` probes are its backend detection; the 404s are harmless and it
proceeds on `/v1/models`.

The server variables are `HALOGEN_REASONING_EFFORT` (the effort a request
gets when it names none; the card's advice is to leave it at `xhigh` for
agentic work), `HALOGEN_ENABLE_THINKING=0` (thinking off unless a request
turns it on) and `HALOGEN_MAX_THINKING_TOKENS` (a budget for requests that
send none). A request that names any of these wins over the variable.

**What the log says during a long turn, since 0.11.0.** The container log
prints `flash_serve: req N prefill P/T tokens, S s` at every 32,768-token
chunk of a long prompt and every 20 s inside one, and `req N generated K
tokens, S s` every 30 s of a long answer, so a 160k-token compaction that
takes minutes is visible while it runs rather than only in the `serve_api:`
line at its end. `/health` reports `busy_for_s` while a request is in
flight.
