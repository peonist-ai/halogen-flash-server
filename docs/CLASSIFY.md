# Using halogen as a classifier

The model can sort text into a fixed set of labels in one forward pass. You
end the prompt exactly where the label goes, and the server returns the
probability the model gives each candidate for that one token. Nothing is
generated past it and there is no free text to parse. It works through the
normal chat endpoint with any OpenAI client, since 0.13.8.

Good fits are triage and routing (which queue, which tool, which team), yes/no
checks, moderation, and asking several questions about one document. The label
is scored before the model has a chance to reason, so a judgment that needs
thought is better served by a normal request with thinking on and a
structured answer (`response_format`, see [Using it](../README.md#using-it)).

## The request

```bash
curl -s http://localhost:8731/v1/chat/completions \
  -H 'Content-Type: application/json' -d '{
  "model": "halogen-qwen3.8-flash-next",
  "messages": [
    {"role": "system", "content": "Classify the support ticket. A = bug report, B = feature request, C = question. Answer with the letter only."},
    {"role": "user", "content": "The export button does nothing since the last update."},
    {"role": "assistant", "content": "{\"label\": \""}
  ],
  "continue_final_message": true,
  "add_generation_prompt": false,
  "chat_template_kwargs": {"enable_thinking": false},
  "max_tokens": 1,
  "temperature": 0,
  "logprobs": true,
  "top_logprobs": 20
}'
```

What each part does:

- **The last message is the answer, cut off where the label goes.**
  `continue_final_message: true` and `add_generation_prompt: false` tell the
  server to continue that message. Without them it opens a new assistant turn
  after it, and the first token is the start of the model's reasoning rather
  than a label.
- **Thinking off** (`chat_template_kwargs: {"enable_thinking": false}`, or
  `"reasoning_effort": "none"`). The label is scored directly.
- **`max_tokens: 1`, `temperature: 0`, `logprobs: true`, `top_logprobs: 20`.**
  One token, and the 20 most likely candidates for it with their log
  probabilities.

## Reading the answer

The candidates are in `choices[0].logprobs.content[0].top_logprobs`, most
likely first. Each entry has `token` (the text), `logprob` and `bytes`. Keep
the entries that are your labels, turn the logprobs into probabilities, and
divide by their sum:

```python
import math
from openai import OpenAI

client = OpenAI(base_url="http://localhost:8731/v1", api_key="none")

SYSTEM = ("Classify the support ticket. A = bug report, B = feature request, "
          "C = question. Answer with the letter only.")
LABELS = ["A", "B", "C"]


def classify(text):
    r = client.chat.completions.create(
        model="halogen-qwen3.8-flash-next",
        messages=[
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": text},
            {"role": "assistant", "content": '{"label": "'},
        ],
        max_tokens=1, temperature=0, logprobs=True, top_logprobs=20,
        extra_body={"continue_final_message": True,
                    "add_generation_prompt": False,
                    "chat_template_kwargs": {"enable_thinking": False}},
    )
    top = r.choices[0].logprobs.content[0].top_logprobs
    p = {t.token: math.exp(t.logprob) for t in top}
    scores = {label: p.get(label, 0.0) for label in LABELS}
    total = sum(scores.values())
    if total > 0:
        scores = {label: s / total for label, s in scores.items()}
    return scores, 1.0 - total   # the second value: probability on anything else
```

A label that is not among the 20 candidates has a probability too small to
matter. The second value is what the model gave to tokens that are none of
your labels. When it is large, the model wanted to say something else, and
the prompt or the labels need work.

## Choosing labels

- **Only the first token is scored.** Give every label a different first
  token. Letters, `yes`/`no` and short single words work. `bug` and `bugfix`
  would compete for the same token.
- **The prefix decides how a label is spelled.** After a `"` the label has no
  leading space (`A`). After `Answer:` it has one (` A`). Do not end the prefix
  with a space. The tokenizer joins a space to the word after it, so a prefix
  that ends in one leaves the model somewhere it has rarely been.
- **Check your labels once.** Send one request whose answer is obvious and read
  the `token` strings in `top_logprobs`. Or tokenize with the tokenizer from the
  weights repo (`tokenizer/tokenizer.json` in the models volume):

  ```python
  from tokenizers import Tokenizer
  tok = Tokenizer.from_file("/path/to/models/tokenizer/tokenizer.json")
  print(tok.encode('{"label": "positive', add_special_tokens=False).tokens)
  ```

  That prints `['{"', 'label', '":', 'Ġ"', 'positive']`, one token for the
  label. `Ġ` stands for a leading space. A label that comes out as two tokens
  (`bugfix` is `bug` + `fix`) is scored by its first one only.

- **Say what the labels mean** in the system message, and ask for the label
  only.

## Making it fast

The prompt cache keeps the model's state at the end of the system message.
Every request that starts with the same system message resumes from there, so
only what follows it (the item and the answer prefix) is processed.

- **Put everything that is the same for every item in the system message.**
  That means the instructions, the label definitions, any worked examples, and
  a document you want to ask several questions about. Each question then goes
  in the user message with its own answer prefix.
- **Keep the fields that shape the system prompt the same on every request.**
  Send no `tools`, and the same thinking setting each time.
- **Check that it worked.** When part of the prompt was reused, the reply's
  `usage.prompt_tokens_details.cached_tokens` says how many tokens.

## What the numbers mean

- **The probabilities are the model's own and are not calibrated.** A 0.9 does
  not mean the label is right 90% of the time. To choose a threshold, score a
  sample you already have labels for and pick the cutoff there.
- **A request that reused the cache can differ from a cold one in the last
  digits.** Compare scores with a tolerance, not for equality.

## Limits

These are refused with a 400 rather than changed silently:

- `logprobs` or `top_logprobs` with `stream: true`
- `n` above 1
- `logprobs` together with `response_format`
- `top_logprobs`, or `logprobs` at temperature 0, with `max_tokens` above 1
- `top_logprobs` above 20
