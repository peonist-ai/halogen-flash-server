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
- **Your own LiquidAI LFM3 models** (see [Your own LFM3-1.7B](#your-own-lfm3-17b), [LFM3-VL-2B](#your-own-lfm3-vl-2b),
  [LFM3-Audio-2B](#your-own-lfm3-audio-2b) and [LFM3-Omni-2B](#your-own-lfm3-omni-2b)): chat, pictures, video, speech in
  and speech out, from checkpoints you supply.
- **Document parsing with your own OvisOCR3** (see [Your own OvisOCR3](#your-own-ovisocr3)): a page to Markdown with
  HTML tables and LaTeX formulas, in one call, from a checkpoint you supply.

Larger sizes of the first three are named the same way (see [Larger sizes](#larger-sizes)). Your own fine-tune of any of the first four runs too. See [Your own model](#your-own-model).

## What the host needs

- The NPU driver, the NPU firmware, and the IOMMU on. See [the host](#host). The image carries XRT.
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

The Quickstart's command, with the NPU added (the device and the models):

```bash
podman run --rm -p 8731:8731 \
  --device /dev/kfd --device /dev/dri --device /dev/accel/accel0 --group-add keep-groups \
  --ipc=host --ulimit memlock=-1:-1 \
  -e HALOGEN_DOWNLOAD=peonist-ai/halogen-qwen3.8-flash-next \
  -e HALOGEN_NPU_MODELS=decider-0.8b,qwen3-embedding-0.6b,qwen3-reranker-0.6b,qwen3guard-gen-0.6b,qwen3.5-2b \
  -v ~/halogen-models:/models \
  ghcr.io/peonist-ai/halogen-flash-server:0.20.2
```

`HALOGEN_DOWNLOAD` fetches the files of the NPU models that `HALOGEN_NPU_MODELS` names, into `/models/npu`, and the
server checks each one's size and checksum. A model you leave out of the list is not fetched. The five names above are
the folder names, and the guard and the reranker share the embedder's device files. Leave
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
| `halogen-spotter-0.6b` | [peonist-ai/halogen-spotter-0.6b](https://huggingface.co/peonist-ai/halogen-spotter-0.6b): reads tool results for [the agent guard](agent-guard.md), a preview |
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

One question to `decider-0.8b` takes, by the prompt's length (its template included):

| prompt | 69 tokens | 965 tokens | 1,989 tokens | 4,037 tokens | 8,133 tokens |
|---|---|---|---|---|---|
| time | 45 ms | 142 ms | 296 ms | 580 ms | 1,207 ms |

The request's wall (HTTP included), served alone, the median of 48 requests on two Strix Halo machines (0.18.22).

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

- `instructions` is the question, and `state` is the text it is about. Both are optional in this contract, so without them the
  answer reads only the options: send them. Any other key, on a question or on the request, is refused with a 422 (since 0.18.24).
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
| a question, 128-token prompt | 46 ms | 72 ms |
| at 1,024 tokens | 145 ms | 264 ms |
| at 2,048 tokens | 300 ms | 514 ms |
| at 4,096 tokens | 611 ms | 1,047 ms |
| at 8,192 tokens | 1,337 ms | 2,173 ms |
| a question with a picture, 256 x 256 / 768 x 768 | ~200 ms / ~500 ms | ~350 ms / ~900 ms |

One question a request, served alone, the request's wall (HTTP included), with one of the two loaded. A prompt's length
counts the model's own template. The text rows are the median of 48 requests on two Strix Halo machines (0.18.22); the
picture row is from one (0.18.11). Loaded together the two share the NPU's memory, and `d3-nano`'s questions about pictures
take 15 to 25% longer.

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

A text of 100 tokens takes 52 ms and one of 400 tokens 89 ms; eight texts of 100 tokens in one request 182 ms, of 400
tokens 687 ms (served alone, the request's wall, the median of 20 on two Strix Halo machines, 0.18.22).

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

While a reply is being generated, a request to another NPU model (a decision, an embedding, a rerank or a moderation, of
any length) runs between two of its tokens instead of waiting for the whole reply. Under a heavy mix of NPU requests the
reply keeps about a third of the NPU and takes longer in turn. Another generation, a d1-2B question, a speech, an image or a
transcription waits until the reply in progress is done.

| prompt | 1,016 tokens | 2,040 tokens | 4,088 tokens | 8,184 tokens | 15,992 tokens |
|---|---|---|---|---|---|
| first token | 333 ms | 1,074 ms | 1,099 ms | 4,342 ms | 4,449 ms |
| decoding | 39.2 tokens a second | 39.2 | 39.2 | 39.1 | 39.0 |

One request alone, greedy, the prompt's length counting its chat template; the first token is the request's wall (HTTP
included) with `max_tokens` 1, and decoding is a 129-token reply's further tokens over its further time. The prompt is read
in steps, so 2,040 tokens take about as long as 4,088. The median of four runs on two Strix Halo machines (0.18.22).

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

A 512x512 image takes 3,221 ms and a 1024x1024 image 9,681 ms (served alone, the median of 20 on two Strix Halo machines, 0.18.22). A 1024x1024 image uses about 0.7 GB of working
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

An edit takes about 5,000 ms with one picture, 7,500 with two, 10,000 with three and 12,500 with four, and about
12,500 ms at 1024x1024.

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
than real time and the 1.7B a little faster than real time, with the first audio in about 300 and 400 ms. One
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
- a LiquidAI LFM3-1.7B checkpoint or fine-tune answers chat completions (see [Your own LFM3-1.7B](#your-own-lfm3-17b)).
- a LiquidAI d1-2B checkpoint answers decisions over text, pictures and video (see [Your own d1-2B](#your-own-d1-2b)).
- a LiquidAI LFM3-VL-2B checkpoint or fine-tune answers chat with pictures and video (see [Your own LFM3-VL-2B](#your-own-lfm3-vl-2b)).
- a LiquidAI LFM3-Audio-2B checkpoint or fine-tune answers speech in and speech out (see [Your own LFM3-Audio-2B](#your-own-lfm3-audio-2b)).
- a LiquidAI LFM3-Omni-2B checkpoint answers every medium on one model (see [Your own LFM3-Omni-2B](#your-own-lfm3-omni-2b)).
- an OvisOCR3 checkpoint parses document pages into Markdown (see [Your own OvisOCR3](#your-own-ovisocr3)).

It runs on the NPU program of the model it was tuned from, so that program is fetched too under `HALOGEN_DOWNLOAD`
(the program only, not that model's weights). Anything else is refused at start with a line that says what it found
and what runs: another size or architecture, or a LoRA adapter on its own (merge it into the model first). A read-only
volume works, but then the conversion runs at every start.

## Your own LFM3-1.7B

The NPU runs a LiquidAI LFM3-1.7B checkpoint you supply: LFM3-1.7B itself, LFM3-1.7B-Base, or a fine-tune of either.
Put it on the models volume as it was saved (a directory with `config.json`, `model.safetensors` and `tokenizer.json`)
and name its path, once for each format you want:

```
-e HALOGEN_NPU_MODELS=/models/LFM3-1.7B,/models/LFM3-1.7B:fast
```

`/models/LFM3-1.7B` runs at full quality (8-bit) and is served as `LFM3-1.7B`; `/models/LFM3-1.7B:fast` runs a
5-bit format of the same checkpoint, faster with a small quality cost, served as `LFM3-1.7B-fast`. At the first start
the server converts the checkpoint (about a minute for both) and keeps the result beside it (`halogen-npu.hnpw` and
`halogen-npu-fast.hnpw`, each with a small `.stamp` file). Later starts check the checkpoint in a few seconds and skip
the conversion; a changed checkpoint, or an update of the server, converts it again. The NPU programs are fetched under
`HALOGEN_DOWNLOAD` (the programs only; no LFM3 weights are downloaded or shipped). A read-only volume works, but then
the conversion runs at every start.

```
curl -s localhost:8731/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "LFM3-1.7B-fast",
  "messages": [{"role": "user", "content": "What is the weather in Lisbon?"}],
  "tools": [{"type": "function", "function": {"name": "get_weather", "parameters": {"type": "object",
    "properties": {"city": {"type": "string"}}, "required": ["city"]}}}]}'
```

Chat completions follow OpenAI's format, streamed or not, with tool calls; a base checkpoint takes raw text on
`/v1/completions`. A prompt may be as long as the model's 262,144-token context (since 0.18.24; before it, about 220,000), and
near that length it reads for about 8 minutes and takes about 20 GiB of host memory at its peak. On a short prompt it decodes about
27 tokens a second at full quality and 38 with `:fast` (about 22 and 28 at 32k tokens, 18 and 20 at 130k), and reads
a prompt at about 3,700 tokens a second. It shares the NPU with the other NPU models as `qwen3.5-2b` does (a request
to another model runs between two of its tokens). The weights stay yours, under their own license (LFM Open License v1.0).

| Prompt or context | Prefill, `LFM3-1.7B` | Prefill, `LFM3-1.7B-fast` | Decode, `LFM3-1.7B` | Decode, `LFM3-1.7B-fast` |
|---|---|---|---|---|
| 1,024 tokens | 3,750 | 3,677 | 27.3 | 38.3 |
| 32,768 tokens | 2,177 | 2,174 | 22.4 | 27.9 |
| 130,000 tokens | 974 | 973 | 17.6 | 19.7 |

Tokens a second, one request alone, greedy decoding. Prefill includes handing the prompt to the decode program.

Naming `lfm3-1.7b` alone is refused: there is no LFM3 checkpoint in the image, only the programs that run yours.

## Your own d1-2B

The NPU runs a LiquidAI d1-2B checkpoint you supply: one-pass decisions over text, pictures and video. Put it on the models
volume as it was saved (`config.json`, `model.safetensors`, `tokenizer.json`, `calibration.json`) and name its path:

```
-e HALOGEN_NPU_MODELS=/models/d1-2B
```

It is served as `d1-2B` on `POST /v1/systemone`, in d1-2B's own form: a `state` (text, a JSON value, or none), named
`questions`, and `media`, a list of pictures and videos that head the state. The server converts the checkpoint at the
first start and keeps the result beside it, as for LFM3-1.7B, and fetches the NPU programs under `HALOGEN_DOWNLOAD`
(the programs only; no d1-2B weights are downloaded or shipped).

```bash
curl -s localhost:8731/v1/systemone -H 'content-type: application/json' -d @- <<EOF
{"model": "d1-2B", "state": null,
 "media": ["data:image/jpeg;base64,$(base64 < cats.jpg | tr -d '\n')"],
 "questions": {
   "cats": {"type": "number", "instructions": "How many cats are there?", "range": [0, 10], "step": 1},
   "remote": {"type": "box", "instructions": "Where is the remote control on the left?"},
   "every_cat": {"type": "boxes", "instructions": "Every cat.", "max": 4}}}
EOF
```

- Questions: `noul`, `choice` (and `multiple`), `score`, `text` / `number` / `date` read from a text state, `number` with a
  `range` (an estimate), and on a picture `box` (one object's top, bottom, left and right as fractions of the picture) and
  `boxes` (every instance, up to 16 or `max`). Up to 16 questions are answered in one pass; the answers have d1-2B's shapes.
- A picture is a `data:` URL, plain base64, or `{"url": ...}` / `{"image_url": {"url": ...}}` holding one (`images` also
  takes pictures). One larger than 1.6 megapixels is scaled down, as d1-2B scales it.
- A video is `{"type": "video", "frames": [pictures], "fps": 24}`: its frames and their rate. The server keeps two frames a
  second, as d1-2B does. A request fits 2,048 tokens, so a long or large clip's frames are scaled down to fit.

A question about a picture takes about 350 ms, the picture's reading included; a box and an every-instance question
about a 640 x 480 photo about 800 ms together; three questions about a few seconds of video about 400 ms. A question on
text alone takes about 70 ms up to 256 tokens of state and questions.

Naming `d1-2b` alone is refused: there is no d1-2B checkpoint in the image, only the programs that run yours. The weights
stay yours, under their own license (LFM Open License v1.0).

## Your own LFM3-VL-2B

The NPU runs a LiquidAI LFM3-VL-2B checkpoint you supply (LFM3-VL-2B itself or a fine-tune of it): chat with pictures and
video, on the same terms as LFM3-1.7B. Put it on the models volume as it was saved and name its path, once for each
format you want:

```
-e HALOGEN_NPU_MODELS=/models/LFM3-VL-2B,/models/LFM3-VL-2B:fast
```

`/models/LFM3-VL-2B` runs the text model at full quality (8-bit) and is served as `LFM3-VL-2B`; `/models/LFM3-VL-2B:fast`
runs a 5-bit text model with the same picture encoder, served as `LFM3-VL-2B-fast`. The first start converts the checkpoint
(about 40 seconds for both) and keeps the result beside it; later starts check it in a few seconds. The NPU programs are
fetched under `HALOGEN_DOWNLOAD` (the programs only; no weights are downloaded or shipped).

```
curl -s localhost:8731/v1/chat/completions -H 'Content-Type: application/json' -d @- <<EOF
{"model": "LFM3-VL-2B",
 "messages": [{"role": "user", "content": [
   {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,$(base64 < photo.jpg | tr -d '\n')"}},
   {"type": "text", "text": "What is written on the sign?"}]}]}
EOF
```

It answers on `/v1/chat/completions`, `/v1/messages` and `/v1/responses`, streamed or not: pictures as `image_url` parts,
Anthropic `image` blocks (base64, or a `url` block holding a `data:` URL) or `input_image` items, and video as
`{"type": "video", "frames": [...], "fps": 2}` on chat completions. Tool calls work on all three, `tool_choice` included
(a named tool or any tool), and a tool result may hold pictures, so an agent can send a screenshot after each action. The
server does not fetch `http(s)` image URLs: send the picture's bytes.

A picture is read at up to 4 megapixels (larger ones are scaled down to that). A picture sent again in a later turn is not
read again, and in a long conversation (past about 4,000 tokens) the part a later turn shares with an earlier one is not
read again either, so an agent's next turn starts from where the last one left off (its `usage` reports those tokens as
cached). On a quiet host: a 640 x 480 picture with a short answer in about 1,300 ms, a 1920 x 1080 screenshot in about
1,400 ms of picture reading plus the prompt, a 4 MP picture in about 2,800 ms plus the prompt; it decodes about 27 tokens a second at
full quality and about 39 with `:fast`. A picture the model has seen before (the same bytes) starts to answer in about 200
to 400 ms at 1280 x 720 and below.

If you run LFM3-VL-2B, it also answers text-only chat, so you do not need LFM3-1.7B beside it.

Its quality through the server matches the model's own code: the same questions, greedy, thinking off, against the model's
own run (the difference is the server's score minus the model's, with a 95% interval):

| benchmark | the server | the model's own | difference |
|---|---|---|---|
| MMStar (1,500) | 58.47% | 58.40% | +0.07 [-1.00, +1.13] |
| RealWorldQA (765) | 72.94% | 73.07% | -0.13 [-1.44, +1.18] |
| OCRBench (1,000) | 81.9% | 81.9% | 0.00 [-0.50, +0.60] |

`:fast` reads 58.53%, 72.55% and 81.2% on the same questions (+0.13, -0.52 and -0.70 from the model's own, every interval
within 3 points). The weights stay yours, under their own license (LFM Open License v1.0).

LFM3-VL-2B keeps about 3.7 GB more of the host's memory locked than LFM3-1.7B alone. On a host that is short of free memory
while the Flash model runs, the kernel may compact memory now and then, and the Flash model can pause for up to about a
minute while it does. [Waiting behind a reply](#beside-an-lfm3-reply) below applies to it.

## Your own LFM3-Audio-2B

The NPU runs a LiquidAI LFM3-Audio-2B checkpoint you supply: speech in (transcription and questions about a recording) and
speech out (text to speech and spoken replies). Put the **whole model folder** on the models volume as it was saved, the
`audio_tokenizer/` folder included (speech out reads it; a folder copied without it converts, but with no speech out, and the
log says so), and name its path:

```
-e HALOGEN_NPU_MODELS=/models/LFM3-Audio-2B,/models/LFM3-Audio-2B:fast
```

Served as `LFM3-Audio-2B` (8-bit text model) and `LFM3-Audio-2B-fast` (5-bit). The first start converts the checkpoint and
keeps the result beside it, as for LFM3-1.7B; the NPU programs are fetched under `HALOGEN_DOWNLOAD` (programs only). A
converted file made by an earlier build is made once more at the first start. It also answers text-only chat.

**Speech in.** A WAV clip as an `input_audio` part on `/v1/chat/completions` or `/v1/responses` (up to 16 clips a request),
or a file to `/v1/audio/transcriptions` (`response_format` `json` or `text`, `language` optional):

```
curl -s localhost:8731/v1/audio/transcriptions -F model=LFM3-Audio-2B -F file=@talk.wav
```

Only WAV is read (other formats are refused with a message that says so), and `/v1/messages` has no audio form. A reply the
model opens with its own `<think>` block comes back as reasoning, with the answer after it as content. A 3.5-second clip is
read in about 100 ms and a 23-second one in about 140 ms; one LibriSpeech sentence (about 7 seconds, a 28-token reply)
takes about 1,400 ms in all, most of it the reply's tokens. Against the model's own code, through the server:

| benchmark | the server | the model's own | difference |
|---|---|---|---|
| LibriSpeech test-clean, word error rate (2,620 clips) | 2.967% | 2.946% | +0.02 [-0.03, +0.07] |
| MMAR, accuracy (1,000 questions) | 50.9% | 50.5% | +0.40 [-0.40, +1.30] |

`:fast`: 2.939% (-0.01 [-0.07, +0.05]) and 49.7% (-0.80 [-1.80, +0.20]).

**Speech out.** Text to speech on `/v1/audio/speech`:

```
curl -s localhost:8731/v1/audio/speech -H 'Content-Type: application/json' \
  -d '{"model": "LFM3-Audio-2B", "input": "Good morning.", "voice": "female", "language": "en-GB"}' -o hello.wav
```

`voice` is `female` or `male` (OpenAI's voice names map to them), `language` one of 19 locales by name or code (American
English by default; Arabic, Danish, German, Greek, British English, Finnish, French, Hebrew, Italian, Japanese, Korean, Dutch,
Polish, Portuguese, Spanish, Swedish, Turkish and Chinese are the others), `seed` fixes the draw. `response_format` is `wav`
(the default) or `pcm` (24 kHz, 16-bit, mono), and `"stream": true` with `pcm` sends the audio as it is made. A reply is up
to about 5 minutes of speech. `instructions` and a `speed` other than 1 are refused. A chat completion with
`"modalities": ["text", "audio"]` and `"audio": {"voice": "female", "format": "wav"}` answers in speech: the audio and its
transcript are in `message.audio` (`"format": "pcm16"` streams on a streamed request). `/v1/messages` and `/v1/responses` do
not make speech.

It speaks at about 0.54 of real time on the 8-bit form and 0.41 with `:fast` (a second of speech takes that fraction of a
second to make), and the first audio arrives after about 130 ms (120 ms with `:fast`). Against the model's own code, scored with the same
recognizer and quality model on both sides:

| test | the server | the model's own | difference |
|---|---|---|---|
| text to speech, word error rate (240 sentences x 5 seeds) | 1.823 | 1.866 | -0.04 [-0.22, +0.12] |
| text to speech, quality score | 3.847 | 3.857 | -0.010 [-0.027, +0.007] |
| voice chat, word error rate (100 questions x 3 seeds) | 1.307 | 1.139 | +0.17 [-0.28, +0.64] |
| voice chat, quality score | (difference only) | | +0.010 [-0.039, +0.057] |

(Word error rate is of the recognizer's transcript of the speech, lower is better; the quality score is higher-is-better.)
The weights stay yours, under their own license (LFM Open License v1.0).

## Your own LFM3-Omni-2B

The NPU runs a LiquidAI LFM3-Omni-2B checkpoint you supply: pictures, video, a video with its soundtrack, speech clips in,
and text, spoken or mixed replies out, on one model id. Put the whole model folder on the models volume (`audio_tokenizer/`
included) and name its path:

```
-e HALOGEN_NPU_MODELS=/models/LFM3-Omni-2B,/models/LFM3-Omni-2B:fast
```

Served as `LFM3-Omni-2B` and `LFM3-Omni-2B-fast`. It uses no programs of its own: the picture and speech encoders and the text
model are the ones for LFM3-VL-2B, LFM3-Audio-2B and LFM3-1.7B, fetched under `HALOGEN_DOWNLOAD`. Everything is on chat
completions as for the two models above (pictures as `image_url`, speech in as `input_audio`, speech out with `modalities` or
on `/v1/audio/speech`); a video is `{"type": "video", "frames": [...], "fps": 2}`, and its soundtrack goes in the item's
`audio` field as a WAV. A picture is read at up to 2 megapixels and a video holds 4 to 384 frames. Thinking is off by default.
Its speech is made with Omni's own sampling settings.

It starts to answer a 448 x 320 picture in about 240 ms, an 8-frame video in 600 ms, the same video with a 3.5-second
soundtrack in 680 ms, a 3.5-second clip in 200 ms, a 2-minute recording in 1,040 ms, and a prompt with a picture, a video,
a soundtrack and a clip together in 1,080 ms. Its speech runs at about 0.54 of real time on the 8-bit form and 0.41 with `:fast` (first audio about 130 ms). Against the
model's own code, through the server:

| benchmark | the server | the model's own | difference |
|---|---|---|---|
| MMStar (1,500) | 58.33% | 58.93% | -0.60 [-1.93, +0.73] |
| RealWorldQA (765) | 65.23% | 65.23% | +0.00 [-0.92, +0.92] |
| OCRBench (1,000) | 81.3% | 80.9% | +0.40 [-0.50, +1.30] |
| MVBench (1,397 video questions) | 61.27% | 60.63% | +0.64 [-0.86, +2.15] |
| Daily-Omni (1,197 videos with sound) | 62.07% | 62.07% | +0.00 [-0.84, +0.75] |
| LibriSpeech test-clean, word error rate (2,620) | 3.152% | 3.110% | +0.042 [+0.004, +0.081] |
| MMAR (1,000) | 53.1% | 53.3% | -0.20 [-1.10, +0.70] |
| text to speech, word error rate | 1.784 | 1.894 | -0.109 [-0.31, +0.06] |
| voice chat, word error rate | 0.842 | 1.106 | -0.264 [-0.92, +0.28] |

The weights stay yours, under their own license (LFM Open License v1.0).

## Your own OvisOCR3

The NPU runs an OvisOCR3 checkpoint you supply (`ATH-MaaS/OvisOCR3`): document parsing in one call a page, no
separate layout model. It returns the page as Markdown, tables as HTML and formulas as LaTeX, with each element's
category and box when the prompt asks for them. Put the checkpoint on the models volume as it was saved and name its path:

```
-e HALOGEN_NPU_MODELS=/models/OvisOCR3
```

It is served as `OvisOCR3` on `/v1/chat/completions`, `/v1/messages` and `/v1/responses`, streamed or not. The first
start converts the checkpoint (about 30 seconds) and keeps the result beside it; the NPU programs are fetched under
`HALOGEN_DOWNLOAD` (the programs only; no weights are downloaded or shipped).

```
curl -s localhost:8731/v1/chat/completions -H 'Content-Type: application/json' -d @- <<EOF
{"model": "OvisOCR3",
 "messages": [{"role": "user", "content": [
   {"type": "image_url", "image_url": {"url": "data:image/png;base64,$(base64 < page.png | tr -d '\n')"}},
   {"type": "text", "text": "Convert this page to Markdown."}]}]}
EOF
```

- One or two pictures a request (`image_url` parts), up to 178,956,970 pixels each, scaled into the model's own range
  (448 x 448 to 2880 x 2880 pixels' worth) as its processor scales them. Text and pictures only: video and audio parts
  are refused with a message naming what is taken.
- Use the prompts on the model's card for each task (full-page parsing, tables, formulas, key information, captions).
  Thinking is off unless the request asks for it; the reply is greedy, as the card runs it.
- With no `max_tokens` a reply may run to 16,384 tokens, the card's limit (or `HALOGEN_MAX_TOKENS_DEFAULT` when you set
  one). A dense page can need 9,000 or more.

An A4 page starts to answer in about 3.4 seconds and a typical page takes about 20 seconds; the reply runs at about
43 tokens a second. Beside other NPU models, a page's picture reading and prompt run without other requests slipped in
between them, so a short request that arrives then waits a few seconds; it runs between the page's reply tokens as usual.
With several generation models loaded beside it, the NPU driver can refuse one of its allocations about once a run; the
server makes room and retries, and no request fails. Two runs of the same page can differ at a near tie (a character, or
one box coordinate by one), on about one page in a hundred on some hosts. When OvisOCR3 and several other generation
models start work at once beside Flash, Flash's first request after that can wait about 40 seconds while the host reads
Flash's weights back into memory; later requests run at their usual speed. `HALOGEN_WEIGHTS_LOCK=1` keeps the weights
resident (see [Host setup](host-setup.md)).
Against the model's own code, through the server:

| benchmark | the server | the model's own | difference |
|---|---|---|---|
| OmniDocBench v1.6, 320 pages, text (1 - edit distance) | 81.99 | 82.10 | -0.11 [-0.71, +0.43] |
| OmniDocBench v1.6, the 90 pages with tables, TEDS | 92.35 | 91.87 | +0.48 [-0.23, +1.74] |
| OCRBench (1,000) | 85.7% | 85.3% | +0.40 [0.00, +0.90] |

The two OmniDocBench scores are page-level scores computed the same way for both sides, not the official pipeline's
numbers. Naming `ovisocr3` alone is refused: there is no OvisOCR3 checkpoint in the image, only the programs that run
yours. The weights stay yours, under their own license (Apache 2.0).

## Batching

When one request carries several short inputs (embedding texts, rerank documents, or moderation inputs), they run
together in one pass.
Each result is exactly what it would be alone. `HALOGEN_NPU_EMB_BATCH=0` turns this off.

A batch holds up to 8 inputs of up to 512 tokens each, padded to the bucket, so 8 inputs of 100 tokens cost the same as 8
of 400: 353 and 356 ms with `qwen3-embedding-0.6b` (349 and 355 ms with the reranker, 351 ms for 8 moderation inputs). A
single input takes 47 ms at 100 tokens and 63 ms at 400. Served alone, the request's wall, the median of 20 on two Strix
Halo machines (0.18.22). The server batches a group from 6 inputs of up to 128 tokens, and from 5 of up to 512.
Smaller groups, and the leftover of a larger request, run one pass each.

## Many requests at once

The NPU runs one pass at a time. A request takes one pass per input, or one per batch of short inputs. Up to
`HALOGEN_NPU_QUEUE` passes (64) wait on the NPU. Passes past that wait in the server, so a burst, such as a whole
knowledge base sent for embedding at once, is answered more slowly, not refused. A request that cannot start within
`HALOGEN_QUEUE_TIMEOUT` gets `503` with the code `engine_busy` and a `Retry-After` header. Raising `HALOGEN_NPU_QUEUE`
changes no result.

### Beside an LFM3 reply

The NPU generates one LFM3 reply at a time. While LFM3-1.7B, LFM3-VL-2B, LFM3-Audio-2B or LFM3-Omni-2B is writing a reply,
a request that needs a picture, a video or speech (in or out) waits until that reply is done, and the other way round; in a
test with all of them busy at once the median wait was one to two minutes. Decisions, embeddings, reranks and moderations
still run between two of its tokens. A d1-2B question joins the reply in progress instead of waiting for it: beside an LFM3
reply a d1-2B question that took 14 to 28 seconds now takes about 500 to 1,200 ms, at the cost of a decision request
queuing a little longer beside a continuous stream of d1-2B questions. Any short NPU job that hosts other short requests
(d1-2B, for example) now runs on a generation's credit: d1-2B beside a busy embedder answers in 1 to 3 seconds instead of 13
to 21, and the embedder runs at about 0.65 of its speed while a long NPU job runs.

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
- LFM3-Audio-2B and LFM3-Omni-2B read WAV clips only. A speech-out reply is at most about 5 minutes of speech; a TTS input is
  limited in characters and a longer one is refused with a 400 that names the limit.
- With several large NPU models loaded (a speech model, `embeddinggemma-2`, `wemm-embedding-4b`, images above
  512x512, `d3-lite` and `d3-nano` together), they take turns at the NPU's memory. Alternating them is slower, and a request that cannot fit answers 503.
- The NPU models are served in the default mode only, not in the two-container setup (`engine` and `api`).

<a id="host"></a>
## The host

- **The NPU driver, `amdxdna`.** Recent kernels carry it. Otherwise, install AMD's xdna-driver package. We test the
  kernel's own driver on Ubuntu 26.04 (kernel 7.0), and AMD's driver 2.25 on kernel 6.17.
- **XRT is in the image.** It carries XRT 2.25.37 with its NPU plugin, built from AMD's source, so you do not need to
  install or mount XRT. We run it on both of the drivers above. To use your host's instead, see [below](#host-xrt).
- **The NPU firmware.** The driver package or `linux-firmware` installs it.
- **The IOMMU on.** The NPU driver needs it. `amd_iommu=off`, which the README measures for GPU prefill, turns the NPU
  off. `iommu=pt` keeps it.

**A known bad pairing: AMD's DKMS driver 2.23 with its XRT 2.23.** On it the NPU can stop every few hundred passes
(`aie2_tdr_work: Device isn't making progress` in `dmesg`, and `command state 8` in the request's error). On the same
host, the kernel's own driver with Ubuntu 26.04's XRT ran the same load clean. Use that, or AMD's 2.25. After such a
fault the server starts the NPU engine again by itself, up to `HALOGEN_NPU_RESTARTS` times (3), while the Flash model
keeps serving. If the host is under `HALOGEN_NPU_HOST_FLOOR_GIB` at that moment, that does not count as a try: the server
tries again every 30 seconds to 5 minutes until there is room.

<a id="host-xrt"></a>
**Using your host's XRT.** You rarely need this: mount it when the server says your NPU driver refused the image's XRT.
It needs XRT 2.20 or newer with its NPU plugin. XRT 2.19 and older cannot read the server's NPU programs, and the NPU
engine then stops at start and names your XRT's version. Mounted, it replaces the image's three libraries,
`libxrt_coreutil.so.2`, `libxrt_core.so.2` and the NPU plugin `libxrt_driver_xdna.so.2`. Mount all three or none. AMD's
packages put XRT in `/opt/xilinx/xrt`, so add `-v /opt/xilinx/xrt:/opt/xilinx/xrt:ro`. A distribution's packages put it
in the system library directory
(`/usr/lib/x86_64-linux-gnu` on Ubuntu, `/usr/lib` on Arch and CachyOS, whose packages are `xrt` and
`xrt-plugin-amdxdna`). Those libraries look for each other at that path, so mount each one twice: once where the image
looks for XRT, and once at its own path, with `L=/usr/lib` on Arch and CachyOS:

```
L=/usr/lib/x86_64-linux-gnu; X=""
for f in libxrt_coreutil.so.2 libxrt_core.so.2 libxrt_driver_xdna.so.2; do
  X="$X -v $(readlink -f "$L/$f"):/opt/xilinx/xrt/lib/${f}:ro -v $(readlink -f "$L/$f"):$L/${f}:ro"
done
# then: podman run ... $X ...
```

XRT 2.25 and newer find their parts relative to where they are loaded from, so on Debian and Ubuntu mount the three files at
`/opt/xilinx/xrt/lib/` and at `/opt/xilinx/lib/x86_64-linux-gnu/` instead. If the path is wrong, the server names the one
it looked for.

Do not mount an `/opt/xilinx/xrt` that holds only links into the system library directory. Inside the container those
links point at nothing. The server names such a link at start and prints the mounts to use.

**The device flags.** `--device /dev/accel/accel0` passes the NPU in. `--ulimit memlock=-1:-1` lets the NPU engine lock
the memory the NPU reads. With podman, `--group-add keep-groups` covers it (your user must be in the device's group on
the host, usually `render`). A tool that drives rootless podman through its API socket cannot pass `keep-groups`. It
can pass `--annotation run.oci.keep_original_groups=1` instead. With docker and `--user`, add `--group-add` with the
device's group as a number (`stat -c %g /dev/accel/accel0`).

**The C++ runtime.** A host's XRT libraries run inside the image, so they must not need a newer C library or C++
runtime than the image carries (the image is Debian 13: glibc 2.41, `GLIBCXX_3.4.33`). Ubuntu 26.04's XRT and AMD's
XRT 2.25 both load. If yours does not, the server says so at start and names the library.
