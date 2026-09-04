# Changelog

## 0.4.3

### Fixed

- **The front-end could open several connections to the engine at once, and
  strand the requests that were already using the old one.** It keeps a single
  connection and multiplexes every request over it, reopening that connection
  when it closes. Every request checked that condition, and the reopen itself
  was not serialised, so a connection that dropped with work in flight raced
  all of the waiting callers into opening their own. Measured: six concurrent
  callers opened six connections.

  Each extra connection leaked the previous socket, started a second reader on
  the same stream, and replaced the table of in-flight requests and the count
  of engine slots underneath requests that were still using them. A request
  whose entry in that table was replaced could no longer be reached by any
  reader, and the reader responsible for it woke the wrong table when it
  exited, so nothing ever told that request the connection had gone. It waited
  out its full token budget and then reported that the engine had gone silent.

  If you have seen an intermittent 504 saying the engine went silent, in either
  prefill or decode, on prompts of any size, recovering by itself on the next
  request, this is a candidate. It is not confirmed as the cause of every such
  report: the race is proven and fixed, and the stranding that follows from it
  is fixed with it, but we were not able to reproduce the reported stall on our
  own hardware in 540 requests across three configurations.

- **A cancelled request that had not started yet was not actually cancelled.**
  Cancellation searched the requests that were running and the one whose prompt
  was being read, but never the queue, so a client that disconnected before its
  request began still had it generated in full, into a slot nobody was reading.
  The front-end cancels every abandoned request, so this was the ordinary path
  for a client that goes away under load rather than a rare case. It now costs
  nothing.

### Added

- **A test for the reconnect path**, which runs against a stand-in engine and
  needs no GPU and no model, so it runs in the release gate on every build. It
  reads six connections on the previous release and one on this one.

## 0.4.2

### Fixed

- **A healthy server reported itself unhealthy, on every deployment using the
  two-container `docker-compose.yml` in this repository.** `docker ps` showed
  `Up (unhealthy)` with a failing streak in the hundreds while the server was
  answering every request correctly.

  The engine serves one connection at a time. That is deliberate and is how the
  slots are shared: the API front-end opens a single socket at startup and
  multiplexes every request over it. But it meant that once the front-end
  connected, no other connection was ever accepted. The kernel completes a few
  extra connections into a backlog without the engine's involvement, and that
  backlog was four, so the first five health probes succeeded and every one
  after them timed out for the life of the process. Measured with a session
  held: probes one to five pass, probe six onward never does.

  The engine now accepts and queues connections while a session is running, and
  serves the queue before asking for a new connection. Probes succeed, and a
  client that connects while another is being served is served afterwards
  rather than being dropped. If you added a longer `start_period`, more
  `retries`, or removed the healthcheck to work around this, you can put it
  back.

- **`HALOGEN_FLASH_PIN_TRUNK=0` would not start alongside the quality overlay**,
  exiting with `expected bf16 or Q4C-P, got q8g64`. The unpinned path handled
  two weight formats and the twelve tensors the quality overlay promotes are a
  third. It now handles them, and the result is token-for-token identical to
  the reference implementation.

### Added

- **The server now says when the host's free memory is in the wrong shape.**
  Free memory can be plentiful and still be unusable in large contiguous
  pieces, typically right after a large process exits. In that state every big
  allocation stops to compact memory, most of those attempts fail, and startup
  can take tens of minutes at 100% of one core with no disk activity and no
  output, which is indistinguishable from a hang. That is not a hypothetical:
  it is what a user spent two rounds of a bug report tracking down.

  Before it allocates anything the server now reads the supply of free 2 MiB
  contiguous blocks and says how many there are, and warns when there are too
  few. It also reports how many times each startup step had to stop and compact
  memory. A healthy host does almost none; the reported case did tens of
  thousands. If you see the warning, stop other large workloads and, as root,
  `echo 1 > /proc/sys/vm/compact_memory` before starting again.

  `HALOGEN_FRAG_WARN_BLOCKS` and `HALOGEN_FRAG_WARN_STALLS` set the two
  thresholds; see `FLAGS.md`.

- **The startup now names every step through to the open socket.** The previous
  release stopped reporting at `model ready`, and the remaining work (reserving
  serving slots, preparing the prompt cache, opening the socket) ran in
  silence. A user watching a slow start could not tell which of those it was
  sitting in. All of them announce themselves now.

## 0.4.1

### Fixed

- **A streamed reply and a non-streamed reply to the same prompt came back
  slightly different.** Asking with `"stream": true` returned the answer with
  a leading blank line that the non-streamed form did not have, and the
  reasoning text differed by leading or trailing whitespace. The model was
  generating exactly the same tokens either way; the two response builders
  disagreed about tidying them, and only one of them was trimming. Measured
  across five prompts on 0.4.0, all five differed.

  One case was more than cosmetic: on a turn where the model called a tool and
  said nothing else, the non-streamed `content` was `""` and the streamed
  `content` was a blank line, so a client testing "did the model say anything
  as well as calling the tool" got different answers depending only on how it
  had asked. If you have a workaround that trims the streamed content or tests
  it loosely, you can drop it.

  This affected `/v1/chat/completions`. `/v1/responses` was fixed before 0.4.0
  shipped and is unchanged.

- **`/v1/completions` returned a 500 on every request, in every release from
  0.2.0 to 0.4.0.** The endpoint was listed in this README and reported by
  `/health` the whole time. Internally it read a set of sampling settings that
  had been added to the chat endpoint's request model and never to this one, so
  the very first thing it touched raised an error and the request came back as
  an opaque "internal error". It now works, greedy and sampled, and rejects
  out-of-range values the same way the chat endpoint does.

  If you tried this route on an earlier release and concluded the server was
  broken, it was, and only for this route. `/v1/chat/completions` and
  `/v1/responses` were unaffected.

- **The release gate now tests every route the server advertises.** It reads
  the endpoint list out of `/health` and exercises each one, so a route cannot
  be published and left untested, which is exactly how the bug above survived
  five releases. A route with no test fails the gate rather than passing
  quietly.

## 0.4.0

### Added

- **The OpenAI Responses API at `POST /v1/responses`**, so clients that dropped
  Chat Completions can use this server directly. The OpenAI Codex CLI is the
  one this was built for: set `wire_api = "responses"` in a `model_providers`
  entry pointing at this server and it works, tool calls included. Streaming
  and non-streaming are both supported, `function_call` and
  `function_call_output` round trip, and tool entries that are not functions
  are ignored rather than rejected. The README has a worked Codex config.

  Verified two ways that do not share an assumption: the Codex CLI driving real
  tasks end to end against the server, and the official `openai` Python SDK,
  which parses every event and object into its own typed models.

  Not included, and stated rather than left to be discovered: **reasoning is
  not returned** (the API carries it as an encrypted item the client hands back
  and this server stores nothing, so a summary would be invented rather than
  real; the answer is unaffected), and **there is no response store**, so
  `previous_response_id`, retrieval by id and cancellation are unavailable.
  Send the history with each request, which is what Codex does.

- `/health` now lists the endpoints the running build serves, generated from
  the routing table so it cannot describe a route that is not there.

## 0.3.2

### Fixed

- **A machine that took longer than 30 minutes to load could not start the
  server at all.** In the default `all` mode the container waited exactly 30
  minutes for the engine, then started the API against an engine that was
  still loading, and the API's failure to connect took the whole container
  down reporting that a component had exited. The engine underneath was
  working normally. There is no correct fixed limit here, because load time is
  your disk and your driver rather than anything the server controls, so it
  now waits for as long as the load takes and watches the engine process
  instead: if the engine actually dies, you are told immediately. Set
  `HALOGEN_ENGINE_WAIT_S` to a number of seconds if you would rather the
  container fail than wait; on expiry it says the engine was still loading and
  exits, rather than starting a front-end that cannot work.
- **A warning printed after the engine came up went nowhere.** The readiness
  check redirected the startup script's own error output to `/dev/null` for
  the life of the container, so every later message was discarded, including
  the one naming which component had exited. Fixed.
- **A failure to load the quality sidecar said only "invalid argument".** It
  now says how much of the model had loaded, that the limit is the GPU
  driver's rather than a problem with your file, and what to check first.

### Added

- **The server now says which startup step it is on and how long it has
  taken**, including a layer counter while it prepares weights. A first start
  reads about 68 GB off disk and can take minutes on a slow or busy machine;
  until now that time was completely silent, which made a slow start
  indistinguishable from a hung one. `HALOGEN_STARTUP_PROGRESS=0` turns it
  off. If you report a slow start, a log with these lines in it is the most
  useful thing to attach.

For reference, on the development machine (Ryzen AI Max+ 395, 125 GB, weights
on NVMe, all defaults) a start takes about 9 seconds with the model already in
the file cache and about 18 seconds otherwise. A first start after boot is
bounded by reading 68 GB off your disk.

## 0.3.1

### Fixed

- **0.3.0 could fail to start with "out of memory" on machines where 0.2.0
  ran.** The default KV pool was three times the context (786,432 positions,
  about 42 GB on the device), sized on a machine whose ceiling is about 47 GB.
  A machine with a lower ceiling refused, and the two settings a reader would
  reach for first do not fix it: `HALOGEN_KV_SLOTS` has not been a memory
  setting since 0.3 (the slots share one pool and cost about 115 MB each), and
  `HALOGEN_CTX` bounds a request rather than the allocation.
- **The default pool is now twice the context** (524,288 positions, about
  35 GB): two full-length conversations resident, or four at 131k. Set
  `HALOGEN_KV_POOL_POSITIONS=786432` for three where the machine has room.
- **The server now measures the device budget at startup and lowers the pool
  itself** when the configured one will not fit, printing the pool it settled
  on. It only ever lowers, never below `HALOGEN_CTX`, and it changes nothing
  about what any conversation computes. `HALOGEN_KV_POOL_FIT=0` turns it off.
- **The out-of-memory message now names the settings that fix it**, and says
  which one does not.
- **A server that started and then crawled on long prompts** with the disk
  busy was the same oversized default wearing a second symptom. The model
  reads a large lookup table through the file cache rather than holding it in
  RAM, so RAM the pool takes is RAM that table loses, and a longer prompt
  touches more of it. The startup sizing now accounts for it, and
  `HALOGEN_HOST_RESERVE_GIB` (default 20) is how much it leaves free.

### Changed

- **The server says less at startup.** It still reports what it is serving:
  the precision it loaded, the KV pool it sized and why, the slots, the cache
  mode and the address it is listening on. It no longer narrates how its
  kernels are arranged, which was detail no deployer acts on.
  `HALOGEN_VERBOSE=1` and `HALOGEN_DMALLOC_LOG=1` are the two settings worth
  turning on when a start goes wrong, and both are documented in the settings
  reference.
- The README's settings table described `HALOGEN_KV_SLOTS` as the memory
  budget, which was true before 0.3 and not after. Corrected, and the README
  has a section on what to do when the server will not start.

## 0.3.0

### Added

- **Several conversations at the full context.** The slots share one pool of
  attention positions instead of each owning a copy, so a slot costs about
  115 MB, and the pool is sized on its own (`HALOGEN_KV_POOL_POSITIONS`,
  default three times the context: three full 262k conversations at once,
  about 42 GB, measured with all three resident and generating; 1,048,576
  positions fit with `HALOGEN_MAX_TOK=16384`). The pool takes RAM from the
  page cache that serves the n-gram table, so a prompt whose rows are not
  cached reads them from disk first; the README's memory section has the
  measurement and the setting that trades back.
  The default is now `HALOGEN_KV_SLOTS=4`. A request reserves its prompt plus
  `max_tokens` positions and waits in arrival order when the pool is full.
  Each stream stays byte-identical to the same request run alone; four
  streams together produce about 76 tokens per second in total against 34
  for one, and a conversation's speed follows its own length, not the pool.
- **A prompt read in beside running conversations does not freeze them for
  its whole length.** It is read in pieces the size of the prefill call
  (`HALOGEN_MAX_TOK`, 32,768) with a generation step for the others between
  pieces, which keeps its answer byte-identical to running alone: a 131k
  prompt pauses the others three times for about 28 s instead of once for
  105 s. `HALOGEN_ADMIT_CHUNK=8192` makes the pause about 8 s for a 32k prompt
  at about 5 s on its own first token, trading the identity property for that
  prompt. A prompt that arrives when nothing else is running is read in one
  call as before.
- **The speculative drafter no longer holds other requests back.** It
  speculates while its conversation is the only one generating and joins the
  batch when another is active, resuming when alone again. The default drafter
  is unchanged.
- **The prompt cache keeps eight entries** (`HALOGEN_CACHE_ENTRIES`, least
  recently used out), two per conversation: at the end of the system prompt
  and at the end of the history. Conversations taking turns each resume from
  their own state (turn two at 25,000 tokens: about 0.5 s to the first token,
  where one entry gave 22 s), and requests sharing a system prompt and asking
  different things resume from it, whether they arrive together or in turn.
- `HALOGEN_KV_POOL=0` restores the previous per-slot layout for comparison.

### Changed

- `HALOGEN_KV_SLOTS` defaults to 4 (was 1). `/health` reports the count as
  before.

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
- **1M context, opt-in.** `HALOGEN_ROPE_YARN=4` with `HALOGEN_CTX=1048576`
  enables the model card's static YaRN; unset, nothing changes. It rescales
  every position and costs about 0.5% perplexity at 1k-32k and some
  speculative acceptance at depth; the README's *1M context* section has the
  measurements, the memory configuration it needs, and the retrieval scores
  above 32k, which are the first this project has published. Contexts past
  262,144 are refused without the factor.
- **The prompt cache keeps the attention state in place** and saves only
  the small position-free part of a conversation's state (about 110 MB at
  any context), so saving and resuming cost well under a second at every
  context; a follow-up turn at 1M reaches its first token in about half a
  second on the test machine. Answers are byte-identical to the previous
  form, which `HALOGEN_CACHE_INPLACE=0` keeps for comparison.
  `HALOGEN_CACHE_FILE` can still put the snapshot on a file.
- **The prompt cache now hits on multi-turn chats whose client omits
  `reasoning_content` from the history**, which is what OpenAI-style
  clients do. It used to snapshot at the very end of the prompt, inside
  the assistant opener the template rewrites on the next turn, so every
  turn of such a conversation re-read the whole prefix. The snapshot now
  lands at the end of the history; a follow-up turn on a 25,000-token
  system prompt takes about 1 s to first token instead of 21 s.
- `/health` reports `rope_scaling`.

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
