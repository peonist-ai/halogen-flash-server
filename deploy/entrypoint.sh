#!/bin/bash
# deploy/entrypoint.sh: Peonist halogen-flash-server release image entrypoint.
#
# The binary is `flash_serve` and its CLI is `--ck FILE` (there is no
# `--checkpoint`), no `--serve` verb at all, plus `--slots/--ctx/--max-tok`.
#
#   all      (default) engine on loopback + OpenAI front-end. One container,
#            one published port. This is the shape a user who just wants to
#            run the thing should get.
#   engine   engine only, for the two-container topology (compose), where
#            front-end iteration must not cost a 115.4 GiB model reload.
#   api      front-end only, same reason.
#   bench    run the throughput benchmark against this image's OWN endpoint
#            and exit. Args: [drafters] [max_tokens] [effort] [reps], e.g.
#            `bench serial,mtp 256 low 3`. Needs the model and tokenizer
#            mounted exactly like `all` does.
#
#            THE DRAFTER SET IS `serial,mtp`. This model has no separate draft
#            model. There is no second checkpoint to draft from. Its two
#            drafters are serial greedy (wire 0, batched across slots) and the
#            MTP head's depth-1 loop (wire 1, lossless). Asking for a drafter
#            that does not exist is a 400 from the front-end, by design (a
#            silent downgrade would make the comparison lie).
#
#            This exists because the first thing anyone does with a claim
#            about speed is try to reproduce it, and until now that required
#            our private golden fixtures. The ten prompt shapes are baked in
#            (a few KB of JSON); the goldens are NOT and are not needed.
#            It drives the real HTTP endpoint, meaning chat template,
#            tokenizer, SSE and engine, not an engine-side harness, because one
#            number is not a serving number.
#   sweep    llama-bench-shaped pp/tg size sweep, for putting a number next to
#            another engine's table on the same box. Args are passed through
#            to tools/halogen-bench.py, e.g.
#            `sweep -p 512,2048,8192 -n 128 -d serial,mtp -r 3`.
#            `bench` answers "how fast in practice", `sweep` answers "how does
#            this compare at a fixed size". They are not interchangeable.
#   convert  (0.12.1) write a llama.cpp GGUF as the engine's own .hgn and
#            exit: `convert IN.gguf OUT.hgn`. The same lossless repack the
#            engine runs in RAM at every GGUF start, with the n-gram table and
#            the draft head folded in, so OUT.hgn is a complete checkpoint
#            (HALOGEN_CHECKPOINT=OUT.hgn starts in seconds from a warm disk
#            and needs no GGUF beside it). Needs the draft head as a GGUF
#            start does (HALOGEN_MTP_HEAD, or beside the GGUF, or
#            HALOGEN_DOWNLOAD). No engine, no port. About 10 minutes and
#            ~105 GiB on the reference machine for an IQ4_XS build.
#   inspect  (0.13.0) the checkpoint tools, one verb each, and exit:
#   verify     `inspect [FILE.hgn] [--json] [--no-hash]` prints what the
#   ppl        file carries (precision by tensor family, bits per weight from
#   niah       the shapes, one sha256 per tensor); `verify [FILE.hgn]` reads
#            it back independently of any writer and says PASS, or FAIL
#            naming the first tensor; `ppl [FILE] --ids IDS.bin [--chunk
#            1024|8] [--vs OTHER]` is teacher-forced perplexity through
#            this image's engine (with --vs, the paired statistic against
#            a second file); `niah [FILE] --manifest CASES.tsv [--out DIR]`
#            runs a retrieval battery. `ppl --corpus TEXT` and `niah
#            --corpus TEXT` take a text file (tokenized with the mounted
#            tokenizer; the battery's filler is the corpus); `--json` gives
#            one object; `ppl --ref REF --worst N` prints the N positions
#            two files disagree on most, decoded. FILE defaults to
#            HALOGEN_CHECKPOINT (an .hgn, or any shard of a GGUF for
#            ppl/niah). ppl and niah
#            load the model and run under this image's engine environment
#            (the baked tuning plan, the quality sidecar beside the
#            checkpoint, the trunk pinned), which is the served numerics;
#            `-e HALOGEN_MATMUL_TUNING_FILE=` runs without the plan. One
#            model at a time: not beside a running server on the same
#            machine. The image advertises these in /health `modes` and the
#            OCI label `ai.peonist.halogen.modes`.
#
# The engine's token protocol has NO AUTH. In `all` it binds loopback INSIDE
# the container and is unreachable from outside; only the API port is
# published. If you split the roles you must keep the engine port unpublished
# yourself. The compose file does, deliberately.
set -euo pipefail

# NO CORE DUMPS, GPU OR CPU (0.12.2, public issue #83). After a GPU memory
# fault the bundled runtime writes a GPU core dump of the process
# ("GPU coredump: ... Falling back to file-based dump"), and this process
# has 100+ GiB mapped, so that is minutes in uninterruptible sleep before
# the engine can exit and the container can come down; the watchdog reads
# the silence as a host short of memory (#79's shape) and waits it out.
# The variable's name is the one the runtime shipped in this image reads
# (strings on its libhsa-runtime64.so; HSA_COREDUMP_PATTERN is the sibling
# the message names). The CPU core of the same process through the host's
# core_pattern is the same minutes, so RLIMIT_CORE is 0 beside it. A fault
# then ends the engine in seconds and the takedown path (0.11.9) runs.
export HSA_DISABLE_COREDUMP_ON_EXCEPTION="${HSA_DISABLE_COREDUMP_ON_EXCEPTION:-1}"
ulimit -c 0

ENG_PORT="${HALOGEN_PORT:-8730}"
API_PORT="${HALOGEN_API_PORT:-8731}"
BIND="${HALOGEN_BIND:-127.0.0.1}"

# THE NATIVE 262,144 CONTEXT IS THE SHIPPED DEFAULT, and the three numbers
# below are a budget, not three independent knobs. Measured on a 128 GB box,
# quality sidecar loaded, cache on:
#
#   slots x ctx     KV per slot      result
#   4 x  32,768     832 MiB          starts, 90.7 GiB left
#   1 x 262,144     6.5 GiB          starts, 87.4 GiB left
#   2 x 262,144     6.5 GiB          starts, 80.6 GiB left
#   4 x 262,144     6.5 GiB          **HIP out of memory**
#
# KV costs ~26 KiB per position per slot, so the product `slots x ctx` was
# what had to fit. Since 0.3 THE SLOTS SHARE ONE KV POOL of `ctx` positions
# (HALOGEN_KV_POOL=1, the default), and a slot costs only its ~115 MiB of
# O(1) state, so 4 x 262,144 is ~28.1 GiB (measured) and STARTS. A request
# reserves prompt + max_tokens positions of the pool and waits when it does
# not fit; four conversations decode together, each byte-identical to the
# one it would have had alone; the speculative drafter speculates while it
# is the only active stream and takes batched rows otherwise; a prompt that
# arrives beside active streams is admitted in HALOGEN_ADMIT_CHUNK pieces
# so it does not freeze them. SLOTS DEFAULTS TO 4. HALOGEN_KV_POOL=0 is the
# pre-0.3 form, where the table above applies.
#
# MAX-TOK IS CAPPED AT 32,768 AND MUST NOT FOLLOW THE CONTEXT. It sizes the
# single-call prefill arena (4.32 GiB of tier-1 scratch at 32,768 alone), and
# asking for a 262,144-wide call is an immediate out-of-memory, measured at
# 131k. Prompts longer than max-tok are prefilled in max-tok pieces, which is
# what makes the native context affordable at all.
# THE SHIPPED SERVER IS QUIET ABOUT HOW IT IS ARMED.
#
# The engine narrates its startup by default, which is right for the machines
# this is developed and gated on and wrong for a published container: those
# lines name internal strategies, kernel arrangements and tuning constants,
# and the audience here is a stranger running an image. What the server IS
# SERVING still prints (precision, KV pool, slots, cache mode, the listening
# banner); how it is armed does not. Set HALOGEN_VERBOSE=1 to get it back when
# troubleshooting, which is the only time anyone wants it.
export HALOGEN_VERBOSE="${HALOGEN_VERBOSE:-0}"

ENG_SLOTS="${HALOGEN_KV_SLOTS:-4}"
ENG_CTX="${HALOGEN_CTX:-262144}"
# 0.3: THE POOL IS SIZED SEPARATELY FROM THE CONTEXT. HALOGEN_KV_POOL_POSITIONS
# is how many attention positions are resident across all conversations;
# HALOGEN_CTX is the most one request may use. Unset, the pool is TWICE the
# context, capped at 1,048,576: two full-length conversations at once, or
# four at 131k, 35.0 GiB at the native context. (0.3.0 defaulted to three,
# 42.2 GiB; 0.3.1 lowered it after that failed to start on a machine whose
# device ceiling was about 40 GiB.) The device budget is the limit
# (~46 GiB on a 128 GB machine): each 262,144 positions cost ~7.2 GiB, and
# the prefill arena (HALOGEN_MAX_TOK) 16.7 GiB at 32,768 or 8.4 GiB at
# 16,384, which is what makes a 1M-position pool fit. The pool also takes
# RAM the page cache would otherwise hold for the n-gram table, so a cold
# prompt whose rows are not cached pays disk reads; a smaller pool leaves
# more cache.
#
# 0.3.1: THE DEFAULT IS TWO CONTEXTS, NOT THREE. 0.3.0 shipped three
# (786,432 positions, 42.2 GiB) against a device ceiling measured at ~47 GiB
# on the one machine it was sized on: 4.8 GiB of headroom on a sample of one.
# A tester's machine refused at ~40.4 GiB and 0.3.0 would not start there at
# all, while 0.2.0 (this pool at 262,144) ran fine. Two contexts is 35.0 GiB,
# holds two full-length conversations or four at 131k, and leaves room on a
# machine that is not this project's box. Three is one line away for anyone
# who has measured their own headroom. The engine also fits the pool downward
# at startup now (HALOGEN_KV_POOL_FIT), so this default is the starting point
# rather than the last line of defence.
ENG_POOL="${HALOGEN_KV_POOL_POSITIONS:-}"
if [ -z "$ENG_POOL" ]; then
  ENG_POOL=$(( ENG_CTX * 2 ))
  [ "$ENG_POOL" -gt 1048576 ] && ENG_POOL=1048576
  [ "$ENG_POOL" -lt "$ENG_CTX" ] && ENG_POOL="$ENG_CTX"
fi
# PAST THE NATIVE CONTEXT THE DEFAULTS CHANGE, AND THIS SAYS SO. Measured on
# a 128 GB machine: the engine's device-side budget stops at ~47 GiB with
# the weights pinned, and 1,048,576 of KV is ~25 GiB of it, so the per-call
# prefill arena (16.7 GiB at max-tok 32,768) has to halve, and the prompt
# cache's snapshot (26.6 GiB of host memory at 1M) does not fit beside it.
# The image BAKES HALOGEN_MAX_TOK=32768 and HALOGEN_PROMPT_CACHE=2 into its
# environment, so "unset" cannot mean "the user did not choose": past the
# native context the arena is capped at 16384 and the cache's snapshot
# goes to a file, whatever the environment says, and both are printed.
# (Measured: 24,576 ALLOCATES at 1M with 2.3 GiB to spare, but a full 1M
# prefill then thrashes, because the limit counts touched pages, while 16,384
# prefills 1M at 750 tok/s. The first cut keyed on -z and the 1M image
# start failed at the same 47 GiB as before.)
ENG_MAX_TOK="${HALOGEN_MAX_TOK:-32768}"
if [ "$ENG_CTX" -gt 262144 ]; then
  if [ "$ENG_MAX_TOK" -gt 16384 ]; then
    echo "halogen: context $ENG_CTX is past the native 262144: HALOGEN_MAX_TOK $ENG_MAX_TOK is capped at 16384 here (a larger prefill arena leaves a 1M KV cache no room to stay resident)."
    ENG_MAX_TOK=16384
  fi
  if [ "${HALOGEN_PROMPT_CACHE:-2}" != "0" ] && [ "${HALOGEN_CACHE_INPLACE:-1}" = "0" ] && [ -z "${HALOGEN_CACHE_FILE:-}" ]; then
    # With HALOGEN_CACHE_INPLACE=0 the snapshot copies the whole KV, which
    # does not fit in host RAM beside a 1M KV cache (26.6 GiB), so it goes
    # to a FILE: the same bytes, at the drive's rate. Mount fast storage at
    # the path, or point HALOGEN_CACHE_FILE somewhere. The default keeps the
    # KV in place and its snapshot is ~115 MiB at any depth.
    export HALOGEN_CACHE_FILE=/var/tmp/halogen-cache.snapshot
    echo "halogen: context $ENG_CTX is past the native 262144 with HALOGEN_CACHE_INPLACE=0: the prompt cache snapshot goes to HALOGEN_CACHE_FILE=$HALOGEN_CACHE_FILE (up to 26.6 GiB at 1M; mount fast storage there, or set the path)."
  fi
fi
[ "$ENG_MAX_TOK" -gt "$ENG_CTX" ] && ENG_MAX_TOK="$ENG_CTX"

# CONTEXTS PAST THE NATIVE 262,144 NEED THE ROPE FACTOR, AND IT IS A DECISION.
# The model's own card extends it to 1M by static YaRN (HALOGEN_ROPE_YARN=4;
# 2 for 524,288), which rescales every position's RoPE, short prompts
# included. The engine refuses the combination too; this says it before the
# model loads. Sizing note: the KV cache is ~26 KiB per position per slot,
# and the prompt cache (on by default) keeps a second copy of it.
ROPE_YARN="${HALOGEN_ROPE_YARN:-}"
if [ "$ENG_CTX" -gt 262144 ] && [ -z "$ROPE_YARN" ]; then
  echo "halogen: HALOGEN_CTX=$ENG_CTX is past the native 262144. Contexts up to"        "1048576 need HALOGEN_ROPE_YARN=<factor> (4 for 1M, 2 for 524288), the"        "model's documented static YaRN, which changes its numerics at every"        "position. Set it deliberately, or lower HALOGEN_CTX." >&2
  exit 2
fi
if [ -n "$ROPE_YARN" ] && [ "$ENG_CTX" -le 262144 ]; then
  echo "halogen: WARNING: HALOGEN_ROPE_YARN=$ROPE_YARN with HALOGEN_CTX=$ENG_CTX at or"        "under the native 262144. Static YaRN rescales every position; the model"        "card advises it only when the context needs it." >&2
fi

# A KV budget the user can read BEFORE the allocator refuses. Without this the
# only symptom of an over-subscribed `slots x ctx` is
# `HIP flash_ops.h:103: out of memory` with no numbers attached, a failure
# shape where the message names the mechanism and not the cause.
kv_budget_note() {
  local kv_gib avail_gib
  # 0.3: one pool of ctx positions plus ~115 MiB of O(1) state per slot;
  # HALOGEN_KV_POOL=0 is the private-KV-per-slot form, slots x ctx.
  kv_gib=$(awk -v s="$ENG_SLOTS" -v c="$ENG_CTX" -v p="$ENG_POOL" -v pool="${HALOGEN_KV_POOL:-1}" 'BEGIN{printf "%.1f", (pool=="0"?s*c*26624:p*29500+s*120586240)/1073741824}')
  # The prompt cache (HALOGEN_PROMPT_CACHE, default on) keeps the KV in
  # place and holds ~115 MiB of O(1) state; with HALOGEN_CACHE_INPLACE=0 it
  # holds a second copy of one slot's state and the budget is kv + one slot.
  cache_gib=$(awk -v c="$ENG_CTX" -v on="${HALOGEN_PROMPT_CACHE:-2}" -v ip="${HALOGEN_CACHE_INPLACE:-1}" -v f="${HALOGEN_CACHE_FILE:-}" -v n="${HALOGEN_CACHE_ENTRIES:-20}" 'BEGIN{printf "%.1f", (on==0 || f!="")?0:(ip!="0"?n*115*1048576/1073741824:c*26624/1073741824)}')
  avail_gib=$(awk '/MemAvailable/{printf "%.1f", $2/1048576}' /proc/meminfo 2>/dev/null || echo "?")
  # PUBLIC ISSUE #10: WHAT THE HOST IS ALREADY CARRYING. The pool sizing reads
  # MemTotal and reserves a fixed amount for the OS plus the lookup table's
  # file cache; it cannot see that a desktop session, a browser, or the
  # client on the same host already holds 13 to 17 GiB, and on such a host
  # the 47.7 GiB table it reads through the file cache is left with almost
  # none, every prompt reads it from disk, and the engine goes silent for
  # minutes under a watchdog that called that a wedge. The number that says
  # so was printed on the line below in every such report and nothing
  # compared it to MemTotal. This does. Informational; the pool is not
  # resized, because below one context there is no smaller pool to pick.
  # PUBLIC ISSUE #80: THE GGUF ESTIMATE IS BY FILE TYPE, NOT ONE CONSTANT.
  # "72 GiB" was unsloth's UD-IQ4_XS repacked (file_type 30); the K-quant
  # build the engine has read since 0.11.6 (UD-Q4_K_XL, file_type 15)
  # repacks to 78 to 80 GiB, and a 122 GiB box that fit the first by 22 GiB
  # missed the pin floor with the second by 2 while this line said it had 27
  # to spare. The engine reads the exact figure from the header before it
  # allocates anything (`... GiB of resident weights once repacked`); this
  # is the same header, read here so the warning below can fire before the
  # engine spends 30 s repacking into a start that will refuse.
  local wt="68 GiB" w_gib=68 ft=""
  if is_gguf; then
    ft=$(gguf_file_type "$HALOGEN_CHECKPOINT")
    case "$ft" in
      15) wt="80 GiB (a K-quant GGUF trunk, file type 15, repacked into RAM)"; w_gib=80 ;;
      30) wt="72 GiB (an 8-bit GGUF trunk, file type 30, repacked into RAM)"; w_gib=72 ;;
      *)  wt="72 GiB or more (a GGUF trunk of file type ${ft:-unknown}, repacked into RAM; measured for types 30 and 15 only)"; w_gib=72 ;;
    esac
  fi
  # The working memory beside the pool, as measured on 0.11.4 (issue #35):
  # 21.3 GiB at HALOGEN_MAX_TOK 32768 and 12.5 at 16384, so a fixed 4.6 plus
  # a prefill arena linear in max_tok. This line said "11 GiB of scratch"
  # until 0.11.9, a number from before the arena was measured.
  local scratch_gib tower_gib=0
  scratch_gib=$(awk -v mt="$ENG_MAX_TOK" 'BEGIN{printf "%.1f", 4.6 + 16.7 * mt / 32768}')
  [ -n "${HALOGEN_VISION_TOWER:-}" ] && [ "${HALOGEN_VISION_TOWER:-0}" != "0" ] && tower_gib=0.84
  w_gib=$(awk -v w="$w_gib" -v s="$scratch_gib" -v t="$tower_gib" 'BEGIN{printf "%.1f", w + s + t}')
  used_gib=$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf "%.1f", (t-a)/1048576}' /proc/meminfo 2>/dev/null || echo "0")
  if awk -v u="$used_gib" 'BEGIN{exit !(u >= 10)}'; then
    echo "halogen: WARNING ${used_gib} GiB of host RAM is in use before this server starts. The server sizes itself from the machine's total and leaves a fixed" \
         "reserve for the OS and the model's 47.7 GiB lookup table, which is read through the file cache; whatever is already using those ${used_gib} GiB comes out of that cache." \
         "Expect every prompt to read the table from disk, prefill to run several times slower than published, and pauses of a minute or more. Stop the other" \
         "workloads, or run this server on a host of its own." >&2
  fi
  if [ "${HALOGEN_KV_POOL:-1}" = "0" ]; then
    echo "halogen: KV budget ${ENG_SLOTS} slot(s) x ${ENG_CTX} ctx = ${kv_gib} GiB" \
         "(~26 KiB/position/slot, HALOGEN_KV_POOL=0) + ${cache_gib} GiB prompt cache in RAM${HALOGEN_CACHE_FILE:+ (snapshot on file)}, on top of roughly ${wt}" \
         "of weights and ${scratch_gib} GiB of working memory (HALOGEN_MAX_TOK ${ENG_MAX_TOK}). Those last two are estimates for this pre-flight check; the engine prints its measured figures once loaded," \
         "including the large lookup table it reads from disk and never holds. MemAvailable now ${avail_gib} GiB."
  else
    echo "halogen: KV budget ${ENG_SLOTS} slot(s) over one ${ENG_POOL}-position pool (each request up to ${ENG_CTX}) = ${kv_gib} GiB" \
         "(~28 KiB/position incl. block scratch + ~115 MiB/slot) + ${cache_gib} GiB prompt cache in RAM${HALOGEN_CACHE_FILE:+ (snapshot on file)}, on top of roughly ${wt}" \
         "of weights and ${scratch_gib} GiB of working memory (HALOGEN_MAX_TOK ${ENG_MAX_TOK}). Those last two are estimates for this pre-flight check; the engine prints its measured figures once loaded," \
         "including the large lookup table it reads from disk and never holds. MemAvailable now ${avail_gib} GiB."
  fi
  # 0.7.0: a GGUF trunk is repacked into RAM in full and its 8-bit layers
  # are larger than the engine's own checkpoint's: ~72 GiB for unsloth's
  # UD-IQ4_XS against ~68 for the .hgn, ~80 for UD-Q4_K_XL (#80). `w_gib`
  # is that plus the working memory and the tower; the engine prints the
  # exact figures. The pin floor (16 GiB of MemAvailable at the last pin) is
  # the check that ends a start that is over, so it is in the sum and the
  # warning names it and the lever that gave #80's box back 9 GiB. On #80's
  # box this reads 129 against 119 for the K-quant (it refused at 14.4) and
  # 120 against 119 for UD-IQ4_XS (it booted with 17.6 left): "close to".
  awk -v kv="$kv_gib" -v cg="$cache_gib" -v av="$avail_gib" -v w="$w_gib" 'BEGIN{ if (av != "?" && kv+cg+w+16 > av)
    print "halogen: WARNING: that budget is close to or over what this host has free (the engine refuses the last pin under 16 GiB of MemAvailable).\n  If startup ends in \"checkpoint: refusing to pin\" or \"HIP ... out of memory\", lower HALOGEN_MAX_TOK to 16384 (the working memory, about 9 GiB back for about 9% of prefill speed)\n  or HALOGEN_KV_POOL_POSITIONS (the pool, ~29.5 KiB a position); a 1,048,576-position pool fits only with HALOGEN_MAX_TOK=16384." > "/dev/stderr" }'
}

# The GGUF's `general.file_type` (u32) from the first shard's header, or
# nothing. Walks the KV table in order and stops at the key; it sits before
# the tokenizer's arrays in every file we have read, so this is a few KB.
# Any surprise (not a GGUF, a nested array, a short file) prints nothing and
# the caller falls back to the unmeasured wording.
gguf_file_type() {
  python3 - "$1" 2>/dev/null <<'PY'
import struct, sys
SZ = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8}
try:
    with open(sys.argv[1], "rb") as f:
        if f.read(4) != b"GGUF":
            sys.exit(0)
        f.read(4)
        _, nk = struct.unpack("<QQ", f.read(16))
        def rs():
            n, = struct.unpack("<Q", f.read(8)); return f.read(n)
        def skip(t):
            if t == 8:
                rs()
            elif t == 9:
                et, = struct.unpack("<I", f.read(4)); n, = struct.unpack("<Q", f.read(8))
                if et == 8:
                    for _ in range(n): rs()
                elif et == 9:
                    raise ValueError("nested array")
                else:
                    f.seek(SZ[et] * n, 1)
            else:
                f.seek(SZ[t], 1)
        for _ in range(nk):
            k = rs(); t, = struct.unpack("<I", f.read(4))
            if k == b"general.file_type" and t == 4:
                print(struct.unpack("<I", f.read(4))[0]); sys.exit(0)
            skip(t)
except Exception:
    pass
PY
}

# PUBLIC ISSUE #79: WHAT THE GPU IS ALREADY HOLDING. On this chip every
# allocation the engine makes on the GPU lands in GTT, which is system RAM
# under the driver's own ceiling (ttm.pages_limit), and a start whose pool
# cannot be placed there does not fail cleanly: it blocks inside the driver,
# and if the driver is also holding a lock the process is unkillable. Four
# hosts have reached that state (#34's two machines, this project's own gate
# box, #79), each after a process holding the GPU ended while the driver had
# work in flight (another model's exit, a bench's normal exit, a cancelled
# request, a watchdog kill under a memory stall): the GTT (35 to 45 GiB,
# measured on three of them) stayed allocated with no process alive and
# every later start refused at the pin guard or hung at "reserving the KV
# pool" until the host rebooted. Nothing inside a container can release it. The
# container CAN say it is there before it commits, which is what this does:
# the counters are the driver's own (mem_info_gtt_used and _total under the
# card's sysfs node, readable through /sys where the runtime mounts it), and
# /sys/class/kfd/kfd/proc lists every process holding the GPU, host-wide,
# so "in use and nobody holds it" is readable from here. The weights do not
# count here (a read-only file mapping registered in place, not a GTT
# allocation); what the engine puts in GTT is the pool and its working
# memory, about 36 GiB at the shipped defaults.
gtt_note() {
  local sys="${_hg_sys:-/sys}" f used="" total="" holders
  for f in "$sys"/class/drm/card*/device/mem_info_gtt_used; do
    [ -r "$f" ] || continue
    used=$(cat "$f" 2>/dev/null) || continue
    total=$(cat "${f%used}total" 2>/dev/null) || continue
    [ -n "$used" ] && [ -n "$total" ] && break
  done
  if [ -z "$used" ] || [ -z "$total" ]; then
    echo "halogen: GTT in use before this start: unknown (no amdgpu sysfs node is readable from this container)"
    return 0
  fi
  # The pool and the O(1) state, as kv_budget_note sizes them, plus the
  # prefill arena (16.7 GiB at HALOGEN_MAX_TOK 32768, linear in it). The
  # rest of the working memory (~4.6 GiB measured on 0.11.4, issue #35) is
  # left out on purpose: this refuses only what certainly does not fit.
  local need_gib
  need_gib=$(awk -v s="$ENG_SLOTS" -v c="$ENG_CTX" -v p="$ENG_POOL" -v pool="${HALOGEN_KV_POOL:-1}" -v mt="$ENG_MAX_TOK" \
    'BEGIN{printf "%.1f", (pool=="0"?s*c*26624:p*29500+s*120586240)/1073741824 + mt/32768*16.7}')
  local used_gib total_gib free_gib
  used_gib=$(awk -v u="$used" 'BEGIN{printf "%.1f", u/1073741824}')
  total_gib=$(awk -v t="$total" 'BEGIN{printf "%.1f", t/1073741824}')
  free_gib=$(awk -v u="$used" -v t="$total" 'BEGIN{printf "%.1f", (t-u)/1073741824}')
  holders="?"
  if [ -d "$sys/class/kfd/kfd/proc" ] && [ -r "$sys/class/kfd/kfd/proc" ]; then
    holders=$(ls "$sys/class/kfd/kfd/proc" 2>/dev/null | wc -l | tr -d ' ')
  fi
  echo "halogen: GTT in use before this start: ${used_gib} GiB of ${total_gib} (${free_gib} free; this start puts about ${need_gib} GiB there)"
  if awk -v u="$used" 'BEGIN{exit !(u >= 2147483648)}'; then
    if [ "$holders" = "0" ]; then
      echo "halogen: WARNING ${used_gib} GiB of GTT is in use and no process holds the GPU, as far as this container can see (/sys/class/kfd/kfd/proc is empty)." >&2
      echo "  That is memory a previous engine's exit did not give back: the driver kept it (issue #79; four hosts, each after a GPU process ended while the driver had work in flight)." >&2
      echo "  Removing and restarting containers does not release it. Check on the host: cat /sys/class/drm/card*/device/mem_info_gtt_used, and fuser -v /dev/kfd." >&2
      echo "  If nothing holds /dev/kfd and the figure does not fall, reboot the host before starting this server; a start on top of it can hang at \"reserving the KV pool\" with the process unkillable." >&2
    elif [ "$holders" != "?" ]; then
      echo "halogen: NOTE ${used_gib} GiB of GTT is held by ${holders} process(es) on this host before this start (another model, or a previous engine still exiting). This server starts on what is left, and shares the GPU with them."
    else
      echo "halogen: NOTE ${used_gib} GiB of GTT is in use before this start (another model on this host, or a previous engine's memory the driver kept; /sys/class/kfd/kfd/proc is not readable here to tell which)."
    fi
  fi
  if awk -v f="$free_gib" -v n="$need_gib" 'BEGIN{exit !(f < n)}'; then
    echo "halogen: refusing to start: ${free_gib} GiB of GTT is free and this configuration needs about ${need_gib} GiB there." >&2
    echo "  A start that cannot place its pool does not fail, it blocks inside the driver (issue #79). Free the GTT first (stop the other GPU workloads, or reboot if nothing holds it), or lower HALOGEN_KV_POOL_POSITIONS / HALOGEN_MAX_TOK to fit ${free_gib} GiB." >&2
    exit 1
  fi
}

# OPTIONAL model download. OFF unless HALOGEN_DOWNLOAD names a repo.
#
# Default-off is deliberate and is not timidity: with it off, this image opens
# NO outbound connections at all, which is a property worth keeping and which
# the EULA states. A 115.4 GiB transfer should also never start because someone
# ran `podman run` to see what happens.
#
# Only fires when the checkpoint is genuinely absent, so a restart never
# re-downloads. huggingface_hub resumes partial files natively, so an
# interrupted pull continues rather than starting over.
maybe_download() {
  [ -n "${HALOGEN_DOWNLOAD:-}" ] || return 0
  [ -f "$HALOGEN_CHECKPOINT" ] && return 0
  # 0.7.0: a GGUF is the user's file (unsloth's, or their own llama-quantize);
  # the weights repo does not carry one and this must not fetch 115 GiB of the
  # engine's checkpoint in its place.
  if is_gguf_path; then
    echo "halogen: $HALOGEN_CHECKPOINT is a GGUF and is not there; GGUF files are not downloaded by this image." >&2
    echo "  Put the file (every shard of a split) in the models volume and point HALOGEN_CHECKPOINT at any shard." >&2
    exit 1
  fi

  local dir; dir="$(dirname "$HALOGEN_CHECKPOINT")"
  if [ ! -w "$dir" ]; then
    echo "halogen: HALOGEN_DOWNLOAD is set but $dir is not writable." >&2
    echo "  The models volume must be read-WRITE to download into it." >&2
    echo "  Mount it as -v <path>:/models  (drop the :ro)." >&2
    exit 1
  fi

  echo "halogen: $HALOGEN_CHECKPOINT not found."
  echo "halogen: downloading from $HALOGEN_DOWNLOAD into $dir"
  echo "         this is tens of GB and will take a while; it resumes if interrupted."
  # HF_HUB_OFFLINE=1 is baked into the image and MUST stay set for serving --
  # it is what stops the front-end reaching for a tokenizer at request time.
  # Override it for this command only. Without this the download fails even
  # against a valid repo, which is exactly how the first build of this feature
  # behaved until the failure-path test caught it.
  if ! HF_HUB_OFFLINE=0 hf download "$HALOGEN_DOWNLOAD" --local-dir "$dir"; then
    echo "halogen: download FAILED. Nothing was started." >&2
    echo "  Re-run to resume, or fetch it yourself and mount it." >&2
    exit 1
  fi

  # Verify rather than trust: a failed transfer can leave a plausible-looking
  # tree, and an engine that starts on a truncated checkpoint fails much later
  # and much more confusingly than one that refuses here.
  if [ ! -f "$HALOGEN_CHECKPOINT" ]; then
    echo "halogen: download finished but $HALOGEN_CHECKPOINT is still missing." >&2
    echo "  The repo layout may not match HALOGEN_CHECKPOINT. Contents:" >&2
    ls -la "$dir" >&2
    exit 1
  fi
  echo "halogen: download complete ($(du -h "$HALOGEN_CHECKPOINT" | cut -f1))"
}

# 0.6.0: THE SIDECAR CHANGED UNDER THE SAME NAME. It gained the draft head's
# 18 dense projections at 8 bits (2.31 -> 2.40 GiB; the 723 tensors it already
# carried are byte-identical). An install that downloaded before 0.6.0 has the
# older file, which runs, with the draft head at 4 bits: about 4% of decode on
# prose, nothing on correctness. maybe_download() never re-fetches once the
# checkpoint exists, which is right for 115 GiB and wrong for a 2.4 GiB file
# that moved, so this checks the sidecar's own table for the head's entries
# (the entry table is the first ~120 KB of the file) and, when HALOGEN_DOWNLOAD
# names the repo and the volume is writable, fetches just that file; otherwise
# it says what is missing and how to get it. A fetch that changes nothing (the
# Hub not yet carrying the new file, or a transient failure) leaves the file on
# disk in place and the server starts on it.
# 0.7.0, public issue #47 (Biggles10-claude): this was `head -c 262144 "$1" |
# grep -aq PAT` under `set -o pipefail`. The marker sits at byte 115,944 of
# the published sidecar, past the pipe buffer, so grep exited on the match,
# head died of SIGPIPE (141), the pipeline's status was head's, and the
# function returned FALSE on the current file: every 0.6.0+ start printed
# the "predates 0.6.0" note, and HALOGEN_DOWNLOAD with a writable volume
# fetched the sidecar again on every start. A `producer | grep -q` under
# pipefail is that shape whenever the match precedes the producer's end;
# the producer goes in a process substitution instead, so the status is
# grep's alone.
sidecar_is_current() {
  grep -aq "mtp.fc_hidden.weight" <(head -c 262144 "$1")
}
update_sidecar() {
  local side="$1"
  sidecar_is_current "$side" && return 0
  local dir; dir="$(dirname "$side")"
  if [ -n "${HALOGEN_DOWNLOAD:-}" ] && [ -w "$dir" ]; then
    echo "halogen: the quality sidecar predates 0.6.0 (the draft head's 8-bit projections are absent)."
    echo "halogen: fetching the current $(basename "$side") from $HALOGEN_DOWNLOAD (2.4 GiB)"
    if HF_HUB_OFFLINE=0 hf download "$HALOGEN_DOWNLOAD" "$(basename "$side")" --local-dir "$dir" \
       && sidecar_is_current "$side"; then
      echo "halogen: sidecar updated ($(du -h "$side" | cut -f1))"
      return 0
    fi
    echo "halogen: the sidecar on disk is unchanged (the fetch failed or the repo still carries the older file); starting on it." >&2
  fi
  echo "halogen: NOTE: the quality sidecar predates 0.6.0, so the draft head runs at 4 bits" >&2
  echo "  (about 4% of decode on prose; answers are unaffected). To update it, fetch" >&2
  echo "  $(basename "$side") from the weights repo into the models volume, or start" >&2
  echo "  once with HALOGEN_DOWNLOAD set and the volume mounted read-write." >&2
}

# THE BAKED TUNING PLAN IS READ FROM A COPY, so the engine's exit cannot
# rewrite it. `~Matmul` writes the plan back at a clean exit whenever a served
# GEMM shape fell outside the baked buckets, and until 0.11.9 no container
# had ever let the engine exit cleanly (the runtime ended it with the pid
# namespace, the errexit above), so the file the image ships had never moved
# under use. With the takedown written out it did, in the release gate:
# after a `podman restart` the plan's size and mtime had changed, the prompt
# cache on disk fingerprints the plan by both, and the restart's restore
# missed with a fresh lineage beside the old one. The published plan is a
# blessed measurement (478 buckets, one sha), not a scratch file; a copy
# with its mtime kept (`cp -p`) reads identically, fingerprints identically
# across restarts, and takes the write instead. A tuning run that names its
# own file (the regeneration recipe) is untouched: only the baked path is
# redirected.
tuning_plan_copy() {
  local baked=/opt/halogen/flash-tune.plan
  [ "${HALOGEN_MATMUL_TUNING_FILE:-}" = "$baked" ] || return 0
  [ -r "$baked" ] || return 0
  if cp -p "$baked" /tmp/halogen-tune.plan 2>/dev/null; then
    export HALOGEN_MATMUL_TUNING_FILE=/tmp/halogen-tune.plan
  else
    echo "halogen: could not copy the tuning plan to /tmp; the engine reads the baked file and may rewrite it at exit" >&2
  fi
}

need_ckpt() {
  maybe_download
  tuning_plan_copy
  [ -f "$HALOGEN_CHECKPOINT" ] || {
    echo "halogen: no checkpoint at $HALOGEN_CHECKPOINT" >&2
    echo "  mount it:  -v /path/to/models:/models:ro" >&2
    echo "  or point:  -e HALOGEN_CHECKPOINT=/models/<file>.hgn (or any shard of a GGUF)" >&2
    exit 1; }
  if is_gguf; then check_gguf; else check_sidecar; fi
  check_vision
  kv_budget_note
  gtt_note
}

# 0.7.0: BRING YOUR OWN GGUF. HALOGEN_CHECKPOINT may name a llama.cpp GGUF
# of this model (any shard of a split; the engine finds the siblings by
# name). The engine repacks it into RAM at every start, losslessly, reads
# its lookup table from the file in place, and takes its MTP head from the
# engine's own head file, `qwen38-flash-next-mtp.hgn` (1.4 GiB, on the
# weights repo), which this resolves the way the quality sidecar is: beside
# the checkpoint by default, HALOGEN_MTP_HEAD to point elsewhere, fetched
# with HALOGEN_DOWNLOAD when the volume is writable. Without it the engine
# cannot start on a GGUF, and it says so here rather than after the repack.
# The quality sidecar does not apply to a GGUF trunk (its tensors are the
# engine's own checkpoint's), so check_sidecar is not run.
is_gguf_path() { case "$HALOGEN_CHECKPOINT" in *.gguf) return 0;; esac; return 1; }
is_gguf() {
  [ -f "$HALOGEN_CHECKPOINT" ] && [ "$(head -c 4 "$HALOGEN_CHECKPOINT" 2>/dev/null)" = "GGUF" ]
}
# The draft head a GGUF trunk runs with (and `convert` folds in): beside the
# GGUF, or HALOGEN_MTP_HEAD, or fetched from HALOGEN_DOWNLOAD. Exports
# HALOGEN_MTP_HEAD. $1 = the GGUF's directory.
need_head() {
  local dir="$1"
  local head="${HALOGEN_MTP_HEAD:-$dir/qwen38-flash-next-mtp.hgn}"
  if [ ! -f "$head" ]; then
    if [ -n "${HALOGEN_DOWNLOAD:-}" ] && [ -w "$dir" ]; then
      echo "halogen: fetching the draft head $(basename "$head") from $HALOGEN_DOWNLOAD (1.4 GiB)"
      HF_HUB_OFFLINE=0 hf download "$HALOGEN_DOWNLOAD" "$(basename "$head")" --local-dir "$dir" || true
    fi
    [ -f "$head" ] || {
      echo "halogen: no draft head at $head" >&2
      echo "  A GGUF trunk needs the engine's MTP head file, qwen38-flash-next-mtp.hgn (1.4 GiB)," >&2
      echo "  from the weights repo. Put it beside the GGUF, point HALOGEN_MTP_HEAD at it, or start" >&2
      echo "  once with HALOGEN_DOWNLOAD set and the models volume mounted read-write." >&2
      exit 1; }
  fi
  # 0.11.10 (issue #20): a llama.cpp MTP draft GGUF beside a third-party
  # quantization is not the engine's head file; the engine would refuse it
  # after the repack. Say so here, in 2 s, and name the file that is.
  if [ "$(head -c 4 "$head" 2>/dev/null)" != "HGN1" ]; then
    echo "halogen: HALOGEN_MTP_HEAD=$head is not the engine's draft head file (its first bytes are not HGN1)." >&2
    echo "  A GGUF draft head (…-MTP-draft.gguf, llama.cpp's) is not read by this engine. The head it runs is" >&2
    echo "  its own qwen38-flash-next-mtp.hgn (1.4 GiB) from the weights repo: put it beside the GGUF, point" >&2
    echo "  HALOGEN_MTP_HEAD at it, or start once with HALOGEN_DOWNLOAD set and the models volume read-write." >&2
    exit 1
  fi
  export HALOGEN_MTP_HEAD="$head"
  echo "halogen: draft head $head ($(du -h "$head" | cut -f1))"
}
check_gguf() {
  local dir; dir="$(dirname "$HALOGEN_CHECKPOINT")"
  echo "halogen: $HALOGEN_CHECKPOINT is a GGUF: it is repacked into RAM at startup, losslessly, on every start"
  echo "         (about 20 s from a cold NVMe disk on the reference machine, 9 s warm; HALOGEN_GGUF_CACHE=1 keeps"
  echo "         a copy beside it and a warm restart is then about 1 s; \`convert\` writes it as a standalone .hgn)"
  echo "         and served with the engine's own draft head. The quality sidecar does not apply to a GGUF trunk."
  need_head "$dir"
  case "${HALOGEN_GGUF_CACHE:-}" in
    ""|0) : ;;
    1) echo "halogen: HALOGEN_GGUF_CACHE=1: the repack is written once beside the GGUF (about 70 GiB for an 8-bit trunk) and read on later starts" ;;
    *) [ -d "$HALOGEN_GGUF_CACHE" ] && [ -w "$HALOGEN_GGUF_CACHE" ] || {
         echo "halogen: HALOGEN_GGUF_CACHE=$HALOGEN_GGUF_CACHE is not a writable directory" >&2; exit 1; }
       echo "halogen: HALOGEN_GGUF_CACHE: the repack is written once to $HALOGEN_GGUF_CACHE (about 70 GiB for an 8-bit trunk) and read on later starts" ;;
  esac
  # A GGUF-only volume has no tokenizer directory; the weights repo's is
  # small and the same Qwen tokenizer, so fetch it when asked and allowed.
  if [ ! -f "$HALOGEN_TOKENIZER/tokenizer.json" ] && [ ! -f "$dir/tokenizer/tokenizer.json" ] \
     && [ -n "${HALOGEN_DOWNLOAD:-}" ] && [ -w "$dir" ]; then
    echo "halogen: fetching the tokenizer from $HALOGEN_DOWNLOAD"
    HF_HUB_OFFLINE=0 hf download "$HALOGEN_DOWNLOAD" --include "tokenizer/*" --local-dir "$dir" || true
  fi
}

# VISION IS OFF UNTIL A PATH IS GIVEN, and that is the feature's whole safety
# property: with HALOGEN_VISION_TOWER unset the tower is never constructed,
# allocates nothing, and every image path is unreachable, so a text server is
# byte-identical to a build without any of it. This does NOT turn it on by
# finding a file, because a default that switches on when a volume happens to
# contain something is not a default anyone chose.
#
# What it does is make the three ways to get it wrong LOUD instead of silent:
# a path that does not exist (the engine would refuse later, after minutes of
# loading), the value `1`/`auto` from someone who expected a discovery
# feature, and a tower sitting unused beside the checkpoint.
check_vision() {
  local side="$(dirname "$HALOGEN_CHECKPOINT")/qwen38-flash-next-vision.hgn"
  case "${HALOGEN_VISION_TOWER:-}" in
    "")
      if [ -f "$side" ]; then
        echo "halogen: a vision sidecar is present but NOT loaded: $side"
        echo "         set HALOGEN_VISION_TOWER=$side to accept images."
      fi
      return 0 ;;
    1|auto|yes|true)
      # A convenience, and it says what it resolved to rather than guessing
      # silently.
      [ -f "$side" ] || {
        echo "halogen: HALOGEN_VISION_TOWER=${HALOGEN_VISION_TOWER} but there is no sidecar at $side" >&2
        echo "  give the full path, or fetch the file (0.84 GiB) beside the checkpoint" >&2
        exit 1; }
      export HALOGEN_VISION_TOWER="$side"
      echo "halogen: vision ON, tower $side (resolved from HALOGEN_VISION_TOWER=1)" ;;
    *)
      [ -f "$HALOGEN_VISION_TOWER" ] || {
        echo "halogen: HALOGEN_VISION_TOWER=$HALOGEN_VISION_TOWER does not exist." >&2
        echo "  It is the vision sidecar (0.84 GiB), converted by tools/convert_vision.py" >&2
        echo "  and normally mounted beside the checkpoint." >&2
        exit 1; }
      echo "halogen: vision ON, tower $HALOGEN_VISION_TOWER ($(du -h "$HALOGEN_VISION_TOWER" | cut -f1))" ;;
  esac
  # An image is 240-8,160 LM tokens depending on its size, so it competes with
  # the prompt for the same context. Say it once, here, rather than leaving it
  # to be discovered by a refusal.
  echo "         an image costs ~1,000 tokens at 1280x800 and ~2,040 at 1080p;"
  echo "         HALOGEN_VISION_MAX_PIXELS caps it (default 2560x1440; larger is downscaled)."
}

# THE SERVED CHECKPOINT IS TWO FILES. `<ck>.overlay.hgn` is the
# quality sidecar (2.31 GiB) and the engine loads it automatically when it sits
# beside the checkpoint, so a models volume holding both Just Works, and one
# holding only the base file also starts, ~6-9% worse on perplexity, saying so
# in ONE line of startup output nobody reads. That silence is the whole reason
# for this check: a missing 2.31 GiB file must not be discoverable only by
# measuring quality.
#
# It WARNS rather than fails. `HALOGEN_CK_OVERLAY=none` is a legitimate
# configuration (the measurement control), and so is choosing not to download
# the sidecar.
check_sidecar() {
  case "${HALOGEN_CK_OVERLAY:-}" in
    none|0)
      echo "halogen: HALOGEN_CK_OVERLAY=${HALOGEN_CK_OVERLAY}, so the BARE checkpoint runs."
      echo "         That is the measurement control, not the shipped precision."
      return 0 ;;
    "") : ;;                       # default: the sidecar beside the checkpoint
    *)  [ -f "$HALOGEN_CK_OVERLAY" ] || {
          echo "halogen: HALOGEN_CK_OVERLAY=$HALOGEN_CK_OVERLAY does not exist." >&2
          exit 1; }
        echo "halogen: overlay $HALOGEN_CK_OVERLAY"
        return 0 ;;
  esac
  local side="${HALOGEN_CHECKPOINT%.hgn}.overlay.hgn"
  # 0.12.1: a `convert`ed GGUF trunk carries the GGUF model id in its header
  # (bytes 40..103 of the .hgn); the sidecar is the w4b checkpoint's and
  # does not apply to it, so the warning below would be wrong here.
  local mid; mid="$(head -c 104 "$HALOGEN_CHECKPOINT" 2>/dev/null | tail -c 64 | tr -d '\0')"
  case "$mid" in *gguf*)
    echo "halogen: $HALOGEN_CHECKPOINT is a converted GGUF trunk (model id $mid): the quality sidecar does not apply and none is looked for"
    return 0 ;;
  esac
  if [ -f "$side" ]; then
    echo "halogen: quality sidecar present ($(du -h "$side" | cut -f1)) at $side"
    update_sidecar "$side"
  else
    echo "halogen: WARNING: no sidecar at $side" >&2
    echo "  The engine will run the BARE 4-bit checkpoint: about 6-9% worse" >&2
    echo "  perplexity than the shipped precision, for about" >&2
    echo "  2% faster decode. If that is not what you meant, fetch the sidecar" >&2
    echo "  alongside the checkpoint; it is 2.31 GiB." >&2
  fi
}

need_tokenizer() {
  # Must be a FLAT dir. HF cache snapshots are symlinks into a sibling blobs/,
  # which dangle inside a container that mounts only the snapshot.
  # The weights repo ships the tokenizer INSIDE it, so a user who mounts only
  # the models volume has one already. Falling back to it removes the second
  # `-v` from the launch command and the whole class of "I forgot the
  # tokenizer mount" first-run failures. An explicit HALOGEN_TOKENIZER still
  # wins; this only fires when the default path is empty and the fallback is
  # real, so it can never silently pick a WRONG tokenizer over a right one.
  if [ ! -f "$HALOGEN_TOKENIZER/tokenizer.json" ] &&
     [ "$HALOGEN_TOKENIZER" = /tokenizer ] &&
     [ -f "$(dirname "$HALOGEN_CHECKPOINT")/tokenizer/tokenizer.json" ]; then
    HALOGEN_TOKENIZER="$(dirname "$HALOGEN_CHECKPOINT")/tokenizer"
    echo "halogen: no /tokenizer mount, using $HALOGEN_TOKENIZER from the models volume"
  fi
  [ -f "$HALOGEN_TOKENIZER/tokenizer.json" ] || {
    echo "halogen: no tokenizer.json in $HALOGEN_TOKENIZER" >&2
    echo "  mount the weights directory at /models (it contains tokenizer/)," >&2
    echo "  or point HALOGEN_TOKENIZER at a FLAT tokenizer dir" >&2
    echo "  (cp -L out of an HF snapshot; symlinks dangle in a container)" >&2
    exit 1; }
}

# WAIT FOR THE ENGINE'S PORT. Bounded only if the operator asks.
#
# This was `for _ in $(seq 1 900); do ...; sleep 2; done` with NO branch for
# exhaustion. At exactly 1800 s it fell out of the loop, started the front-end
# against a port nothing was listening on, the front-end exited with
# ConnectionRefusedError, and `wait -n` took the whole container down saying
# "a component exited". A user whose machine needs longer than 30 minutes to
# load therefore saw five identical deaths that read as "the server does not
# start", with the engine still loading normally underneath, and worked around
# it by running the two roles as separate containers.
#
# There is no correct fixed bound. Load time is disk read time plus the
# driver's, and both are the host's property, not ours. So the default is to
# wait, and what is watched is the engine PROCESS: if it dies, this returns at
# once, which is the failure that genuinely needs reporting. A heartbeat says
# the wait is a wait and not a hang.
#
# HALOGEN_ENGINE_WAIT_S bounds it in seconds for an orchestrator that would
# rather a container failed than waited. When that bound expires this says so
# and returns non-zero; it never starts a front-end that cannot work.
wait_for_engine() {
  local port="$1" pid="$2" log="${3:-}"
  local limit="${HALOGEN_ENGINE_WAIT_S:-0}" t=0 beat=0
  while :; do
    # THE PROBE RUNS IN A SUBSHELL, and that is not style. `exec` with no
    # command applies its redirections to the CURRENT shell permanently, so
    # the old `if exec 3<>/dev/tcp/... 2>/dev/null` sent this script's stderr
    # to /dev/null for the life of the container the moment the engine came
    # up. Verified: an `echo >&2` after a successful probe produces nothing.
    # Every warning the entrypoint had left to give was silently discarded,
    # "a component exited; shutting down" among them, which is the one line
    # that would have told the 0.3.1 reporter what killed their container.
    # A subshell also drops the descriptor for us; this is a liveness probe
    # and has nothing to read.
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
      echo "halogen: engine listening after ${t}s"
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "halogen: the engine exited after ${t}s without listening." >&2
      [ -n "$log" ] && [ -f "$log" ] && tail -30 "$log" >&2
      return 1
    fi
    if [ "$limit" -gt 0 ] && [ "$t" -ge "$limit" ]; then
      echo "halogen: HALOGEN_ENGINE_WAIT_S=${limit} expired after ${t}s and the engine is STILL LOADING (pid $pid is alive)." >&2
      echo "  Nothing is wrong with it yet. Raise or unset HALOGEN_ENGINE_WAIT_S to keep waiting;" >&2
      echo "  0 or unset means wait as long as the load takes." >&2
      [ -n "$log" ] && [ -f "$log" ] && tail -30 "$log" >&2
      return 1
    fi
    sleep 2; t=$((t + 2)); beat=$((beat + 2))
    if [ "$beat" -ge 60 ]; then
      beat=0
      echo "halogen: still loading, ${t}s elapsed (the engine is alive, state $(wd_state "$pid"); GTT in use $(wd_gtt_gib) GiB; the startup lines above name the step)"
    fi
  done
}

# THE WEDGE WATCHDOG. A container whose engine is ALIVE and answering nothing
# is the failure that was reported, and it is invisible to everything else
# here: the process is up, so `wait -n` never fires; the port accepts, so a
# connect-based healthcheck stays green; and the front-end goes on returning
# 5xx after its own long timeouts. Reproduced on the shipped 0.4.4 image by
# stopping the engine with SIGSTOP, which is what an aborted GPU queue looks
# like from outside: healthcheck green, /health "ok", every request hung.
#
# PING is the discriminator, because the engine answers it between decode
# rounds and, since 0.5.2, every HALOGEN_ENGINE_YIELD_MS while a prompt is
# being read in, whatever its length. Before that it was answered only at a
# prefill chunk boundary, and a prompt shorter than one chunk has none, so an
# ordinary prompt on a slow host could trip this while the engine was working
# correctly. Silence for
# HALOGEN_ENGINE_WATCHDOG_S (default 180) therefore means wedged, not slow --
# an order of magnitude above the ~14 s a 16k prefill chunk can take in 1M
# mode. Taking the container down is the point: a restart policy can recover
# a container, and nothing can recover a wedged engine in place.
#
# 0 disables it. The engine's own SIGTERM path is used, so a clean shutdown
# still writes what it writes.
#
# PUBLIC ISSUE #79 (and #35 before it): SILENCE INSIDE THE KERNEL IS NOT A
# WEDGE, AND KILLING IT IS WHAT WEDGES THE DRIVER. On a host short of
# contiguous memory the engine stops for minutes at a time inside a page
# fault or an allocation while the kernel compacts memory for it: 100% of
# one core, no output, no PING, and it clears on its own (#35's reporter
# watched the silence reach 135 s and the engine come back, six times). The
# text below said "this is a slow host and not a wedge" and then took the
# container down anyway. On #79's host that kill landed twice on a process
# with 66 GiB registered with the GPU while the driver had work in flight,
# and left the driver holding the memory with no process alive: every later
# start hung at "reserving the KV pool" until a reboot, the end state three
# other hosts reached by other unclean exits (#34's two machines, this
# project's own gate box). So the watchdog reads two
# things the container can see before it counts a silent probe: the
# engine's threads' states in /proc (a task in D is inside the kernel and
# cannot answer anything), and the kernel's own compaction counter in
# /proc/vmstat (compact_stall climbing while the engine is silent is the
# stall the startup note describes). Silence under either is logged and NOT
# counted: a wedged engine on a quiet host is taken down at the same 180 s
# as before, and an engine that comes back from a stall is never killed for
# it. What this could not see until 0.12.3 was a wedge on a host where
# memory is compacted without pause: the counter is host-wide, so the
# deferral never ended (#71's second reporter, 30 minutes, container Up).
# 0.12.3 bounds it: HALOGEN_ENGINE_WATCHDOG_DEFER_S (900) of deferred silence
# with the threads running and not in D is the wedge, counter or no counter.
wd_state() {
  # The worst state among the engine's tasks: D if any is in uninterruptible
  # sleep, else the main thread's. The comm field can contain spaces, so
  # the state is read after the last ')'.
  local proc="${_hg_proc:-/proc}" pid="$1" f st main="?"
  for f in "$proc/$pid/task/"*/stat; do
    [ -r "$f" ] || continue
    st=$(sed 's/.*) //' "$f" 2>/dev/null | cut -d' ' -f1 || true)
    [ "$st" = "D" ] && { echo D; return 0; }
    [ "${f%/stat}" = "$proc/$pid/task/$pid" ] && main="$st"
  done
  echo "$main"
}
wd_compact() {
  local proc="${_hg_proc:-/proc}"
  awk '/^compact_stall /{print $2; exit}' "$proc/vmstat" 2>/dev/null || true
}
wd_gtt_gib() {
  local sys="${_hg_sys:-/sys}" f
  for f in "$sys"/class/drm/card*/device/mem_info_gtt_used; do
    [ -r "$f" ] || continue
    awk -v u="$(cat "$f" 2>/dev/null || echo 0)" 'BEGIN{printf "%.1f", u/1073741824}' || true
    return 0
  done
  echo "?"
}
# THE TAKEDOWN, WRITTEN OUT. Found by 0.11.9's own release gate: under `set -e` the
# `wait -n` below returned the watchdog's 1 (or a crashed engine's status)
# and the script EXITED THERE, so "a component exited; shutting down", the
# SIGTERM to the engine, and everything after it had never once run on a
# non-zero exit; the runtime ended the engine with the pid namespace. This
# is the path instead: SIGTERM and the engine's own exit, 30 s, then SIGKILL,
# 30 s, then say what is left. A wedged engine's accept loop never reads the
# flag its handler sets, so the SIGKILL is the one that lands; an engine in
# D ignores both, and the line says so and names the reboot (issue #79). A
# child that has exited is a zombie until reaped and `kill -0` still
# succeeds on it, so liveness is the state in /proc, not the signal.
# Liveness is the MAIN thread's state, not the worst thread's: after SIGKILL
# the other threads sit in D for a moment while the kernel releases 66 GiB of
# registrations, and the worst-state read (which is what the watchdog wants)
# called a dying engine "still alive, state D" at 0 s (found by hand while
# 0.11.9 was gated). A zombie main thread is reaped by `wait`, not alive.
wd_main_state() {
  local f="${_hg_proc:-/proc}/$1/task/$1/stat"
  [ -r "$f" ] || { echo "?"; return 0; }
  sed 's/.*) //' "$f" 2>/dev/null | cut -d' ' -f1 || echo "?"
}
wd_alive() { [ -d "${_hg_proc:-/proc}/$1" ] && [ "$(wd_main_state "$1")" != "Z" ]; }
# The GTT figure after an exit, read once it stops falling: the driver
# releases an engine's device memory a few seconds after the process is
# gone (18 MB within 5 s on a healthy host), and a read at 0 s is the
# engine's own figure whatever the driver is about to do. Capped at 6 s so
# a `podman stop` (10 s before its SIGKILL) still ends with this line.
wd_gtt_after_exit() {
  local t=0 g
  while [ $t -lt 6 ]; do
    g=$(wd_gtt_gib)
    case "$g" in "?") break;; esac
    awk -v g="$g" 'BEGIN{exit !(g < 1.0)}' && break
    sleep 1; t=$((t + 1))
  done
  echo "halogen: GTT in use after the engine exited: ${g:-?} GiB (${t}s after)" >&2
  if [ "${g:-?}" != "?" ] && awk -v g="$g" 'BEGIN{exit !(g >= 2.0)}'; then
    echo "halogen: WARNING the driver has not released this engine's device memory. If the figure does not fall (cat /sys/class/drm/card*/device/mem_info_gtt_used on the host), the next start will hang at \"reserving the KV pool\"; reboot the host first (issue #79)." >&2
  fi
}
stop_engine() {   # stop_engine PID -> the engine's exit status (137 if it would not die)
  local pid="$1" t=0 st rc=0
  kill -TERM "$pid" 2>/dev/null || true
  while wd_alive "$pid" && [ $t -lt 30 ]; do sleep 1; t=$((t + 1)); done
  if wd_alive "$pid"; then
    st=$(wd_state "$pid")
    echo "halogen: the engine did not exit on SIGTERM within ${t}s (state ${st}); sending SIGKILL" >&2
    kill -KILL "$pid" 2>/dev/null || true
    t=0
    while wd_alive "$pid" && [ $t -lt 30 ]; do sleep 1; t=$((t + 1)); done
  fi
  if wd_alive "$pid"; then
    echo "halogen: the engine is still alive ${t}s after SIGKILL (state $(wd_state "$pid")): it is inside the kernel and nothing in this container can end it. GTT in use now: $(wd_gtt_gib) GiB. The host needs a reboot before the next start (issue #79)." >&2
    return 137
  fi
  wait "$pid" 2>/dev/null || rc=$?
  return "$rc"
}
engine_pong() {
  ( exec 3<>"/dev/tcp/127.0.0.1/${1}" || exit 1
    printf 'PING\n' >&3 || exit 1
    read -r -t "${HALOGEN_ENGINE_PING_S:-30}" reply <&3 || exit 1
    [ "$reply" = "PONG" ] ) 2>/dev/null
}

engine_watchdog() {
  local port="$1" pid="$2"
  local limit="${HALOGEN_ENGINE_WATCHDOG_S:-180}" step=15 silent=0
  if [ "$limit" -le 0 ]; then
    echo "halogen: engine watchdog OFF (HALOGEN_ENGINE_WATCHDOG_S=$limit)"
    return 0
  fi
  echo "halogen: engine watchdog on, ${limit}s of silence takes the container down"
  # SILENCE IS COUNTED IN REAL SECONDS, not in loop iterations. A failed probe
  # also BLOCKS for the ping timeout, so counting `step` per iteration made the
  # threshold mean about three times what it says: measured 130 s to fire at a
  # 45 s setting. `last_ok` is the last time the engine actually answered.
  # 0.12.3 (public issues #71, #85): THE SILENCE CLOCK NEVER RESTARTS ON A
  # DEFERRAL. 0.11.9 set `last_ok` to now on every deferred probe, so the
  # seconds it printed were the time since the previous probe, not the
  # silence, and under compaction that never stopped the engine could never
  # be counted: one host sat wedged for 30 minutes with the container Up,
  # the main thread at 100% of a core in user space, `/health` timing out,
  # while `compact_stall` (a HOST-WIDE counter that says nothing about this
  # engine) climbed at its usual rate. Now `last_ok` moves only when the
  # engine answers, every line prints the true silence, and the compaction
  # deferral has a cap, HALOGEN_ENGINE_WATCHDOG_DEFER_S (default 900, 0 =
  # no cap): past it, an engine whose threads are running and not in the
  # kernel is a wedge whatever the counter says, and the takedown runs. A
  # thread in D still defers without a cap: SIGKILL does not reach a task
  # in D, and the kill is what leaves the driver holding its GTT (#79).
  # When a deferral ends without a PONG (the counter stops climbing) the
  # engine gets one more `limit` from that point before the wedge counts,
  # so a stall that has just cleared is not killed at its first probe.
  # `last_ok` moves only on a PONG. `deferred` is the silence so far while
  # deferred (0 = none this silence). `grace_from` is set when a deferral
  # ends without a PONG: the wedge clock counts from there, not from
  # `last_ok`, so the engine gets one `limit` after the stall clears.
  local last_ok st cs_prev cs_now deferred=0 grace_from="" defer_max="${HALOGEN_ENGINE_WATCHDOG_DEFER_S:-900}" now
  last_ok=$(date +%s)
  cs_prev=$(wd_compact)
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$step"
    if engine_pong "$port"; then
      now=$(date +%s)
      if [ "$deferred" -gt 0 ]; then
        echo "halogen: the engine answered PING again after $(( now - last_ok ))s of silence (${deferred}s of it deferred: a thread inside the kernel, or the kernel compacting memory); not a wedge, nothing was taken down" >&2
        deferred=0
      fi
      grace_from=""
      last_ok="$now"
      cs_prev=$(wd_compact)
      continue
    fi
    st=$(wd_state "$pid")
    cs_now=$(wd_compact)
    now=$(date +%s)
    if [ "$st" = "D" ] || { [ -n "$cs_now" ] && [ -n "$cs_prev" ] && [ "$cs_now" -gt "$cs_prev" ]; }; then
      grace_from=""
      deferred=$(( now - last_ok ))
      if [ "$st" = "D" ]; then
        echo "halogen: the engine has not answered PING for ${deferred}s: a thread is in uninterruptible sleep (state D, inside the kernel). Not counted as a wedge; this is the host short of memory, and killing the engine here is what leaves the driver holding its memory (issue #79)." >&2
      elif [ "$defer_max" -gt 0 ] && [ "$deferred" -ge "$defer_max" ]; then
        echo "halogen: the engine has answered nothing for ${deferred}s while the kernel's compaction counter kept climbing (compact_stall +$(( cs_now - cs_prev )) since the last probe), past HALOGEN_ENGINE_WATCHDOG_DEFER_S=${defer_max}." >&2
        echo "  That counter is host-wide and says nothing about this engine; its threads are running (state ${st}), not inside the kernel, so this is a wedge under memory pressure, not a stall that will clear (issue #85). GTT in use now: $(wd_gtt_gib) GiB." >&2
        echo "  Shutting the container down so a restart policy can recover it. Free host memory, or give this server a machine of its own; if the next start hangs at 'reserving the KV pool', read its 'GTT in use before this start' line (issue #79)." >&2
        return 1
      else
        echo "halogen: the engine has not answered PING for ${deferred}s: the kernel is compacting host memory (compact_stall +$(( cs_now - cs_prev )) since the last probe). Not counted as a wedge yet; it clears when the compaction does, and past ${defer_max}s of this it is taken down (HALOGEN_ENGINE_WATCHDOG_DEFER_S). Free host memory, or give this server a machine of its own." >&2
      fi
      cs_prev="$cs_now"
      continue
    fi
    cs_prev="$cs_now"
    if [ "$deferred" -gt 0 ] && [ -z "$grace_from" ]; then
      grace_from="$now"
      echo "halogen: the compaction stopped after ${deferred}s of deferred silence and the engine has not answered; counting from here (${limit}s to the takedown)" >&2
      continue
    fi
    silent=$(( now - ${grace_from:-$last_ok} ))
    echo "halogen: the engine has not answered PING for ${silent}s (engine state ${st}, no compaction in progress)" >&2
    if [ "$silent" -ge "$limit" ]; then
      echo "halogen: the engine process is alive and has answered nothing for ${silent}s." >&2
      echo "  PING is answered between decode rounds, between the layers of a prefill, and" >&2
      echo "  while the lookup table is being read. Its threads are not inside the kernel" >&2
      echo "  and the kernel is not compacting memory for it, so this is a wedge, not a" >&2
      echo "  stall. GTT in use now: $(wd_gtt_gib) GiB." >&2
      echo "  Shutting the container down so a restart policy can recover it. If the next" >&2
      echo "  start hangs at 'reserving the KV pool', read its 'GTT in use before this" >&2
      echo "  start' line: memory the driver kept after this kill needs a host reboot" >&2
      echo "  (issue #79). Please report it with this log." >&2
      return 1
    fi
  done
  return 0
}

start_engine() {
  need_ckpt
  # NOT `exec` any more: something has to outlive the engine to watch it.
  # SIGTERM is forwarded so the daemon still takes its own exit path.
  /usr/local/bin/flash_serve \
    --ck "$HALOGEN_CHECKPOINT" --port "$ENG_PORT" --bind "$BIND" \
    --slots "$ENG_SLOTS" --ctx "$ENG_CTX" --max-tok "$ENG_MAX_TOK" --kv-pool "$ENG_POOL" &
  ENGINE_PID=$!
  trap 'kill -TERM "$ENGINE_PID" 2>/dev/null || true' TERM INT
  if ! wait_for_engine "$ENG_PORT" "$ENGINE_PID"; then
    kill -TERM "$ENGINE_PID" 2>/dev/null || true
    wait "$ENGINE_PID" 2>/dev/null || true
    exit 1
  fi
  # A DISABLED WATCHDOG MUST NOT BE IN THE WAIT SET. It returns immediately
  # when the limit is 0, so `wait -n` saw a component exit and took the
  # container down at once: the documented way to turn this OFF killed the
  # server. Found by running with it off, which no cell did.
  WATCHDOG_PID=""
  if [ "${HALOGEN_ENGINE_WATCHDOG_S:-180}" -gt 0 ]; then
    engine_watchdog "$ENG_PORT" "$ENGINE_PID" &
    WATCHDOG_PID=$!
  else
    echo "halogen: engine watchdog OFF (HALOGEN_ENGINE_WATCHDOG_S=0)"
  fi
  # ERREXIT OFF FROM HERE: this is a supervisor, and every status below is
  # data (which child ended, how the engine died, whether a kill found its
  # target), not a reason to stop. Under `set -e` the `wait -n` alone had
  # ended the script on any non-zero status since 0.4.4, and a `kill` on an
  # already-gone watchdog did the same once that was fixed; the `|| true`s
  # stay as documentation of each, this is the rule.
  set +e
  # shellcheck disable=SC2086
  WRC=0; wait -n "$ENGINE_PID" $WATCHDOG_PID 2>/dev/null || WRC=$?
  # `|| true` because this follows the final `&&`: when the watchdog is the
  # component that exited, its pid is gone, the kill fails, and under
  # `set -e` a failing command after the last `&&` ends the script (found
  # by the 0.11.9 release gate, the second errexit in this path).
  [ -n "$WATCHDOG_PID" ] && kill -9 "$WATCHDOG_PID" 2>/dev/null || true
  # Reap it here, or bash prints "Killed engine_watchdog" into every clean
  # stop's log when it notices later.
  [ -n "$WATCHDOG_PID" ] && wait "$WATCHDOG_PID" 2>/dev/null || true
  RC=0; stop_engine "$ENGINE_PID" || RC=$?
  echo "halogen: engine exited (rc=$RC, the component that ended this: $WRC); shutting down" >&2
  wd_gtt_after_exit
  [ "$RC" -ne 0 ] && exit "$RC"
  exit "$WRC"
}

# PUBLIC ISSUE #30: the HALOGEN_* request defaults (HALOGEN_TEMPERATURE,
# HALOGEN_TOP_P, HALOGEN_MAX_TOKENS_DEFAULT, HALOGEN_REASONING_EFFORT, ...)
# are read by serve_api.py, which refuses to start on a bad value. Ask it
# HERE, before the engine spends minutes pinning the checkpoint, so that a
# typo in a variable is found in a second. One implementation of the rules,
# used early; a bash copy of them would drift.
check_defaults() {
  if ! python3 /halogen/tools/serve_api.py --tokenizer "$HALOGEN_TOKENIZER" \
       --max-tokens-cap "${HALOGEN_MAX_TOKENS_CAP:-65536}" --check-defaults; then
    echo "halogen: a HALOGEN_* request default is invalid (see above); not starting" >&2
    exit 1
  fi
}

start_api() {
  need_tokenizer
  check_defaults
  # HALOGEN_ENGINE must be settable. In `all` the engine is in this same
  # container and loopback is right, but in the two-container topology
  # (docker-compose) the services get SEPARATE network namespaces and the
  # api has to reach `engine:8730` by name. Hardcoding 127.0.0.1 here made
  # `api` mode silently unusable for exactly the deployment the split exists
  # to serve, found by writing the compose file rather than by testing.
  exec python3 /halogen/tools/serve_api.py \
    --tokenizer "$HALOGEN_TOKENIZER" \
    --engine "${HALOGEN_ENGINE:-127.0.0.1:$ENG_PORT}" \
    --host 0.0.0.0 --port "$API_PORT" \
    --max-tokens-cap "${HALOGEN_MAX_TOKENS_CAP:-65536}" \
    --queue-timeout "${HALOGEN_QUEUE_TIMEOUT:-3600}"
}

# The FIRST line of every mode names the release and
# the role. Two containers four releases apart ran side by side for weeks and
# neither log said a version, so a careful reader posting both had no way to
# see the split; the api one predated the image path the engine one had, and
# every picture was answered from nothing.
# The tool modes keep stdout for their own output (`--json` is one object a
# script reads), so their release line goes to stderr.
case "${1:-all}" in
  inspect|verify|ppl|niah) echo "halogen: halogen-flash-server ${HALOGEN_IMAGE_VERSION:-unknown}, mode $1" >&2 ;;
  *) echo "halogen: halogen-flash-server ${HALOGEN_IMAGE_VERSION:-unknown}, mode ${1:-all}" ;;
esac

case "${1:-all}" in
engine) start_engine ;;
api)    start_api ;;
all)
  need_ckpt; need_tokenizer; check_defaults
  /usr/local/bin/flash_serve --ck "$HALOGEN_CHECKPOINT" \
      --port "$ENG_PORT" --bind 127.0.0.1 \
      --slots "$ENG_SLOTS" --ctx "$ENG_CTX" --max-tok "$ENG_MAX_TOK" --kv-pool "$ENG_POOL" &
  ENGINE_PID=$!
  trap 'kill -TERM "$ENGINE_PID" 2>/dev/null || true' TERM INT

  # The front-end connects to the engine at STARTUP and exits on refusal, so
  # it must not launch first. A cold 115.4 GiB checkpoint faults in slowly when
  # it is not already in page cache, measured longer than any fixed sleep is
  # willing to wait, which is why this polls instead of sleeping.
  echo "halogen: waiting for engine on $ENG_PORT (cold load can take minutes)"
  if ! wait_for_engine "$ENG_PORT" "$ENGINE_PID"; then
    kill -TERM "$ENGINE_PID" 2>/dev/null || true
    wait "$ENGINE_PID" 2>/dev/null || true
    exit 1
  fi

  python3 /halogen/tools/serve_api.py \
    --tokenizer "$HALOGEN_TOKENIZER" \
    --engine "127.0.0.1:$ENG_PORT" \
    --host 0.0.0.0 --port "$API_PORT" \
    --max-tokens-cap "${HALOGEN_MAX_TOKENS_CAP:-65536}" \
    --queue-timeout "${HALOGEN_QUEUE_TIMEOUT:-3600}" &
  API_PID=$!

  # Either process exiting must take the container down. A live API in front
  # of a dead engine answers 200 + zero bytes, which is indistinguishable
  # from a hang on the client side.
  # The watchdog joins the set: a process that EXITS is caught by `wait -n`
  # (measured: the container is down in under a second), and a process that
  # lives and answers nothing is caught by this.
  WATCHDOG_PID=""
  if [ "${HALOGEN_ENGINE_WATCHDOG_S:-180}" -gt 0 ]; then
    engine_watchdog "$ENG_PORT" "$ENGINE_PID" &
    WATCHDOG_PID=$!
  else
    echo "halogen: engine watchdog OFF (HALOGEN_ENGINE_WATCHDOG_S=0)"
  fi
  # Errexit off from here: a supervisor's statuses are data (see start_engine).
  set +e
  # shellcheck disable=SC2086
  WRC=0; wait -n "$ENGINE_PID" "$API_PID" $WATCHDOG_PID || WRC=$?
  echo "halogen: a component exited (rc=$WRC); shutting down" >&2
  kill -TERM "$API_PID" 2>/dev/null || true
  # `|| true` because this follows the final `&&`: when the watchdog is the
  # component that exited, its pid is gone, the kill fails, and under
  # `set -e` a failing command after the last `&&` ends the script (found
  # by the 0.11.9 release gate, the second errexit in this path).
  [ -n "$WATCHDOG_PID" ] && kill -9 "$WATCHDOG_PID" 2>/dev/null || true
  # Reap it here, or bash prints "Killed engine_watchdog" into every clean
  # stop's log when it notices later.
  [ -n "$WATCHDOG_PID" ] && wait "$WATCHDOG_PID" 2>/dev/null || true
  stop_engine "$ENGINE_PID" || true
  wait "$API_PID" 2>/dev/null || true
  # Issue #79: the figure the next start's "GTT in use before this start"
  # line will read. A driver that kept this engine's memory shows here
  # first, while the log that explains it is still the same log.
  wd_gtt_after_exit
  exit 1
  ;;
bench|sweep)
  MODE="$1"
  shift || true
  need_ckpt; need_tokenizer; check_defaults
  BENCH_LOG=/tmp/halogen-api.log
  : > "$BENCH_LOG"

  /usr/local/bin/flash_serve --ck "$HALOGEN_CHECKPOINT" \
      --port "$ENG_PORT" --bind 127.0.0.1 \
      --slots "$ENG_SLOTS" --ctx "$ENG_CTX" --max-tok "$ENG_MAX_TOK" --kv-pool "$ENG_POOL" \
      > /tmp/halogen-engine.log 2>&1 &
  ENGINE_PID=$!
  trap 'kill -TERM "$ENGINE_PID" 2>/dev/null || true' TERM INT EXIT

  echo "halogen bench: loading model (cold load can take minutes)"
  wait_for_engine "$ENG_PORT" "$ENGINE_PID" /tmp/halogen-engine.log || exit 1

  # The api's stdout is TEED, not just redirected: the ledger lines the bench
  # scrapes for commit/round and prefill only exist in this stream, and a
  # bench that silently lost them would still print a t/s table.
  python3 /halogen/tools/serve_api.py \
    --tokenizer "$HALOGEN_TOKENIZER" \
    --engine "127.0.0.1:$ENG_PORT" \
    --host 127.0.0.1 --port "$API_PORT" \
    --max-tokens-cap "${HALOGEN_MAX_TOKENS_CAP:-65536}" \
    --queue-timeout "${HALOGEN_QUEUE_TIMEOUT:-3600}" 2>&1 | tee "$BENCH_LOG" &
  API_PID=$!

  # python, not curl: the slim base has no curl and a bench that silently
  # skipped its readiness wait would just fail the first request instead.
  API_UP=0
  for _ in $(seq 1 150); do
    python3 -c "import urllib.request,sys
try: urllib.request.urlopen('http://127.0.0.1:$API_PORT/health', timeout=3); sys.exit(0)
except Exception: sys.exit(1)" 2>/dev/null && { API_UP=1; break; }
    kill -0 "$API_PID" 2>/dev/null || break
    sleep 2
  done
  # Same defect as the engine wait, one layer up: this used to fall through
  # silently and the bench then failed on its first request, which reads as a
  # broken benchmark rather than a front-end that never came up.
  if [ "$API_UP" -eq 0 ]; then
    echo "halogen bench: the front-end never answered /health on $API_PORT after 300s." >&2
    tail -30 "$BENCH_LOG" >&2 || true
    kill -TERM "$API_PID" "$ENGINE_PID" 2>/dev/null || true
    exit 1
  fi

  if [ "$MODE" = sweep ]; then
    python3 /halogen/tools/halogen-bench.py \
      --api "http://127.0.0.1:$API_PORT" "$@"
  else
    HALOGEN_API="http://127.0.0.1:$API_PORT" HALOGEN_API_LOG="$BENCH_LOG" \
      python3 /halogen/tools/bench-serving.py \
        "${1:-serial,mtp}" "${2:-256}" "${3:-low}" "${4:-1}"
  fi
  RC=$?
  kill -TERM "$API_PID" "$ENGINE_PID" 2>/dev/null || true
  exit $RC
  ;;
convert)
  # 0.12.1: GGUF -> .hgn on disk, the runtime repack with a file sink. No
  # model is loaded and no port is bound; the process is the repack and
  # exits with its status. IN is any shard of a split GGUF (the siblings are
  # found by name beside it); OUT is written whole, with the table and the
  # draft head, so it is a checkpoint on its own.
  IN="${2:-}"; OUT="${3:-}"
  if [ -z "$IN" ] || [ -z "$OUT" ]; then
    echo "usage: entrypoint.sh convert IN.gguf OUT.hgn" >&2
    echo "  IN: any shard of a llama.cpp GGUF of Qwen3.8-Flash-Next (unsloth's, bartowski's, your own llama-quantize)." >&2
    echo "  OUT: the .hgn to write (about 105 GiB for an IQ4_XS build; the table and the draft head are folded in)." >&2
    exit 2
  fi
  [ -f "$IN" ] || { echo "halogen convert: $IN is not there (mount the models volume and name a file inside it)" >&2; exit 1; }
  [ "$(head -c 4 "$IN" 2>/dev/null)" = "GGUF" ] || { echo "halogen convert: $IN is not a GGUF (its first bytes are not GGUF)" >&2; exit 1; }
  OUTDIR="$(dirname "$OUT")"
  [ -d "$OUTDIR" ] && [ -w "$OUTDIR" ] || { echo "halogen convert: cannot write into $OUTDIR (is the volume mounted read-write?)" >&2; exit 1; }
  need_head "$(dirname "$IN")"
  echo "halogen convert: $IN -> $OUT (the table and the draft head folded in; a few minutes to ten on an NVMe disk)"
  /usr/local/bin/flash_serve --repack "$IN" --out "$OUT" --with-table --head "$HALOGEN_MTP_HEAD"
  RC=$?
  if [ "$RC" -eq 0 ]; then
    echo "halogen convert: done. Start the image with HALOGEN_CHECKPOINT=$OUT (no GGUF is needed beside it;"
    echo "  the quality sidecar does not apply to a converted trunk, and none is looked for)."
  else
    echo "halogen convert: the repack failed (rc=$RC); $OUT is not usable and can be removed" >&2
  fi
  exit $RC
  ;;
inspect|verify|ppl|niah)
  # 0.13.0: the checkpoint tools as modes. The verb goes to the sibling
  # binary as it is; the only thing this layer adds is the FILE default
  # (HALOGEN_CHECKPOINT, the file `all` would serve) and, for the two modes
  # that load a model, the same resolution `all` does: the draft head beside
  # a GGUF, the tuning plan copied out of the read-only layer so a clean
  # exit cannot rewrite the baked file. No port is bound; the process is
  # the tool and exits with its status.
  MODE="$1"
  shift || true
  FILE=""
  if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then FILE="$1"; shift; fi
  [ -n "$FILE" ] || FILE="$HALOGEN_CHECKPOINT"
  [ -f "$FILE" ] || { echo "halogen $MODE: $FILE is not there (mount the models volume and name a file inside it, or set HALOGEN_CHECKPOINT)" >&2; exit 1; }
  if [ "$MODE" = ppl ] || [ "$MODE" = niah ]; then
    tuning_plan_copy
    if [ "$(head -c 4 "$FILE" 2>/dev/null)" = "GGUF" ]; then need_head "$(dirname "$FILE")"; fi
    echo "halogen $MODE: $FILE under this image's engine environment (tuning plan: ${HALOGEN_MATMUL_TUNING_FILE:-none}; quality sidecar: ${HALOGEN_CK_OVERLAY:-beside the checkpoint, if any}; trunk pinned: ${HALOGEN_FLASH_PIN_TRUNK:-1})" >&2
    # the two modes that read text go through the Python front end: it
    # tokenizes --corpus with the mounted tokenizer, builds the retrieval
    # battery, runs the binary, and decodes what the binary prints as ids
    need_tokenizer
    exec python3 /halogen/tools/halogen_tools.py "$MODE" "$FILE" --tokenizer "$HALOGEN_TOKENIZER" "$@"
  fi
  exec /usr/local/bin/halogen-tools "$MODE" "$FILE" "$@"
  ;;
*) echo "usage: entrypoint.sh [all|engine|api|bench|sweep|convert IN.gguf OUT.hgn|inspect|verify|ppl|niah [FILE] ...]" >&2; exit 2 ;;
esac
