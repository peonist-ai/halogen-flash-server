<p align="center">
  <img src="docs/halogen.jpg" alt="halogen-flash" width="760">
</p>

# halogen-flash-server

**halogen™ is the fastest way to run Qwen3.8-Flash-Next on AMD Strix Halo,
and it does not get there by spending fewer bits.**

Every kernel is written for this one GPU and this one model family. No
general-purpose runtime, no portability layer, no fallback path. That is why it
can do things a general engine cannot, and why it runs on exactly one piece of
silicon.

On a 32K prompt with a 256-token answer, against the fastest numbers anyone
else has published for this model on this hardware:

| | precision | prefill | decode | **total** |
|---|---|---|---|---|
| **halogen-flash 0.5.3** | **5.53 bpw** | **23.0 s** | **6.1 s** | **29.1 s** |
| [EngramHalo.cpp](https://github.com/Aristo94/EngramHalo.cpp) | 3.71 bpw | 103.7 s | 14.3 s | 118.0 s |
| [ROCmFP4](https://huggingface.co/kingjones777/Qwen3.8-Flash-Next-ROCmFP4-STRIX-GGUF) | 5.51 bpw | 104.7 s | 13.2 s | 117.9 s |
| [CIRU-IU4](https://huggingface.co/jcbtc/Qwen3.8-Flash-CIRU-STRIX-IU4) | 5.96 bpw | 143.7 s | 11.0 s | 154.7 s |

**Roughly 4x faster end to end than the best of them.** Prefill is where that
is won, and on any prompt with real context prefill is most of the wall clock.
The one runtime carrying more bits than we do is the slowest of the three, and
the fastest of them runs at 3.71 bpw, two thirds of our precision.

Our two cells are the rows published under [Measured](#measured), which is also
where the conditions are: 32,768 tokens at 1,424 tok/s, then 256 tokens at the
served speculative rate of 41.7 tok/s. Read those conditions before comparing,
particularly the power envelope. The competitor rows are their own published
figures on their own machines, and [Against the
alternatives](#against-the-alternatives) says what differs.

Bits per weight is measured from the checkpoint's own tensor table rather than
quoted from a format name. It is 5.53 bpw across all 179.55B parameters, or
4.55 bpw across the trunk and experts with the FP8 n-gram lookup table set
aside. [`docs/QUANT.md`](docs/QUANT.md) gives the breakdown by tensor family
and says how the figure is derived, so it can be checked with arithmetic rather
than taken on trust.

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
a quality trade. Since 0.6.0 there are two draft sources, the model's own
draft head and the request's own text (prompt lookup), and the guarantee
covers both.

Since 0.7.0 the engine also opens a **llama.cpp GGUF** of this model directly:
point it at the file you already have (unsloth's `UD-IQ4_XS`, say) and it
runs on these kernels, with the same speculation and the same identity
guarantee. Same file, faster runtime, no conversion step. See [Bring your own
GGUF](#bring-your-own-gguf) for which files, and for the numbers.

There is a [Discord](https://discord.gg/bcm6QknaV6) for questions, for
numbers from your own box, and for comparing setups. Bugs and regressions go
to [issues](https://github.com/peonist-ai/halogen-flash-server/issues), where
the changelog can credit them. See [Community](#community).

---

## Contents

- **[Quickstart](#quickstart)**, then **[Using it](#using-it)**:
  [sampling](#sampling), [images](#images),
  [token budgets](#token-budgets-and-why-an-empty-answer-means-you-ran-out),
  [Codex and the Responses API](#codex-and-the-responses-api),
  [from an agent harness](#from-an-agent-harness)
- **[Give it a machine of its own](#give-it-a-machine-of-its-own)**: what this
  server holds, what that leaves for anything else, and
  [the recipes if you must share it](#if-you-must-share-it)
- **[Measured](#measured)**: prefill and decode,
  [against the alternatives](#against-the-alternatives), and
  [end to end over HTTP](#served-throughput-end-to-end-over-http)
- **[Quality](#quality-what-is-measured-and-what-is-not)**: what is measured,
  and what is not
- **[Precision](#precision-what-you-get-and-how-to-trade-it)**: what you get,
  and how to trade it
- **[Bring your own GGUF](#bring-your-own-gguf)**: run a llama.cpp file of this
  model on this engine, and what that costs and buys
- **[Measuring a checkpoint](#measuring-a-checkpoint)**: `verify`, `inspect`,
  `ppl` (perplexity, and KL against a reference file) and `niah` as modes
  of the image, for your own quant or a GGUF
- **[Configuration](#configuration)**: every setting worth knowing, plus
  [cache modes](#choosing-a-cache-mode),
  [context and memory](#context-and-memory-one-kv-pool-several-conversations)
  and [1M context](#1m-context-opt-in-and-a-different-configuration),
  [attention budget](#attention-budget-opt-in-and-a-different-configuration),
  [composable context](#composable-context-an-opt-in-preview)
- **[Troubleshooting](#troubleshooting)**:
  [will not start](#if-the-server-will-not-start-out-of-memory),
  [starts but crawls](#if-the-server-starts-but-crawls-on-long-prompts),
  [the host settings we measured
  on](#the-host-settings-these-numbers-were-measured-on)
- **[What this release is not](#what-this-release-is-not)**,
  [community](#community), and the [license](#license)
- **[AGENTS.md](AGENTS.md)**: the short form of all of the above for an AI
  agent deploying, driving or debugging this server

---

## Quickstart

**First, set the BIOS carve-out to its minimum.** Most engines on this
hardware want as much dedicated VRAM as the firmware will give. This one
wants the opposite. Set the UMA frame buffer (or "dedicated graphics
memory") to its smallest explicit value, not Auto. On some boards Auto
means 64 GiB, which hides half the machine from the OS, and the weights
then cannot load. [Troubleshooting](#if-the-server-starts-but-crawls-on-long-prompts)
has the detail.

```bash
mkdir -p ~/halogen-models

podman run --rm -p 8731:8731 \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --ipc=host --ulimit memlock=-1:-1 \
  -e HALOGEN_DOWNLOAD=peonist-ai/halogen-qwen3.8-flash-next \
  -v ~/halogen-models:/models \
  ghcr.io/peonist-ai/halogen-flash-server:0.13.8
```

That is the whole thing. It fetches the weights on first start (118 GiB, so
give it a while; the transfer resumes if interrupted; since 0.13.2 the log
says how many gigabytes have arrived every 30 seconds instead of counting
files) and serves an OpenAI-compatible endpoint on `:8731`, reachable from
your network. The `mkdir` is there because Podman refuses a bind mount
whose source does not exist (`statfs ...: no such file or directory`) where
Docker would create it; through 0.13.1 this block started with the
`podman run` and failed on a fresh machine.

**The tag is pinned on purpose, and `:latest` exists too.** Every release
also publishes `ghcr.io/peonist-ai/halogen-flash-server:latest`. A `run`
does not ask the registry about a tag your machine already has, so a local
`:latest` stays whatever it was on the day you first pulled it (Podman and
Docker both behave this way). Add `--pull=always` to the `run` line to
fetch the newest build on every start, or update by hand with
`podman pull ghcr.io/peonist-ai/halogen-flash-server:latest`. The
Quickstart pins a version because a pinned tag is what makes a bug report
answerable and a bad release reversible: the startup log and `/health` both
name the version either way, but by the time you read a log the tag may
have moved under it. Pin in anything durable, use `:latest` to try the
newest.

Note the models volume is read-**write** here, with no `:ro`, because it is
being downloaded into. Nothing is fetched on later starts, with one
exception: a start with `HALOGEN_DOWNLOAD` set and the volume writable
re-fetches the 2.4 GiB quality sidecar when the one on disk predates the image
(0.6.0 changed that file; the 115 GiB checkpoint is never re-fetched). With
`HALOGEN_DOWNLOAD` unset the container opens no outbound connections at all,
and says at startup if the sidecar is the older one.

**If you would rather fetch the weights yourself:**

```bash
hf download peonist-ai/halogen-qwen3.8-flash-next --local-dir ~/halogen-models

podman run --rm -p 8731:8731 \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --ipc=host --ulimit memlock=-1:-1 \
  -v ~/halogen-models:/models:ro \
  ghcr.io/peonist-ai/halogen-flash-server:0.13.8
```

The weights repo carries the tokenizer, so one `-v` is all either form needs.
On Docker rather than Podman, replace `--group-add keep-groups` with
`--group-add video --group-add render`: `keep-groups` is a Podman extension.

**If you split the engine and the API into two containers** (the shipped
[`docker-compose.yml`](docker-compose.yml) does), **run both from the same
image tag.** The API renders the prompt and the engine runs it, and what one
release can do the other may not know how to ask for: an API from before
0.5.0 in front of a newer engine sends an image as a placeholder with no
pixels behind it, and the model describes a picture it never received. Since
0.5.8 the engine refuses that, each container prints its version on its
first log line, the API warns at startup when the engine's differs, and
`/health` reports both under `version`. (The text `<|image_pad|>` written in
a message is not a placeholder and, since 0.6.2, is served as text; see #39.)

---

## Using it

The server speaks the OpenAI API at `/v1`, and `/health` is the authoritative
account of what the build you are running supports: the sampling fields,
whether images are accepted, the token budget aliases and the current default,
and the tool-call wire format. What follows is the part worth reading first.

### Sampling

`temperature`, `top_p`, `top_k`, `min_p`, `seed`,
`presence_penalty`, `frequency_penalty`, `logit_bias` and `logprobs` are
supported. `temperature` absent or 0 is greedy decode. Above 0, the request
samples from the filtered distribution on the same drafter it would otherwise
get, so speculation stays on. A `seed` reproduces a request on the same server
configuration. A sampled request (temperature above 0) with `logprobs: true`
carries the chosen token's logprob on every token. For scoring, `logprobs` at
`temperature: 0` and `top_logprobs` (1 to 20, at any temperature) cover the
first generated token, so those requests set `max_tokens: 1`. `logprobs` with
`stream: true`, logprobs past the first token at temperature 0, and `n > 1`
are not implemented and are refused with a 400, as is any value outside its
defined range, rather than clamped. `/health` lists what the running build
supports.

**Reading a label's probability** (0.13.8, #100). A classifier reads the
next-token distribution over a few labels from one forward pass. End the
messages with the assistant's answer prefix, for example `{"answer": "`, and
send `continue_final_message: true`, `add_generation_prompt: false`,
`max_tokens: 1`, `temperature: 0`, `logprobs: true` and `top_logprobs: 20`.
Each `top_logprobs` entry names a token, its logprob and its bytes. Without
`continue_final_message` the server opens a new turn after the prefix, and with
thinking on, the first token is then the start of the reasoning rather than a
label. With thinking off (`chat_template_kwargs: {"enable_thinking": false}`)
a request without a prefix scores the label too. The probabilities are the
model's own and are not calibrated.

**Server-side defaults, and the model card's settings.** This image decodes
greedy unless a request says otherwise, because greedy is what every
byte-identical guarantee below is made on. The model's authors recommend
sampling: the card's thinking-mode settings are `temperature=1.0`,
`top_p=0.95`, `top_k=20`, and every benchmark in it was run at that point.
Most agent clients send no sampling fields at all, so the server can supply
them:

```
-e HALOGEN_TEMPERATURE=1.0 -e HALOGEN_TOP_P=0.95 -e HALOGEN_TOP_K=20
```

`HALOGEN_TEMPERATURE`, `HALOGEN_TOP_P`, `HALOGEN_TOP_K`, `HALOGEN_MIN_P`,
`HALOGEN_PRESENCE_PENALTY` and `HALOGEN_FREQUENCY_PENALTY` each set the value a
request gets when it omits that field. The rule is one sentence: a field the
request sends always wins, a default fills only a field the request omits, and
a request that sends `temperature: 0` decodes greedy and takes none of the
sampling defaults. With a temperature default set, a request that sends no
temperature is sampled, so its output differs run to run unless it sends a
`seed`, and the byte-identical claims below apply only to requests that send
`temperature: 0`. That is why the image does not set these itself: it is your
call which default you want, and this is the switch. `/health` reports what is
set under `server_defaults`, and a value outside its range refuses to start,
before the model loads, naming the variable. (The card's non-thinking settings
are `temperature=0.7`, `top_p=0.80`, `top_k=20`, `presence_penalty=1.5`; they
apply when a request disables thinking, which these defaults cannot tell
apart, so send them from the client in that case.)

### Images

The server reads images, and it is **off until you turn it on**. Point
`HALOGEN_VISION_TOWER` at the vision sidecar that ships beside the weights, or
set it to `1` to look for the file next to the checkpoint:

```
-e HALOGEN_VISION_TOWER=1
```

With no tower the image path is absent rather than disabled, so a text-only
deployment behaves exactly as it did before this release. `/health` reports
whether images are accepted and, when they are not, why; an image sent to a
server without a tower is a 400 naming the flag.

Both `/v1/chat/completions` and `/v1/responses` take an image content part in
the usual OpenAI shape, carrying a `data:` URL or bare base64:

```json
{"role": "user", "content": [
  {"type": "text", "text": "What does the error message say?"},
  {"type": "image_url", "image_url": {"url": "data:image/png;base64,..."}}
]}
```

An `http(s)` URL is refused deliberately: fetching one would make the server
issue outbound requests to wherever a client pointed it. Several images in one
conversation are attributed correctly, including an earlier one referred to
after a later one has arrived.

**What to expect from it.** Text at 12 pt and above is read exactly at every
supported resolution. Below that it degrades gradually rather than failing:
across a battery of several hundred readings every miss was the right field
with one to three characters wrong, and none read a different field or invented
a value. Two things are worth knowing when you choose what to send. A **bigger
frame is not better** for the same text, because past a point it adds empty
area and not detail. And a **densely filled page is harder than a sparse one**
at the same point size, which is a matter of finding the right row rather than
resolving it.

**What it costs.** One image adds roughly 5.5, 11.8 or 25.3 seconds at
1280x800, 1920x1080 or 2560x1440. `HALOGEN_VISION_MAX_PIXELS` (default
2560x1440) is the size an image is scaled down to fit, preserving aspect ratio;
larger images are downscaled rather than refused, and nothing is refused until
four times that. 3840x2160 costs about 105 seconds and reads no better than
1440p, which is why the default sits where it does. There is no fixed aspect
ratio anywhere in the path: tall, wide and square crops all work, and a crop
under 256x256 is scaled up, which helps small text rather than hurting it. A
1920x1080 frame occupies about 2,040 tokens of the context.

### Token budgets, and why an empty answer means you ran out

**The token budget covers thinking, not just the answer.** This model reasons
before it replies and those tokens count against the budget. Before 0.11.0 a
budget that ran out mid-thought did not shorten the answer, it removed it:
the reply came back with `finish_reason: "length"`, an empty `content`, and
the partial reasoning in `reasoning_content`, which most OpenAI clients do
not display. Since 0.11.0 the server closes the think block with room left
for the answer (the *answer room*, below), so that shape needs a request
that asks for it (`HALOGEN_THINKING_ANSWER_ROOM=0`).

The default is **8192**, which finished every ordinary prompt we measured with
room to spare. Send more when you want more, up to `HALOGEN_MAX_TOKENS_CAP`
(**65536** by default); above the cap you get a 400 rather than a silent
truncation, so ask for what you need and the server will tell you if it is too
much. Hard reasoning problems can genuinely exceed 8192: pass a larger budget,
or `"reasoning_effort": "low"` to make the model think less. Accepted efforts
are `minimal`, `low`, `medium`, `high` and `xhigh`; the model's own default is
`xhigh`. The chat template itself knows three levels, so the five names fold
onto them: `minimal` and `low` are `low`, `medium` is `medium`, `high` and
`xhigh` are `xhigh`, and the startup line and `/health` report the level the
template will see (#71 asked why `high` printed as `xhigh`; #76 asked for
the middle one to be said). `medium` is the one step down from the default. `"reasoning_effort": "none"` turns thinking off for that request
(the same as `chat_template_kwargs: {"enable_thinking": false}`, and
`reasoning: {"effort": "none"}` on `/v1/responses`).

**A thinking budget, since 0.8.1.** `"max_thinking_tokens": N` on a request
(or `HALOGEN_MAX_THINKING_TOKENS` as the server default; the request wins)
bounds the think block: if the model has not closed it after N generated
tokens, the server closes it (Qwen's own budget sentence, then `</think>`)
and the answer follows in the same stream, on the same state, with no second
request. The `max_tokens` budget still covers both. This exists because
greedy decoding at 100k+ of context can loop inside the block and spend the
whole budget there (issue #56: 32,000 tokens of reasoning and an empty
answer); the model card's sampling settings above are the cure, and the
budget bounds the damage when a client sends none. Unset, nothing changes.

**The answer room, since 0.11.0.** Thinking no longer consumes the whole
budget. When a request sends no thinking budget of its own, the server closes
the think block once `max(1024, 15% of max_tokens)` tokens of the budget
remain (the same close as `max_thinking_tokens`), so a capped request ends
with an answer rather than `finish_reason: "length"` and an empty `content`.
This matters because agent harnesses send no thinking control at all to an
OpenAI-compatible server unless configured to, so the model's own `xhigh`
runs under whatever cap the harness set for the *answer*: a compaction
summary capped at 13,000 tokens that the model thinks past is a compaction
that fails, and the harness retries it. A request's own budget still wins
when it is smaller. `HALOGEN_THINKING_ANSWER_ROOM` sets the room in tokens;
`0` restores the 0.10.x behaviour; `/health` reports it as
`thinking_answer_room`. Only a request whose thinking would have run past
the line is affected; every other reply is untouched.

**When the server closed the block, it says so, since 0.12.2.** A reply whose
think block the server closed (the answer room, or your own
`max_thinking_tokens`) carries `reasoning_closed_at` (the token the block
was closed at) and `reasoning_closed_by` (`"answer_room"` or
`"max_thinking_tokens"`) in `usage.completion_tokens_details`, beside
`reasoning_tokens`; on `/v1/responses` the same two ride
`output_tokens_details`. A reply whose block the model closed itself has
neither. The server's per-request log line says the same (`think on, closed
at 1024 by answer room`) and, on every chat request, whether the prompt
opened a think block at all (`think on` / `think off`). Under a 2,048
budget the room is 1,024 tokens, so a reply that reads as "about a thousand
hidden tokens, then a short answer" is this close, and the fields now name
it.

**The chat template is checked before the server starts, since 0.12.2.**
Every thinking control above works by asking the chat template to render
the block one way or the other, and the server renders whatever template
the tokenizer directory carries. A tokenizer mounted from another
repository can carry a template without that branch, and on 0.12.1 and
earlier it silently accepted `enable_thinking: false`, `reasoning_effort:
"none"` and `HALOGEN_ENABLE_THINKING=0` and rendered thinking anyway. The
server now renders a one-message conversation with thinking off and on at
startup and refuses to start if the two do not differ the way the controls
assume, naming the file in one sentence; `HALOGEN_TEMPLATE_UNCHECKED=1`
serves it anyway, with the same sentence as a warning. The startup line
and `/health.chat_template` say which template loaded (the path and the
sha256 of its text) and whether the check passed, so a report about
thinking can start from that line. The weights repo's own `tokenizer/`
passes, and the entrypoint's fallback to it needs no mount at all.

**Your harness's own name for the thinking controls works, since 0.11.0.**
Besides `reasoning_effort`, `enable_thinking`, `chat_template_kwargs` and
`max_thinking_tokens`, the chat route reads `thinking_budget_tokens`,
`thinking_budget` and `thinking_token_budget` (the three names Pi's
`compat.thinkingTokenBudgetField` can send), the `reasoning` object
(`{"enabled": false}`, `{"effort": "low"}`, `{"max_tokens": 4096}`: the
OpenRouter shape, which hermes-agent and aider send) and the `thinking`
object (`{"type": "disabled"}`, `{"type": "enabled", "budget_tokens": 4096}`:
the Anthropic shape, which aider's `--thinking-tokens` sends to every
non-OpenRouter model). Two names with two different values is a 400, as
with the token budget. `/health` lists them under `supported`.

**Any of three field names works**, and they mean the same thing here:
`max_completion_tokens` (current OpenAI Chat Completions), `max_output_tokens`
(OpenAI Responses), or `max_tokens` (deprecated upstream, still widely sent).
Send one, or send several as long as they agree; two different values is a 400
rather than a guess about which you meant. `/health` lists all three under
`token_budget_aliases` and reports the current default as `max_tokens_default`.
`HALOGEN_MAX_TOKENS_DEFAULT` moves that default for every route. The card's
advice is not to cap the budget at all; here a request reserves its prompt
plus its budget in the KV pool when it is admitted, so a large default costs
concurrency (four slots at 65,536 is a whole 262,144-position pool before a
single prompt token). `-e HALOGEN_MAX_TOKENS_DEFAULT=16384` is the step that
clears an ordinary agentic turn's reasoning without that cost.
`HALOGEN_REASONING_EFFORT` moves the effort a request gets when it names none,
and the card's own guidance is to leave it at `xhigh`: lower effort on
multi-turn agentic tasks "can lead to insufficient analysis, more failures, and
repeated retries." A request that sends either field still wins.

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

**A quoted end-of-turn marker no longer ends the reply, since 0.13.4.** The
tokenizer has one token for `<|im_end|>`, so a model that writes or reads a
ChatML chat template in its reasoning writes the real end-of-turn token, and
through 0.13.3 the reply ended right there: `finish_reason: "stop"`, no
content and no tool call, on 15-25% of one agent's turns (#84). Inside the
thinking block that token is now kept as text and generation goes on;
inside an open tool call it is kept up to four times a reply (a template
written through a file-writing tool). The other half of the same report is
a model that writes a complete tool call inside its thinking block and then
ends its turn on it: that call is now made, with `finish_reason:
"tool_calls"`, and its text also stays in `reasoning_content`, where it was
streamed. A kept `<|im_end|>` and a quoted `<|im_start|>` appear in the text
literally (they used to vanish, so a quoted template came back with empty
spans). `usage.completion_tokens_details` carries `end_of_turn_kept` and
`tool_call_from_reasoning` when either happened, the request line in the log
says `end of turn kept as text`, and `HALOGEN_EOS_GUARD=0` restores 0.13.3's
behaviour. An end-of-turn token in the answer itself still ends the reply.

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

**Reasoning is returned** (since 0.7.0; #44). The model's thinking goes out
as a `reasoning` output item ahead of the message, its text as a
`reasoning_text` content part streamed in `response.reasoning_text.delta`
events, and `usage.output_tokens_details.reasoning_tokens` says how much of
the output it was (both routes carry that count). When the request asks for
a reasoning summary, as Codex does (`reasoning: {"summary": "auto"}`), the
same text is sent again as the item's `summary_text`, with the
`response.reasoning_summary_*` events: there is no separate summarizer, the
summary is the reasoning. Codex renders summaries by default and shows raw
reasoning content only with `show_raw_agent_reasoning = true` in its config,
so with that setting on you will see the text twice. No `encrypted_content`
is sent, and a `reasoning` item echoed back in a later turn is dropped, as
before. **There is no response store**, so `previous_response_id`, retrieving
a response by id, and cancelling one are not available; send the history with
each request, which is what Codex does.

**Statistics for llama-swap** (since 0.7.0; #45): every response, on both
routes, carries a `timings` object in llama-server's shape (`prompt_n`,
`predicted_n`, `prompt_ms`, `predicted_ms`, `prompt_per_second`,
`predicted_per_second`, `cache_n`, `draft_n`, `draft_n_accepted`), on the
non-streamed body and on a stream's last frames, so llama-swap's activity
page shows prefill and decode rates and the draft count. `draft_n` counts the
draft head's proposals and the prompt-lookup chains' together; the numbers
are the engine's own per-request line, copied.

**Prometheus** (since 0.8.0): `GET /metrics` answers in llama-server's
metric names, so a dashboard built for llama.cpp (or for llama-swap's
upstream) reads this server unchanged: `llamacpp:prompt_tokens_total`,
`llamacpp:tokens_predicted_total` and their `_seconds_total` counters (the
engine's own per-request numbers, summed; `prompt_n` is the processed count),
the `prompt_tokens_seconds` / `predicted_tokens_seconds` gauges over the
requests since the last scrape, `requests_processing`, `requests_deferred`,
`kv_cache_tokens` and `kv_cache_usage_ratio` (since 0.11.5 the engine's own
occupancy: the positions its pool holds in every region, busy and held,
over the pool, as of the last completed request; before 0.11.5 they counted
what the requests holding a front-end slot had asked for, admitted or not,
which read 913k against a 655k pool in issue #74). Beside them,
`halogen:requests_total`, `halogen:prompt_tokens_cached_total`,
`halogen:draft_tokens_total`, `halogen:draft_tokens_accepted_total`,
`halogen:structured_requests_total`, and since 0.11.5 `halogen:kv_pool_positions`
and `halogen:kv_pool_reserved_tokens` (the front end's reservation, the old
meaning). Always on, no flag, no engine round trip.

**Cache and pool occupancy in the log** (since 0.11.5; #73): every
request's `serve_api:` line carries the cached share of its prompt, the
prefill rate over the tokens actually processed, and the pool's occupancy
as the engine reports it: `prompt 30828 (30803 cached, 99.9%), prefill 0.38s
(25 new) | ... | pool 30976/524288 6%`. Since 0.11.9 the rate is printed
only when at least 2,048 tokens were processed (the cold turn before that
one read `prompt 30803, prefill 27.92s = 1103 t/s`); below that the line
says how many were new and leaves the rate out, because a few hundred
tokens in a second is one prefill chunk's fixed cost and not a speed, and
two reports had read it as one. `timings` in the response is unchanged. `GET /cache` adds `token_hit_rate` (prompt tokens the
cache covered over every prompt token seen since the server started;
`hit_rate` counts requests) and, under `pool`, `positions`, `used`,
`usage_ratio`, `busy_regions` (a request decoding), `held_regions` (a warm
conversation between turns, not a full pool), `room_clamped` and `moved`.
Since 0.11.9 `dropped` counts the entries a follow-up dropped to take its
region over (they went under `evicted` in 0.11.8), and a `/cache` polled
while the engine is inside a long cold prefill answers the last counters it
had with `stale_s` set, where it used to answer 500 after ten seconds.

**Structured output** (since 0.8.0; #14, #43). `response_format:
{"type": "json_schema", "json_schema": {"name": ..., "schema": {...}}}` and
`{"type": "json_object"}` on `/v1/chat/completions` and `/v1/completions`,
`text: {"format": {"type": "json_schema", "name": ..., "schema": {...}}}`
and `{"type": "json_object"}` on `/v1/responses` (the shape Codex sends; its
approvals reviewer sends one on every auto-reviewed tool call, which is what
#43 hit). The engine enforces the schema while it decodes: every token is
chosen from the tokens the schema allows next, so the reply parses and
validates by construction, with no retry and no repair. It is greedy
decoding under a mask, nothing else changes: the same request without the
schema is bitwise what it was, and a constrained request is identical
whether it decoded serially, with the draft head, with prompt lookup, or
beside other requests. It costs nothing measurable: the schema is compiled
once (a millisecond) and every state's mask lives on the GPU, so the decode
loop reads a pointer.

What is enforced: `type` (object, array, string, number, integer, boolean,
null, and `["string", "null"]`), `properties` with keys emitted in schema
order, `required` (an optional key may be skipped), `additionalProperties`
(`false`, `true`, or a schema: extra keys only after the listed ones),
`items`, `minItems`, `maxItems`, `minLength`, `maxLength`, `enum`, `const`,
`anyOf` (`oneOf` is treated as `anyOf`), `$ref` and `$defs` including
recursive ones. Accepted and not enforced: `minimum`, `maximum`,
`exclusiveMinimum`, `exclusiveMaximum`, `multipleOf`, and the annotation
keywords. Refused with a 400 naming the keyword: `pattern`, `format`,
`allOf`, `not`, `if`/`then`/`else`, `patternProperties`, `dependentRequired`,
`dependentSchemas`, `uniqueItems`, `contains`, `propertyNames`,
`unevaluated*`, `minProperties`, `maxProperties`, `prefixItems`. `/health`
lists all three under `structured_output`.

The reasoning block is not constrained: with thinking on the model thinks
freely and the JSON starts after `</think>`. A request with tools may open a
tool call instead of the JSON (the schema binds the final text, not a call),
which is how the Codex reviewer's own read-only tool checks keep working.
Whitespace between tokens is allowed, so a pretty-printed reply is fine, but
at most two whitespace-only tokens in a row (a forbidden preference
otherwise falls to a newline, and then another). Only the end-of-turn token
is legal once the value is complete, so the reply is exactly the JSON.
Temperature must be 0 (or omitted): a sampled request with a schema is a
400 for now, and so is a schema with an image. `HALOGEN_GRAMMAR=0` turns the
feature off (the 400 of 0.7.0 comes back).

Verified against the Codex CLI driving real tasks end to end, and separately
against the official `openai` Python SDK, which parses every event into its own
typed models.

---

### From an agent harness

Every coding-agent harness we read (Pi, opencode, Codex CLI, hermes-agent,
Cline, Roo Code, aider, oh-my-pi) follows the same sensible rule against an
OpenAI-compatible server it was not written for: send nothing the server
was not declared to accept. So none of them sends a thinking control unless
you configure one, and most cannot express "thinking off" at all against a
custom endpoint. Two consequences: **the server's defaults are what your
harness runs at**, and a compaction (which six of the seven build as a new
conversation, a cold prefill of the whole history under the harness's own
output cap) runs at the model's `xhigh` effort. The [answer
room](#token-budgets-and-why-an-empty-answer-means-you-ran-out) keeps that
from failing; these are the switches if you want it faster:

| harness | what it sends for thinking on a custom endpoint | to set effort or turn thinking off |
|---|---|---|
| **Pi** | `reasoning_effort` only with `"reasoning": true` in the model entry and a level other than off; nothing when off | `"reasoning": true, "thinkingLevelMap": {"off": "none"}` in the entry; a budget through `compat.thinkingTokenBudgetField: "thinking_budget"` (any of its three names works here) |
| **oh-my-pi** | as Pi: nothing when off | its own effort-map keys on the model entry, or the server variables |
| **opencode** | `reasoning_effort` low/medium/high when a variant is picked; no off variant for a custom provider | pick a variant, or `HALOGEN_REASONING_EFFORT` / `HALOGEN_ENABLE_THINKING=0` on the server |
| **Codex CLI** | `reasoning.effort` on `/v1/responses` only when `model_reasoning_effort` is set | `model_reasoning_effort = "medium"` in `config.toml` |
| **hermes-agent** | nothing to a custom base URL (its `reasoning_effort` setting reaches OpenRouter, Nous, LM Studio, Ollama and GitHub only) | the server variables; for the compaction summary, `extra_body: {enable_thinking: false}` under its auxiliary settings |
| **Cline** | `reasoning_effort` when set; "off" sends nothing outside its portable-provider list | set an effort, or the server variables |
| **Roo Code** | `reasoning_effort` (`none`..`high`) when the model info advertises reasoning effort; `disable` sends nothing | enable reasoning effort on the model and pick a level |
| **aider** | `--reasoning-effort` as `reasoning_effort`; `--thinking-tokens N` as `thinking: {budget_tokens}` | either flag; both are read here |

**Point the harness at this server as a provider, not as its own server.**
OpenCode has both: a provider entry in `opencode.json` (`"npm":
"@ai-sdk/openai-compatible"`, `"options": {"baseURL": "http://HOST:8731/v1"}`,
a model under `"models"`) is the one that reaches this server; `opencode
attach URL` and the `OPENCODE_SERVER` setting expect an OpenCode server and
probe `/global/health` and `/api/health`, which this server does not have
and should not answer (issue #91). hermes-agent's `/api/tags`, `/props` and
`/version` probes are its backend detection; the 404s are harmless and it
proceeds on `/v1/models`.

The server variables are `HALOGEN_REASONING_EFFORT` (the effort a request
gets when it names none; the card's advice is to leave it at `xhigh` for
agentic work), `HALOGEN_ENABLE_THINKING=0` (thinking off unless a request
turns it on) and `HALOGEN_MAX_THINKING_TOKENS` (a budget for requests that
send none). A request that names any of these wins over the variable.

**What the log says during a long turn, since 0.11.0.** The container log
prints `flash_serve: req N prefill P/T tokens, S s` at every 32,768-token
chunk of a long prompt and every 20 s inside one, and `req N generated K
tokens, S s` every 30 s of a long answer, so a 160k-token compaction that
takes minutes is visible while it runs rather than only in the `serve_api:`
line at its end. `/health` reports `busy_for_s` while a request is in
flight.

## Give it a machine of its own

This server holds most of the host once it is loaded: the weights stay resident
and the KV pool is reserved up front. On a 128 GB machine that leaves roughly
twelve gigabytes free, and very little of it in the large contiguous pieces
that another big process needs in order to start or to grow.

If you run application containers, a database, or another model on the same
machine, they compete for what is left. When it runs out, allocations do not
fail cleanly: the kernel goes looking for contiguous memory it cannot find, and
whatever asked for it, including this server, can stop for minutes at a time at
100% of one core with no disk activity and no output. It is not a crash, it
needs no restart, and it looks exactly like a hang.

Since 0.11.9 the container's watchdog knows the difference. Before it counts
a silent probe it reads the engine's thread states and the kernel's
compaction counter, and silence with a thread in uninterruptible sleep or
with `compact_stall` climbing is logged as `not counted as a wedge` and does
not take the container down. It matters more than it sounds: on the host in
issue #79 the old watchdog's kill landed on an engine in exactly that state,
twice, and the driver then kept the engine's GPU memory after the process
was gone, so every later start hung until the host rebooted (the end state
issue #34's two machines and our own gate machine each reached by a
different unclean exit). A restart policy turns that into a loop.

That deferral has a bound since 0.12.3. The compaction counter is host-wide,
so on a machine that compacts memory without pause it says nothing about
this engine, and until 0.12.2 the watchdog also restarted its clock on every
deferred probe: a reporter's engine sat wedged for 30 minutes, main thread
at 100% of one core, `/health` timing out, container up (issue #85). The
watchdog now prints the true silence on every line and, after
`HALOGEN_ENGINE_WATCHDOG_DEFER_S` (900 s) of deferral with the engine's
threads running rather than inside the kernel, takes the container down
with a line that says why. An engine with a thread in uninterruptible sleep
is still never killed.

Two host settings that come up here. `amdgpu.noretry=0` on the kernel
command line (ours has it) makes the GPU retry a lost page mapping instead
of faulting, which turns the fault in issue #83 into the silent engine in
issue #85: the same event, a hang instead of an error. And
`vm.compaction_proactiveness=0` does not stop the stalls and slows the
startup reservation, which waits on that compaction to build the KV pool;
a reporter measured both and restored the kernel default (issue #85). If
you run this server beside other work, read the watchdog's lines before
trusting a restart policy to recover anything, and see [the host settings
section](#the-host-settings-these-numbers-were-measured-on) for what a
start on such a host says. Issue #85 tracks the stalls and wedges under
host memory pressure across hosts.

The startup line says how much room is left, and a second line says why your
own tools will disagree:

```
startup [   4.9 s] host memory left for everything else: 465 contiguous 2 MiB
                   blocks (12.4 GiB total, most of it not contiguous)
startup [   4.9 s] free(1) and MemAvailable will report about 80.4 GiB
                   instead: the kernel counts this server's locked weights as
                   reclaimable file cache, and they cannot be reclaimed
```

**Believe the first line.** `free`, `MemAvailable`, and every monitoring tool
that reads them, count this server's locked weights as reclaimable page cache,
so they overstate the memory available on this host by the size of the model,
about 68 GiB. No kernel field reports the difference (`Mlocked` and
`Unevictable` both stay at zero across the load), which is why the server has
to print the correction itself. With `HALOGEN_WEIGHTS_LOCK=1` (below) the
weights are locked in the kernel's sense too, `Mlocked` and `Unevictable`
carry them, `free` and `MemAvailable` drop by their size, and the second
line is not printed because there is nothing to correct.

A few hundred blocks is normal for this server and is fine on a host of its
own. If that number is small and you have other work on the machine, expect the
above. Options, in the order worth trying:

- **Give it its own machine.** This is the honest answer for a server that
  holds this much of one.
- **Lower `HALOGEN_KV_POOL_POSITIONS`.** Fewer conversations stay resident at
  once; each one's speed and its answers are unchanged.
- **`HALOGEN_FLASH_PIN_TRUNK=0`** gives a great deal of memory back and costs
  **several times the decode speed** (6 tokens/s against 37 on the
  reference machine) and a fixed cost on every prompt of 64 tokens or more,
  which copies each layer's experts onto the GPU once: about 7 s when the
  weights are in the file cache (the whole reason for the setting is that
  they are no longer locked there) and 25 to 50 s when the kernel has let
  them go to disk. Measured: a 32,768-token prompt in 26.6 s against 26.7
  pinned and 8,192 in 8.8 against 7.1 with the weights cached; served, a
  6,500-token prompt in 28 s and 51 s on the first request after a start.
  It is a last resort, not a tuning option. Through 0.12.1 it did not work
  at the shipped settings at all (the first request ended the server with
  `internal sizing error in the per-forward arena`, issue #83); since
  0.12.2 it does.

- **`HALOGEN_WEIGHTS_LOCK=1`** (0.13.2, opt-in) is for the other direction:
  a host that is already short. "Reclaimable page cache" above is not only
  a reporting problem. The weights are registered with the GPU as ordinary
  file-backed memory, and this server also streams a 47 GiB lookup table
  through the same file cache on every request, so when the host is short
  the kernel reclaims weight pages to make room for table rows and the GPU
  driver has to tear down and restore the engine's mapping each time. That
  cycle is what the stalls in issue #85 and the read faults in issue #83
  look like from the outside. With the flag set the server `mlock`s every
  weight page it registers (never the table), which takes the weights out
  of that cycle entirely: the kernel cannot reclaim them, and the pressure
  lands somewhere visible instead. Measured both ways on two machines: a
  20 GiB co-tenant beside the unlocked server silenced it from the first
  request and the watchdog took it down after 15 minutes; a 12 GiB
  co-tenant beside the locked server, with under 1 GiB left on the host,
  got 81 of 81 requests answered at about 5 percent longer walls. The
  other side of that coin: a co-tenant that asks for more than the host
  has left triggers the OOM killer, and the OOM killer picks the process
  with the largest resident set, which is this server (its locked weights
  count). The container then exits with status 137 within seconds rather
  than sitting silent for 15 minutes, a restart policy brings it back, and
  it will be killed again until the co-tenant is gone. Neither is a way to
  share the machine; the lock just makes the failure fast and legible. Costs nothing on a warm start (the lock is a
  fraction of a second over resident pages; the startup line
  `checkpoint: locked ...` says how long and what `MemAvailable` did), and
  changes no output: the same bytes at the same addresses. It needs the
  memlock limit to cover the weights, and here the `--ulimit memlock=-1:-1`
  on every run line is not enough by itself: a rootless container cannot
  raise that limit above your user's hard limit, and Ubuntu's default is
  8 MiB (Podman clamps it silently; measured on a fresh Ubuntu 26.04
  install, where the lock failed after 0 bytes). Check with `ulimit -H -l`
  on the host; if it does not say `unlimited`, add
  `<user> hard memlock unlimited` and `<user> soft memlock unlimited` to
  `/etc/security/limits.conf` (or a file under `/etc/security/limits.d/`),
  log in again, and start the container from that login. The container
  says so at startup when it can see the limit is short, the engine says
  so again if the lock fails, and it runs unlocked either way. It is opt-in
  until the reporters on those two issues have run it. Memory the kernel
  can move by compaction is not held still by this flag; if that turns out
  to matter, the next step is a pinned allocation, and it will be a
  different value of the same flag.

Compacting memory afterwards does not help, because the memory this server
holds cannot be moved. If you need to reclaim it, stop the server.

### If you must share it

The 68 GiB of weights are pinned and do not move. Everything else the server
takes is decided by three settings, so sharing the machine means choosing
how much of the other half you keep. What each configuration takes is the
engine's own fit arithmetic (the same model the startup uses to size the
pool), and it does not depend on the machine; what is left does, so read the
`host memory left for everything else` line on yours and believe it over
`free`.

| configuration | device side | halogen takes | what you give up |
|---|---|---|---|
| the Quickstart defaults: pool 524,288, 4 slots, `MAX_TOK` 32768 | ~35 GiB | ~103 GiB | nothing |
| pool 262,144, 2 slots | ~28 GiB | ~96 GiB | one full-length conversation resident at a time |
| pool 262,144, 2 slots, `MAX_TOK` 16384 | ~19 GiB | ~87 GiB | the above, and prefill about 9% slower |
| context 131,072, pool 131,072, 2 slots, `MAX_TOK` 16384 | ~16 GiB | ~84 GiB | the above, and half the context |

A GGUF adds to the "takes" column: unsloth's `UD-IQ4_XS` holds 72 GiB of
weights instead of 68, and the K-quant `UD-Q4_K_XL` 78 to 80 GiB, so add 4
or 12 GiB to every row. The engine refuses the last pin when it would leave
under 16 GiB, and on a 122 GiB box the K-quant at the Quickstart's `MAX_TOK`
lands 2 GiB under that floor (issue #80); `HALOGEN_MAX_TOK=16384` is the
row that fits it. Since 0.11.9 the pre-flight check reads the GGUF's file
type and sizes the estimate accordingly, and the refusal names the levers.

Every recipe below assumes the weights are already in `~/halogen-models`
(the Quickstart's first start put them there). On Docker, replace
`--group-add keep-groups` with `--group-add video --group-add render`. With
the shipped `docker-compose.yml`, put the same variables under the engine's
`environment:`.

**Share about a third of the machine.** One conversation at the full
context stays warm between turns; two of them alternating re-prefill on
each turn; two shorter ones (100k each, say) both stay warm. Speed and
answers are unchanged.

```bash
podman run --rm -p 8731:8731 \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --ipc=host --ulimit memlock=-1:-1 \
  -e HALOGEN_KV_POOL_POSITIONS=262144 \
  -e HALOGEN_KV_SLOTS=2 \
  -v ~/halogen-models:/models:ro \
  ghcr.io/peonist-ai/halogen-flash-server:0.13.8
```

**The smallest footprint at the full context.** The prefill arena halves.
Prefill runs about 9% slower (measured at 262k through the server), and a
prompt admitted while another stream is decoding stalls it for half as long.
Nothing else changes.

```bash
podman run --rm -p 8731:8731 \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --ipc=host --ulimit memlock=-1:-1 \
  -e HALOGEN_KV_POOL_POSITIONS=262144 \
  -e HALOGEN_KV_SLOTS=2 \
  -e HALOGEN_MAX_TOK=16384 \
  -v ~/halogen-models:/models:ro \
  ghcr.io/peonist-ai/halogen-flash-server:0.13.8
```

**If 131k of context is enough.** The pool cannot be smaller than one
request's context, so a smaller context is what lets it go under 262,144. A
prompt at or past 131,072 tokens gets a 400 that says so.

```bash
podman run --rm -p 8731:8731 \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --ipc=host --ulimit memlock=-1:-1 \
  -e HALOGEN_CTX=131072 \
  -e HALOGEN_KV_POOL_POSITIONS=131072 \
  -e HALOGEN_KV_SLOTS=2 \
  -e HALOGEN_MAX_TOK=16384 \
  -v ~/halogen-models:/models:ro \
  ghcr.io/peonist-ai/halogen-flash-server:0.13.8
```

Two things hold for all of them. The lookup table (the n-gram embedding,
47.7 GiB, read from the file on demand) lives in the page cache, not in the
numbers above. A neighbour that pushes it out makes the next cold prompt
read its rows from disk before it starts: about 1.3 s on a 32k prompt from
an NVMe drive, more from a slower one, and the `lookup table: ... took N s`
log line reports any read of 2 s or more. And a neighbour that takes the
room this server was going to grow into produces the stall described above,
on both sides. The `host memory left` line is the budget. Size the
neighbours to it, not to `free`.

---

## Measured

**Conditions, because they change the numbers:** AMD Ryzen AI Max+ 395
(Radeon 8060S, gfx1151), 128 GB unified memory, ROCm 7.14.0, and **about 85 W
of sustained package power**, sampled from sysfs during a 32,768-token prefill
alongside a 2,229 MHz median clock against the part's 2,900 MHz top state.

**The IOMMU is off on the reference machine, and it is worth 13 to 16 percent
of prefill.** Prefill is compute-bound, and on this hardware an enabled IOMMU
is a power-budget tax rather than a memory-path one: with `iommu=pt` we
measured the SoC drawing more power (122 to 127 W against 108 to 118) for lower
shader clocks (2,357 to 2,409 MHz against 2,549 to 2,713) at the same
temperature, and prefill fell from 460 to 385 tok/s at 2,048 tokens while every
bandwidth-bound number held exactly. Bisected on one kernel, so it is the IOMMU
and not the kernel version. We have not measured the IOMMU in translated mode, only off against
passthrough, and this is one machine.

The full kernel command line this was measured on is published under
[The host settings these numbers were measured
on](#the-host-settings-these-numbers-were-measured-on), because numbers you
cannot reproduce are not much use.

**Match the power envelope before comparing decode numbers.** It is the
condition most easily left out and it moves these rows: an independent tester
running a 70 W-limited handheld measured 11 to 12 percent under both the serial
and the drafted figure below, consistently on both, which is the signature of a
lower envelope rather than a disagreement about the engine. Prefill reproduced
on that same machine.

The shipped checkpoint and its quality sidecar, in the image's default
configuration: full 262,144 context, prompt cache on, tuned GEMM plan loaded.
Prefill is a cold single-call prefill of real text; decode is greedy at
temperature 0. Prefill is measured by the engine's own
prefill bench; a served request with the default speculative drafter pays about
2-3% more time-to-first-token, because the draft head prefills too. The prefill
rows are 0.5.3's measurements. The control was this same binary with the
previous release's ordering step selected, so the two arms differ in one thing
and nothing else; it ran in the same session, on the plan this image bakes, and
it reproduced the rows it replaces to within 1.4%. The serial decode rows are 0.2.0's and have not moved since:
the releases between them changed the scheduler, the memory layout and one
host-side sort, not the decode kernels. 0.6.0 moves the speculative rows
twice, and both moves are draft-side: the sidecar now carries the draft
head's own projections at 8 bits (its proposals are accepted more often), and
the request's own text is a second draft source (the rows below the served
one). **The four 0.12.0 rows are served, through this image, at the 1M
configuration** (`HALOGEN_ROPE_YARN=4 HALOGEN_CTX=1048576`, which caps the
prefill arena at 16,384 and turns the prompt cache off): one cold request
each, synthetic non-compressible text, thinking off, 64 tokens generated,
the rates the response's `timings` report, and the previous release beside
each from the same session with the same prompt. Decode there is 64 tokens
straight after a cold prefill, with the draft head, so it is a served rate
in that shape (and its first steps read the lookup table from disk, since
a 1M pool leaves the table little page cache), not the ten-prompt mean the
32k row is. What moved between the releases is the model's sparse-attention
indexer: its block select ran serial in the context length on one compute
unit at decode and was a fifth of a 1M prefill pass, and its scoring kernel
re-read the block keys once per 16 query rows; both are rewritten in 0.12.0
with byte-identical results.

| | halogen-flash 0.5.3 |
|---|---|
| prefill @ 8,192 | **~1,246 tok/s** (TTFT 6.6 s) |
| prefill @ 32,768 | **~1,424 tok/s** (TTFT 23.0 s) |
| prefill @ 131,072 | **1,358 tok/s** (96.5 s) |
| follow-up turn at 100,000 tokens of context | **~2 s** (prompt cache on, the default) |
| decode, serial greedy @ ctx 1,500 | **37.6 tok/s** |
| decode, serial greedy @ ctx 8,000 | **36.1 tok/s** |
| decode, serial greedy @ ctx 32,768 | **34.1 tok/s** |
| decode, MTP speculation @ ctx 1,500 | **44.8 tok/s** prose, **49.9 tok/s** code (0.6.0 sidecar; 42.4 / 48.3 with the 0.5.x sidecar) |
| decode, MTP speculation @ ctx 32,768, served | **41.7 tok/s** mean over ten prompts |
| prefill @ 258,794, served, 1M configuration (0.12.0) | **1,114 tok/s** (232 s; 1,086 on 0.11.10) |
| prefill @ 1,004,581, served, 1M configuration (0.12.0) | **937 tok/s** (17.9 min; 790 and 21.2 min on 0.11.10) |
| decode, MTP speculation @ ctx 258,794, served, cold (0.12.0) | **45.0 tok/s** (42.9 on 0.11.10) |
| decode, MTP speculation @ ctx 1,004,581, served, cold (0.12.0) | **38.3 tok/s** (27.3 on 0.11.10) |
| decode, coding-agent turn, MTP alone (0.6.0 control) | **49.1 tok/s** thinking off, **49.2** thinking on |
| decode, coding-agent turn, MTP + prompt lookup (0.6.0) | **56.3 tok/s** thinking off, **55.7** thinking on |
| decode, function-calling turn, MTP + prompt lookup (0.6.0) | **53.1 tok/s** thinking off (48.8 with MTP alone) |

**The 0.6.0 rows are agent turns, not prose.** Each is the mean over six
prompts: a real coding-agent conversation (SWE-agent trajectories over real
repositories, driven by another model) or a function-calling dialogue, cut at
the start of an assistant turn, ~1,000–1,800 tokens of context, 400 tokens
generated, greedy. Prompt lookup drafts from the request's own text: when the
last three tokens of the answer already occur earlier in the conversation, the
three that followed are proposed as a chain and verified in one step, with the
draft head's own proposal opening the chain. On a coding turn about half the
generated tokens are such copies (tool-call arguments, paths, code quoting the
file being edited), thinking on or off, which is why the gain over the head
alone is 13–15% there, 6–9% on function-calling turns, and within noise on
prose and code text (the head already takes what there is). Serial on the same
prompts is 36.8 tok/s, so a coding-agent turn decodes at about 1.5x serial.
Every one of those runs produced the serial run's tokens exactly. Like the
draft head, prompt lookup runs while the request is the only one generating;
with several conversations generating at once the scheduler batches them
instead (the concurrency table below is unchanged by it).

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
| @ 8,192 | 373 | 385 | 436 | **1,246** | **2.9x** |
| @ 32,768 | 228 | 313 | 316 | **1,424** | **4.5x** |
| @ 131,072 | 121 | 196 | 174 | **1,358** | **6.9x** |

**The shape matters more than the ratio.** Every one of them decays hard with
depth. Ours does not: 1,246 at 8K, 1,424 at 32K, 1,358 at 131K. Their own documentation puts it plainly enough. A 156K
prompt takes EngramHalo about twelve minutes. We prefill 131K in 96 seconds.

Decode is the closer row. Against the fastest of them we are roughly 1.2x on
code and 1.7x on prose at short context, and the comparison at depth is muddied
by their speculative numbers mostly not being published.

**These are published figures, not a head-to-head we ran.** Every number in
the competitor columns is from their own model card or repository, on their
machine, at their quantization and their settings. We have not run their
builds. Their conditions differ from ours in ways that matter: EngramHalo
measures on a 96 GB machine rather than 128 GB, runs a q8_0 KV cache, and
quantizes the n-gram lookup table harder than we do, to 26.8 GiB against our
47.7 GiB. Keeping that table on disk is not one of the differences: we do the
same, by default and with no way to turn it off. Treat the prefill gap as real
and the decode rows as indicative.

### Served throughput, end to end over HTTP

The prefill numbers above are the engine's own prefill bench. Through the full
stack of chat template, tokenizer, HTTP and SSE, the image's own `sweep` mode
measures **812 tok/s at pp2048 and 1,041 at pp8192**, and `bench` over ten real prompt
shapes measures **45.3 tok/s mean with speculation** on the 0.6.0 image with
its sidecar (min 39.5 on chat, max 49.4 on procedural text; 1.63 tokens
committed per round; the 0.3.0 image read 43.6 on the same instrument, and
the difference is the draft head's 8-bit projections: these short prompts
give prompt lookup one to eight rounds a case).
Acceptance depends on how predictable the text is, so quote the mean with the
prompt set named, never a single shape.

That run also re-checks the identity property on live traffic: **every drafter
produced byte-identical output on every case.**

Reproduce the numbers with the benchmarks baked into the image:

```bash
podman run ... ghcr.io/peonist-ai/halogen-flash-server:0.13.8 bench serial,mtp 256 low 3
podman run ... ghcr.io/peonist-ai/halogen-flash-server:0.13.8 sweep -p 8192,32768 -n 128
```

---

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
The test can fail, and does. Since 0.9.1 those two misses are known to be the
attention budget's: at `HALOGEN_INDEXER_BUDGET=4096` both retrieve
([Attention budget](#attention-budget-opt-in-and-a-different-configuration)).
The 1,024 depth is the control: below the
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

**Which tensor families are stored at which precision is written out in
[`docs/QUANT.md`](docs/QUANT.md)**, along with what the sidecar changes and
what has not been measured. Bits per weight there is computed from the tensor
shapes in the checkpoint rather than quoted from a format name, so a format
whose real cost differs from its nominal one shows the difference.

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

## Bring your own GGUF

Since 0.7.0 `HALOGEN_CHECKPOINT` may name a llama.cpp GGUF of this model
instead of the engine's own checkpoint. The engine reads the file itself: at
startup it repacks every tensor but the lookup table into the layouts its
kernels read, **losslessly** (the file's own quantized values, moved, not
requantized), reads the lookup table from the GGUF in place, and takes the
draft head from a 1.4 GiB file of its own, because a GGUF carries no draft
head this engine can run. Nothing is written to disk unless you ask.

```bash
podman run --rm -p 8731:8731 \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --ipc=host --ulimit memlock=-1:-1 \
  -e HALOGEN_DOWNLOAD=peonist-ai/halogen-qwen3.8-flash-next \
  -e HALOGEN_CHECKPOINT=/models/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf \
  -v ~/gguf-models:/models \
  ghcr.io/peonist-ai/halogen-flash-server:0.13.8
```

Name any shard of a split; the siblings are found by name. With
`HALOGEN_DOWNLOAD` set and the volume writable, the first start fetches the
draft head (`qwen38-flash-next-mtp.hgn`) and the tokenizer from the weights
repo, 1.4 GiB in all; the GGUF itself is never downloaded by this image. Or
put both beside the GGUF yourself and mount the volume read-only.
`HALOGEN_MTP_HEAD` points at the head file if it lives elsewhere.

**Which files.** The repack is lossless where the format's values are a
small set times a per-block scale, which is the whole `IQ4_NL` / `IQ4_XS` /
`IQ3_S` / `Q4_0` family, `Q8_0`, `Q6_K`, and since 0.11.6 the K-quant
blocks `Q4_K`, `Q5_K` and `Q5_1` as their exact affine planes. Through
0.12.0 those types were read on some tensors and not others: the three
linear-attention projections of each DeltaNet layer (`attn_qkv`,
`attn_gate`, `ssm_out`) had to be `Q8_0`, `Q6_K` was read on the output
projection only, and the K-quants on the experts only, which is unsloth's
bit map (`UD-IQ4_XS`, `UD-Q4_K_XL`) and nobody else's: bartowski's and
mradermacher's IQ4_XS files were refused by name on their first DeltaNet
tensor (issue #20, the census by @Syakyr). **Since 0.12.1 every one of those
types is read on every tensor**, so bartowski's `IQ4_XS` loads as it is
(measured below), and so does any `llama-quantize` output in those types
with one exception: a K-quant or `Q6_K` on `ssm_out` is refused, because
the engine reorders that tensor's columns in 128-wide blocks at load and
those formats' scale groups are 256 wide (bartowski's `Q4_K_M` has that
shape, and `Q5_0` on its down experts besides; his `IQ4_XS` and `IQ4_NL`
do not). `Q4_1`, `Q5_0`, `Q2_K`,
`Q3_K` and the IQ2/IQ1 families stay **refused by name at startup**, before
anything is loaded, because reading them needs kernels for their block
layouts rather than a repack, and a lossy fallback would make "the same
file" untrue.

One of the newly read cases costs something and the log says so. A
K-quant (`Q4_K` / `Q5_K`) on a dense tensor rather than an expert has no
decode kernel of its own yet; the engine reads it losslessly and then
keeps a bf16 copy of it on the GPU (`affine trunk: N tensors staged to
bf16 on the device (X GiB)` at startup), which decode reads at 16 bits a
weight instead of 4.5 or 5.5. bartowski's `IQ4_XS` has twelve such tensors
(the attention output projections, 0.35 GiB); mradermacher's `i1-IQ4_XS`
has forty-eight, including the largest DeltaNet projection of every layer
(1.8 GiB). The kernel that removes this is on the list; the numbers below
include the cost as it stands.

**bartowski's `IQ4_XS` and mradermacher's `i1-IQ4_XS`, measured** (0.12.1,
the reference machine, unsloth's `UD-IQ4_XS` in the same session as the
control, MTP on in all three; the shipped checkpoint's own numbers are in
the table above):

| | unsloth UD-IQ4_XS | bartowski IQ4_XS | mradermacher i1-IQ4_XS |
|---|---|---|---|
| on disk | 94 GB, 3 shards | 91 GB, 3 shards | 91 GB, 1 file |
| held in RAM (repacked weights, head included) | 72 GiB | **68 GiB** | **68 GiB** |
| dense layers | 8-bit | 4-bit (+ 6 `Q6_K`, 12 `Q5_K`) | 4-bit (+ 48 `Q5_K`) |
| experts | IQ3_S / IQ4_NL | IQ4_XS / IQ4_NL | IQ4_XS / IQ4_NL |
| fixture agreement with transformers | 185/192 | 185/192 | 182/192 |
| perplexity, 32K tokens | 5.577 | 5.634 (+1.0%) | not run |
| prefill 8,192 / 32,768 tok/s | 1,237-1,239 / 1,420-1,422 | 1,244-1,267 / 1,423-1,425 | not run |
| decode, serial, short context | 26.0-27.1 tok/s | 26.1-32.2 | 30.1 |
| decode, draft head, short context | 27.9-30.2 (45% accepted) | 33.2-35.9 (51%) | 35.8 (53%) |
| speculative streams byte-identical to serial | yes | yes | yes |
| startup repack, cold disk | 20 s | 18 s | 6 s (warm page cache) |

The two 4-bit-trunk files read a gigabyte less per token than unsloth's
8-bit trunk and decode faster for it, staged tensors included; their
perplexity is a little higher for the same reason. Every one of these
files gets the same identity property: whichever drafter runs, the tokens
are serial greedy's.

The small tensors that unsloth keeps at F32 come out of other quantizers at
F16 (bartowski's and orcarouter's IQ4_XS files carry one,
`blk.1.ple_conv1d.weight`). Since 0.11.10 the engine reads F16 wherever its
own destination for the tensor is bf16: the values are widened exactly and
the repack's check that every value is bf16 clean still applies, so the file's
values arrive with their bits intact. What the quantizer's own F16 step
already rounded stays rounded: in this tensor 101 of 40,960 values sit under
F16's normal range (the smallest is 4.8e-8), and a file that carries them at
F16 carries them rounded to F16's grid. Such files usually come with a
llama.cpp draft head beside them (`...-MTP-draft.gguf`); that is not the
head this engine runs, and `HALOGEN_MTP_HEAD` pointing at one is refused at
once with the name of the file that is (`qwen38-flash-next-mtp.hgn`, above).

**The short version: the GGUF costs decode and 4 GiB of RAM, and nothing
else.** Same prefill, better perplexity, 24 GB less disk; serial decode about
28% slower and coding-agent turns about 22% slower, because its 8-bit dense
layers are 2 GB more to read per token. The full comparison:

**What it costs and buys, measured on the reference machine with unsloth's
`UD-IQ4_XS`** (the same file llama.cpp reads; the engine's own checkpoint with
its quality sidecar is the other arm; MTP on in both):

| | halogen's own checkpoint | unsloth UD-IQ4_XS on halogen |
|---|---|---|
| on disk | 118 GiB (two files) | **94 GB, the GGUF only** |
| held in RAM | 68 GiB | 72 GiB (the 8-bit dense layers, repacked) |
| perplexity, three corpora | | **0.7 to 2.1% better** |
| fixture agreement with transformers | 182/192 | 184/192 |
| prefill 8,192 / 32,768 | 1,246 / 1,424 tok/s | 1,246 / 1,423 (within 1%) |
| decode, serial, short context | 35.4 tok/s | 25.4 (**-28%**) |
| decode, draft head + prompt lookup, coding-agent turns | 55-57 tok/s | 42-45 |

The quality row is the interesting one: unsloth's file keeps the dense layers
at 8 bits and crushes the experts to about 3.4 bits, and that beats our
calibrated 4-bit dense layers over 4.5-bit experts. The decode row is the
price of the same bytes: an 8-bit trunk is 2 GB more per token at 240 GB/s,
and no lossless repack avoids it. Prefill is compute-bound and does not care.

**unsloth's `UD-Q4_K_XL`, the K-quant build (0.11.6).** Read the same way,
its own quantized values moved into the affine planes the kernels take with
nothing requantized, and measured against `UD-IQ4_XS` in the same session on
the same machine, MTP on in both. It is 104 GiB on disk and holds about
78 to 80 GiB in RAM (the engine's header estimate says 79.6), because its
`Q4_K` / `Q5_K` dense rows carry more bits than `UD-IQ4_XS`'s; on a 122 GiB
box that is the difference between fitting at `HALOGEN_MAX_TOK` 32768 and
needing 16384 (issue #80). It is the more accurate of the two: perplexity 0.020 nats
lower than `UD-IQ4_XS` over 32K tokens (0.033 lower than the engine's own
checkpoint, which both GGUFs beat), and fixture agreement 31/32 and 32/32
against transformers where `UD-IQ4_XS` scores 30 and 31. Prefill is the same
(1,267 / 1,440 tok/s at 8,192 / 32,768, within 2% of `UD-IQ4_XS`); serial
decode is about 3% slower (25.2 against 26.0 tok/s at short context) and the
draft head accepts about as often (49% against 45% on prose). It carries the
same 4 GiB of draft head and tokenizer and the same refusals; every
speculative stream is byte-identical to serial greedy on it too.

**Against llama.cpp on the same bytes, same machine, same session** (their
`strix-halo` branch, built and run at their settings on stock ROCm 7.14, so
their numbers here are below their own published figures; the ratios are
about this file on a stock box, and the decode ratio is the durable one):
prefill **1.9x at 8,192 and 2.7x at 32,768**; serial decode 1.1x at short
context and 1.3x at 32K; with the draft head 1.3 to 1.4x; on coding-agent
turns with both drafters **1.9x**. The identity guarantee holds on their file:
every speculative stream's tokens were byte-identical to serial greedy.

**Startup.** The repack reads the whole file once, on eight threads
(`HALOGEN_GGUF_THREADS`): **18 s from a cold disk on the reference machine,
9 s with the file in the page cache**, and every start pays it, because the
repacked weights live in RAM and the page cache is dropped behind them so the
file is not held twice. That is no slower than the engine's own checkpoint
loads from a cold disk on the same machine (about 30 s for its 118 GiB).
`HALOGEN_GGUF_CACHE=1` writes the repack out once beside
the GGUF (70 GiB; five minutes on the reference drive; `=<dir>` puts it
elsewhere) and later starts take the engine's own path: 1.4 s when the cache
file is warm, 16 s cold. It buys 7 s on a warm restart and 2 s on a cold one
here, since the cache file is larger than the bytes the repack reads; it is
for a host whose restarts are warm and whose disk is dear, not a requirement.
The write needs the volume mounted read-write with the room to spare;
without either it is skipped with a line in the log and the server starts
without it, and a file left half-written by a crash is removed on the next
start.
A cache is checked against the shards' sizes and modification times on every
start and is never used stale: with the flag set it is rebuilt, without it
ignored, both said in the log. `/health` reports `checkpoint_format` as
`gguf` or `gguf-cache`.

**What does not apply.** The quality sidecar is the engine's own checkpoint's
and is not loaded over a GGUF trunk (the log says so). The draft head is ours
and was fitted to our trunk; on unsloth's it accepts fewer draft tokens on
prose (45% against 59%) and the same on code, which is inside the decode
numbers above.

### Convert a GGUF once

Since 0.12.1 the image has a `convert` mode that writes the same lossless
repack to disk as a complete checkpoint of the engine's own kind, with the
lookup table and the draft head folded in, and exits:

```bash
podman run --rm \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --ipc=host --ulimit memlock=-1:-1 \
  -e HALOGEN_DOWNLOAD=peonist-ai/halogen-qwen3.8-flash-next \
  -v ~/gguf-models:/models \
  ghcr.io/peonist-ai/halogen-flash-server:0.13.8 \
  convert /models/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf /models/flash-next-iq4xs.hgn
```

Name any shard as the input; the output is one file, about 106 GB for an
IQ4_XS build (the repacked weights plus the 27 GB lookup table), written in
about ten minutes on the reference machine's NVMe. It needs the draft head
as a GGUF start does (`HALOGEN_MTP_HEAD`, or beside the GGUF, or fetched
with `HALOGEN_DOWNLOAD` and a writable volume). Then start the server on it
with `HALOGEN_CHECKPOINT=/models/flash-next-iq4xs.hgn` and no GGUF beside
it: the start is the engine's own checkpoint path (`checkpoint_format: hgn`
on `/health`; the log notes that it is a converted trunk and that the
quality sidecar does not apply), which loads in seconds from a warm disk
instead of repacking at every start, and the file can move to any machine
that runs this image. Nothing in it is requantized: byte for byte it is
what a GGUF start builds in RAM, so the outputs are the same. The command
is the engine's `flash_serve --repack IN.gguf --out OUT.hgn` with the head
and the checks around it (since 0.12.3 the table is written by default; on
0.12.2 and earlier `--repack` needed `--with-table`, and a file made without
it loads and stops at `no tensor named layers.1.ple.ngram_embedding.weight`).

---

## Measuring a checkpoint

Since 0.13.0 the image carries the tools this project measures its own
checkpoints with, as modes of the same container: `verify`, `inspect`,
`ppl` and `niah`. They take the same mounts as the server and no port,
they load nothing you do not already have, and every number they print
is on the same scale as the numbers in this README, because it is the
same engine computing it. They exist so that a quant you made, a GGUF you
pulled, or a fine-tune you converted can be checked and compared without
our fixtures, a torch install, or our word for it.

The run line is the server's without `-p`, plus the mode and its
arguments. Every example below abbreviates it as `podman run … halogen`:

```bash
podman run --rm \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --ipc=host --ulimit memlock=-1:-1 \
  -v ~/halogen-models:/models:ro \
  ghcr.io/peonist-ai/halogen-flash-server:0.13.8 \
  MODE [FILE] [flags]
```

`FILE` is any `.hgn` (the checkpoint, a sidecar, the draft head, the
vision sidecar) or, for `ppl` and `niah`, any shard of a GGUF; left out, it
is `HALOGEN_CHECKPOINT`, the file the server would serve. The tokenizer is
the one the server uses (`tokenizer/` beside the checkpoint, or the
`/tokenizer` mount), read from disk only. `ppl` and `niah` load the model,
so run them on a machine that is not serving at the time. `--json` on any
of the four prints one object on stdout for a script or an assistant to
read; the prose goes to stderr. Every one of them reads whatever file it is
given and refuses a malformed one with a sentence rather than a crash.

### Is this file what it says it is?

```bash
podman run … halogen verify /models/my-quant.hgn
PASS /models/my-quant.hgn: 1198 tensors, 115.55 GiB, v2, model_id qwen3.8-flash-next; header, table,
  layout, payload sizes, checksums, codebooks and scales OK; geometry checked on 1197 tensors (1 with no rule)
```

`verify` reads the file back independently of whatever wrote it: the
header, the table, every tensor's dims against the model's geometry, the
payload size each format implies, the per-tensor checksum over the bytes
on disk, codebooks in order, scales finite. It says `PASS`, or `FAIL` and
names the first tensor and what is wrong with it, and its exit status is
the answer. About 40 seconds on the full checkpoint from an NVMe, under a
second on a sidecar. Run it on anything you downloaded or converted before
you run anything else on it, and paste its line into any report of a bad
file.

### What does it actually carry?

```bash
podman run … halogen inspect /models/my-quant.hgn
  class                      format  count         params       bytes     bpw
  FFN (mlp)                  q4c       288   121032007680    68.58 GB    4.53
  embed_tokens               fp8g        1    51200245760    51.20 GB    8.00
  …
  FFN (mlp)                  bf16       48       62914560     0.13 GB   16.00
```

The precision by tensor family with bits per weight computed from the
shapes (so padding and scale planes are in the number, not hidden by the
format's name), then one sha256 per tensor in table order behind the hash
of the header and table. `--no-hash` skips the hashes and answers in a
second; `--json` gives every tensor's dims, format and hash as one object.
Two files with the same hash lines are the same weights.

### How does it compare to the shipped checkpoint?

Perplexity is the coarse number, and it hides more than it shows: two files
can read within a percent of each other and still disagree about the next
token at thousands of positions. So the comparison has two parts. The first
is a reference dump of the file you are comparing against, made once per
corpus (here the shipped checkpoint on the wikitext-2 test split; the
recipe for that text is below):

```bash
podman run … halogen ppl /models/qwen38-flash-next-w4b.hgn \
  --corpus /models/wikitext-2-raw-test.txt --ref-out /models/shipped-wikitext2.ref
/models/qwen38-flash-next-w4b.hgn: PPL 3.8522 (mean NLL 1.34864 over 297052 tokens, chunk 1024 = the prefill kernels)
```

The second is your file against it. This is unsloth's UD-IQ4_XS GGUF, as
downloaded, through this image (0.13.0, the reference machine):

```bash
podman run … halogen ppl /models/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf \
  --corpus /models/wikitext-2-raw-test.txt --ref /models/shipped-wikitext2.ref --worst 5
/models/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf: PPL 3.8109 (mean NLL 1.33786 over 297052 tokens, chunk 1024 = the prefill kernels)
  against /models/shipped-wikitext2.ref (top-128 support, a lower bound on the exact KL):
  KL(ref || this)  mean 0.136478  median 0.045499  p90 0.326418  p99 1.444613  max 11.698369
  top-1 agreement  86.463%
  delta p(target)  mean +0.005551  rms 0.116753  |dp| p99 0.510357
  the 5 positions the two files disagree on most:
    pos   9039  KL   11.70  ref p 0.000  this p 0.000  ' " Surfer Girl " , Elvis Presley \'s "' -> ' Blue'
      ref top: ' Jail' 0.99, ' "' 0.00, ' Jam' 0.00   this top: ' tongue' 0.23, ' All' 0.14, ' all' 0.09
    pos   9776  KL   10.06  ref p 0.994  this p 0.000  ' Rami Yacoub — writing , production , programming ,' -> ' instruments'
      ref top: ' instruments' 0.99, ' instrumentation' 0.00, ' guitar' 0.00   this top: ' \n' 0.56, ' \n\n' 0.15, '<|im_end|>' 0.03
    pos   9778  KL    9.82  ref p 0.708  this p 0.000  ' Yacoub — writing , production , programming , instruments ,' -> ' bass'
      ref top: ' bass' 0.71, ' guitar' 0.20, ' background' 0.04   this top: ' \n' 0.32, ' \n\n' 0.11, ' Carl' 0.03
    pos  13492  KL    9.16  ref p 1.000  this p 0.000  ' metres ( 11 @,@ 000 y' -> 'd'
      ref top: 'd' 1.00, 'dT' 0.00, 'dB' 0.00   this top: '0' 0.98, '4' 0.00, '\n\n' 0.00
    pos   9194  KL    9.15  ref p 0.944  this p 0.000  ' @,@ 000 increase in Facebook likes during the' -> ' week'
      ref top: ' week' 0.94, ' same' 0.02, ' video' 0.01   this top: " '" 0.21, ' video' 0.20, ' ' 0.08
```

What the lines mean:

- **PPL** is the teacher-forced perplexity of the corpus through this
  engine: the text is fed in chunks of 1,024 tokens on the prefill
  kernels, and the line says so, because a different chunk is a different
  forward pass and a different number. `--chunk 8` scores on the decode
  kernels, the arithmetic the server generates with; it is slower and it
  is a different number too. Inside the image the run is under the image's
  own engine environment (the baked tuning plan, the quality sidecar
  beside the checkpoint), which is what the server computes with; the
  mode prints that line first.
- **KL(ref || this)** is how far this file's next-token distribution sits
  from the reference's, per position, in nats, on the reference's 128 most
  likely tokens with everything else as one bucket. That makes it a lower
  bound on the exact value, tight where those 128 tokens carry the mass;
  the reference run prints how much they carried. Read the median and the
  percentiles before the mean: quantization noise is a median of a few
  hundredths, and a mean far above the median means a tail of positions
  where the two files disagree outright, as here (median 0.045, mean
  0.136, p99 1.44).
- **top-1 agreement** is how often the two files would emit the same token
  greedily. **delta p(target)** is how much probability this file gives the
  token that actually came next, relative to the reference; the mean says
  who is closer to the text on average (+0.0056: the GGUF, slightly), the
  rms and the p99 say how often they part ways.
- **`--worst N`** decodes the N positions the two files disagree on most:
  the context, the token that came next, and what each file expected
  instead. This is the line to read before deciding whether a difference is
  noise, a register a file is weak in, or a broken tensor. Above, the
  worst positions are places where one file is certain of a continuation
  the other does not consider, on both sides, which is what two different
  4-bit quantizations of one model look like when you look this closely.

`--vs OTHER` compares two files by PPL alone in one run (a paired
statistic: the mean per-token difference with a t and a 95% interval,
which resolves a half-percent difference two separate PPLs cannot). `--ids
IDS.bin` takes a pre-tokenized corpus of little-endian int32 ids instead of
text; `--per-pos P.bin` writes four floats per position (KL, delta p,
top-1, NLL) for your own plots.

**Which corpus.** There is no built-in text. A perplexity is a number about
a register: two files that read within a percent of each other on prose
can differ far more on agent transcripts, and the other way round, so use
the text you actually serve, and say which. For a number other people can
reproduce, use a public one: the wikitext-2 raw test split is the
convention. It is not ours to redistribute; the example above was made
from it exactly like this (the same bytes give the same numbers):

```bash
curl -sL -o wt2.parquet https://huggingface.co/datasets/Salesforce/wikitext/resolve/main/wikitext-2-raw-v1/test-00000-of-00001.parquet
python3 -c "import pyarrow.parquet as pq; open('wikitext-2-raw-test.txt','w').write(''.join(pq.read_table('wt2.parquet').column('text').to_pylist()))"
```

That is 297,053 tokens under this model's tokenizer, longer than the
native context, so the tool scores it as two consecutive sequences of
262,144 and says so (`--seq` sets the length). A dump is specific to a
corpus, a chunk and a sequence length; the tool refuses one made with a
different length.

One caution about sharing a reference dump: it holds the model's most
likely tokens and the true next token's probability at every position,
which is enough to reconstruct most of the text it was made on. A dump
made on private text is private text. Share dumps made on public corpora.

**What this is not.** It is not `llama-perplexity`, and the numbers do not
match it: llama.cpp scores fixed windows with half a window of context,
this scores one continuous stream at the chunk it prints; llama.cpp's KL
is against a base model's full log-probs, this is against a reference file
through the same engine, on a bounded support. It is a comparison between
two files under one engine, which is the question a quant answers. A
comparison against the BF16 model through transformers is a different
tool and is not in the image.

### Does it still find things at depth?

```bash
podman run … halogen niah /models/qwen38-flash-next-w4b.hgn \
  --corpus /models/wikitext-2-raw-test.txt --depths 4096,32768 --positions 0.05,0.5,0.95
retrieval by depth x needle position (hits / cases)
  T              p05       p50       p95       all
  4096           3/3       3/3       3/3      9/9    100.0%
  32768          3/3       3/3       3/3      9/9    100.0%
overall 18/18 = 100.0%
```

(The shipped checkpoint through this image; `--depths 131072,262144` are
the interesting ones for this engine and take minutes a case.)

A needle-in-a-haystack battery: three synthetic facts (codes no corpus
contains) are spliced into your text at the given depths and positions,
the document continues into a sentence whose next words are the fact, and
the model decodes greedily. A hit is the answer appearing in what it
wrote; the misses are listed with what it wrote instead. It measures
retrieval, not knowledge: a fact the model could know is not a test. The
filler is your corpus, repeated when a depth is longer than it; a depth
below 2,048 tokens is the control, where the engine's attention budget is
not yet in play. Deep cases take minutes each at 131k and above.

### Reading the output as an assistant

Every mode takes `--json`, and the files the modes write are small and
plain: the reference dump is a header (`HREF`, version, K, vocab,
positions) followed by fixed-size records, and `--per-pos` is 16 bytes a
position. `AGENTS.md` has the field lists. The pattern that works: `verify`,
`inspect --json`, `ppl --ref … --worst 20 --json`, then hand the object and
the per-position file to the assistant and ask it what the worst positions
have in common.

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
| **`2`** *(default)* | Saves its place at the end of the system prompt, at the start of the last message and at the end of every request | **~2 s** | no |
| `1` | Saves its place only at fixed checkpoints | ~17 s typical, ~32 s worst | **yes** |
| `0` | Never saves its place | ~88 s | yes |

The follow-up figures are measured over a 20-turn conversation growing from
90,000 to 108,000 tokens, adding about 1,000 tokens a turn.

**Use the default (`2`) for chat and agents**, anything where one conversation
gets longer. It is the only setting that helps short conversations: at the
shipped configuration, mode `1` saves nothing at all until a conversation passes
32,768 tokens, so ordinary chat gets no benefit from it. The default has no such
threshold; it starts working on the second turn, whatever the length. The first
request on a new prompt costs a little more than it would with the cache off,
the price of saving the state: about 1 to 2% of its prefill at any length
(a fixed 0.15 s or so on the reference machine, mostly the two saves
themselves), paid once per new prompt, never on a hit. From 0.11.3 to
0.12.0 that first request cost about 5% instead, at every length, because
the save re-ran part of the model over the prompt; 0.12.1 records the state
as the pass goes by (the changelog has the numbers and the credit). To
reproduce a cache-off benchmark figure, set `HALOGEN_PROMPT_CACHE=0`; the
default's first-request cost is what a benchmark that sends every prompt
once measures, and its second-turn saving is what a conversation measures.

**Use `1` when you need the same prompt to always give the same answer**:
evaluation suites, regression tests, A/B comparisons, or anything audited. With
`1`, an answer served from the cache is byte-for-byte what a cold run would have
produced. With the default it usually is, but not always.

Since 0.11.3 that "not always" applies only to a request that actually
*resumes* from the cache and continues past it. A request the cache has
nothing for (the first turn, or any prompt whose prefix is not held) answers
byte-for-byte what modes `1` and `0` would: the server used to split such a
request's forward pass at the point it saved, and now captures the state
mid-pass instead (issue #65 was a cold request under the default mode
landing on a wrong answer at `temperature 1.0` that mode `1` did not
produce). An exact repeat of a request also answers byte-for-byte its first
answer: the server keeps the state at the end of the last request and
restores it whole. `/health` reports the saved place's alignment as
`snapshot_align: 64`: the place is the last 64-token boundary before the end
of the system prompt or of the history, and the next turn re-reads at most
63 tokens.

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

**A long document, then a different question each time.** A client that
keeps a document in one message and asks each new question in the next
(`[document][question 1]`, then `[document][question 2]`) used to miss under
the default: the saved places were the end of the system prompt and the end
of the previous request, and a new question matched neither, so every
question re-read the document and only an exact repeat was served from the
cache (a 1M-context reader on the Hub saw exactly this, and the advice then
was to put the document in the `system` message, which still works). Since
0.12.1 the default also saves its place at the **start of the last message**
of the request, so the second question resumes from the end of the document:
measured on a 30,000-token document, the second question is served 99%
from the cache and answers in 1.3 s where it took 26 s cold. The extra
save costs nothing measurable (the state is recorded as the pass goes by,
see the first-request cost above) and nothing on a hit; a request whose
last message is its only message has nothing behind it and gets no third
place. `HALOGEN_CACHE_SNAP3=0` turns it
off. With that, mode `1`'s remaining advantage is the strict one: an answer
served from the cache under `1` is byte-for-byte the cold answer, under the
default it usually is.

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

**Check what pool you actually got.** The fit at startup budgets `MemTotal`
less the resident weights (67.7 GiB) and `HALOGEN_HOST_RESERVE_GIB` (20), and
a 524,288 pool at `HALOGEN_MAX_TOK=32768` needs about 36.7 GiB (14.4 for the
pool, 20.6 for the arena and the slots, 1.7 of margin). A 128 GB machine
whose `MemTotal` reads 125 GiB fits it; one that reads 122.7 GiB (a
`crashkernel` reservation of 2 GB is enough) does not, and the pool halves
to 262,144 with the line `kv pool: 524288 positions need ~36.7 GiB ...
LOWERING THE POOL TO 262144` in the startup log. Every request line since
0.11.5 ends with `pool N/<positions>`, so a grep settles it. On such a
machine `HALOGEN_MAX_TOK=16384` gives back 8.8 GiB (about 9% of prefill
speed) and 524,288 fits; at `8192` even 786,432 does (issue #75).

**Sizing for a fan-out harness** (a parent that runs subagents in parallel,
issue #75). Every live conversation holds `prompt + max_tokens` between its
turns, so the pool must hold their sum: `pool >= sum over live conversations
of (prompt + max_tokens)`, with `max_tokens` the client's, not the server
default, when the client sends one. A subagent's prompt grows by the whole
of each turn's generation when the harness replays the reasoning into the
next request (Pi with `reasoning: true` does; the Qwen template keeps it),
so a child that thinks for 25k tokens a turn under a 32k budget grows by
about 26k a turn: a parent at 50k and two children at 80k each start at
`82k + 112k + 112k = 306k` and pass the default 524,288 by their fifth turn.
When they do, a move cannot help and one conversation is forgotten by the
least-recently-used rule; the log says which. The levers are the pool
(`786432` holds that shape for about four more turns, by which point the
children are near the 262k context in any case), the client's budget (a
harness that uses 2k of 32k can send 8k), and fewer parallel subagents.

One cost the pool does carry. A larger pool leaves less RAM for the model's
file cache, so the first prompt after a restart reads its rows of the lookup
table from disk. Before 0.6.3 those rows were read one at a time and a
32,000-token prompt took up to twice its usual 25 s right after a fresh start
(up to 50 s more with the table fully evicted). Since 0.6.3 the rows are read
64 at a time: on this machine's NVMe drive the same first prompt costs about
1.3 s more than its usual time, and an 8,000-token one under half a second.
The log line `lookup table: ... took N s on 64 threads` reports it whenever it
takes 2 s or more. `HALOGEN_KV_POOL_POSITIONS=262144` still leaves more of the
table cached, and `786432` buys a third resident conversation where the
machine has the headroom for it.

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

Re-measured on the 0.6.0 image in one session: 2 streams 56.5 total, 4
streams 77.1, every stream byte-identical to alone. Prompt lookup does not
change these rows: like the draft head, it drafts only while a request is the
only one generating (see below), and a batched step is already the cheapest
way to get one token per stream on this hardware.

**Slots are a latency policy, not a memory decision.** Raising
`HALOGEN_KV_SLOTS` past four trades what each client sees for admitting more
clients at once instead of queueing them; past eight the total stops growing.
Four is the default because it keeps per-stream speed where the numbers in
this document were measured. Slots cap admission: a client past the count
queues rather than diluting the batch, so with five workers on four slots
each admitted stream still decodes at the four-stream rate and the fifth
waits. A reporter's sweep on a five-worker aider fleet (issue #51) read the
per-turn wall at 42 s on four slots against 46 on three and 52 on two, and
14.9 t/s per stream on eight slots against 18.7 on four; for reply-heavy,
cache-hostile clients the default is the right setting even when more slots
would fit.

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
holds the others back; prompt lookup rides with it and follows the same rule.

The prompt cache keeps twenty-four entries (`HALOGEN_CACHE_ENTRIES`;
twenty from 0.12.1 to 0.13.2, sixteen before), six per conversation: one at the end of its system prompt,
three at points in its history (the ends of earlier requests, and since
0.12.1 the start of the last message, above), and since 0.11.3 one at the
end of its last request, which serves an exact repeat of that request
without reading anything again (`HALOGEN_CACHE_FULL=0` turns that one off). Since 0.8.1 a conversation holds a fixed number of entries: a new
turn's history entry replaces an older one rather than adding to the list,
so a long tool-calling session cannot push other sessions out (before that,
eight tool calls in one session evicted every other conversation, issue #54;
the count shows as `superseded` on `/cache`). Since 0.11.0 it keeps the
most recently *used* history entries, not the newest, because of a
client pattern that the newest-only rule broke (issue #61): a harness that
sends the whole history plus a side question (oh-my-pi's idle recap does)
and then drops that turn from its history continues from where the side
turn branched, and with only the newest entry kept that point was gone and
the next turn re-prefilled everything after the system prompt. Now the side
turn hits the true history entry and stores its own beside it, and the next
real turn hits the true one again. Conversations taking turns each resume
from their own state, and requests that share a system prompt and ask
different things, together or in turn, resume from it as well. More than
four deep conversations at once wants `HALOGEN_CACHE_ENTRIES` raised by
one conversation's worth for each extra one (about 115 MiB of host RAM per
entry, and the KV rows an entry covers stay reserved while it exists); from
0.13.3 a value too small to hold one conversation's worth per slot says so
at startup instead of quietly costing a conversation its history. A
**fan-out**, where one parent conversation is forked into several children
that all live in the same region, wants `HALOGEN_CACHE_BRANCHES` raised
instead: it is two by default, which is a conversation plus one side turn,
and on two the parent's resume point is the one the children's stores
replace. The server prints the memory budget at startup and warns before
the allocator refuses.

When the KV pool has no room for a new request, the server forgets the
least recently used conversation's region and says so in the log (`kv
pool: no room for N positions; forgot the region at ...`); the entry the
request is about to resume from is never the one forgotten, and a
conversation whose only stale entries are dead side turns grows its own
region in place rather than displacing another conversation. **Through
0.13.2 that last guarantee did not hold when conversations shared a system
prompt** (issue #94): a conversation that had lost its own history would
match the shared resume point at the end of the system block inside
*another* conversation's region, and the server, which had no way to tell
whose region it had matched in, would drop that conversation's history and
take the space before it had considered giving up any idle space. From
0.13.3 it gives up an idle region first and only takes a live
conversation's as a last resort. Before 0.11.0
the eviction order could drop the very entry the request had matched, which
read as an unexplained cold prefill (issue #61). When nothing else is left
to forget and the request still has no span, because the conversation's own
region sits where the reservation cannot reach (the upper half of the pool,
with a reservation past half of it), the server moves that conversation's
rows into the free span and the turn stays a cache hit (`kv pool: ... moved
the N rows this request resumes from, region A -> B`); when the rows cannot
be copied there it forgets them and the turn runs cold. Before 0.11.4 that
request waited for room that could never appear, with the health probe
answered throughout (issue #68). A request that waits for a *busy*
conversation to retire says so once in the log (`kv pool: request N waits
for M positions ...`), and `/cache` reports it under `pool`
(`waiting_for_room`, `waiting_s`, `relocated`, `cold_resorts`). Since
0.11.7 that move is the FIRST thing tried when a region cannot grow, not the
last: the conversation's own span counts as free, its rows move into any
span that holds them, overlap or not (the copy goes in block-aligned chunks
in the safe direction, `moved the N rows ... in 12.3 ms`), and when held
neighbours are what stand in the way they are moved up against the next
busy region so the region grows in place (`kv pool: ... moved N held
regions ... grows in place (no loss)`, counted as `packed`). Only after
every no-loss step fails is another conversation forgotten, and
`cold_resorts` reads 0 from 0.11.7 on. Before that, a harness fanning out
two subagents beside a parent (issue #75) had the parent forgotten on every
child re-bind (with both children decoding, the parent's region was the
only one the least-recently-used rule could reach) and then the children
forgetting their own rows on alternate turns; the same workload fails the
same way on 0.11.4, so it was the allocator, not the 0.11.5 change.

A conversation keeps its whole reservation between turns, and since 0.11.5
its next turn uses it. A follow-up whose region cannot grow (another
conversation's region sits directly after it) runs in the room the region
has left, with `max_tokens` clamped to that room, when the room is at least
the answer room (`max(1024, 15%)` of the request's `max_tokens`, twice that
when the request thinks). The log says so (`kv pool: the region at A this
request resumes from cannot grow; the turn runs in the N positions it has
left (max_tokens 32768 -> 30521)`), the request line ends with `max_tokens
clamped 32768 -> 30521`, and the response's `timings` carries
`max_tokens_clamped_from` and `max_tokens_clamped_to`, so a `finish_reason`
of `length` on such a turn is legible. Since 0.11.7 the clamp comes AFTER
the moves above: it runs only when no span anywhere holds the region, so a
harness whose turns use their budget keeps the whole budget at the cost of
a copy (issue #74's own shape now runs warm with zero evictions and no
clamp, its two sessions leapfrogging by a 7 ms copy a turn), and the clamp
remains for a pool with nothing left to move. When the room is smaller than the
answer room, or the conversation resumes from a region another request is
decoding in, the rows are copied to a fresh span, and since 0.11.5 a held
region whose longest entry the request resumes from is *moved* (`kv pool:
moved the N rows this request resumes from, region A -> B ... the old
region is free`) rather than copied and left behind, so a stale duplicate
never competes with a live conversation for the pool. Since 0.11.8 all of
this applies whether or not the client sends `reasoning_content` back; on
0.11.7 a client that did not was on the older path (issue #75, the second
report). Before 0.11.5 two
long conversations taking turns behind a shared system prompt forgot each
other on every turn (issue #74): the first's growth could not extend or
copy, the second's region was the only one to forget, and each turn
re-prefilled the whole history at 100 to 160 s.

**What the pool leaves the host.** The engine prints, once loaded, how much
host RAM is left after the weights and the pool (`host memory left for
everything else`), and since 0.11.4 says under about 10 GiB what that
means: the lookup table is read from disk through the page cache and never
held, so that figure is the cache it gets, and below it the table's rows
page in on every long prompt, a prefill takes minutes instead of seconds,
and the watchdog can read the stall as a wedge. A reporter's measurements on
a 128 GB machine with other services resident (issue #35), the pool the only
change:

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

The machine this document's numbers come from runs the default pool at
about 12 GiB left and does not page; the line between the two rows above
is where the note fires. `HALOGEN_KV_POOL_POSITIONS` and `HALOGEN_MAX_TOK`
are the two levers; stopping other resident workloads is the third.

`HALOGEN_MAX_TOK` (default 32,768, capped at the context) is the widest single
prefill call, and it sizes the working memory the server holds beside the
pool, which is a good deal more than the GEMM arena alone: the startup
line's `working memory` reads **21.3 GiB at 32,768 and 12.5 GiB at 16,384**
on the 0.11.4 image. Halving it gives back 8.8 GiB for
about 9% of prefill speed, a long prompt read in more pieces, and the
answer byte-identical. That made it the lever on the same reporter's next
two boxes (issue #35), both shared with other work and both already
auto-lowered to one full conversation of pool, so the pool could not go
lower without cutting what one request may use (box A / box B):

| | before | after |
|---|---|---|
| `HALOGEN_MAX_TOK` | 32,768 | 16,384 |
| pool | 262,144 (auto-lowered) | 393,216 (set) |
| working memory | 21.3 GiB | 12.5 GiB |
| host memory left | 11.8 / 16.1 GiB | 17.1 / 20.5 GiB |
| free contiguous 2 MiB blocks | 79 / 123 | 823 / 1,136 |
| compaction stalls reserving the pool | 194 (194 failed) / none | 0 / 0 |
| startup to "engine listening" | 97 s / 50 s | 18 s / 7 s |

Longer prompts are prefilled in pieces. Do not raise it to the native
context. That allocation does not fit, and the server will not start.

### Prompt cache on disk: resume a conversation after a restart

By default the prompt cache lives in memory: it makes a follow-up turn in the
same running server resume where the last one stopped, but a restart loses it,
and the next turn re-reads the whole conversation. Point `HALOGEN_CACHE_DIR` at
a directory and the cache also lands on disk, so a conversation survives a
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

Each build of the engine, each weights file and each context size keeps its
own subtree of the directory, and the bound above applies to the current one
only: an upgrade leaves the previous build's subtree behind, readable by
nothing but that build. The startup log counts them (`N other
configuration(s) hold X GiB there`). `HALOGEN_CACHE_PRUNE_OLD=1` removes
them at startup and names each one with its size (0.11.10, issue #78); the
default keeps them so a rollback finds its cache warm.

Two things worth knowing:

- **It is exact.** A conversation restored from disk continues from the same
  attention state it was saved with, byte for byte across the restart; it is
  the same "resume anywhere" cache as in memory, not a re-read.
- **The write rate falls as the pool fills.** Saving a turn's rows copies them
  out of device memory, and near the memory ceiling that copy slows (from
  several GB/s when the pool is a third full to a few hundred MB/s when it is
  near the top). Because the write is behind the request it does not slow the
  answer, but a machine that keeps very long conversations (past ~64k tokens)
  warm across restarts should shrink the resident pool with
  `HALOGEN_KV_POOL_POSITIONS=262144`, which keeps the copy at the drive's
  rate. For ordinary chat and agent sessions at the default pool the write is
  several GB/s and this does not arise.

Each distinct configuration keeps its own files, keyed to the exact engine
build, weights, context, and every setting that changes the saved bytes, so a
different build or setting never restores another's state; the others are kept
untouched. Stopping the server flushes the last turn before it exits, so give
it a moment to stop (the bundled compose sets a 60-second stop grace period).

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
  prints it. Since 0.12.0 a 1,004,581-token prompt prefills in 17.9
  minutes (937 tok/s, served, cold) and decodes at 38 tok/s with the
  default speculative drafter, 32 serial in the engine's own harness; on
  0.11.10 the same request took 21.2 minutes and decoded at 27 (19 serial),
  and 0.2.0's figure was 22-24 minutes and 19 serial. A 258,794-token
  prompt prefills at 1,114 tok/s and decodes at 45 with the drafter (35
  serial in the harness; ~28 before 0.12.0). Decode at depth now costs what
  reading every block's key costs, about 3.6 ms a step at 1M, on top of the
  short-context step. The conversation then continues at ordinary speed
  where the prompt cache is on: it keeps the attention state in place and
  saves only its small position-free part, so a follow-up turn at
  1,000,000 tokens reached its first token in 0.55 s on the test machine
  (0.45 s at 262,144), against the cold prefill. The context must leave
  room for the generation: a prompt at exactly the context is refused.

### Attention budget: opt-in, and a different configuration

The model's sparse attention scores every 4-token block of the context with a
small indexer and attends the top 512 blocks (2,048 tokens) per query; the
checkpoint's config sets that budget and this server runs it by default. It can
be raised at startup, and it is off unless you ask:

```
HALOGEN_INDEXER_BUDGET=4096
```

Unset, or set to 2048, nothing changes (byte-identical). Set higher, it is a
different model configuration, not a cache setting: every query past the budget
attends a superset of what the checkpoint was trained to attend, so the answer
to a long prompt is not the same answer. Accepted values are 2048 to 8192,
rounded down to a multiple of 16; the effective value is printed at startup and
reported by `/health` as `indexer_budget`. It is static for the server's life.
What it buys and costs, measured on the same machine as the tables above, the
default beside each arm in the same session:

| | 2048 (default) | 4096 | 8192 |
|---|---|---|---|
| retrieval battery, 16k + 32k rows, 96 cases | 94/96 | 95/96 | 96/96 |
| perplexity, prose / code / agentic transcript | | +0.1% / +0.3% / −0.4% | +0.5% / +0.3% / +1.1% |
| prefill 8,192 tokens | 1,271 tok/s | −4.5% | −4.5% |
| prefill 32,768 tokens | 1,426 tok/s | −6.7% | −19% |
| decode at 32k, serial / with the draft head | 34.5 / 36.3 tok/s | −2.3% / −2.8% | −4.5% / −7.9% |

At 4096 the two misses of the default's battery (the `16,384` row above, both
the same needle) retrieve, and one different case is cut off at the end-of-turn
token; perplexity moves within noise, with a structure worth knowing: the
hardest predictions get better and the easy ones (verbatim copying) a little
worse, most visibly on agentic transcripts. At 8192 every planted fact
retrieves, but perplexity is a consistent cost on all three corpora and prefill
pays a fifth. Speculative decoding stays byte-identical to serial at every
budget. The cost is the attention kernel gathering more keys per query; nothing
else in the pass changes.

If your workload is long-context lookup (a fact buried in a large document or
transcript, asked about much later) and you can spare 7% of prefill, 4096 is the
setting to try; measure it on your own prompts, because the retrieval battery
is a retrieval test and not a general one. Reported as
[issue #57](https://github.com/peonist-ai/halogen-flash-server/issues/57).

### Composable context: an opt-in preview

An agent harness eventually **compacts** a conversation: it replaces the early
turns with a short summary and keeps the recent tool results verbatim, so the
context fits. Today that costs a full re-prefill of everything after the
system prompt, because the kept results now sit at new positions. Composable
context removes that cost for the kept results, and it is off unless you ask:

```
-e HALOGEN_COMPOSABLE_CONTEXT=1
```

With it on, each message at or above `HALOGEN_COMPOSABLE_CONTEXT_FLOOR`
(default 2048 tokens) is retained in a host store
(`HALOGEN_COMPOSABLE_CONTEXT_BYTES`, default 4 GiB, least-recently-used; in
the server's memory, not on disk, and gone at restart) as it is first read. When a later request repeats that message at any offset behind
the same system prompt, the server reuses the retained work instead of reading
it again. On the test machine a compaction that kept ~8,700 tokens of tool
results was restored in about 0.13 s where reading them fresh costs ~14 s, and
the finish line reports `composed 5 chunks`.

It needs the resume-anywhere prompt cache and the KV pool, which are the
serving defaults (`HALOGEN_PROMPT_CACHE=2`, `HALOGEN_KV_POOL=1`); it refuses
image requests. `/health` reports it under `composable_context`.

**It is not the prompt cache, and it is honest about that.** The prompt cache
is exact: a resume is byte-identical to a fresh run. Composable context is not:
a reused answer is very close to, but not identical to, the one you would get
by reading the text fresh, and quality is otherwise unchanged (retrieval in
testing held at the same rate as reading fresh). That is why it is opt-in and
its own switch. **With the flag off, nothing changes and every byte-identical
guarantee above still holds.**

This is a preview, and the flag and defaults may change. On the roadmap for it:

- **closer to exact** — narrowing the small difference between a reused answer
  and reading the text fresh;
- **broader reuse** — reusing material across separate sessions and
  sub-agents working the same files, not only within one conversation's
  compaction;
- **a smaller footprint and a durable store** — less memory per retained
  message, and an optional on-disk store that survives a restart and holds
  far more than the in-memory one.

---

## Troubleshooting

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
will not start, halve the prefill call as well with `-e HALOGEN_MAX_TOK=16384`,
which gives back about 8.8 GiB (the startup line's working memory, 21.3 to
12.5 GiB) for about 9% of prefill speed; the [memory
section](#context-and-memory-one-kv-pool-several-conversations) has the
measured table.

A start that ends in `checkpoint: refusing to pin ... the floor is 16.00
GiB` instead is the same arithmetic one step later: everything fit except
the last pin, and finishing it would leave the host under 16 GiB, where the
lookup table pages in from disk on every long prompt. Since 0.11.9 that line
says how far short the configuration is and lists the levers in order;
`HALOGEN_MAX_TOK=16384` is usually the one. A K-quant GGUF on a 122 GiB box
is the case that found it (issue #80): the pool was already at one context,
so the pool fit had nothing to lower, and the pre-flight estimate carried
the smaller GGUF's weight size.

### If the server hangs at "reserving the KV pool"

A start that prints `reserving the KV pool` and then nothing for many
minutes, with `still reserving` lines whose compaction counts climb and a
process that `podman stop` cannot end, is not the out-of-memory case above.
The pool lands in GTT, the driver's own window on system RAM, and a start
that cannot place it there does not fail: it blocks inside the driver. On
four hosts (issues #34 and #79, and our own gate machine) the cause was
memory a previous GPU process's exit did not give back: a process ending
while the GPU had work in flight (another model's exit, a watchdog kill
under a memory stall, a `podman restart` mid-reservation, a cancelled
request on a busy queue), after which 35 to 45 GiB of GTT stayed allocated
with no process alive, on two of them with a kernel worker
(`svm_range_restore_work`) in uninterruptible sleep. Since 0.11.9 the
container reads the driver's counters before it starts and says so:

```
halogen: GTT in use before this start: 34.9 GiB of 120.0 (85.1 free; this start puts about 31.6 GiB there)
halogen: WARNING 34.9 GiB of GTT is in use and no process holds the GPU, as far as this container can see
```

If that warning appears, check on the host (not in the container) that
nothing holds the device, `fuser -v /dev/kfd`, and that the figure does not
fall on its own, `cat /sys/class/drm/card*/device/mem_info_gtt_used`.
Removing containers does not release it and neither does waiting; reboot the
host before starting the server again. When the GTT is held by another
process the line says that instead, and the server starts on what is left;
when what is left is less than the pool needs, it refuses at once rather
than blocking. What puts a host there is the kill, and since 0.11.9 the
watchdog no longer kills an engine that is silent inside the kernel (see
[Give it a machine of its own](#give-it-a-machine-of-its-own)). A start
that grinds at `reserving the KV pool` with `compaction stalls` climbing
and no GTT held is the other case: the host's free memory is not in
contiguous pieces large enough (other processes hold it), and freeing them
lets the reservation complete at once. That, and the stalls and wedges the
same pressure causes while serving, are tracked in issue #85.

A GPU memory fault (`Memory access fault by GPU node-1 ... Page not present`)
is a different failure, and since 0.12.2 the container ends it in seconds:
on 0.12.1 and earlier the bundled runtime then wrote a GPU core dump of the
whole process (`GPU coredump: ... Falling back to file-based dump`), which
for a process with over 100 GiB mapped is minutes in uninterruptible sleep
before the engine can exit, read by the watchdog as the memory case above.
The container now disables that dump and the process's core file, so the
fault line is followed by the engine's exit and the takedown path, and the
log holds the fault's own decode (issue #83). The fault itself is reported
on one host (kernel 7.2.5) and not reproduced on the reference host (7.1.8);
if you see it, the fault line and `uname -r` are what a report needs.

### If the server starts but crawls on long prompts

A server that starts, answers short prompts, and then collapses to a few
tokens per second on a long one, with the disk busy and the process stuck in
uninterruptible sleep, is short of file cache rather than short of memory.
The model keeps a large lookup table on disk and reads it through the page
cache instead of holding it in RAM, so RAM the KV pool takes is RAM that
table loses, and a longer prompt touches more of it. Since 0.6.3 the rows a
prompt needs are read 64 at a time, so a table that is not in the cache costs
seconds on an NVMe drive rather than minutes, and the log says how long each
long prompt spent on it (`lookup table: ... took N s on 64 threads`). If that
line still reads in the tens of seconds, the drive is the limit, and the same
setting helps:

```
-e HALOGEN_KV_POOL_POSITIONS=262144
```

`HALOGEN_HOST_RESERVE_GIB` (default 20) is how much RAM the server leaves
free for that cache when it sizes the pool at startup; raising it makes the
server choose a smaller pool on its own.

**Check the BIOS before you tune anything, if this machine carves memory out
for the iGPU.** A fixed block assigned to graphics in firmware is taken before
the kernel boots, so it never shows up as missing anywhere on the host: the
machine just reports itself smaller, and that RAM is gone from the file cache
the lookup table depends on. **This server does not need it.** It drives the
GPU through GTT and allocates from the same unified memory whichever way the
setting is left, so a large carve-out buys nothing here and costs cache. Set
the UMA frame buffer or dedicated graphics memory option to its explicit
MINIMUM, not to Auto: on the reference machine the minimum reports about
512 MiB, on a GMKtec EVO-X2 it is 2 GB, and on that board "Auto" turned out
to be 64 GiB (the OS saw 61 GiB of a 128 GB machine and the weights could
not load until the setting was changed).

You are paying for a carve-out even when nothing has thrashed yet. The pool
sizes itself from the memory total the OS reports, which the carve-out has
already made smaller, so the server quietly chooses a smaller pool and keeps
fewer conversations resident than [the pool table](#context-and-memory-one-kv-pool-several-conversations) says. Pin the pool yourself
and the file cache takes the whole loss instead. Either way the server prints
what it found at startup, and warns when it is large:

```
memory: 16.0 GiB of this machine's RAM is carved out for the iGPU in firmware.
        That is not free memory the OS can lend to the file cache above, and
        it does not appear anywhere in /proc/meminfo: the machine simply
        reports itself smaller
```

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

### The host settings these numbers were measured on

**Native Linux only.** This server runs on the amdgpu/KFD driver stack and
its memory design depends on it: the checkpoint is mapped and registered with
the GPU in place, never copied, and every memory ceiling it knows about lives
in that driver. **WSL2 (ROCm through `/dev/dxg`) is not a supported host**: the
registration is refused there, and the server does not reach readiness. If
you are on that stack, the same hardware booted into Linux is the path that
works.

**Kernel 7.0 or newer.** The checkpoint is a read-only file mapping registered
with the GPU as read-only, and that registration needs kernel support. The
reference host runs 7.1.8 (Fedora 43 Server); every install reported working
here is on 7.0.0 or later; on 6.18.6
([#37](https://github.com/peonist-ai/halogen-flash-server/issues/37)) the
driver refuses every read-only mapping with `invalid argument` and the server
cannot pin the weights. We have not bisected the exact kernel that added it;
7.0 is the oldest we have seen work.

Everything in [Measured](#measured) was measured on a machine booted like this,
and the same command line has been in place unchanged for the whole life of
this engine. **This is our configuration, not a tuning guide**: of the six
settings we have A/B'd exactly one, and it is published here so the numbers can
be reproduced and so a slow machine has somewhere to look.

```
amdgpu.vm_update_mode=0 amdgpu.noretry=0 amdgpu.gttsize=126976
ttm.pages_limit=32505856 amdgpu.sg_display=0 amd_iommu=off
```

**`amd_iommu=off` is the one we have measured, and it is worth 13 to 16 percent
of prefill.** The numbers and the mechanism are in the conditions paragraph
above. Two things to weigh before copying it: it turns off DMA translation
machine-wide, which is a real change in posture on a host that is not dedicated
to this, and it takes the NPU with it. On a box that exists to serve this model
it is the right trade and it is the one we made.

**`ttm.pages_limit` and `amdgpu.gttsize` are sizes, not constants. Do not paste
ours.** GTT is where every allocation this server makes on the GPU actually
lands, and `ttm.pages_limit` sets that ceiling exactly: 32,505,856 pages times
4 KiB is 124 GiB, which is 99.3% of this machine's RAM, and it is precisely
what the driver then reports as its GTT total. Both values say the same thing
in different units, so set both to about your installed RAM:

| machine | `amdgpu.gttsize` (MiB) | `ttm.pages_limit` (4 KiB pages) |
|---|---|---|
| 128 GB | `126976` | `32505856` |
| 96 GB | `95232` | `24379392` |
| 64 GB | `63488` | `16252928` |

Pasting the 128 GB row onto a 64 GB machine asks the driver for more GTT than
the machine has. **Neither flag is required.** Measured on a second 128 GB
machine on a stock kernel command line: the kernel's default GTT is half of
RAM (60.6 GiB there), this server at the Quickstart defaults uses about
35 GiB of it (the weights are registered host memory and do not count
against GTT), and the Quickstart served from that default without either
flag. Ours are set because we set them on day one, not because the server
needs them.

The remaining three, `amdgpu.vm_update_mode=0`, `amdgpu.noretry=0` and
`amdgpu.sg_display=0`, we have never run without. They are listed for
completeness rather than recommended, and they are unmeasured in both
directions: we make no claim about what they buy. One of them changes a
failure's shape rather than any speed: `amdgpu.noretry=0` makes the GPU
retry a page whose mapping is gone instead of faulting, so an event that
produces `Page not present` on a default boot (issue #83) produces a silent
engine on ours (issue #85). Neither is better; know which one you will see. Two reports
([#34](https://github.com/peonist-ai/halogen-flash-server/issues/34)) of the
driver keeping an engine's GPU memory after the process was gone came from
boots with them set, and one A/B on one machine ran clean without them, so
this section said for a week to leave them off. A third host
([#79](https://github.com/peonist-ai/halogen-flash-server/issues/79)) then
reached the same state with none of the three set, and our own gate machine
reached it once with all of them, so the flags are not what decides it. What
the four share is a process holding the GPU ending while the driver had work
in flight: another model's exit, a bench's normal exit, a cancelled request
on a busy queue, a watchdog kill under a memory stall. After it, 35 to 45
GiB of GTT stays allocated with nothing alive (`Trying to push to a killed
entity` in dmesg on two of them, a kernel worker in `svm_range_restore_work`
in D on two), and every later start either refuses at the pin guard or hangs
at `reserving the KV pool` until the host reboots. Nothing in user space
releases it; `amdgpu_gpu_recover` through debugfs may, and we have not
tried it. Since 0.11.9 the container reads the counters before it starts
and names the state (the troubleshooting section above shows the lines),
and its watchdog no longer kills an engine that is silent inside the
kernel, which is where #79's two kills landed. The flags: leave them
off unless something else needs them, and do not expect that to be what
saves you. After any unclean exit, check

```
cat /sys/class/drm/card*/device/mem_info_gtt_used
```

before starting again; tens of GiB with no container running is the state
above.

Check what you are on with:

```
cat /proc/cmdline
```

---

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
  by id are not available. **Cancellation is by disconnect** (since 0.10.2;
  #58): on every route, streaming or not, a request whose client closes the
  connection is cancelled within one decode step, its slot and KV
  reservation are released, and `/health.in_flight` and `/metrics` show it
  at once; the server log prints a "client disconnected" line with the
  timing. Its prefix stays in the prompt cache, so a retry resumes from it.
  Before 0.10.2 only streaming requests were cancelled; a non-streaming
  request ran to its natural end (EOS, `max_tokens` or the thinking budget).
- **Images are read, not generated.** There is no image output, and no audio
  or video input.
- **One GPU, one model family.** gfx1151 only. The build hard-rejects other
  architectures.

---

## Community

- **[Discord](https://discord.gg/bcm6QknaV6)** for questions, setup help,
  numbers from your own machine, and comparisons with other runtimes. If you
  have run a benchmark against this server, post the command and the curve.
  A result from a box we do not own is worth more to us than one from ours.
- **[Issues](https://github.com/peonist-ai/halogen-flash-server/issues)** for
  bugs and regressions. [CONTRIBUTING.md](CONTRIBUTING.md) says what to
  include. The changelog credits the report that drove each fix.
- **Security issues** go to the maintainers directly, not to Discord or a
  public issue.

---

## License

The engine is distributed under the terms in [LICENSE.md](LICENSE.md).
Third-party components and their licenses are listed in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). Model weights are licensed
separately by their original authors.

"halogen" and "Peonist" are trademarks of Peonist, LLC (U.S. application
pending). [TRADEMARKS.md](TRADEMARKS.md) says how the names may be used;
referring to the project, running it, and publishing numbers about it need
no permission.
