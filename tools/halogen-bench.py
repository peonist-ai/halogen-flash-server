#!/usr/bin/env python3
"""halogen-bench, llama-bench-shaped sweep over halogen's HTTP endpoint.

    halogen-bench -p 512,2048,8192 -n 128 -d serial,mtp -r 3

Why this exists alongside tools/bench-serving.py, they answer different
questions and BOTH are needed:

    bench-serving.py   ten REAL prompt shapes, the number of record for
                       "how fast is this in practice". Prompt-shaped, so it
                       measures acceptance as users actually experience it.
    halogen-bench.py   a SIZE SWEEP at fixed synthetic lengths, so a number
                       can be put next to llama-bench's pp/tg table for the
                       same model on the same box. Comparable, not realistic.

Do not quote one where the other belongs. A pp2048 figure is not a chat
throughput figure and never was.

Everything goes over HTTP to /v1/chat/completions, chat template, tokenizer,
scheduler, engine. An engine-side harness measures a different thing (it skips
the whole front end), and this project has already misread an engine-side
fixture number as a serving number more than once.

Stdlib only, so it runs inside the release image, on the box, or from a
laptop pointed at a remote endpoint.
"""

import argparse
import json
import os
import statistics
import sys
import time
import urllib.request

# One filler sentence, repeated. Prefill cost is matmul FLOPs over the token
# count, it does not depend on WHICH tokens, so repeated filler measures the
# same thing real text would, and it makes the length predictable. This is
# also what llama-bench does with its dummy tokens.
FILLER = ("The unified memory architecture changes how inference engines "
          "schedule work across the accelerator and the host processor. ")


def post(api, body, timeout=1800):
    req = urllib.request.Request(api + "/v1/chat/completions",
                                 json.dumps(body).encode(),
                                 {"content-type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        d = json.loads(r.read())
    return d, time.time() - t0


def ask(api, prompt, max_tokens, drafter, effort):
    body = {"messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens, "enable_thinking": False,
            "reasoning_effort": effort}
    if drafter:
        body["drafter"] = drafter
    return post(api, body)


def build_prompt(api, target_tokens, effort, cache):
    """Text whose TOTAL prompt_tokens (chat template included) is ~target.

    Calibrated against the server rather than a local tokenizer: the release
    image's bench must not need transformers loaded in the bench process, and
    the template overhead is the server's business anyway. Two cheap probes
    (max_tokens=1) are enough, one for the fixed overhead, one for the
    per-filler-unit rate.
    """
    if "overhead" not in cache:
        d, _ = ask(api, "x", 1, None, effort)
        cache["overhead"] = d["usage"]["prompt_tokens"]
        d, _ = ask(api, "x" + FILLER * 20, 1, None, effort)
        cache["per_unit"] = max(
            1e-6, (d["usage"]["prompt_tokens"] - cache["overhead"]) / 20.0)
    need = max(0, target_tokens - cache["overhead"])
    return "x" + FILLER * max(1, round(need / cache["per_unit"]))


def main():
    ap = argparse.ArgumentParser(
        description="llama-bench-shaped pp/tg sweep over halogen's endpoint")
    ap.add_argument("--api", default="http://127.0.0.1:8731",
                    help="endpoint base URL")
    ap.add_argument("-p", default="512,2048",
                    help="prefill sizes (comma separated); empty to skip")
    ap.add_argument("-n", default="128",
                    help="generation sizes (comma separated); empty to skip")
    ap.add_argument("-d", "--drafters", default="",
                    help="drafters to sweep, e.g. serial,mtp "
                         "(default: whatever the server's default is)")
    ap.add_argument("-r", "--reps", type=int, default=3)
    ap.add_argument("--effort", default="low")
    ap.add_argument("--tg-cases", default="",
                    help="restrict tg to these prompt-set cases, e.g. "
                         "code_a,prose_b (default: all shapes)")
    ap.add_argument("--json", action="store_true",
                    help="emit machine-readable JSON instead of a table")
    a = ap.parse_args()

    pps = [int(x) for x in a.p.split(",") if x.strip()]
    tgs = [int(x) for x in a.n.split(",") if x.strip()]
    drafters = [d.strip() for d in a.drafters.split(",") if d.strip()] or [None]

    try:
        with urllib.request.urlopen(a.api + "/health", timeout=10) as r:
            health = json.loads(r.read())
    except Exception as e:
        print("cannot reach %s/health: %s" % (a.api, e), file=sys.stderr)
        return 2

    model = health.get("model", "?")
    ctx = health.get("context", "?")
    print("halogen-bench: %s, ctx %s, reps %d, effort %s"
          % (model, ctx, a.reps, a.effort))
    print("endpoint %s  (HTTP: chat template + tokenizer + engine)\n" % a.api)

    cache, rows, notes = {}, [], []

    # The same ten shapes bench-serving.py uses, so a tg figure here and a
    # figure there are measuring the same population.
    tg_src = "eval-prompts.json"
    try:
        _p = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          "eval-prompts.json")
        tg_prompts = [(k, v["prompt"] if isinstance(v, dict) else v)
                      for k, v in json.load(open(_p)).items()
                      if not k.startswith("_")]
    except Exception:
        # Worst-case-only fallback, and it says so: a lone prose prompt is
        # the low-acceptance end of the range, not a representative number.
        tg_prompts = [("prose", "Write a long detailed essay about "
                                "distributed systems.")]
        tg_src = "BUILT-IN PROSE ONLY, worst case, not representative"
    if a.tg_cases:
        want = {c.strip() for c in a.tg_cases.split(",")}
        tg_prompts = [c for c in tg_prompts if c[0] in want] or tg_prompts
        tg_src = "subset: " + ",".join(c[0] for c in tg_prompts)

    for drafter in drafters:
        dname = drafter or health.get("drafter_default", "default")

        for target in pps:
            prompt = build_prompt(a.api, target, a.effort, cache)
            samples, actual = [], None
            for _ in range(a.reps):
                # max_tokens=1 so the measured wall is prefill-dominated. The
                # single decode step is left IN rather than subtracted: it is
                # a real cost of answering, and subtracting an unmeasured
                # estimate would be worse than including a measured one.
                d, wall = ask(a.api, prompt, 1, drafter, a.effort)
                actual = d["usage"]["prompt_tokens"]
                samples.append(actual / wall)
            rows.append(("pp%d" % target, dname, samples, actual))

        for target in tgs:
            # tg SWEEPS THE PROMPT SET, it must not be one prompt.
            #
            # halogen's decode rate depends on draft ACCEPTANCE, which depends
            # on how predictable the text is. Measured on one build, holding
            # everything else fixed and varying only the prompt: prose 20.7 /
            # 22.6 t/s, code 40.4, proof 41.6. A 2x spread. The first cut of
            # this file used a single "write an essay" prompt, prose, the
            # WORST case, and so understated the drafter by ~30% against its own
            # ten-shape mean. That is the same mistake this project has
            # already made twice by quoting one prose prompt as the number.
            #
            # Consequence for cross-engine comparison: an engine with no
            # speculative decoding has a content-INDEPENDENT tg, so its single
            # number is legitimately one number. Ours is a distribution, and
            # the mean plus spread is the honest form of it. Say which prompt
            # set produced it whenever the figure is quoted.
            samples, got, ptok = [], 0, 0
            for cname, cprompt in tg_prompts:
                for _ in range(a.reps):
                    d, wall = ask(a.api, cprompt, target, drafter, a.effort)
                    got = d["usage"]["completion_tokens"]
                    ptok = d["usage"]["prompt_tokens"]
                    samples.append(got / wall)
            rows.append(("tg%d" % target, dname, samples, got))
            notes.append("tg%d over %d prompt shapes x %d reps (%s)"
                         % (target, len(tg_prompts), a.reps, tg_src))

    if a.json:
        print(json.dumps({"model": model, "context": ctx, "reps": a.reps,
                          "rows": [{"test": t, "drafter": dr,
                                    "tokens": n,
                                    "mean": statistics.fmean(s),
                                    "stdev": (statistics.stdev(s)
                                              if len(s) > 1 else 0.0)}
                                   for t, dr, s, n in rows]}, indent=2))
        return 0

    print("| model | drafter | test | tokens | t/s | min-max |")
    print("| --- | --- | --- | ---: | ---: | ---: |")
    for test, dname, s, n in rows:
        mean = statistics.fmean(s)
        sd = statistics.stdev(s) if len(s) > 1 else 0.0
        print("| %s | %s | %s | %d | %.2f ± %.2f | %.1f-%.1f |"
              % (model, dname, test, n, mean, sd, min(s), max(s)))
    print("\npp = prefill (prompt processing), tg = token generation.")
    print("Both are END-TO-END over HTTP and include that request's prefill, "
          "so tg\nslightly understates the pure decode rate.")
    print("tg is a MEAN OVER PROMPT SHAPES, and the min-max column is not "
          "noise: draft\nacceptance depends on how predictable the text is, "
          "so code and proofs run\n~2x prose. Quote the mean with the prompt "
          "set named, never a single shape.")
    for n in dict.fromkeys(notes):
        print("  note: " + n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
