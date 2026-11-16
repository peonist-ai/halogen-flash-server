# Precision: what you get, and how to trade it

**You are running the quality build by default.** There is nothing to enable.

The checkpoint is one file, with the model's lookup table beside it:

```
qwen38-flash-next-v2.hgn        62.1 GiB   the checkpoint
qwen38-flash-next-ngram.hgn     47.7 GiB   the lookup table (paged, not held in memory)
qwen38-flash-next-drafter-r2.hgn 1.42 GiB  the draft head (0.20.6 on; proposes tokens, answers unchanged)
```

Its weights are 4.16 bits each on average: the experts and the rest of the
model at 4 bits, the small mixing layers between them at 6 bits, and the
draft head's projections at 8. It stays closer to the original model's
outputs than 0.14's checkpoint did, measured on real agent sessions, and
holds about 5.9 GiB less in memory than that checkpoint with its sidecar. **Which families are stored at which
precision is written out in [`docs/QUANT.md`](QUANT.md).**

**A smaller checkpoint, if you need the memory.** `qwen38-flash-next-ht43.hgn`
stores the experts in fewer bits and holds about 8 GiB less in memory than
the default (53.7 GiB against 62.1), with the same lookup table. Prompts are
read about 6 to 10% slower with it, and decode with the draft head runs a few
percent slower. It is opt in. Start with
`-e HALOGEN_CHECKPOINT=/models/qwen38-flash-next-ht43.hgn`, and with
`HALOGEN_DOWNLOAD` set the server fetches it (about 58 GB) beside what the
volume already holds.

**0.14's checkpoint still loads.** `qwen38-flash-next-w4b.hgn` and its
quality sidecar (the two files below) run as before, named with
`HALOGEN_CHECKPOINT`. On a volume that holds only them, they are what an
unset `HALOGEN_CHECKPOINT` serves (see [Upgrading from 0.14 or earlier](getting-started.md)).

**With w4b:** the checkpoint ships as two files, and the engine picks the
second one up on its own when it sits beside the first:

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
[`docs/QUANT.md`](QUANT.md)**, along with what the sidecar changes and
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
