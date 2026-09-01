# halogen-flash: precision of the shipped checkpoint

What the checkpoint the image loads actually carries, and why. This is the
basis for the precision claims in the README.

**4-bit weights are a correctness precondition, not an optimization.**
Qwen3.8-Flash-Next is 125B parameters plus a 51B-parameter n-gram embedding
table, 335 GiB at BF16 and 173 GiB at FP8, against 124 GB of unified memory.
The question was never whether to quantize, only where to spend the bits.

## The base checkpoint

| | |
|---|---|
| file | **115.55 GiB**, 1,198 tensors |
| trunk and experts | 4-bit, per-column groups |
| n-gram embedding table | FP8, 47.7 GiB, a lookup that is paged rather than held resident |
| rank-1, conv1d and projection weights | BF16, passed through unquantized |

## The sidecar, and why it is small

The served checkpoint is **two files**: the base above, plus a **2.31 GiB
quality sidecar** the engine reads in place of the base's copies. It holds 723
non-expert tensors re-quantized against measured activation statistics, and
twelve `o_proj` tensors promoted to 8-bit.

It is small because the loss was concentrated. Measuring each tensor family
against its own BF16 ceiling put nearly all of the non-expert quantization cost
in **twelve tensors, 106 MB, 0.09% of the file**. At 8 bits those twelve
measure as a *statistical tie* with that ceiling. The mechanism is calibration
rather than resolution: the 4-bit trunk is over-confident, and the whole gain
sits in the hardest quartile of predictions.

Running without the sidecar costs about **6-9% perplexity** and buys back about
**2% of serial decode**. The server says which precision it loaded at startup,
and warns if the sidecar is missing. A speed-arm sidecar (the re-quantization
without the 8-bit promotion, 2.22 GiB) ships beside it for anyone who wants
that trade the other way.

## What has not been measured

The model has never been run at BF16 on this hardware. It does not fit, which
is the reason this engine exists, so quality is measured against a reference
running on the same dequantized weights, and between arms, never against the
full-precision model at scale.

The per-tensor quantization map is not published.
