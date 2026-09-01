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
# KV costs ~26 KiB per position per slot, so the product `slots x ctx` is what
# has to fit. SLOTS DEFAULTS TO 1 and that is not a downgrade: the default
# drafter is the MTP loop, which drives its slot alone and blocks admission
# while it runs, so extra slots buy nothing unless requests ask for
# `"drafter": "serial"`. Raise slots and lower ctx together if you want
# concurrency.
#
# MAX-TOK IS CAPPED AT 32,768 AND MUST NOT FOLLOW THE CONTEXT. It sizes the
# single-call prefill arena (4.32 GiB of tier-1 scratch at 32,768 alone), and
# asking for a 262,144-wide call is an immediate out-of-memory, measured at
# 131k. Prompts longer than max-tok are prefilled in max-tok pieces, which is
# what makes the native context affordable at all.
ENG_SLOTS="${HALOGEN_KV_SLOTS:-1}"
ENG_CTX="${HALOGEN_CTX:-262144}"
ENG_MAX_TOK="${HALOGEN_MAX_TOK:-32768}"
[ "$ENG_MAX_TOK" -gt "$ENG_CTX" ] && ENG_MAX_TOK="$ENG_CTX"

# A KV budget the user can read BEFORE the allocator refuses. Without this the
# only symptom of an over-subscribed `slots x ctx` is
# `HIP flash_ops.h:103: out of memory` with no numbers attached, a failure
# shape where the message names the mechanism and not the cause.
kv_budget_note() {
  local kv_gib avail_gib
  kv_gib=$(awk -v s="$ENG_SLOTS" -v c="$ENG_CTX" 'BEGIN{printf "%.1f", s*c*26624/1073741824}')
  avail_gib=$(awk '/MemAvailable/{printf "%.1f", $2/1048576}' /proc/meminfo 2>/dev/null || echo "?")
  echo "halogen: KV budget ${ENG_SLOTS} slot(s) x ${ENG_CTX} ctx = ${kv_gib} GiB" \
       "(~26 KiB/position/slot), on top of ~68 GiB of weights and ~11 GiB of" \
       "scratch. MemAvailable now ${avail_gib} GiB."
  awk -v kv="$kv_gib" -v av="$avail_gib" 'BEGIN{ if (av != "?" && kv+80 > av)
    print "halogen: WARNING: that budget is close to or over what this host has free.\n  If startup ends in \"HIP … out of memory\", lower HALOGEN_KV_SLOTS or HALOGEN_CTX;\n  their PRODUCT is the constraint. 4 slots at the native context does not fit in 128 GB." > "/dev/stderr" }'
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
    --slots "$ENG_SLOTS" --ctx "$ENG_CTX" --max-tok "$ENG_MAX_TOK"
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
    --max-tokens-cap "${HALOGEN_MAX_TOKENS_CAP:-16384}" \
    --queue-timeout "${HALOGEN_QUEUE_TIMEOUT:-2400}"
}

case "${1:-all}" in
engine) start_engine ;;
api)    start_api ;;
all)
  need_ckpt; need_tokenizer
  /usr/local/bin/flash_serve --ck "$HALOGEN_CHECKPOINT" \
      --port "$ENG_PORT" --bind 127.0.0.1 \
      --slots "$ENG_SLOTS" --ctx "$ENG_CTX" --max-tok "$ENG_MAX_TOK" &
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
    --max-tokens-cap "${HALOGEN_MAX_TOKENS_CAP:-16384}" \
    --queue-timeout "${HALOGEN_QUEUE_TIMEOUT:-2400}" &
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
      --slots "$ENG_SLOTS" --ctx "$ENG_CTX" --max-tok "$ENG_MAX_TOK" \
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
    --max-tokens-cap "${HALOGEN_MAX_TOKENS_CAP:-16384}" \
    --queue-timeout "${HALOGEN_QUEUE_TIMEOUT:-2400}" 2>&1 | tee "$BENCH_LOG" &
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
