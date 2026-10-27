# API reference

**One port (default `8731`) serves everything the Flash model does; the NPU
sidecar adds its own routes beside them.** All bodies are JSON. Errors come
back OpenAI-style as `{"error": {"message": ..., "type": ...}}` with a real
HTTP status, and a refusal always says why rather than guessing what you
meant. `/health` is the authoritative account of what the build you are
running supports; read it before writing against a feature.

## Conventions

| | |
|---|---|
| model id | `halogen-qwen3.8-flash-next` (`HALOGEN_MODEL_ID`); `/v1/models` lists it |
| authentication | off by default; with `HALOGEN_API_KEY` set, send `Authorization: Bearer <key>` (OpenAI SDKs, Codex, curl) or `x-api-key: <key>` (Anthropic SDK, Claude Code). `/health` stays open; every other route answers 401 without a key. [Details](configuration.md#api-key-require-one-on-the-api-port-opt-in) |
| streaming | `"stream": true` on any generation route, standard SSE frames; a stream that goes quiet gets a keepalive, not a hang-up |
| token budget | `max_completion_tokens`, `max_output_tokens` and `max_tokens` are one field with three names; two different values is a 400. [Token budgets](token-budgets.md) |
| timings | every response carries a `timings` object in llama-server's shape (`prompt_n`, `predicted_n`, `cache_n`, `draft_n`, `draft_n_accepted`, rates); [codex.md](codex.md#observability) |
| determinism | at `temperature: 0` output is byte-identical to serial greedy decode, with or without the cache, alone or batched. [Quality](quality.md#quality-what-is-measured-and-what-is-not) |

## Generation routes

### `POST /v1/chat/completions`

The main route. `messages` (with `system`, `developer`, `user`, `assistant`,
`tool` roles), optional `tools` (function calling; arguments stream),
`response_format` for structured output, `logprobs`/`top_logprobs` at
`max_tokens: 1` for scoring, `continue_final_message` and
`add_generation_prompt` (the [classifier](classifier.md) pattern), images as
content parts when the vision tower is on ([Images](images.md)), and the
thinking controls ([Token budgets](token-budgets.md)). The response is the
standard shape: `choices[].message` (with `tool_calls` and `reasoning_content`
where they apply), `usage` including reasoning-token detail, and `timings`.
A non-streaming request whose client hangs up is cancelled and logged as 499.

### `POST /v1/completions`

Raw `prompt`, same budget/sampling/progress fields. `"return_progress":
true` on a streamed request adds `prompt_progress` frames while the prompt
is read ([Prompt progress](codex.md#prompt-progress)). It has no chat
template: what you send is what the model sees, markers included.

### `POST /v1/responses`

The OpenAI Responses API: input items, `function_call` /
`function_call_output` round trip, `reasoning` items, `text.format`
schemas, `instructions`. Codex CLI drives this route. **There is no
response store**: send the history each turn; a `previous_response_id`
without history is refused with a 400. [Codex and the Responses API](codex.md).

### `POST /v1/messages` and `POST /v1/messages/count_tokens`

The Anthropic Messages API: `system` blocks, `content` blocks, `tools` and
`tool_use` / `tool_result`, streaming events, `thinking`, and the
`anthropic-version` header. Claude Code drives this route.
[Claude Code and the Anthropic Messages API](claude-code.md).

## Server state routes

| route | what it is |
|---|---|
| `GET /health` | the build's own account: version (front end and engine), `supported` fields, `structured_output`, `token_budget_aliases` and `max_tokens_default`, `thinking_answer_room`, `indexer_budget`, `chat_template` (path, sha256, check), `request_records`, `composable_context`, `stop_ids` (every token id that ends a reply), `queued` and `longest_wait_s` (how long the oldest queued request has waited, 0 when none). Always open, even with an API key set |
| `GET /v1/models` | the one model id this server serves, with `architecture.input_modalities` (`["text", "image"]` with the vision tower loaded, `["text"]` without) and `output_modalities` (`["text"]`) |
| `GET /cache` | the prompt cache's full report: `hit_rate` and `token_hit_rate`, and under `pool`: `positions`, `used`, `usage_ratio`, `busy_regions`, `held_regions`, `room_clamped`, `moved`, `dropped`, `waiting_for_room`, `waiting_s`, `relocated`, `cold_resorts`; `stale_s` when the engine is mid-prefill |
| `GET /metrics` | Prometheus format, llama-server's names plus `halogen:` counters; a scrape never stalls on a busy engine. [The metric table](codex.md#observability) |
| `GET /props` | llama.cpp's shape: `total_slots`, `default_generation_settings.n_ctx` and `.params.n_predict`, `chat_template`, `modalities.vision`, `build_info` |
| `GET /slots` | one `{id, n_ctx}` per slot |
| `POST /tokenize` | `{content, add_special, parse_special, with_pieces}` to `{tokens}`, as llama.cpp's |
| `POST /detokenize` | `{tokens}` to `{content}` |
| `GET /halogen/handles`, `DELETE /halogen/handles/{name}` | list and release session keep-names. [Sessions](sessions.md) |

## NPU sidecar routes

When the NPU container runs, small models answer beside the Flash model:
`POST /v1/embeddings`, `/v1/rerank`, `/v1/moderations`, `/v1/systemone`
(decisions), `/v1/images/generations`, `/v1/audio/transcriptions`,
`/v1/audio/speech`, and
`/v1/chat/completions` for the small generative models; `GET /health` and
`/v1/models` report them. Each route only accepts the model kinds built
for it, and a wrong pairing is refused with a message naming the right
route. [Small models on the NPU](npu-small-models.md) and the
[host details](NPU.md).

## Status codes you can rely on

| code | when |
|---|---|
| 400 | a budget above the cap; two budget fields with different values; a schema keyword the mask refuses (the message names it); `logprobs` shapes not implemented; a `previous_response_id` with no history; an image with no vision tower; a prompt at exactly the context |
| 401 | a key is required and this request did not carry one |
| 404 | an unknown route or handle |
| 499 | a non-streaming request whose client hung up; the work was cancelled, not lost |
| 500 | the server's own failure; the message says what, and `/health` still answers |

---

*This page is the map; the linked pages carry the detail, the examples, and
the conditions. If a field here and the running server disagree, the server
is right and `/health` is the arbiter. A report to
[issues](https://github.com/peonist-ai/halogen-flash-server/issues) would be
welcome.*
