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
| `HALOGEN_MAX_TOKENS_CAP` | `65536` | Largest `max_tokens` a request may ask for. Exceeding it is a **400**, never a silent truncation: a truncated response and a model that stopped on its own both end with `finish_reason: "length"`, so a client cannot tell them apart. **Coupled to `HALOGEN_QUEUE_TIMEOUT`**, see the README. |
| `HALOGEN_QUEUE_TIMEOUT` | `3600` | Seconds a queued request waits before `503 engine_busy`. Must exceed the time a full-length request takes, or a long request 503s everyone behind it. |
| `HALOGEN_DRAFTER_DEFAULT` | `1` | Which drafter a request that names none gets: `1` the model's own MTP head (speculative, and **byte-identical** to serial greedy, since it only proposes), `0` batched serial. A speculating request speculates while it is the only one generating and joins the batch as soon as another request is active, so the setting costs no concurrency. Overridable per request with `"drafter": "serial" | "mtp"`. |

## Context and concurrency

| flag | default | meaning |
|---|---|---|
| `HALOGEN_KV_SLOTS` | `4` | Conversations generating at once. A slot costs about 115 MB; the pool below decides what fits. Each stream is **byte-identical to running alone**. Four streams together produce about 76 tokens per second in total, each at 11 to 19; eight produce about 85, each at about 10, so raising it trades per-stream speed for admitting more clients at once rather than queueing them. Past eight a step takes two forwards and total throughput stops growing. Capped at 64. |
| `HALOGEN_KV_POOL_POSITIONS` | `2 x HALOGEN_CTX`, capped at 1,048,576 | Attention positions resident across all conversations; `HALOGEN_CTX` is the most one request may use. A request reserves its prompt plus `max_tokens` positions when admitted and waits in arrival order when they are not free. The default 524,288 holds two full-length conversations, about 35 GB on the device; 786,432 holds three at about 42 GB (0.3.0 defaulted to it and it is too close to the ceiling on some machines) and 1,048,576 needs `HALOGEN_MAX_TOK=16384` (about 41 GB). The server measures the device budget at startup and lowers the pool itself if the configured one will not fit, saying what it chose. Generation speed follows each conversation's own length, not the pool. The pool takes RAM the page cache would otherwise keep for the model's n-gram table, so a prompt whose rows are not cached reads them from disk first; a smaller pool leaves more cache. |
| `HALOGEN_KV_POOL_FIT` | `1` | Whether the server measures the device budget at startup and lowers `HALOGEN_KV_POOL_POSITIONS` when the configured pool will not fit, printing the pool it settled on. `0` allocates exactly what was asked for and lets the allocation fail, which is what every release before 0.3.1 did. It can only lower the pool, never raise it, and it never lowers it below `HALOGEN_CTX`; a shorter pool changes how many conversations stay resident and changes nothing about what any one of them computes. |
| `HALOGEN_HOST_RESERVE_GIB` | `20` | How much system RAM the server leaves free, on top of the weights, when it sizes the KV pool at startup. The model keeps a large lookup table on disk and reads it through the file cache rather than holding it in memory, so RAM the pool takes is RAM that table loses. Too little and the server starts, runs, and then crawls on long prompts with the disk busy. Raise it if you see that; a smaller pool is the trade. |
| `HALOGEN_CTX` | `262144` | The most context ONE request may use, **the model's full native context, by default**. A prompt over the limit is a hard error naming it, never a truncation. The published quality numbers cover 1k-32k; beyond that the context is served but unscored. |
| `HALOGEN_ADMIT_CHUNK` | `0` (the engine's own prefill chunk) | How a prompt is read in when other conversations are already generating: in pieces, with a generation step for the others between pieces. The default piece is the prefill call size (`HALOGEN_MAX_TOK`, 32,768), which is exactly how the same prompt is split when it runs alone, so the answer stays byte-identical to running alone; a 131k prompt pauses the others three times for about 28 s each instead of once for 105 s. `HALOGEN_MAX_TOK=16384` halves the pause for everyone at about 8% slower prefill and keeps identity. A smaller value such as `8192` (measured: a 32k prompt pauses the others about 8 s rather than 28, and pays about 5 s on its own first token) trades that identity for the admitted prompt, whose answer then depends on the load when it arrived. `-1` reads every prompt in one call. |
| `HALOGEN_CACHE_ENTRIES` | `8` | How many prompt-cache entries the server keeps, least recently used out. A conversation holds two: one at the end of its system prompt, one at the end of its history, so eight entries cover four conversations, and requests that share a system prompt and ask different things resume from it. Each entry is about 115 MB of RAM plus the pool positions its context occupies, which stay reserved until a request needs them. One entry cannot serve two conversations taking turns; four can. |
| `HALOGEN_MAX_TOK` | `32768` | Largest single prefill call; longer prompts are prefilled in pieces. It sizes a ~4 GB scratch arena, so **do not raise it to the native context**. That allocation does not fit and the server will not start. |
| `HALOGEN_CACHE_INPLACE` | `1` | The prompt cache keeps the conversation's attention state where it already is and saves only the small position-free state (about 110 MB at any context), so saving and resuming cost well under a second even at 1M. `0` copies the whole state instead (up to 26.6 GB at 1M); it is the older form, kept for comparison, and gives the same answers byte for byte. |
| `HALOGEN_CACHE_FILE` | *(unset)* | Keep the prompt cache's snapshot in a file at this path instead of host RAM: the same bytes, at the drive's speed. Only needed with `HALOGEN_CACHE_INPLACE=0` past 262,144, where that form's snapshot is up to 26.6 GB; the container then sets it to `/var/tmp/halogen-cache.snapshot`. The file is created at startup and removed at exit. |
| `HALOGEN_ROPE_YARN` | *(unset)* | Contexts past the native 262,144, up to 1,048,576. Set it to the model card's static YaRN factor (`4` for 1M, `2` for 524,288) together with a larger `HALOGEN_CTX`; the server refuses a context past 262,144 without it, and past 262,144 x factor with it. It is a different model configuration, not a cache setting: every position's RoPE is rescaled, short prompts included, and the model card advises it only when the context needs it. Past the native context the server caps `HALOGEN_MAX_TOK` at 16384 and prints it, because a 1M KV cache leaves no room for the larger prefill arena on a 128 GB machine. The README's *1M context* section has what it costs. Unset, nothing changes. |

## Speed levers

| flag | default | meaning |
|---|---|---|
| `HALOGEN_PROMPT_CACHE` | `2` (resume anywhere) | Reuse a session's shared prefix instead of re-reading it. **`2` (default)** saves its place at the end of every request, so a follow-up turn at 100,000 tokens of context costs about 2 s against 88 s cold, at any prompt length. **`1`** saves only on a prefill-chunk boundary, which makes a resumed answer byte-identical to a cold one, at the price of caching nothing below one chunk. **`0`** is off. The README's *Choosing a cache mode* has the numbers and the cases. **NUMERIC** in mode 2. |
| `HALOGEN_PREFILL_CHUNK` | `32768` | How many tokens the engine prefills per call. Under the default cache mode this is purely a speed setting and 32,768 is the fastest value measured; 1,024 costs about half the throughput at long context. Under `HALOGEN_PROMPT_CACHE=1` it is also the resume granularity, so lower it to 8,192 if you need byte-identical repeat answers on conversations shorter than 32,768 tokens, at about 13% less prefill throughput. |
| `HALOGEN_MATMUL_TUNING_FILE` | `/opt/halogen/flash-tune.plan` (baked in) | A tuned GEMM plan: which kernel the matrix library should use for each shape, decided once and shipped in the image. On by default at no measurable quality cost, and the published prefill numbers include it. Every process reads the same decisions, so the same prompt keeps giving the same answer. The plan is tuned on one machine; a different Strix Halo SKU loads it with a warning. To retune for your own workload, point this at a path that does not exist yet, run with `HALOGEN_MATMUL_ALGOS=8`, and stop the container cleanly. **Do not set `HALOGEN_MATMUL_ALGOS=8` without a file**: selection then happens per process by timing, and identical prompts stop answering identically across restarts. |

## Troubleshooting

| flag | default | meaning |
|---|---|---|
| `HALOGEN_VERBOSE` | `0` in this image | Whether the server narrates how it is armed at startup, on top of what it is serving. Off in the published image, where the extra lines are internal detail rather than anything a deployer acts on. Set it to `1` when you are diagnosing a start that goes wrong and want the fullest account the server can give. |
| `HALOGEN_STARTUP_PROGRESS` | `1` (on) | Whether the server says which startup step it is on and how long it has taken: pinning weights, preparing them layer by layer, reserving working memory, reserving the KV pool, ready. A first start reads about 68 GB off disk, so on a slow or busy machine the wait is minutes, and these lines are what tell you it is progressing rather than stuck. Leave it on. If you report a slow start, the log with these lines in it is the single most useful thing to attach. |
| `HALOGEN_ENGINE_WAIT_S` | `0` (wait as long as the load takes) | How long the container waits for the engine to finish loading before giving up. The default waits indefinitely and watches the engine process, so a machine that needs twenty minutes to load gets twenty minutes, and a crash is still reported immediately. Set a number of seconds if you would rather the container fail than wait, for example under an orchestrator with its own startup probe; on expiry the container exits with a message saying the engine was still loading. |
| `HALOGEN_DMALLOC_LOG` | `0` | `1` prints every device allocation of 64 MB or more as it happens, with its size, a running total and a count. It is this configuration's memory budget measured rather than estimated, and it is the right thing to attach to a report about a server that will not start. It prints sizes and totals only. |

## Benchmark tooling

| flag | default | meaning |
|---|---|---|
| `HALOGEN_API` | `http://127.0.0.1:8731` | Endpoint the bundled benchmarks target. |
| `HALOGEN_API_LOG` | *(unset)* | Path to a teed front-end log, so the serving benchmark can read throughput counters from inside a container. |
