# Quickstart

**First, set the BIOS carve-out to its minimum.** Most engines on this
hardware want as much dedicated VRAM as the firmware will give. This one
wants the opposite. Set the UMA frame buffer (or "dedicated graphics
memory") to its smallest explicit value, not Auto. On some boards Auto
means 64 GiB, which hides half the machine from the OS, and the weights
then cannot load. [Troubleshooting](troubleshooting.md#if-the-server-starts-but-crawls-on-long-prompts)
has the detail.

```bash
mkdir -p ~/halogen-models

podman run --rm -p 8731:8731 \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --ipc=host --ulimit memlock=-1:-1 \
  -e HALOGEN_DOWNLOAD=peonist-ai/halogen-qwen3.8-flash-next \
  -v ~/halogen-models:/models \
  ghcr.io/peonist-ai/halogen-flash-server:0.18.18
```

That is the whole thing. It fetches the weights from
[peonist-ai/halogen-qwen3.8-flash-next](https://huggingface.co/peonist-ai/halogen-qwen3.8-flash-next)
on first start (about 111 GiB, so
give it a while; the transfer resumes if interrupted; since 0.13.2 the log
says how many gigabytes have arrived every 30 seconds instead of counting
files) and serves an OpenAI-compatible endpoint on `:8731`, reachable from
your network. The `mkdir` is there because Podman refuses a bind mount
whose source does not exist (`statfs ...: no such file or directory`) where
Docker would create it; through 0.13.1 this block started with the
`podman run` and failed on a fresh machine.

**The tag is pinned on purpose, and `:latest` exists too.** Every release
also publishes `ghcr.io/peonist-ai/halogen-flash-server:latest`. A `run`
does not ask the registry about a tag your machine already has, so a local
`:latest` stays whatever it was on the day you first pulled it (Podman and
Docker both behave this way). Add `--pull=always` to the `run` line to
fetch the newest build on every start, or update by hand with
`podman pull ghcr.io/peonist-ai/halogen-flash-server:latest`. The
Quickstart pins a version because a pinned tag is what makes a bug report
answerable and a bad release reversible: the startup log and `/health` both
name the version either way, but by the time you read a log the tag may
have moved under it. Pin in anything durable, use `:latest` to try the
newest.

Note the models volume is read-**write** here, with no `:ro`, because it is
being downloaded into. Nothing is fetched on later starts, with one
exception: a start with `HALOGEN_DOWNLOAD` set and the volume writable
re-fetches w4b's 2.4 GiB quality sidecar when the one on disk predates the
image (0.6.0 changed that file; a checkpoint is never re-fetched). With
`HALOGEN_DOWNLOAD` unset the container opens no outbound connections at all,
and says at startup if the sidecar is the older one.

**Upgrading from 0.14 or earlier.** Your volume holds 0.14's checkpoint,
`qwen38-flash-next-w4b.hgn` and its sidecar. With `HALOGEN_CHECKPOINT`
unset, 0.15 keeps serving that file and downloads nothing. The startup log
says a newer default is available. To move to it, start once with
`-e HALOGEN_CHECKPOINT=/models/qwen38-flash-next-v2.hgn` and
`HALOGEN_DOWNLOAD` set, and the first start fetches v2 and its lookup
table (about 110 GiB). Once v2 runs, the w4b files can be deleted, and
later starts pick v2 without the variable.

**If you would rather fetch the weights yourself:**

```bash
hf download peonist-ai/halogen-qwen3.8-flash-next --local-dir ~/halogen-models

podman run --rm -p 8731:8731 \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --ipc=host --ulimit memlock=-1:-1 \
  -v ~/halogen-models:/models:ro \
  ghcr.io/peonist-ai/halogen-flash-server:0.18.18
```

The weights repo carries the tokenizer, so one `-v` is all either form needs.
On Docker rather than Podman, replace `--group-add keep-groups` with
`--group-add video --group-add render`: `keep-groups` is a Podman extension.

**If you split the engine and the API into two containers** (the shipped
[`docker-compose.yml`](https://github.com/peonist-ai/halogen-flash-server/blob/main/docker-compose.yml) does), **run both from the same
image tag.** The API renders the prompt and the engine runs it, and what one
release can do the other may not know how to ask for: an API from before
0.5.0 in front of a newer engine sends an image as a placeholder with no
pixels behind it, and the model describes a picture it never received. Since
0.5.8 the engine refuses that, each container prints its version on its
first log line, the API warns at startup when the engine's differs, and
`/health` reports both under `version`. (The text `<|image_pad|>` written in
a message is not a placeholder and, since 0.6.2, is served as text; see #39.)

---
