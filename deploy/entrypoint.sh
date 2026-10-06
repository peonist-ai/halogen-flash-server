#!/bin/bash
# halogen-flash-server: source shipped as-is, comments stripped. The README is the documentation.
set -euo pipefail

export HSA_DISABLE_COREDUMP_ON_EXCEPTION="${HSA_DISABLE_COREDUMP_ON_EXCEPTION:-1}"
ulimit -c 0

ENG_PORT="${HALOGEN_PORT:-8730}"
API_PORT="${HALOGEN_API_PORT:-8731}"
BIND="${HALOGEN_BIND:-127.0.0.1}"

export HALOGEN_VERBOSE="${HALOGEN_VERBOSE:-0}"

default_checkpoint() {
  if [ ! -f "$1/qwen38-flash-next-v2.hgn" ] && [ -f "$1/qwen38-flash-next-w4b.hgn" ]; then
    echo "$1/qwen38-flash-next-w4b.hgn"
  else
    echo "$1/qwen38-flash-next-v2.hgn"
  fi
}
resolve_checkpoint() {
  LEGACY_W4B=0
  if [ -z "${HALOGEN_CHECKPOINT:-}" ]; then
    HALOGEN_CHECKPOINT="$(default_checkpoint "$1")"
    case "$HALOGEN_CHECKPOINT" in */qwen38-flash-next-w4b.hgn) LEGACY_W4B=1 ;; esac
  fi
}
resolve_checkpoint /models
export HALOGEN_CHECKPOINT

ENG_SLOTS="${HALOGEN_KV_SLOTS:-4}"
ENG_CTX="${HALOGEN_CTX:-262144}"

ENG_POOL="${HALOGEN_KV_POOL_POSITIONS:-}"
if [ -z "$ENG_POOL" ]; then
  ENG_POOL=$(( ENG_CTX * 2 ))
  [ "$ENG_POOL" -gt 1048576 ] && ENG_POOL=1048576
  [ "$ENG_POOL" -lt "$ENG_CTX" ] && ENG_POOL="$ENG_CTX"
fi

ENG_MAX_TOK="${HALOGEN_MAX_TOK:-32768}"
if [ "$ENG_CTX" -gt 262144 ]; then
  if [ "$ENG_MAX_TOK" -gt 16384 ]; then
    echo "halogen: context $ENG_CTX is past the native 262144: HALOGEN_MAX_TOK $ENG_MAX_TOK is capped at 16384 here (a larger prefill arena leaves a 1M KV cache no room to stay resident)." >&2
    ENG_MAX_TOK=16384
  fi
  if [ "${HALOGEN_PROMPT_CACHE:-2}" != "0" ] && [ "${HALOGEN_CACHE_INPLACE:-1}" = "0" ] && [ -z "${HALOGEN_CACHE_FILE:-}" ]; then

    export HALOGEN_CACHE_FILE=/var/tmp/halogen-cache.snapshot
    echo "halogen: context $ENG_CTX is past the native 262144 with HALOGEN_CACHE_INPLACE=0: the prompt cache snapshot goes to HALOGEN_CACHE_FILE=$HALOGEN_CACHE_FILE (up to 26.6 GiB at 1M; mount fast storage there, or set the path)." >&2
  fi
fi
[ "$ENG_MAX_TOK" -gt "$ENG_CTX" ] && ENG_MAX_TOK="$ENG_CTX"

ROPE_YARN="${HALOGEN_ROPE_YARN:-}"
if [ "$ENG_CTX" -gt 262144 ] && [ -z "$ROPE_YARN" ]; then
  echo "halogen: HALOGEN_CTX=$ENG_CTX is past the native 262144. Contexts up to"        "1048576 need HALOGEN_ROPE_YARN=<factor> (4 for 1M, 2 for 524288), the"        "model's documented static YaRN, which changes its numerics at every"        "position. Set it deliberately, or lower HALOGEN_CTX." >&2
  exit 2
fi
if [ -n "$ROPE_YARN" ] && [ "$ENG_CTX" -le 262144 ]; then
  echo "halogen: WARNING: HALOGEN_ROPE_YARN=$ROPE_YARN with HALOGEN_CTX=$ENG_CTX at or"        "under the native 262144. Static YaRN rescales every position; the model"        "card advises it only when the context needs it." >&2
fi

kv_budget_note() {
  local kv_gib avail_gib

  kv_gib=$(awk -v s="$ENG_SLOTS" -v c="$ENG_CTX" -v p="$ENG_POOL" -v pool="${HALOGEN_KV_POOL:-1}" 'BEGIN{printf "%.1f", (pool=="0"?s*c*26624:p*29500+s*120586240)/1073741824}')

  cache_gib=$(awk -v c="$ENG_CTX" -v on="${HALOGEN_PROMPT_CACHE:-2}" -v ip="${HALOGEN_CACHE_INPLACE:-1}" -v f="${HALOGEN_CACHE_FILE:-}" -v n="${HALOGEN_CACHE_ENTRIES:-}" -v s="$ENG_SLOTS" -v br="${HALOGEN_CACHE_BRANCHES:-2}" -v s3="${HALOGEN_CACHE_SNAP3:-1}" -v fu="${HALOGEN_CACHE_FULL:-1}" 'BEGIN{if (n=="") n = s * (1 + br*((s3=="0")?1:2) + ((fu=="0")?0:1)); printf "%.1f", (on==0 || f!="")?0:(ip!="0"?n*115*1048576/1073741824:c*26624/1073741824)}')
  avail_gib=$(awk '/MemAvailable/{printf "%.1f", $2/1048576}' /proc/meminfo 2>/dev/null || echo "?")

  local wt="68 GiB" w_gib=68 ft=""
  if ckpt_facts; then
    wt="${CK_RES_GIB} GiB (read from the checkpoint)"; w_gib=$CK_RES_GIB
  elif is_gguf; then
    ft=$(gguf_file_type "$HALOGEN_CHECKPOINT")
    case "$ft" in
      15) wt="80 GiB (a K-quant GGUF trunk, file type 15, repacked into RAM)"; w_gib=80 ;;
      30) wt="72 GiB (an 8-bit GGUF trunk, file type 30, repacked into RAM)"; w_gib=72 ;;
      *)  wt="72 GiB or more (a GGUF trunk of file type ${ft:-unknown}, repacked into RAM; measured for types 30 and 15 only)"; w_gib=72 ;;
    esac
  fi

  local scratch_gib tower_gib=0 ws
  ws=$(work_split)
  scratch_gib=$(echo "$ws" | awk '{printf "%.1f", $1 + $2}')
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

  awk -v kv="$kv_gib" -v cg="$cache_gib" -v av="$avail_gib" -v w="$w_gib" 'BEGIN{ if (av != "?" && kv+cg+w+16 > av)
    print "halogen: WARNING: that budget is close to or over what this host has free (the engine refuses the last pin under 16 GiB of MemAvailable).\n  If startup ends in \"checkpoint: refusing to pin\" or \"HIP ... out of memory\", lower HALOGEN_MAX_TOK to 16384 (the working memory, about 4 GiB back on the default checkpoint and 1.6 on w4b, for about 9% of prefill speed)\n  or HALOGEN_KV_POOL_POSITIONS (the pool, ~29.5 KiB a position); a 1,048,576-position pool fits only with HALOGEN_MAX_TOK=16384." > "/dev/stderr" }'
}

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

  local need_gib arena_gib
  arena_gib=$(work_split | awk '{print $1}')
  need_gib=$(awk -v s="$ENG_SLOTS" -v c="$ENG_CTX" -v p="$ENG_POOL" -v pool="${HALOGEN_KV_POOL:-1}" -v a="$arena_gib" \
    'BEGIN{printf "%.1f", (pool=="0"?s*c*26624:p*29500+s*120586240)/1073741824 + a}')
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

    local carve_b=0 carve_gib=0 memtotal_gib=0
    for f in /sys/class/drm/card*/device/mem_info_vram_total; do
      [ -r "$f" ] || continue
      local v; v=$(cat "$f" 2>/dev/null || echo 0)
      [ "${v:-0}" -gt "$carve_b" ] && carve_b=$v
    done
    carve_gib=$(awk -v b="$carve_b" 'BEGIN{printf "%.1f", b/1073741824}')

    [ -n "${HALOGEN_UMA_CARVEOUT_GIB:-}" ] && carve_gib=$HALOGEN_UMA_CARVEOUT_GIB
    memtotal_gib=$(awk '/MemTotal/{printf "%.1f", $2/1048576}' /proc/meminfo 2>/dev/null || echo 0)
    if awk -v c="$carve_gib" 'BEGIN{exit !(c >= 8.0)}'; then
      echo "  LIKELY CAUSE: ${carve_gib} GiB of this machine's RAM is carved out for the iGPU in firmware, and the OS reports only ${memtotal_gib} GiB as a result. GTT is sized from that smaller total, which is why only ${total_gib} GiB of it exists." >&2
      echo "  This server does not want a carve-out at all: it drives the GPU through GTT and allocates from the same unified memory whichever way the BIOS option is left, so a large one buys it nothing and costs it the file cache the model's lookup table is read through." >&2
      echo "  Set the UMA frame buffer size (or dedicated graphics memory) to its explicit MINIMUM rather than Auto, and start again. Measured: on a GMKtec EVO-X2, Auto took 64 GiB of a 128 GB machine and the weights could not load until it was changed." >&2
    else

      local w=68 hint_gib rest_gib
      ckpt_facts && w=$CK_RES_GIB
      rest_gib=$(work_split | awk '{print $2}')
      hint_gib=$(awk -v w="$w" -v n="$need_gib" -v r="$rest_gib" 'BEGIN{printf "%.0f", w + n + r + 16}')
      echo "  This host reports ${memtotal_gib} GiB of RAM in total. This server needs about ${hint_gib} GiB of addressable unified memory for the checkpoint, so if that figure is far below what is physically installed, check the BIOS for an iGPU memory carve-out: it is taken before Linux boots and nothing on the host reports the memory as missing." >&2
    fi
    exit 1
  fi
}

host_preflight() {
  local sys="${_hg_sys:-/sys}" dev="${_hg_dev:-/dev}" bad=0 p v gpus="" found=0
  if [ ! -e "$dev/kfd" ]; then
    if [ -e "$dev/dxg" ]; then
      echo "halogen: this looks like WSL2: /dev/dxg is here and /dev/kfd is not. WSL2 is not a supported host for this server; run it on Linux on the machine itself." >&2
    else
      echo "halogen: there is no /dev/kfd in this container, so the GPU was not passed in." >&2
      echo "  Add  --device /dev/kfd --device /dev/dri  and, with podman, --group-add keep-groups (with docker: --group-add video --group-add render)." >&2
    fi
    bad=1
  elif [ ! -r "$dev/kfd" ] || [ ! -w "$dev/kfd" ]; then
    echo "halogen: WARNING /dev/kfd is here but this user may not be able to open it. If the engine cannot find the GPU, check the group mapping: --group-add keep-groups with podman, --group-add video --group-add render with docker." >&2
  fi
  if [ "$bad" = 0 ] && ! ls "$dev"/dri/renderD* >/dev/null 2>&1; then
    echo "halogen: WARNING there is no render node under /dev/dri in this container; pass --device /dev/dri as well as /dev/kfd." >&2
  fi
  for p in "$sys"/class/kfd/kfd/topology/nodes/*/properties; do
    [ -r "$p" ] || continue
    v=$(awk '$1 == "gfx_target_version" {print $2; exit}' "$p" 2>/dev/null)
    case "$v" in ""|0) continue ;; esac
    gpus="$gpus $v"
    [ "$v" = "110501" ] && found=1
  done
  if [ -n "$gpus" ] && [ "$found" = 0 ]; then
    echo "halogen: the GPU here is not a Strix Halo (gfx1151): the kernel reports gfx_target_version$gpus, and this server is built for gfx1151 (110501) only." >&2
    bad=1
  fi
  return "$bad"
}

download_room_check() {
  local need_k free_k have_k
  need_k=$(( (${2:-0} + 1023) / 1024 ))
  [ "$need_k" -gt 0 ] || return 0
  free_k=$(df -Pk "$1" 2>/dev/null | awk 'NR == 2 {print $4}')
  [ -n "$free_k" ] || return 0
  have_k=$(du -sk "$1"/.cache/huggingface 2>/dev/null | awk '{s += $1} END {print s + 0}')
  if [ $((free_k + have_k)) -lt "$need_k" ]; then
    echo "halogen: $1 has $(awk -v k="$free_k" 'BEGIN{printf "%.1f", k/1048576}') GiB free and the download needs about $(awk -v k="$((need_k - have_k))" 'BEGIN{printf "%.1f", k/1048576}') GiB more. Nothing was downloaded." >&2
    echo "  Free space on the models volume, or mount a larger one, and start again." >&2
    return 1
  fi
  return 0
}

hub_list() {
  local to=""; command -v timeout > /dev/null 2>&1 && to="timeout 60"
  HF_HUB_OFFLINE=0 HF_HUB_DISABLE_TELEMETRY=1 $to python3 - "$1" 2>/dev/null <<'PY' || true
import sys
try:
    from huggingface_hub import HfApi
    for f in HfApi().list_repo_tree(sys.argv[1], recursive=True):
        size = getattr(f, "size", None)
        if size is not None:
            print(f.path, size)
except Exception:
    pass
PY
}

tokenizer_present() {
  [ -f "$(dirname "$HALOGEN_CHECKPOINT")/tokenizer/tokenizer.json" ] || [ -f "${HALOGEN_TOKENIZER:-/tokenizer}/tokenizer.json" ]
}

companions_missing() {
  local dir base; dir="$(dirname "$HALOGEN_CHECKPOINT")"; base="$(basename "$HALOGEN_CHECKPOINT")"
  if [ "$base" = "qwen38-flash-next-w4b.hgn" ]; then
    [ -f "$dir/${base%.hgn}.overlay.hgn" ] || echo "${base%.hgn}.overlay.hgn"
  elif [ -z "${HALOGEN_NGRAM_TABLE:-}" ] && ckpt_facts && [ "$CK_HAS_TABLE" = "0" ]; then
    [ -f "$dir/$NGRAM_TABLE_NAME" ] || echo "$NGRAM_TABLE_NAME"
  fi
  return 0
}

download_plan() {
  local base side listing="$1"
  base="$(basename "$HALOGEN_CHECKPOINT")"
  side="${base%.hgn}.overlay.hgn"
  echo "$base"
  if [ -n "$listing" ]; then
    printf '%s\n' "$listing" | awk -v s="$side" '$1 == s {print $1}'
    [ "$base" = "qwen38-flash-next-w4b.hgn" ] || [ -n "${HALOGEN_NGRAM_TABLE:-}" ] \
      || printf '%s\n' "$listing" | awk -v t="$NGRAM_TABLE_NAME" '$1 == t {print $1}'
    printf '%s\n' "$listing" | awk '$1 == "qwen38-flash-next-vision.hgn" {print $1}'
  else
    if [ "$base" = "qwen38-flash-next-w4b.hgn" ]; then echo "$side"
    elif [ -z "${HALOGEN_NGRAM_TABLE:-}" ]; then echo "$NGRAM_TABLE_NAME"; fi
    echo "qwen38-flash-next-vision.hgn"
  fi
}

download_plan_bytes() {
  printf '%s\n' "$1" | awk -v dir="$2" -v plan="$(printf '%s ' $3)" -v tok="${4:-1}" '
    BEGIN { n = split(plan, p, " "); for (i = 1; i <= n; i++) want[p[i]] = 1 }
    ($1 in want) || (tok == 1 && $1 ~ /^tokenizer\//) {
      f = dir "/" $1; have = -1
      cmd = "stat -c %s \"" f "\" 2>/dev/null || stat -f %z \"" f "\" 2>/dev/null"
      if ((cmd | getline have) <= 0) have = -1
      close(cmd)
      if (have + 0 != $2 + 0) s += $2
    }
    END { printf "%.0f\n", s + 0 }'
}

maybe_download() {
  [ -n "${HALOGEN_DOWNLOAD:-}" ] || return 0

  local dir base files="" tok=0 fresh=0
  dir="$(dirname "$HALOGEN_CHECKPOINT")"; base="$(basename "$HALOGEN_CHECKPOINT")"
  if [ -f "$HALOGEN_CHECKPOINT" ]; then
    is_gguf && return 0
    files=$(companions_missing)
    tokenizer_present || tok=1
    { [ -n "$files" ] || [ "$tok" = 1 ]; } && [ -w "$dir" ] || return 0
  else

    if is_gguf_path; then
      echo "halogen: $HALOGEN_CHECKPOINT is a GGUF and is not there; GGUF files are not downloaded by this image." >&2
      echo "  Put the file (every shard of a split) in the models volume and point HALOGEN_CHECKPOINT at any shard." >&2
      exit 1
    fi
    if [ ! -w "$dir" ]; then
      echo "halogen: HALOGEN_DOWNLOAD is set but $dir is not writable." >&2
      echo "  The models volume must be read-WRITE to download into it." >&2
      echo "  Mount it as -v <path>:/models  (drop the :ro)." >&2
      exit 1
    fi
    fresh=1
    tokenizer_present || tok=1
  fi
  local listing plan f need=""
  listing=$("${_hg_hub_list:-hub_list}" "$HALOGEN_DOWNLOAD") || listing=""
  if [ "$fresh" = 1 ]; then
    if [ -n "$listing" ] && ! printf '%s\n' "$listing" | awk -v b="$base" '$1 == b {f = 1} END {exit !f}'; then
      echo "halogen: $HALOGEN_DOWNLOAD has no $base. The checkpoints it holds:" >&2
      printf '%s\n' "$listing" | awk '$1 ~ /\.hgn$/ && $1 !~ /overlay|vision|mtp|ngram/ {printf "  /models/%s\n", $1}' >&2
      echo "  Point HALOGEN_CHECKPOINT at one of them." >&2
      exit 1
    fi

    for f in $(download_plan "$listing"); do [ -e "$dir/$f" ] || files="$files $f"; done
  fi
  plan=$(printf '%s\n' $files)
  if [ -n "$listing" ]; then
    need=$(download_plan_bytes "$listing" "$dir" "$plan" "$tok")
    case "$need" in
      ""|*[!0-9]*)
        echo "halogen: WARNING: could not size this download, so the free space on $dir is not checked first." >&2
        need="" ;;
      *) download_room_check "$dir" "$need" || exit 1 ;;
    esac
  else
    echo "halogen: the Hub did not list $HALOGEN_DOWNLOAD's files, so the free space on $dir is not checked first." >&2
  fi

  echo "halogen: downloading from $HALOGEN_DOWNLOAD into $dir:$(printf ' %s' $plan)$([ "$tok" = 1 ] && echo ' and the tokenizer')${need:+ ($(awk -v b="$need" 'BEGIN{printf "%.1f", b/1073741824}') GiB to fetch)}"
  [ "$fresh" = 1 ] && echo "         this is tens of GB and will take a while; it resumes if interrupted."

  local t0 b0 rep
  t0=$(date +%s); b0=$(du -sb "$dir" 2>/dev/null | cut -f1) || b0=0; b0=${b0:-0}

  ( s=""; trap '[ -n "$s" ] && kill "$s" 2>/dev/null; exit 0' TERM
    while :; do
      sleep 30 & s=$!; wait "$s"
      local b now
      b=$(du -sb "$dir" 2>/dev/null | cut -f1) || b=0; b=${b:-0}; now=$(date +%s)
      printf 'halogen: downloaded %.1f GB so far (%.0f MB/s average over %d s)\n' \
        "$(( b - b0 ))e-9" "$(( (b - b0) / (now - t0 + 1) ))e-6" "$(( now - t0 ))" 2>/dev/null || true
    done ) &
  rep=$!

  if ! { { [ -z "$plan" ] || HF_HUB_OFFLINE=0 HF_HUB_DISABLE_PROGRESS_BARS=1 HF_HUB_DISABLE_TELEMETRY=1 \
             "${_hg_hf:-hf}" download "$HALOGEN_DOWNLOAD" $plan --local-dir "$dir"; } \
         && { [ "$tok" != 1 ] || HF_HUB_OFFLINE=0 HF_HUB_DISABLE_PROGRESS_BARS=1 HF_HUB_DISABLE_TELEMETRY=1 \
             "${_hg_hf:-hf}" download "$HALOGEN_DOWNLOAD" --include "tokenizer/*" --local-dir "$dir"; }; } \
       2> >(grep --line-buffered -vE 'hf update|hf skills|HF_TOKEN|gitignore\.lock|A new version of' >&2); then
    kill "$rep" 2>/dev/null || true; wait "$rep" 2>/dev/null || true
    if [ "$fresh" = 1 ]; then
      echo "halogen: download FAILED. Nothing was started." >&2
      echo "  Re-run to resume, or fetch it yourself and mount it." >&2
      exit 1
    fi
    echo "halogen: fetching$(printf ' %s' $plan) did not complete; starting on what the volume holds (re-run to resume)." >&2
    return 0
  fi
  kill "$rep" 2>/dev/null || true; wait "$rep" 2>/dev/null || true

  if [ ! -f "$HALOGEN_CHECKPOINT" ]; then
    echo "halogen: download finished but $HALOGEN_CHECKPOINT is still missing." >&2
    echo "  The repo layout may not match HALOGEN_CHECKPOINT. Contents:" >&2
    ls -la "$dir" >&2
    exit 1
  fi
  [ "$fresh" = 1 ] && echo "halogen: download complete ($(du -h "$HALOGEN_CHECKPOINT" | cut -f1))"
  return 0
}

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

CK_RES_GIB="" CK_HAS_TABLE="" CK_OWN_PREC="" CK_GATHER="" CK_KEPT="" CK_FOR=""
ckpt_facts() {
  if [ "${CK_FOR:-}" = "${HALOGEN_CHECKPOINT:-}" ]; then
    [ -n "${CK_RES_GIB:-}" ]
    return
  fi
  CK_FOR="${HALOGEN_CHECKPOINT:-}"; CK_RES_GIB=""; CK_HAS_TABLE=""; CK_OWN_PREC=""; CK_GATHER=""; CK_KEPT=""
  [ -f "${HALOGEN_CHECKPOINT:-}" ] || return 1
  is_gguf && return 1
  local out line
  out=$("${_hg_flash_serve:-/usr/local/bin/flash_serve}" --resident-gib "$HALOGEN_CHECKPOINT" 2>/dev/null) || return 1

  line=$(echo "$out" | grep -E '^[0-9]+\.[0-9] [01]( [01]){0,2}( [0-9]+\.[0-9])?$' | tail -n 1)
  [ -n "$line" ] || return 1
  CK_RES_GIB=$(echo "$line" | awk '{print $1}')
  CK_HAS_TABLE=$(echo "$line" | awk '{print $2}')
  CK_OWN_PREC=$(echo "$line" | awk '{print ($3 == "" ? 0 : $3)}')
  CK_GATHER=$(echo "$line" | awk '{print ($4 == "" ? 1 : $4)}')
  CK_KEPT=$(echo "$line" | awk '{print ($5 == "" ? 0 : $5)}')
  return 0
}

work_split() {
  local g=1 k=0
  ckpt_facts && { g=${CK_GATHER:-1}; k=${CK_KEPT:-0}; }

  if [ "$g" = "0" ]; then
    awk -v mt="$ENG_MAX_TOK" -v k="$k" 'BEGIN{printf "%.1f %.1f\n", 8.8 * mt / 32768, 3.8 + k}'
  else
    awk -v mt="$ENG_MAX_TOK" -v k="$k" 'BEGIN{printf "%.1f %.1f\n", 6.0 + 3.1 * mt / 32768, 3.5 + k}'
  fi
}

NGRAM_TABLE_NAME="qwen38-flash-next-ngram.hgn"
check_ngram_table() {
  ckpt_facts || return 0
  [ "$CK_HAS_TABLE" = "0" ] || return 0
  if [ -n "${HALOGEN_NGRAM_TABLE:-}" ]; then
    [ -f "$HALOGEN_NGRAM_TABLE" ] && return 0
    echo "halogen: HALOGEN_NGRAM_TABLE=$HALOGEN_NGRAM_TABLE is not there." >&2
    exit 1
  fi
  local t dir; dir="$(dirname "$HALOGEN_CHECKPOINT")"; t="$dir/$NGRAM_TABLE_NAME"

  local tried=""
  if [ ! -f "$t" ] && [ -n "${HALOGEN_DOWNLOAD:-}" ] && [ -w "$dir" ]; then
    local listing sz
    listing=$("${_hg_hub_list:-hub_list}" "$HALOGEN_DOWNLOAD") || listing=""
    sz=$(printf '%s\n' "$listing" | awk -v t="$NGRAM_TABLE_NAME" '$1 == t {print $2}')
    echo "halogen: fetching the lookup table $NGRAM_TABLE_NAME from $HALOGEN_DOWNLOAD ($(if [ -n "$sz" ]; then awk -v b="$sz" 'BEGIN{printf "%.1f GiB", b/1073741824}'; else echo "about 48 GiB; the free space is not checked first"; fi); it resumes if interrupted)"
    [ -z "$sz" ] || download_room_check "$dir" "$sz" || exit 1
    HF_HUB_OFFLINE=0 HF_HUB_DISABLE_PROGRESS_BARS=1 HF_HUB_DISABLE_TELEMETRY=1 \
      "${_hg_hf:-hf}" download "$HALOGEN_DOWNLOAD" "$NGRAM_TABLE_NAME" --local-dir "$dir" \
      2> >(grep --line-buffered -vE 'hf update|hf skills|HF_TOKEN|gitignore\.lock|A new version of' >&2) || true
    tried=1
  fi
  if [ -f "$t" ]; then
    export HALOGEN_NGRAM_TABLE="$t"
    echo "halogen: the checkpoint's lookup table is its own file: $t"
    return 0
  fi
  if [ -n "$tried" ]; then
    echo "halogen: fetching $NGRAM_TABLE_NAME from $HALOGEN_DOWNLOAD did not complete, and $HALOGEN_CHECKPOINT does not carry the table." >&2
    echo "  Start again to resume it, or put the file in the models volume beside the checkpoint." >&2
    exit 1
  fi
  echo "halogen: $HALOGEN_CHECKPOINT does not carry the model's lookup table, and $NGRAM_TABLE_NAME is not beside it." >&2
  echo "  Put the table file in the models volume beside the checkpoint, point HALOGEN_NGRAM_TABLE at it," >&2
  echo "  or start once with HALOGEN_DOWNLOAD set and the volume read-write." >&2
  exit 1
}

need_ckpt() {
  host_preflight || {
    echo "halogen: this container cannot run the server as started; nothing was downloaded or loaded." >&2
    exit 1; }
  maybe_download
  tuning_plan_copy
  [ -f "$HALOGEN_CHECKPOINT" ] || {
    echo "halogen: no checkpoint at $HALOGEN_CHECKPOINT" >&2
    echo "  mount it:  -v /path/to/models:/models:ro" >&2
    echo "  or point:  -e HALOGEN_CHECKPOINT=/models/<file>.hgn (or any shard of a GGUF)" >&2
    exit 1; }
  if is_gguf; then check_gguf; else check_sidecar; fi
  legacy_note
  check_ngram_table
  check_vision
  kv_budget_note
  gtt_note
}

is_gguf_path() { case "$HALOGEN_CHECKPOINT" in *.gguf) return 0;; esac; return 1; }
is_gguf() {
  [ -f "$HALOGEN_CHECKPOINT" ] && [ "$(head -c 4 "$HALOGEN_CHECKPOINT" 2>/dev/null)" = "GGUF" ]
}

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

  if [ ! -f "$HALOGEN_TOKENIZER/tokenizer.json" ] && [ ! -f "$dir/tokenizer/tokenizer.json" ] \
     && [ -n "${HALOGEN_DOWNLOAD:-}" ] && [ -w "$dir" ]; then
    echo "halogen: fetching the tokenizer from $HALOGEN_DOWNLOAD"
    HF_HUB_OFFLINE=0 hf download "$HALOGEN_DOWNLOAD" --include "tokenizer/*" --local-dir "$dir" || true
  fi
}

text_only_mode() {
  if [ -n "${HALOGEN_VISION_TOWER:-}" ]; then
    echo "halogen $1: HALOGEN_VISION_TOWER is ignored in this mode (text only)" >&2
    unset HALOGEN_VISION_TOWER
  fi
}

check_vision() {
  local side="$(dirname "$HALOGEN_CHECKPOINT")/qwen38-flash-next-vision.hgn"
  case "${HALOGEN_VISION_TOWER:-}" in
    "")
      if [ -f "$side" ]; then
        echo "halogen: a vision sidecar is present but NOT loaded: $side"
        echo "         set HALOGEN_VISION_TOWER=$side to accept images."
      fi
      return 0 ;;
    0|no|false|off)

      echo "halogen: vision OFF (HALOGEN_VISION_TOWER=${HALOGEN_VISION_TOWER})"
      unset HALOGEN_VISION_TOWER
      return 0 ;;
    1|auto|yes|true)

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

  echo "         an image costs ~1,000 tokens at 1280x800 and ~2,040 at 1080p;"
  echo "         HALOGEN_VISION_MAX_PIXELS caps it (default 2560x1440; larger is downscaled)."
}

legacy_note() {
  [ "${LEGACY_W4B:-0}" = 1 ] || return 0
  echo "halogen: this volume holds qwen38-flash-next-w4b.hgn and not the newer default,"
  echo "  qwen38-flash-next-v2.hgn (higher quality, less memory). w4b is served and nothing is downloaded."
  if [ -n "${HALOGEN_DOWNLOAD:-}" ]; then
    echo "  To switch, start with -e HALOGEN_CHECKPOINT=/models/qwen38-flash-next-v2.hgn. That start"
    echo "  downloads v2 and its lookup table (about 110 GiB). Once v2 runs, the w4b files can be removed."
  else
    echo "  To switch, put qwen38-flash-next-v2.hgn and qwen38-flash-next-ngram.hgn in this volume, then"
    echo "  start with -e HALOGEN_CHECKPOINT=/models/qwen38-flash-next-v2.hgn. Once v2 runs, the w4b files"
    echo "  can be removed."
  fi
}
check_sidecar() {
  case "${HALOGEN_CK_OVERLAY:-}" in
    none|0)

      if ckpt_facts && [ "$CK_OWN_PREC" = "1" ]; then
        echo "halogen: HALOGEN_CK_OVERLAY=${HALOGEN_CK_OVERLAY} has no effect: $HALOGEN_CHECKPOINT carries its own precision and takes no sidecar."
      else
        echo "halogen: HALOGEN_CK_OVERLAY=${HALOGEN_CK_OVERLAY}, so the BARE checkpoint runs."
        echo "         That is the measurement control, not the shipped precision."
      fi
      return 0 ;;
    "") : ;;
    *)  [ -f "$HALOGEN_CK_OVERLAY" ] || {
          echo "halogen: HALOGEN_CK_OVERLAY=$HALOGEN_CK_OVERLAY does not exist." >&2
          exit 1; }
        echo "halogen: overlay $HALOGEN_CK_OVERLAY"
        return 0 ;;
  esac
  local side="${HALOGEN_CHECKPOINT%.hgn}.overlay.hgn"

  if ckpt_facts && [ "$CK_OWN_PREC" = "1" ] && [ ! -f "$side" ]; then
    echo "halogen: $HALOGEN_CHECKPOINT carries its own precision choices: no quality sidecar applies and none is looked for"
    return 0
  fi

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

wait_for_engine() {
  local port="$1" pid="$2" log="${3:-}"
  local limit="${HALOGEN_ENGINE_WAIT_S:-0}" t=0 beat=0
  while :; do

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

wd_state() {

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

wd_main_state() {
  local f="${_hg_proc:-/proc}/$1/task/$1/stat"
  [ -r "$f" ] || { echo "?"; return 0; }
  sed 's/.*) //' "$f" 2>/dev/null | cut -d' ' -f1 || echo "?"
}
wd_alive() { [ -d "${_hg_proc:-/proc}/$1" ] && [ "$(wd_main_state "$1")" != "Z" ]; }

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
stop_engine() {
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

memlock_note() {
  [ "${HALOGEN_WEIGHTS_LOCK:-0}" = "1" ] || return 0
  local hard; hard=$(ulimit -H -l 2>/dev/null || echo "?")
  case "$hard" in unlimited|"?") return 0 ;; esac

  local w_gib=68 need_k=75000000
  if ckpt_facts; then
    w_gib=$CK_RES_GIB
    need_k=$(awk -v r="$CK_RES_GIB" 'BEGIN{printf "%.0f", (r + 2) * 1048576}')
  fi
  if [ "$hard" -lt "$need_k" ] 2>/dev/null; then
    echo "halogen: WARNING HALOGEN_WEIGHTS_LOCK=1 asks the engine to mlock about ${w_gib} GiB of weights, but this container's hard memlock limit is ${hard} KiB." >&2
    echo "  A rootless container cannot exceed the host user's hard limit, so --ulimit memlock=-1:-1 did not take effect. On the host: ulimit -H -l; if it is not unlimited, add" >&2
    echo "    <user> hard memlock unlimited" >&2
    echo "    <user> soft memlock unlimited" >&2
    echo "  to /etc/security/limits.conf (or a file under /etc/security/limits.d/), log in again, and start the container from that login. The engine will start, unlocked." >&2
  fi
}

start_engine() {
  need_ckpt
  memlock_note

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

  WATCHDOG_PID=""
  if [ "${HALOGEN_ENGINE_WATCHDOG_S:-180}" -gt 0 ]; then
    engine_watchdog "$ENG_PORT" "$ENGINE_PID" &
    WATCHDOG_PID=$!
  else
    echo "halogen: engine watchdog OFF (HALOGEN_ENGINE_WATCHDOG_S=0)"
  fi

  set +e

  WRC=0; wait -n "$ENGINE_PID" $WATCHDOG_PID 2>/dev/null || WRC=$?

  [ -n "$WATCHDOG_PID" ] && kill -9 "$WATCHDOG_PID" 2>/dev/null || true

  [ -n "$WATCHDOG_PID" ] && wait "$WATCHDOG_PID" 2>/dev/null || true
  RC=0; stop_engine "$ENGINE_PID" || RC=$?
  echo "halogen: engine exited (rc=$RC, the component that ended this: $WRC); shutting down" >&2
  wd_gtt_after_exit
  [ "$RC" -ne 0 ] && exit "$RC"
  exit "$WRC"
}

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

  exec python3 /halogen/tools/serve_api.py \
    --tokenizer "$HALOGEN_TOKENIZER" \
    --engine "${HALOGEN_ENGINE:-127.0.0.1:$ENG_PORT}" \
    --host 0.0.0.0 --port "$API_PORT" \
    --max-tokens-cap "${HALOGEN_MAX_TOKENS_CAP:-65536}" \
    --context "$ENG_CTX" \
    --queue-timeout "${HALOGEN_QUEUE_TIMEOUT:-3600}"
}

NPU_PINS="${_hg_npu_pins:-/opt/halogen/npu/models.txt}"
NPU_DIR="${_hg_npu_dir:-/models/npu}"

npu_pin_ids() { awk '$1 == "model" {print $2}' "$NPU_PINS" 2>/dev/null || true; }

npu_pin_get() {
  awk -v id="$1" -v k="$2" '$1 == "model" && $2 == id {
    for (i = 3; i <= NF; i++) if (index($i, k "=") == 1) { print substr($i, length(k) + 2); exit } }' "$NPU_PINS" 2>/dev/null || true
}

npu_pin_files() { awk -v id="$1" '$1 == "file" && $2 == id {print $3, $4, $5}' "$NPU_PINS" 2>/dev/null || true; }

npu_devices_of() {
  local o
  o=$(npu_pin_get "$1" devices)
  echo "${o:-$1}"
}

npu_stat() { stat -c '%A %U:%G' "$1" 2>/dev/null || ls -ld "$1" 2>/dev/null | awk '{print $1, $3 ":" $4}'; }

npu_fclk() {
  local r="$1" d perf top first=""
  for d in "$r"/sys/class/drm/card*/device; do
    [ -r "$d/pp_dpm_fclk" ] && [ -r "$d/power_dpm_force_performance_level" ] || continue
    perf=$(cat "$d/power_dpm_force_performance_level" 2>/dev/null)
    top=$(grep . "$d/pp_dpm_fclk" | tail -n 1)
    if [ "$perf" = high ] || { [ "$perf" = manual ] && [ "$(grep -c '\*' "$d/pp_dpm_fclk")" = 1 ] && [ "${top%\*}" != "$top" ]; }; then
      [ -n "$first" ] || first="held $(echo "$top" | awk '{print $2}')"
    else
      echo "${d#"$r"} ${top%%:*}"
      return 0
    fi
  done
  [ -n "$first" ] && echo "$first"
  return 0
}

npu_sysfs_write() { echo "$2" > "$1" 2>/dev/null; }
NPU_FCLK_HELD=""
npu_fclk_hold() {
  local r="$1" d perf top lvl n=0
  for d in "$r"/sys/class/drm/card*/device; do
    [ -e "$d/pp_dpm_fclk" ] && [ -e "$d/power_dpm_force_performance_level" ] || continue
    [ -w "$d/pp_dpm_fclk" ] && [ -w "$d/power_dpm_force_performance_level" ] || return 1
    perf=$(cat "$d/power_dpm_force_performance_level" 2>/dev/null)
    lvl=$(grep . "$d/pp_dpm_fclk" | tail -n 1 | cut -d: -f1)
    NPU_FCLK_HELD="$NPU_FCLK_HELD $d:$perf"
    if ! npu_sysfs_write "$d/power_dpm_force_performance_level" manual || ! npu_sysfs_write "$d/pp_dpm_fclk" "$lvl"; then
      npu_fclk_release > /dev/null; return 1
    fi
    n=$((n + 1))
  done

  local t=0
  [ "$n" -gt 0 ] && echo "halogen npu: holding the GPU's fabric clock (the driver takes a few seconds)"
  while [ "$n" -gt 0 ] && [ "$t" -lt 300 ]; do
    case "$(npu_fclk "$r")" in held*) trap npu_fclk_release EXIT; return 0 ;; esac
    sleep 0.1; t=$((t + 1))
  done
  npu_fclk_release > /dev/null
  return 1
}
npu_fclk_release() {
  local e
  for e in $NPU_FCLK_HELD; do npu_sysfs_write "${e%:*}/power_dpm_force_performance_level" "${e##*:}"; done
  [ -n "$NPU_FCLK_HELD" ] && echo "halogen npu: the GPU's fabric clock given back to the driver (${NPU_FCLK_HELD##*:})"
  NPU_FCLK_HELD=""
}

npu_retired() {
  local v bad=0
  for v in HALOGEN_NPU_DOWNLOAD HALOGEN_NPU_REPO HALOGEN_NPU_DIR; do
    [ -n "${!v:-}" ] || continue
    case "$v" in
      HALOGEN_NPU_DOWNLOAD) echo "halogen npu: HALOGEN_NPU_DOWNLOAD is gone: HALOGEN_DOWNLOAD fetches the NPU models too (the same switch as the main model). Unset it." >&2 ;;
      HALOGEN_NPU_REPO) echo "halogen npu: HALOGEN_NPU_REPO is gone: our NPU models come from where this image's record says; your own model is a path in HALOGEN_NPU_MODELS (/models/<dir>). Unset it." >&2 ;;
      HALOGEN_NPU_DIR) echo "halogen npu: HALOGEN_NPU_DIR is gone: our NPU models live under /models/npu/<id>/, your own at the path HALOGEN_NPU_MODELS names. Unset it." >&2 ;;
    esac
    bad=1
  done
  return "$bad"
}

npu_fetch() {
  local id="$1" d="$2" repo rev need=0 p sz
  shift 2
  repo=$(npu_pin_get "$id" repo); rev=$(npu_pin_get "$id" revision)
  if [ -z "$repo" ]; then
    echo "halogen npu: HALOGEN_DOWNLOAD is set, but this image names no download source for $id yet; put its files under $d." >&2
    return 1
  fi
  if ! mkdir -p "$d" 2>/dev/null || [ ! -w "$d" ]; then
    echo "halogen npu: HALOGEN_DOWNLOAD is set but $d is not writable. Mount the models volume read-write (drop the :ro)." >&2
    return 1
  fi
  for p in "$@"; do
    sz=$(npu_pin_files "$id" | awk -v p="$p" '$1 == p {print $2}')
    need=$((need + ${sz:-0}))
  done
  download_room_check "$d" "$need" || return 1
  echo "halogen npu: fetching $id from $repo${rev:+ at $rev}:$(printf ' %s' "$@")"

  if ! HF_HUB_OFFLINE=0 HF_HUB_DISABLE_PROGRESS_BARS=1 HF_HUB_DISABLE_TELEMETRY=1 "${_hg_hf:-hf}" download "$repo" "$@" ${rev:+--revision "$rev"} --local-dir "$d" > /dev/null \
       2> >(grep --line-buffered -vE 'hf update|hf skills|HF_TOKEN|gitignore\.lock|A new version of' >&2); then
    echo "halogen npu: fetching $id from $repo failed (see above); nothing was started" >&2
    return 1
  fi
}

npu_model_ready() {
  local id="$1" d="$2/$1" part="${3:-all}" pins paths p sz want got missing="" verify="${HALOGEN_NPU_VERIFY:-1}" known own dk
  case "$id" in ''|*/*|.*) echo "halogen npu: '$id' is not a model id" >&2; return 1 ;; esac
  pins=$(npu_pin_files "$id")
  [ "$part" = devices ] && pins=$(printf '%s\n' "$pins" | awk '$1 ~ /^devices\//')
  if [ "$verify" != 0 ] && [ -z "$pins" ]; then
    known=$(npu_pin_ids | tr '\n' ' ' | sed 's/ *$//')
    [ -n "$known" ] && known="it knows: $known" || known="its table lists none"
    echo "halogen npu: $id is not a model this image has a record of ($known)." >&2
    echo "  Name one it knows in HALOGEN_NPU_MODELS, a path for your own fine-tune (/models/<dir>), or set HALOGEN_NPU_VERIFY=0 to run files it has no record of." >&2
    return 1
  fi

  if [ -n "$pins" ] && { [ "$verify" != 0 ] || [ -n "${HALOGEN_DOWNLOAD:-}" ]; }; then
    paths=$(printf '%s\n' "$pins" | awk '{print $1}')
  elif [ "$part" = devices ]; then paths="devices/devices.hnpm"
  else paths="devices/devices.hnpm $id.hnpw tokenizer/tokenizer.json"; fi
  for p in $paths; do [ -f "$d/$p" ] || missing="$missing $p"; done
  if [ -n "$missing" ] && [ -n "${HALOGEN_DOWNLOAD:-}" ]; then

    npu_fetch "$id" "$d" $missing || return 1
    missing=""
    for p in $paths; do [ -f "$d/$p" ] || missing="$missing $p"; done
  fi
  if [ -n "$missing" ]; then
    echo "halogen npu: $id is missing$missing under $d." >&2
    echo "  Start once with HALOGEN_DOWNLOAD set and the models volume mounted read-write, or put the files there." >&2
    return 1
  fi

  own=$(npu_devices_of "$id")
  if { [ "$part" = devices ] || [ "$own" = "$id" ]; } && ! ls "$d/devices/"*.elf > /dev/null 2>&1; then
    echo "halogen npu: $id: $d/devices/ holds no .elf file (the NPU's program for the model)" >&2
    return 1
  fi
  if [ "$verify" != 0 ]; then

    local stale="" pass
    for pass in check recheck; do
      while read -r p sz want; do
        [ -n "$p" ] || continue
        [ "$pass" = check ] || case " $stale " in *" $p "*) ;; *) continue ;; esac
        got=$(wc -c < "$d/$p" | tr -d ' ')
        if [ "$got" != "$sz" ]; then
          if [ "$pass" = check ] && [ -n "${HALOGEN_DOWNLOAD:-}" ] && [ -w "$d" ]; then stale="$stale $p"; continue; fi
          echo "halogen npu: $id: $d/$p is $got bytes and this image's record says $sz (an interrupted download?). Remove it and fetch it again (HALOGEN_DOWNLOAD)." >&2
          return 1
        fi
        got=$(${_hg_sha256:-sha256sum} "$d/$p" | awk '{print $1}')
        if [ "$got" != "$want" ]; then
          if [ "$pass" = check ] && [ -n "${HALOGEN_DOWNLOAD:-}" ] && [ -w "$d" ]; then stale="$stale $p"; continue; fi
          echo "halogen npu: $id: $d/$p is not the file this image has a record of (sha256 ${got:0:16}, expected ${want:0:16}). Remove it and fetch it again (HALOGEN_DOWNLOAD)." >&2
          return 1
        fi
      done <<PINS
$pins
PINS
      [ -n "$stale" ] || break
      if [ "$pass" = check ]; then
        echo "halogen npu: $id:$stale not the files this image has a record of (another release's?); fetching them again"
        for p in $stale; do rm -f "$d/$p"; done

        npu_fetch "$id" "$d" $stale || return 1
        for p in $stale; do [ -f "$d/$p" ] || { echo "halogen npu: $id: the fetch left $d/$p missing" >&2; return 1; }; done
      fi
    done
    echo "halogen npu: $id: $(printf '%s\n' "$pins" | grep -c .) files checked against this image's record"
  else
    echo "halogen npu: $id: HALOGEN_NPU_VERIFY=0, so the files under $d are not checked against this image's record"
  fi
  [ "$part" = devices ] && sz=0 || sz=$(wc -c < "$d/$id.hnpw" | tr -d ' ')
  dk=0
  { [ "$part" = devices ] || [ "$own" = "$id" ]; } && dk=$(du -sk "$d/devices" | awk '{print $1}')
  NPU_NEED_K=$(( ${NPU_NEED_K:-0} + sz / 1024 + dk ))
}

npu_finetune_ready() {
  local p="${1%/}" bin="${_hg_npu_bin:-/usr/local/bin/halogen-npu}" info rc=0 task base name out f own
  if [ ! -d "$p" ]; then
    echo "halogen npu: $p is not a directory. A path in HALOGEN_NPU_MODELS is your own model: a directory on the models volume holding config.json, model.safetensors and tokenizer.json." >&2
    return 1
  fi
  name=$(basename "$p")
  case "$name" in *[!A-Za-z0-9._-]*|.*) echo "halogen npu: $p: its directory's name ($name) is the id it is served under, so it must be letters, digits, '.', '_' or '-'" >&2; return 1 ;; esac
  if [ "$name" = "${HALOGEN_MODEL_ID:-halogen-qwen3.8-flash-next}" ] || [ -n "$(npu_pin_get "$name" task)" ]; then
    echo "halogen npu: $p: its directory's name ($name) is the id it is served under, and that id is already one of this image's models; rename the directory" >&2
    return 1
  fi
  for f in config.json tokenizer.json; do
    [ -f "$p/$f" ] || { echo "halogen npu: $p has no $f (a Hugging Face checkpoint holds config.json, model.safetensors and tokenizer.json)" >&2; return 1; }
  done
  info=$("$bin" probe "$p") || rc=$?
  [ "$rc" = 0 ] || return 1
  task=$(printf '%s\n' "$info" | tr ' ' '\n' | awk -F= '$1 == "task" {print $2}')
  base=$(printf '%s\n' "$info" | tr ' ' '\n' | awk -F= '$1 == "base" {print $2}')
  own=$(npu_devices_of "$base")
  npu_model_ready "$own" "$NPU_DIR" devices || return 1
  if [ -w "$p" ]; then out="$p/halogen-npu.hnpw"
  else
    out="/tmp/halogen-npu/$name.hnpw"; mkdir -p /tmp/halogen-npu
    echo "halogen npu: $p is read-only, so $name is converted into the container at every start; mount the models volume read-write once to keep the result beside it"
  fi
  case "$task" in decision) task=decisions ;; embedding) task=embeddings ;; score) task=rerank ;; classify) task=moderation ;; generate) task="chat completions" ;; esac
  echo "halogen npu: $name ($p): a fine-tune of $base, served for $task"
  "$bin" convert "$p" "$NPU_DIR/$own/devices" "$out" --name "$name" --source "$p" --if-stale || {
    echo "halogen npu: converting $p for the NPU failed (above); nothing was started" >&2; return 1; }
  NPU_FT_NAME="$name"; NPU_FT_DEV="$NPU_DIR/$own/devices"; NPU_FT_W="$out"
  NPU_NEED_K=$(( ${NPU_NEED_K:-0} + $(wc -c < "$out" | tr -d ' ') / 1024 + $(du -sk "$NPU_FT_DEV" | awk '{print $1}') ))
}

npu_preflight() {
  local r="${_hg_root:-}" gpu="${1:-0}" node x xv drv out rc=0
  node="$r/dev/accel/accel0"; x="$r/opt/xilinx/xrt/lib"
  if [ ! -e "$node" ]; then
    echo "halogen npu: this container has no NPU device (/dev/accel/accel0)." >&2
    if [ ! -d "$r/sys/module/amdxdna" ]; then
      echo "  The host has not loaded the NPU driver (amdxdna). Install AMD's NPU driver on the host (or use a kernel that carries it); ls /dev/accel on the host must show accel0." >&2
    elif grep -qE '(^| )(amd_iommu|iommu)=off( |$)' "$r/proc/cmdline" 2>/dev/null || [ -z "$(ls -A "$r/sys/kernel/iommu_groups" 2>/dev/null)" ]; then
      echo "  The host's IOMMU is off (amd_iommu=off or iommu=off on the kernel command line), and the NPU driver needs it. iommu=pt keeps it on." >&2
    else
      echo "  Pass it in: --device /dev/accel/accel0" >&2
    fi
    return 1
  fi
  if [ ! -r "$node" ] || [ ! -w "$node" ]; then
    echo "halogen npu: /dev/accel/accel0 is here, but this process cannot open it ($(npu_stat "$node"))." >&2
    echo "  Podman: add --group-add keep-groups (the user starting the container must be in the device's group on the host)." >&2
    echo "  Docker with --user: add --group-add with the device's group id as a number (stat -c %g /dev/accel/accel0 on the host)." >&2
    return 1
  fi

  local f t="" bad=""
  for f in libxrt_coreutil.so.2 libxrt_core.so.2 libxrt_driver_xdna.so.2; do
    if [ -L "$x/$f" ] && [ ! -e "$x/$f" ]; then bad="$f"; t=$(readlink "$x/$f"); break; fi
  done
  if [ -n "$bad" ]; then
    echo "halogen npu: /opt/xilinx/xrt/lib/$bad is a link to $t, which is not in this container: the mount carries the host's links, not the files they point at." >&2
    case "$t" in
      /*) local td="${t%/*}"
          echo "  The host's XRT is in $td. Mount its three files instead of /opt/xilinx/xrt, each twice, at /opt/xilinx/xrt/lib/ and at $td/, since they load each other from there:" >&2
          for f in libxrt_coreutil.so.2 libxrt_core.so.2 libxrt_driver_xdna.so.2; do
            echo "    -v $td/$f:/opt/xilinx/xrt/lib/$f:ro -v $td/$f:$td/$f:ro" >&2
          done
          echo "  libxrt_driver_xdna.so.2 is the NPU plugin (Arch and CachyOS: xrt-plugin-amdxdna; Ubuntu: libxrt-npu2): ls -l $td/libxrt_driver_xdna.so.2 on the host must show it." >&2 ;;
      *) echo "  Mount the directory that holds what the link names, or mount the files themselves (ls -lL /opt/xilinx/xrt/lib on the host)." >&2 ;;
    esac
    return 1
  fi
  if [ ! -e "$x/libxrt_coreutil.so.2" ]; then
    echo "halogen npu: no XRT in this container (/opt/xilinx/xrt/lib/libxrt_coreutil.so.2)." >&2
    echo "  Mount the host's: -v /opt/xilinx/xrt:/opt/xilinx/xrt:ro (the host needs AMD's XRT with its NPU plugin installed there; the container uses the host's so it matches the host's driver)." >&2
    echo "  A distribution's XRT lives in the system library directory instead (Ubuntu: /usr/lib/x86_64-linux-gnu; Arch and CachyOS: /usr/lib): mount libxrt_coreutil.so.2, libxrt_core.so.2 and libxrt_driver_xdna.so.2 each twice, at /opt/xilinx/xrt/lib/ and at that same path, since they load each other from there." >&2
    return 1
  fi
  if [ ! -e "$x/libxrt_driver_xdna.so.2" ]; then
    echo "halogen npu: the host's XRT has no NPU plugin (/opt/xilinx/xrt/lib/libxrt_driver_xdna.so.2). Install the one AMD's NPU driver ships (or your distribution's: Ubuntu libxrt-npu2, Arch and CachyOS xrt-plugin-amdxdna), on the host." >&2
    return 1
  fi
  xv=$(basename "$(readlink -f "$x/libxrt_coreutil.so.2" 2>/dev/null || echo "$x/libxrt_coreutil.so.2")")
  xv="${xv#libxrt_coreutil.so.}"
  case "$xv" in *.*) xv="XRT $xv" ;; *) xv="XRT (its version is not in the mounted file's name)" ;; esac
  drv=$(cat "$r/sys/module/amdxdna/version" 2>/dev/null || true)
  [ -n "$drv" ] || drv="(the kernel's own)"
  out=$("${_hg_npu_bin:-/usr/local/bin/halogen-npu}" 2>&1) || rc=$?
  if [ "$rc" != 1 ] || ! printf '%s\n' "$out" | grep -q '^usage: halogen-npu'; then
    echo "halogen npu: the NPU engine does not load against the host's $xv (exit $rc):" >&2
    printf '%s\n' "$out" | head -3 | sed 's/^/    /' >&2
    echo "  The host's XRT is older than this image needs, or was built for a newer C++ runtime than the image carries (glibc 2.41, GLIBCXX_3.4.33). Tested: AMD's XRT 2.25 and Ubuntu 26.04's XRT 2.21." >&2
    return 1
  fi

  local kp="$r/sys/class/kfd/kfd/proc" gp="" fc why
  if [ "${HALOGEN_NPU_WITH_GPU:-0}" != 1 ]; then
    if [ "$gpu" = 1 ]; then why="the Flash engine runs on the GPU beside it"
    elif [ -d "$kp" ]; then gp=$(ls "$kp" 2>/dev/null | tr '\n' ' '); why="a GPU compute process is running on this machine (process ${gp% })"
    fi
    if [ "$gpu" = 1 ] || [ -n "$gp" ]; then
      fc=$(npu_fclk "$r")
      if [ "$gpu" = 1 ] && [ "${fc%% *}" != held ]; then
        local hr
        for hr in "$r/host" "$r"; do
          if npu_fclk_hold "$hr"; then
            fc=$(npu_fclk "$hr")
            echo "halogen npu: the GPU's fabric clock was not held, and this container may hold it: held at its top speed (${fc#held }) while the server runs"
            break
          fi
        done
      fi
      case "$fc" in
        held*) echo "halogen npu: $why; the GPU's fabric clock is held at its top speed (${fc#held }), so the NPU starts beside it" ;;
        *) echo "halogen npu: $why, and the GPU's fabric clock is not held at its top speed. On this chip the GPU and the NPU at once can hang the machine and corrupt the NPU's results while that clock changes speed." >&2
           if [ -n "$fc" ]; then
             echo "  Hold it once per boot, as root on the host: echo manual > ${fc%% *}/power_dpm_force_performance_level; echo ${fc##* } > ${fc%% *}/pp_dpm_fclk" >&2
             echo "  (or install the host unit, halogen-fabric-clock.service, which does it at every boot; undo: echo auto > ${fc%% *}/power_dpm_force_performance_level)." >&2
             echo "  Or run this container as root (docker run, sudo podman run) with -v /sys:/host/sys: it then holds the clock itself while it runs." >&2
           else
             echo "  This container cannot read the GPU's clock controls (/sys/class/drm/card*/device/pp_dpm_fclk), so it cannot tell." >&2
           fi
           echo "  Or start without HALOGEN_NPU_MODELS. HALOGEN_NPU_WITH_GPU=1 starts anyway, at that risk." >&2
           return 1 ;;
      esac
    fi
  fi
  echo "halogen npu: device /dev/accel/accel0 ($(npu_stat "$node")), driver amdxdna $drv, $xv with its NPU plugin"
}

npu_memlock() {
  local l
  l=$(ulimit -l 2>/dev/null || echo unlimited)
  [ -n "${_hg_memlock:-}" ] && l="$_hg_memlock"
  [ "$l" = unlimited ] && return 0
  [ "$l" -ge "$1" ] 2>/dev/null && return 0
  echo "halogen npu: this container may lock $l KiB of memory, and the NPU needs about $1 KiB for these models." >&2
  echo "  Add --ulimit memlock=-1:-1. A rootless container cannot go past the host user's own limit: on the host, ulimit -H -l; if it is not unlimited, add" >&2
  echo "    <user> hard memlock unlimited" >&2
  echo "    <user> soft memlock unlimited" >&2
  echo "  to /etc/security/limits.conf (or a file under /etc/security/limits.d/), log in again, and start the container from that login." >&2
  return 1
}

start_npu_engine() {
  local gpu="$1" port="${HALOGEN_NPU_PORT:-8740}" ids id n=0 first=1 rc dev w tokd own
  local bin="${_hg_npu_bin:-/usr/local/bin/halogen-npu}"
  local -a nargs
  npu_retired || exit 1
  ids=$(printf '%s' "${HALOGEN_NPU_MODELS:-}" | tr ',' ' ')
  for id in $ids; do n=$((n + 1)); done
  if [ "$n" = 0 ]; then echo "halogen npu: HALOGEN_NPU_MODELS names no model" >&2; exit 1; fi
  case "$port" in ''|*[!0-9]*) echo "halogen npu: HALOGEN_NPU_PORT=$port is not a port number" >&2; exit 1 ;; esac
  npu_preflight "$gpu" || exit 1
  NPU_NEED_K=524288
  NPU_API_ARGS=(--npu "127.0.0.1:$port")
  nargs=(listen)
  for id in $ids; do
    case "$id" in
      /*) npu_finetune_ready "$id" || exit 1
          dev="$NPU_FT_DEV"; w="$NPU_FT_W"; tokd="${id%/}" ;;
      *) npu_model_ready "$id" "$NPU_DIR" || exit 1
         own=$(npu_devices_of "$id")
         if [ "$own" != "$id" ]; then npu_model_ready "$own" "$NPU_DIR" devices || exit 1; fi
         dev="$NPU_DIR/$own/devices"; w="$NPU_DIR/$id/$id.hnpw"; tokd="$NPU_DIR/$id/tokenizer" ;;
    esac
    if [ "$first" = 1 ]; then nargs+=("$dev" "$w" "127.0.0.1:$port"); NPU_TOK1="$tokd"; first=0
    else nargs+=(--model "$dev" "$w"); fi
    NPU_API_ARGS+=(--npu-tokenizer "$tokd")
  done
  npu_memlock "$NPU_NEED_K" || exit 1
  NPU_OUT="${_hg_npu_out:-/tmp/halogen-npu.out}"
  : > "$NPU_OUT"
  "$bin" "${nargs[@]}" > >(tee -a "$NPU_OUT") &
  NPU_PID=$!
  NPU_STOP=0
  trap 'NPU_STOP=1; kill -TERM "$NPU_PID" 2>/dev/null || true' TERM INT

  local t0=$SECONDS last=$SECONDS
  until grep -q '^READY' "$NPU_OUT" 2>/dev/null; do
    if ! kill -0 "$NPU_PID" 2>/dev/null; then
      rc=0; wait "$NPU_PID" 2>/dev/null || rc=$?
      echo "halogen npu: the NPU engine exited before it was ready (rc=$rc; its own lines are above)" >&2
      exit 1
    fi
    [ "$NPU_STOP" = 1 ] && exit 0
    if [ $((SECONDS - last)) -ge 30 ]; then
      echo "halogen npu: still loading the NPU models ($((SECONDS - t0)) s)"
      last=$SECONDS
    fi
    sleep 0.2
  done
}

start_npu_alone() {
  local who rc nrc=0 arc=0
  start_npu_engine 0
  API_PID=""
  trap 'NPU_STOP=1; kill -TERM "$NPU_PID" $API_PID 2>/dev/null || true' TERM INT
  "${_hg_python:-python3}" /halogen/tools/serve_api.py \
    --engine none --tokenizer "$NPU_TOK1" "${NPU_API_ARGS[@]}" \
    --host 0.0.0.0 --port "$API_PORT" --queue-timeout "${HALOGEN_QUEUE_TIMEOUT:-3600}" &
  API_PID=$!

  set +e
  rc=0; wait -n "$NPU_PID" "$API_PID" 2>/dev/null || rc=$?
  if [ "$NPU_STOP" = 1 ]; then who="stop signal"
  elif ! kill -0 "$NPU_PID" 2>/dev/null; then who="NPU engine"
  else who="front end"; fi
  kill -TERM "$NPU_PID" "$API_PID" 2>/dev/null || true
  wait "$NPU_PID" 2>/dev/null || nrc=$?
  wait "$API_PID" 2>/dev/null || arc=$?
  if [ "$NPU_STOP" = 1 ]; then
    echo "halogen npu: stopped (NPU engine rc=$nrc, front end rc=$arc)" >&2
    [ "$nrc" = 0 ] && exit 0
    exit "$nrc"
  fi
  echo "halogen npu: the $who exited (rc=$rc); shutting down" >&2
  [ "$rc" = 0 ] && rc=1
  exit "$rc"
}

case "${1:-all}" in
  inspect|verify|ppl|niah) echo "halogen: halogen-flash-server ${HALOGEN_IMAGE_VERSION:-unknown}, mode $1" >&2 ;;
  *) echo "halogen: halogen-flash-server ${HALOGEN_IMAGE_VERSION:-unknown}, mode ${1:-all}" ;;
esac

case "${1:-all}" in
engine) start_engine ;;
api)    start_api ;;
all)
  [ "${_hg_npu_alone:-0}" = 1 ] && [ -n "${HALOGEN_NPU_MODELS:-}" ] && start_npu_alone
  need_ckpt; need_tokenizer; check_defaults

  NPU_PID=""; NPU_API_ARGS=()
  [ -n "${HALOGEN_NPU_MODELS:-}" ] && start_npu_engine 1
  "${_hg_flash_serve:-/usr/local/bin/flash_serve}" --ck "$HALOGEN_CHECKPOINT" \
      --port "$ENG_PORT" --bind 127.0.0.1 \
      --slots "$ENG_SLOTS" --ctx "$ENG_CTX" --max-tok "$ENG_MAX_TOK" --kv-pool "$ENG_POOL" &
  ENGINE_PID=$!
  trap 'NPU_STOP=1; kill -TERM "$ENGINE_PID" $NPU_PID 2>/dev/null || true' TERM INT

  echo "halogen: waiting for engine on $ENG_PORT (cold load can take minutes)"
  if ! wait_for_engine "$ENG_PORT" "$ENGINE_PID"; then
    kill -TERM "$ENGINE_PID" $NPU_PID 2>/dev/null || true
    wait "$ENGINE_PID" 2>/dev/null || true
    npu_fclk_release
    exit 1
  fi

  "${_hg_python:-python3}" /halogen/tools/serve_api.py \
    --tokenizer "$HALOGEN_TOKENIZER" \
    --engine "127.0.0.1:$ENG_PORT" \
    --host 0.0.0.0 --port "$API_PORT" \
    --max-tokens-cap "${HALOGEN_MAX_TOKENS_CAP:-65536}" \
    --context "$ENG_CTX" \
    --queue-timeout "${HALOGEN_QUEUE_TIMEOUT:-3600}" "${NPU_API_ARGS[@]}" &
  API_PID=$!

  WATCHDOG_PID=""
  if [ "${HALOGEN_ENGINE_WATCHDOG_S:-180}" -gt 0 ]; then
    engine_watchdog "$ENG_PORT" "$ENGINE_PID" &
    WATCHDOG_PID=$!
  else
    echo "halogen: engine watchdog OFF (HALOGEN_ENGINE_WATCHDOG_S=0)"
  fi

  set +e

  WRC=0; wait -n "$ENGINE_PID" "$API_PID" $WATCHDOG_PID $NPU_PID || WRC=$?
  if [ -n "$NPU_PID" ] && [ "${NPU_STOP:-0}" != 1 ] && ! kill -0 "$NPU_PID" 2>/dev/null; then
    echo "halogen npu: the NPU engine exited (rc=$WRC); shutting down" >&2
  else
    echo "halogen: a component exited (rc=$WRC); shutting down" >&2
  fi
  kill -TERM "$API_PID" $NPU_PID 2>/dev/null || true

  [ -n "$WATCHDOG_PID" ] && kill -9 "$WATCHDOG_PID" 2>/dev/null || true

  [ -n "$WATCHDOG_PID" ] && wait "$WATCHDOG_PID" 2>/dev/null || true
  stop_engine "$ENGINE_PID" || true
  wait "$API_PID" 2>/dev/null || true
  [ -n "$NPU_PID" ] && { wait "$NPU_PID" 2>/dev/null || true; }
  npu_fclk_release

  wd_gtt_after_exit
  exit 1
  ;;
bench|sweep)
  MODE="$1"
  shift || true
  text_only_mode "$MODE"
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

  python3 /halogen/tools/serve_api.py \
    --tokenizer "$HALOGEN_TOKENIZER" \
    --engine "127.0.0.1:$ENG_PORT" \
    --host 127.0.0.1 --port "$API_PORT" \
    --max-tokens-cap "${HALOGEN_MAX_TOKENS_CAP:-65536}" \
    --context "$ENG_CTX" \
    --queue-timeout "${HALOGEN_QUEUE_TIMEOUT:-3600}" 2>&1 | tee "$BENCH_LOG" &
  API_PID=$!

  API_UP=0
  for _ in $(seq 1 150); do
    python3 -c "import urllib.request,sys
try: urllib.request.urlopen('http://127.0.0.1:$API_PORT/health', timeout=3); sys.exit(0)
except Exception: sys.exit(1)" 2>/dev/null && { API_UP=1; break; }
    kill -0 "$API_PID" 2>/dev/null || break
    sleep 2
  done

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

  MODE="$1"
  shift || true
  text_only_mode "$MODE"
  FILE=""
  if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then FILE="$1"; shift; fi
  [ -n "$FILE" ] || FILE="$HALOGEN_CHECKPOINT"
  [ -f "$FILE" ] || { echo "halogen $MODE: $FILE is not there (mount the models volume and name a file inside it, or set HALOGEN_CHECKPOINT)" >&2; exit 1; }
  if [ "$MODE" = ppl ] || [ "$MODE" = niah ]; then
    tuning_plan_copy
    if [ "$(head -c 4 "$FILE" 2>/dev/null)" = "GGUF" ]; then need_head "$(dirname "$FILE")"
    else HALOGEN_CHECKPOINT="$FILE" check_ngram_table >&2
    fi
    echo "halogen $MODE: $FILE under this image's engine environment (tuning plan: ${HALOGEN_MATMUL_TUNING_FILE:-none}; quality sidecar: ${HALOGEN_CK_OVERLAY:-beside the checkpoint, if any}; trunk pinned: ${HALOGEN_FLASH_PIN_TRUNK:-1})" >&2

    need_tokenizer
    exec python3 /halogen/tools/halogen_tools.py "$MODE" "$FILE" --tokenizer "$HALOGEN_TOKENIZER" "$@"
  fi
  exec /usr/local/bin/halogen-tools "$MODE" "$FILE" "$@"
  ;;
*) [ "${1:-}" = npu ] && echo "halogen: there is no npu mode any more: the NPU's models run in the default mode beside the Flash model; set HALOGEN_NPU_MODELS (and drop the npu argument)." >&2
   echo "usage: entrypoint.sh [all|engine|api|bench|sweep|convert IN.gguf OUT.hgn|inspect|verify|ppl|niah [FILE] ...]" >&2; exit 2 ;;
esac
