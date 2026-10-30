<p align="center">
  <img src="docs/halogen.jpg" alt="halogen-flash" width="760">
</p>

# halogen-flash-server

**halogen™ is the fastest way to run Qwen3.8-Flash-Next on AMD Strix Halo,
and it is built for agents: deep into a long session, each turn starts
answering in about 1.6 seconds.**

Every kernel is written for this one GPU and this one model family. No
general-purpose runtime, no portability layer, no fallback path. That is why it
can do things a general engine cannot, and why it runs on exactly one piece of
silicon.

| 0.18.0, the default configuration | halogen-flash |
|---|---|
| decode | **up to 94 tok/s** on repetitive output · **73** writing code · **54** prose |
| prefill: 8,192 / 32,768 / 131,072-token prompt | **1,821 / 1,740 / 1,675 tok/s** |
| an agent turn, 30,000 to 96,000 tokens of context | **4.2 s** (first token in **1.6 s**) |
| the first turn of a 34,000-token agent prompt, cold | **21 s** |
| decode: editing code / an agent's tool call / six other languages | **81 / 71 / 52 tok/s** |

**What each row is.** The agent turns are three sessions of a coding agent
fixing a bug in a Python repository: each turn sends the whole conversation
back with the model's last tool call and a tool result of 800 to 3,000
tokens appended, and the time runs from the request to the last byte of the
answer, on the client's clock (the median of 115 turns, about 200 tokens of
answer each). Decode is measured on the kind of text each row names. The
best case is five short prompts whose answer repeats itself ("print the word
red ten times" and four like it), shown so it can be compared like for like
with other figures of that kind. Prefill is the image's own `sweep`, on a
synthetic prompt; real text through the chat template runs about 8 to 12%
slower, which is why the cold first turn takes 21 s for 34,000 tokens.

All of it is the published 0.18.0 image at its defaults (the v2 checkpoint,
the prompt cache on, greedy, thinking off) on an AMD Ryzen AI Max+ 395 with
128 GB, at about 85 W of sustained package power. [Measured](docs/performance.md#measured) has
every number for both checkpoints. The prefill rows, and a decode mean over
ten prompt shapes, reproduce with one command from the image
([how](docs/performance.md#served-throughput-end-to-end-over-http)); the agent turns and the
decode by kind of text are measured from the client side, over the same
OpenAI-compatible API you use. Prefill barely decays with depth: 131,072
tokens run at 96% of the 32,768 rate.

**Precision: 4.16 bpw** across the trunk, the experts and the draft head of
the default checkpoint (v2), or 5.25 bpw across all 179.55B parameters with
the FP8 n-gram lookup table counted in. Both are measured from the files
rather than quoted from a format name. [`docs/QUANT.md`](docs/QUANT.md) gives
the breakdown by tensor family, so it can be checked with arithmetic rather
than taken on trust.

At temperature 0, output is byte-identical to serial greedy decode.
Speculation here is a pure speed optimization, verified on every release, not
a quality trade. Since 0.6.0 there are two draft sources, the model's own
draft head and the request's own text (prompt lookup), and the guarantee
covers both.

0.18.21: your own LFM3-1.7B runs on the NPU, and a long request to an NPU model no longer
waits for a whole generated reply ([NPU](docs/NPU.md)). The Flash engine is unchanged: every
Flash reply is byte-identical to 0.18.20's.

Since 0.7.0 the engine also opens a **llama.cpp GGUF** of this model directly:
point it at the file you already have (unsloth's `UD-IQ4_XS`, say) and it
runs on these kernels, with the same speculation and the same identity
guarantee, and no conversion step. See [Bring your own
GGUF](docs/gguf.md#bring-your-own-gguf) for which files, and for the numbers.

There is a [Discord](https://discord.gg/bcm6QknaV6) for questions, for
numbers from your own box, and for comparing setups. Bugs and regressions go
to [issues](https://github.com/peonist-ai/halogen-flash-server/issues), where
the changelog can credit them. See [Community](#community).

---

## Documentation

The full documentation is the [`docs/`](docs/) tree, one page per task. It is
also hosted with search at
[peonist-ai.github.io/halogen-flash-server](https://peonist-ai.github.io/halogen-flash-server/).
For an AI agent: [`llms.txt`](llms.txt) maps every page in one fetch, and
[`AGENTS.md`](AGENTS.md) is the short playbook for deploying, driving or
debugging the server.

| | |
|---|---|
| **[Quickstart](docs/getting-started.md)** | first run on a Strix Halo box, weights included |
| **[Give it a machine of its own](docs/host-setup.md)** | what the server holds; [recipes if you must share it](docs/host-setup.md#if-you-must-share-it) |
| **[API reference](docs/api.md)** | every endpoint, conventions, status codes |
| Clients | [Codex (Responses API)](docs/codex.md) · [Claude Code (Messages API)](docs/claude-code.md) · [agent harnesses](docs/agent-harness.md) · [sessions: keep, fork, join](docs/sessions.md) |
| Requests | [sampling](docs/sampling.md) · [images](docs/images.md) · [token budgets](docs/token-budgets.md) · [as a classifier](docs/classifier.md) |
| **[Configuration](docs/configuration.md)** | [cache modes](docs/configuration.md#choosing-a-cache-mode), [the KV pool](docs/configuration.md#context-and-memory-one-kv-pool-several-conversations), [disk cache](docs/configuration.md#prompt-cache-on-disk-resume-a-conversation-after-a-restart), [1M context](docs/configuration.md#1m-context-opt-in-and-a-different-configuration), [attention budget](docs/configuration.md#attention-budget-opt-in-and-a-different-configuration), [API key](docs/configuration.md#api-key-require-one-on-the-api-port-opt-in), [request records](docs/configuration.md#request-records-a-log-of-what-your-clients-send-opt-in) |
| Checkpoints | [precision](docs/precision.md) · [bring your own GGUF](docs/gguf.md) · [measuring a checkpoint](docs/checkpoint-tools.md) · [QUANT.md](docs/QUANT.md) |
| Numbers | **[measured](docs/performance.md)** · [quality: what is measured, and what is not](docs/quality.md) |
| NPU | [small models on the NPU](docs/npu-small-models.md) · [host details](docs/NPU.md) |
| **[Troubleshooting](docs/troubleshooting.md)** | will not start, hangs at pool reservation, crawls on long prompts, Fedora/SELinux, [the host settings measured on](docs/troubleshooting.md#the-host-settings-these-numbers-were-measured-on) |
| Reference | [every flag](docs/FLAGS.md) · [classify endpoint](docs/CLASSIFY.md) · [what this release is not](docs/limits.md) |

## Quickstart

```bash
mkdir -p ~/halogen-models
podman run --rm -p 8731:8731 \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --ipc=host --ulimit memlock=-1:-1 \
  -e HALOGEN_DOWNLOAD=peonist-ai/halogen-qwen3.8-flash-next \
  -v ~/halogen-models:/models \
  ghcr.io/peonist-ai/halogen-flash-server:0.18.21
```

The weights come from
[peonist-ai/halogen-qwen3.8-flash-next](https://huggingface.co/peonist-ai/halogen-qwen3.8-flash-next)
on Hugging Face; each NPU model's repository is listed on the
[NPU page](docs/NPU.md#where-the-files-are).

One condition first: **set the BIOS carve-out (UMA frame buffer) to its
minimum**, not Auto: this engine wants host RAM, not dedicated VRAM. The
[Quickstart](docs/getting-started.md) covers that, Docker, the compose
file, and upgrading from an older checkpoint.

### Flint preview

A separate image serves RecursiveSI's Flint (40B mixture-of-experts, about
2B active, Apache-2.0) as a preview; `:latest` above is unchanged. On first
start it downloads the int4 weights (about 21 GB) into `~/halogen-models` and
checks them against the tested revision:

```bash
podman run --rm -p 8731:8731 \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --ipc=host --ulimit memlock=-1:-1 \
  -e HALOGEN_SERVE_MODEL=flint \
  -v ~/halogen-models:/models \
  ghcr.io/peonist-ai/halogen-flash-server:0.18.14-flint-preview
```

It is a preview: prefill slows past roughly 80-90k tokens of context, and
speculative decoding is opt-in (`HALOGEN_FLINT_SPEC=1`) and greedy-only.
Speeds, options and limits: [Flint preview](docs/flint-preview.md).

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
