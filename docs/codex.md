# Codex and the Responses API

The server speaks the **OpenAI Responses API** at `POST /v1/responses`. The
OpenAI Codex CLI is the reason it exists: point it at this server and it
works, including tool calls.

```toml
# ~/.codex/config.toml
model = "halogen-qwen3.8-flash-next"
model_provider = "halogen"

[model_providers.halogen]
name = "halogen"
base_url = "http://<your-server>:8731/v1"
wire_api = "responses"
requires_openai_auth = false
```

## What round-trips

Streaming and non-streaming both work. `function_call` and
`function_call_output` items round trip. `tools` entries that are not
functions (`web_search`, and the `namespace` wrapper, whose nested
functions are used) are ignored rather than rejected. `instructions` and
any `developer` turns are folded into the system prompt. A
`function_call_output` whose output is a content array with an
`input_image` passes the image to the model; that needs the vision tower,
and without it the request is refused with a 400.

> [!IMPORTANT]
> **There is no response store.** `previous_response_id`, retrieving a
> response by id, and cancelling one are not available; send the history
> with each request, which is what Codex does. A request that sends
> `previous_response_id` and no earlier turn is refused with a 400, so a
> client that expects a store finds out at once instead of getting an
> answer without its context.

## Reasoning

The model's thinking goes out as a `reasoning` output item ahead of the
message: its text as a `reasoning_text` content part streamed in
`response.reasoning_text.delta` events, and
`usage.output_tokens_details.reasoning_tokens` says how much of the output
it was (both routes carry that count). When the request asks for a reasoning
summary, as Codex does (`reasoning: {"summary": "auto"}`), the same text is
sent again as the item's `summary_text`, with the
`response.reasoning_summary_*` events: there is no separate summarizer, the
summary is the reasoning. Codex renders summaries by default and shows raw
reasoning content only with `show_raw_agent_reasoning = true` in its config,
so with that setting on you will see the text twice. No `encrypted_content`
is sent, and a `reasoning` item echoed back in a later turn is dropped.

## Structured output

`response_format: {"type": "json_schema", "json_schema": {"name": ...,
"schema": {...}}}` and `{"type": "json_object"}` on
`/v1/chat/completions` and `/v1/completions`;
`text: {"format": {"type": "json_schema", "name": ..., "schema": {...}}}`
and `{"type": "json_object"}` on `/v1/responses` (the shape Codex sends;
its approvals reviewer sends one on every auto-reviewed tool call).

The engine enforces the schema while it decodes: every token is chosen from
the tokens the schema allows next, so the reply parses and validates **by
construction**, with no retry and no repair. It is decoding under a mask,
greedy or sampled, and nothing else changes: the same request without the
schema is bitwise what it was, and a greedy constrained request is
identical whether it decoded serially, with the draft head, with prompt
lookup, or beside other requests. It costs nothing measurable: the schema
is compiled once (a millisecond), every state's mask lives on the GPU, and
the decode loop reads a pointer. Since 0.18.1 a request with a schema may
also sample (temperature above 0): every token is drawn from the tokens the
schema allows, and a `seed` repeats the reply on the terms of *Sampling*
(alone, and both runs cold or both read from the prompt cache). A schema
with an image, or with `logprobs`, is a 400. `HALOGEN_GRAMMAR=0` turns the
feature off.

What the mask does with each keyword:

| status | keywords |
|---|---|
| enforced | `type` (object, array, string, number, integer, boolean, null, and unions like `["string", "null"]`), `properties` (keys emitted in schema order), `required` (an optional key may be skipped), `additionalProperties` (`false`, `true`, or a schema: extra keys only after the listed ones), `items`, `minItems`, `maxItems`, `minLength`, `maxLength`, `enum`, `const`, `anyOf` (`oneOf` is treated as `anyOf`; up to 32 alternatives that can be read at once, such as one object per tool in a "call one of N tools" schema; past that, a 400 with the count), `$ref` and `$defs` including recursive ones |
| accepted, not enforced | `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf`, and the annotation keywords |
| refused with a 400 naming the keyword | `pattern`, `format`, `allOf`, `not`, `if`/`then`/`else`, `patternProperties`, `dependentRequired`, `dependentSchemas`, `uniqueItems`, `contains`, `propertyNames`, `unevaluated*`, `minProperties`, `maxProperties`, `prefixItems` |

`/health` lists the feature under `structured_output`.

**Strict tools** (since 0.18.2; #147). A tool declared `strict: true` is held
to its schema the same way: `function.strict` on `/v1/chat/completions`,
`strict` on a `/v1/responses` tool and on a `/v1/messages` tool beside
`input_schema`. When any tool on a request is strict, a tool call names one of
the request's tools, and a strict tool's arguments match its parameter schema:
the enforced keywords above, every required parameter, and no parameter the
schema does not declare (`additionalProperties` absent counts as `false`, as
strict mode means). Parameters may come in any order. A tool without `strict`
is called as before, and a turn that makes no call is unchanged.
`parallel_tool_calls: false` (`disable_parallel_tool_use` on `/v1/messages`)
then allows one call. A call the model writes inside its reasoning block is not
held to a schema. A string argument cannot contain the line `</parameter>` (the
call format's own closing tag). `pattern` and `format` are accepted and not
enforced in a tool's schema. A strict tool whose schema uses a keyword refused
above, allows extra parameters at the top, or has more than 32 parameters, and
every strict tool on a request with images, `logprobs` or more than 128 tools,
is called as it would be without `strict`. The request's log line names it and
`/metrics` counts it (`halogen:strict_tools_unenforced_total`). `/health` lists
the rules under `structured_output.strict_tools`. `HALOGEN_STRICT_TOOLS=0`
accepts `strict` without enforcing it.

> [!NOTE]
> **Thinking and tools under a schema.** The reasoning block is not
> constrained: with thinking on the model thinks freely and the JSON starts
> after the block closes. A request with tools may open a tool call instead
> of the JSON (the schema binds the final text, not a call), which is how
> the Codex reviewer's own read-only tool checks keep working. Such a reply
> starts unconstrained: the model chooses between a call and the answer as
> it would with no schema. The schema holds from the JSON's first `{`; the
> text written before it is dropped, and a reply that would end first
> starts the JSON instead. That preamble may run to half of what
> `max_tokens` leaves after thinking, at most 1024 tokens; past that the
> JSON starts and a tool call is no longer offered. Since 0.18.2 a sampled
> request that would answer in plain text starts the JSON about as promptly
> as the greedy one does. This applies to schemas
> whose root is an object; `HALOGEN_SCHEMA_ESCAPE=off` binds the schema
> from the first token again. Whitespace between tokens is allowed, so a
> pretty-printed reply is fine, but at most two whitespace-only tokens in a
> row (a forbidden preference otherwise falls to a newline, and then
> another). Only the end-of-turn token is legal once the value is complete,
> so the reply is exactly the JSON.

## Observability

**Every response carries a `timings` object** in llama-server's shape
(`prompt_n`, `predicted_n`, `prompt_ms`, `predicted_ms`,
`prompt_per_second`, `predicted_per_second`, `cache_n`, `draft_n`,
`draft_n_accepted`), on the non-streamed body and on a stream's last
frames, so llama-swap's activity page shows prefill and decode rates and
the draft count. `draft_n` counts the draft head's proposals and the
prompt-lookup chains' together; the numbers are the engine's own
per-request line, copied.

**`GET /metrics` answers in Prometheus format** with llama-server's metric
names, so a dashboard built for llama.cpp (or llama-swap's upstream) reads
this server unchanged. Beside them sit halogen's own counters.

| metric | what it is |
|---|---|
| `llamacpp:prompt_tokens_total`, `llamacpp:tokens_predicted_total`, and their `_seconds_total` counters | the engine's own per-request numbers, summed (`prompt_n` is the processed count) |
| `llamacpp:prompt_tokens_seconds`, `llamacpp:predicted_tokens_seconds` | rates over the requests since the last scrape |
| `llamacpp:requests_processing`, `llamacpp:requests_deferred` | queue state |
| `llamacpp:kv_cache_tokens`, `llamacpp:kv_cache_usage_ratio` | the engine's own occupancy: the positions its pool holds in every region, busy and held, over the pool, as of the last completed request |
| `halogen:requests_total`, `halogen:prompt_tokens_cached_total`, `halogen:draft_tokens_total`, `halogen:draft_tokens_accepted_total`, `halogen:structured_requests_total` | halogen's own request counters |
| `halogen:kv_pool_positions`, `halogen:kv_pool_reserved_tokens` | pool positions; the front end's reservation |
| `halogen:kv_pool_waiting_for_room` | requests waiting for pool room |
| `halogen:queue_waited_total`, `halogen:queue_wait_seconds_total`, `halogen:queue_wait_longest_seconds`, `halogen:queue_gave_up_total` | requests that waited a second or more for a free slot, the seconds they waited, the longest wait now, and requests that gave up while waiting (the client left, or `HALOGEN_QUEUE_TIMEOUT` passed) |
| `halogen:cache_hits_total`, `halogen:cache_misses_total`, `halogen:cache_prompt_tokens_saved_total`, `halogen:cache_entries`, `halogen:cache_bytes`, `halogen:cache_evicted_total` | the prompt cache's main numbers |
| `halogen:cache_disk_enabled`, `halogen:cache_disk_bytes`, `halogen:cache_disk_budget_bytes`, `halogen:cache_disk_hits_total` | the cache's disk tier |
| `halogen:cache_last_message_rewrites_total` | requests that resumed inside the previous request's last message (a client that changes or drops part of it each turn) and continued in that conversation's cache |
| `halogen:cache_disk_cut_back_total` | times the disk tier trimmed a conversation's files back to where its next request resumed, instead of writing a second copy |
| `halogen:engine_up`, `halogen:busy_for_seconds`, `halogen:build_info` | liveness: the probe `/health` reports; how long the oldest request has run; the build |
| `halogen:cache_stats_age_seconds` | how old the cache numbers are |
| `halogen:gpu_queues_evicted_seconds_total` | seconds the kernel driver held the engine's GPU queues evicted because the host moved memory the GPU maps (compaction or reclaim); every request in flight stalls for them. Present only on a host that reports it |

A scrape never stalls on a busy engine: the cache numbers are the engine's
last report, refreshed in the background, and `cache_stats_age_seconds`
says how old it is. `GET /cache` keeps the full report. Always on, no flag.

**The per-request log line** carries the cached share of its prompt, the
prefill rate over the tokens actually processed, and the pool's occupancy
as the engine reports it:

```
serve_api: prompt 30828 (30803 cached, 99.9%), prefill 0.38s (25 new) | ... | pool 30976/524288 6%
```

The rate is printed only when at least 2,048 tokens were processed; below
that the line says how many were new and leaves the rate out, because a few
hundred tokens in a second is one prefill chunk's fixed cost and not a
speed. `timings` in the response is unchanged.

**`GET /cache`** adds `token_hit_rate` (prompt tokens the cache covered
over every prompt token seen since the server started; `hit_rate` counts
requests) and, under `pool`: `positions`, `used`, `usage_ratio`,
`busy_regions` (a request decoding), `held_regions` (a warm conversation
between turns, not a full pool), `room_clamped`, `moved` and `dropped` (the
entries a follow-up dropped to take its region over). A `/cache` polled
while the engine is inside a long cold prefill answers the last counters it
had with `stale_s` set, rather than failing.

## Prompt progress

`"return_progress": true` on a streamed `/v1/chat/completions` or
`/v1/completions` request adds chunks with an empty `choices` list and a
`prompt_progress` object while the prompt is read, before the first token,
in the shape llama.cpp's server sends:

| field | meaning |
|---|---|
| `total` | the prompt's tokens |
| `cache` | how many of them came from the prompt cache |
| `processed` | how many are read so far, the cached ones included |
| `time_ms` | milliseconds since prompt processing started |

The first chunk opens at the cached count and the last has `processed`
equal to `total`. A bar of the work left is `(processed - cache) /
(total - cache)`. Without `stream` the field is ignored; the Messages and
Responses routes have no such field. It never changes the reply.

---

*Verified* against the Codex CLI driving real tasks end to end, and
separately against the official `openai` Python SDK, which parses every
event into its own typed models.

## History

| shipped | what arrived |
|---|---|
| 0.7.0 | the Responses route, reasoning items, the `timings` object |
| 0.8.0 | structured output; `/metrics` |
| 0.11.5 | cache and pool fields on the log line; the occupancy rework |
| 0.11.9 | the prefill-rate floor (2,048 tokens) |
| 0.14.2 | images in tool outputs |
| 0.16.3 | the unconstrained tool-call-or-answer preamble under a schema |
| 0.17.5 | the cache metrics; prompt progress |
| 0.18.0 | the two cache-composition counters |
| 0.18.1 | the `previous_response_id` refusal |
