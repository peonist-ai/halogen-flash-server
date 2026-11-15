# Small models on the NPU

The server can also run small models on the Ryzen AI NPU, beside the Flash
model and behind the same port: decisions (`decider-0.8b`), embeddings
(`qwen3-embedding-0.6b`), reranking (`qwen3-reranker-0.6b`), moderation
(`qwen3guard-gen-0.6b`, on `/v1/moderations`), text generation for
summaries and other short jobs (`qwen3.5-2b`, on `/v1/chat/completions`),
images up to 1024x1024 (`flux2-klein-4b`, on `/v1/images/generations`),
speech to text (`qwen3-asr-0.6b` or `qwen3-asr-1.7b`, on
`/v1/audio/transcriptions`) and text to speech (`qwen3-tts-0.6b-customvoice`
or `qwen3-tts-1.7b-customvoice`, on `/v1/audio/speech`), or your own
fine-tune of a decision, embedding, reranking or moderation model, or a LiquidAI LFM3, d1-2B or OvisOCR3 checkpoint.
Decisions over text and pictures (`d3-lite`, `d3-nano`), a streaming guard and larger 4B sizes run there too. See the
[NPU page](NPU.md) for the full list.

Add the NPU to the Quickstart's command:

```
  --device /dev/accel/accel0 \
  -e HALOGEN_NPU_MODELS=decider-0.8b,qwen3-embedding-0.6b,qwen3-reranker-0.6b \
```

A request picks a model by its `model`. The host needs the NPU driver, the NPU firmware and the IOMMU on; the image carries XRT. It also needs the GPU's fabric clock held at its top speed. GPU work and NPU work
at the same time can otherwise hang a Strix Halo machine. Run as root with
`-v /sys:/host/sys` and the server holds the clock itself while it runs.
Rootless, the unit in [`deploy/host/`](https://github.com/peonist-ai/halogen-flash-server/tree/main/deploy/host) holds it at every boot.
Without either, the server refuses to start and prints the commands for your
machine. The Flash model runs somewhat slower while the NPU works.
[docs/NPU.md](NPU.md) has the host's details, the request shapes, and
how to serve your own fine-tune. Leave `HALOGEN_NPU_MODELS` out and nothing
changes.
