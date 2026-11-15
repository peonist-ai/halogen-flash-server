# What this release is not

- **Four conversations, not forty.** The slot count is fixed at startup
  (`HALOGEN_KV_SLOTS`, up to 64) and a request waits for a free slot and for
  room in the pool; there is no preemption and no paging. Throughput past four
  streams grows slowly. Servers started with more than 8 slots got about 10 to
  20% more combined throughput at 16 concurrent requests in 0.20.4.
- **Speculation is for up to four conversations.** With two to four
  generating, they speculate together in one forward pass while that pays.
  With five or more (`HALOGEN_KV_SLOTS` above four), every stream takes a
  batched step, and the drafter resumes when four or fewer remain.
- **No response store.** `/v1/responses` generates and streams; it does not
  keep responses, so `previous_response_id`, retrieval by id and cancellation
  by id are not available. **Cancellation is by disconnect** (since 0.10.2;
  #58). A request whose client closes the connection while its prompt is
  being read stops within about a second, and the log says how far it got
  (since 0.16.0, #122). A prompt read in full stays in the prompt cache, so a
  retry resumes from it. Since 0.18.1 a client that leaves after the reply
  has started pauses it instead: nothing more is generated, and the same
  request sent again within 20 seconds continues it
  (`HALOGEN_RETRY_GRACE_S`, `0` = stop at once, as before). After the wait,
  or at once when another request needs the slot, the paused reply is stopped
  and its slot and KV reservation are released. The server log prints a
  "client disconnected" line with the timing either way.
- **The Flash model reads images, it does not generate them.** It has no image
  output and no audio or video input. Image generation, speech-to-text and
  text-to-speech run on the NPU models, if you load them: see
  [Small models on the NPU](npu-small-models.md).
- **One GPU architecture.** The GPU engine serves Qwen3.8-Flash-Next on
  gfx1151 only; the build rejects other architectures. Small NPU models run
  beside it (see the NPU page), and Flint has its own preview image.

---
