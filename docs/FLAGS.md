# halogen environment flags

Everything is configured by environment variable; there is no config file.
All flags are read **once at startup**.

This lists the flags used to deploy and operate halogen. The engine carries
additional kernel-tuning levers that are not documented here: they select
internal implementation variants, they are not needed to run the server, and
the shipped defaults are the measured winners. Changing what is listed below
is supported; anything else is not.

| class | meaning |
|---|---|
| **BITWISE** | output is byte-identical. Safe to change. |
| **NUMERIC** | output *can* change. |

Every flag below is **BITWISE**, deployment policy rather than arithmetic, except
`HALOGEN_CK_OVERLAY`, which selects which weights run, and
`HALOGEN_MATMUL_TUNING_FILE`, which changes the order a sum is accumulated in.
Both are marked, and both were measured before being offered.


## Model and tokenizer

| flag | default | meaning |
|---|---|---|
| `HALOGEN_CHECKPOINT` | `/models/qwen38-flash-next-w4b.hgn` | Path to the `.hgn` checkpoint the engine loads. **The served checkpoint is two files**: this one and the quality sidecar `<checkpoint>.overlay.hgn` beside it, which the engine picks up on its own. The server says at startup which precision it is about to run, and warns if the sidecar is absent. |
| `HALOGEN_CK_OVERLAY` | *(unset = the sidecar)* | Which precision sidecar to read. Unset means the quality sidecar beside the checkpoint, **which is the default and needs no action**. Point it at `…overlay-speed.hgn` to trade the `o_proj` calibration for about 2% of decode, or `none` to run the bare 4-bit checkpoint, which is the measurement control rather than a serving configuration. **NUMERIC**: it selects which weights run. |
| `HALOGEN_TOKENIZER` | `/tokenizer` | Flat tokenizer directory. **You usually do not need to set this**: the weights repo ships `tokenizer/` inside it, and when nothing is mounted at `/tokenizer` the server falls back to `tokenizer/` beside the checkpoint, so one `-v` of the models directory is enough. Set it only when your tokenizer lives elsewhere. It must be FLAT: HuggingFace cache snapshots are symlinks into a sibling `blobs/` and dangle inside a container, so materialize with `cp -L`. |
| `HALOGEN_MODEL_ID` | `halogen-qwen3.8-flash-next` | The model id listed at `/v1/models`, reported at `/health`, and echoed in every completion. A label. Requests are never rejected for naming a different one. Override it to run two stacks on one host without the ids colliding. |

## Networking

| flag | default | meaning |
|---|---|---|
| `HALOGEN_API_PORT` | `8731` | Port for the OpenAI-compatible front-end. The only port that should be published. |
| `HALOGEN_PORT` | `8730` | Engine port. **The engine protocol has no authentication**, so keep it unpublished. |
| `HALOGEN_BIND` | `127.0.0.1` | Engine bind address. Loopback when engine and front-end share a container; `0.0.0.0` for the two-container topology, where it stays unpublished to the host. |
| `HALOGEN_ENGINE` | `127.0.0.1:$HALOGEN_PORT` | Where the front-end reaches the engine. Compose gives the services separate network namespaces, so it needs `engine:8730` there. |

## Request policy

| flag | default | meaning |
|---|---|---|
| `HALOGEN_MAX_TOKENS_CAP` | `16384` | Largest `max_tokens` a request may ask for. Exceeding it is a **400**, never a silent truncation: a truncated response and a model that stopped on its own both end with `finish_reason: "length"`, so a client cannot tell them apart. **Coupled to `HALOGEN_QUEUE_TIMEOUT`**, see the README. |
| `HALOGEN_QUEUE_TIMEOUT` | `2400` | Seconds a queued request waits before `503 engine_busy`. Must exceed the time a full-length request takes, or a long request 503s everyone behind it. |
| `HALOGEN_DRAFTER_DEFAULT` | `1` | Which drafter a request that names none gets: `1` the model's own MTP head (speculative, and **byte-identical** to serial greedy, since it only proposes), `0` batched serial. A speculating request holds its slot alone, so on a busy server `0` admits more concurrency at lower per-stream speed. Overridable per request with `"drafter": "serial" | "mtp"`. |

## Context and concurrency

| flag | default | meaning |
|---|---|---|
| `HALOGEN_KV_SLOTS` | `1` | Sequences resident at once. Each stream is **byte-identical to running alone**. One is the default and is not a downgrade: the default drafter is the model's own speculative head, which drives its slot alone and blocks admission while it runs, so extra slots buy nothing unless requests ask for `"drafter": "serial"`. Raise it and lower `HALOGEN_CTX` together, since their product is the budget. Capped at 64. |
| `HALOGEN_CTX` | `262144` | Context the server admits, **the model's full native context, by default**. Costs about 26 KiB per position per slot, so `HALOGEN_KV_SLOTS x HALOGEN_CTX` is one memory budget: measured on a 128 GB machine, 1 slot at 262,144 starts and 4 does not. A prompt over the limit is a hard error naming it, never a truncation. The published quality numbers cover 1k-32k; beyond that the context is served but unscored. |
| `HALOGEN_MAX_TOK` | `32768` | Largest single prefill call; longer prompts are prefilled in pieces. It sizes a ~4 GB scratch arena, so **do not raise it to the native context**. That allocation does not fit and the server will not start. |

## Speed levers

| flag | default | meaning |
|---|---|---|
| `HALOGEN_PROMPT_CACHE` | `2` (resume anywhere) | Reuse a session's shared prefix instead of re-reading it. **`2` (default)** saves its place at the end of every request, so a follow-up turn at 100,000 tokens of context costs about 2 s against 88 s cold, at any prompt length. **`1`** saves only on a prefill-chunk boundary, which makes a resumed answer byte-identical to a cold one, at the price of caching nothing below one chunk. **`0`** is off. The README's *Choosing a cache mode* has the numbers and the cases. **NUMERIC** in mode 2. |
| `HALOGEN_PREFILL_CHUNK` | `32768` | How many tokens the engine prefills per call. Under the default cache mode this is purely a speed setting and 32,768 is the fastest value measured; 1,024 costs about half the throughput at long context. Under `HALOGEN_PROMPT_CACHE=1` it is also the resume granularity, so lower it to 8,192 if you need byte-identical repeat answers on conversations shorter than 32,768 tokens, at about 13% less prefill throughput. |
| `HALOGEN_MATMUL_TUNING_FILE` | `/opt/halogen/flash-tune.plan` (baked in) | A tuned GEMM plan: which kernel the matrix library should use for each shape, decided once and shipped in the image. On by default at no measurable quality cost, and the published prefill numbers include it. Every process reads the same decisions, so the same prompt keeps giving the same answer. The plan is tuned on one machine; a different Strix Halo SKU loads it with a warning. To retune for your own workload, point this at a path that does not exist yet, run with `HALOGEN_MATMUL_ALGOS=8`, and stop the container cleanly. **Do not set `HALOGEN_MATMUL_ALGOS=8` without a file**: selection then happens per process by timing, and identical prompts stop answering identically across restarts. |

## Benchmark tooling

| flag | default | meaning |
|---|---|---|
| `HALOGEN_API` | `http://127.0.0.1:8731` | Endpoint the bundled benchmarks target. |
| `HALOGEN_API_LOG` | *(unset)* | Path to a teed front-end log, so the serving benchmark can read throughput counters from inside a container. |
