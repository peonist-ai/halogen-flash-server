#!/usr/bin/env python3
# halogen-flash-server: source shipped as-is, comments stripped. The README is the documentation.
import collections
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

API = os.environ.get("HALOGEN_API", "http://127.0.0.1:8731")
HALO = os.environ.get("HALOGEN_HALO", os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
PROMPTS_PATH = os.environ.get("HALOGEN_PROMPTS",
                              os.path.join(HALO, "tools", "eval-prompts.json"))
API_CTR = os.environ.get("HALOGEN_API_CTR", "halogen-api")
API_LOG = os.environ.get("HALOGEN_API_LOG", "")

DEPTH = int(os.environ.get("HALOGEN_BENCH_DEPTH", "0"))
PREFIX_PATH = os.environ.get("HALOGEN_BENCH_PREFIX", "")
CPT = float(os.environ.get("HALOGEN_BENCH_CPT", "3.6"))

DRAFTERS = (sys.argv[1] if len(sys.argv) > 1 else "serial,mtp").split(",")
MAXTOK = int(sys.argv[2]) if len(sys.argv) > 2 else 256
EFFORT = sys.argv[3] if len(sys.argv) > 3 else "low"
REPS = int(sys.argv[4]) if len(sys.argv) > 4 else 1
TEMP = float(sys.argv[5]) if len(sys.argv) > 5 else 0.0
TOPP = float(sys.argv[6]) if len(sys.argv) > 6 else 0.95
SEED0 = 0x5EED0000

CASES = [(k, v["prompt"] if isinstance(v, dict) else v)
         for k, v in json.load(open(PROMPTS_PATH)).items()
         if not k.startswith("_")]

PREFIX, PREFIX_SHA = "", ""
if DEPTH:
    if not PREFIX_PATH:
        sys.exit("HALOGEN_BENCH_DEPTH needs HALOGEN_BENCH_PREFIX=<text file>. "
                 "There is deliberately no default corpus: see the header.")
    with open(PREFIX_PATH, "r", errors="replace") as f:
        doc = f.read()
    want = int(DEPTH * CPT)
    if len(doc) < want:
        sys.exit("%s holds %d chars, need ~%d for depth %d at %.1f chars/token"
                 % (PREFIX_PATH, len(doc), want, DEPTH, CPT))
    doc = doc[:want]
    PREFIX_SHA = hashlib.sha256(doc.encode()).hexdigest()[:12]
    PREFIX = ("Here is a reference document.\n\n<document>\n" + doc
              + "\n</document>\n\n")

LEDGER = re.compile(
    r"serve_api: (\w+) (\d+) tok in ([\d.]+)s = ([\d.]+) t/s \| "
    r"(\d+) rounds, commit ([\d.]+)/round \| prompt (\d+)"
    r"(?: \((\d+) cached(?:, [\d.]+%)?\))?, prefill ([\d.]+)s")

def _api_output():
    if API_LOG:
        try:
            with open(API_LOG, "r", errors="replace") as f:
                return "".join(collections.deque(f, maxlen=2000))
        except FileNotFoundError:
            return ""
    out = subprocess.run(["podman", "logs", "--tail", "2000", API_CTR],
                         capture_output=True, text=True)
    return out.stdout + out.stderr

def ledger_count():
    return len(LEDGER.findall(_api_output()))

def ledger_tail(n):
    return LEDGER.findall(_api_output())[-n:] if n else []

def ask(prompt, drafter, seed=None):
    b = {"messages": [{"role": "user", "content": PREFIX + prompt}],
         "max_tokens": MAXTOK, "reasoning_effort": EFFORT,
         "drafter": drafter}
    if TEMP > 0.0:
        b.update(temperature=TEMP, top_p=TOPP, seed=seed)
    else:
        b["temperature"] = 0.0
    body = json.dumps(b).encode()
    req = urllib.request.Request(API + "/v1/chat/completions", body,
                                 {"content-type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=900) as r:
        d = json.loads(r.read())
    wall = time.time() - t0
    m = d["choices"][0]["message"]
    return (d["usage"]["completion_tokens"], wall,
            m.get("reasoning_content", "") + m["content"])

base = ledger_count()
order, hashes = [], collections.defaultdict(dict)
print(f"bench: {len(CASES)} cases x {len(DRAFTERS)} drafters x {REPS} rep(s), "
      f"max_tokens={MAXTOK}, effort={EFFORT}"
      + (f", SAMPLED temp={TEMP} top_p={TOPP}" if TEMP > 0 else ", greedy")
      + (f"\n  depth ~{DEPTH} tok from {PREFIX_PATH} sha {PREFIX_SHA} "
         f"@ {CPT} chars/tok (measured length in the prompt column)"
         if DEPTH else ""))
for rep in range(REPS):
    for name, prompt in CASES:
        for dr in DRAFTERS:
            n, wall, text = ask(prompt, dr,
                                seed=SEED0 + rep * 1000 + hash(name) % 997)
            order.append((name, dr, wall, n))
            h = hashlib.sha256(text.encode()).hexdigest()[:12]
            prev = hashes[name].setdefault(dr, h)
            flag = "" if prev == h else "  !! UNSTABLE ACROSS REPS"
            print(f"  r{rep} {name:9s} {dr:8s} {n:4d} tok  {wall:6.2f}s wall"
                  f"{flag}", flush=True)

stats = ledger_tail(ledger_count() - base)

per = collections.defaultdict(lambda: collections.defaultdict(list))
wall_only = collections.defaultdict(lambda: collections.defaultdict(list))
si = 0
for (name, dr, wall, ntok) in order:
    if si < len(stats) and stats[si][0] == dr:
        st = stats[si]; si += 1
        per[name][dr].append((float(st[3]), float(st[5]), float(st[8]), wall,
                              int(st[7] or 0), int(st[6])))
    else:
        wall_only[name][dr].append((wall, ntok))

quiet = si == len(stats)
if not quiet:
    print(f"\nWARNING: {len(stats) - si} ledger line(s) matched no request, "
          f"other traffic hit the pod during the run. Re-run when it is quiet.",
          file=sys.stderr)
nospec = sorted({dr for c in wall_only.values() for dr in c})
if nospec:
    print(f"note: {', '.join(nospec)} emit no ledger line (non-speculative); "
          f"scored on wall and marked *, not comparable to engine t/s.")

print(f"\n{'case':10s} {'drafter':9s} {'t/s':>7s} {'commit/rd':>10s} "
      f"{'prefill':>8s} {'wall':>7s}" + (f" {'prompt':>7s}" if DEPTH else ""))
agg = collections.defaultdict(list)
for name, _ in CASES:
    for dr in DRAFTERS:
        v = per.get(name, {}).get(dr)
        if not v:
            w = wall_only.get(name, {}).get(dr)
            if w:
                mw = sum(x[0] for x in w) / len(w)
                mt = sum(x[1] for x in w) / len(w)
                print(f"{name:10s} {dr:9s} {mt / mw:7.2f}*{'':9s} "
                      f"{'':7s} {mw:6.2f}s")
            continue
        ts = sum(x[0] for x in v) / len(v)
        cm = sum(x[1] for x in v) / len(v)
        pf = sum(x[2] for x in v) / len(v)
        wl = sum(x[3] for x in v) / len(v)
        spread = f"  (±{(max(x[0] for x in v) - min(x[0] for x in v)) / 2:.2f})" \
            if len(v) > 1 else ""
        cached = sum(x[4] for x in v) / len(v)
        ch = f"  [{cached:.0f} cached]" if cached else ""
        pt = f" {sum(x[5] for x in v) / len(v):7.0f}" if DEPTH else ""
        print(f"{name:10s} {dr:9s} {ts:7.2f} {cm:10.2f} {pf:7.2f}s "
              f"{wl:6.2f}s{pt}{spread}{ch}")
        agg[dr].append((ts, cm))

print("\n=== identity (sha256 of reasoning+content, per case) ===")
if TEMP > 0.0:
    print("SKIPPED, sampled runs are not expected to be identical across")
    print("drafters. Correctness here is gated distributionally by")
    print("--spec-sample-check and gate-s3-falsify.sh, not by a hash.")
    sys.exit(0)
bad = [n for n, h in hashes.items() if len(set(h.values())) != 1]
print("PASS, every drafter byte-identical on every case" if not bad
      else f"FAIL, drafters disagree on: {bad}\n"
           f"  A drafter CANNOT change output (commit is trunk-argmax\n"
           f"  equality). This is a verify or drafter-state bug, not a\n"
           f"  tuning issue. Stop and fix it.")

print("\n=== means over all cases ===")
REF = next((d for d in DRAFTERS if agg.get(d)), None)
ref_mean = (sum(a for a, _ in agg[REF]) / len(agg[REF])) if REF else 0.0
for dr in DRAFTERS:
    v = agg.get(dr)
    if not v:
        print(f"{dr:9s} no engine t/s (non-speculative; see the wall-scored "
              f"* rows above)")
        continue
    ts = [a for a, _ in v]
    mean = sum(ts) / len(ts)
    cm = sum(b for _, b in v) / len(v)
    delta = f"   {(mean / ref_mean - 1) * 100:+.1f}% vs {REF}" \
        if dr != REF else ""
    print(f"{dr:9s} mean {mean:6.2f} t/s   min {min(ts):5.2f}  "
          f"max {max(ts):5.2f}   commit {cm:.2f}/round{delta}")
if DEPTH and any(d not in agg for d in DRAFTERS):
    print("\nWARNING: at depth, a wall-scored * row is NOT a decode rate. Its\n"
          "wall is dominated by the shared prefix's prefill (about 26 s at\n"
          "32k here), so it reads several times slower than the drafter\n"
          "actually decodes. Compare * rows only against other * rows at the\n"
          "SAME depth, never against an engine t/s.")
sys.exit(1 if bad else 0)
