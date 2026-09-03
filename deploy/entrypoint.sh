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
#
# The engine's token protocol has NO AUTH. In `all` it binds loopback INSIDE
# the container and is unreachable from outside; only the API port is
# published. If you split the roles you must keep the engine port unpublished
# yourself. The compose file does, deliberately.
set -euo pipefail

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
  cache_gib=$(awk -v c="$ENG_CTX" -v on="${HALOGEN_PROMPT_CACHE:-2}" -v ip="${HALOGEN_CACHE_INPLACE:-1}" -v f="${HALOGEN_CACHE_FILE:-}" 'BEGIN{printf "%.1f", (on==0 || f!="")?0:(ip!="0"?0.2:c*26624/1073741824)}')
  avail_gib=$(awk '/MemAvailable/{printf "%.1f", $2/1048576}' /proc/meminfo 2>/dev/null || echo "?")
  if [ "${HALOGEN_KV_POOL:-1}" = "0" ]; then
    echo "halogen: KV budget ${ENG_SLOTS} slot(s) x ${ENG_CTX} ctx = ${kv_gib} GiB" \
         "(~26 KiB/position/slot, HALOGEN_KV_POOL=0) + ${cache_gib} GiB prompt cache in RAM${HALOGEN_CACHE_FILE:+ (snapshot on file)}, on top of ~68 GiB" \
         "of weights and ~11 GiB of scratch. MemAvailable now ${avail_gib} GiB."
  else
    echo "halogen: KV budget ${ENG_SLOTS} slot(s) over one ${ENG_POOL}-position pool (each request up to ${ENG_CTX}) = ${kv_gib} GiB" \
         "(~28 KiB/position incl. block scratch + ~115 MiB/slot) + ${cache_gib} GiB prompt cache in RAM${HALOGEN_CACHE_FILE:+ (snapshot on file)}, on top of ~68 GiB" \
         "of weights and ~11 GiB of scratch. MemAvailable now ${avail_gib} GiB."
  fi
  awk -v kv="$kv_gib" -v cg="$cache_gib" -v av="$avail_gib" 'BEGIN{ if (av != "?" && kv+cg+80 > av)
    print "halogen: WARNING: that budget is close to or over what this host has free.\n  If startup ends in \"HIP … out of memory\", lower HALOGEN_KV_POOL_POSITIONS (the pool) or HALOGEN_MAX_TOK (the prefill arena);\n  a 1,048,576-position pool fits only with HALOGEN_MAX_TOK=16384." > "/dev/stderr" }'
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

need_ckpt() {
  maybe_download
  [ -f "$HALOGEN_CHECKPOINT" ] || {
    echo "halogen: no checkpoint at $HALOGEN_CHECKPOINT" >&2
    echo "  mount it:  -v /path/to/models:/models:ro" >&2
    echo "  or point:  -e HALOGEN_CHECKPOINT=/models/<file>.hgn" >&2
    exit 1; }
  check_sidecar
  kv_budget_note
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
  if [ -f "$side" ]; then
    echo "halogen: quality sidecar present ($(du -h "$side" | cut -f1)) at $side"
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

start_engine() {
  need_ckpt
  exec /usr/local/bin/flash_serve \
    --ck "$HALOGEN_CHECKPOINT" --port "$ENG_PORT" --bind "$BIND" \
    --slots "$ENG_SLOTS" --ctx "$ENG_CTX" --max-tok "$ENG_MAX_TOK" --kv-pool "$ENG_POOL"
}

start_api() {
  need_tokenizer
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

case "${1:-all}" in
engine) start_engine ;;
api)    start_api ;;
all)
  need_ckpt; need_tokenizer
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
  for _ in $(seq 1 900); do
    if exec 3<>"/dev/tcp/127.0.0.1/$ENG_PORT" 2>/dev/null; then
      exec 3>&-; echo "halogen: engine listening"; break
    fi
    kill -0 "$ENGINE_PID" 2>/dev/null || { echo "halogen: engine died during load" >&2; wait "$ENGINE_PID"; exit 1; }
    sleep 2
  done

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
  wait -n "$ENGINE_PID" "$API_PID"
  echo "halogen: a component exited; shutting down" >&2
  kill -TERM "$ENGINE_PID" "$API_PID" 2>/dev/null || true
  wait || true
  exit 1
  ;;
bench|sweep)
  MODE="$1"
  shift || true
  need_ckpt; need_tokenizer
  BENCH_LOG=/tmp/halogen-api.log
  : > "$BENCH_LOG"

  /usr/local/bin/flash_serve --ck "$HALOGEN_CHECKPOINT" \
      --port "$ENG_PORT" --bind 127.0.0.1 \
      --slots "$ENG_SLOTS" --ctx "$ENG_CTX" --max-tok "$ENG_MAX_TOK" --kv-pool "$ENG_POOL" \
      > /tmp/halogen-engine.log 2>&1 &
  ENGINE_PID=$!
  trap 'kill -TERM "$ENGINE_PID" 2>/dev/null || true' TERM INT EXIT

  echo "halogen bench: loading model (cold load can take minutes)"
  for _ in $(seq 1 900); do
    if exec 3<>"/dev/tcp/127.0.0.1/$ENG_PORT" 2>/dev/null; then
      exec 3>&-; break
    fi
    kill -0 "$ENGINE_PID" 2>/dev/null || { echo "engine died during load:" >&2; tail -20 /tmp/halogen-engine.log >&2; exit 1; }
    sleep 2
  done

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
  for _ in $(seq 1 150); do
    python3 -c "import urllib.request,sys
try: urllib.request.urlopen('http://127.0.0.1:$API_PORT/health', timeout=3); sys.exit(0)
except Exception: sys.exit(1)" 2>/dev/null && break
    sleep 2
  done

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
*) echo "usage: entrypoint.sh [all|engine|api|bench|sweep]" >&2; exit 2 ;;
esac
