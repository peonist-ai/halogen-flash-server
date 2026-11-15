# Sessions: keep, fork and join

A harness that runs several branches from one conversation can ask the server to keep that conversation's state under a name and start new requests from it. Named keeps are on by default. Set `HALOGEN_FORK=0` to turn them off; then no header is read and `/halogen/handles` does not exist.

    # keep the state where this reply ends, under the name plan-7f3a
    curl -s localhost:8731/v1/chat/completions -H 'X-Halogen-Keep: plan-7f3a' -d '{"messages": [...]}'
    # three workers start from it at once, each sending the history, the reply and its own message
    curl -s localhost:8731/v1/chat/completions -H 'X-Halogen-From: plan-7f3a' -d '{"messages": [..., "do part A"]}'
    # join: continue from one name and keep the result under another
    curl -s localhost:8731/v1/chat/completions -H 'X-Halogen-From: plan-7f3a' -H 'X-Halogen-Keep: plan-7f3b' -d '{...}'

Every request is an ordinary request, and a server with `HALOGEN_FORK=0` answers it the same way. The response header `X-Halogen-From` says `used`, `unmatched` (the history does not repeat the kept one) or `unknown`, and the last two are answered as usual. A request that names the same handle in From and Keep but cannot start from it releases that handle and runs as an ordinary request; it does not wait for the handle's idle timer. To branch from inside a reply, send part of it as the last assistant message (`continue_final_message` on Chat Completions, a final assistant message on Messages and Responses). The same headers work on `/v1/messages` and `/v1/responses`, for harnesses that can set request headers. Names are released after 10 minutes unused, at most 8 live at once (`HALOGEN_FORK_TTL_S`, `HALOGEN_FORK_HANDLES`), and `GET /halogen/handles` lists them. Kept states also stop at `HALOGEN_FORK_GIB` of host memory (default 2) and half of the KV pool; past a limit the request is answered as usual and nothing is kept. With `HALOGEN_CACHE_DIR` set they survive a restart. **Every client of the server shares one set of names.** Keep the port private or set `HALOGEN_API_KEY`, and use names other clients cannot guess.

**Claude Code.** Claude Code cannot send these headers, but it names its own threads on every request. With `HALOGEN_FORK=1` and `HALOGEN_FORK_MAP=claude-code`, the server keeps each thread's state (the main conversation and each subagent) under a name of its own and starts that thread's next request from it, with nothing to set in Claude Code. A subagent's first request starts from its parent's state when it repeats it. Each name is made from the session, the thread and the API key, so it cannot be guessed and two keys never share one. A side request on a session (a title, a summary) never replaces the conversation's state. Off by default.
