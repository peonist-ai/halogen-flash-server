<p align="center">
  <img src="docs/halogen.jpg" alt="halogen-flash" width="760">
</p>

# halogen-flash-server

**The fastest way to run Qwen3.8-Flash-Next on AMD Strix Halo, and it does not
get there by spending fewer bits.**

Every kernel is written for this one GPU and this one model family. No
general-purpose runtime, no portability layer, no fallback path. That is why it
can do things a general engine cannot, and why it runs on exactly one piece of
silicon.

On a 32K prompt with a 256-token answer, against the fastest numbers anyone
else has published for this model on this hardware:

| | precision | prefill | decode | **total** |
|---|---|---|---|---|
| **halogen-flash 0.3.0** | **5.53 bpw** | **25.0 s** | **6.1 s** | **31.1 s** |
| [EngramHalo.cpp](https://github.com/Aristo94/EngramHalo.cpp) | 3.71 bpw | 103.7 s | 14.3 s | 118.0 s |
| [ROCmFP4](https://huggingface.co/kingjones777/Qwen3.8-Flash-Next-ROCmFP4-STRIX-GGUF) | 5.51 bpw | 104.7 s | 13.2 s | 117.9 s |
| [CIRU-IU4](https://huggingface.co/jcbtc/Qwen3.8-Flash-CIRU-STRIX-IU4) | 5.96 bpw | 143.7 s | 11.0 s | 154.7 s |

**Roughly 3.8x faster end to end than the best of them.** Prefill is where that
is won, and on any prompt with real context prefill is most of the wall clock.
The one runtime carrying more bits than we do is the slowest of the three, and
the fastest of them runs at 3.71 bpw, two thirds of our precision.

Bits per weight is measured from the checkpoint's own tensor table rather than
quoted from a format name. It is 5.53 bpw across all 179.55B parameters, or
4.55 bpw across the trunk and experts with the FP8 n-gram lookup table set
aside.

**On the decode column, which is the soft one.** Those are the published
figures at this depth, and for two of the three we cannot tell whether
speculative decoding was on. EngramHalo's 14.3 s is explicitly its
non-speculative number; its speculative rate at 32K is not published, and
interpolating its own curve suggests something nearer 9 s. Hand every
competitor its best plausible speculative decode and the totals still land
around 110 s against our 31.1 s. The prefill column is the one carrying the
claim, and it has no such ambiguity.

At temperature 0, output is byte-identical to serial greedy decode.
Speculation here is a pure speed optimization, verified on every release, not
a quality trade.

```bash
podman run --rm -p 8731:8731 \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --security-opt seccomp=unconfined --ipc=host --ulimit memlock=-1:-1 \
  -e HALOGEN_DOWNLOAD=peonist-ai/halogen-qwen3.8-flash-next \
  -v ~/halogen-models:/models \
  ghcr.io/peonist-ai/halogen-flash-server:0.4.2
```

That is the whole thing. It fetches the weights on first start (118 GiB, so
give it a while; the transfer resumes if interrupted) and serves an
OpenAI-compatible endpoint on `:8731`, reachable from your network.

Note the models volume is read-**write** here, with no `:ro`, because it is
being downloaded into. Nothing is fetched on later starts, and with
`HALOGEN_DOWNLOAD` unset the container opens no outbound connections at all.

**If you would rather fetch the weights yourself:**

```bash
hf download peonist-ai/halogen-qwen3.8-flash-next --local-dir ~/halogen-models

podman run --rm -p 8731:8731 \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --security-opt seccomp=unconfined --ipc=host --ulimit memlock=-1:-1 \
  -v ~/halogen-models:/models:ro \
  ghcr.io/peonist-ai/halogen-flash-server:0.4.2
```

The weights repo carries the tokenizer, so one `-v` is all either form needs.
On Docker rather than Podman, replace `--group-add keep-groups` with
`--group-add video --group-add render`: `keep-groups` is a Podman extension.

**Sampling.** `temperature`, `top_p`, `top_k`, `min_p`, `seed`,
`presence_penalty`, `frequency_penalty`, `logit_bias` and `logprobs` are
supported. `temperature` absent or 0 is greedy decode. Above 0, the request
samples from the filtered distribution on the same drafter it would otherwise
get, so speculation stays on. A `seed` reproduces a request on the same server
configuration. `top_logprobs`, `logprobs` with `stream: true` and `n > 1` are
not implemented and are refused with a 400, as is any value outside its defined
range, rather than clamped. `/health` lists what the running build supports.

### Codex and the Responses API

The server also speaks the **OpenAI Responses API** at `POST /v1/responses`, so
clients that dropped Chat Completions can use it directly. The OpenAI Codex CLI
is the reason it exists: point it at this server and it works, including tool
calls.

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

Streaming and non-streaming both work, `function_call` and
`function_call_output` round trip, and `tools` entries that are not functions
(`web_search`, and the `namespace` wrapper, whose nested functions are used)
are ignored rather than rejected. `instructions` and any `developer` turns are
folded into the system prompt.

Two things it does not do. **Reasoning is not returned**: the model thinks
before it answers, but the Responses API carries reasoning as an encrypted item
the client hands back on the next turn, and this server does not store
anything, so a reasoning summary would be invented rather than real. The answer
is unaffected. **There is no response store**, so `previous_response_id`,
retrieving a response by id, and cancelling one are not available; send the
history with each request, which is what Codex does.

Verified against the Codex CLI driving real tasks end to end, and separately
against the official `openai` Python SDK, which parses every event into its own
typed models.

**The token budget covers thinking, not just the answer.** This model reasons
before it replies and those tokens count against the budget, so a budget that
runs out mid-thought does not shorten the answer, it removes it: the reply comes
back with `finish_reason: "length"`, an empty `content`, and the partial
reasoning in `reasoning_content`, which most OpenAI clients do not display.

The default is **8192**, which finished every ordinary prompt we measured with
room to spare. Send more when you want more, up to `HALOGEN_MAX_TOKENS_CAP`
(**65536** by default); above the cap you get a 400 rather than a silent
truncation, so ask for what you need and the server will tell you if it is too
much. Hard reasoning problems can genuinely exceed 8192: pass a larger budget,
or `"reasoning_effort": "low"` to make the model think less. Accepted efforts
are `minimal`, `low`, `medium`, `high` and `xhigh`; the model's own default is
`xhigh`.

**Any of three field names works**, and they mean the same thing here:
`max_completion_tokens` (current OpenAI Chat Completions), `max_output_tokens`
(OpenAI Responses), or `max_tokens` (deprecated upstream, still widely sent).
Send one, or send several as long as they agree; two different values is a 400
rather than a guess about which you meant. `/health` lists all three under
`token_budget_aliases` and reports the current default as `max_tokens_default`.

```json
{
  "model": "halogen-qwen3.8-flash-next",
  "messages": [{"role": "user", "content": "..."}],
  "max_completion_tokens": 16384,
  "reasoning_effort": "low"
}
```

If a reply looks empty or cut off, read `finish_reason` first: `"stop"` means
you have the whole answer, `"length"` means you ran out of budget.

---

## Measured

**Conditions, because they change the numbers:** AMD Ryzen AI Max+ 395
(Radeon 8060S, gfx1151), 128 GB unified memory, ROCm 7.14.0. The shipped
checkpoint and its quality sidecar, in the image's default configuration:
full 262,144 context, prompt cache on, tuned GEMM plan loaded. Prefill is a cold single-call prefill of real text;
decode is greedy at temperature 0. Prefill is measured by the engine's own
prefill bench; a served request with the default speculative drafter pays about
2-3% more time-to-first-token, because the draft head prefills too. The prefill
and decode rows are 0.2.0's measurements: 0.3.0 changed the scheduler and the
memory layout, not the kernels, and a same-session check of the two images at
the engine's protocol read the same decode rates within 1 tok/s.

| | halogen-flash 0.3.0 |
|---|---|
| prefill @ 8,192 | **~1,175 tok/s** (TTFT 7.0 s) |
| prefill @ 32,768 | **~1,309 tok/s** (TTFT 25.0 s) |
| prefill @ 131,072 | **1,256 tok/s** (104.4 s) |
| follow-up turn at 100,000 tokens of context | **~2 s** (prompt cache on, the default) |
| decode, serial greedy @ ctx 1,500 | **37.6 tok/s** |
| decode, serial greedy @ ctx 8,000 | **36.1 tok/s** |
| decode, serial greedy @ ctx 32,768 | **34.1 tok/s** |
| decode, MTP speculation @ ctx 1,500 | **42.4 tok/s** prose, **48.3 tok/s** code |
| decode, MTP speculation @ ctx 32,768, served | **41.7 tok/s** mean over ten prompts |

Decode barely moves with depth. Serial gives up about 7% going from 1,500 to
32,768 tokens of context, a 22x increase. The 32,768 served figure is the one
to compare against other runtimes' depth curves, and it is measured through the
full HTTP stack rather than on a raw token fixture, which is the harder
condition.

Two levers move these and both are one environment variable:

- **A tuned GEMM plan ships in the image and is on by default.** The matrix
  library exposes many kernels per shape, and the image carries choices
  measured on this hardware rather than picking at runtime
  (`HALOGEN_MATMUL_TUNING_FILE`). It costs nothing in quality: paired
  perplexity over 32,767 positions differs by 0.0006 nats, a confidence
  interval spanning zero. It is also *deterministic*, since every process
  reads the same decisions, so the same prompt keeps giving the same answer.
- **The prompt cache is ON by default**, which is what makes the native context
  usable in practice. A session whose prompt grows, whether an agent, a chat, or a
  document you keep asking about, does not re-read its shared prefix. Only the
  tokens you actually added get processed:

  | | first turn | every turn after |
  |---|---|---|
  | 100,000-token conversation | ~88 s | **~2 s** |
  | 10,000-token conversation | ~9 s | **~1.4 s** |

  The follow-up cost is **flat**. It does not grow as the conversation does,
  because it depends on how much you added, not on how much is already there.
  Measured over a 20-turn session growing to 108,000 tokens, every turn after
  the first landed between 2.0 and 2.3 s. See
  [Choosing a cache mode](#choosing-a-cache-mode) for when to change it.

### Against the alternatives

Three other runtimes publish figures for this model on this hardware. All are
llama.cpp derivatives or forks of one.

| prefill, tok/s | CIRU-IU4 | ROCmFP4 | EngramHalo | **halogen-flash** | vs best |
|---|---|---|---|---|---|
| @ 8,192 | 373 | 385 | 436 | **1,175** | **2.7x** |
| @ 32,768 | 228 | 313 | 316 | **1,309** | **4.1x** |
| @ 131,072 | 121 | 196 | 174 | **1,256** | **6.4x** |

**The shape matters more than the ratio.** Every one of them decays hard with
depth. Ours does not: 1,175 at 8K, 1,309 at 32K, 1,256 at 131K. Their own documentation puts it plainly enough. A 156K
prompt takes EngramHalo about twelve minutes. We prefill 131K in 104 seconds.

Decode is the closer row. Against the fastest of them we are roughly 1.2x on
code and 1.7x on prose at short context, and the comparison at depth is muddied
by their speculative numbers mostly not being published.

**These are published figures, not a head-to-head we ran.** Every number in
the competitor columns is from their own model card or repository, on their
machine, at their quantization and their settings. We have not run their
builds. Their conditions differ from ours in ways that matter: EngramHalo
measures on a 96 GB machine rather than 128 GB, runs a q8_0 KV cache, and
keeps the model's 26.8 GiB n-gram table on SSD. Treat the prefill gap as real
and the decode rows as indicative.

## Quality: what is measured, and what is not

Speed claims are cheap. These are the checks behind them.

**Token-for-token against `transformers`.** Six real prompts, 32 greedy steps
each, teacher-forced against goldens dumped from HuggingFace `transformers`
running the original BF16 weights: **182 of 192 steps identical**, two of the
six prompts perfect. That figure is END-TO-END. It includes everything 4-bit
quantization costs, not only the engine. The engine's own share is measured
separately, against a reference run on the *same dequantized weights*, and is
the smaller half.

**Perplexity at corpus scale.** Three 32k-token corpora, scored per position
and compared paired between arms. Measuring each tensor family against its own
BF16 ceiling located nearly all of the non-expert quantization cost in twelve
`o_proj` tensors; at the shipped precision those twelve measure as a
*statistical tie* with that ceiling. The rest of the trunk still has a little
left in it, and the experts have not been probed this way at all.

**Long context, the 10 to 32k band.** A needle-in-a-haystack battery: a synthetic
fact is spliced into filler at a known token position, the document continues
into a sentence whose next words are that fact, greedy decode, exact string
match. Three needles x five insertion positions x two filler corpora x five
depths from 1,024 to 32,768 tokens.

| depth | retrieved |
|---|---|
| 1,024 *(control)* | 30/30 |
| 4,096 | 30/30 |
| 8,192 | 30/30 |
| 16,384 | 28/30 |
| 32,768 | 30/30 |
| **total** | **148/150 = 98.7%** |

The two misses confabulate a plausible-looking code rather than trailing off.
The test can fail, and does. The 1,024 depth is the control: below the
attention selection budget the sparse path is not engaged, so it exercises the
same dense attention the fixture gate already covers. Every depth above it runs
block selection live, which no short fixture can reach.

This is the first quality measurement this project has in the band its prefill
numbers are about. It is a retrieval test and not a general one: it says the
model finds a fact it was given, not that its reasoning holds at depth.

**Identity properties, gated on every build.** The first two hold whatever
your configuration; the third depends on one setting.

- At temperature 0, speculative decoding emits **byte-identical tokens** to
  serial greedy decode. The draft head only proposes; a token is emitted only
  if the full model would have produced it. It is speed with no quality cost.
  When sampling, the accept/reject rule emits exactly the requested
  distribution; a seed reproduces a request on the same drafter.
- A request batched alongside others emits **byte-identical tokens** to the
  same request run alone.
- A prompt-cache hit answers **byte-identically** to a cold run of the same
  prompt, *under `HALOGEN_PROMPT_CACHE=1`*, which is the setting to choose
  when you need that guarantee. The default cache mode trades it for speed at
  every prompt length; [Choosing a cache mode](#choosing-a-cache-mode) has the
  numbers on what that trade actually costs.

**What is not measured.** We have never run the model at BF16. It does not
fit in 124 GB, which is the whole reason this engine exists, so every quality
number is against either a dequantized-weight reference or our own arms, never
against the full-precision model at scale. Quality comparisons against other
runtimes are not possible: their instruments differ from ours and neither of us
has the BF16 baseline.

---

## Precision: what you get, and how to trade it

**You are running the quality build by default.** There is nothing to enable.

The checkpoint ships as two files, and the engine picks the second one up on
its own when it sits beside the first:

```
qwen38-flash-next-w4b.hgn              115.55 GiB   the checkpoint
qwen38-flash-next-w4b.overlay.hgn        2.31 GiB   the quality sidecar
```

One `hf download` gets both, so this is a fact about the files rather than a
step you have to take. The server says which precision it loaded at startup,
and warns if the sidecar is missing rather than quietly serving something
worse.

The sidecar is a patch overlay: 723 tensors re-quantized against measured
activation statistics, plus twelve `o_proj` tensors promoted to 8 bits, read in
place of the base file's copies. It costs **0.09 GB net**, because it is not
adding weight, it is spending the same bits better. Measuring each tensor
family against its own BF16 ceiling put nearly all of the non-expert
quantization cost in those twelve tensors, 106 MB of a 115 GiB file. At 8 bits
they measure as a statistical tie with that ceiling.

**To trade quality for speed**, point `HALOGEN_CK_OVERLAY` at the speed arm:

```
-e HALOGEN_CK_OVERLAY=/models/qwen38-flash-next-w4b.overlay-speed.hgn
```

That is the same re-quantization without the 8-bit promotion. It buys back
about 2% of serial decode and gives up the calibration those twelve tensors
carry. Setting it to `none` runs the bare 4-bit checkpoint, which costs about
6-9% perplexity and is the measurement control rather than a serving
configuration.

4-bit weights are a **correctness precondition, not an optimization**: 125B
parameters plus a 51B-parameter n-gram embedding table is 335 GiB at BF16 and
173 GiB at FP8, against 124 GB of unified memory.

---

## Configuration

Full list in [`docs/FLAGS.md`](docs/FLAGS.md). The ones that matter:

| variable | default | what it does |
|---|---|---|
| `HALOGEN_API_PORT` | `8731` | The published port. Change it *and* the `-p` mapping together: `-e HALOGEN_API_PORT=9000 -p 9000:9000`. |
| `HALOGEN_PORT` | `8730` | The engine's own port, inside the container. **The engine protocol has no authentication**; keep it unpublished. |
| `HALOGEN_BIND` | `127.0.0.1` | Engine bind address. Loopback when engine and API share a container; `0.0.0.0` only for the split topology, where it stays unpublished. |
| `HALOGEN_CTX` | `262144` | The most one request may use, the model's full native context. Since 0.3 this bounds a **request**, not the allocation. |
| `HALOGEN_KV_POOL_POSITIONS` | `2 x HALOGEN_CTX` | **The memory knob.** Positions resident across all conversations, about 29.5 KiB each. [See below](#context-and-memory-one-kv-pool-several-conversations). |
| `HALOGEN_KV_SLOTS` | `4` | Conversations generating at once. A slot costs about 115 MB of its own state; **it is not the memory knob** since 0.3, the pool above is. |
| `HALOGEN_PROMPT_CACHE` | `2` | Session prefix reuse. On by default. `1` for byte-identical repeat answers, `0` for off. [See below](#choosing-a-cache-mode). |
| `HALOGEN_MATMUL_TUNING_FILE` | **baked into the image** | A tuned GEMM plan, on by default, at no measured quality cost. The published prefill numbers include it. |
| `HALOGEN_CK_OVERLAY` | **the quality sidecar** | You get quality by default. `…overlay-speed.hgn` trades the calibration for about 2% decode, `none` runs the bare checkpoint. [See above](#precision-what-you-get-and-how-to-trade-it). |
| `HALOGEN_MODEL_ID` | `halogen-qwen3.8-flash-next` | The id at `/v1/models` and in every response. |
| `HALOGEN_DOWNLOAD` | unset | Fetch weights on first start. Off by default, which is what keeps the container free of all outbound connections. |

### Choosing a cache mode

When a conversation continues, the server can either re-read the whole
conversation from the start or pick up where it left off. `HALOGEN_PROMPT_CACHE`
decides which, and there are three settings.

| | what it does | follow-up turn at 100k | repeat answers identical? |
|---|---|---|---|
| **`2`** *(default)* | Saves its place at the end of every request | **~2 s** | no |
| `1` | Saves its place only at fixed checkpoints | ~17 s typical, ~32 s worst | **yes** |
| `0` | Never saves its place | ~88 s | yes |

The follow-up figures are measured over a 20-turn conversation growing from
90,000 to 108,000 tokens, adding about 1,000 tokens a turn.

**Use the default (`2`) for chat and agents**, anything where one conversation
gets longer. It is the only setting that helps short conversations: at the
shipped configuration, mode `1` saves nothing at all until a conversation passes
32,768 tokens, so ordinary chat gets no benefit from it. The default has no such
threshold; it starts working on the second turn, whatever the length. The first
turn costs about 1% more, which is the price of saving the state.

**Use `1` when you need the same prompt to always give the same answer**:
evaluation suites, regression tests, A/B comparisons, or anything audited. With
`1`, an answer served from the cache is byte-for-byte what a cold run would have
produced. With the default it usually is, but not always.

Worth knowing what "not always" means, because it is smaller than it sounds.
The difference only appears where the model was already close to a coin flip
between two words. Across a battery of tests: the next word was identical in 9
of 9 single-resume tests, and differed 3 times across 38 resumed turns, every
one of those three at a point where the model's top two candidates were within
a rounding error of each other. On a 240-question fact-retrieval test the
resumed server scored 236 against a cold server's 238, and in chat format
specifically both scored 100%.

For proportion: the server already splits long prompts into chunks to fit them
in memory, and simply changing where it splits moves the output *slightly more*
than resuming from a cache does. Exact reproducibility across configuration
changes was never on offer; mode `1` guarantees it across cache state, which is
a narrower and more useful promise than it first appears.

**Use `0` for many short unrelated prompts.** Nothing is shared between them, so
saving state is pure overhead.

**One case where `1` genuinely wins on speed:** one long shared prefix followed
by many *different short* questions, such as a fixed system prompt or document asked
about repeatedly from scratch. Mode `1` checkpoints at a fixed position all of
those questions can resume from. The default saves its place at the end of each
request and cannot rewind, so it misses. If that is your workload, `1` is both
faster and stricter.

### Context and memory: one KV pool, several conversations

The server admits the model's **full native 262,144-token context** per
request by default, keeps **two full-length conversations resident**, and
generates for **four at once**. Two settings
that used to be one: `HALOGEN_CTX` is the most a single request may use, and
`HALOGEN_KV_POOL_POSITIONS` is how many attention positions are resident
across all conversations. The four slots share that pool rather than each
owning a copy, so a slot adds only about 115 MB of its own state and the pool
is what has to fit on the device. Attention state costs about 28 KiB per
position including its scratch. Measured on a 128 GB machine:

| pool | holds at once | device memory | measured |
|---|---|---|---|
| 262,144 | one full conversation, or four at 65k | 27.8 GB | 0.2.0's layout |
| **524,288 (default)** | **two full conversations, or four at 131k** | **35.0 GB** | **starts and serves; the 0.3.1 default** |
| 786,432 | three full conversations, or four at 196k | 42.2 GB | three 250k conversations resident and generating, memory flat. **0.3.0's default, and too close to the ceiling on some machines** |
| 1,048,576 | four full conversations, or eight at 131k | ~41 GB with `HALOGEN_MAX_TOK=16384` | the 1M configuration's layout; ~49 GB at the default arena, which does not start |

A request reserves its prompt plus `max_tokens` positions when it is admitted
(the chat default budget is 8,192 tokens, so a 30,000-token conversation
reserves about 38,000) and waits in arrival order when the pool cannot hold it
yet. Each stream's tokens are byte-identical to the same request run alone.
Generation speed follows a conversation's own length, not the pool: a short
chat in a 1M-position pool runs at short-chat speed, and three conversations
at 250k each generate at about 17 tokens per second apiece.

One cost the pool does carry. A larger pool leaves less RAM for the model's
file cache, so the first prompt after a restart can take longer to read in
(measured: a 32,000-token prompt took up to twice its usual 25 s right after a
fresh start, and its usual time once it had been seen). The default trades some
of that for a second resident conversation; `HALOGEN_KV_POOL_POSITIONS=262144`
trades back, and `786432` buys a third conversation where the machine has the
headroom for it.

**Speed by concurrency.** Measured at the engine's own protocol on the
published image at its defaults (the 8-stream row with `HALOGEN_KV_SLOTS=8`):
1,500-token prompts of prose, 600 tokens generated each, greedy, rates over
the window in which every stream is generating. The one-stream rows are the
same measurement, so the rows compare; the reproducible one-stream figure is
the built-in `bench` below.

| streams generating | total tokens/s | per stream | byte-identical to alone |
|---|---|---|---|
| 1, speculative (the default) | 41.3 | 41.3 | yes |
| 1, serial | 36.5 | 36.5 | |
| 2 | 55.2 | 27.5 to 27.6 | 2 of 2 |
| 4 | 74.8 | 18.6 to 18.7 | 4 of 4 |
| 8 | 87.8 | 10.9 to 11.0 | 8 of 8 |

**Slots are a latency policy, not a memory decision.** Raising
`HALOGEN_KV_SLOTS` past four trades what each client sees for admitting more
clients at once instead of queueing them; past eight the total stops growing.
Four is the default because it keeps per-stream speed where the numbers in
this document were measured.

Two other things the scheduler does for you. A prompt that arrives while other
conversations are generating is read in pieces with a generation step for the
others between pieces. The piece is the prefill call size (`HALOGEN_MAX_TOK`,
32,768 tokens), which is exactly how the same prompt is split when it runs
alone, so its answer stays byte-identical: a 131k prompt pauses the others
three times for about 28 s each instead of once for 105 s. `HALOGEN_MAX_TOK=16384`
halves the pause for everyone at about 8% slower prefill. `HALOGEN_ADMIT_CHUNK=8192`
makes the pause about 8 s and costs the admitted prompt about 5 s on its first
token, and that prompt's answer then depends on the load when it arrived, which
is the one setting here that gives up the identity property. And the speculative
drafter, which is the default, speculates while it is the only conversation
generating and joins the batch as soon as another one is active, so it never
holds the others back.

The prompt cache keeps eight entries (`HALOGEN_CACHE_ENTRIES`), two per
conversation: one at the end of its system prompt and one at the end of its
history. Conversations taking turns each resume from their own state, and
requests that share a system prompt and ask different things, together or in
turn, resume from it as well. The server prints the memory budget at startup
and warns before the allocator refuses.

`HALOGEN_MAX_TOK` (default 32,768, capped at the context) is the widest single
prefill call, which sizes a ~4 GB scratch arena. Longer prompts are prefilled
in pieces. Do not raise it to the native context. That allocation does not
fit, and the server will not start.

### 1M context: opt-in, and a different configuration

The model card extends the native 262,144 to 1M by static YaRN (factor 4),
and this server implements it. It is off unless you ask:

```
HALOGEN_ROPE_YARN=4 HALOGEN_CTX=1048576
```

Unset, nothing changes. Set, it is a different model configuration, not a
cache setting: every position's RoPE is rescaled, short prompts included, and
the card advises it only when the context needs it. What it costs, measured
on the same machine as the table above:

- **Quality at 1k-32k:** perplexity +0.4-0.6% on three corpora (most of it
  above 8k positions); the 240-case retrieval battery reads 236/240 against
  238/240 unscaled, with the chat register at 100% at every depth in both.
- **Speculative decode at 8k-30k context** accepts 5-15 points fewer drafts,
  about 10% slower than unscaled.
- **Above 32k:** needle retrieval, chat register, three needles at three
  positions: 9/9 at 262,144 unscaled, 9/9 at 262,144 scaled,
  9/9 at 1,000,000.
- **Memory:** a 1M KV cache is ~25 GB, which on a 128 GB machine leaves no
  room for the default prefill arena. Past the native context the server
  therefore caps `HALOGEN_MAX_TOK` at 16384 (prefill about 9% slower) and
  prints it. A 1,000,000-token prompt prefills in 22-24 minutes (~700-770
  tok/s) and decodes at 19 tok/s serial, 25 with the default speculative
  drafter. The conversation then continues at ordinary speed: the prompt
  cache keeps the attention state in place and saves only its small
  position-free part, so a follow-up turn at 1,000,000 tokens reached its
  first token in 0.55 s on the test machine (0.45 s at 262,144), against
  22-24 minutes cold. A 262,144-token prompt decodes at ~28. The context
  must leave room for the generation: a prompt at exactly the context is
  refused.

### Served throughput, end to end over HTTP

The numbers above are the engine's own prefill bench. Through the full stack of
chat template, tokenizer, HTTP and SSE, the image's own `sweep` mode measures
**812 tok/s at pp2048 and 1,041 at pp8192**, and `bench` over ten real prompt
shapes measures **43.6 tok/s mean with speculation** on the 0.3.0 image (min
38.5 on chat, max 48.1 on procedural text; 1.63 tokens committed per round;
the 0.2.0 image read 44.4 in the same session, inside the run-to-run spread).
Acceptance depends on how predictable the text is, so quote the mean with the
prompt set named, never a single shape.

That run also re-checks the identity property on live traffic: **every drafter
produced byte-identical output on every case.**

Reproduce the numbers with the benchmarks baked into the image:

```bash
podman run ... ghcr.io/peonist-ai/halogen-flash-server:0.4.2 bench serial,mtp 256 low 3
podman run ... ghcr.io/peonist-ai/halogen-flash-server:0.4.2 sweep -p 8192,32768 -n 128
```

---

### If the server will not start: "out of memory"

A start that ends in

```
dmalloc: FAILED requesting 0.750 GiB after 39.703 GiB in 647 allocations (out of memory)
HIP /src/halogen/src/flash_ops.h:122: out of memory
```

means the KV pool did not fit on this machine. **`HALOGEN_KV_SLOTS` will not
fix it** and is the first thing most people try: since 0.3 the slots share one
pool and each costs only about 115 MB, so one slot allocates as much as four.
The knob is the pool:

```
-e HALOGEN_KV_POOL_POSITIONS=262144
```

That is 27.8 GB, the same layout 0.2.0 ran, and it still serves four
conversations at once. `524288` is 35.0 GB and is the default. If it still
will not start, halve the prefill arena as well with `-e HALOGEN_MAX_TOK=16384`,
which costs about 9% of prefill speed.

### If the server starts but crawls on long prompts

A server that starts, answers short prompts, and then collapses to a few
tokens per second on a long one, with the disk busy and the process stuck in
uninterruptible sleep, is short of file cache rather than short of memory.
The model keeps a large lookup table on disk and reads it through the page
cache instead of holding it in RAM, so RAM the KV pool takes is RAM that
table loses, and a longer prompt touches more of it. The same setting fixes
it:

```
-e HALOGEN_KV_POOL_POSITIONS=262144
```

`HALOGEN_HOST_RESERVE_GIB` (default 20) is how much RAM the server leaves
free for that cache when it sizes the pool at startup; raising it makes the
server choose a smaller pool on its own.

Device memory here is system memory, and the ceiling is set by the kernel's
resident-memory limit rather than by anything a driver reports: measured at
about 47 GB on a 128 GB machine, and lower on machines carrying more besides
this server. From 0.3.1 the server measures that budget at startup and lowers
the pool itself when the configured one will not fit, printing what it chose;
`HALOGEN_KV_POOL_FIT=0` turns that off and allocates exactly what was asked
for. `HALOGEN_DMALLOC_LOG=1` prints every allocation over 64 MB with a running
total, which is this configuration's memory budget measured rather than
estimated, and `HALOGEN_VERBOSE=1` turns on the fullest startup account the
server can give. Both are off by default and both are useful to attach to a
report. The two lines worth sending on their own are:

```
docker logs <container> 2>&1 | grep -E '^(dmalloc|kv pool):'
```

## What this release is not

- **Four conversations, not forty.** The slot count is fixed at startup
  (`HALOGEN_KV_SLOTS`, up to 64) and a request waits for a free slot and for
  room in the pool; there is no preemption and no paging. Throughput past four
  streams grows slowly.
- **Speculation is for a conversation on its own.** With two or more
  conversations generating, every stream takes a batched step; the drafter
  resumes when a stream is alone again. Speculating inside a batch was measured
  to pay only for exactly two code-heavy streams and is not built.
- **No response store.** `/v1/responses` generates and streams; it does not
  keep responses, so `previous_response_id`, retrieval by id and cancellation
  are not available, and reasoning is not returned to the client.
- **One GPU, one model family.** gfx1151 only. The build hard-rejects other
  architectures.

## License

The engine is distributed under the terms in [LICENSE.md](LICENSE.md).
Third-party components and their licenses are listed in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). Model weights are licensed
separately by their original authors.
