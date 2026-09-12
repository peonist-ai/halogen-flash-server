# Changelog

## 0.6.2

Front-end only (`tools/serve_api.py`). No kernel change, no weight change, no
change to any answer on a request that does not mention the placeholder, so
every published prefill, decode and quality number is unmoved.

### Fixed

- **A conversation that mentioned `<|image_pad|>` was unservable.** Reported
  with a precise repro and the mechanism by
  [@Syakyr](https://github.com/Syakyr) (#39). The tokenizer parses its added
  tokens out of ordinary text, so the thirteen characters `<|image_pad|>`
  typed by a user (a pasted log, a quoted traceback, a bug report about this
  server) or printed by the model became the same special id the chat
  template writes for an image, and the engine's 0.5.8 check refused it as a
  placeholder with no image behind it. The next turn re-tokenizes the
  history, so one mention by either side made every later turn a 400 and the
  only recovery was a new session with the string rewritten. 0.5.8's
  changelog called that path "the same defect"; it is not, and the reporter
  is right that a mention has to be servable as text.

  The API now sends a mentioned placeholder as the ordinary tokens of its
  spelling (`<`, `|`, `image`, `_pad`, `|`, `>`), decided on the token ids
  after the template runs, so the model reads exactly the characters that
  were written and the engine never sees an uncovered placeholder. The
  template's own placeholder is told apart by the `<|vision_start|>` and
  `<|vision_end|>` it is always written between when the request carries an
  image; with no image on the request every placeholder is a mention.
  `<|video_pad|>` in text is text the same way. Applies to
  `/v1/chat/completions`, `/v1/responses` and `/v1/completions`. Every
  request without a mention sends the same ids it did before, checked on the
  gate. The engine's refusal (0.5.8) is unchanged; from this API it is now
  reachable only by typing the whole
  `<|vision_start|><|image_pad|><|vision_end|>` sequence in a request that
  also attaches an image, which is refused with a message naming both counts.

  A `video` content part is now refused by the API before the template runs
  (this server has no video path); it used to reach the engine and be
  refused there, after the stream had started.

- **An error after a streaming response had started cut the connection.**
  The second half of #39. The engine's refusal, and the first-token and
  mid-decode timeouts, were raised after the SSE headers had gone out, so
  the client saw a dropped stream and the log Starlette's
  `Caught handled exception, but response already started`. A streaming
  request now ends with its wire's own error: on `/v1/chat/completions` and
  `/v1/completions` a `data: {"error": {...}}` frame followed by
  `data: [DONE]` (what the OpenAI SDKs raise as an `APIError`), on
  `/v1/responses` an `error` event. The log gets one line with the reason.
  Non-streaming requests still get the 400 they always did.

- **The prompt cache's snapshot point could drift on a conversation with
  images.** Found while fixing the above: the API added an image's token
  growth to the snapshot point once per token it walked past the shifted
  value, not once. Unreachable in practice for an image (its growth outruns
  the few tokens that follow the history point) and reachable for a
  mention's five; both passes now read the original points. No served
  number moved.

## 0.6.1

Serving surface and startup legibility. No kernel change, no weight change, no
change to any answer, so every published prefill, decode and quality number is
unmoved.

### Fixed

- **Tool-call arguments were flushed as one burst, and Node clients hung up on
  the long ones.** Reported with a raw-client measurement by
  [@smazurov](https://github.com/smazurov) (#36) and, from the client side,
  by [@iTechMedic](https://github.com/iTechMedic) (#3), who showed every
  failing client was Node/undici, every passing one was not, and that
  re-chunking the identical bytes through a proxy removed every failure. The
  streaming splitter emitted nothing about a call until its closing tag
  arrived, so a 150-character command was 1.4 s of silence and a file-writing
  call was minutes, which is undici's 300 s inactivity timer with no client
  setting to change it.

  A call's id and name now go out as soon as the function tag closes, a
  string parameter streams as it is written (JSON-escaped in pieces, and the
  pieces concatenate byte for byte to what a non-streaming request returns),
  and a non-string parameter goes out when its value closes, because the wire
  carries values untyped. On the gate, the report's `bash` command is 43
  argument frames spread over the value's generation instead of 3 at its end.
  A call cut off by `max_tokens` now leaves its partial arguments on the wire
  with `finish_reason: "length"`, as OpenAI does.

  Separately, a streaming response now sends an SSE comment line
  (`: keepalive`) whenever nothing else has gone out for 10 s
  (`HALOGEN_SSE_KEEPALIVE_S`, 0 disables). SSE parsers ignore comment lines
  and every HTTP client's inactivity timer resets on one. This also covers a
  long prefill, which sends nothing before its first token. The
  client-disconnected log line now ends with the largest gap between frames,
  the age of the last frame at the hangup, and the keepalive count.

- **The `developer` role was refused with a 400.** Reported by
  [@felladrin](https://github.com/felladrin) (#32), confirmed by
  [@k4ss4n](https://github.com/k4ss4n). OpenAI clients send it for reasoning
  models; pi does for every model it marks as one. It maps to `system` before
  the template runs, on `/v1/chat/completions` as it already did on
  `/v1/responses`.

- **Four `/cache` fields were placeholders.** Found while answering
  [@carrot-root-ai](https://github.com/carrot-root-ai) (#31). `entries`,
  `evicted`, `cap_bytes` and `reserved_bytes` were stand-ins from when the
  cache held one entry and were never updated for the eight-entry cache, so a
  two-prompt run read `entries: 1, evicted: 3`. `entries` and `evicted` are
  real now; `cap_bytes` and `reserved_bytes` are replaced by `max_entries`
  and `last_entry_bytes`, and `bytes` is what is resident for the live
  entries. The counters that were already right (`hits`, `misses`, `stores`,
  the timings) are unchanged.

### Added

- **`HALOGEN_ENABLE_THINKING`**, the ninth request default, alongside the
  eight from 0.5.9. `0` renders every request that does not say otherwise
  without the thinking block; a request that sends `enable_thinking` wins.
  `/v1/responses` has no such field, so this is the only way to run that
  route without thinking.

- **A reservation that runs long says why while it runs.** Reported by
  [@felladrin](https://github.com/felladrin) (#33), who watched
  `still loading, 300s elapsed` five times on the KV pool step and could not
  tell a slow disk from a machine that would never finish. Every 30 s
  (`HALOGEN_RESERVE_TICK_S`) during the working-memory and KV-pool
  reservations the engine now prints the free contiguous 2 MiB block count
  and the compaction stalls since the reservations began. Stalls climbing
  means the kernel is compacting host memory, which finishes on its own. The
  pool is not sized against the block count, and the report's own log shows
  why that would not have helped: 16.6 GiB was contiguous two lines before a
  7.2 GiB pool stalled, and the 21 GiB working reservation between them took
  it.

### Changed

- **`seccomp:unconfined` is gone** from the compose file and both run
  commands. Suggested by [@rcmorano](https://github.com/rcmorano) (#8) and
  measured: the image starts and serves without it under Podman, and the
  reporter runs Docker without it. `ipc: host` stays; the compose file now
  says why beside it (the GPU runtime dies in 2 s without it, and no
  `shm_size` substitutes). If a Docker install breaks on the default profile,
  the line comes back and this file will say so.

- **The published 0.6.0 source tree lagged the 0.6.0 image on
  `deploy/entrypoint.sh`.** The image's entrypoint checks whether the quality
  sidecar on disk predates 0.6.0 (no draft-head entries), fetches just that
  2.4 GiB file when `HALOGEN_DOWNLOAD` is set and the volume is writable, and
  otherwise says what is missing; the tree published with 0.6.0 did not carry
  that change. It does now, and the README's note on the models volume says
  when a start re-fetches.

### Documentation

- The three kernel flags the README lists for completeness
  (`amdgpu.vm_update_mode=0`, `amdgpu.noretry=0`, `amdgpu.sg_display=0`) now
  say they are unmeasured in both directions and cite
  [@felladrin](https://github.com/felladrin)'s report (#34) of an amdgpu
  deadlock on a boot that had the first two set: one machine, one occurrence,
  not isolated to either flag.

## 0.6.0

Faster decode on the traffic an agent produces, and a better draft head. No
kernel change and no change to any answer: at temperature 0 every token is
still the model's own greedy choice, verified on every release, and the
sidecar's 723 existing tensors are byte-identical to 0.5.x's.

### Added

- **Prompt lookup beside the MTP head.** When the last three tokens of the
  answer already occur earlier in the request's own context (the prompt or
  what it has generated so far), the three tokens that followed that earlier
  occurrence are proposed as one chain and verified in a single step, and the
  head's own draft has to open the chain. Nothing is drafted by a model, so it
  costs nothing where an answer is new text and pays where it repeats its
  context, which is most of what a coding agent's turn is: tool-call
  arguments, file paths, code that quotes the file being edited. Measured on
  the engine, thinking off, coding-agent turns (SWE-agent trajectories cut at
  an assistant turn, six prompts, 400 tokens each): **49.1 tok/s with the head
  alone, 56.3 with prompt lookup beside it (+15%)**, serial 36.8; on
  function-calling turns (Hermes, six prompts) 48.8 to 53.1 (+9%). With thinking on,
  the served default: 49.2 to 55.7 on the same SWE prompts (+13%), because
  this model's reasoning quotes the task and the file. Prose and code text are
  unchanged within noise. Greedy requests only; a sampled request uses the
  head alone; like the head it drafts while the request is the only one
  generating, and the concurrency rows are unchanged (2 streams 56.5 and 4
  streams 77.1 tokens/s total on this image, every stream byte-identical to
  alone). `HALOGEN_PLD=0` turns it off. Every one of those runs produced the
  serial run's tokens exactly.

- **The MTP head's own projections at 8 bits**, in the sidecar. The head had
  shipped at the base file's 4-bit rounding since 0.1.0 and nobody had
  measured what that cost, because there was no other head to compare it with.
  At 8 bits its drafts are accepted 59% of the time on prose against 51%,
  which is about 4% of decode on prose (43.1 to 44.8 tok/s at 1,500 tokens of
  context) and within noise on code. The sidecar grows by 0.09 GiB (2.31 to
  2.40 GiB); its existing 723 tensors are unchanged byte for byte, so
  `HALOGEN_CK_OVERLAY` and the speed arm behave as before. An older image
  reads the new file and gains the same.

- The per-request log line ends with the prompt-lookup rounds (`pld N
  rounds, X acc/round`), the engine's `D` line carries them as two trailing
  fields, and `/health` reports `prompt_lookup`. The image's own `bench` over
  its ten prompt shapes reads 45.3 tok/s mean with speculation (43.6 on
  0.3.0, the same instrument).

### Changed

- The speculative verify reserves 4 rows instead of 2 (about 0.2 GiB of device
  memory), so a three-token chain fits; the KV-pool fit accounts for it.

## 0.5.9

Server-side defaults for the fields a request leaves out, and two things the
log now says that it could not before. No kernel change, no weight change, no
numeric change on any path a request took before: every published prefill,
decode and quality number is unmoved.

### Added

- **Server-side defaults for sampling, the token budget, and reasoning
  effort.** Asked for by [@Mushoz](https://github.com/Mushoz) (#30).
  `HALOGEN_TEMPERATURE`, `HALOGEN_TOP_P`, `HALOGEN_TOP_K`, `HALOGEN_MIN_P`,
  `HALOGEN_PRESENCE_PENALTY`, `HALOGEN_FREQUENCY_PENALTY`,
  `HALOGEN_MAX_TOKENS_DEFAULT` and `HALOGEN_REASONING_EFFORT` each set the
  value a request gets when it omits that field, on all three routes. A field
  the request sends always wins; a default fills only a field the request
  omits; a request that sends `temperature: 0` decodes greedy and takes none
  of the sampling defaults. A value outside its range refuses to start,
  before the model loads, naming the variable. `/health` reports what is set
  under `server_defaults` and says which path a temperature-less request
  takes. The image's own default is unchanged (greedy); the README now gives
  the model card's settings as the three `-e` lines that switch to them.

### Fixed

- **The engine answers its health check while it reads the lookup table.**
  Reported by [@mqtt-fan](https://github.com/mqtt-fan) (#10, #22). Reading
  the model's 47.7 GiB lookup table at the start of a prefill was the one
  step that could not answer the container's PING. On a host with too little
  RAM left for the table's file cache that read runs for minutes, and the
  watchdog took a working server down as a wedge, twice, while the same host
  with the watchdog off finished every request. The read now answers PING on
  the same cadence as the rest of a prefill, prints `lookup table: ... took
  N s` when it runs long, and the watchdog's message says what the code
  guarantees. The startup pre-flight warns when 10 GiB or more of host RAM
  is already in use before the engine starts, which is the condition. The
  slowness itself is the host's memory, not the engine, and is not changed.

- **`commit N/round` in the request log counted tokens the request produced
  beside other streams.** Same reporter (#22), and the same shape in #3. A
  request alone for one speculative round and then sharing the engine for
  189 tokens printed `1 rounds, commit 190.00/round`, which read as a decode
  defect and was not one. The ratio is now over the speculative rounds'
  tokens only (healthy is 1.6 to 1.8), and the line ends with `N tok beside
  other streams` when any were.

### Documentation

- The README's Sampling section gives the model card's recommended settings
  and how to make them the server's default; the budget section explains why
  the default budget is a concurrency decision on a 128 GB host.

## 0.5.8

One engine check that can only refuse, and a version that can be read from
inside the container. No kernel change, no weight change, no numeric change:
every request the engine served before is served identically, so every
published prefill, decode and quality number is unmoved.

### Fixed

- **An image placeholder with no image behind it was answered as if there
  were one.** Reported by [@jtnishi](https://github.com/jtnishi) (#26). Their
  compose file ran the `api` container at 0.4.4 and the `engine` at 0.5.6.
  That front-end predates image support: it rendered the chat template's
  `<|vision_start|><|image_pad|><|vision_end|>` for the image part and never
  decoded or sent the pixels. The engine then prefilled the placeholder's
  ordinary embedding, and the model, which has learned that an image lives at
  that token, described one. The result was a fluent, confident, different
  picture every run, unaffected by temperature, with nothing anywhere saying
  a thing had gone wrong. Reproduced here against one engine: 60 prompt tokens
  through the 0.4.4 front-end against 2,559 through the current one, for the
  same image.

  The engine now refuses any prompt in which a placeholder token is not
  covered by an attached image, naming the token position and the likely
  cause, and the same goes for a video placeholder (this server has no video
  path) and for an image declared over a token that is not a placeholder.
  The check runs once over the prompt ids at admission and can only refuse,
  so an accepted request is untouched. It also closes a path that was open
  from any client at any version: a user message whose text contains the
  literal string `<|image_pad|>` reached the engine the same way, and was
  answered the same way.

- **The engine's reason for refusing a request now reaches the client.**
  Until now it went only to the engine's log, and the front-end's `400` had to
  guess (the old text blamed prompt length). The reason rides the internal
  protocol after the fixed fields, and the front-end repeats it verbatim:
  `the engine refused this request: prompt token 38 is the image placeholder
  <|image_pad|> and no image covers it: ...`.

### Added

- **Each container says which release it is, and the front-end compares.**
  Nothing running inside the image could read the version label, so neither
  log in #26 printed one and `/health` had none to show; a careful reporter
  posting both logs could not see that they disagreed. The first line of every
  mode is now `halogen: halogen-flash-server 0.5.8, mode api`, the front-end
  prints its own version beside the engine's at startup and prints a
  `WARNING` when they differ, and `/health` carries
  `version: {"api": ..., "engine": ..., "match": ...}`. A mismatch is a warning
  and not a refusal, because a split across a patch release is harmless and
  refusing it would break a working install; the engine-side check above is
  what turns the harmful case into an error.

### Documentation

- The compose file and the README now say it in one place: **both services
  run the same image tag.** When you bump one, bump the other.

## 0.5.7

Front-end only. No engine change, no kernel change, no weight change, so every
published prefill, decode and quality number is unmoved.

### Fixed

- **An idle connection was closed after five seconds, and the next request on
  it failed.** Reported by [@iTechMedic](https://github.com/iTechMedic) (#25).
  The server never set uvicorn's keep-alive timeout, so it ran at the framework
  default of 5 s on every release ever shipped. An agent idles between turns for
  as long as a tool call, a file write, or a person reading the last answer
  takes, and because `POST` is not idempotent most HTTP clients will not quietly
  retry on a fresh socket the way they would for a `GET`. The failure therefore
  reached the user as a socket error partway through a long session.

  The default is now 300 s, and `HALOGEN_KEEPALIVE_TIMEOUT` sets it. An idle
  connection costs a file descriptor and holds no conversation slot, so there is
  no reason for it to be short. The race is inherent to HTTP keep-alive, since a
  server may close at the moment a client writes, so a client that pools
  connections should still retry a reused socket; what the old default did was
  turn a rare race into a constant one.

  The report is worth reading for its method. The first reproduction idled 6, 30
  and 90 seconds between reuses, all above the threshold, which a server closing
  after *every* response would have matched exactly. Asked for a control, they
  added back-to-back reuse at zero idle and then bracketed the boundary to
  between 4 s and 5 s.

- **`chat_template_kwargs` was accepted and silently ignored.** Reported by
  [@nortejiang-tech](https://github.com/nortejiang-tech) (#24). vLLM and SGLang
  take the template controls nested, as
  `chat_template_kwargs: {"enable_thinking": false}`, and that is what most
  agentic clients send because that is what they were written against. This
  server declared those controls only as top-level fields, so the nested form
  was discarded with no warning and no log line: a caller who asked for thinking
  off got a `200` with thinking on.

  Both spellings now reach the same three controls: `reasoning_effort`,
  `enable_thinking` and `preserve_thinking`. Sending a control both ways is fine
  when the values agree and a `400` when they disagree, and an unsupported key
  inside `chat_template_kwargs` is a `400` naming the keys that work rather than
  a silent drop.

### Added

- **`/health` says what the token budget is spent on.** Raised by
  [@tretyakevich](https://github.com/tretyakevich) (#21) and
  [@nortejiang-tech](https://github.com/nortejiang-tech) (#24). `max_tokens`
  bounds reasoning and content together, and with no `reasoning_effort` sent the
  chat template's own default is `xhigh`. On a long agentic prompt that can
  consume the entire budget before the model closes its thinking block, and the
  caller then receives an empty `content`, the whole reply in
  `reasoning_content`, and `finish_reason: "length"`. At least one agent harness
  reads that as "the model returned no assistant message" and retries, which is
  deterministic at temperature 0 and so repeats exactly.

  None of that was discoverable. `/health` advertised `max_tokens_default` and
  said nothing about what consumes it. It now reports
  `reasoning_effort_default`, `reasoning_effort_values`,
  `token_budget_covers_reasoning` and `chat_template_kwargs` beside it. To turn
  reasoning off entirely, send `enable_thinking: false`; `reasoning_effort:
  "minimal"` is an alias for the template's `low`, which still reasons.

- **A client that hangs up mid-stream now says so in the log.** Raised by
  [@iTechMedic](https://github.com/iTechMedic) while diagnosing #3, which stays
  open. Until now a hangup and a clean finish produced identical output: uvicorn
  logs `200 OK` either way, because the status went out with the headers long
  before, and the per-request summary never printed because the generator was
  cancelled before it could emit one. The entire server-side trace of an
  abandoned stream was a bare access line indistinguishable from success.

  That is a hole in the log, and a hole in a log gets filled by someone's
  inference: the reporter reasoned from the absence of our own timeout message
  that the engine had stalled, and the silence was ours. There is now one line
  on the disconnect path, naming the response id, the frames and characters
  already sent, and the elapsed time. A disconnect is a normal event rather than
  an error, so it is a line and not a traceback.

## 0.5.6

### Fixed

- **`/health` said the speculative drafter was not loaded, on every build ever
  shipped.** Reported by [@aic0d3r](https://github.com/aic0d3r) (#16), who
  benchmarked four stacks on this hardware and noticed that
  `drafter_weights_loaded` read `false` while their own measurements showed the
  drafter working: 43.1 tokens per second drafted against 33.2 serial, with
  drafted and serial output byte-identical on all ten prompts they tried.

  The field is inherited from an engine that had a separate draft model, where
  it meant that model's weights were present. This engine has no such model,
  the MTP head is the drafter, and nothing ever set the field, so it reported a
  hardcoded `false`. At least one public diagnosis had already misfired off it,
  reading it as evidence that speculative decoding never loads.

  It now reports whether the MTP head is ready, which is the question the name
  asks. `shortlist_draft_head` stays `false` beside it and that is correct:
  this build has no such head, and the fix for a field that lies is not to make
  an honest neighbour lie the other way.

- **The out-of-memory refusal at startup referred to one of our internal
  documents.** If pinning the weights would have left the host short, the
  server refused and explained why by citing a file nobody outside this
  project can read. It now says the same thing in its own words and names the
  setting that runs without pinning.

### Added

- **The server detects a BIOS iGPU memory carve-out and says so.** A fixed
  block of RAM assigned to graphics in firmware is taken before the kernel
  boots, so it appears nowhere on the host: the machine simply reports itself
  smaller. This model reads a 47.7 GiB lookup table through the host file cache
  on every request, so that RAM is taken directly out of what the table needs.
  The startup memory ledger now reports the carve-out, and warns when it is
  large enough to matter, naming the BIOS setting.

  It costs you something even when nothing has visibly thrashed: the KV pool
  sizes itself from the memory total the OS reports, so a carve-out quietly
  buys fewer resident conversations instead.

### Documentation

- **The conditions the published numbers were measured under are now stated in
  full**, after #16 measured our decode 11 to 12 percent low on both rows on a
  70 W handheld and we had never published a power envelope. The Measured
  section now names the sustained package power and the clock, and it names the
  IOMMU, which is worth 13 to 16 percent of prefill on this hardware and which
  no artifact had ever mentioned.
- **The kernel command line the reference machine boots with is published**, in
  a new section under Troubleshooting. Numbers nobody can reproduce are not
  much use. It is labelled as our configuration rather than a tuning guide, and
  the two settings that are sizes rather than constants are given as a table
  per machine size instead of as values to paste.
- **A startup line in the README had been quoting output the server stopped
  printing three releases ago**, on the one line that tells you how much memory
  is left. It now shows what the server actually prints, including the second
  line explaining why `free` and `MemAvailable` disagree with it by the size of
  the model.
- **`docs/QUANT.md` is linked from the README.** It has shipped in this
  repository since 0.1 and nothing pointed at it, so a reader asking how the
  bits-per-weight figure is derived had no way to find the answer already here.
- The README has a table of contents, and the two troubleshooting sections have
  a heading to live under. The explanation of token budgets covering thinking
  as well as the answer, which is the difference between a short reply and an
  empty one, was filed under the Codex section; it applies to every client and
  now has its own section.

## 0.5.5

### Fixed

- **The server could exit in the middle of serving, taking every request in
  flight with it.** Reported by [@nr23730](https://github.com/nr23730) (#15),
  who crashed it twice in a few minutes and posted the log that identified it.

  Any request that used a temperature above 0 together with the speculative
  drafter (both defaults for most clients) was decoded using a block of memory
  that had already been released. The sampling settings for the request -
  temperature, seed, and the repetition penalties - lived in that block, and
  they were read again on every step of the answer.

  Usually the memory still happened to hold the right values, which is why this
  went unnoticed for nine releases. When it did not, one of two things
  happened. If the leftover data looked like a plausible temperature, the reply
  came back normally but was generated with settings that were not the ones
  asked for. If it happened to be exactly zero, the server treated it as an
  internal contradiction and shut itself down, and every other request being
  served at that moment failed with a 502.

  **If you use temperature above 0, we would treat any sampled output from
  0.4.x or 0.5.0 through 0.5.4 as unreliable, not merely as occasionally
  crashy.** Greedy decoding (temperature 0, the default when the field is
  omitted) was never affected: it does not use that path at all, and a
  48-request control run confirms it.

  Reproduced on the published 0.5.4 image before the fix was written: four
  concurrent requests at temperature 0.7 took the container down on the first
  round. The same test against 0.5.5 completes 48 of 48 with the server up.

### Known

- Some internal consistency checks still stop the whole server rather than
  failing the one request responsible. Nothing is known to reach them, and the
  path that did reach one is fixed above, but it is the wrong behaviour for a
  server handling several conversations and we are changing it.


## 0.5.4

### Fixed

- **Long replies no longer slow down as they get longer.** The streaming
  front-end re-decoded the entire answer on every single token and diffed it
  against what it had already sent, which costs time proportional to the length
  squared. A reply of a few thousand tokens spent hundreds of microseconds per
  token on that alone, and a reply running to the cap would have spent about
  half a minute of pure bookkeeping.

  It now decodes only the last token or two, which is all that can still
  change. Detokenization cost is flat at 9 to 19 microseconds per token
  regardless of output length, where before it climbed from 42 to 726. Long
  answers no longer pay more per token than short ones. The reporter measured
  the end-to-end effect on their own host at 34-35 rising to 36-37.6 tok/s on
  replies of several thousand tokens; our own runs vary by about 7% with
  machine state, so we quote the detokenization cost, which is the part that
  is controlled.

  **Reported and diagnosed by [@rosstang](https://github.com/rosstang), with
  measurements and a differential harness, and independently confirmed by
  [@hvico](https://github.com/hvico).** The problem, the measurements and the
  analysis that made the fix possible are theirs; the implementation here is
  our own, written from the description rather than from their patch, and we
  verified the tokenizer property ourselves before relying on it. Thank you
  both. (#13)

- **`response_format` is no longer accepted and silently ignored.** A request
  asking for JSON or a schema returned 200 and prose, so a client had no way to
  tell that nothing had enforced it. This server has no constrained decoding,
  so it cannot honour the field. It now refuses with a 400 that says so, on
  both `/v1/chat/completions` and `/v1/responses` (where the field is spelled
  `text.format`), matching what the server already does for any other option it
  cannot honour. `/health` gained a `not_implemented` list so a client can ask
  before sending. `{"type": "text"}`, the default, is unaffected.

  **Reported by [@hvico](https://github.com/hvico)**, who also laid out what
  real support would take. Structured output is not implemented and this
  release does not add it: it makes the gap visible instead. (#14)


## 0.5.3

### Faster

- **Long prompts are read 5 to 8 percent faster, and the answers are
  byte-for-byte the ones 0.5.2 gave.** Nothing about the model or the
  arithmetic changed. Every layer has to work out which expert handles which
  token, and that ordering was being produced by a general-purpose sort running
  on the CPU while the GPU sat idle waiting for it. There are only 512 experts,
  so the ordering can be counted out directly instead of compared into place.
  A stable count on the same key produces the identical ordering by definition,
  which is why the output is unchanged rather than merely close.

  Measured on this machine against 0.5.2 in the same session, on the tuned plan
  this image ships:

  | prompt | 0.5.2 | 0.5.3 | |
  |---|---|---|---|
  | 8,192 tokens | 1,191 tok/s | **1,246 tok/s** | +4.6% |
  | 32,768 tokens | 1,317 tok/s | **1,424 tok/s** | +8.1% |
  | 131,072 tokens | 1,259 tok/s (104.1 s) | **1,358 tok/s (96.5 s)** | +7.9% |

  Decode speed is unchanged, and unchanged by construction: generating a token
  never takes the path this touches.

  The saving is a fixed amount of time per layer, so it is worth more on a long
  prompt than a short one, and worth more on a fast machine than a slow one.

### Changed

- **The server now reports the memory it actually holds.** The pre-flight
  estimate printed at startup says plainly that it is an estimate, and the
  engine prints measured figures once the model is loaded, including the large
  lookup table it reads from disk and never keeps in memory.

  This matters for anyone sizing a machine, because the usual tools understate
  it: the weights are locked in place in a way that `MemAvailable` and `free`
  do not count, so a loaded server looks like it has roughly 68 GB more room
  than it has. Nothing but the server itself can correct that figure, so it
  does.

- **`/health` now names `/cache`**, which carries the live prompt-cache
  counters. It was reachable before but undiscoverable, since it does not sit
  under `/v1/`. The counters now include how many times a cache hit had to copy
  its rows and how long that took: if those climb while the hit rate looks
  healthy, the host is under memory pressure rather than the cache missing.


## 0.5.2

### Fixed

- **An image request that generated a long answer could take the engine
  down.** On some hosts it ended in a GPU page fault and the container was
  gone; on others the engine simply stopped answering and requests timed out.
  It needed no second request and no unusual image: only an answer of a few
  hundred tokens or more, which an image plus a detailed question routinely
  produces.

  The table that tells the model where each token sits, which images make more
  complicated than a plain count, was built to cover the prompt and nothing
  more. It was then used for every token generated after the prompt as well,
  reading further past the end with each one. The table now covers everything
  a request can generate, and the values past the prompt are the ordinary
  count the model would have used anyway, so answers up to that point are
  unchanged.

  Short answers were never affected, which is why this survived: the gates all
  asked for short ones. A request that generates 400 lines and then refers
  back to the image is now part of the release gate.

  Reported on 0.5.1 and present in 0.5.0. Text only servers cannot be
  affected: the whole path exists only for requests that carry an image.

- **A container could shut itself down in the middle of a request it was
  serving correctly.** The server has a watchdog: it asks the engine a
  question every few seconds, and if the engine has not answered for
  `HALOGEN_ENGINE_WATCHDOG_S` (180 by default) it takes the container down so
  a restart policy can recover it. The message it prints says a silent engine
  is a stuck one rather than a busy one, because the engine is supposed to
  answer between decode rounds and between the pieces a long prompt is read in.

  It was not answering while a prompt was being read in, unless that prompt was
  longer than one piece. The shipped piece size is 32,768 tokens, so any
  ordinary prompt went in as a single uninterrupted step and the engine said
  nothing for the whole of it. On a machine where that step took more than
  three minutes, the watchdog shut down a container that was working.

  The engine now comes up for air during a prompt, whatever its length. On this
  hardware the longest it goes without answering fell from the length of the
  whole prompt to under two seconds: measured 14.8 to 17.0 seconds down to 1.2
  to 1.5 on a 20,000 token prompt, and 46.3 seconds down to 1.7 on a 100,000
  token one. Prompt processing and generation speed are unchanged, and the same
  prompts give byte for byte the same answers as 0.5.1.

  `HALOGEN_ENGINE_YIELD_MS` controls how often it comes up for air, in
  milliseconds. The default is 250 and there is no reason to change it; 0
  restores the previous behaviour.

- **A health check could be answered one step later than it needed to be.**
  Connections that arrived while the engine was busy were accepted after the
  waiting ones were answered rather than before, so a check that arrived during
  a piece of work waited for the end of the next one as well.

## 0.5.1

### Fixed

- **An image request sent while another request was still generating could
  stop the engine.** On some hosts it ended in a GPU memory fault and the
  container went down and was restarted; on others the engine simply stopped
  answering, at full GPU load, until the built in watchdog took the container
  down. Both are the same defect and which one you saw was a matter of where
  the bad read landed.

  The state that maps an image onto the tokens it occupies, and the position
  table that goes with it, belonged to one conversation but was kept once for
  the whole server. Both are sized from the region reserved for the request
  that created them, while every request in the server used them at its own
  position. So an image request with a small region, arriving beside a
  conversation that had a large one, left that conversation reading well past
  the end of both. The state is now per conversation, and the code that reads
  it cannot reach another conversation's copy.

  It needed an overlap to happen. An image on its own is unaffected, and so is
  an image sent after an earlier request has finished, which is why single
  image use and the release gates never saw it. Reproduced on 0.5.0 before the
  fix and confirmed on 0.5.1 with the same test: an image alone passes, an
  image after a 19,000 token request passes, and an image beside that request
  while it is still generating is what fails.

  If you have seen a 504 saying the engine went silent, this is a candidate for
  some of those reports, and it is not claimed as the cause of all of them.
  0.4.3 fixed a different defect with the same symptom.

- **A long prompt left the health check unanswered for the whole of its
  prefill.** The engine answers a health probe once per pass of its serving
  loop, and a prompt with nothing else running went in as a single pass, so
  nothing was answered until the whole prompt was in. Measured on 0.5.0: 60
  seconds of silence on a prompt of 100,000 tokens, against a watchdog that
  stops the container at 180. A large image on a long prompt could cross that,
  and the container was then restarted while it was working correctly.

  The engine now answers between the chunks it already divides a long prompt
  into. The longest silence is one chunk, measured at 26 seconds at the shipped
  settings, for prompts of any length and whether or not other requests are
  running. Health probes allow 30 seconds by default, so this is answered well
  inside a single probe.

### Notes

- No change to weights, to any default, or to what the server computes. Text
  output is byte for byte identical to 0.5.0, and so is image output for a
  request that was not affected by the defect above.

## 0.5.0

### Added

- **The server can read images.** It is off by default and stays off until you
  point `HALOGEN_VISION_TOWER` at the vision sidecar, or set it to `1` to look
  for the file beside the checkpoint. With no tower the image path is not
  merely disabled but absent, so a text-only deployment behaves exactly as it
  did in 0.4.x, byte for byte.

  Both `/v1/chat/completions` and `/v1/responses` accept an image content part
  carrying a `data:` URL or bare base64. An `http(s)` URL is refused on
  purpose: fetching one would make the server issue outbound requests to
  wherever a client asked, which is a different feature with a different threat
  model. Several images in one conversation are attributed correctly, including
  when an earlier one is referred to after a later one arrives.

  `/health` gained a `vision` block saying whether images are accepted, on
  which routes, in what form, and when they are not, why. An image sent to a
  server with no tower is a **400 naming the flag**, rather than a generic
  rejection that blames prompt length.

- **What it reads, stated rather than implied.** Text at 12 pt and above is
  read exactly at every supported resolution. Below that it degrades gradually
  instead of failing: in a battery of several hundred readings, every miss was
  the right field with one to three characters wrong, and none read a different
  field or invented a value. Two things are worth knowing when you choose a
  capture size. A **bigger frame is not better** for the same text, since past
  a point it adds empty area rather than detail. And a **densely filled page is
  harder than a sparse one** at the same point size, which is a matter of
  finding the right row rather than seeing it.

- **`HALOGEN_VISION_MAX_PIXELS`**, default 2560x1440. Larger images are
  downscaled to fit rather than refused, preserving aspect ratio, and nothing
  is refused until four times that. Measured end to end, one image costs about
  5.5, 11.8, 25.3 and 105.8 seconds at 1280x800, 1920x1080, 2560x1440 and
  3840x2160. 4K costs four times a 1440p frame and reads no better, which is
  why the default is where it is. There is no fixed aspect ratio anywhere in
  the path: a tall, wide or square crop all work, and a crop smaller than
  256x256 is scaled up, which helps small text rather than hurting it.

### Changed

- **Image requests are substantially faster.** The work the tower does grows
  with the square of the picture, so at any real capture size it, and not the
  language model, is most of the request. That part is now about 2.3 times
  faster at 1920x1080. Text requests are untouched.

### Fixed

- **A server that had stopped answering could still report itself healthy.**
  If the engine stopped making progress while its process stayed alive, which
  is what an aborted GPU queue looks like from outside, the published
  healthcheck kept passing, `/health` kept returning `ok`, the container stayed
  up, and every request hung until its timeout. The healthcheck was a bare TCP
  connect, which the kernel completes without the engine's help, and `/health`
  answered from the front-end's own state without asking the engine anything.

  Now the engine answers a ping on a queued connection while it is generating,
  the shipped healthcheck asks for that, `/health` returns **503
  `engine_unresponsive`** when it does not come back, and a watchdog
  (`HALOGEN_ENGINE_WATCHDOG_S`, default 180 seconds, `0` to disable) takes the
  container down so a restart policy can act. Docker does not restart a
  container for being unhealthy, which is the only reason the old behaviour was
  survivable.


## 0.4.4

### Added

- **The server now says how much of the machine is left when it finishes
  loading**, because that turned out to be the thing operators most needed to
  know and had no way to see:

  ```
  startup [   4.9 s] host memory left for everything else: 620 contiguous 2 MiB
                     blocks (80.4 GiB total, most of it not contiguous)
  ```

  When that number is low it adds a note explaining what follows: other large
  processes on the host compete for what is left, and when it runs out both
  they and this server can stop for minutes at a time at full CPU with no disk
  activity and no output. That is not a crash and needs no restart, but it
  looks exactly like a hang, and two separate reports spent days on it before
  the server said anything at all.

  The block count leads because it is the number that matters. Plenty of
  gigabytes can be free while almost none of it is in the large contiguous
  pieces another big process needs in order to start or to grow.

- **A README section, "Give it a machine of its own"**, with the same
  information and what to do about it: lower `HALOGEN_KV_POOL_POSITIONS` first,
  and treat `HALOGEN_FLASH_PIN_TRUNK=0` as a last resort at several times the
  decode cost rather than as a tuning option. Compacting memory afterwards does
  not help, because the memory this server holds cannot be moved.

- **`HALOGEN_FLASH_PIN_TRUNK` is documented in the flag reference** as the
  setting to reach for when you must share a machine, with its cost stated.

### Changed

- **`HALOGEN_DMALLOC_LOG` now takes a size in bytes** as well as `1`. `1` keeps
  the previous behaviour and reports the large allocations that make up the
  server's memory budget; a small value such as `4096` reports everything,
  which is what you want if you are investigating what happens while requests
  are being served rather than at startup.

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
