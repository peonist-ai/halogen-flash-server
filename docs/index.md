# halogen-flash-server

**halogen™ is the fastest way to run Qwen3.8-Flash-Next on AMD Strix Halo
(gfx1151), and it is built for agents.** One GPU, one model family, every
kernel written for this exact silicon, shipped as a container with an
OpenAI-compatible API.

## Using it

The server speaks the OpenAI API at `/v1`, and `/health` is the authoritative
account of what the build you are running supports: the sampling fields,
whether images are accepted, the token budget aliases and the current default,
and the tool-call wire format. What follows is the part worth reading first.

## The documentation

**Start here if you are new:** [Quickstart](getting-started.md), then
[Give it a machine of its own](host-setup.md): what the server holds and
what that leaves for anything else.

**Driving it from a client:**

- [API reference](api.md): every endpoint, conventions, status codes
- [Codex and the Responses API](codex.md)
- [Claude Code and the Anthropic Messages API](claude-code.md)
- [From an agent harness](agent-harness.md)
- [Sessions: keep, fork and join](sessions.md)
- [Sampling](sampling.md) · [Images](images.md) ·
  [Token budgets](token-budgets.md) · [Using it as a classifier](classifier.md)
- [Agent guard (preview)](agent-guard.md): with the NPU, a small model reads
  each tool result and can hold a side-effecting tool call

**Configuring it:**

- [Configuration](configuration.md): cache modes, the KV pool, the prompt
  cache on disk, 1M context, the attention budget, composable context, an
  API key, request records
- [Precision: what you get, and how to trade it](precision.md)
- [Bring your own GGUF](gguf.md)
- [Small models on the NPU](npu-small-models.md) and the
  [NPU host details](NPU.md)
- [Flint preview](flint-preview.md): RecursiveSI's Flint on its own image tag

**Understanding the numbers:**

- [Measured](performance.md): every published number, both checkpoints,
  with the conditions each was taken under
- [Quality: what is measured, and what is not](quality.md)
- [Measuring a checkpoint](checkpoint-tools.md): `verify`, `inspect`, `ppl`,
  `niah` as modes of the image

**When something is wrong:**

- [Troubleshooting](troubleshooting.md)
- [What this release is not](limits.md)

**Reference:**

- [docs/FLAGS.md](FLAGS.md): every `HALOGEN_*` environment flag
- [docs/QUANT.md](QUANT.md): the shipped checkpoint's precision, by tensor family
- [docs/CLASSIFY.md](CLASSIFY.md): the classify endpoint
- [CHANGELOG](https://github.com/peonist-ai/halogen-flash-server/blob/main/CHANGELOG.md): every release, what changed, and who reported it

**For AI agents:** [AGENTS.md](https://github.com/peonist-ai/halogen-flash-server/blob/main/AGENTS.md)
is the short playbook for deploying, driving or debugging the server, and
[llms.txt](https://github.com/peonist-ai/halogen-flash-server/blob/main/llms.txt)
maps every documentation page in one fetch.
