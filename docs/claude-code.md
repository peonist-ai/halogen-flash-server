# Claude Code and the Anthropic Messages API

The server also speaks the **Anthropic Messages API** at
`POST /v1/messages`, with `POST /v1/messages/count_tokens` beside it, so
Claude Code and the `anthropic` SDKs can use it directly:

```bash
export ANTHROPIC_BASE_URL=http://<your-server>:8731
export ANTHROPIC_API_KEY=anything
export CLAUDE_CODE_MAX_OUTPUT_TOKENS=32000
claude
```

With no `HALOGEN_API_KEY` set the server accepts any key, and it answers any model name Claude Code sends; replies name the
model that served them. Claude Code asks for its model's full output limit on
every request, more than this server's cap (`max_tokens_cap` in `/health`,
65,536 by default). Since 0.18.1 `/v1/messages` runs such a request with the
cap and says so once in the log; the third line above keeps it below the cap
and leaves room in the KV pool for other requests. It was built from what Claude Code actually sends:
streamed replies with `thinking`, `text` and `tool_use` blocks, tool
results, a system prompt in text blocks, and `system` turns inside
`messages`, which become user text. `thinking` (enabled, adaptive or
disabled, and `budget_tokens` as the thinking budget), `output_config.effort`
(as `reasoning_effort`), `output_config.format` (a JSON schema, as
structured output), `tool_choice` and `stop_sequences` are read. Images
work with the vision tower on. Errors come back in the Messages error
shape, and `GET /v1/models` carries the Messages API's model fields too.

**Thinking round trips.** A thinking block's `signature` carries the
reasoning itself. A client that sends the block back, as Claude Code does on
every tool turn, replays exactly what the model wrote, even with
`display: "omitted"`, where the block's text is empty. The next prompt then
starts with the last one, and the prompt cache resumes it.

**`cache_control`.** The prompt cache needs no marks. A request's last
`cache_control` mark inside `messages` is used as one more resume point, so
a later request that shares the conversation up to the mark resumes from
it. `usage.cache_read_input_tokens` says how much of the prompt came from
the cache, and `input_tokens` counts the rest.

**Tools that change mid-session.** Claude Code announces a tool added or removed during a session as a system message carrying the
tool's definition. The server accepts it: an added tool is available from that point of the conversation, a call to it comes back
as an ordinary tool call, and the start of the prompt is unchanged, so the prompt cache keeps hitting.

**Not served.** Anthropic's server-side tools, such as web search and code
execution, are dropped with a log line, and your own tools are used. A PDF
document block is a 400. The Batches and Files APIs are not there. Fields the server
does not use, such as `context_management`, are accepted and named once in
the log.

Verified against Claude Code running tool round trips end to end, and
separately against the official `anthropic` Python SDK.

---

---

## History

| shipped | what arrived |
|---|---|
| 0.15.1 | the Messages API and `count_tokens` |
