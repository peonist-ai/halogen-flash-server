# Contributing

Reports are genuinely wanted. Several releases have been driven entirely by
them, and the changelog credits the people who found the problems.

**What helps most**

- What you ran, what you expected, what happened.
- The image tag, and any `HALOGEN_*` variables you set.
- `GET /health`, and the container log around the problem.
- If it is a performance report: how many requests were in flight, and whether
  the number is per-stream or aggregate. Those two questions resolve most of
  them.
- Measurements, if you have them. A curve beats an adjective.

**About patches**

halogen-flash is closed source and this repository holds the deployment tree,
not the engine. That means we cannot merge a diff: there is no inbound licence
for code posted to an issue, and taking one into a proprietary build would put
code of unclear provenance into a product we ship.

This is not a brush-off, and it is not about the quality of the patch. Please
do send the analysis: what the mechanism is, what you measured, what you think
the fix is, and how you convinced yourself it is correct. That is the part that
is hard, and it is the part we credit. We will implement it here and say plainly
where the diagnosis came from.

If you have already attached a diff, nothing is wrong and nothing is lost. We
will read it, and we will still write our own implementation.

**Security issues**

Please do not open a public issue. Contact the maintainers directly.
