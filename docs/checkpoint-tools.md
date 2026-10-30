# Measuring a checkpoint

**The image carries four checkpoint tools as modes of the same container.**
Each answers one question about a file:

| mode | the question it answers |
|---|---|
| `verify` | is this file what it says it is? |
| `inspect` | what does it actually carry: precision by family, hashes? |
| `ppl` | how does it compare to the shipped checkpoint (perplexity, and KL against a reference dump)? |
| `niah` | does it still find things at depth? |

They take the same mounts as the server and no port, they load nothing you
do not already have, and every number they print is on the same scale as
the numbers in this documentation, because it is the same engine computing
it. They exist so that a quant you made, a GGUF you pulled, or a fine-tune
you converted can be checked and compared without our fixtures, a torch
install, or our word for it.

The run line is the server's without `-p`, plus the mode and its
arguments. Every example below abbreviates it as `podman run … halogen`:

```bash
podman run --rm \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --ipc=host --ulimit memlock=-1:-1 \
  -v ~/halogen-models:/models:ro \
  ghcr.io/peonist-ai/halogen-flash-server:0.18.19 \
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

## Is this file what it says it is?

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

## What does it actually carry?

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

## How does it compare to the shipped checkpoint?

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

## Does it still find things at depth?

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

## Reading the output as an assistant

Every mode takes `--json`, and the files the modes write are small and
plain: the reference dump is a header (`HREF`, version, K, vocab,
positions) followed by fixed-size records, and `--per-pos` is 16 bytes a
position. `AGENTS.md` has the field lists. The pattern that works: `verify`,
`inspect --json`, `ppl --ref … --worst 20 --json`, then hand the object and
the per-position file to the assistant and ask it what the worst positions
have in common.

---

---

## History

| shipped | what arrived |
|---|---|
| 0.13.0 | the four modes (`verify`, `inspect`, `ppl`, `niah`) in the image |
