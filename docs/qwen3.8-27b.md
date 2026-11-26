# Qwen3.8-27B

Since 0.21.0 the same image that serves Qwen3.8-Flash-Next also serves **Qwen3.8-27B**, with image input and LoRA
adapters. The server picks the engine from the checkpoint file you name, so there is no second image and no mode to
set. Flash-Next is unchanged.

The model id is `halogen-qwen3.8-27b`, as it was in halogen 0.1.x. Numbers are on the [Measured](performance.md) page.

## Getting the files

The weights are in [peonist-ai/halogen-qwen3.8-27b-ht4](https://huggingface.co/peonist-ai/halogen-qwen3.8-27b-ht4):

| file | size | what it is |
|---|---|---|
| `qwen38-27b-ht4.hgn` | 12.8 GiB | the checkpoint, 4-bit, with the model's draft head |
| `qwen38-27b-vision.hgn` | 0.86 GiB | optional: the vision tower, for images |

Either let the container fetch them on first start:

```bash
podman run --rm -p 8731:8731 \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --ipc=host --ulimit memlock=-1:-1 \
  -e HALOGEN_DOWNLOAD=peonist-ai/halogen-qwen3.8-27b-ht4 \
  -v ~/halogen-models:/models \
  ghcr.io/peonist-ai/halogen-flash-server:0.21.0
```

or download them yourself into a models folder:

```bash
hf download peonist-ai/halogen-qwen3.8-27b-ht4 --local-dir ~/halogen-models
```

## Starting it

Name the checkpoint:

```bash
podman run --rm -p 8731:8731 \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --ipc=host --ulimit memlock=-1:-1 \
  -e HALOGEN_CHECKPOINT=/models/qwen38-27b-ht4.hgn \
  -v ~/halogen-models:/models:ro \
  ghcr.io/peonist-ai/halogen-flash-server:0.21.0
```

A models folder that holds only this checkpoint serves it with no setting. The server reads the file itself to choose
the engine, and refuses, by name and before loading anything, a checkpoint it has no engine for. That includes halogen
0.1.x's 27B files (`qwen3.8-27b-p1w4d-d2.hgn`), which the `halogen:0.1.4` image still serves; 0.21.0 does not load them, and
`halogen:0.1.4` does not load the new file.

## The tokenizer

The weights repository carries a `tokenizer/` folder, which `HALOGEN_DOWNLOAD` fetches with the checkpoint. Its files
are the same as Qwen3.8-Flash-Next's, so a `tokenizer` folder you already have from Flash-Next works too, beside the
checkpoint in the models folder.

## Images

Put `qwen38-27b-vision.hgn` beside the checkpoint and add `-e HALOGEN_VISION_TOWER=1`. The request shapes, limits and
what to expect are on the [Images](images.md) page and are the same as for Flash-Next. Without the flag the server
loads nothing for images and is the text-only engine exactly.

## LoRA adapters

Put PEFT LoRA adapters in a folder named `adapters` next to the model file, one subfolder an adapter. Each is served as
`<model id>:<adapter name>`, for example `halogen-qwen3.8-27b:my-adapter`, by setting that as the request's `model`.

- Up to 8 adapters are served at once. They are converted when the server starts.
- `/v1/models` lists each adapter that loaded.
- An adapter the server cannot use is skipped at start and named, with the reason, in the log and in `/health`.
- A request that names no adapter is answered exactly as before. A request with one decodes about 2.5% slower.

## Memory

The KV cache costs about 73 KiB a position. At the defaults (a 262,144-token context and four slots) the server holds
12.8 GiB of weights, a 36.5 GiB KV pool and about 12 GiB of working memory. `HALOGEN_CTX` and `HALOGEN_KV_SLOTS`
(see [Configuration](configuration.md)) change the pool.
