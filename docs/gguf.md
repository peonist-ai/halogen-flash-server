# Bring your own GGUF

`HALOGEN_CHECKPOINT` may name a llama.cpp GGUF of this model
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
  ghcr.io/peonist-ai/halogen-flash-server:0.18.18
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
(measured below), and so does any `llama-quantize` output in those types.
**Since 0.14.1 `Q5_0` is read too**, exactly, on every tensor a `Q4_K_M` or
`Q4_K_S` stores it on (the lookup table and the down experts among them),
and so is a K-quant on `ssm_out`. The engine reorders that tensor's
columns in 128-wide blocks at load and those formats' scale groups are 256
wide, so a K-quant `ssm_out` is stored as the bf16 the engine computes it
in. `Q6_K` on `ssm_out` is still refused. **Since 0.18.18 a `Q4_0` lookup
table is read too**, exactly: ggml-org's official `Qwen3.8-Flash-Next-GGUF`
stores its table that way, and its `IQ4_NL` build loads as it is (issue #217;
WikiText-2 perplexity 3.821, against 3.817 for unsloth's `UD-IQ4_XS` on the
same image). A file re-encoded from an already quantized one, with a tensor
written back as `F32`, carries the first quantizer's rounding and is
refused by the bf16-clean check: use the original file. `Q4_1`, `Q2_K`,
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
(1.8 GiB). A `Q4_K_M`'s K-quant `ssm_out` (36 tensors) is read at 16 bits
the same way. The kernel that removes this is on the list; the numbers
below include the cost as it stands.

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
| prefill 8,192 / 32,768, served (0.14.1) | 1,502 / 1,499 tok/s | 1,485 / 1,465 (within 2.5%) |
| decode, serial, short context | 35.4 tok/s | 25.4 (**-28%**) |
| decode, draft head + prompt lookup, coding-agent turns | 55-57 tok/s | 42-45 |

The checkpoint column is 0.14's w4b. v2 holds about 62 GiB.

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

**Known issue (0.18.4): K-quant files and concurrent requests** (issue #172). On `UD-Q4_K_XL`, a
request that overlaps another one can return an empty reply: its first token ends the turn. The
same requests are normal on `UD-IQ4_XS` and on the engine's own checkpoints. If you serve more
than one request at a time, use one of those.

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

## Convert a GGUF once

Since 0.12.1 the image has a `convert` mode that writes the same lossless
repack to disk as a complete checkpoint of the engine's own kind, with the
lookup table and the draft head folded in, and exits:

```bash
podman run --rm \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --ipc=host --ulimit memlock=-1:-1 \
  -e HALOGEN_DOWNLOAD=peonist-ai/halogen-qwen3.8-flash-next \
  -v ~/gguf-models:/models \
  ghcr.io/peonist-ai/halogen-flash-server:0.18.18 \
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
