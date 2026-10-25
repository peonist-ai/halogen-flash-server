# Configuration

Full list in [`docs/FLAGS.md`](FLAGS.md). The ones that matter:

| variable | default | what it does |
|---|---|---|
| `HALOGEN_API_PORT` | `8731` | The published port. Change it *and* the `-p` mapping together: `-e HALOGEN_API_PORT=9000 -p 9000:9000`. |
| `HALOGEN_PORT` | `8730` | The engine's own port, inside the container. **The engine protocol has no authentication**; keep it unpublished. |
| `HALOGEN_BIND` | `127.0.0.1` | Engine bind address. Loopback when engine and API share a container; `0.0.0.0` only for the split topology, where it stays unpublished. |
| `HALOGEN_CTX` | `262144` | The most one request may use, the model's full native context. It bounds a **request**, not an allocation. |
| `HALOGEN_KV_POOL_POSITIONS` | `2 x HALOGEN_CTX` | **The memory knob.** Positions resident across all conversations, about 29.5 KiB each. [See below](#context-and-memory-one-kv-pool-several-conversations). |
| `HALOGEN_KV_SLOTS` | `4` | Conversations generating at once. A slot costs about 115 MB of its own state; **it is not the memory knob**; the pool is. |
| `HALOGEN_PROMPT_CACHE` | `2` | Session prefix reuse. On by default. `1` for byte-identical repeat answers, `0` for off. [See below](#choosing-a-cache-mode). |
| `HALOGEN_MATMUL_TUNING_FILE` | **baked into the image** | A tuned GEMM plan, on by default, at no measured quality cost. The published prefill numbers include it. |
| `HALOGEN_CK_OVERLAY` | **the quality sidecar** | You get quality by default. `…overlay-speed.hgn` trades the calibration for about 2% decode, `none` runs the bare checkpoint. [See above](precision.md#precision-what-you-get-and-how-to-trade-it). |
| `HALOGEN_MODEL_ID` | `halogen-qwen3.8-flash-next` | The id at `/v1/models` and in every response. |
| `HALOGEN_DOWNLOAD` | unset | Fetch weights on first start. Off by default, which is what keeps the container free of all outbound connections. |

## Choosing a cache mode

**Use the default (`2`) for chat and agents. Use `1` when a repeated prompt
must give a byte-identical answer. Use `0` for many short unrelated prompts.**

When a conversation continues, the server can either re-read the whole
conversation from the start or pick up where it left off.
`HALOGEN_PROMPT_CACHE` decides which:

| | what it does | follow-up turn at 100k | repeat answers identical? |
|---|---|---|---|
| **`2`** *(default)* | Saves its place at the end of the system prompt, at the start of the last message and at the end of every request | **~2 s** | no |
| `1` | Saves its place only at fixed checkpoints | ~17 s typical, ~32 s worst | **yes** |
| `0` | Never saves its place | ~88 s | yes |

The follow-up figures are measured over a 20-turn conversation growing from
90,000 to 108,000 tokens, adding about 1,000 tokens a turn.

**Why the default (`2`) for anything where one conversation gets longer.**
It is the only setting that helps short conversations: mode `1` saves nothing
at all until a conversation passes 32,768 tokens, so ordinary chat gets no
benefit from it. The default starts working on the second turn, whatever the
length. The first request on a new prompt costs a little more than with the
cache off: about 1 to 2% of its prefill at any length (a fixed 0.15 s or so
on the reference machine, mostly the two saves themselves), paid once per new
prompt, never on a hit. To reproduce a cache-off benchmark figure, set
`HALOGEN_PROMPT_CACHE=0`: the default's first-request cost is what a
benchmark that sends every prompt once measures, and its second-turn saving
is what a conversation measures.

**Use `1` when you need the same prompt to always give the same answer**:
evaluation suites, regression tests, A/B comparisons, or anything audited.
With `1`, an answer served from the cache is byte-for-byte what a cold run
would have produced.

**Use `0` for many short unrelated prompts.** Nothing is shared between them,
so saving state is pure overhead.

> [!NOTE]
> **How much "not always" means under the default.** The difference only
> appears where the model was already close to a coin flip between two words:
> across a battery of tests the next word was identical in 9 of 9
> single-resume tests, and differed 3 times across 38 resumed turns, every
> one at a point where the top two candidates were within a rounding error.
> On a 240-question fact-retrieval test the resumed server scored 236
> against a cold server's 238, and in chat format specifically both scored
> 100%. And the server already splits long prompts into chunks to fit them in
> memory. Simply changing where it splits moves the output *slightly more*
> than resuming from a cache does. Exact reproducibility across configuration
> changes was never on offer; mode `1` guarantees it across cache state,
> which is a narrower and more useful promise than it first appears.

**A long document, then a different question each time.** The default also
saves its place at the **start of the last message** of the request, so a
client that keeps a document in one message and asks each new question in
the next (`[document][question 1]`, then `[document][question 2]`) resumes
from the end of the document: measured on a 30,000-token document, the
second question is served 99% from the cache and answers in 1.3 s where it
took 26 s cold. The extra save costs nothing measurable and nothing on a
hit; a request whose last message is its only message gets no third place.
`HALOGEN_CACHE_SNAP3=0` turns it off. Putting the document in the `system`
message also still works.

## Context and memory: one KV pool, several conversations

**`HALOGEN_KV_POOL_POSITIONS` is the memory knob; slots are a latency
policy.** The server admits the model's **full native 262,144-token
context** per request by default, keeps **two full-length conversations
resident**, and generates for **four at once**. `HALOGEN_CTX` is the most a
single request may use; `HALOGEN_KV_POOL_POSITIONS` is how many attention
positions are resident across all conversations. The slots share that pool
rather than each owning a copy, so a slot adds only about 115 MB of its own
state and the pool is what has to fit on the device. Attention state costs
about 28 KiB per position including its scratch. Device memory below is the
default checkpoint and four slots on a 128 GB machine:

| pool | holds at once | device memory | measured |
|---|---|---|---|
| 262,144 | one full conversation, or four at 65k | 19.8 GiB | |
| **524,288 (default)** | **two full conversations, or four at 131k** | **27.0 GiB** | **starts and serves** |
| 786,432 | three full conversations, or four at 196k | 34.2 GiB | three 250k conversations resident and generating, memory flat |
| 1,048,576 | four full conversations, or eight at 131k | 36.9 GiB with `HALOGEN_MAX_TOK=16384` | the 1M configuration's layout. At the default `MAX_TOK` it is 41.4 GiB, which a 128 GB machine fits only with a smaller `HALOGEN_HOST_RESERVE_GIB` (below) |
| 2,097,152 | eight full conversations | about 41 GiB with `HALOGEN_KV8=1` and `HALOGEN_MAX_TOK=16384` | eight 242k conversations resident, each answer identical to the request alone; not with 16-bit KV (about 58 GiB of pool), w4b, or NPU models beside it |

A request reserves its prompt plus `max_tokens` positions when it is
admitted (the chat default budget is 8,192 tokens, so a 30,000-token
conversation reserves about 38,000) and waits in arrival order when the pool
cannot hold it yet. Each stream's tokens are byte-identical to the same
request run alone. Generation speed follows a conversation's own length, not
the pool: a short chat in a 1M-position pool runs at short-chat speed, and
three conversations at 250k each generate at about 17 tokens per second
apiece.

**Check what pool you actually got.** The fit at startup budgets `MemTotal`
less the resident weights (62.1 GiB for the default checkpoint, 68.0 for w4b
and its sidecar, read from the checkpoint itself) and
`HALOGEN_HOST_RESERVE_GIB` (20). A 524,288 pool at `HALOGEN_MAX_TOK=32768`
needs about 29 GiB: 14.4 for the pool, 12.4 for the working memory and the
slots, and about 2 of margin, which also covers the vision tower's scratch. A
1,048,576 pool needs about 43.4 GiB at 32,768 and 39.0 at
`HALOGEN_MAX_TOK=16384`, so on a machine whose `MemTotal` reads 121 to
125 GiB the default checkpoint gets it at 16,384, and
`HALOGEN_HOST_RESERVE_GIB=18` gets it at 32,768 at the cost of that much
file cache. When the fit lowers the pool, the startup log says
`LOWERING THE POOL TO N`; it halves from what you asked for, so ask for
786,432 directly if three conversations is what you want. Every request line
ends with `pool N/<positions>`, so a grep settles it.

**Sizing for a fan-out harness** (a parent that runs subagents in parallel).
Every live conversation holds `prompt + max_tokens` between its turns, so the
pool must hold their sum: `pool >= sum over live conversations of (prompt +
max_tokens)`, with `max_tokens` the client's, not the server default, when
the client sends one. A subagent's prompt grows by the whole of each turn's
generation when the harness replays the reasoning into the next request (Pi
with `reasoning: true` does; the Qwen template keeps it), so a child that
thinks for 25k tokens a turn under a 32k budget grows by about 26k a turn: a
parent at 50k and two children at 80k each start at `82k + 112k + 112k = 306k`
and pass the default 524,288 by their fifth turn. When they do, a move
cannot help and one conversation is forgotten by the least-recently-used
rule; the log says which. The levers: the pool (`786432` holds that shape for
about four more turns, by which point the children are near the 262k context
in any case), the client's budget (a harness that uses 2k of 32k can send
8k), and fewer parallel subagents.

One cost the pool does carry: a larger pool leaves less RAM for the model's
file cache, so the first prompt after a restart reads its rows of the lookup
table from disk. Since 0.6.3 the rows are read 64 at a time: on this
machine's NVMe drive the first prompt costs about 1.3 s more than its usual
time, and an 8,000-token one under half a second. The log line
`lookup table: ... took N s on 64 threads` reports it whenever it takes 2 s
or more. `HALOGEN_KV_POOL_POSITIONS=262144` leaves more of the table cached;
`786432` buys a third resident conversation where the machine has the
headroom.

**Speed by concurrency.** Measured on the published 0.18.0 image over the
OpenAI-compatible API, in the conditions of [0.18.0, both
checkpoints](performance.md#0180-both-checkpoints), with `HALOGEN_KV_SLOTS=8`
so that all eight streams are admitted at once. Each stream has its own
short prompt and generates 384 tokens with thinking off; greedy streams
write code, sampled streams (temperature 0.7) write English prose. The
total counts every stream's tokens over the window in which all of them are
generating; the per-stream figure is the slowest stream's. Two runs each,
shown as a range where they differ.

| streams generating | v2 total, code (greedy) | v2 per stream | v2 total, prose (sampled) | ht43 total, code / prose |
|---|---|---|---|---|
| 1 | 70 to 72 tok/s | 70 to 72 | 55 to 58 tok/s | 69 / 51 to 54 |
| 2 | 81 tok/s | 40 | 71 to 75 tok/s | 77 to 79 / 71 to 73 |
| 4 | 84 to 85 tok/s | 21 | 82 tok/s | 83 / 81 |
| 8 | 107 to 108 tok/s | 13 | 105 to 106 tok/s | 106 / 104 |

Every stream emits byte-identical tokens to the same request run alone,
which is gated on every release (see the identity properties under
[Quality](quality.md#quality-what-is-measured-and-what-is-not)). One stream
alone drafts from both the draft head and the request's own text; two to
four streams generating together all draft with the head and one forward pass
checks every draft while that pays (three and four since 0.18.11), and decode
as a plain batch when it does not; at eight streams a batched step is the
cheapest way to get one token per stream on this hardware. (An earlier table, from 0.6.0 on the 0.14 checkpoint with
1,500-token prose prompts, read 41.3 / 55.2 / 74.8 / 87.8 tok/s at one / two
/ four / eight streams.) A request with a JSON schema decodes in the plain batch,
and the requests generating beside it then do too, so it never holds them
back. Prompt lookup drafts only for a conversation generating alone.

**Slots are a latency policy, not a memory decision.** Raising
`HALOGEN_KV_SLOTS` past four trades what each client sees for admitting more
clients at once instead of queueing them; past eight the total stops
growing. Four is the default because it keeps per-stream speed where the
numbers in this document were measured. Slots cap admission: a client past
the count queues rather than diluting the batch, so with five workers on
four slots each admitted stream still decodes at the four-stream rate and
the fifth waits. A reporter's sweep on a five-worker aider fleet (issue #51)
read the per-turn wall at 42 s on four slots against 46 on three and 52 on
two, and 14.9 t/s per stream on eight slots against 18.7 on four; for
reply-heavy, cache-hostile clients the default is the right setting even
when more slots would fit.

**Chunked admission.** A prompt that arrives while other conversations are
generating is read in pieces with a generation step for the others between
pieces. The piece is the prefill call size (`HALOGEN_MAX_TOK`, 32,768
tokens), which is exactly how the same prompt is split when it runs alone,
so its answer stays byte-identical: a 131k prompt pauses the others three
times for about 28 s each instead of once for 105 s.

| lever | effect |
|---|---|
| `HALOGEN_MAX_TOK=16384` | halves the pause for everyone at about 8% slower prefill |
| `HALOGEN_ADMIT_CHUNK=8192` | makes the pause about 8 s and costs the admitted prompt about 5 s on its first token; that prompt's answer then depends on the load when it arrived, the one setting here that gives up the identity property |

A short request that arrives during those pieces runs between two of them
instead of waiting for the whole prompt, and a request from a person goes
ahead of agent turns waiting in the queue (a request whose last message is a
tool result; an agent turn that has waited half a minute counts as a
person's). Neither changes any answer. A conversation that is already
generating still pauses while each piece is read.

**When the pool runs out of room,** the server tries, in order:

1. give up an **idle region** first: a conversation's own span counts as
   free, and its rows move into any span that holds them, overlap or not (the
   copy goes in block-aligned chunks in the safe direction; the log says
   `moved the N rows ... in 12.3 ms`);
2. when held neighbours are what stand in the way, move them up against the
   next busy region so the region **grows in place** (no loss, counted as
   `packed`);
3. **clamp** a follow-up whose region cannot grow to the room the region has
   left, when the room is at least the answer room (`max(1024, 15%)` of the
   request's `max_tokens`, twice that when the request thinks):
   `max_tokens 32768 -> 30521` in the log and in the response's `timings` as
   `max_tokens_clamped_from` / `max_tokens_clamped_to`, so a
   `finish_reason: "length"` on such a turn is legible;
4. **copy** the rows to a fresh span when the room is smaller than the answer
   room, or the conversation resumes from a region another request is
   decoding in; a held region whose longest entry the request resumes from
   is *moved* rather than copied and left behind, so a stale duplicate never
   competes for the pool;
5. only then **forget the least recently used conversation** and say so
   (`kv pool: no room for N positions; forgot the region at ...`). The entry
   the request is about to resume from is never the one forgotten, and a
   conversation whose only stale entries are dead side turns grows its own
   region in place rather than displacing another conversation.

A conversation keeps its whole reservation between turns, and its next turn
uses it. When nothing else is left to forget and the request still has no
span, the server moves that conversation's rows into the free span and the
turn stays a cache hit; when the rows cannot be copied there it forgets them
and the turn runs cold. A request that waits for a *busy* conversation to
retire says so once in the log, and `/cache` reports it under `pool`:
`waiting_for_room`, `waiting_s`, `relocated`, `cold_resorts`.

**What the pool leaves the host.** The engine prints, once loaded, how much
host RAM is left after the weights and the pool (`host memory left for
everything else`), and says under about 10 GiB what that means: the lookup
table is read from disk through the page cache and never held, so that figure
is the cache it gets, and below it the table's rows page in on every long
prompt, a prefill takes minutes instead of seconds, and the watchdog can
read the stall as a wedge. A reporter's measurements on a 128 GB machine
with other services resident (issue #35), the pool the only change:

| `HALOGEN_KV_POOL_POSITIONS` | 786,432 | 524,288 |
|---|---|---|
| host RAM left | 5.6 GiB | 12.7 GiB |
| free contiguous 2 MiB blocks | 210 | 2,776 |
| startup to "engine listening" | 38 s | 10 s |

and on identical warm turns (a ~1,425-token prompt, 1,277 cached) before and
after that change:

| | 786,432 | 524,288 |
|---|---|---|
| decode, median | 24.8 t/s | 39.4 t/s |
| decode, min to max | 13.8 to 38.9 t/s | 33.5 to 41.1 t/s |
| prefill, median | 6.69 s | 1.51 s |
| prefill, min to max | 1.50 to 39.88 s | 1.46 to 5.92 s |

The machine this document's numbers come from runs the default pool at about
12 GiB left and does not page; the line between the two rows above is where
the note fires. `HALOGEN_KV_POOL_POSITIONS` and `HALOGEN_MAX_TOK` are the two
levers; stopping other resident workloads is the third.

`HALOGEN_MAX_TOK` (default 32,768, capped at the context) is the widest
single prefill call, and it sizes the working memory the server holds beside
the pool. The startup line's `working memory` reads **12.6 GiB at 32,768 and
8.1 GiB at 16,384** on the default checkpoint, and 12.5 and 11.0 with w4b,
whose experts keep about 6 GiB of scratch at any setting. Halving it gives
back about 4.4 GiB on the default checkpoint for about 9% of prefill speed,
a long prompt read in more pieces, and the answer byte-identical. It was the
lever on a shared machine whose pool could not go lower without cutting what
one request may use (issue #35, two boxes, both already auto-lowered to one
full conversation of pool):

| | before | after |
|---|---|---|
| `HALOGEN_MAX_TOK` | 32,768 | 16,384 |
| pool | 262,144 (auto-lowered) | 393,216 (set) |
| working memory | 21.3 GiB | 12.5 GiB |
| host memory left | 11.8 / 16.1 GiB | 17.1 / 20.5 GiB |
| free contiguous 2 MiB blocks | 79 / 123 | 823 / 1,136 |
| compaction stalls reserving the pool | 194 (194 failed) / none | 0 / 0 |
| startup to "engine listening" | 97 s / 50 s | 18 s / 7 s |

Longer prompts are prefilled in pieces. **Do not raise
it to the native context:** that allocation does not fit, and the server will
not start.

**Cache entries.** The prompt cache keeps twenty-four entries
(`HALOGEN_CACHE_ENTRIES`), six per conversation: one at the end of its system
prompt, three at points in its history (the ends of earlier requests, and the
start of the last message), and one at the end of its last request, which
serves an exact repeat of that request without reading anything again
(`HALOGEN_CACHE_FULL=0` turns that one off). A conversation holds a fixed
number of entries: a new turn's history entry replaces an older one rather
than adding to the list, so a long tool-calling session cannot push other
sessions out (the count shows as `superseded` on `/cache`). It keeps the
most recently *used* history entries, not the newest: a harness that sends
the whole history plus a side question (an idle recap, say) and then drops
that turn continues from where the side turn branched. Conversations taking
turns each resume from their own state, and requests that share a system
prompt and ask different things resume from it as well.

| lever | when |
|---|---|
| raise `HALOGEN_CACHE_ENTRIES` by one conversation's worth (about 115 MiB of host RAM per entry, and the KV rows an entry covers stay reserved while it exists) for each extra deep conversation | more than four deep conversations at once; a value too small to hold one conversation's worth per slot says so at startup |
| raise `HALOGEN_CACHE_BRANCHES` (two by default: a conversation plus one side turn) | a **fan-out**: one parent forked into several children living in the same region; at two, the parent's resume point is the one the children's stores replace |

The server prints the memory budget at startup and warns before the
allocator refuses.

## Prompt cache on disk: resume a conversation after a restart

By default the prompt cache lives in memory: a restart loses it, and the next
turn re-reads the whole conversation. Point `HALOGEN_CACHE_DIR` at a
directory and the cache also lands on disk, so a conversation survives a
restart:

```
HALOGEN_CACHE_DIR=/cache
```

Each turn, the server writes only that turn's new attention rows behind the
request (nothing on the request's own path waits for it), and a request that
is no longer in memory is restored from disk instead of re-read. On the test
machine a 32k-token conversation, its server stopped and started, reached its
first token in a few seconds against about 40 seconds of cold prefill.

What it stores is about 27 KiB per token of context: 0.9 GB at 32k, 2.7 GB at
100k, 7.2 GB at 262k. `HALOGEN_CACHE_DISK_GIB` bounds the directory (default
64; the least recently used conversations are removed first; `0` is
unbounded). The directory must be on a real filesystem that accepts direct
I/O; a tmpfs or an overlay is refused with a message, and the cache stays in
memory only.

> [!NOTE]
> Two things worth knowing:
>
> - **It is exact.** A conversation restored from disk continues from the
>   same attention state it was saved with, byte for byte across the restart;
>   it is the same "resume anywhere" cache as in memory, not a re-read.
> - **The write rate falls as the pool fills.** Saving a turn's rows copies
>   them out of device memory, and near the memory ceiling that copy slows
>   (from several GB/s when the pool is a third full to a few hundred MB/s
>   when it is near the top). The write does not slow the answer, but a
>   machine that keeps very long conversations (past ~64k tokens) warm across
>   restarts should shrink the resident pool with
>   `HALOGEN_KV_POOL_POSITIONS=262144`, which keeps the copy at the drive's
>   rate.

Each distinct configuration (engine build, weights file, context, and every
setting that changes the saved bytes) keeps its own subtree of the
directory, so a different build or setting never restores another's state,
and the bound above applies to the current subtree only. An upgrade leaves
the previous build's subtree behind, readable by nothing but that build; the
startup log counts them (`N other configuration(s) hold X GiB there`).
`HALOGEN_CACHE_PRUNE_OLD=1` removes them at startup and names each one with
its size; the default keeps them so a rollback finds its cache warm.
Stopping the server flushes the last turn before it exits, so give it a
moment to stop (the bundled compose sets a 60-second stop grace period).

## 1M context: opt-in, and a different configuration

The model card extends the native 262,144 to 1M by static YaRN (factor 4),
and this server implements it. It is off unless you ask:

```
HALOGEN_ROPE_YARN=4 HALOGEN_CTX=1048576
```

Unset, nothing changes. Set, it is a **different model configuration**, not a
cache setting: every position's RoPE is rescaled, short prompts included, and
the card advises it only when the context needs it. What it costs, measured
on the reference machine:

| | cost |
|---|---|
| quality at 1k-32k | perplexity +0.4-0.6% on three corpora (most of it above 8k positions); the 240-case retrieval battery reads 236/240 against 238/240 unscaled, chat register 100% at every depth in both |
| speculative decode at 8k-30k context | accepts 5-15 points fewer drafts, about 10% slower than unscaled |
| above 32k | needle retrieval, chat register, three needles at three positions: 9/9 at 262,144 unscaled, 9/9 scaled, 9/9 at 1,000,000 |
| memory | a 1M KV cache is ~25 GB, which on a 128 GB machine leaves no room for the default prefill arena: past the native context the server caps `HALOGEN_MAX_TOK` at 16384 (prefill about 9% slower) and prints it |

A 1,004,581-token prompt prefills in 17.9 minutes (937 tok/s, served, cold)
and decodes at 38 tok/s with the default speculative drafter, 32 serial in
the engine's own harness. A 258,794-token prompt prefills at 1,114 tok/s and
decodes at 45 with the drafter (35 serial in the harness). Decode at depth
costs what reading every block's key costs, about 3.6 ms a step at 1M, on top
of the short-context step. The conversation then continues at ordinary speed
where the prompt cache is on: it keeps the attention state in place and saves
only its small position-free part, so a follow-up turn at 1,000,000 tokens
reached its first token in 0.55 s on the test machine (0.45 s at 262,144),
against the cold prefill. The context must leave room for the generation: a
prompt at exactly the context is refused.

## Attention budget: opt-in, and a different configuration

The model's sparse attention scores every 4-token block of the context with
a small indexer and attends the top 512 blocks (2,048 tokens) per query; the
checkpoint's config sets that budget and this server runs it by default. It
can be raised at startup, and it is off unless you ask:

```
HALOGEN_INDEXER_BUDGET=4096
```

Unset, or set to 2048, nothing changes (byte-identical). Set higher, it is a
**different model configuration**: every query past the budget attends a
superset of what the checkpoint was trained to attend, so the answer to a
long prompt is not the same answer. Accepted values are 2048 to 8192, rounded
down to a multiple of 16; the effective value is printed at startup and
reported by `/health` as `indexer_budget`. It is static for the server's
life. Measured on the reference machine, the default beside each arm in the
same session:

| | 2048 (default) | 4096 | 8192 |
|---|---|---|---|
| retrieval battery, 16k + 32k rows, 96 cases | 94/96 | 95/96 | 96/96 |
| perplexity, prose / code / agentic transcript | | +0.1% / +0.3% / −0.4% | +0.5% / +0.3% / +1.1% |
| prefill 8,192 tokens | 1,271 tok/s | −4.5% | −4.5% |
| prefill 32,768 tokens | 1,426 tok/s | −6.7% | −19% |
| decode at 32k, serial / with the draft head | 34.5 / 36.3 tok/s | −2.3% / −2.8% | −4.5% / −7.9% |

At 4096 the two misses of the default's battery (both the same needle)
retrieve, and one different case is cut off at the end-of-turn token;
perplexity moves within noise, with a structure worth knowing: the hardest
predictions get better and the easy ones (verbatim copying) a little worse,
most visibly on agentic transcripts. At 8192 every planted fact retrieves,
but perplexity is a consistent cost on all three corpora and prefill pays a
fifth. Speculative decoding stays byte-identical to serial at every budget.
The cost is the attention kernel gathering more keys per query; nothing else
in the pass changes.

**If your workload is long-context lookup** (a fact buried in a large
document or transcript, asked about much later) and you can spare 7% of
prefill, 4096 is the setting to try; measure it on your own prompts, because
the retrieval battery is a retrieval test and not a general one. Reported as
[issue #57](https://github.com/peonist-ai/halogen-flash-server/issues/57).

## Composable context: an opt-in preview

An agent harness eventually **compacts** a conversation: it replaces the
early turns with a short summary and keeps the recent tool results verbatim,
so the context fits. That costs a full re-prefill of everything after the
system prompt, because the kept results now sit at new positions. Composable
context removes that cost for the kept results, and it is off unless you
ask:

```
-e HALOGEN_COMPOSABLE_CONTEXT=1
```

With it on, each message at or above `HALOGEN_COMPOSABLE_CONTEXT_FLOOR`
(default 2048 tokens) is retained in a host store
(`HALOGEN_COMPOSABLE_CONTEXT_BYTES`, default 4 GiB, least-recently-used; in
the server's memory, not on disk, and gone at restart) as it is first read.
When a later request repeats that message at any offset behind the same
system prompt, the server reuses the retained work instead of reading it
again. On the test machine a compaction that kept ~8,700 tokens of tool
results was restored in about 0.13 s where reading them fresh costs ~14 s,
and the finish line reports `composed 5 chunks`.

It needs the resume-anywhere prompt cache and the KV pool, which are the
serving defaults (`HALOGEN_PROMPT_CACHE=2`, `HALOGEN_KV_POOL=1`); it refuses
image requests. `/health` reports it under `composable_context`.

> [!WARNING]
> **It is not the prompt cache, and it is honest about that.** The prompt
> cache is exact: a resume is byte-identical to a fresh run. Composable
> context is not: a reused answer is very close to, but not identical to, the
> one you would get by reading the text fresh, and quality is otherwise
> unchanged (retrieval in testing held at the same rate as reading fresh).
> That is why it is opt-in and its own switch. **With the flag off, nothing
> changes and every byte-identical guarantee above still holds.**

This is a preview, and the flag and defaults may change. On the roadmap:
**closer to exact** (narrowing the small difference between a reused answer
and reading fresh); **broader reuse** (across separate sessions and
sub-agents working the same files, not only within one conversation's
compaction); **a smaller footprint and a durable store** (less memory per
retained message, and an optional on-disk store that survives a restart and
holds far more than the in-memory one).

## API key: require one on the API port, opt-in

By default the API port answers anyone who can reach it. To require a key,
start the server with `-e HALOGEN_API_KEY=<key>`, or with
`HALOGEN_API_KEY_FILE` pointing at a mounted file that holds it. Clients send
the key the way they already send one: `Authorization: Bearer <key>` (the
OpenAI SDKs, Codex, curl) or `x-api-key: <key>` (the Anthropic SDK, Claude
Code with `ANTHROPIC_API_KEY`). `/health` stays open for health checks; every
other route answers 401 without the key, the NPU models' routes included.
Separate several keys with commas to rotate them. A variable that is set but
empty is refused at startup, so a key that failed to expand in your shell
cannot leave the port open. The engine's own port (8730) is not covered:
never publish it.

## Request records: a log of what your clients send, opt-in

The server can keep a record of the requests it answers: which API and
client sent each one, its size and settings, how it ended, and, unless you
say otherwise, the text of the messages and the reply. It is for you, to see
what your agents and clients actually send and get back: how long their
prompts are, how much of each the cache covered, which tools they call and
how often a result comes back as an error. It is off by default, and nothing
is written anywhere until you name a directory:

```bash
mkdir -p ~/halogen-models ~/halogen-records

podman run --rm --name halogen -p 8731:8731 \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --ipc=host --ulimit memlock=-1:-1 \
  -e HALOGEN_DOWNLOAD=peonist-ai/halogen-qwen3.8-flash-next \
  -v ~/halogen-models:/models \
  -v ~/halogen-records:/records -e HALOGEN_RECORD_DIR=/records \
  ghcr.io/peonist-ai/halogen-flash-server:0.18.16
```

The startup log then says `request records ON in /records`, with the text
fields, the size cap and the retention, and `/health` carries a
`request_records` block (written, dropped, bytes, the text fields).

> [!WARNING]
> **Read this before you turn it on for a server other people can reach.**
> Unless `HALOGEN_API_KEY` is set, the API port has no authentication, and
> `HALOGEN_RECORD_TEXT` defaults to `all`. Everything anyone sends to the
> port is written to the directory, the text included. Keep the port on a
> network you trust, or set `HALOGEN_RECORD_TEXT=none` to keep only the
> per-request lines with no text. The session fields below are whatever a
> client says they are: they group requests, and they prove nothing about
> who sent them.

**What it writes.** The directory holds two kinds of file, plain JSON you can
read with `jq`:

- `turns/<day>/<host>-<pid>-<ms>.jsonl`: one line per request, appended as
  it finishes, in a new file each day (UTC) and every 64 MiB. A line carries
  the API (`chat`, `messages`, `responses`, `completions`), whether it
  streamed, the model, the client family read from the `User-Agent`
  (`claude-code`, `codex`, `openai-sdk`, `curl`, ...), the request's counts
  and switches (prompt tokens, messages, tools, images, thinking and effort,
  sampled or greedy, a schema), how it finished (`stop`, `length`,
  `tool_calls`, `disconnect`, `error`), the tokens generated and how many
  were thinking, the id and name of each tool call in the reply, for each
  tool result sent back whether it answers one of this server's calls (and,
  on the Messages API, whether the client marked it an error), the same
  `timings` block a response carries, and how long the request waited for a
  free slot. When the client sends `user`, `prompt_cache_key`,
  `safety_identifier` or `metadata` (on Messages, `metadata.user_id`), the
  line carries a hash of it, never the value, so the turns of one
  conversation can be grouped. The hash is keyed by `.salt`, a random file in
  the directory.
- `units/<2 characters>/<hash>.json`: the text. Each message, reply and
  thinking block is one file, named by a hash of its content and written
  once, however many requests repeat it; a request's line lists its
  messages' hashes in order. An agent that resends its whole history every
  turn adds only its new messages. Images are never stored, only a hash and
  their pixel size. `/v1/completions` requests get the line only, no text.

Requests to the [small NPU models](npu-small-models.md#small-models-on-the-npu)
are recorded too: the text of decisions, guard checks and generations, and
only the counts for embeddings, reranking and images.

**Size and age.** `HALOGEN_RECORD_GIB` (default 2) caps the whole directory;
past it new records are dropped and counted. `HALOGEN_RECORD_DAYS` (default
90) removes older days at start and when the date changes, with any text no
remaining record refers to. Nothing on a request's path waits for the disk:
a full disk, the cap or a backlog drops records, never a request.

**Reading and pruning.** Two commands run inside the container:

```bash
podman exec halogen python3 /halogen/tools/request_records.py stats /records
podman exec halogen python3 /halogen/tools/request_records.py prune /records --days 7
```

`stats` counts records by API, client, finish and thinking, the cache's share
of the prompts, and how many of this server's tool calls were answered with
an error. `prune` also takes `--gib G`, `--session H` (one conversation, by
the hash in its lines), `--unit H` (one stored text; the records keep its
hash) or `--all`. No HTTP route reads, deletes or serves the records. The
files and the directories the server makes are readable by their owner only
(0600 and 0700): your user under rootless Podman, root under Docker.

---

## History

| shipped | what arrived |
|---|---|
| 0.3 | `HALOGEN_CTX` bounds a request, not the allocation (the pool became the memory knob) |
| 0.6.3 | the lookup table is read 64 rows at a time after a restart; before that a 32,000-token prompt took up to twice its usual 25 s right after a fresh start (up to 50 s more with the table fully evicted) |
| 0.8.1 | fixed entries per conversation, so a long tool-calling session cannot push other sessions out (was issue #54) |
| 0.11.0 | the cache keeps the most recently *used* history entries, not the newest (issue #61); before it, eviction could drop the very entry a request had matched |
| 0.11.3 | mode `2` answers cold requests byte-for-byte like modes `1` and `0` (issue #65 was a cold request under the default landing on a wrong answer at `temperature 1.0` that mode `1` did not produce); the end-of-last-request entry (`HALOGEN_CACHE_FULL`) |
| 0.11.4 | the host-memory note under ~10 GiB; the move-before-forget order |
| 0.11.5 | the pool's own occupancy in `/metrics`; a follow-up uses its region's reservation, with the clamp; the `moved`/`waiting` log lines and `/cache` counters. Before it, two long conversations taking turns behind a shared system prompt forgot each other on every turn (issue #74) and each turn re-prefilled the whole history at 100 to 160 s |
| 0.11.7 | moves come FIRST when a region cannot grow (in-place growth, `packed`); the clamp runs only after every no-loss step fails; `cold_resorts` reads 0 from here |
| 0.11.8 | all of it applies whether or not the client sends `reasoning_content` back (issue #75) |
| 0.11.10 | `HALOGEN_CACHE_PRUNE_OLD` (issue #78) |
| 0.12.0 | the 1M prefill figures above; on 0.11.10 the same 1M request took 21.2 minutes and decoded at 27 (19 serial), and 0.2.0's figure was 22-24 minutes and 19 serial |
| 0.12.1 | the save-at-start-of-last-message for the default mode; the first-request cost dropped from ~5% to ~1-2% (the state is recorded as the pass goes by); `snapshot_align: 64` in `/health` |
| 0.13.3 | an idle region is given up before a live conversation's (issue #94); a too-small `HALOGEN_CACHE_ENTRIES` says so at startup |
| 0.15.1 | the pool-fit reading on 121-125 GiB machines (issue #117; before it the fit overestimated working memory by ~8 GiB and a pool that fits came out halved) |
| 0.17.3 | request records |
| 0.18.1 | interactive-first admission between pieces; side requests (`prompt_cache_policy: "no_store"`) |

**Side requests** (the 0.18.1 row; issue #151): a request that carries
`"prompt_cache_policy": "no_store"` at the top level reads the prompt cache
and stores nothing: no entry, no write to `HALOGEN_CACHE_DIR`, and every
cached conversation is left exactly as it was, including one it resumed from.
Send it on a summarizer, a title generator or any other side request that
shares the server with a conversation, so the conversation's next turn still
finds its history. Absent or `"default"` is the usual caching, and any other
value is a 400. It reads entries held in memory, not ones only the disk cache
holds. Under memory pressure it needs room in the pool like any request, so
it can make the server forget an idle conversation, the same as any other
request.
