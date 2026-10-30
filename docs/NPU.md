# Small models on the NPU

The server can run small models on the Ryzen AI NPU beside the Flash model, behind the same port. Name them in
`HALOGEN_NPU_MODELS`, and a request picks one by its `model`. Every other request goes to the Flash model, as before.
Nine kinds of model run there:

- **Decisions** with `decider-0.8b` (a Qwen3.5-0.8B classifier). Give a text and a question with 2 to 10 options, and
  get a probability for every option from one pass.
- **Decisions over the whole prompt, pictures included,** with `d3-lite` and `d3-nano` (vLLM Semantic Router's Decision 3.0,
  0.8B and 2B). Ask a choice of up to 255 options, a yes or no, or a score about a text and a picture, and get a probability for
  every answer.
- **Embeddings** with `qwen3-embedding-0.6b`, or with `embeddinggemma-2` (EmbeddingGemma 2) for text, pictures and
  sound in one space.
- **Reranking** with `qwen3-reranker-0.6b`. Score documents against a query.
- **Moderation** with `qwen3guard-gen-0.6b` (Qwen3Guard-Gen-0.6B). Is a prompt, or a reply in its conversation, safe?
- **A streaming guard** with `qwen3guard-stream-0.6b` (Qwen3Guard-Stream-0.6B). It labels a reply from the Flash model
  as it is written.
- **Text generation** with `qwen3.5-2b` (Qwen3.5-2B, thinking off). Summaries and other short jobs, beside the Flash
  model.
- **Images** with `flux2-klein-4b` (FLUX.2-klein-4B). Icons, diagrams, illustrations and placeholders from 256x256 up
  to 1024x1024, square or not, on `/v1/images/generations`, and edits of up to four pictures you send on
  `/v1/images/edits`.
- **Speech to text** with `qwen3-asr-0.6b` or `qwen3-asr-1.7b` (Qwen3-ASR). Recordings up to 20 minutes, on
  `/v1/audio/transcriptions`.
- **Text to speech** with `qwen3-tts-0.6b-customvoice` or `qwen3-tts-1.7b-customvoice` (Qwen3-TTS CustomVoice). Nine
  preset voices, on `/v1/audio/speech`.

Larger sizes of the first three are named the same way (see [Larger sizes](#larger-sizes)). Your own fine-tune of any of the first four runs too. See [Your own model](#your-own-model).

## What the host needs

- The NPU driver, XRT with its NPU plugin, the NPU firmware, and the IOMMU on. See [the host](#host).
- **The GPU's fabric clock held at its top speed.** On Strix Halo, GPU work and NPU work at the same time can hang the
  machine and corrupt the NPU's results while that clock changes speed. Held, they run together cleanly on our
  machines, but some owners still get hard hangs with it held. AMD tracks that fault in
  [ROCm/TheRock#8709](https://github.com/ROCm/TheRock/issues/8709) and expects the fix in a BIOS update with newer
  SMU firmware, so install your maker's newest BIOS. Holding the clock is a setting of the host's GPU driver that only
  the host's root may change, so how it gets held depends on how you run the container:

  - **As root** (`docker run`, or `sudo podman run`): add `-v /sys:/host/sys`. The server then holds the clock itself
    while it runs and gives it back when it stops. Nothing to install.
  - **Rootless podman** (the Quickstart's form): the container cannot change it. Install the unit in
    [`deploy/host/`](https://github.com/peonist-ai/halogen-flash-server/tree/main/deploy/host) once, and it holds the clock at every boot:

    ```
    sudo install -m 755 deploy/host/halogen-fabric-clock /usr/local/sbin/
    sudo install -m 644 deploy/host/halogen-fabric-clock.service /etc/systemd/system/
    sudo systemctl daemon-reload && sudo systemctl enable --now halogen-fabric-clock.service
    halogen-fabric-clock status
    ```

  It costs about a watt while held. If the clock is not held and the server cannot hold it, it refuses to start and
  prints the commands for your machine. This applies to any NPU program beside a GPU program, not only to this server.
- **Host memory for the models you name.** The NPU reads each model from host memory that cannot be swapped, and a
  model takes more of it as it is used, up to about the size of its files: for example `qwen3-embedding-0.6b` 0.8 GiB,
  `decider-4b` 5.5 GiB, `flux2-klein-4b` 7.6 GiB, and twelve models together about 43 GiB. That comes on top of the
  Flash model's weights and its KV pool. At startup the server adds up the models you named and warns when the host
  cannot hold everything once it is in use. While it runs, the NPU engine keeps `HALOGEN_NPU_HOST_FLOOR_GIB` (default
  4) GiB of host memory available: past that, a request answers 503 with the code `host_memory` instead of the host
  running out of memory. Name only the models you use.

Check the NPU with `ls -l /dev/accel/accel0`.

## Start it

The Quickstart's command, with the NPU added (the device, the host's XRT, and the models):

```bash
podman run --rm -p 8731:8731 \
  --device /dev/kfd --device /dev/dri --device /dev/accel/accel0 --group-add keep-groups \
  --ipc=host --ulimit memlock=-1:-1 \
  -v /opt/xilinx/xrt:/opt/xilinx/xrt:ro \
  -e HALOGEN_DOWNLOAD=peonist-ai/halogen-qwen3.8-flash-next \
  -e HALOGEN_NPU_MODELS=decider-0.8b,qwen3-embedding-0.6b,qwen3-reranker-0.6b,qwen3guard-gen-0.6b,qwen3.5-2b \
  -v ~/halogen-models:/models \
  ghcr.io/peonist-ai/halogen-flash-server:0.18.19
```

`HALOGEN_DOWNLOAD` fetches the files of the NPU models that `HALOGEN_NPU_MODELS` names, into `/models/npu`, and the
server checks each one's size and checksum. A model you leave out of the list is not fetched. The five names above are
the folder names, and the guard and the reranker share the embedder's device files. If your XRT came from your distribution, mount it as [the host section](#host) shows. Leave
`HALOGEN_NPU_MODELS` out and the server is exactly what it was without it.

With compose, use `docker-compose.npu.yml`, which runs this same single container. The two-container `docker-compose.yml`
starts no NPU engine.

The NPU models' files stay in memory beside the Flash model's, a few GB in all, about 8 GB more with
`flux2-klein-4b`, about 1.6 GB more with `qwen3-asr-0.6b`, about 4 GB with `qwen3-asr-1.7b`, about 1.1 GB with
`embeddinggemma-2`, about 0.8 GB with `qwen3guard-stream-0.6b`, and about 4 GB with `qwen3-tts-0.6b-customvoice` or
about 5 GB with `qwen3-tts-1.7b-customvoice`. The Flash model runs somewhat slower
while the NPU works, since the two share the memory bus and the chip's power budget.

## Larger sizes

Three more models run on the NPU. They are not in the default list: name them in `HALOGEN_NPU_MODELS`, and they are
fetched and served like the others.

- `decider-4b` (a Qwen3.5-4B classifier) answers decisions as `decider-0.8b` does, with a better answer on harder questions.
  It takes a little longer to decide.
- `qwen3-embedding-4b` (Qwen3-Embedding-4B) for embeddings, and `qwen3-reranker-4b` (Qwen3-Reranker-4B) for reranking.
  The reranker shares the embedder's device files.

Each holds about 5 GB in memory beside the Flash model. A fine-tune of either Qwen3 model, from a path under
`/models`, loads the same way as at the smaller size.

## Where the files are

Each model's files are in its own Hugging Face repository, fetched by name when the model is listed in
`HALOGEN_NPU_MODELS`. The Flash model's are in
[peonist-ai/halogen-qwen3.8-flash-next](https://huggingface.co/peonist-ai/halogen-qwen3.8-flash-next).

| model | repository |
|---|---|
| `decider-0.8b` | [peonist-ai/halogen-npu-decider-0.8b](https://huggingface.co/peonist-ai/halogen-npu-decider-0.8b) |
| `decider-4b` | [peonist-ai/halogen-npu-decider-4b](https://huggingface.co/peonist-ai/halogen-npu-decider-4b) |
| `d3-lite` | [peonist-ai/halogen-npu-d3-lite](https://huggingface.co/peonist-ai/halogen-npu-d3-lite) |
| `d3-nano` | [peonist-ai/halogen-npu-d3-nano](https://huggingface.co/peonist-ai/halogen-npu-d3-nano) |
| `qwen3-embedding-0.6b` | [peonist-ai/halogen-npu-qwen3-embedding-0.6b](https://huggingface.co/peonist-ai/halogen-npu-qwen3-embedding-0.6b) |
| `qwen3-embedding-4b` | [peonist-ai/halogen-npu-qwen3-embedding-4b](https://huggingface.co/peonist-ai/halogen-npu-qwen3-embedding-4b) |
| `embeddinggemma-2` | [peonist-ai/halogen-npu-embeddinggemma-2](https://huggingface.co/peonist-ai/halogen-npu-embeddinggemma-2) |
| `wemm-embedding-4b` | [peonist-ai/halogen-npu-wemm-embedding-4b](https://huggingface.co/peonist-ai/halogen-npu-wemm-embedding-4b) |
| `qwen3-reranker-0.6b` | [peonist-ai/halogen-npu-qwen3-reranker-0.6b](https://huggingface.co/peonist-ai/halogen-npu-qwen3-reranker-0.6b) |
| `qwen3-reranker-4b` | [peonist-ai/halogen-npu-qwen3-reranker-4b](https://huggingface.co/peonist-ai/halogen-npu-qwen3-reranker-4b) |
| `qwen3guard-gen-0.6b` | [peonist-ai/halogen-npu-qwen3guard-gen-0.6b](https://huggingface.co/peonist-ai/halogen-npu-qwen3guard-gen-0.6b) |
| `qwen3guard-stream-0.6b` | [peonist-ai/halogen-npu-qwen3guard-stream-0.6b](https://huggingface.co/peonist-ai/halogen-npu-qwen3guard-stream-0.6b) |
| `qwen3.5-2b` | [peonist-ai/halogen-npu-qwen3.5-2b](https://huggingface.co/peonist-ai/halogen-npu-qwen3.5-2b) |
| `flux2-klein-4b` | [peonist-ai/halogen-npu-flux2-klein-4b](https://huggingface.co/peonist-ai/halogen-npu-flux2-klein-4b) |
| `qwen3-asr-0.6b` | [peonist-ai/halogen-npu-qwen3-asr-0.6b](https://huggingface.co/peonist-ai/halogen-npu-qwen3-asr-0.6b) |
| `qwen3-asr-1.7b` | [peonist-ai/halogen-npu-qwen3-asr-1.7b](https://huggingface.co/peonist-ai/halogen-npu-qwen3-asr-1.7b) |
| `qwen3-tts-0.6b-customvoice` | [peonist-ai/halogen-npu-qwen3-tts-0.6b-customvoice](https://huggingface.co/peonist-ai/halogen-npu-qwen3-tts-0.6b-customvoice) |
| `qwen3-tts-1.7b-customvoice` | [peonist-ai/halogen-npu-qwen3-tts-1.7b-customvoice](https://huggingface.co/peonist-ai/halogen-npu-qwen3-tts-1.7b-customvoice) |

## Decisions

Send the text to judge as the messages. Put the question in `response_format.json_schema.description` and the options
in its `schema`. Ask for `logprobs` to get every option's probability.

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:8731/v1", api_key="none")
r = client.chat.completions.create(
    model="decider-0.8b",
    messages=[{"role": "user", "content": "WIN a FREE iPhone now!!! Click http://bit.ly/x to claim your prize before midnight."}],
    response_format={"type": "json_schema", "json_schema": {
        "name": "spam",
        "description": "Is this email spam?",
        "schema": {"enum": ["no", "yes"]}}},
    logprobs=True, top_logprobs=2)
print(r.choices[0].message.content)                   # the most likely option, as JSON in the schema's shape
for t in r.choices[0].logprobs.content[0].top_logprobs:
    print(t.token, t.logprob)                           # each option's log probability
```

The options can be an `enum`, a `oneOf` of `{"const": ..., "description": ...}` items, `{"type": "boolean"}`, or an
object with one property holding one of those. The answer is the most likely option, in the schema's shape. A decision
is not sampled: `temperature`, `top_p`, `seed` and the penalties are accepted and ignored. A conversation works too:
every message becomes part of the text to judge, and a system message can carry the question instead of the schema.

## System One questions

`POST /v1/systemone` takes TypeSafe's System One request, so a client written for it can point at `decider-0.8b`.
Send a `state` (a string, or an object or array that is sent as JSON) and `questions`, each with a `type`,
`instructions` and `criteria`. There is no API key. `model` can be `decider-0.8b` or any other name, and it runs the
decision model loaded.

```bash
curl -s localhost:8731/v1/systemone -H 'content-type: application/json' -d '{
  "model": "decider-0.8b",
  "state": "Customer: I was charged twice and nobody answers my emails.",
  "questions": {
    "team": {"type": "choice", "instructions": "Which team should handle this",
             "criteria": {"billing": "Payment issues", "technical": "Bugs", "other": null}},
    "anger": {"type": "score", "instructions": "How frustrated does the customer appear",
              "criteria": ["Calm and neutral", "Concerned but civil", "Very angry"]},
    "refund": {"type": "noul", "instructions": "Does the customer request a refund?"}}}'
```

Each question is one pass. A `choice` answers with `choice`, `probabilities` and `confidence`; a `score` with its
expected level (`score`), `legend`, `probabilities` keyed by level number from 0, and `confidence`; a `noul` with the
probability of yes. A choice or score takes 2 to 10 options here, where System One takes up to 255. A bad request
answers 422.

Several questions about one long text: start the server with `HALOGEN_NPU_DEC_RESUME=1`. A request with several
questions then reads the text once. With `HALOGEN_NPU_DEC_RESUME=2`, a later request whose text only adds to an earlier
one also reuses that work (a text that arrives with one question is kept from its second time on). The answers are the
same as without it. It is off by default. It keeps up to `HALOGEN_NPU_DEC_ENTRIES` texts (6), and each kept text holds
memory on the host until it is replaced.

## Decision 3.0

`d3-lite` and `d3-nano` run vLLM Semantic Router's Decision 3.0 models on the NPU. They are not in the default list: name them
in `HALOGEN_NPU_MODELS`, and they are fetched and served like the others. They speak their own System One contract on
`POST /v1/systemone`:

```bash
curl -s localhost:8731/v1/systemone -H 'content-type: application/json' -d '{
  "model": "d3-lite",
  "state": "Customer: I was charged twice and nobody answers my emails.",
  "questions": {
    "team": {"type": "choice", "instructions": "Which team should handle this?",
             "criteria": {"billing": "payments and refunds", "technical": "bugs and errors", "other": null}},
    "refund": {"type": "noul", "instructions": "Does the customer ask for a refund?"},
    "anger": {"type": "score", "instructions": "How frustrated is the customer?",
              "criteria": ["calm", "annoyed", "furious"]}}}'
```

- A `choice` takes 1 to 255 options (each a key, with an optional description); a `noul` is a yes or no; a `score` an ordered list
  of 2 or more levels. The answers have the same shape as the other decision models' System One answers.
- The `state` can be a string, or an object or array (sent as JSON). It can be empty.
- `model` can also be `vllm-sr/d3-lite` or `vllm-sr/d3-nano`, the upstream names; the reply names the model as asked.
- Each question is one pass over the whole prompt. These models read the prompt in both directions, so a stored text is never
  reused between questions (`HALOGEN_NPU_DEC_RESUME` does not apply to them).
- Prompts go up to 8,192 tokens.

### With a picture

Add `images`, a list of one picture, and every question in the request is asked about the picture and the `state` together:

```bash
curl -s localhost:8731/v1/systemone -H 'content-type: application/json' -d @- <<EOF
{"model": "d3-nano",
 "images": ["data:image/png;base64,$(base64 < shelf.png | tr -d '\n')"],
 "state": "A photo from the warehouse camera.",
 "questions": {
   "empty": {"type": "noul", "instructions": "Is any shelf in the picture empty?"},
   "boxes": {"type": "choice", "instructions": "How many boxes are on the top shelf?",
             "criteria": {"none": null, "one to three": null, "four or more": null}}}}
EOF
```

- The picture is a `data:` URL (`data:image/png;base64,...`, or JPEG, WebP and the other common formats), plain base64, or an
  object `{"url": ...}` / `{"image_url": {"url": ...}}` holding one. The server does not fetch picture URLs.
- One picture a request. It is scaled, keeping its shape, to between 256 x 256 and 768 x 768 worth of pixels; a larger one is
  scaled down, so small text in a large screenshot may not survive. A picture more than 200 times wider than tall (or taller than
  wide) is refused.
- A request reads its picture once, however many questions it asks.

| | d3-lite | d3-nano |
|---|---|---|
| base | Qwen3.5-0.8B | Qwen3.5-2B |
| files on disk, the picture reader included | 2.5 GB | 3.0 GB |
| a question, short state | ~80 ms | ~110 ms |
| at 600 tokens | ~190 ms | ~320 ms |
| at 3,500 tokens | ~650 ms | ~1.1 s |
| a question with a picture, 256 x 256 / 768 x 768 | ~0.2 s / ~0.5 s | ~0.35 s / ~0.9 s |

One Strix Halo, one question a request, served alone, the request's wall (HTTP included), with one of the two loaded. Loaded
together they share the NPU's memory, and `d3-nano`'s questions about pictures take 15 to 25% longer.

Their answers match the models' own runtime on the CPU: on text, the same answer on 509 and 502 of 512 questions of our decision
benchmark; with pictures, on 63 and 64 of 64 questions of a public vision benchmark (CV-Bench). The rest were near ties. `d3-nano`
gives better answers on harder questions; `d3-lite` is the faster.

## Embeddings

```python
r = client.embeddings.create(model="qwen3-embedding-0.6b",
                             input=["Instruct: Given a question, retrieve passages that answer it\nQuery:What is the NPU?",
                                    "The NPU is the neural processing unit on Ryzen AI chips."])
vectors = [d.embedding for d in r.data]                 # 1024 floats each, unit length
```

A query carries the task instruction in the model's own form, `Instruct: <task>\nQuery:<query>`. A document carries
none. `dimensions` (32 to 1024) keeps the first dimensions and normalizes them again. `encoding_format` can be `float`
or `base64`. Send text, not token ids. With LangChain's `OpenAIEmbeddings`, set `check_embedding_ctx_length=False`.

## Text, pictures and sound in one space

Name `embeddinggemma-2` (EmbeddingGemma 2) in `HALOGEN_NPU_MODELS` and it is fetched and served on `/v1/embeddings`.
It puts texts, pictures and audio clips in one 768-dimension space, so a text query can find a photo or a voice memo.

```python
r = client.embeddings.create(
    model="embeddinggemma-2",
    input=["a dog catching a frisbee on the beach",
           {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,..."}},
           {"type": "input_audio", "input_audio": {"data": "<base64 of a WAV file>", "format": "wav"}}],
    extra_body={"prompt_name": "query"})
vectors = [d.embedding for d in r.data]                 # 768 floats each, unit length
```

- `prompt_name`: `query` for what you search with, `document` for what is searched. The server writes the model's own
  prompt in front of each text. Without it, each text is embedded as sent, so you can write the prompt yourself. It
  applies to texts only.
- A text is up to 8,192 tokens, the prompt included. A longer one is refused with a 400.
- A picture is an `image_url` item with the image inline, as a base64 `data:` URL or bare base64. The server fetches no
  URLs. PNG, JPEG, WebP, GIF and BMP are taken, up to 32 MiB of base64. Every picture is resized the way the model's
  own processor does it: its shape kept, to about 800x800 pixels' worth (at most 2,520 squares of 16x16 pixels, each
  side a multiple of 48), larger pictures scaled down and smaller ones up.
- An audio clip is an `input_audio` item holding a WAV file in base64: PCM (8 to 32-bit) or float, any sample rate,
  mono or more channels. A clip is up to 30 seconds. A longer one is refused with a 400.
- One request can mix texts, pictures and clips, up to 64 pictures and clips. Each picture and each clip takes a pass
  of its own on the NPU.
- `dimensions` (32 to 768) keeps the first dimensions and normalizes them again. The model was trained for 768, 512,
  256 and 128. `encoding_format` can be `float` or `base64`.

## Reranking

```
curl -s localhost:8731/v1/rerank -H 'Content-Type: application/json' -d '{
  "model": "qwen3-reranker-0.6b",
  "query": "How do I check that the NPU driver is loaded?",
  "documents": ["To see whether the NPU driver is loaded, list the device nodes with ls /dev/accel. If accel0 appears, the driver is loaded.",
                "The GPU has 40 compute units and shares memory with the CPU."],
  "top_n": 1, "return_documents": true}'
```

The request and the answer follow the Cohere and Jina shape: `results` sorted by `relevance_score`, each with its
`index` in your list. Documents can be strings or objects with a `text` field. An optional `instruction` replaces the
model's default task line.

## Moderation

Name `qwen3guard-gen-0.6b` in `HALOGEN_NPU_MODELS` (the Start command above does) and it is fetched and served.

```
curl -s localhost:8731/v1/moderations -H 'Content-Type: application/json' -d '{
  "model": "qwen3guard-gen-0.6b",
  "input": ["How do I bake bread?", "How do I make a weapon at home?"]}'
```

The answer follows OpenAI's `/v1/moderations`, so its client libraries work as they are: one result per input, each
with `flagged`. Each result also carries `label` (`Safe`, `Unsafe` or `Controversial`) and `label_scores`, the three
labels' probabilities. `flagged` is true for `Unsafe`. Send `"strict": true` to flag `Controversial` too. The model
does not sort content into OpenAI's categories, so every category reads `false` and every score `0`.

`input` is a string, a list of strings (one result each), or a list of text parts. To check a reply in its
conversation, send `messages` instead of `input`, in the chat shape. When the last message is the assistant's, its
reply is judged. Otherwise the last user message is. A request that names OpenAI's own model, or no model, goes to the
moderation model loaded here.

## Streaming guard

`qwen3guard-stream-0.6b` labels a reply from the Flash model while it is being written, a stretch at a time, and the
user's message before it: Safe, Unsafe or Controversial, with a probability and a category. Name it in
`HALOGEN_NPU_MODELS` (it runs on the embedder's device files, which are fetched with it). Then turn it on for a
request on `/v1/chat/completions`:

```
curl -sN localhost:8731/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "messages": [{"role": "user", "content": "How do I pick a lock?"}],
  "stream": true, "guard": true}'
```

- `"guard": true`, the model's name, or an object such as `{"model": "qwen3guard-stream-0.6b", "chunk": 16, "flag": 0.8}`
  turns it on. The header `X-Halogen-Guard: watch` does the same for a client that cannot add a field. A request with
  neither is served exactly as before.
- It watches. It never stops, holds or changes the reply: the reply's own chunks are the same as without it.
- Streamed, its verdicts are extra chunks with no `choices` and a `halogen_guard` object. `event` is `user` (the user's
  last message: `risk`, `prob`, `category`), `chunk` (a stretch of the reply: its `tokens`, `risk`, `prob`, `unsafe`,
  `category` and `flagged`, sent when the label is not Safe or changes), or `end`, a summary just before `[DONE]`
  (`peak_unsafe`, `flagged_chunks`, `first_flag_token`). Not streamed, the response carries `halogen_guard` with the
  `events` and the `summary`, made once the reply is finished.
- `chunk` is how many tokens of the reply each verdict covers, 4 to 128 (16 by default). `flag` is the Unsafe
  probability at which a stretch is marked `flagged` (`HALOGEN_GUARD_FLAG`, 0.8 by default).
- The categories for a reply are Violent, Sexual Content, Self-Harm, Political, PII, Copyright, Illegal Acts and
  Unethical. The user's message can also be Jailbreak.
- It reads the reply's text, not its reasoning or tool calls, and the user's last message (up to 1,024 tokens: its
  start and end when it is longer). It watches the first 2,048 tokens of the two together, then says it has stopped.
- Up to `HALOGEN_GUARD_STREAMS` replies (4) are watched at once. One more is served without the guard, and its stream
  says so. Text the guard has not reached yet waits, up to `HALOGEN_GUARD_LAG` characters (4,096). Past that the
  oldest is skipped and a `skipped` event says how much. The end of a streamed reply waits up to
  `HALOGEN_GUARD_FINAL_S` seconds (3) for the last verdicts.
- `/v1/chat/completions` only for now, not `/v1/responses` or `/v1/messages`. A `guard` field this server cannot honour
  (another mode, a model that is not loaded or is not a streaming guard, a `chunk` out of range) is refused with a 400
  before the reply starts.
- It is not a moderation model: `/v1/moderations` and `/classify` refuse it with a 400. Use `qwen3guard-gen-0.6b` to
  judge a finished prompt or reply.

## Classification

A fine-tune saved as a sequence classifier (`Qwen3ForSequenceClassification`) of Qwen3-0.6B or Qwen3-Embedding-0.6B loads by path, as under "Your own model" below, and answers `POST /classify` in vLLM's shape. Name it in `HALOGEN_NPU_MODELS` and use the directory's name as the model.

```
curl -s localhost:8731/classify -H 'Content-Type: application/json' -d '{
  "model": "my-classifier",
  "input": ["Win a free prize now", "Lunch at noon?"]}'
```

Each input gets an entry in `data` with its `index`, the most likely `label` (from the checkpoint's `id2label`), `probs` (one probability per label) and `num_classes`, and `usage` counts the prompt tokens. `input` is a string, a list of strings, token ids, or a list of token-id lists. Send `"use_activation": false` to get the raw scores in `probs`. `truncate_prompt_tokens` and `add_special_tokens` work as in vLLM. Chat `messages` are not taken.

## Generation

Name `qwen3.5-2b` in `HALOGEN_NPU_MODELS` (the Start command above does) and it is fetched and served.

```
curl -s localhost:8731/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "qwen3.5-2b",
  "messages": [{"role": "user", "content": "Summarize this in three sentences: ..."}]}'
```

A chat request that names `qwen3.5-2b` runs on the NPU. Every other chat request goes to the Flash model. The answer
follows OpenAI's chat completions, streamed or not, with `stop` strings and usage. The model reads text only, calls no
tools, and answers without thinking. A request that sets no sampling fields gets the model card's (temperature 1.0,
`top_k` 20, `presence_penalty` 2.0), and any of them can be set per request. `max_tokens` defaults to 2,048.

## Images

Name `flux2-klein-4b` in `HALOGEN_NPU_MODELS` and it is fetched and served. It draws an image from a prompt, on
`/v1/images/generations` in OpenAI's shape:

```
curl -s localhost:8731/v1/images/generations -H 'Content-Type: application/json' \
  -d '{"model": "flux2-klein-4b", "prompt": "a flat vector icon of a cloud with a lightning bolt",
       "size": "512x512", "n": 1, "seed": 7}'
```

- `size`: `WxH`, one of `256x256`, `512x512`, `768x768`, `1024x1024`, `768x512`, `512x768`, `1024x768`, `768x1024`,
  `1024x576`, `576x1024`, `640x512`, `512x640`, `896x512`, `512x896`, `1024x448`, `448x1024`, `1024x512`, `512x1024`,
  `1024x640`, `640x1024`. `auto` is `512x512`. Any other size is refused with the list.
- `steps` (or `num_inference_steps`): FLUX.2-klein draws in four steps. Any other value is refused.
- `n`: one to four images. They are drawn one after another.
- `response_format`: `b64_json` (the default) or `url`, a `data:` URL of the PNG.
- `output_format`: `png` only.
- `seed`: an extension. Image `i` of a request draws at `seed + i`, so the same request gives the same images. Without
  it each request draws its own.
- `quality`: `low` is refused for now. Every other value draws the same image.
- The prompt is written into the model's chat template and cut to 512 tokens.

The model holds about 8 GB of the host's memory while it is loaded. One image request runs at a time on the NPU,
queued with the other NPU models' work.

A 512x512 image takes about 3 seconds and a 1024x1024 image about 10. A 1024x1024 image uses about 0.7 GB of working
memory while it draws.

## Image edits

With `flux2-klein-4b` loaded, `/v1/images/edits` changes the pictures you send as you describe, and
`/v1/images/variations` draws a new take on one. Both use OpenAI's multipart shape:

```
curl -s localhost:8731/v1/images/edits -F model=flux2-klein-4b -F image=@photo.png \
  -F prompt="turn it into a pencil sketch" -F seed=7
```

Several pictures go in one edit, for example a scene and an object to place in it. The prompt names them in the order
they are sent:

```
curl -s localhost:8731/v1/images/edits -F model=flux2-klein-4b -F "image[]=@scene.png" -F "image[]=@cat.png" \
  -F prompt="put the cat from image 2 on the bench in image 1, matching its light" -F seed=7
```

- `image`: one to four pictures (`image` or `image[]`, repeated), PNG, JPEG, WebP, GIF or BMP, each up to 25 MiB. Four
  is the model's limit, and a fifth is refused. Each is cropped to a square at its centre and scaled to 512x512.
  Transparent parts become white. A variation takes one picture.
- `prompt`: the change, in words. An edit needs one. A variation takes none: it is the picture under an empty
  instruction, and each `seed` gives another one.
- `mask` is refused. The model edits by instruction, so describe the part to change in the prompt.
- `size`: `512x512`, `1024x1024`, `auto`, or any size generations serve. An edit comes out at 512x512, or at 1024x1024
  when that size is asked for with one picture. The response's `size` says which, so a client that keeps one size
  setting for both routes can edit what it generated.
- `n` (one to four), `response_format` (`b64_json` or `url`), `output_format` (`png`) and `seed` work as they do for
  generations. A `model` that is not one of the server's own (OpenAI's `gpt-image-1`, say) reaches the loaded image
  model.

An edit takes about 5 seconds with one picture, 7.5 with two, 10 with three and 12.5 with four, and about 12.5
seconds at 1024x1024.

## Speech to text

Name `qwen3-asr-0.6b` or `qwen3-asr-1.7b` in `HALOGEN_NPU_MODELS` and it is fetched and served. It transcribes a
recording on `/v1/audio/transcriptions`, in OpenAI's multipart shape:

```
curl -s localhost:8731/v1/audio/transcriptions -F model=qwen3-asr-1.7b -F file=@meeting.wav
```

- `file`: a WAV file, PCM (8 to 32-bit) or float, any sample rate, mono or more channels. Other formats are refused
  for now.
- Recordings of up to 20 minutes or 25 MiB, whichever comes first, in one request. A longer one is refused with both
  limits named.
- `model`: any name reaches the loaded speech model, so a client that sends `whisper-1` works unchanged. One speech
  model is served at a time. Name `qwen3-asr-0.6b` or `qwen3-asr-1.7b` in `HALOGEN_NPU_MODELS`, not both.
- `language`: optional, a name (`Italian`) or a two-letter code (`it`). Without it the model names the language
  itself.
- `prompt`: optional context for the model, such as names or terms the recording uses.
- `response_format`: `json` (the default, `{"text": ...}`) or `text`. `stream` is refused.

The 1.7B is the more accurate of the two, and the 0.6B the lighter. One transcription runs at a time on the NPU,
queued with the other NPU models' work.

A speech model, the image sizes above 512x512, `embeddinggemma-2`, and `wemm-embedding-4b`'s pictures each need a
large share of the NPU's memory, which every NPU model of the server shares. When a request does not fit beside what the
other NPU models hold, the server closes their idle parts and tries again. They reopen at their next request, which then
takes a little longer, so alternating these models is slower than using one at a time. A request that still does not fit
answers 503 with an error that says so, and the server keeps running. 256x256 and 512x512 images always fit.

While the models take turns, the kernel log (`dmesg`) can show `amdxdna` error lines such as
`Failed to alloc dev bo memory, ret -28`. They mean the driver turned down a first try. The server recovers by itself,
and the answers are unaffected.

## Text to speech

Name `qwen3-tts-0.6b-customvoice` or `qwen3-tts-1.7b-customvoice` in `HALOGEN_NPU_MODELS` and it is fetched and served.
It speaks a text on `/v1/audio/speech`, in OpenAI's request shape:

```
curl -s localhost:8731/v1/audio/speech -H 'Content-Type: application/json' \
  -d '{"model": "qwen3-tts-1.7b-customvoice", "input": "Hello from the NPU.", "voice": "ryan"}' -o hello.wav
```

- `voice`: one of the nine preset voices, `aiden`, `dylan`, `eric`, `ono_anna`, `ryan`, `serena`, `sohee`, `uncle_fu`
  and `vivian`.
- `input`: up to 4,096 characters. One request speaks for about two and a half minutes at most, so split a longer text.
- `language`: optional, `auto` (the default) or one of `chinese`, `english`, `french`, `german`, `italian`, `japanese`,
  `korean`, `portuguese`, `russian`, `spanish`, `beijing_dialect` and `sichuan_dialect`.
- `response_format`: `wav` (the default here) or `pcm` (16-bit mono at 24 kHz). `mp3` and the other compressed formats
  are refused.
- `stream`: with `pcm`, the audio comes as it is made.
- `instructions`: how to speak it, for example "read this like a calm audiobook narrator". The 1.7B takes it, and the
  0.6B refuses it.
- `seed`: optional, the same audio again for the same request. A `speed` other than 1 is refused.

The talker runs on the NPU and the audio is decoded on the CPU. On a Strix Halo the 0.6B speaks about 1.5 times faster
than real time and the 1.7B a little faster than real time, with the first audio in about 0.3 and 0.4 seconds. One
text-to-speech model is served at a time.

The NPU speaks one request at a time, frame by frame. The streaming guard's checks and a short request to another NPU
model (a decision, an embedding, a rerank or a moderation of up to 1,024 tokens) run between two frames, in a fraction
of a second, the guard's checks first; longer requests wait until the speech in progress is done. Under a heavy mix of
NPU requests a speech request takes longer in turn, as it makes room for them. With `HALOGEN_NPU_SPLICE=0` every other
NPU request waits for the speech, the guard's checks among them: a guarded reply that streams beside a long speech
request can then end before the guard has read it, and its end event says so.

<a id="your-own-model"></a>
## Your own model

A fine-tune of the decision, embedding, reranking or moderation model runs on the NPU too. Put it on the models volume as your trainer saved it (a
directory with `config.json`, `model.safetensors` and `tokenizer.json`), and name its path:

```
-e HALOGEN_NPU_MODELS=decider-0.8b,/models/my-guard
```

At the first start the server converts it for the NPU and keeps the result in the same directory
(`halogen-npu.hnpw`), so the next start skips that step. If you change the checkpoint, the next start converts it
again. It is served under the directory's name, here `my-guard`. What it does comes from the checkpoint:

- a fine-tune of Qwen3.5-0.8B answers decisions. Start from `decider-0.8b` to keep its prompt layout, which the server
  builds from your messages and schema.
- a fine-tune of Qwen3-Embedding-0.6B answers `/v1/embeddings`.
- a fine-tune of Qwen3-Reranker-0.6B answers `/v1/rerank`.
- a Qwen3-0.6B or Qwen3-Embedding-0.6B fine-tune saved as a sequence classifier answers `/classify`.
- a fine-tune of Qwen3Guard-Gen-0.6B answers `/v1/moderations`. It must keep that model's chat template: the server
  writes the prompt the way the template does, so a changed policy would not be what runs.

It runs on the NPU program of the model it was tuned from, so that program is fetched too under `HALOGEN_DOWNLOAD`
(the program only, not that model's weights). Anything else is refused at start with a line that says what it found
and what runs: another size or architecture, or a LoRA adapter on its own (merge it into the model first). A read-only
volume works, but then the conversion runs at every start.

## Batching

When one request carries several short inputs (embedding texts, rerank documents, or moderation inputs), they run
together in one pass.
Each result is exactly what it would be alone. `HALOGEN_NPU_EMB_BATCH=0` turns this off.

A batch holds up to 8 inputs of up to 512 tokens each, padded to the bucket, so it costs the same (about 0.38 s) for 2
inputs as for 8. A single input takes about 0.07 s up to 128 tokens and 0.09 s above. The server batches a group only
when running its inputs one by one would take longer: from 6 inputs of up to 128 tokens, from 5 of up to 512. Smaller
groups, and the leftover of a larger request, run one pass each.

## Many requests at once

The NPU runs one pass at a time. A request takes one pass per input, or one per batch of short inputs. Up to
`HALOGEN_NPU_QUEUE` passes (64) wait on the NPU. Passes past that wait in the server, so a burst, such as a whole
knowledge base sent for embedding at once, is answered more slowly, not refused. A request that cannot start within
`HALOGEN_QUEUE_TIMEOUT` gets `503` with the code `engine_busy` and a `Retry-After` header. Raising `HALOGEN_NPU_QUEUE`
changes no result.

## Limits

- A decision is up to 8,192 tokens, its questions and the model's own template included, and so is an
  `embeddinggemma-2` text, its prompt included. Every other input is up to 4,096 tokens, a rerank pair or a moderation
  prompt included (the model's own template counts). A longer one is refused with a 400 that says so.
- An `embeddinggemma-2` audio clip is up to 30 seconds. An image edit takes one to four pictures and comes out at
  512x512, or at 1024x1024 with one picture.
- The streaming guard watches the first 2,048 tokens of the user's last message and the reply.
- A generation prompt is up to 16,384 tokens (its template counts). The prompt and its answer share 18,432 positions,
  so an answer stops there at the latest.
- A decision takes 2 to 10 options (`d3-lite` and `d3-nano`: 1 to 255).
- A transcription takes a WAV file of up to 20 minutes or 25 MiB.
- A speech request takes up to 4,096 characters and speaks for about two and a half minutes at most.
- With several large NPU models loaded (a speech model, `embeddinggemma-2`, `wemm-embedding-4b`, images above
  512x512, `d3-lite` and `d3-nano` together), they take turns at the NPU's memory. Alternating them is slower, and a request that cannot fit answers 503.
- The NPU models are served in the default mode only, not in the two-container setup (`engine` and `api`).

<a id="host"></a>
## The host

- **The NPU driver, `amdxdna`.** Recent kernels carry it. Otherwise, install AMD's xdna-driver package. We test the
  kernel's own driver on Ubuntu 26.04 (kernel 7.0), and AMD's driver 2.25 on kernel 6.17.
- **XRT with its NPU plugin**, from AMD's packages or from your distribution. The container uses the host's XRT, so it
  matches the host's driver. We test AMD's XRT 2.25 and Ubuntu 26.04's XRT 2.21 (`libxrt2`, `libxrt-npu2`).
- **The NPU firmware.** The driver package or `linux-firmware` installs it.
- **The IOMMU on.** The NPU driver needs it. `amd_iommu=off`, which the README measures for GPU prefill, turns the NPU
  off. `iommu=pt` keeps it.

**A known bad pairing: AMD's DKMS driver 2.23 with its XRT 2.23.** On it the NPU can stop every few hundred passes
(`aie2_tdr_work: Device isn't making progress` in `dmesg`, and `command state 8` in the request's error). On the same
host, the kernel's own driver with Ubuntu 26.04's XRT ran the same load clean. Use that, or AMD's 2.25. After such a
fault the server starts the NPU engine again by itself, up to `HALOGEN_NPU_RESTARTS` times (3), while the Flash model
keeps serving.

**Where your XRT lives.** The container needs three XRT libraries from the host: `libxrt_coreutil.so.2`,
`libxrt_core.so.2` and the NPU plugin `libxrt_driver_xdna.so.2`. AMD's packages put XRT in `/opt/xilinx/xrt`, and the
command above mounts that directory. A distribution's packages put it in the system library directory
(`/usr/lib/x86_64-linux-gnu` on Ubuntu, `/usr/lib` on Arch and CachyOS, whose packages are `xrt` and
`xrt-plugin-amdxdna`). Those libraries look for each other at that path, so mount each one twice: once where the image
looks for XRT, and once at its own path. Use these mounts in place of the `-v /opt/xilinx/xrt:/opt/xilinx/xrt:ro`
line, with `L=/usr/lib` on Arch and CachyOS:

```
L=/usr/lib/x86_64-linux-gnu; X=""
for f in libxrt_coreutil.so.2 libxrt_core.so.2 libxrt_driver_xdna.so.2; do
  X="$X -v $(readlink -f "$L/$f"):/opt/xilinx/xrt/lib/${f}:ro -v $(readlink -f "$L/$f"):$L/${f}:ro"
done
# then: podman run ... $X ...
```

Do not mount an `/opt/xilinx/xrt` that holds only links into the system library directory. Inside the container those
links point at nothing. The server names such a link at start and prints the mounts to use.

**The device flags.** `--device /dev/accel/accel0` passes the NPU in. `--ulimit memlock=-1:-1` lets the NPU engine lock
the memory the NPU reads. With podman, `--group-add keep-groups` covers it (your user must be in the device's group on
the host, usually `render`). A tool that drives rootless podman through its API socket cannot pass `keep-groups`. It
can pass `--annotation run.oci.keep_original_groups=1` instead. With docker and `--user`, add `--group-add` with the
device's group as a number (`stat -c %g /dev/accel/accel0`).

**The C++ runtime.** The host's XRT libraries run inside the image, so they must not need a newer C library or C++
runtime than the image carries (the image is Debian 13: glibc 2.41, `GLIBCXX_3.4.33`). Ubuntu 26.04's XRT and AMD's
XRT 2.25 both load. If yours does not, the server says so at start and names the library.
