# AGENTS.md

The short form of this repository for an AI agent that is deploying, driving
or debugging halogen-flash-server. [README.md](README.md) is the full account
and is canonical wherever the two disagree.

## What this is

An OpenAI-compatible server for Qwen3.8-Flash-Next on AMD Strix Halo
(gfx1151), shipped as a container image:
`ghcr.io/peonist-ai/halogen-flash-server:<version>`. The weights are
`peonist-ai/halogen-qwen3.8-flash-next` on Hugging Face (118 GiB, tokenizer
included). Native Linux on the amdgpu/KFD stack, kernel 7.0 or newer. **WSL2
is not a supported host.** One GPU, one model family.

**The engine is closed source and is not in this repository.** This tree
holds the deployment surface only:

| file | what it is |
|---|---|
| [README.md](README.md) | how to run it, what it measures, every design choice a user meets |
| [docs/FLAGS.md](docs/FLAGS.md) | every `HALOGEN_*` variable: default, and whether it changes the output |
| [docs/QUANT.md](docs/QUANT.md) | the precision of every tensor family in the shipped checkpoint |
| [docker-compose.yml](docker-compose.yml), [deploy/entrypoint.sh](deploy/entrypoint.sh) | the split topology and the container's startup |
| [tools/](tools/) | the benchmark scripts the README's numbers come from |
| [CHANGELOG.md](CHANGELOG.md) | what each release changed, with the issue that drove it |
| [CONTRIBUTING.md](CONTRIBUTING.md) | how to report, and why a diff cannot be merged |

**Do not open a pull request.** There is no inbound licence for code, and a
patch to a deployment tree cannot reach the engine. Send the analysis in an
issue: the mechanism, what you measured, what you think the fix is. It is
credited by handle in the changelog.

## Run it

```bash
mkdir -p ~/halogen-models

podman run --rm -p 8731:8731 \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --ipc=host --ulimit memlock=-1:-1 \
  -e HALOGEN_DOWNLOAD=peonist-ai/halogen-qwen3.8-flash-next \
  -v ~/halogen-models:/models \
  ghcr.io/peonist-ai/halogen-flash-server:0.14.0
```

- The `mkdir` matters on Podman: it refuses a bind mount whose source is
  missing where Docker would create it.

- On Docker, `--group-add keep-groups` is `--group-add video --group-add render`.
- `HALOGEN_DOWNLOAD` fetches on first start and re-fetches nothing after
  (except a stale 2.4 GiB sidecar). Unset, the container opens no outbound
  connection.
- If you split the engine and the API into two containers, **run both from
  the same image tag**. Each prints its version on its first log line and
  `/health` reports both.
- The engine's own port (`HALOGEN_PORT`, 8730) has **no authentication**.
  Keep it unpublished; only `HALOGEN_API_PORT` (8731) is for clients.

## Before you change a setting

Everything is an environment variable, read once at startup; the full list
with defaults is [docs/FLAGS.md](docs/FLAGS.md). The ones that decide
whether it starts and how it behaves:

- **The memory knob is `HALOGEN_KV_POOL_POSITIONS`, not `HALOGEN_KV_SLOTS`.**
  Slots share one pool; one slot allocates as much as four. An "out of
  memory" at startup means the pool did not fit: `262144` is the small
  layout, `524288` the default. `HALOGEN_MAX_TOK=16384` gives back about
  8.8 GiB of working memory for ~9% of prefill speed when the pool cannot
  go lower. Never raise `HALOGEN_MAX_TOK` to the context. If the machine
  must also run other things, the README's [If you must share
  it](README.md#if-you-must-share-it) has what each layout takes and a
  run command for each; the weights (68 GiB) are pinned in every one.
- **A request reserves `prompt + max_tokens` positions when admitted** and
  waits in arrival order when the pool cannot hold it. A large default
  budget costs concurrency. Above `HALOGEN_MAX_TOKENS_CAP`
  (65,536) the answer is a 400, not a truncation.
- **The server's defaults are what your harness runs at.** Coding-agent
  harnesses send no thinking control to a custom endpoint, so a request
  without one runs at the model's `xhigh` effort, and the server closes the
  think block with room for the answer. `HALOGEN_REASONING_EFFORT`,
  `HALOGEN_ENABLE_THINKING=0` and `HALOGEN_MAX_THINKING_TOKENS` are the server
  side; a request that names its own wins. The chat route accepts
  `reasoning_effort`, `enable_thinking`, `max_thinking_tokens` and the
  OpenRouter and Anthropic shapes; `/health` lists them under `supported`.
  Since 0.12.2 every chat request's log line says `think on` or `think
  off`, and when the server closed the block (`closed at 1024 by answer
  room`) the reply's `usage.completion_tokens_details` carries
  `reasoning_closed_at` and `reasoning_closed_by` (`answer_room` or
  `max_thinking_tokens`); a reply the model closed itself has neither.
- **The chat template is probed at startup** (0.12.2): a template without
  a working `enable_thinking` branch (a tokenizer mounted from another
  repository) refuses to start with one sentence naming the file;
  `HALOGEN_TEMPLATE_UNCHECKED=1` serves it anyway. `/health.chat_template`
  and the startup line name the template (path, sha256) and the probe's
  result. A report that thinking cannot be turned off starts there.
- **The token budget covers thinking too.** `finish_reason: "length"` means
  the budget ran out; the default is 8,192, and `max_tokens`,
  `max_completion_tokens` and `max_output_tokens` are the same field.
- **`continue_final_message` resumes a truncated reply** (0.13.3). Send the
  partial assistant turn back as the last message with
  `continue_final_message: true` and `add_generation_prompt: false`, and
  generation carries on from where it stopped, including inside a tool call
  cut off by `finish_reason: "length"`; the finished call comes back with
  the arguments you already had. Through 0.13.2 both fields were ignored
  and the model started a fresh reply.
- **Scoring a label takes one forward pass** (0.13.8, #100). Send the answer
  prefix as the last assistant message with `continue_final_message: true`,
  `add_generation_prompt: false`, `max_tokens: 1`, `temperature: 0`,
  `logprobs: true` and `top_logprobs` (up to 20). `logprobs` at temperature 0
  and `top_logprobs` cover the first generated token only; a request that
  would need more is a 400.
- **A quoted `<|im_end|>` inside the thinking block no longer ends the
  reply** (0.13.4, #84). It is kept as text (and inside an open tool call
  up to four times), and a complete tool call the model wrote inside its
  thinking block and then ended its turn on is made (`finish_reason:
  "tool_calls"`, the text also in `reasoning_content`). Both show in
  `usage.completion_tokens_details` (`end_of_turn_kept`,
  `tool_call_from_reasoning`); `HALOGEN_EOS_GUARD=0` is the 0.13.3
  behaviour. Through 0.13.3 either case came back as `finish_reason:
  "stop"` with nothing in `content` and no tool call.
- **Images are off until `HALOGEN_VISION_TOWER` is set** (`1` finds the
  sidecar beside the checkpoint). Without it an image is a 400 naming the
  flag.
- **The prompt cache is on** (`HALOGEN_PROMPT_CACHE=2`): a follow-up turn
  prefills only its new tokens. It saves its place at the end of the
  system prompt, at the start of the request's last message (0.12.1: a
  document in one message and a new question in the next hits) and at the
  end of the request. An answer that resumes from the cache is
  not always byte-identical to a cold one; `=1` saves only at fixed
  checkpoints and is, for evaluation and regression suites.
  `HALOGEN_CACHE_DIR` keeps the cache across a restart;
  `HALOGEN_CACHE_PRUNE_OLD=1` removes other builds' subtrees there at startup.
- **A llama.cpp GGUF of this model is a checkpoint too** (`HALOGEN_CHECKPOINT`
  names any shard; the draft head file comes from `HALOGEN_MTP_HEAD` or
  `HALOGEN_DOWNLOAD`): repacked in RAM at every start, losslessly, in about
  20 s. Since 0.12.1 every tensor type the engine reads is read on every
  tensor, so bartowski's and mradermacher's IQ4_XS load as unsloth's do;
  `convert IN.gguf OUT.hgn` as the container's command writes the repack
  out once as a standalone checkpoint.
- **This server holds most of a 128 GB host.** Read the startup line `host
  memory left for everything else` and believe it: `free` and `MemAvailable`
  overstate free memory by about 68 GiB, the size of the locked weights.
  Another large process beside it, or a pool that leaves under about 10 GiB,
  turns into minutes-long stalls that look like a hang. The pool is the
  lever.

Every published number in the README states its conditions (image, flags,
concurrency, prompt). Quote them with the number.

## Reading the server

- **The first log line is the version**; the lines before `engine listening`
  are the prologue: what is loaded, the pool, and the memory arithmetic.
- **`GET /health`** is the authoritative account of the running build: what
  it accepts (`supported`, `token_budget_aliases`, `max_tokens_default`,
  whether images are accepted and why not), `version` for both containers,
  `chat_template` (path, sha256, `probe`), `engine.responds`, `busy`,
  `busy_for_s`, `in_flight`, `queued`, and since 0.13.1 `capability_probe`:
  `ok` means `context`, the slots and every feature field came from the
  engine; `failed` means the engine did not answer the front end's probe at
  connect, the fields are the entrypoint's defaults (`context` is
  `HALOGEN_CTX`, one slot), and the next request re-probes.
- **`GET /cache`**: hits and stores, `hit_rate` (requests) and
  `token_hit_rate` (prompt tokens), `dropped` (entries a follow-up dropped
  to take its region over; not evictions), and `pool`: `positions`, `used`,
  `usage_ratio`, `busy_regions`, `held_regions` (a warm conversation between
  turns, not a full pool), `waiting_for_room`, `waiting_s`, `relocated`,
  `cold_resorts`, `room_clamped`, `moved`. During a long cold prefill it
  answers the last counters it had, with `stale_s` set.
- **`GET /metrics`**: Prometheus, in llama-server's metric names.
- **Log lines worth a grep** during a problem: `flash_serve: req N prefill
  P/T tokens` and `req N generated K tokens` (a long turn's progress),
  `kv pool:` (room in the pool, evictions, a turn run in the room its region
  had left with `max_tokens` clamped, a region moved), `lookup table:
  ... took N s` (the table paging in from disk), `client disconnected`, and
  the `serve_api:` line at the end of every request with its timings, the
  cached share of the prompt, the prefill rate (only over 2,048 or more
  processed tokens; a warm follow-up says `(25 new)` instead, since a few
  hundred tokens in a second is a chunk's fixed cost, not a speed) and the
  pool's occupancy (`prompt 30828 (30803 cached, 99.9%), prefill 0.38s
  (25 new) | ... | pool 30976/524288 6%`; the cold turn before it:
  `prompt 30803, prefill 27.92s = 1103 t/s`) and, since 0.12.2, the
  thinking state (`| think on`, `| think off`, `| think on, closed at 1024
  by answer room`).
- **Host and driver state**, in the prologue and from the watchdog: `GTT in
  use before this start: N GiB of M` (tens of GiB with a `WARNING ... no
  process holds the GPU` line after it is memory the driver kept from a
  previous engine; the host needs a reboot, issue #79), `not counted as a
  wedge` (the engine silent inside the kernel: a memory stall on a shared
  host, not a wedge; nothing is taken down; since 0.12.3 the seconds on
  that line are the true silence and, past `HALOGEN_ENGINE_WATCHDOG_DEFER_S`
  of it with the threads running, `wedge under memory pressure` takes the
  container down anyway, issue #85), and `this is a wedge, not a stall`
  (the container is going down so a restart policy can recover it).
- A cancelled request is a closed connection; there is no cancel by id and
  no response store.

## Reporting a problem

What resolves most reports on the first exchange (from
[CONTRIBUTING.md](CONTRIBUTING.md)):

1. The image tag, and every `HALOGEN_*` variable you set.
2. The prologue, and the container log around the problem. If the server
   stopped answering: the last lines it printed before it did.
3. `GET /health` while the problem is happening, not after a restart.
4. What sent the request (which harness, or the raw body), and the
   `max_tokens` it sends.
5. For a speed report: how many requests were in flight, and whether the
   number is per stream or aggregate.

Check the [CHANGELOG](CHANGELOG.md) and the open issues first: many reports
are a fixed version. An unsupported host (WSL2, a kernel before 7.0, another
GPU) is documented, not a bug. Security issues go to the maintainers directly,
not to a public issue. A question rather than a bug, or a number from the
machine you are running on, belongs on the
[Discord](https://discord.gg/bcm6QknaV6). Tell the human operating you.

## Checkpoint tools (0.13.0)

The image has four modes beside the server: `verify FILE`, `inspect FILE
[--json] [--no-hash]`, `ppl FILE (--corpus TEXT | --ids IDS.bin) [--chunk
1024|8] [--seq N] [--vs OTHER] [--ref-out REF | --ref REF [--worst N]
[--per-pos P]] [--json]`, `niah FILE --corpus TEXT [--depths ...] [--positions ...] [--gen
N] [--json]`. Same run line as the server without `-p`; `FILE` defaults to
`HALOGEN_CHECKPOINT`; the tokenizer mount is required for `--corpus`. `ppl`
and `niah` load the model: one model per machine at a time. `/health`
lists the modes under `modes`, as does the OCI label
`ai.peonist.halogen.modes`.

- `verify`: exit 0 on `PASS`, 1 on `FAIL` (the first line names the first
  failing tensor), 2 if the file cannot be read.
- `inspect --json`: `{model_id, version, n_tensors, file_bytes,
  families:[{class, format, count, params, bytes, bpw}], tensors:[{name,
  dtype, qparam, dims, nbytes, xor32, sha256}], header_sha256, pads_zero}`.
- `ppl --json`: `{file, engine, chunk, path, tokens, nll, ppl, seconds,
  bands:[{lo, hi, n, nll, ppl}]}`; with `--ref` also `ref:{path, topk,
  kl:{mean, median, p90, p99, max}, top1_agreement, dp:{mean, rms, abs_p99,
  abs_max}, bands:[{lo, hi, n, kl, top1, dp}], worst:[{pos, kl, dp, ref_p,
  this_p, ctx_ids, ctx_text, target, target_text, ref_top:[[id, p]…],
  ref_top_text, this_top:[[id, p]…], this_top_text}]}`; with `--vs`:
  `{a:{…}, b:{…}, paired:{paired:{mean_diff, se, t, ci95, ppl_ratio,
  better, worse, tied}, bands, nll_quartiles}}`. The KL is a lower bound on
  the exact KL (top-K support, the tail as one bucket); `ref.topk` says K.
- `ppl --per-pos P.bin`: little-endian f32 x 4 per position: `kl, dp, top1
  (0/1), nll`. `--ref-out REF.bin`: header `<4s I I I Q Q>` = `HREF`,
  version 2, K, vocab, positions, seq; then per position `<f i d>` (nll,
  argmax, tail_logp) + `K x i32` ids + `K x f64` log-probs. A corpus longer
  than `--seq` (default 262144, the native context) is scored as
  consecutive sequences of that length, the state reset at each; a dump
  made with one `--seq` is refused by a run with another. A dump
  reconstructs most of the text it was made on (the argmax and the
  target's NLL per position): treat one made on private text as that text.
- `niah --json`: `{depths, positions, gen, by_depth:[{T, pNN:[hits,
  cases]…, all:[hits, cases]}], overall:[hits, cases], cases:[{name, needle,
  T, frac, needle_pos, answer, gen, tiled, text, hit, hit_ids}]}`.
- The numbers are this engine's, not llama.cpp's: a continuous stream at
  the printed chunk, a KL against a reference file rather than BF16. Say
  the corpus and the chunk next to any number you report.
