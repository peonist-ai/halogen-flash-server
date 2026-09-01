# Changelog

## 0.1.0 (unreleased)

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
