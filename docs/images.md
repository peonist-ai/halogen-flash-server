# Images

The server reads images, and it is **off until you turn it on**. Point
`HALOGEN_VISION_TOWER` at the vision sidecar that ships beside the weights, or
set it to `1` to look for the file next to the checkpoint:

```
-e HALOGEN_VISION_TOWER=1
```

With no tower the image path is absent rather than disabled, so a text-only
deployment behaves exactly as it did before this release. The tower takes
about 2 GiB of RAM, which the startup's pool fit counts, and the startup log
says what pool you got (see *Check what pool you actually got* below). `/health` reports
whether images are accepted and, when they are not, why; an image sent to a
server without a tower is a 400 naming the flag.

A request may carry as many images as fit in the context; there is no fixed count. A JSON schema and strict tools apply to a request with images as to any other, and `/health` reports it under `structured_output.images`.

`/v1/chat/completions` and `/v1/responses` take an image content part in the
usual OpenAI shape, carrying a `data:` URL or bare base64. Since 0.15.1
`/v1/messages` takes an Anthropic `image` block with a `base64` source.

```json
{"role": "user", "content": [
  {"type": "text", "text": "What does the error message say?"},
  {"type": "image_url", "image_url": {"url": "data:image/png;base64,..."}}
]}
```

An `http(s)` URL is refused deliberately: fetching one would make the server
issue outbound requests to wherever a client pointed it. Several images in one
conversation are attributed correctly, including an earlier one referred to
after a later one has arrived.

**What to expect from it.** Text at 12 pt and above is read exactly at every
supported resolution. Below that it degrades gradually rather than failing:
across a battery of several hundred readings every miss was the right field
with one to three characters wrong, and none read a different field or invented
a value. Two things are worth knowing when you choose what to send. A **bigger
frame is not better** for the same text, because past a point it adds empty
area and not detail. And a **densely filled page is harder than a sparse one**
at the same point size, which is a matter of finding the right row rather than
resolving it.

**What it costs.** One image adds roughly 1.0, 2.2 or 4.2 seconds at
1280x800, 1920x1080 or 2560x1440 (0.20.6, the time to the first token of a
request carrying one new image and a short question, the median of three on
each of two machines). `HALOGEN_VISION_MAX_PIXELS` (default
2560x1440) is the size an image is scaled down to fit, preserving aspect ratio;
larger images are downscaled rather than refused, and nothing is refused until
four times that. 3840x2160 is scaled down to 2560x1440, so it costs the same
4.3 seconds and reads no better than 1440p, which is why the default sits where
it does. There is no fixed aspect
ratio anywhere in the path: tall, wide and square crops all work, and a crop
under 256x256 is scaled up, which helps small text rather than hurting it. A
1920x1080 frame with a short question takes about 2,100 tokens of the context.
