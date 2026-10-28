# Give it a machine of its own

**This server is built to own its machine.** The weights stay resident and
the KV pool is reserved up front; on a 128 GB machine that leaves roughly
twelve gigabytes free, and very little of it in the large contiguous pieces
that another big process needs in order to start or to grow. If you must
share, the levers are the pool, `HALOGEN_WEIGHTS_LOCK=1`, and sizing your
neighbours to the `host memory left` line, not to `free`.

If you run application containers, a database, or another model on the same
machine, they compete for what is left. When it runs out, allocations do not
fail cleanly: the kernel goes looking for contiguous memory it cannot find,
and whatever asked for it, including this server, can stop for minutes at a
time at 100% of one core with no disk activity and no output. It is not a
crash, it needs no restart, and it looks exactly like a hang.

**The watchdog knows the difference.** Before it counts a silent probe it
reads the engine's thread states and the kernel's compaction counter, and
silence with a thread in uninterruptible sleep or with `compact_stall`
climbing is logged as `not counted as a wedge` and does not take the
container down. It matters more than it sounds: on the host in issue #79 the
old watchdog's kill landed on an engine in exactly that state, twice, and the
driver then kept the engine's GPU memory after the process was gone, so
every later start hung until the host rebooted (the end state issue #34's
two machines and our own gate machine each reached by a different unclean
exit). A restart policy turns that into a loop.

The deferral has a bound: the compaction counter is host-wide, so on a
machine that compacts memory without pause it says nothing about this
engine, and until 0.12.2 the watchdog also restarted its clock on every
deferred probe: a reporter's engine sat wedged for 30 minutes, main thread
at 100% of one core, `/health` timing out, container up (issue #85). The
watchdog now prints the true silence on every line and, after
`HALOGEN_ENGINE_WATCHDOG_DEFER_S` (900 s) of deferral with the engine's
threads running rather than inside the kernel, takes the container down with
a line that says why. An engine with a thread in uninterruptible sleep is
still never killed.

Two host settings come up here:

- `amdgpu.noretry=0` on the kernel command line (ours has it) makes the GPU
  retry a lost page mapping instead of faulting, which turns the fault in
  issue #83 into the silent engine in issue #85: the same event, a hang
  instead of an error.
- `vm.compaction_proactiveness=0` does not stop the stalls and slows the
  startup reservation, which waits on that compaction to build the KV pool;
  a reporter measured both and restored the kernel default (issue #85).

If you run this server beside other work, read the watchdog's lines before
trusting a restart policy to recover anything, and see [the host settings
section](troubleshooting.md#the-host-settings-these-numbers-were-measured-on)
for what a start on such a host says. Issue #85 tracks the stalls and wedges
under host memory pressure across hosts.

## What the server leaves the host

The startup line says how much room is left, and a second line says why your
own tools will disagree:

```
startup [   4.9 s] host memory left for everything else: 465 contiguous 2 MiB
                   blocks (12.4 GiB total, most of it not contiguous)
startup [   4.9 s] free(1) and MemAvailable will report about 80.4 GiB
                   instead: the kernel counts this server's locked weights as
                   reclaimable file cache, and they cannot be reclaimed
```

**Believe the first line.** `free`, `MemAvailable`, and every monitoring tool
that reads them, count this server's locked weights as reclaimable page
cache, so they overstate the memory available on this host by the size of the
model, about 62 GiB (68 with w4b). No kernel field reports the difference
(`Mlocked` and `Unevictable` both stay at zero across the load), which is why
the server has to print the correction itself. With `HALOGEN_WEIGHTS_LOCK=1`
(below) the weights are locked in the kernel's sense too, `Mlocked` and
`Unevictable` carry them, `free` and `MemAvailable` drop by their size, and
the second line is not printed because there is nothing to correct.

A few hundred blocks is normal for this server and is fine on a host of its
own. If that number is small and you have other work on the machine, expect
the stall described above. Options, in the order worth trying:

1. **Give it its own machine.** This is the honest answer for a server that
   holds this much of one.
2. **Lower `HALOGEN_KV_POOL_POSITIONS`.** Fewer conversations stay resident
   at once; each one's speed and its answers are unchanged.
3. **`HALOGEN_WEIGHTS_LOCK=1`**, for a host that is already short (below).
4. **`HALOGEN_FLASH_PIN_TRUNK=0`**, w4b only, a last resort (below).

Compacting memory afterwards does not help, because the memory this server
holds cannot be moved. If you need to reclaim it, stop the server.

### `HALOGEN_WEIGHTS_LOCK=1`: the weights stop being reclaimable

"Reclaimable page cache" above is not only a reporting problem. The weights
are registered with the GPU as ordinary file-backed memory, and this server
also streams a 47 GiB lookup table through the same file cache on every
request, so when the host is short the kernel reclaims weight pages to make
room for table rows, and the GPU driver has to tear down and restore the
engine's mapping each time. That cycle is what the stalls in issue #85 and
the read faults in issue #83 look like from the outside, and each request
line's `GPU queues evicted N ms` (`halogen:gpu_queues_evicted_seconds_total`
in `/metrics`) counts the time it costs. With the flag set the server
`mlock`s every weight page it registers (never the table), so the kernel
cannot reclaim them, and the pressure lands somewhere visible instead. The
kernel can still move locked pages to compact memory, which costs the same
cycle, unless the host turns that off (below).

Measured both ways on two machines:

| | result |
|---|---|
| 20 GiB co-tenant, weights **unlocked** | silenced from the first request; the watchdog took it down after 15 minutes |
| 12 GiB co-tenant, weights **locked**, under 1 GiB left on the host | 81 of 81 requests answered, about 5% longer walls |

> [!NOTE]
> The other side of that coin: a co-tenant that asks for more than the host
> has left triggers the OOM killer, and the OOM killer picks the process with
> the largest resident set, which is this server (its locked weights count).
> The container then exits with status 137 within seconds rather than sitting
> silent for 15 minutes, a restart policy brings it back, and it will be
> killed again until the co-tenant is gone. Neither is a way to share the
> machine; the lock just makes the failure fast and legible.

It costs nothing on a warm start (the lock is a fraction of a second over
resident pages; the startup line `checkpoint: locked ...` says how long and
what `MemAvailable` did), and changes no output: the same bytes at the same
addresses.

It needs the memlock limit to cover the weights, and here the
`--ulimit memlock=-1:-1` on every run line is not enough by itself: a
rootless container cannot raise that limit above your user's hard limit, and
Ubuntu's default is 8 MiB (Podman clamps it silently; measured on a fresh
Ubuntu 26.04 install, where the lock failed after 0 bytes). Check with
`ulimit -H -l` on the host; if it does not say `unlimited`, add

```
<user> hard memlock unlimited
<user> soft memlock unlimited
```

to `/etc/security/limits.conf` (or a file under `/etc/security/limits.d/`),
log in again, and start the container from that login. The container says so
at startup when it can see the limit is short, the engine says so again if
the lock fails, and it runs unlocked either way. It is opt-in until the
reporters on those two issues have run it.

To stop compaction from moving the locked weights, set this on the host
(it lasts until a reboot unless you also put it in a file under
`/etc/sysctl.d/`):

```
sudo sysctl vm.compact_unevictable_allowed=0
```

Holding the weights in a pinned allocation instead was measured as well and
made things worse: about five times the queue-eviction time on a fragmented
test host, because everything else then has to move around a fixed 62 GiB
block. The lock with that setting is what takes the weights out of the
cycle.

### `HALOGEN_FLASH_PIN_TRUNK=0`: last resort, w4b only

v2 and ht43 refuse it at startup. It gives a great deal of memory back and
costs **several times the decode speed** (6 tokens/s against 37 on the
reference machine) and a fixed cost on every prompt of 64 tokens or more,
which copies each layer's experts onto the GPU once: about 7 s when the
weights are in the file cache (the whole reason for the setting is that they
are no longer locked there) and 25 to 50 s when the kernel has let them go to
disk. Measured: a 32,768-token prompt in 26.6 s against 26.7 pinned and
8,192 in 8.8 against 7.1 with the weights cached; served, a 6,500-token
prompt in 28 s and 51 s on the first request after a start. It is a last
resort, not a tuning option. Through 0.12.1 it did not work at the shipped
settings at all (the first request ended the server with `internal sizing error in the per-forward arena`, issue #83); since 0.12.2 it does.

## If you must share it

The weights take about 62 GiB (68 with w4b) whatever you set. They are file
cache the kernel can reclaim or move unless you lock them (above).
Everything else the server takes is decided by three settings, so sharing
the machine means choosing how much of the other half you keep. What each
configuration takes is the engine's own fit arithmetic (the same model the
startup uses to size the pool), and it does not depend on the machine; what
is left does, so read the `host memory left for everything else` line on
yours and believe it over `free`.

| configuration | device side | halogen takes | what you give up |
|---|---|---|---|
| the Quickstart defaults: pool 524,288, 4 slots, `MAX_TOK` 32768 | ~27 GiB | ~89 GiB | nothing |
| pool 262,144, 2 slots | ~20 GiB | ~82 GiB | one full-length conversation resident at a time |
| pool 262,144, 2 slots, `MAX_TOK` 16384 | ~15 GiB | ~77 GiB | the above, and prefill about 9% slower |
| context 131,072, pool 131,072, 2 slots, `MAX_TOK` 16384 | ~12 GiB | ~74 GiB | the above, and half the context |

The rows are the default checkpoint (0.15.1's startup figures). With w4b add
6 GiB to the "halogen takes" column in every row: that is its weights, 68.0
GiB pinned against 62.1. In the two `MAX_TOK` 16384 rows add 3 more to both
columns, because its experts keep about 6 GiB of scratch at any `MAX_TOK`;
at 32768 the device side is the same. A GGUF is sized like w4b and adds to
it. Unsloth's `UD-IQ4_XS` holds 72 GiB of weights instead of 68, and the
K-quant `UD-Q4_K_XL` 78 to 80 GiB, so add 4 or 12 GiB to the w4b figures.
The engine refuses the last pin when it would leave under 16 GiB, and on a
122 GiB box the K-quant at the Quickstart's `MAX_TOK` lands 2 GiB under that
floor (issue #80); `HALOGEN_MAX_TOK=16384` is the row that fits it. The
pre-flight check reads the GGUF's file type and sizes the estimate
accordingly, and the refusal names the levers.

Every recipe below assumes the weights are already in `~/halogen-models`
(the Quickstart's first start put them there). On Docker, replace
`--group-add keep-groups` with `--group-add video --group-add render`. With
the shipped `docker-compose.yml`, put the same variables under the engine's
`environment:`.

**Share about a third of the machine.** One conversation at the full context
stays warm between turns; two of them alternating re-prefill on each turn;
two shorter ones (100k each, say) both stay warm. Speed and answers are
unchanged.

```bash
podman run --rm -p 8731:8731 \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --ipc=host --ulimit memlock=-1:-1 \
  -e HALOGEN_KV_POOL_POSITIONS=262144 \
  -e HALOGEN_KV_SLOTS=2 \
  -v ~/halogen-models:/models:ro \
  ghcr.io/peonist-ai/halogen-flash-server:0.18.18
```

**The smallest footprint at the full context.** The prefill arena halves.
Prefill runs about 9% slower (measured at 262k through the server), and a
prompt admitted while another stream is decoding stalls it for half as long.
Nothing else changes.

```bash
podman run --rm -p 8731:8731 \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --ipc=host --ulimit memlock=-1:-1 \
  -e HALOGEN_KV_POOL_POSITIONS=262144 \
  -e HALOGEN_KV_SLOTS=2 \
  -e HALOGEN_MAX_TOK=16384 \
  -v ~/halogen-models:/models:ro \
  ghcr.io/peonist-ai/halogen-flash-server:0.18.18
```

**If 131k of context is enough.** The pool cannot be smaller than one
request's context, so a smaller context is what lets it go under 262,144. A
prompt at or past 131,072 tokens gets a 400 that says so.

```bash
podman run --rm -p 8731:8731 \
  --device /dev/kfd --device /dev/dri --group-add keep-groups \
  --ipc=host --ulimit memlock=-1:-1 \
  -e HALOGEN_CTX=131072 \
  -e HALOGEN_KV_POOL_POSITIONS=131072 \
  -e HALOGEN_KV_SLOTS=2 \
  -e HALOGEN_MAX_TOK=16384 \
  -v ~/halogen-models:/models:ro \
  ghcr.io/peonist-ai/halogen-flash-server:0.18.18
```

**Beside other GPU servers, count the hardware queues.** Another project
measured that the iGPU stays 100% busy at idle, drawing about 30 W instead
of 4, once more than 8 hardware compute queues are open across all
processes. This server holds 2. `GPU_MAX_HW_QUEUES` caps how many a HIP
process opens, so start the other GPU servers with `GPU_MAX_HW_QUEUES=1`
or `2` to keep the total at 8 or fewer. Each process's queues are listed in
`/sys/class/kfd/kfd/proc/<pid>/queues/`, and a `type` of 0 is a compute
queue.

Two things hold for all of them. The lookup table (the n-gram embedding,
47.7 GiB, read from the file on demand) lives in the page cache, not in the
numbers above. A neighbour that pushes it out makes the next cold prompt
read its rows from disk before it starts: about 1.3 s on a 32k prompt from
an NVMe drive, more from a slower one, and the `lookup table: ... took N s`
log line reports any read of 2 s or more. And a neighbour that takes the
room this server was going to grow into produces the stall described above,
on both sides. The `host memory left` line is the budget. Size the
neighbours to it, not to `free`.

---

## History

| shipped | what arrived |
|---|---|
| 0.11.9 | the watchdog stops killing engines silent inside the kernel; the GGUF-aware pre-flight |
| 0.12.2 | `HALOGEN_FLASH_PIN_TRUNK=0` works at the shipped settings (before it the first request ended the server, issue #83); the watchdog's defer bound was still unbounded per probe |
| 0.12.3 | the watchdog's deferral bound (`HALOGEN_ENGINE_WATCHDOG_DEFER_S`, 900 s) after issue #85's 30-minute silent wedge |
| 0.13.2 | `HALOGEN_WEIGHTS_LOCK=1` (opt-in) |
