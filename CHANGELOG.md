# Changelog

## 0.13.0

The checkpoint tools, as modes of the image: `verify`, `inspect`, `ppl`
and `niah`. No weight change; no kernel change; the server's numerics are
untouched (the engine gained one method the tools read the logits through,
which the server never calls). One front-end addition from issue #86
([@Lafunamor](https://github.com/Lafunamor)).

### Added

- **`verify FILE`**: reads an `.hgn` back independently of whatever wrote
  it (header, table, every tensor's dims against the model's geometry, the
  payload size each format implies, per-tensor checksums over the bytes on
  disk, codebooks in order, scales finite) and says `PASS`, or `FAIL`
  naming the first tensor. Exit status is the answer. About 40 s on the full
  checkpoint.
- **`inspect FILE [--json] [--no-hash]`**: the precision by tensor family
  with bits per weight from the shapes, and one sha256 per tensor in table
  order behind the hash of the header and table.
- **`ppl FILE --corpus TEXT`** (or `--ids IDS.bin`): teacher-forced
  perplexity through this engine, the chunk printed with the number.
  `--vs OTHER` compares two files paired (mean per-token difference, t,
  95% interval). `--ref-out REF` writes the file's next-token distribution
  at every position (top-128 log-probs, the tail, the argmax; 50 MB for
  32k tokens) and `--ref REF` scores another file against it: KL on that
  support (a stated lower bound on the exact KL), top-1 agreement, the
  target's probability shift, per band, and `--worst N` decodes the N
  positions the two files disagree on most. `--json` prints one object.
- **`niah FILE --corpus TEXT --depths ...`**: a needle-in-a-haystack
  battery built from your text at the given depths and positions, run
  through the engine and scored.
- The README's [Measuring a checkpoint](README.md#measuring-a-checkpoint)
  section has the recipes, which corpus to use, and what these numbers are
  not (they are not `llama-perplexity`'s). `AGENTS.md` has the `--json`
  shapes and the file formats.
- `/health` lists the image's modes under `modes`, and the image carries
  the same list in the OCI label `ai.peonist.halogen.modes`
  (`HALOGEN_IMAGE_MODES`).
- **`/v1/models` advertises the window and the token limits** (issue #86):
  `max_model_len` and `context_length` (the served context), `meta.n_ctx_train`,
  `max_tokens_cap` and `max_tokens_default`, the values `/health` reports,
  so a generic client or proxy sizes its compaction from the OpenAI surface.

### Notes

- The tools load the model where a mode needs it (`ppl`, `niah`): one model
  per machine at a time, not beside a running server.
- Inside the image `ppl` runs under the image's own engine environment
  (the baked tuning plan, the quality sidecar beside the checkpoint), which
  is the served numerics; `-e HALOGEN_MATMUL_TUNING_FILE=` runs without the
  plan. The mode prints which it did.
- `--corpus` reads the tokenizer from the mounted directory only; a path
  that is not a directory is refused rather than looked up by name.

## 0.12.3

Entrypoint, front end, the repack command's default, and docs. No
weight change, no new kernel, nothing in the engine's numerics. Three
things from reports this weekend: the watchdog's deferral in issue #71
([@YanissAmz](https://github.com/YanissAmz), tracked as issue #85), a
`--repack` that wrote a checkpoint missing its lookup table (Hugging Face
discussion 4), and a request-log field that lied on a lone stream (issue
#84, [@rba](https://github.com/rba)).

### Fixed

- **`flash_serve --repack` wrote a checkpoint without the n-gram lookup
  table unless `--with-table` was given, and that file loads and dies with
  `checkpoint: no tensor named layers.1.ple.ngram_embedding.weight`.** The
  0.7.0 changelog printed the flag in brackets, and a user who ran the
  command on their own working GGUF got exactly that (Hugging Face
  discussion 4). The table is now written by default (`--no-table` is the
  opt-out), the loader's message for that tensor names both ways to such a
  file, and the same repack refuses at the plan, writing nothing, when the
  GGUF itself has no table. The image's `convert` always passed the flag
  and was never affected. Note for anyone quantizing their own: this engine
  reads the table in IQ4_NL only, which is what `llama-quantize` produces
  for it from an IQ4_XS recipe and what the unsloth, bartowski and
  mradermacher builds carry; a Q4_K_M, Q5_K or Q6_K recipe lands the table
  on Q5_0, Q5_1 or Q8_0 and is refused with a message naming the type.
  Reading those is the next GGUF item.

- **A silent engine under constant memory compaction was never taken
  down.** Since 0.11.9 the watchdog defers a silent probe while the
  kernel's `compact_stall` counter climbs, because that silence is usually
  a host short of memory and killing the engine there is what leaves the
  driver holding its GPU memory (issue #79). Two things were wrong with
  it. The counter is host-wide, so on a machine that compacts memory
  without pause it says nothing about this engine; and the watchdog
  restarted its clock on every deferred probe, so the seconds it printed
  were the probe step, not the silence. A reporter's engine sat wedged for
  30 minutes, main thread at 100% of one core in user space, `/health`
  timing out, container up, while the log said `not counted as a wedge`
  every 15 seconds. The clock now moves only when the engine answers,
  every line prints the true silence, the end of a deferral is announced,
  and the compaction deferral is capped by a new setting,
  `HALOGEN_ENGINE_WATCHDOG_DEFER_S` (900 s; `0` = the old unbounded
  behaviour): past it, an engine whose threads are running and not inside
  the kernel is a wedge whatever the counter says, and the takedown line
  names the cap and the counter. A thread in uninterruptible sleep is
  still never killed. The deferral logic has a standing check that drives
  every branch against a fake engine and a fake `/proc`, and it reads red
  on the 0.12.2 script.
- **The request line's `N tok beside other streams` counted tokens
  produced with the drafter's head off**, which includes the adaptive
  policy's rest stretches on a lone stream, so the field appeared on
  requests that had the server to themselves. It now says `with the head
  off`. The number did not change; the label did.

### Docs

- README: the watchdog's bound under "Give it a machine of its own"; that
  `amdgpu.noretry=0` changes a lost GPU mapping from a fault (issue #83)
  into a silent engine (issue #85) and buys no speed; that
  `vm.compaction_proactiveness=0` does not stop the stalls and slows the
  startup reservation; the contiguity case of a start that grinds at
  `reserving the KV pool` with no GTT held. Issue #85 tracks the stalls
  and wedges under host memory pressure across hosts.

## 0.12.2

Engine, front end, entrypoint and docs. No weight change, no new kernel.
Four things the server could not say about itself, from two reports this
week: a fine-tune's assessment on the model's Hugging Face page
(cygnal) and issue #83 ([@noguespi](https://github.com/noguespi)); and
one correction to our own speed gate. Every number below is the
reference machine.

### Added

- **The chat template is probed at startup.** Every thinking control
  (`enable_thinking`, `reasoning_effort: "none"`, `HALOGEN_ENABLE_THINKING=0`,
  the budgets and the answer room) works by asking the chat template to
  render the think block one way or the other, and the server renders
  whatever template the tokenizer directory carries. A tokenizer mounted
  from another repository can carry a template without that branch, and
  through 0.12.1 the server accepted every thinking control against it and
  rendered thinking anyway, with nothing in the log or on the wire saying
  so (cygnal's assessment ran 0.11.4 with a hand-mounted `/tokenizer` and
  reported "no way to disable thinking"). The server now renders a
  one-message conversation with thinking off and on at startup, in the
  entrypoint's pre-flight so the answer comes in a second rather than after
  the weights are pinned, and refuses to start on a template whose two
  renders do not differ the way the controls assume, naming the file in one
  sentence. `HALOGEN_TEMPLATE_UNCHECKED=1` serves it anyway with the same
  sentence as a warning. The startup line and `/health.chat_template` name
  the template (the path that carries the rendered text and the sha256 of
  that text) and the probe's result. The weights repo's own `tokenizer/`
  passes.
- **Thinking is visible per request.** Every chat request's log line ends
  with `think on` or `think off`, and when the server closed the think
  block (the answer room, or the request's own `max_thinking_tokens`) the
  line says `closed at N by answer room` and the reply's
  `usage.completion_tokens_details` carries `reasoning_closed_at` and
  `reasoning_closed_by` (`"answer_room"` or `"max_thinking_tokens"`) beside
  `reasoning_tokens`; on `/v1/responses` the same two ride
  `output_tokens_details`. A reply whose block the model closed itself has
  neither. Under a 2,048 budget the answer room is 1,024 tokens, so a reply
  that reads as about a thousand hidden tokens and then a short answer is
  that close; the fields now name it (cygnal's "~1,049 hidden tokens").

### Fixed

- **`HALOGEN_FLASH_PIN_TRUNK=0` runs at the shipped defaults** (issue #83,
  [@noguespi](https://github.com/noguespi)). The README's own last resort
  for a shared machine exited on the first request, on every release, with
  `internal sizing error in the per-forward arena`: the unpinned path's
  scratch was sized for a decode step (its slack held about 50 prompt
  tokens) and the path itself had no prefill (the grouped-by-expert prefill
  reads the weights in place and was skipped without the pin), so a prompt
  would have run decode kernels once per token. Both are fixed: the scratch
  is sized for a 32,768-token call, and a prompt of 64 tokens or more
  stages each layer's experts onto the GPU once per call (1.43 GB a layer)
  and runs the same grouped prefill the pinned path runs, on the same
  bytes. What it costs, measured on the reference machine: with the weights in the
  file cache, a 32,768-token prompt prefills in 26.6 s against 26.7 pinned,
  8,192 in 8.8 against 7.1, 128 tokens in 2.4 against 1.0, 32 in 2.3
  against 0.45 (the staging is about 7 s a prompt at any length, and on a
  long prompt the grouped kernels run faster on the GPU copy than in place,
  so the two cancel); served, where the unlocked weights compete with the
  KV pool and the lookup table for the file cache, a 6,500-token prompt
  took 28 s, and 51 s on the first request after a start (the copy then
  reads from disk at about 3 GB/s). Decode under the flag is unchanged at 6
  tokens/s against 37, several times slower as documented. The generated tokens match the pinned run's on the three
  longer prompts and differ on the 32-token one, as the flag's numeric
  label has always said. It remains a last resort, and now a working one.
- **No GPU core dump after a fault** (issue #83). After a GPU memory fault
  the bundled runtime wrote a GPU core dump of the process (`GPU coredump:
  ... Falling back to file-based dump`), which for a process with over
  100 GiB mapped is minutes in uninterruptible sleep before the engine can
  exit; the container's watchdog read that silence as a host short of
  memory and waited it out. The container now disables the runtime's dump
  (`HSA_DISABLE_COREDUMP_ON_EXCEPTION=1`) and the process's core file
  (`ulimit -c 0`), so a fault is followed by the engine's exit and the
  takedown path in seconds. Measured with a deliberate fault in a throwaway
  container holding 48 GiB of GPU memory: without the variable the runtime
  wrote a 52 GB dump and the process lived 33 s past the fault, on an idle
  machine with a warm file cache (a host at its memory edge writes that to
  disk under reclaim, which is the minutes in #83's log); with it, no file
  and the process ended within a second of the fault.
- **The speed gate's cold-prefill arm ran its two prompts in the wrong
  order.** The 32k prompt is now measured first, so its number is cold; in
  the old order it hit the 8k prompt's cache entry (the tool's prompts are
  prefixes of each other) and read about 1,690 tok/s where the cold figure
  is about 1,417. The README's numbers were already the cold ones.

## 0.12.1

Engine, front end, entrypoint and docs. No weight change. Three things
reported on the model's Hugging Face thread and on issue #20 (one of them
a speed regression that had stood since 0.11.3), the door that turns a
GGUF into a checkpoint of the engine's own, and two small owed items.
Every number below is the reference machine, the same session as its
control.

### Added

- **Third-party GGUFs load: the DeltaNet projections in any row format**
  (issue #20, the census by [@Syakyr](https://github.com/Syakyr)).
  The engine reorders the linear-attention heads of every DeltaNet layer at
  load, and through 0.12.0 that reorder was implemented for `Q8_0` rows
  only, so `attn_qkv`, `attn_gate` and `ssm_out` had to be `Q8_0`: unsloth's
  bit map and nobody else's, and bartowski's and mradermacher's IQ4_XS files
  were refused by name on their first DeltaNet tensor. The reorder now runs
  on the decoded planes of every format the engine reads (whole rows, or
  whole 32-wide chunks of `ssm_out`'s columns), which is exact: gguf-py's
  own dequant of the source, permuted, matches the repacked planes on every
  tensor of bartowski's file (2^-11 relative on IQ4_XS, the scale's f16
  rounding; 0 on the rest), and the C++ repack and the Python reference
  produce identical bytes. Two more lifts the same file needed: `Q6_K` is
  read on any tensor (it was the output projection only; the kernels were
  already general), and a K-quant (`Q4_K` / `Q5_K`) on a dense tensor is
  read and then kept as a bf16 copy on the GPU, since the affine decode
  kernels exist for the experts only; the log says how many and how much
  (`affine trunk: 12 tensors staged to bf16 on the device (0.35 GiB)` on
  bartowski's IQ4_XS). unsloth's two files repack to the same bytes as
  before, to the hash. bartowski's `IQ4_XS` (91 GB, three shards), measured
  beside unsloth's `UD-IQ4_XS` in one session: fixture agreement with
  transformers 185/192 on both; perplexity over 32K tokens 1.0% higher
  (5.634 against 5.577; its dense layers are 4-bit where unsloth's are
  8-bit, its experts IQ4_XS where unsloth's are IQ3_S); prefill within 1%
  (1,244-1,267 / 1,423-1,425 tok/s at 8,192 / 32,768); serial decode at
  short context 26.1-32.2 tok/s against 26.0-27.1 (a 4-bit trunk is a
  gigabyte less to read a token), with the draft head 33.2-35.9 against
  27.9-30.2 and every speculative stream byte-identical to serial. It holds
  68 GiB in RAM with the head. mradermacher's `i1-IQ4_XS` (91 GB, one file; `Q5_K` on
  every DeltaNet input projection, 48 staged tensors, 1.8 GiB) loads the
  same way: fixture agreement 182/192, serial decode 30.1 tok/s, with the
  draft head 35.8, byte-identical to serial. What is still refused: a K-quant or `Q6_K` on `ssm_out` (the
  column reorder would split their 256-wide scale groups; bartowski's
  `Q4_K_M` and up), and `Q4_1` / `Q5_0` / `Q2_K` / `Q3_K` / IQ2 / IQ1 as
  before.
- **`convert`: a GGUF as a checkpoint of the engine's own, once.**
  `podman run ... halogen-flash-server:0.12.1 convert IN.gguf OUT.hgn`
  writes the lossless repack the engine builds in RAM at every GGUF start
  to disk as one file, with the lookup table and the draft head folded in
  (about 106 GB for an IQ4_XS build, ten minutes on an NVMe disk), and
  exits. A server started on that file takes the engine's own checkpoint
  path (`checkpoint_format: hgn`), loads in seconds from a warm disk, needs
  no GGUF beside it, and answers what the GGUF start answers. The log notes
  a converted trunk and that the quality sidecar does not apply to it.
- **A third saved place for the prompt cache: the start of the last
  message** ([@nightvich](https://huggingface.co/nightvich)'s 1M sweep on
  the Hugging Face thread, where every new question behind the same
  document read as cold). The default cache mode saved its place at the
  end of the system prompt and the end of the previous request; a client
  that keeps a document in one message and asks each new question in the
  next matched neither, so every question re-read the document and only an
  exact repeat hit. The cache now also saves at the start of the request's
  last message, when that message is not the request's only one: on a
  30,000-token document the second question is served 99% from the cache
  and answers in 1.3 s where it took 26 s. The extra save costs nothing
  measurable on the first request (see the fix below) and nothing on a
  hit; a one-message request gets no third place; conversations that
  extend their history each turn were served already and do not change.
  `HALOGEN_CACHE_SNAP3=0` turns it off; `HALOGEN_CACHE_ENTRIES` defaults to
  20 (was 16), five per conversation. A cold request and an exact repeat
  stay byte-identical to what 0.12.0 produced.

### Fixed

- **Every cold prefill under the default cache mode had lost about 5%
  since 0.11.3** ([@rekillkos](https://huggingface.co/rekillkos) measured
  it on the Hugging Face thread: `halogen-bench.py`, three runs a version,
  pp8192 1,381 -> 1,300 tok/s and pp32768 1,565 -> 1,496 at 0.11.2 ->
  0.11.3, held through 0.12.0). Since 0.11.3 the cache captures its save
  point at the end of the conversation history without splitting the
  prefill (the split was issue #65's wrong answers), and the capture
  reached the state at that point by re-running the linear-attention
  recurrence over the prompt up to it, in every DeltaNet layer. On a
  request whose history ends a few tokens before the end of the prompt,
  every single-message request included, that is a second pass over the
  whole prompt: about 5.5% of a cold prefill, once per new prompt, never
  on a cached turn. The recurrence now records the state as it passes the
  save point instead, which costs one 3 MB store per layer; the state it
  records is bit for bit the one it continues with, so nothing in any
  answer changes (checked: a cold request and a resumed turn are
  byte-identical to the previous mechanism's). Served, cache on, one cold
  request per size on the reference machine, 0.12.0 -> 0.12.1: pp8192
  1,190 -> 1,245 tok/s, pp32768 1,348 -> 1,417, each now within 2% of the
  same image's cache-off figure, which is 0.11.2's level. (A note on the
  tool: `halogen-bench.py` builds each prompt as a prefix of the next
  larger one, so with the cache on the 32,768 request hits the 8,192
  request's entry when run in that order and reads high; run the larger
  size first for a cold number. The figures here are cold.) The release speed
  gate now runs a cache-on cold prefill beside its cache-off one; the
  cache-off sweep it ran alone is exactly the setting that skipped the
  capture, which is why no release gate saw this. `HALOGEN_PROMPT_CACHE=0`
  and `=1` reproduce the cache-off number on every version.
- A request whose prompt alone exceeds the context returned a 400 that
  printed a negative room (`leaving room for -778714`); it now says how many
  tokens over the context the prompt is and names the two levers.

### Documentation

- `HALOGEN_SPEC_ADAPT` (the draft head's adaptive policy) has its row in
  FLAGS.md; it had shipped without one.
- The README's *Bring your own GGUF* names what is read on which tensor now
  and what it costs; *Choosing a cache mode* describes the third saved place
  and drops the advice it replaced.

## 0.12.0

Engine only, two kernels of the model's sparse-attention indexer. No weight
change, no new setting. Byte-identical output: the block lists and the scores
both kernels produce are compared bit for bit against the previous kernels at
32k, 262k and 1M tokens (serial and with the draft head), and the logits of a
32,768-token prefill and two decode fixtures are identical; every published
quality number is unmoved. What moves is speed at long context, on both the
decode and the prefill side. The numbers below are the engine's own harness on
the reference machine (quality sidecar, the tuned plan, a 1,044,480-token
prompt at the 1M configuration with `HALOGEN_MAX_TOK=16384`, a 258,048-token
prompt at the default 32,768 arena); the served figures through this image are
in the README's 1M section.

### Fixed

- **Decode at long context was paying for the indexer's block SELECT, not its
  scores.** Each layer's indexer scores every 4-token block of the context and
  keeps the top 512. The select ran as one workgroup per query row walking
  every visible block, which at prefill is thousands of rows in parallel and
  invisible, and at decode is one workgroup per layer, serial in the number
  of blocks: 5.2 ms of a 33 ms step at 262k and 22 ms of a 53 ms step at 1M,
  which is the whole of the decode slope [@nightvich](https://huggingface.co/nightvich)
  measured on the model's Hugging Face thread (42 tok/s at 11k to 16 at 937k
  on 0.11.1). The select is now a register-resident bisection over slices of
  the row, spread across the GPU, with the same result: the same blocks, the
  same tie rule, the same order. Serial decode 30.0 -> 35.2 tok/s at 262k and
  18.9 -> 32.1 at 1M; with the draft head 43.5 -> 49.4 and 27.2 -> 41.7. What is
  left of the depth term at decode is the block-key read itself (768 MiB a
  step at 1M, at the memory roofline), 3.6 ms a step.
- **Prefill at 1M was paying twice for the same indexer.** The select above
  was 18% of a 1M prefill pass, and the scoring kernel another 13% at a
  quarter of the matrix units' rate, because it re-read the whole key set
  once per 16 query rows. The scoring kernel now keeps 128 block keys per
  workgroup in registers and walks the query rows, with the same products
  in the same order. A 1,044,480-token prefill: 1,191 -> 994 s (877 -> 1,051
  tok/s); a 258,048-token prefill 204 -> 199 s; 32k unchanged.

### Documentation

- The README's 1M section carries the served rates at 262k and 1M measured
  through this image.

## 0.11.10

### Added

- **`HALOGEN_CACHE_PRUNE_OLD=1` removes the other builds' cache subtrees at
  startup** (issue #78, @eemin). With `HALOGEN_CACHE_DIR` set, each engine
  build, weights file, context size and numeric setting keeps its own
  subtree there, and `HALOGEN_CACHE_DISK_GIB` bounds only the current one,
  so an upgrade day left 29.5 GB of files no build would read again beside
  the live 8.5 GB. The default keeps them (a rollback finds its cache warm).
  With the flag, after the engine has named its own subtree it removes the
  others and the startup log names each one with its size, then says how
  much was freed. Only a directory the cache itself wrote is a candidate (a
  sixteen-hex name holding a `fingerprint` file); anything else under the
  directory is left alone and counted, as before.
- **Third-party GGUFs whose small tensors are F16 load** (issue #20's later
  report, @Syakyr; the Hugging Face thread's "any gguf version"). unsloth's
  files keep the model's small F32 tensors at F32; bartowski's and
  orcarouter's IQ4_XS write one of them, `blk.1.ple_conv1d.weight`, as F16,
  and the engine refused the whole file for it. F16 is read now where the
  engine's own destination for the tensor is bf16: the values are widened
  exactly and the repack's existing check that every value is bf16 clean
  still applies, so the file's values arrive with their bits intact. What
  the quantizer's F16 step already rounded stays rounded: 101 of that
  tensor's 40,960 values sit under F16's normal range, and a file that
  carries them at F16 carries them on F16's grid. Nothing changes for
  unsloth's files: a synthetic copy of UD-IQ4_XS with that one tensor
  rewritten to F16 repacks every other tensor byte for byte the original,
  and that one exactly as the reference tool reads it. A llama.cpp draft
  head beside such a file (`...-MTP-draft.gguf`)
  is still not the engine's head: `HALOGEN_MTP_HEAD` pointing at one is
  refused in two seconds with the name of the file that is.

### Fixed

- **A served run no longer rewrites the baked tuning plan at a clean exit.**
  Under the shipped `HALOGEN_MATMUL_ALGOS=1` a GEMM shape outside the plan's
  buckets takes the library's first pick and nothing is measured; the plan
  was marked dirty for it anyway, and a clean exit wrote it back with the
  unmeasured buckets added, moving the file's size and time, which the disk
  cache's fingerprint includes. 0.11.9 read the plan from a copy so the
  baked file could not move; the engine now does not mark it dirty for a
  bucket it did not time. A tuning run (`ALGOS` above 1) still records
  every bucket; an absent or stale file is still written.

### Documentation

- `HALOGEN_REASONING_EFFORT`'s text says all three mappings, `medium` to
  `medium` included (issue #76, @ker2x).

## 0.11.9

### Fixed

- **The watchdog no longer kills an engine that is silent inside the
  kernel** (issue #79, @lory9995; issue #35). On a host short of contiguous
  memory the engine stops for minutes inside a page fault or an allocation
  while the kernel compacts memory for it, answers nothing, and comes back;
  the container's watchdog counted that as a wedge and took the container
  down at 180 s, saying in the same breath that a slow host is not a wedge.
  On #79's host that kill landed twice on an engine in that state, and the
  driver then kept the engine's GPU memory after the process was gone (35
  GiB of GTT with nothing alive, a kernel worker in `svm_range_restore_work`
  in D), so every later start hung at `reserving the KV pool` until the host
  rebooted, with the restart policy starting the next one into the same
  wall. Before a silent probe counts, the watchdog now reads the engine's
  thread states in `/proc` and the kernel's `compact_stall` counter in
  `/proc/vmstat`; a thread in uninterruptible sleep, or compaction advancing
  since the last probe, is logged as `not counted as a wedge` and the clock
  restarts when it ends. A wedge on a quiet host (threads running, no
  compaction, no answer) is taken down at the same 180 s as before, and the
  line says which case it saw. The same end state has been reached on three
  other hosts by other unclean exits (#34's two machines, our own gate
  machine), so the README's paragraph on the three amdgpu flags no longer
  says leaving them off avoids it; it does not.
- **A start says what the GPU is already holding, and refuses what cannot
  fit** (issue #79). Before the engine starts, the container reads the
  driver's own counters (`mem_info_gtt_used` and `_total` under the card's
  sysfs node, and `/sys/class/kfd/kfd/proc`, the processes holding the GPU)
  and prints `GTT in use before this start: N GiB of M (F free; this start
  puts about K GiB there)`. Tens of GiB in use with no process holding the
  GPU is memory a previous engine's exit did not give back, and the line
  after it says so and what to do (check `fuser -v /dev/kfd` on the host,
  then reboot; removing containers does not release it). Held by another
  process, it is a note. Less free than the pool and the prefill arena need
  is a refusal at once, since a start that cannot place its pool blocks
  inside the driver instead of failing. The `still loading` heartbeat and
  the shutdown line carry the engine's state and the GTT figure, so a report
  of a hung start has the numbers in it.
- **`/cache` during a long cold prefill answered 500** (owed since 0.11.5).
  The engine reports its counters between rounds, and one 32k prefill chunk
  is longer than the route's 10 s wait. It now answers the last counters it
  had, with `stale_s` set to their age, and 503 with a reason if it has
  none yet.
- **The request line prints `= N t/s` for the prefill only when at least
  2,048 tokens were processed** (owed since 0.11.5, said on #73 and #74). A
  warm follow-up that processed 257 tokens in 1.20 s printed `= 214 t/s`,
  which is one chunk's fixed cost and not a speed, and was read as one. Below
  the threshold the line says `(257 new)`; `timings` is unchanged.
- **`evicted` on `/cache` counted the entries a follow-up drops to take its
  region over** (0.11.8's takeover, issue #75). They are `dropped` now;
  nothing a later request could have hit was lost, and `evicted` is back to
  entries forgotten for room.
- **The pre-flight memory estimate sized every GGUF as UD-IQ4_XS** (issue
  #80, @philtheriver). "Roughly 72 GiB of weights" was that file's repacked
  size; the K-quant `UD-Q4_K_XL` repacks to 78 to 80 GiB, and on a 122 GiB
  box the estimate said 27 GiB to spare while the engine, correctly, refused
  the last pin 2 GiB under its 16 GiB floor, under a restart policy, fifty
  times. The check now reads the GGUF's file type from the header (15 = a
  K-quant, 80 GiB; 30 = IQ4_XS, 72) and sizes the working memory by
  `HALOGEN_MAX_TOK` (21.3 GiB at 32768, 12.5 at 16384; it had said "11 GiB
  of scratch" since before the arena was measured), and its warning names
  the floor and the lever. The engine's refusal is now the summary: how far
  short, and the levers in the order worth trying (`HALOGEN_MAX_TOK=16384`,
  the pool, host memory, `PIN_TRUNK=0` last). `HALOGEN_MAX_TOK=16384` boots
  that box today.
- **The takedown path had never run on a non-zero exit.** The container's
  `set -e` ended the entrypoint the moment its `wait -n` returned the
  watchdog's status or a crashed engine's, so "a component exited; shutting
  down", the SIGTERM to the engine and the wait after it had never run on a
  wedge; the runtime ended the engine with the pid namespace. Now: SIGTERM
  and the engine's own exit, 30 s, then SIGKILL, 30 s, then a line that says
  the engine is inside the kernel and the host needs a reboot. The shutdown
  line carries the GTT figure after the exit.

### Documentation

- `HALOGEN_ENGINE_WATCHDOG_S` is in the flag reference; it had been named by
  the container's own message and two issue replies and by nothing else.
- The README's host settings section, the shared-host section and a new
  troubleshooting entry (a start that hangs at `reserving the KV pool`)
  carry the four occurrences and the check.

## 0.11.8

### Fixed

- **0.11.7's pool changes now apply to clients that do not send
  `reasoning_content` back** (issue #75, the second report from @jtsylve).
  Since 0.11.3 the cache keeps a FULL entry at each turn's prompt end, for an
  exact repeat of that prompt. A follow-up from a client that omits the
  reasoning cannot match it (the template writes `<think>\n\n</think>` where
  the model generated `<think>\n`, and the tokens differ), so the entry it
  hits is the history entry a few tokens shorter, and the region held "a
  longer entry". That made the region not the conversation's own to take
  over, and every step 0.11.7 added (grow in place, move, pack, the clamp)
  was skipped: with free space in the pool the turn took a fresh span, copied
  its rows and left the old region held as a stale duplicate; with none it
  fell to `grows in place: forgot 1 longer entries (cheapest)`. Clients that
  replay their reasoning (Pi with `reasoning: true`) hit the FULL entry
  itself and were on the fixed path all along; hermes-agent and most
  OpenAI-shaped clients were not. Now a FULL entry past the hit does not
  block the takeover; it is dropped (the generation overwrites those rows in
  any case; what is lost is an exact repeat of the previous prompt after the
  next turn began). The fan-out recipe with thinking on and no replay reads
  `moved 2, relocated 3, packed 1, rows_copied 0` where 0.11.7 read `moved 0,
  relocated 0, rows_copied 4` and forgot the parent on its second turn.
  `HALOGEN_CACHE_FULL=0` was the stopgap on 0.11.7.

### Documentation

- **A 128 GB box can start with a 262,144 pool without meaning to.** The
  startup fit budgets `MemTotal` less the 67.7 GiB of resident weights and
  the 20 GiB host reserve; at `HALOGEN_MAX_TOK=32768` a 524,288 pool needs
  about 36.7 GiB, and a machine whose `MemTotal` reads 122.7 GiB (a
  `crashkernel` reservation is enough) has 35.0, so the pool halves and the
  log says `LOWERING THE POOL TO 262144`. The README's memory section now
  says so, with the arithmetic; `HALOGEN_MAX_TOK=16384` is the lever
  (issue #75, @myliuyx).

## 0.11.7

### Fixed

- **A harness fanning out subagents no longer loses the parent's or the
  children's cache when the pool has the room** (issue #75, @myliuyx). With
  one parent and two children busy at once, each child turn using most of
  its reservation, the pool's no-room path forgot the parent on every child
  re-bind (with two children decoding, the parent's region was the only one
  the least-recently-used rule could reach), and once the parent was gone
  the children forgot their own rows on alternate turns: the last resort
  that moves a conversation's rows into the free span ran cold whenever
  that span overlapped the rows' old place, which is exactly the case of a
  region moving down into the hole below itself. The report called it a
  0.11.5 regression; the same workload at 1/8 scale fails the same way on
  0.11.4 (both children cold at turn 5, the parent cold from turn 2), so
  pinning back gains nothing. Now the no-room path takes its no-loss steps
  first and retries them after every eviction: the region grows in place;
  a fresh span holds a move; the conversation's own span counts as free
  and its rows move into a span that includes it, overlap or not (the copy
  goes in block-aligned chunks in the safe direction); held neighbours are
  moved up against the next busy region so the region can grow in place
  (`kv pool: ... moved N held regions ... grows in place (no loss)`); then
  the 0.11.5 clamp (a smaller budget, no copy); and only then does another
  conversation get forgotten. The clamp used to come before the moves, so a
  harness whose turns use their budget had them cut at the room left
  (`finish_reason: length`) where a copy of milliseconds keeps the whole
  budget; it no longer does. The log line for a move carries its time
  (`moved the N rows ... in 12.3 ms`), `/cache.pool` gains `packed`, and
  `cold_resorts` reads 0 from here on. **Sizing still applies:** three
  conversations need `pool >= sum over live conversations of (prompt +
  max_tokens)`, and a child's prompt grows by the whole of each turn's
  generation when the harness replays the reasoning; the README's memory
  section has the arithmetic. Reproduced at 1/8 scale (one parent with a
  step of growth, two children on their own threads each generating 3,100
  of a 4,096 reservation, six turns) on the 0.11.4 and 0.11.6 images and
  gated on the fix, plus a text gate for the overlapping copy (the moved
  rows produce the same greedy continuation as the unmoved ones, byte for
  byte).

## 0.11.6

### Added

- **The engine reads llama.cpp K-quant GGUFs.** `HALOGEN_CHECKPOINT` may now
  name a `Q4_K` / `Q5_K` / `Q5_1` file (unsloth's `UD-Q4_K_XL`), which 0.11.5
  refused by name. Those blocks are read losslessly, as the exact affine
  planes their values define (a per-block scale and minimum, and the packed
  4- or 5-bit weights), the same "moved, not requantized" repack the engine
  already did for the `IQ4_XS` family; a K-quant file's perplexity and
  fixture agreement are its own, not a rounded copy's. On `UD-Q4_K_XL` this
  is the most accurate GGUF the engine runs, 0.020 nats better perplexity
  than `UD-IQ4_XS` and 0.033 better than the engine's own checkpoint over
  32K tokens, at the same prefill and about 3% slower serial decode. See
  **Bring your own GGUF** in the README for the full comparison and the list
  of which block types are read and which are still refused (`Q4_1`, `Q5_0`,
  `Q2_K`, `Q3_K` and the IQ2/IQ1/F16 families, each by name at startup).

## 0.11.5

### Fixed

- **Two long conversations taking turns no longer forget each other on
  every turn** (issue #74, @eemin). A conversation keeps its whole
  reservation (prompt plus `max_tokens`) between turns, and a second
  conversation's region is placed directly after it. When the first's next
  turn needed a few hundred more positions, its region could not grow, no
  free span held a copy, and the only region left to forget was the
  second's: the reporter's harness reserved 32k a turn and used about 2k,
  and both sessions re-prefilled their whole history at 100 to 160 s on
  every turn (`prompt 199574 (61632 cached)`; only the shared system
  prompt survived). Now a follow-up whose region cannot grow runs in the
  room the region has left, with `max_tokens` clamped to it, when that
  room is at least the answer room (`max(1024, 15%)` of `max_tokens`, twice
  that when the request thinks); the thinking budget moves down with the
  clamp so the answer room is kept. The log says so (`kv pool: the region
  at A this request resumes from cannot grow; the turn runs in the N
  positions it has left (max_tokens 32768 -> 30521)`), the request line
  ends with `max_tokens clamped 32768 -> 30521`, and `timings` carries
  `max_tokens_clamped_from` and `max_tokens_clamped_to`. At the reporter's
  shape (1/8 scale) both sessions now read 99% cached on every turn with
  nothing forgotten, where 0.11.4 forgot one of them between every turn.
- **A conversation's rows move to the request's span rather than being
  copied and left behind.** When a turn resumes from a held region whose
  longest entry it continues and needs a fresh span (the region cannot
  grow and has no room left, or the conversation was forked), the rows are
  moved (`kv pool: moved the N rows this request resumes from, region A ->
  B ... the old region is free`) instead of copied with the old region
  kept. The stale duplicates those copies left could not be told from a
  live conversation by the least-recently-used rule, and with a small
  reservation a live session was forgotten for one by its fifth turn; that
  arm now stays warm throughout. A fork's original that never returns is
  freed the moment the fork resumes. A region another request is decoding
  in is still copied, as before.
- **The pool reports its own occupancy** (issue #73, @ker2x). Every
  `serve_api:` request line now carries the cached share of the prompt, the
  prefill rate over the tokens actually processed, and the pool's
  occupancy as the engine reports it (`prompt 59498 (58013 cached, 97.5%),
  prefill 2.29s = 648 t/s | ... | pool 412224/655360 63%`). `/cache` adds
  `token_hit_rate` (prompt tokens the cache covered over every prompt token
  seen; `hit_rate` counts requests) and, under `pool`, `positions`, `used`,
  `usage_ratio`, `busy_regions`, `held_regions`, `room_clamped`, `moved`.
  `/metrics`' `llamacpp:kv_cache_tokens` and `kv_cache_usage_ratio` are the
  engine's occupancy (positions held in every region, busy and held); before
  this they counted what the requests holding a front-end slot had asked
  for, admitted or not, which read 913k against a 655k pool in #74's log.
  That figure keeps a name of its own, `halogen:kv_pool_reserved_tokens`,
  beside `halogen:kv_pool_positions`. No new flag; nothing on the decode
  path. A turn that is not clamped generates exactly what it did; a
  clamped one has a smaller budget and says so.

### Declined

- `HALOGEN_CACHE_IDLE_S`, time-based eviction of idle conversations (issue
  #74). The reproduction showed the mechanism was placement, not idleness,
  and the eviction order already forgets the least recently touched region
  first, which a dead conversation is by construction. A sweep by wall
  clock could only free positions nothing was waiting for, or evict a
  conversation that comes back after the timeout. The fork case the request
  named is covered by the move above.

## 0.11.4

### Fixed

- **A speculative request answers exactly what a serial one answers when the
  thinking cap fires** (issue #69, @drmokchichien). The thinking budget
  (`max_thinking_tokens`, and since 0.11.0 the answer room, which at
  `max_tokens` 256 leaves a budget of one token) closes the think block by
  force when the budget is spent, and the budget is counted on committed
  tokens. A speculative round commits several at once, so under the draft
  head the count crossed the budget inside a round and the close landed a
  token or more later than it does serially; everything after started from
  a different token, and the two drafters disagreed whenever the cap fired
  (the reporter's table: different at 64 to 1024, identical at 8192 where
  thinking ended on its own; the bench's own identity gate failed all ten
  cases on 0.11.2). A round now commits at most what the budget has left,
  so the close lands on exactly the budget's token under any drafter, alone
  or beside other streams. `tools/bench-serving.py serial,mtp 256 low 3`
  passes with the prompt cache on and off; the reporter's table reads
  identical at every size. The same accounting bounds `max_tokens`, so the
  engine no longer computes the rows a length stop would have discarded.
  Note for anyone gating identity on 0.11.3: with the cache on, that
  release passed the bench by accident of request order (the speculative
  arm resumed from the serial arm's saved state, which carried no draft);
  `HALOGEN_PROMPT_CACHE=0` showed the defect there too.
- **A request the KV pool cannot place is no longer parked forever**
  (issue #68, @kamiox). A request reserves its prompt plus `max_tokens`
  positions in one contiguous span. When the conversation it continues
  held a region in the upper half of the pool that could not grow to the
  new reservation, and forgetting every other conversation's region still
  left the span below it short (the reporter's: 131,584 needed, 131,328
  free below, 130,816 possible in place, 256 short either way), the
  scheduler spared that region, found nothing else to forget, and retried
  every pass, for ever: nothing else was running, so nothing freed
  anything, the health probe was answered throughout, `/health` read
  healthy and the request ended only when the client gave up (17 and 30
  minutes in the report; reproduced here in a minute at 1/8 scale). Now
  the last resort moves the conversation's own rows into the free span, so
  the turn stays a cache hit (the log says `moved the N rows this request
  resumes from, region A -> B`; the answer is byte for byte the in-place
  hit's), and when the rows cannot be copied there it forgets them and
  runs the turn cold instead of waiting. A request that does wait, for a
  busy conversation to retire, now says so once in the log (`kv pool:
  request N waits for M positions ...`) and `/cache` carries it under
  `pool`: `waiting_for_room`, `waiting_s`, `relocated`, `cold_resorts`.
- **The startup note on host memory left draws its conclusion** (issues
  #35 @loonylabs-dev and #64 @Bushido76). The engine already printed how
  much host RAM the weights and the KV pool leave; under about 10 GiB it
  now also says what that means (the lookup table's rows page in from disk
  on every long prompt, a prefill takes minutes, the watchdog can read the
  stall as a wedge) and names the two levers, `HALOGEN_KV_POOL_POSITIONS`
  and `HALOGEN_MAX_TOK`. The README's memory section carries the
  reporter's two tables.

## 0.11.3

### Fixed

- **A request that starts cold under the default cache mode now answers
  exactly as it would with the cache off** (issue #65,
  @lev-medien-sandkasten). The default mode (`HALOGEN_PROMPT_CACHE=2`) saves
  its place at the end of the system prompt and at the end of the
  conversation history, and to save its place there it used to split the
  prompt's forward pass at that point. A split pass is not the same
  arithmetic as a single one (the second half runs at a different batch
  size), so a request with nothing to resume still got slightly different
  logits from the cache-off answer. At temperature 0 the answer was the same;
  at `temperature 1.0` the sampler could pick a different early token and, on
  the reporter's reasoning prompt, deterministically land on a coherent wrong
  answer that `HALOGEN_PROMPT_CACHE=1` did not produce. The pass now runs
  unsplit and the state is captured mid-pass instead: a cold request under
  the default mode is byte-identical to modes `1` and `0`, verified on the
  reporter's request and on 161 to 32,768-token prompts. A request that
  *resumes* from the cache is unchanged in kind (a resume was and is a
  numeric seam, documented under *Choosing a cache mode*); its saved place
  is now up to 63 tokens before the exact point, and the next turn re-reads
  those. An exact repeat of a request is a special case: the server now
  keeps one more entry per conversation, the state at the end of the last
  request, so a repeated request restores it and reads nothing again,
  answering byte for byte what it answered the first time (and a little
  faster). `HALOGEN_CACHE_ENTRIES` therefore defaults to 16 (four per
  conversation, about 111 MiB of host RAM each); `HALOGEN_CACHE_FULL=0`
  turns that entry off. `/health` reports `snapshot_align: 64`; `/cache`
  gains `tapped` and `full_hits`.
- **Reasoning no longer streams twice on `/v1/responses` when a summary is
  asked for** (issue #67, @UtkuKaynak). With `reasoning: {"summary":
  "auto"}` the same text went out both as `response.reasoning_text.delta`
  and as `response.reasoning_summary_text.delta`, and a client that renders
  both kinds of delta into one thinking block (Pi, oh-my-pi) showed every
  word twice. Only the stream the request asked for goes out now: the
  summary events with a summary asked, the raw `reasoning_text` events
  without. The reasoning item itself is unchanged (both `summary` and
  `content` when a summary was asked), so Codex and SDK readers see what
  they saw before.
- **The startup line printed while the KV pool is being reserved now names
  the state it was missing** (issue #33, @felladrin): compaction stalls
  climbing with the failed count climbing beside them and the free block
  count flat means the kernel is finding nothing to compact, and the step
  waits on another large process letting memory go.

### Documentation

- The kernel command line section carries the second data point on
  `amdgpu.vm_update_mode=0` / `amdgpu.noretry=0` / `amdgpu.sg_display=0`
  (issue #34, @Unveiledlogic): with them set, GTT stayed allocated after
  the container exited and the next start refused at the pin guard;
  without them it was released within seconds. The advice stays: leave
  them off.


## 0.11.2

### Fixed

- **An image request that has to wait for cache room is no longer refused with
  "GEN declared 1 images but 0 arrived"** (issue #63, @chanadmon11-gif). On a
  busy server (one slot with the prompt cache holding earlier turns), a
  mid-conversation image request often has to wait a moment for room before it
  can start. While it waited, the server dropped the image's pixels and then,
  on the next attempt, saw an image it no longer had and refused the request
  with HTTP 400 -- every time, for that turn, while the engine stayed up. The
  pixels are now kept until the request actually starts, so a queued image turn
  is served rather than refused. The refusal that remains for a genuinely
  missing payload now names each declared image (its token offset and size),
  so a client can pinpoint which one did not arrive.


## 0.11.1

### Fixed

- **An image request after a text request no longer takes the engine down**
  (issue #62, @ionutpopean04). Since 0.10.1, a request without images
  cleared the slot's image-position table on admission (the fix for a text
  turn that had inherited the previous image turn's positions on a cache
  hit), and that clear dropped the table's buffer while keeping its size.
  The next image request on the same slot whose table fit that size reused
  the dropped buffer: `HIP flash_model.hip:4510: invalid argument`, the
  engine exited, the client got `502 engine closed the connection`, and the
  container restarted. The order was text -> image -> text -> image, which is
  any client that sends a text-only side request (a chat title, a summary,
  a sub-agent) between image turns; text -> image -> image -> text was fine,
  and 0.10.0 was fine. The clear now keeps the buffer, as the 0.5.0 reset
  path already did. The release gate's vision cell runs the reporter's
  order and the control order on one server and checks both image answers.

## 0.11.0

### Fixed

- **A side turn no longer evicts the point a conversation continues from**
  (issue #61, @GavinAstk). oh-my-pi's idle recap sends the whole history plus
  a question and then drops that turn from its history, so the next real
  turn continues from where the recap branched. Since 0.8.1 a conversation
  kept one history entry in the prompt cache, the newest, and the recap's
  store replaced the one the conversation needed; the next turn matched only
  the system prompt (`161006 cached` -> `19528 cached`, a 146k-token
  re-prefill, 179 s), and every recap after the first did the same. A
  conversation now keeps its two most recently *used* history entries
  beside the system-prompt entry; the side turn hits and refreshes the true
  one, and the next real turn hits it again. `HALOGEN_CACHE_ENTRIES`
  defaults to 12 (three per conversation) instead of 8.
- **The KV pool no longer forgets what the request it is making room for is
  about to use** (issue #61). When the pool was full, the allocator dropped
  the composable-context store's retained messages first, including the
  ones the request's own plan was about to compose (a 146k re-prefill under
  the flag whose purpose is that prefill), and then cache entries by global
  age without sparing the entry the request had just matched, so a rarely
  hit system-prompt entry could be dropped for its own request's region,
  which read as a cold prefill with no line in the log (`170604` with no
  `cached`, 203 s). Eviction is now by region, oldest first; the matched
  entry is never dropped; a conversation whose only stale entries are dead
  side turns grows its region in place instead of displacing another
  conversation; and every eviction prints `kv pool: no room for N
  positions; forgot ...` so a cold turn has a reason next to it.

### Added

- **Progress lines during a long prompt and a long answer** (issue #49,
  @Bushido76). The engine log prints `flash_serve: req N prefill P/T tokens,
  S s` at every 32,768-token chunk of a prompt and every 20 s inside one,
  and `req N generated K tokens, S s` every 30 s of a generation, so a
  160k-token compaction is visible while it runs rather than only in the
  `serve_api:` line at its end.
- **The answer room.** Thinking no longer consumes the whole `max_tokens`:
  when a request sends no thinking budget, the think block is closed with
  `max(1024, 15% of max_tokens)` tokens left for the answer (the same close
  as `max_thinking_tokens`), so a capped request ends with content rather
  than `finish_reason: "length"` and an empty `content`. Every agent harness
  read for this release sends no thinking control to a custom endpoint
  unless configured to, so the model's `xhigh` was running under whatever
  cap the harness set for the answer: Pi caps a compaction at 13,107 tokens
  and discards it on a length stop, hermes-agent persists nothing from one,
  Cline logs `output_budget_consumed_by_reasoning`. `HALOGEN_THINKING_ANSWER_ROOM`
  sets the room; `0` restores the previous behaviour; `/health` reports
  `thinking_answer_room`. Only a request whose thinking would have run past
  the line is affected.
- **The harnesses' own names for the thinking controls are read**:
  `thinking_budget_tokens`, `thinking_budget`, `thinking_token_budget` (the
  three names Pi's `compat.thinkingTokenBudgetField` can send), the
  `reasoning` object (`enabled`, `effort`, `max_tokens`: OpenRouter's shape,
  sent by hermes-agent and aider) and the `thinking` object (`type`,
  `budget_tokens`: Anthropic's shape, sent by aider's `--thinking-tokens`
  and Kimi-style clients), on `/v1/chat/completions` and `/v1/responses`.
  Two names with two values is a 400, as with the token budget. Before this
  every one of them was silently dropped. `/health` lists them under
  `supported`.

### Documentation

- A README section, *From an agent harness*: what Pi, oh-my-pi, opencode,
  Codex CLI, hermes-agent, Cline, Roo Code and aider each send for thinking
  to a custom OpenAI-compatible server (nothing, unless configured), and
  the setting on each side that changes it.

## 0.10.2

### Fixed

- **A non-streaming request now stops when its client disconnects**
  (issue #58, @dabblingwithcode). Streaming requests have been cancelled on
  disconnect since 0.5.7; a non-streaming one ran to its natural end (EOS,
  `max_tokens` or the thinking budget) holding its slot, which is what
  `in_flight: 1` for 150 s after the client had exited was. On every route
  the connection is now watched once per token; on a disconnect the
  generation is cancelled within a step, the slot and KV reservation are
  released, `/health` and `/metrics` show it at once, and the log prints a
  "client disconnected mid-request" line with the count dropped. The README's
  cancellation passage says all of this.
- **Several leading system messages render as one** (issue #60, @suvayu).
  The model's chat template accepts a single `system` message and only as
  the first, and refused `opencode`'s prompt, which older builds send as two
  system messages. `/v1/chat/completions` now merges a leading run of
  `system`/`developer` messages (strings or text parts) into one, as
  `/v1/responses` already did. A system message after a user or assistant
  turn is still refused, now with its position named.

### Documentation

- `docs/FLAGS.md` lists `HALOGEN_CACHE_DIR`, `HALOGEN_CACHE_DISK_GIB` and the
  three `HALOGEN_COMPOSABLE_CONTEXT*` flags, which the README named and the
  flag list did not; its "every flag is byte-identical except" note now also
  names `HALOGEN_INDEXER_BUDGET` and `HALOGEN_COMPOSABLE_CONTEXT`. The
  composable-context section says its store is in the server's memory, not
  on disk, and gone at restart.

## 0.10.1

### Fixed

- **Composable context: a long conversation could reuse the wrong retained
  message, then the engine exited** (issue #59, @GavinAstk). With the flag on
  and the host store at its byte budget (about 18 retained messages at the
  default 4 GiB), retaining a new message could evict one while a request was
  part-way through reusing others, and the request then reused a neighbour
  of the message it meant to; when the two differed in length the engine
  refused the next reuse and exited, closing every stream on the server
  (`cc_place(... ): ... pos N != at`, then `502 engine closed the
  connection`). A reuse is now checked against the message's own tokens
  before anything is touched, a message that is gone or different is simply
  read fresh, a placement the engine cannot make ends that one request with
  an error instead of the process, and a message the prompt cache's snapshot
  point had split no longer fails to be retained (`... raw rows ... not
  stored` on stderr). Reproduced on 0.10.0 with the smoke that now guards it
  and fixed in this build; with the flag off nothing changes.
- **A text request that resumed from the prompt cache on a slot whose
  previous request carried an image inherited that request's image position
  table**, and its new tokens were rotated by it: the same greedy turn
  diverged from a fresh run some 70 tokens in. Vision servers only
  (`HALOGEN_VISION_TOWER`); a cache miss had always cleared it. A request
  without images now clears the table on admission. Measured before and after
  on the test machine: identical to the restart control after the fix.

## 0.10.0

### Added

- **Prompt cache on disk** (`HALOGEN_CACHE_DIR`, off by default; issue #40
  @D-revv, #4). The resume-anywhere prompt cache now also persists to a
  directory, so a conversation survives a server restart instead of being
  re-read from the start. Each turn's new attention rows are written behind
  the request (nothing on the request path waits), and a request no longer in
  memory is restored from disk: on the test machine a 32k conversation
  resumed across a stop/start in a few seconds against about 40 s of cold
  prefill. About 27 KiB per token (0.9 GB at 32k, 7.2 GB at 262k);
  `HALOGEN_CACHE_DISK_GIB` bounds the directory (default 64, least recently
  used conversations out). Restore from disk is exact (byte-identical to the
  in-memory resume across the restart). Each build/weights/setting keeps its
  own files and never restores another's. Needs a filesystem that accepts
  direct I/O (a tmpfs or overlay is refused, the cache staying in memory).
  The bundled compose sets a 60-second stop grace period so the last turn is
  flushed. See the README's "Prompt cache on disk" section.

## 0.9.1

### Added

- **`HALOGEN_INDEXER_BUDGET`: the model's sparse-attention budget, raisable at
  startup** (issue #57, @KaiFelixBennett). The checkpoint attends the top 512
  blocks (2,048 tokens) of the context per query; that value is the default
  and the byte-identical path. Set to 4096 (any value 2048–8192, rounded down
  to a multiple of 16) the model attends a superset of what it was trained on,
  which is a different configuration: in the README's retrieval battery
  (16k + 32k rows, 96 cases) 4096 read 95/96 against the default's 94/96,
  recovering both of the default's misses, for 4.5% / 6.7% of prefill at
  8k / 32k and about 2% of decode; perplexity moved within noise on prose,
  code and an agentic transcript. 8192 read 96/96 at a consistent perplexity
  cost and 19% of prefill. Printed at startup, on the INFO line, and at
  `/health.indexer_budget`; speculative decoding stays byte-identical to
  serial at every budget. The README's "Attention budget" section has the
  table.

## 0.9.0

### Added

- **Composable context, opt-in preview** (`HALOGEN_COMPOSABLE_CONTEXT=1`, off
  by default). With the flag on, each message at or above
  `HALOGEN_COMPOSABLE_CONTEXT_FLOOR` (default 2048 tokens) is retained in a
  host store (`HALOGEN_COMPOSABLE_CONTEXT_BYTES`, default 4 GiB, LRU) as it is
  first read; when a later request repeats that message at any offset behind
  the same system prompt, the server reuses the retained work instead of
  reading it again. The use case is harness compaction: a transcript whose head
  is replaced by a summary and whose tool results are kept verbatim reads only
  the summary and the new turn fresh, so the first token after a compaction
  arrives in a couple of seconds instead of after a full re-read. Needs the
  prompt cache (`HALOGEN_PROMPT_CACHE=2`) and the KV pool (`HALOGEN_KV_POOL=1`);
  refuses image requests. **Not the prompt cache and not byte-identical:** a
  reused answer is very close to, but not identical to, the one you would get
  by reading the text fresh (retrieval in testing held at the same rate); with
  the flag off nothing changes and every byte-identical guarantee stands. A
  preview: expect it to get more accurate and broader in later releases.
  `/health.composable_context` reports it; the finish line names how many
  chunks a request reused.

## 0.8.1

### Fixed

- **A token the schema grammar refuses ends the request, not the engine
  connection** (issue #53, @mjbrn, confirmed by @HIM0413). The speculative
  loop returned the same code for "the grammar refused this token" as for a
  dead socket, so the daemon dropped its connection to the front end: a 502
  for the request and a `ConnectionResetError` for the next one on the same
  connection. It now ends that one request with a `400` whose message names
  the token, and every other stream is untouched. The message itself is
  fixed too: a request that ended mid-generation printed its statistics
  where the reason belongs (`the engine refused this request: 0 0 0 0 0 0
  0 0`). The disagreement between the device mask and the host automaton at
  a union-typed property that produced the illegal token is still open;
  that request fails cleanly now.
- **The union-type failure's root cause: a UTF-8 continuation-byte count was
  missing from the grammar's state key**, so a string state mid-multibyte-character
  shared a mask with its completed-character sibling and the engine admitted a
  token it then refused. Reproduced on served requests (a free string of emoji
  and accented text failed 6 of 8 times before the fix, 0 of 8 after) and
  fixed; the structured-output test suite is unchanged (128/128).
- **The prompt cache keeps two entries per conversation, so one session's
  tool calls no longer evict every other session** (issue #54,
  @loonylabs-dev). Each turn stored a new entry at a new length and the
  global LRU then dropped other conversations' anchors: eighteen tool calls
  in one session cost a 120k conversation a 120 s re-prefill. A region now
  holds its system-prompt anchor and its newest history entry; a third store
  replaces the leaf in place. `/cache` reports `superseded`.
- **The vision tower runs only for images the prompt cache did not cover**
  (issue #52, @Biggles10-claude). Every image in a request went through the
  tower on every turn, 2.5 s per 1920x1080 frame, including images whose
  tokens the cache had restored and whose tower output nothing then read: an
  identical 8-image request the engine called 0.05 s of prefill took 21.7 s.
  Covered images now skip the tower; their geometry is still bound.

### Added

- **`max_thinking_tokens`, a thinking budget** (issue #56, @loonylabs-dev),
  on `/v1/chat/completions` and `/v1/responses`, with
  `HALOGEN_MAX_THINKING_TOKENS` as the server default (the request wins). If
  the model has not closed its think block after that many generated tokens,
  the engine closes it (Qwen's own budget sentence, then `</think>`) and the
  answer follows in the same stream, on the same state: no cancel, no second
  request, no re-prefill. Greedy decoding at 100k+ of context can loop inside
  the block and spend the whole `max_tokens` there; the model card's sampling
  settings are the cure, this bounds the damage. Unset, nothing changes.
  `/health` reports `max_thinking_tokens_default`.
- **A floating `:latest` tag** on the container image, from this release on
  (issue #55, @brzewVCE). The README and compose file stay pinned; `/health`
  reports whether the front end and engine versions match.

### Documentation

- README: slots cap admission and extra clients queue rather than dilute,
  with @eemin's sweep from issue #51; the cache's two entries per
  conversation and when to raise `HALOGEN_CACHE_ENTRIES`; the thinking
  budget beside the sampling settings.

## 0.8.0

### Added

- **Structured output: `response_format` `json_schema` and `json_object`
  on `/v1/chat/completions` and `/v1/completions`, `text.format` on
  `/v1/responses`** (issues #14, @hvico, and #43, @fordiy). The engine
  enforces the schema while it decodes: each token is the greedy choice
  among the tokens the schema allows next, so the reply parses and
  validates by construction. The grammar engine is the server's own (no
  third-party library): OpenAI's strict-mode subset plus `json_object`,
  keys in schema order, optional keys skippable, `$ref`/`$defs` with
  recursion, `anyOf`; `pattern`, `format`, `allOf`, `not`, `if`/`then`/
  `else` and the other keywords it does not enforce are refused by name
  (the README lists the three sets, and so does `/health` under
  `structured_output`). The reasoning block stays unconstrained (the JSON
  starts after `</think>`), a request with tools may open a tool call
  instead of the JSON (the schema binds the final text, not a call: the
  Codex approvals reviewer, which sends a schema on every auto-reviewed
  approval, keeps its read-only tool checks), and only the end-of-turn
  token is legal once the value is complete. Every request without a
  schema is bitwise what it was; a constrained request is identical
  serial, with the draft head, with prompt lookup, and beside other
  requests. Greedy only: a sampled request with a schema is a 400 (say
  `temperature: 0`), and so is a schema with an image. `HALOGEN_GRAMMAR=0`
  turns it off.
- **`/metrics`: Prometheus text in llama-server's metric names** (asked
  for on r/LocalLLaMA after 0.7.0's `timings`). `llamacpp:prompt_tokens_total`,
  `prompt_seconds_total`, `tokens_predicted_total`,
  `tokens_predicted_seconds_total` (counters over the engine's own per-request
  numbers, `prompt_n` being the processed count), `prompt_tokens_seconds` and
  `predicted_tokens_seconds` (gauges over the requests since the last scrape,
  as llama-server's), `requests_processing`, `requests_deferred`,
  `kv_cache_tokens` and `kv_cache_usage_ratio` (the positions the requests in
  flight reserve, prompt + `max_tokens` each, over the pool), plus `halogen:`
  counters for what llama-server has no name for: requests, prompt tokens the
  cache covered, draft tokens proposed and accepted, structured requests.
  Always on, no engine round trip; `/health` names it.
- **`reasoning_effort: "none"` turns thinking off for the request** (issue
  #50, @devThLan), on `/v1/chat/completions` and as `reasoning: {"effort":
  "none"}` on `/v1/responses`. It was a 400, and agent clients send it on a
  real path (Hermes turns thinking off for the continuation after a turn that
  spent its whole budget thinking, and for title generation). It is the same
  as `chat_template_kwargs: {"enable_thinking": false}`, wins over
  `HALOGEN_ENABLE_THINKING=1` for that request, and `/health` lists it under
  `reasoning_effort_values`. The server-side default for thinking off stays
  `HALOGEN_ENABLE_THINKING=0`; `HALOGEN_REASONING_EFFORT=none` refuses at
  startup and says so.

### Fixed

- **`timings.prompt_n` is the number of prompt tokens the engine processed,
  not the whole prompt** (issue #48, @felladrin). `prompt_ms` was always the
  engine's time on the tokens after the prefix the cache covered, so on a warm
  turn `prompt_per_second` divided the whole context by the tail's time
  (97,052 tokens over 1.8 s read as 53,000 tok/s in llama-swap). Now
  `prompt_n` excludes `cache_n`, as llama-server's does (the context is
  `prompt_n + cache_n + predicted_n`), and the rate is over those tokens; a
  fully cached prompt reads `prompt_n: 0` and no rate. `usage` is unchanged:
  `prompt_tokens` is still the whole prompt with `cached_tokens` beside it.

## 0.7.0

### Added

- **Bring your own GGUF.** `HALOGEN_CHECKPOINT` may name a llama.cpp GGUF of
  this model (any shard of a split), and the engine opens it itself: at
  startup it repacks every tensor but the lookup table into the layouts its
  kernels read, losslessly (the file's own quantized values, moved, never
  requantized), reads the lookup table from the GGUF in place, and takes the
  draft head from a 1.4 GiB file of its own (`qwen38-flash-next-mtp.hgn`, on
  the weights repo; fetched by `HALOGEN_DOWNLOAD`, or `HALOGEN_MTP_HEAD`). The
  GGUF is then the only large file on disk: 94 GB for unsloth's `UD-IQ4_XS`
  against the 118 GiB of the engine's own checkpoint.

  Read losslessly: `IQ4_NL`, `IQ4_XS`, `IQ3_S` and `Q4_0` experts, a `Q8_0`
  trunk, a `Q6_K` output projection, which is unsloth's `UD-IQ4_XS` build and
  any `llama-quantize` output in those types. The K-quant builds (`Q4_K`,
  `Q5_K`, `Q5_1`, `Q4_1`, unsloth's `UD-Q4_K_XL`) and the IQ2/IQ1 families are
  refused by name before anything is loaded; those need kernels for their
  block layouts and are next.

  Measured on the reference machine with unsloth's `UD-IQ4_XS` against the
  engine's own checkpoint with its quality sidecar, MTP on in both:
  perplexity 0.7 to 2.1% better on three corpora and the fixture agreement
  184/192 against 182 (the 8-bit trunk carries it); prefill within 1% at
  8,192 and 32,768; serial decode 25.4 tok/s against 35.4 (the 8-bit trunk
  is 2 GB more a token, and no lossless repack avoids it), 42-45 on
  coding-agent turns with both drafters against 55-57. Against llama.cpp on
  the same file, same machine, same session, at their settings on stock ROCm
  7.14: prefill 1.9x at 8,192 and 2.7x at 32,768, serial decode 1.1 to 1.3x,
  1.9x on coding-agent turns; every speculative stream byte-identical to
  serial greedy on their file too. The repacked weights are byte-identical
  to `tools/gguf2hgn.py`'s (the reference conversion: every tensor's sha256,
  the header and the table), and a server on the GGUF is bitwise a server on
  that file. The engine's own checkpoint path did not move (bitwise on a
  32,768-token prefill and two fixtures).

  Startup on a GGUF is a read of the whole file on eight threads: 18 s from
  a cold disk on the reference machine, 9 s warm, on every start (the
  repacked weights live in RAM; the page cache is dropped behind them).
  `HALOGEN_GGUF_CACHE=1` writes the repack out once beside the GGUF (70 GiB,
  five minutes on the reference drive; `=<dir>` puts it elsewhere) and later
  starts take the engine's own path, 1.4 s warm and 16 s cold; a cache is
  checked against the shards' sizes and modification times and is never used
  stale (rebuilt with the flag, ignored without, both said in the log).
  `HALOGEN_GGUF_THREADS` (default 8) sets the repack's workers.

- **`/v1/responses` returns the model's reasoning** (#44, reported with
  frame-by-frame timings by [@samuelobao](https://github.com/samuelobao)): a
  `reasoning` output item ahead of the message, its text as a `reasoning_text`
  content part streamed in `response.reasoning_text.delta` events, and, when
  the request asks for a reasoning summary (Codex sends
  `reasoning: {"summary": "auto"}`), the same text again as `summary_text`
  with the `response.reasoning_summary_*` events, since there is no separate
  summarizer. Codex renders summaries by default and raw content only with
  `show_raw_agent_reasoning`. Both routes now report
  `output_tokens_details.reasoning_tokens` (`completion_tokens_details` on
  chat), counted from the position of the `</think>` token, and the
  Responses usage carries `input_tokens_details.cached_tokens`. Dropping the
  reasoning was a decision from when the only documented reasoning item
  carried an encrypted payload; it no longer holds.
- **Statistics in llama-server's shape** (#45, requested by
  [@DomiStyle](https://github.com/DomiStyle) for llama-swap): a `timings`
  object on every response on both routes, on the non-streamed body, the
  stream's finish chunk and its usage chunk, and the `response.completed`
  frame: `prompt_n`, `predicted_n`, `prompt_ms`, `predicted_ms`,
  `prompt_per_second`, `predicted_per_second`, `cache_n`, `draft_n`,
  `draft_n_accepted`. Every field is the engine's own per-request line;
  `draft_n` counts the draft head's proposals and the prompt-lookup chains'
  proposed tokens together (the engine now reports the latter), so drafted
  against accepted is exact.
- `/health` reports `checkpoint_format`: `hgn`, `gguf` or `gguf-cache`.
- `flash_serve --repack IN.gguf --out OUT.hgn [--with-table]` writes the same
  repack to a file, for anyone who wants the artifact; `--repack-hash` prints
  a sha256 per tensor for the file it would write.

### Fixed

- **Every start on the current quality sidecar said it predated 0.6.0**, and
  with `HALOGEN_DOWNLOAD` set and the volume writable fetched the sidecar
  again each time. The check read the file's first 256 KB through a pipe
  into `grep -q` under `pipefail`; the marker it looks for sits at byte
  115,944 of the published file, past the pipe buffer, so `grep` exited on
  the match, `head` died of SIGPIPE and the pipeline's status was the
  producer's. Found and diagnosed by
  [@Biggles10-claude](https://github.com/Biggles10-claude) (#47). The
  producer is a process substitution now, and the release gate runs a cell
  on the current sidecar (every earlier run had only the stale one to test
  against).

### Documentation

- README: [Bring your own GGUF](README.md#bring-your-own-gguf), with the
  format table, the memory and disk figures, the quality and decode trade in
  numbers, and the same-file comparison against llama.cpp. The published
  prefill, decode and quality rows are unchanged: the engine's own checkpoint
  is what they measure.

## 0.6.3

Engine only, one loop. No kernel change, no weight change, bitwise identical
output (checked on a 32,768-token prefill and on a 1,068-token fixture), so
every published prefill, decode and quality number is unmoved; the prefill
rows are best-of-two and this changes the first pass only.

### Fixed

- **The first long prompt after a restart read the lookup table one row at a
  time.** The model's 47.7 GiB n-gram table is read through the page cache,
  never held in RAM, and on a 128 GB machine running this server there is
  never enough cache left to hold all of it (about 13 GiB at the defaults),
  so any prompt whose rows are not cached reads them from disk. Each row is
  one 4 KB random read, and the engine issued them one after another and
  waited for each: 28 MB/s on the reference machine's NVMe drive, a
  32,768-token prompt paying 46 to 52 s on top of its usual 25 s with the
  table evicted, and 13.5 s on top of an 8,192-token prompt's 7 s. On a
  host with less RAM to spare the table is never cached, and every long
  prompt paid that, at whatever the drive or its contention made one read
  cost; that is the mechanism behind the minutes reported on #10 and #22
  by [@mqtt-fan](https://github.com/mqtt-fan), whose watchdog then read the
  silence as a wedge.

  The rows are now read 64 at a time (`HALOGEN_NGRAM_GATHER_THREADS`, `1`
  restores the old loop). Same bytes to the same places. Measured on the
  reference machine with the table evicted before each run: the
  32,768-token first prompt costs 1.3 s over its usual time instead of 46
  to 52 (8 threads 7.3 s, 16 and 32 about 3 s, 64 1.3 s, 128 1.2 s); the
  8,192-token one under half a second instead of 13.5. The health PING is
  answered through the read as before. The `lookup table: ... took N s`
  line now says how many threads read it.

  What this does not change: a drive that tops out below 64 reads in
  flight (SATA queues 32; a spinning disk is slow at any depth) gets that
  drive's depth rather than one; decode is untouched (16 rows a token); and
  the amount of the table that fits in cache is the same, so
  `HALOGEN_KV_POOL_POSITIONS=262144` still leaves more of it resident.

### Documentation

- README: the cold-start cost is stated with the version that changed it, in
  the pool section and in "If the server starts but crawls on long prompts";
  `--bench-prefill` in the engine's harness prints each pass, so the
  first-pass cost is a number in the log rather than something inferred.

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
