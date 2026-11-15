# Token budgets, and why an empty answer means you ran out

**The budget covers thinking and the answer.** This model reasons before it
replies, and those tokens come out of your budget. An empty `content` with
`finish_reason: "length"` means the budget ran out inside the thinking.
Raise the budget, or think less:

```json
{
  "model": "halogen-qwen3.8-flash-next",
  "messages": [{"role": "user", "content": "..."}],
  "max_completion_tokens": 16384,
  "reasoning_effort": "low"
}
```

If a reply looks empty or cut off, read `finish_reason` first: `"stop"`
means you have the whole answer, `"length"` means you ran out of budget.

## The fields you send

| you want | send | what it does |
|---|---|---|
| a total budget | `max_completion_tokens` | also accepted: `max_output_tokens`, `max_tokens`: one field, three names, same meaning. Send one, or several that agree; two different values is a 400, never a guess. Default **8192** on chat and Responses (128 on `/v1/completions`); cap **65536** (`HALOGEN_MAX_TOKENS_CAP`). Above the cap you get a 400 rather than a silent truncation: ask for what you need and the server tells you if it is too much. `-1` asks for the most the server allows (the cap, or the room left in the context); `0` and other negative values are a 400. |
| less thinking | `"reasoning_effort": "low"` | accepted: `minimal` `low` `medium` `high` `xhigh` `max`; the model's own default is `xhigh`. Hard reasoning problems can genuinely exceed 8192 tokens: pass a larger budget, or think less. |
| no thinking | `"reasoning_effort": "none"` | the same as `chat_template_kwargs: {"enable_thinking": false}`, and `reasoning: {"effort": "none"}` on `/v1/responses`. |
| a bound on the think block | `"max_thinking_tokens": N` | if the model has not closed the block after N generated tokens, the server closes it (see *When the server closes the block*). Server default: `HALOGEN_MAX_THINKING_TOKENS`; the request wins. The total budget still covers thinking and answer. |

The chat template itself knows three effort levels, so the six names fold
onto them: `minimal` and `low` are `low`, `medium` is `medium`, and `high`,`xhigh` and `max` are `xhigh`. The startup line and `/health` report the
level the template will see. `medium` is the one step down from the default.

`max_thinking_tokens` exists because greedy decoding at 100k+ of context can
loop inside the think block and spend the whole budget there (issue #56:
32,000 tokens of reasoning and an empty answer); the model card's sampling
settings are the cure, and this bounds the damage when a client sends none.
When it fires, the server writes its closing sentence (below), and the
answer follows in the same stream, on the same state, with no second
request. Unset, nothing changes.

> [!NOTE]
> **Your harness's own field names work.** Besides the fields above, the
> chat route reads `thinking_budget_tokens`, `thinking_budget` and
> `thinking_token_budget` (the three names Pi's `compat.thinkingTokenBudgetField`
> can send), the OpenRouter `reasoning` object (`{"enabled": false}`,
> `{"effort": "low"}`, `{"max_tokens": 4096}`: hermes-agent and aider send
> it) and the Anthropic `thinking` object (`{"type": "disabled"}`,
> `{"type": "enabled", "budget_tokens": 4096}`: aider's `--thinking-tokens`
> sends it). Two names with two different values is a 400, as with the
> budget. `/health` lists them all under `supported`.

## Server defaults

`HALOGEN_MAX_TOKENS_DEFAULT` moves the default budget for every route;
`/health` reports it as `max_tokens_default` and the three names under
`token_budget_aliases`. `HALOGEN_REASONING_EFFORT` moves the effort a
request gets when it names none. The model card's advice is not to cap the
budget at all and to leave effort at `xhigh`: lower effort on multi-turn
agentic tasks "can lead to insufficient analysis, more failures, and
repeated retries." A request that sends either field still wins.

> [!TIP]
> **Why the default is 8192 and not the cap.** A request reserves its
> prompt plus its budget in the KV pool when it is admitted, so a large
> default costs concurrency: four slots at 65,536 is a whole 262,144-position
> pool before a single prompt token. 8192 finished every ordinary prompt we
> measured with room to spare; `-e HALOGEN_MAX_TOKENS_DEFAULT=16384` is the
> step that clears an ordinary agentic turn's reasoning without that cost.

## The answer room

Thinking no longer consumes the whole budget. When a request sends no
thinking budget of its own, the server closes the think block once
`max(1024, 15% of max_tokens)` tokens remain, so a capped request ends with
an answer rather than `finish_reason: "length"` and an empty `content`. A
request's own budget still wins when it is smaller, and only a request
whose thinking would have run past the line is affected; every other reply
is untouched.

This matters because agent harnesses send no thinking control to an
OpenAI-compatible server unless configured to, so the model's own `xhigh`
runs under whatever cap the harness set for the *answer*: a compaction
summary capped at 13,000 tokens that the model thinks past is a compaction
that fails, and the harness retries it.

`HALOGEN_THINKING_ANSWER_ROOM` sets the room in tokens (`0` turns the
mechanism off); `/health` reports it as `thinking_answer_room`.

## When the server closes the block, it says so

When the server closes the think block, at your `max_thinking_tokens`, at
the answer room, at the end-of-turn guard below or when the model ends its turn inside its reasoning, it writes Qwen's
closing sentence and then `<|im_end|>`; the answer follows in the same stream,
on the same state, with no second request. `HALOGEN_THINKING_BUDGET_MESSAGE`,
like llama-server's `--reasoning-budget-message`, replaces that sentence
(set and empty, the block closes with `<|im_end|>` alone). The forced tokens
count against the budget. The server refuses to
start on a message that holds a chat marker such as `<|im_end|>` or `<|im_start|>`,
or on one longer than 512 tokens.

A reply whose block the server closed carries, in
`usage.completion_tokens_details` (on `/v1/responses`,
`output_tokens_details`):

| field | meaning |
|---|---|
| `reasoning_closed_at` | the token the block was closed at |
| `reasoning_closed_by` | `"answer_room"`, `"max_thinking_tokens"`, `"end_of_turn_guard"`, or `"end_of_turn_in_reasoning"` (the model ended its turn inside its reasoning; the server closes the block and the model writes its answer) |

A reply whose block the model closed itself has neither (`reasoning_closed_*`
ride beside `reasoning_tokens`). The per-request
log line says the same (`think on, closed at 1024 by answer room`) and, on
every chat request, whether the prompt opened a think block at all
(`think on` / `think off`). Under a 2,048 budget the room is 1,024 tokens,
so a reply that reads as "about a thousand hidden tokens, then a short
answer" is this close, and the fields name it.

## The end-of-turn guard

The tokenizer has one token for `<|im_end|>`, so a model that writes or reads a
ChatML chat template in its reasoning writes the real end-of-turn token, and the reply would end right there: `finish_reason: "stop"`, no content,
no tool call (on 15-25% of one agent's turns, issue #84). The guard keeps
generation going instead:

- inside the thinking block, `<|im_end|>` is kept as text and generation goes
  on, at most 16 of them per reply; the 17th closes the block with the
  thinking budget's closing text and the model answers, so a sampled reply
  caught in a loop of markers does not spend its budget there
  (`reasoning_closed_by` then reads `end_of_turn_guard`);
- inside an open tool call it is kept up to four times a reply;
- a model that writes a complete tool call inside its thinking block and
  then ends its turn on it gets that call made, with `finish_reason:
  "tool_calls"`; its text also stays in `reasoning_content`, where it was
  streamed;
- a kept `<|im_end|>` and a quoted `<|im_start|>` appear in the text literally (they
  used to vanish, so a quoted template came back with empty spans).

`usage.completion_tokens_details` carries `end_of_turn_kept` and
`tool_call_from_reasoning` when either happened, and the log line says
`end of turn kept as text`. `HALOGEN_EOS_GUARD=0` turns the guard off. An
end-of-turn token in the answer itself still ends the reply.

> [!WARNING]
> **A document that quotes the chat markers.** A prompt is tokenized whole,
> so `<|im_end|>` or `
</think>` written in a message reaches the model as
> the real control token, as it does on vLLM. A model translating or
> summarizing such a document can copy the token and end its reply there
> (issue #115). Break each marker in the source text, for example
> `<| im_end |>`. A request with thinking off counts no reasoning tokens
> even when its reply writes `<|im_end|>`.

## The chat template is checked at startup

Every control on this page works by asking the chat template to render the
think block one way or the other, and the server renders whatever template
the tokenizer directory carries. A tokenizer mounted from another
repository can carry a template without that branch, and such a server
would silently accept `enable_thinking: false`, `reasoning_effort: "none"`
and `HALOGEN_ENABLE_THINKING=0` and render thinking anyway. The server now
renders a one-message conversation with thinking off and on at startup and
refuses to start if the two do not differ the way the controls assume,
naming the file in one sentence; `HALOGEN_TEMPLATE_UNCHECKED=1` serves it
anyway, with the same sentence as a warning. The startup line and
`/health.chat_template` say which template loaded (the path and the sha256
of its text) and whether the check passed, so a report about thinking can
start from that line. The weights repo's own `tokenizer/` passes, and the
entrypoint's fallback to it needs no mount at all.

---

## History

| shipped | what arrived |
|---|---|
| 0.8.1 | `max_thinking_tokens` |
| 0.11.0 | the answer room; harness field-name aliases |
| 0.12.2 | `reasoning_closed_at` / `reasoning_closed_by`; the startup template check |
| 0.13.4 | the end-of-turn guard |
| 0.14.2 | the kept-marker limit (16 in the thinking block) |
| 0.15.1 | `HALOGEN_THINKING_BUDGET_MESSAGE`; the `max` effort; thinking-off requests count no reasoning tokens |
| 0.20.1 | the model's own end of turn inside its reasoning is closed and answered (`end_of_turn_in_reasoning`) |

Before 0.11.0 a budget that ran out mid-thought removed the answer entirely;
the answer room is why that shape no longer happens unless you turn it off.
