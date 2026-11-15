# Quality: what is measured, and what is not

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
([Attention budget](configuration.md#attention-budget-opt-in-and-a-different-configuration)).
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
  distribution; a seed reproduces a request served alone on the same
  drafter.
- A request batched alongside others emits **byte-identical tokens** to the
  same request run alone.
- A prompt-cache hit answers **byte-identically** to a cold run of the same
  prompt, *under `HALOGEN_PROMPT_CACHE=1`*, which is the setting to choose
  when you need that guarantee. The default cache mode trades it for speed at
  every prompt length; [Choosing a cache mode](configuration.md#choosing-a-cache-mode) has the
  numbers on what that trade actually costs.

These properties hold within a release. Between releases a reply at temperature 0
can read slightly differently where two words were nearly tied (the changelog says
so for 0.20.0 and 0.20.5); `HALOGEN_DN_STATE=fp32` restores 0.20.4's arithmetic exactly.

**What is not measured.** We have never run the model at BF16. It does not
fit in 124 GB, which is the whole reason this engine exists, so every quality
number is against either a dequantized-weight reference or our own arms, never
against the full-precision model at scale. Quality comparisons against other
runtimes are not possible: their instruments differ from ours and neither of us
has the BF16 baseline.

---
