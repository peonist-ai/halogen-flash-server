# Inkling-2-Mini preview

halogen now runs Inkling-2-Mini, Thinking Machines Lab's model, as a preview on Strix Halo, with image input and the model's full 1,048,576-token context. It is a separate image tag; `:latest` is unchanged and still serves Qwen3.8 Flash-Next.

## Quickstart

```bash
hf download peonist-ai/halogen-inkling-2-mini --local-dir ~/halogen-models

podman run --rm -p 8731:8731 \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --security-opt seccomp=unconfined --ipc=host --ulimit memlock=-1:-1 \
  -v ~/halogen-models:/models:ro \
  ghcr.io/peonist-ai/halogen-flash-server:0.20.7-inkling-preview
```

The download is about 19 GB: the converted weights, the vision tower, the draft head and the tokenizer ([what each file is](https://huggingface.co/peonist-ai/halogen-inkling-2-mini)). On Docker rather than Podman, replace `--group-add keep-groups` with `--group-add video --group-add render`.

An OpenAI-compatible endpoint comes up on `:8731`: `/v1/chat/completions` and `/v1/models`. The model id is `inkling-2-mini`. Tool calls, structured output and streaming are supported.

## Speed

Measured on Strix Halo (Ryzen AI Max+ 395, 128 GB) through the HTTP endpoint, one request at a time unless stated:

| | tokens/s |
|---|---|
| decode, greedy (`temperature` 0), short prompt | ~54 |
| decode, greedy, 32k context | ~43-48 |
| decode, sampled (what a request with no temperature gets), mean of twelve prompts | ~53-59 |
| sampled, by kind of reply: code, summaries, step-by-step reasoning | ~65-70 |
| sampled: lists and creative writing / casual prose | ~51 / ~46 |
| four requests at once, total | ~96 |
| eight requests at once, total | ~127 |
| prefill, 1.3k to 37k prompt | ~1,850-2,150 |

## What is in it

- The model's experts exactly as Thinking Machines Lab ships them (4-bit and 8-bit); the attention projections as 8-bit and the output head as 6-bit integer codes. The [model card](https://huggingface.co/peonist-ai/halogen-inkling-2-mini) says what was converted and how.
- **The full context.** With nothing set, the server sizes the context to your machine's memory, up to 1,048,576 tokens, and says what it chose when it starts. On a 128 GB machine that is the full million tokens in one pool shared by four requests. `HALOGEN_CTX` and `HALOGEN_KV_SLOTS` set them by hand.
- **Images.** Send them as `data:` URLs in the usual `image_url` content parts. An image costs one token for every 40 by 40 pixels (169 tokens for 512 by 512, 1,296 for 1920 by 1080); larger than 2560 by 1440 is scaled down first.
- **A draft head** that proposes several tokens at a time. The model checks every one, so a greedy reply is the same text with or without it, and a sampled reply is drawn from the same distribution.
- A prompt cache that reuses a shared start of a conversation, in memory.

## Known limits

- **Not evaluated on any task.** No generative benchmark was run. Quality is reported only as closeness to the original model, on the model card.
- **Not served yet** (the server answers 400 with a sentence): stop strings, logprobs, `logit_bias`, the presence, frequency and repetition penalties, `n` above 1. The endpoints are `/v1/chat/completions` and `/v1/models` only.
- The model thinks before it answers. With a small `max_tokens` a reply can end inside the thinking block with no visible answer; give it room.
- Decoding slows as the context grows: about 15 tokens/s with 262,000 tokens of context and about 5 with a million. A 268,000-token prompt was read and answered in about 5 minutes.
- Images only, no video.
- Tested on machines with 128 GB of memory; the sizing for smaller machines was checked by simulation only.
- This is a preview: Inkling-2-Mini is not part of the regular release, and its numbers may move.

Inkling-2-Mini is Thinking Machines Lab's work, used under the Apache-2.0 license and the model's [Acceptable Use Policy](https://thinkingmachines.ai/model-acceptable-use-policy/), which also applies to the converted weights. If you put it in front of other people, the policy asks you to tell them its known limits and that they are talking to an AI system.
