# Changelog

## 0.2.0

### Added

- **Sampling.** `temperature`, `top_p`, `top_k`, `min_p`, `seed`,
  `presence_penalty`, `frequency_penalty`, `logit_bias` and `logprobs` on
  `/v1/chat/completions` and `/v1/completions`. `temperature` absent or 0 is
  greedy decode and unchanged. Above 0, the request samples from the filtered
  distribution on the drafter it would otherwise get, so speculative decoding
  stays on: the accept/reject rule emits exactly the requested distribution.
  `top_k`, `top_p` and `min_p` compose as an intersection. Penalties count
  generated tokens. A `seed` reproduces a request on the same drafter and
  server configuration; a sampled speculative run and a sampled serial run
  agree in distribution, not token for token. Not implemented and refused
  with a 400: `top_logprobs`, `logprobs` with `stream: true`, `n > 1`. A value
  outside a parameter's defined range is refused, not clamped.
- `/health` reports the sampling parameters the running build supports.

### Changed

- Greedy decode is about 1% faster on every path. Token output is unchanged.

## 0.1.1

A bug-fix release. **The engine is unchanged**: no kernel, no checkpoint, no
format change, and the binary builds from identical source, so every
performance and quality number below still stands and **your weights do not
need re-downloading**. The image carries no weights and the mount layout is the
same, so upgrading is a container pull and nothing else.

### Fixed

- **A default request could come back empty.** `max_tokens` defaulted to 512
  while the chat template defaults `reasoning_effort` to `xhigh`, and reasoning
  tokens count against the budget. A request that ran out before the model
  finished thinking returned `finish_reason: "length"` with an **empty
  `content`** and the whole reply in `reasoning_content`, which most OpenAI
  clients do not display. On ten ordinary prompts, three were truncated and
  "write a Python function that merges overlapping intervals" came back
  completely blank. The default is now **8192**; eight of eight prompts that
  finish at all finish inside 2048.
- **`max_completion_tokens` and `max_output_tokens` were silently ignored.**
  They were not declared, so a client using the current OpenAI Chat Completions
  field name had it dropped without an error and got the default no matter what
  it asked for. The budget was reachable only under the deprecated
  `max_tokens`. All three names are now accepted and mean the same thing. Send
  one, or send several as long as they agree; two different values is a 400
  rather than a guess.

### Changed

- `HALOGEN_MAX_TOKENS_CAP` **16384 to 65536**, so a long reasoning problem is
  not cut off by server policy. `HALOGEN_QUEUE_TIMEOUT` **2400 to 3600** with
  it: the two are coupled, and a cap that outlasts the timeout makes one long
  request 503 everyone queued behind it.
- `/health` now reports `max_tokens_default` and `token_budget_aliases`, so a
  client can read which spellings this server accepts instead of guessing.

### If you saw poor output on 0.1.0

Check `finish_reason` on a reply that looked wrong. `"length"` with an empty or
truncated `content` was this bug, and it was not your configuration. Either pull
0.1.1, or stay on 0.1.0 and pass `"max_tokens": 8192` explicitly, which is the
only spelling 0.1.0 reads.

## 0.1.0


First release of halogen-flash-server. Container image only; the engine is
closed source. Weights are published separately and are two files.

### The engine

- **Qwen3.8-Flash-Next end to end on gfx1151.** Gated DeltaNet, QSA with its
  micro-block indexer, the 512-expert MoE, the gated residual, and the 51B
  n-gram embedding table, all as kernels written for this silicon. No
  general-purpose runtime underneath.
- **4-bit weights as a correctness precondition.** 335 GiB at BF16 against
  124 GB of unified memory. The served precision is a 4-bit base plus a
  2.31 GiB quality sidecar, the default, which upgrades the twelve tensors
  measurement showed the loss was concentrated in. Served precision is
  5.53 bits per weight, measured from the checkpoint's tensor table.
- **Context to 262,144 native, and 262,144 admitted by default.** The quality
  work covers 1k to 32k; beyond that the context is served but unscored.
- **Prefill to 131,072 tokens** with QSA block selection live.

### Serving

- OpenAI-compatible endpoint: `/v1/chat/completions` (streaming and not),
  `/v1/models`, `/health`, tool calls.
- **Static N-slot batching**, one slot by default. Concurrent sequences share
  the engine, and a request batched alongside others emits byte-identical
  tokens to the same request run alone.
- **Lossless speculative decoding** with the model's own MTP head, on by
  default. Byte-identical to serial greedy decode.
- **Prompt cache on by default** (mode 2, resume anywhere). A growing session
  does not re-prefill its shared prefix: a follow-up turn at 100,000 tokens of
  context costs about 2 s against 88 s cold. `HALOGEN_PROMPT_CACHE=1` snapshots
  only on chunk boundaries and makes the warm answer byte-identical to a cold
  one, which the default trades away for speed at every prompt length.
- **Greedy only. There is no sampler.** `temperature` above 0, `top_p`,
  `top_k`, `min_p`, `seed`, the penalties, `logit_bias` and `logprobs` are
  rejected with a 400 naming the reason, rather than quietly served greedy,
  because a client cannot tell those apart from the response. `/health`
  reports exactly this. Sampling is a post-0.1.0 feature.

### The image

- `python:3.12-slim` plus AMD's ROCm 7.14.0 wheels, 3.53 GB. **No torch**, no
  compiler, no devel tree, and no engine source: nothing from the builder stage
  reaches the runtime but the stripped binary. The OpenAI front-end is Python
  and necessarily ships as readable source, and it pulls in `transformers` for
  the chat template.
- ROCm is **pinned**: the version is ours, not a third party's moving tag.
- No outbound connections unless `HALOGEN_DOWNLOAD` is set.
- Ships the two benchmarks it is measured with (`bench`, `sweep`), so the
  published numbers are reproducible against your own hardware.

### Known limits

- Continuous batching and speculation-inside-a-batch are 0.2. A speculating
  request holds its slot alone, so concurrent requests queue behind it.
- gfx1151 only. The build hard-rejects other architectures.
