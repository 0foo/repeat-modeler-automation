# Source reference

Line-by-line documentation of `worker.sh` and `rm-manager.sh`. For how to *use* the tool, see
the [README](../README.md); this document is for someone modifying, debugging or porting it.

Two standalone bash scripts and a mandatory config file. No shared library — the config
reader is duplicated verbatim between them, deliberately.

| File | Lines | Role |
|---|---|---|
| `worker.sh` | 829 | one worker: claim a genome, run both stages, record each outcome |
| `rm-manager.sh` | 311 | supervisor: start/stop/status over N workers |
| `rmodeler.conf.example` | 65 | complete, working template |
| `rmodeler.conf` | 65 | the live config (committed; differs from the example — see below) |

Roughly half of `worker.sh` is comments. They are unusually good and explain *why* rather
than *what*; this document does not repeat them, it covers the structure and the
consequences.

Line references are against the files as committed and were re-verified for this revision.

---

## 1. Two stages per genome

A genome goes through two stages, and this shapes everything below:

| Stage | Function | Runs | Produces | Marker |
|---|---|---|---|---|
| model | `stage_model` (`worker.sh:541-591`) | `BuildDatabase` + `RepeatModeler` | `$OUT_DIR/<sample>-families.fa` | `done/<sample>` |
| mask | `stage_mask` (`worker.sh:601-660`) | `RepeatMasker -lib` | `$OUT_DIR/<sample>.rm.out` | `masked/<sample>` |

The mask stage runs only when `RUN_MASKER=1`. `process_one` (`worker.sh:700-758`) decides
which stages are due by looking at the markers that already exist, and **each stage writes its
own marker the instant it succeeds** (`worker.sh:740`, `:752`) rather than one marker at the
end.

That split is the whole point. Three consequences follow:

- **Enabling masking later costs nothing extra.** Set `RUN_MASKER=1` and every genome holding
  a `done/` marker becomes available again for the mask stage alone. The library is copied
  back out of `$OUT_DIR` (`worker.sh:613-614`), which is the only place it survives once the
  job directory is deleted.
- **A failed mask does not cost you the model.** A genome that models in 20 hours and then
  fails during RepeatMasker keeps `done/` and its library, so the retry is one RepeatMasker
  run.
- **The stages log separately** — `<sample>.log` and `<sample>.masker.log`, truncated
  independently at `worker.sh:733` and `:745` — so a mask-only retry cannot destroy the
  RepeatModeler log belonging to the library it is using.

If the `done/` marker exists but the library is gone, the worker fails that genome with an
explicit message (`worker.sh:617-618`) rather than silently re-modelling it.

---

## 2. Configuration

### The contract

`worker.sh:204-251`, duplicated at `rm-manager.sh:105-154`.

Eighteen recognised keys:

```
IN_DIR WORK_DIR OUT_DIR STATE_DIR LOG_DIR RUN_DIR
RM_IMAGE DOCKER THREADS MEM_LIMIT GLOB
LTRSTRUCT KEEP_WORK RETRY_FAILED STOP_GRACE WORKERS
RUN_MASKER KEEP_MASKED_FASTA
```

Both scripts accept all eighteen even though each uses only a subset (`WORKERS` and `RUN_DIR`
are the manager's; the rest are mostly the worker's). One file serves both.

The reader enforces, in order:

1. every non-blank, non-comment line is `KEY=value` — otherwise `die`
2. the key matches `^[A-Za-z_][A-Za-z0-9_]*$` — otherwise `die`
3. the key is in `CONFIG_KEYS` — **an unknown key is a hard error, not a skipped line**
4. the key has not already been seen — duplicates `die`
5. one matching pair of surrounding quotes is stripped
6. after the file is read, every key in `CONFIG_KEYS` must have been seen

Point 3 is the one that earns its keep. A typo'd setting that is silently ignored looks
exactly like one that was applied, and you find out three hours into a run.

### Why environment variables are discarded

`worker.sh:212` unsets all eighteen names *before* reading the file. `THREADS=2 ./worker.sh`
does not override, and does not survive as a leftover either.

The reasoning: N workers share `$STATE_DIR`, `$OUT_DIR` and `$WORK_DIR`, and only behave if
all of them were configured identically. A per-invocation override is precisely how two
workers end up disagreeing about where the queue lives.

Note the interaction with `rm-manager.sh`: the manager `export`s every setting, so launched
workers inherit them — but each worker then *re-reads and unsets* them anyway
(`rm-manager.sh:113`). A worker started by hand and one started by the manager are configured
identically by construction.

### Not `source`

The reader is hand-rolled rather than `source rmodeler.conf`. The config file therefore cannot
execute shell commands — it can only set the eighteen names.

### Validation

`validate_config()` (`worker.sh:255-268`):

- nine path/name settings must be non-empty
- `THREADS`, `WORKERS` must match `^[1-9][0-9]*$`
- `LTRSTRUCT`, `KEEP_WORK`, `RETRY_FAILED`, `RUN_MASKER`, `KEEP_MASKED_FASTA` must be exactly
  `0` or `1`
- `STOP_GRACE` must be `^[0-9]+$` (zero permitted, unlike the five above)
- `IN_DIR` must exist

`MEM_LIMIT` is **not** validated and may be empty (meaning unlimited). It is passed through to
`docker run --memory` unchecked (`worker.sh:360`).

### The committed `rmodeler.conf`

It differs from the example in four values:

```diff
-IN_DIR=/data/genomes
+IN_DIR=/data/genomes/1_masked_datasets/genomes_dhakad
-WORK_DIR=/scratch/rmodeler/work
+WORK_DIR=/data/rmodeler/scratch/rmodeler/work
-WORKERS=4
+WORKERS=2
-THREADS=6
+THREADS=2
```

Two workers × 2 threads = 4 cores, versus the example's 24. This is a real machine's config,
not a template — it carries the paths of the machine this was developed on.

> Committing a live `rmodeler.conf` means a fresh clone silently inherits someone else's
> paths. It contains no secrets, but `cp rmodeler.conf.example rmodeler.conf` — the documented
> first step — will refuse to overwrite without `-f`, so check what you have.

> The `1_masked_datasets` component of that `IN_DIR` is worth a second look. If those
> assemblies are already repeat-masked, both stages behave differently than they would on raw
> ones — RepeatModeler has less to find, and RepeatMasker is re-masking masked sequence. Not
> verified either way here.

---

## 3. Concurrency

The state machine:

```mermaid
stateDiagram-v2
    [*] --> Available: genome file exists in IN_DIR
    Available: <b>available</b><br/>has an unfinished stage, not claimed or failed<br/>(recomputed every pass, never recorded)
    Claimed: <b>claimed/&lt;sample&gt;/</b><br/>owner file records host + pid + container
    Done: <b>done/&lt;sample&gt;</b><br/>families file is in OUT_DIR<br/>still available for the mask stage
    Masked: <b>masked/&lt;sample&gt;</b><br/>sample.rm.out is in OUT_DIR
    Failed: <b>failed/&lt;sample&gt;</b><br/>scratch dir and logs kept

    Available --> Claimed: mkdir succeeded<br/>(exactly one winner)
    Claimed --> Done: RepeatModeler succeeded
    Claimed --> Failed: rc 1
    Claimed --> Available: rc 130 — SIGTERM<br/>no marker written
    Claimed --> Available: reap_stale_claims()<br/>owner pid is dead on this host
    Done --> Masked: RUN_MASKER=1<br/>RepeatMasker succeeded
    Failed --> Available: RETRY_FAILED=1<br/>or rm failed/&lt;sample&gt;
    Done --> Available: rm done/&lt;sample&gt;
    Masked --> Available: rm masked/&lt;sample&gt;<br/>re-masks, no re-modelling
```

### State is directory names

```
$STATE_DIR/claimed/<sample>/owner    in progress
$STATE_DIR/done/<sample>             RepeatModeler finished OK
$STATE_DIR/masked/<sample>           RepeatMasker finished OK (RUN_MASKER=1 only)
$STATE_DIR/failed/<sample>           a stage failed, scratch + logs kept
```

A genome is **available** when it still has an unfinished stage and is neither claimed nor
failed. That state is not recorded anywhere — it is inferred from the absence of the markers
above, recomputed from `$IN_DIR` on every pass (`worker.sh:809-816`).

Note that `done/` no longer means "finished". With `RUN_MASKER=1` a modelled genome stays
available for the mask stage until `masked/` exists too, which is exactly what makes turning
masking on later work.

Nothing is ever *read* to decide what to work on next. There is no file for workers to
disagree about and nothing to keep in sync.

### `claim()` — the whole lock

```bash
claim() {
    mkdir "$STATE_DIR/claimed/$1" 2>/dev/null || return 1
    printf 'host=%s\npid=%s\nworker=%s\ncontainer=%s\nstart=%s\n' … > …/owner
}
```

`worker.sh:463-468`. On a local filesystem `mkdir` is atomic: the kernel performs the
does-it-exist check and the create as one indivisible operation. N workers racing for one
genome produce exactly one exit status 0 and N-1 `EEXIST`.

There is deliberately **no `if [ -d … ]` test** before it. That would reintroduce the
test-and-set window the design exists to avoid.

The marker checks in the main loop (`worker.sh:809-816`) are an optimisation only — they skip
pointless `mkdir` attempts and are *allowed to be stale*. The `mkdir` is the only
authoritative step. `process_one` re-reads the markers after winning the claim
(`worker.sh:708-713`) and returns immediately if there is nothing left to do.

> **`STATE_DIR` must be local.** `mkdir` atomicity is not dependable over NFS. This is the
> single assumption the whole scheme rests on, and violating it produces duplicate runs in a
> shared job directory, not an error message.

### `unclaim()`

```bash
unclaim() { rm -rf "${STATE_DIR:?}/claimed/${1:?}"; }
```

`worker.sh:476`. The `${VAR:?}` expansions make an unset or empty variable a loud failure
rather than an expansion to nothing — a bug can never turn this into `rm -rf /claimed/`.

Called for **every** outcome, because it is the `done/`, `masked/` or `failed/` marker, not the
claim, that keeps a genome from being picked up again.

### `reap_stale_claims()`

`worker.sh:487-512`, runs once at startup, before the main loop.

For each `claimed/*/`:

- no `owner` file → **skip and log**. A worker died between the `mkdir` and the write. The
  script refuses to guess; clear it by hand once you are sure nothing is running.
- `host` != this host → **skip**. Pid 4823 here tells you nothing about pid 4823 elsewhere,
  and releasing it would return a genome another box is actively working to the pool.
- `kill -0 $pid` fails → **reap**: `docker rm -f "${cname}-db" "${cname}-rm" "${cname}-mask"`,
  then unclaim.

Note the suffixes. The owner file records the *base* container name; the stages always launch
`<base>-db`, `<base>-rm` and `<base>-mask`, never the bare base. All three are removed;
whichever doesn't exist errors harmlessly under the redirect.

### `shuf` is not cosmetic

`worker.sh:826`:

```bash
done < <(find "$IN_DIR" -maxdepth 1 -name "$GLOB" -type f | shuf)
```

Without `shuf`, every worker walks the identical list in the identical order. Workers 2..N
lose the race on genome 1, then on genome 2, then on genome 3 — hundreds of wasted `mkdir`
calls before they find open work. Shuffling scatters them so collisions are rare.

It is a process substitution rather than `find … | while read` because a pipeline runs the
loop body in a **subshell**, where `processed` would be discarded at the end and the traps
would not behave.

---

## 4. Signals and shutdown

### `set -uo pipefail`, no `-e`

`worker.sh:152`. Unset variables are fatal; a pipeline fails if any stage failed. `-e` is
deliberately absent: **one genome failing must not kill the worker.**

### The trap

`on_term()` (`worker.sh:304-321`) does two things: set `SHUTDOWN=1` so the main loop stops
taking new work, and stop the running container.

The container is stopped **by name**, not by killing `$CHILD_PID`. The container is a child of
the Docker daemon, not of this script — killing the `docker run` client would leave the tool
running and chewing cores with nothing watching it.

There is a retry loop around `docker stop`, because `CURRENT_CONTAINER` is set just *before*
`docker run` launches and the container may not exist in the daemon yet if the signal lands in
that window. Up to 20 attempts at 0.25 s, with an early exit if the client process is already
gone.

`SIGHUP` is swallowed (`worker.sh:326`) so closing the terminal doesn't kill a worker started
without `nohup`.

### Why `docker_run` loops around `wait`

`worker.sh:390-395`:

```bash
while :; do
    wait "$CHILD_PID"; rc=$?
    if (( rc > 128 )) && kill -0 "$CHILD_PID" 2>/dev/null; then continue; fi
    break
done
```

When a trapped signal arrives while bash is blocked in `wait`, bash abandons the wait, runs
the trap, and has `wait` return 128+signum — **but the child is often still alive**, because
`docker stop` takes up to `STOP_GRACE` seconds. Returning while the container still runs would
let the caller move on and start a second container in the same job directory.

So: if the status is above 128 *and* the process still exists, wait again. `kill -0` sends no
signal, it only tests existence.

### rc 130 — "aborted, not failed"

The script's private convention. Both stage functions check `(( SHUTDOWN ))` before treating a
non-zero exit as failure — `worker.sh:547`, `:564`, `:569`, `:579` in `stage_model`, and
`:606`, `:637` in `stage_mask` — and `process_one` checks again after decompression, before
committing to any container at all (`worker.sh:727-730`).

Without those checks, every clean shutdown would wrongly mark its in-flight genome **failed** —
because stopping a container makes `docker run` exit non-zero, which is indistinguishable from
a genuine failure unless you check whether you were the one who stopped it.

`finish_failed_stage()` (`worker.sh:671-680`) handles the two unsuccessful outcomes, and
`process_one` the successful one:

| rc | marker | scratch | logs |
|---|---|---|---|
| 0 | `done/` and/or `masked/` | deleted unless `KEEP_WORK=1` | kept |
| 130 | **none** | deleted | kept |
| other | `failed/` | **kept** | kept |

rc 130 writing no marker is what makes an interrupted stage look untouched on the next pass.
Because the markers are per-stage, an abort during masking leaves the `done/` marker intact —
only the mask is repeated.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | queue exhausted, finished normally |
| 2 | configuration problem |
| 127 | docker missing, or image not present locally |
| 143 | stopped by SIGTERM (128+15) |

---

## 5. The container invocation

`docker_run()` (`worker.sh:357-399`). Every flag is there for a reason:

| Flag | Why |
|---|---|
| `--rm` | 300 genomes × 3 container calls would otherwise leave 900 dead containers |
| `--init` | a real pid 1 to reap zombies; RepeatModeler forks heavily |
| `--name` | so `on_term` can stop it, and so a stale claim's orphan can be found |
| `--label rmworker.sample=…` | lets `docker ps --filter` list only our containers |
| `--user $(id -u):$(id -g)` | without it every output file is owned by root |
| `--cpus $THREADS` | a **hard ceiling** — RepeatModeler ignores thread counts in places |
| `-v $jobdir:$jobdir` | mounted at the **identical host path** |
| `-w $jobdir` | start there |
| `-e HOME=$jobdir` | `--user` leaves the container with no valid home |

The identical-path mount (same convention `dfam-tetools.sh` uses) matters because
RepeatModeler writes **absolute paths into its round logs and errors**. Matching paths mean a
trace you can follow on the host without translating.

One image serves both stages: `dfam/tetools:latest` bundles RepeatMasker alongside
RepeatModeler, so the mask stage needs no second image and no second mount.

`safe_name()` (`worker.sh:407`) reduces a sample name to `[A-Za-z0-9_.-]`, capped at 100 chars
to leave room for the `-db` / `-rm` / `-mask` suffixes. It uses `printf` rather than a
here-string because a here-string appends its own newline, which `tr -c` would transliterate
into a trailing `_` on every generated name.

### `MEM_LIMIT` and the OOM trap

If set, `--memory` and `--memory-swap` are both applied. **A cgroup OOM kill surfaces as an
ordinary non-zero exit**, so a genome killed that way lands in `failed/` with a truncated log
and no obvious cause. If one fails suspiciously fast, check `dmesg` before believing the log.

### `-threads` vs `-pa`

`detect_thread_flag()` (`worker.sh:424-446`). `-pa` was deprecated in RepeatModeler 2.0.4 in
favour of `-threads`. Rather than assume, the worker runs `RepeatModeler -help` once and greps
for `-threads`.

The answer is a property of `$RM_IMAGE`, not of the worker, so it is cached at
`$STATE_DIR/.thread_flag_mode` (`worker.sh:425`) — with N workers sharing one image, only the
first to ask launches a probe container. A lost race just means two probe instead of one.
Harmless.

On an old build, `-pa` counted 4-core BLAST jobs rather than cores, so the requested thread
count is divided by four (floor 1).

The result is stored in an **array**, so it expands to two separate arguments rather than one
string containing a space.

**This detection applies to RepeatModeler only.** RepeatMasker has no `-threads` spelling to
detect; `stage_mask` passes `-pa "$THREADS"` unconditionally (`worker.sh:635`), where `-pa` is
RepeatMasker's own count of parallel search jobs. The container's `--cpus` ceiling still
applies on top.

### No `-engine`

`worker.sh:548-553`. Current RepeatModeler (checked against 2.0.9) dropped AB-Blast support
and removed `-engine` from `BuildDatabase`'s argument list — passing it is a hard "Unknown
option: engine" failure. RepeatModeler itself still parses it but hardcodes rmblast and
ignores the value. The flag is gone from both calls.

### `-xsmall` on the mask stage

`worker.sh:635`. RepeatMasker soft-masks rather than replacing repeats with `N`, so
`<sample>.fa.masked` remains usable as sequence for the downstream motif scanning in
`build_tfbs_te_gff.py`. It has no effect on the `.out` table, which is what the rest of the
pipeline actually consumes.

### Decompression happens on the host

`decompress_genome()` (`worker.sh:522-532`) runs `zcat "$gz" > "$jobdir/$sample.fa"` outside
any container. This means `$IN_DIR` is **never mounted into the container** — a container only
ever sees one genome's scratch directory. It runs once per attempt, because both stages need
the FASTA.

### Output is verified, not assumed

Both stages check their product before declaring success: `<sample>-families.fa` at
`worker.sh:584`, and `<sample>.fa.out` at `worker.sh:642`. RepeatModeler can exit 0 having
produced nothing usable, and RepeatMasker writes its `.out` even for a genome with no hits at
all — so an empty one means the run did not really finish.

---

## 6. `rm-manager.sh`

Three subcommands. That is the entire interface; extra arguments are rejected rather than
ignored (`rm-manager.sh:305`) because `start 4` used to mean "four workers" and must not now be
silently read as `start`.

### `start`

`rm-manager.sh:181-220`. Pulls the image if absent (once, here, rather than letting four
workers each start the same download — the workers themselves *refuse* rather than pull).

Then for slots 1..`WORKERS`: skip any whose pid file names a live process, otherwise

```bash
setsid nohup "$WORKER" >>"$LOG_DIR/worker-$i.out" 2>&1 </dev/null &
echo $! > "$pidf"
sleep 2
```

- **idempotent** — run it again after one worker dies and only the dead slot is refilled
- **raising `WORKERS` is safe** — edit the config, run `start` again; running slots are left
  alone and a new worker just joins in
- **the 2 s stagger** stops all workers decompressing a genome at the same instant and
  thrashing the disk before any reaches RepeatModeler

### `stop`

`rm-manager.sh:229-250`. Walks **pid files**, not 1..`WORKERS`, so lowering `WORKERS` can never
strand a running worker with nothing to stop it.

The pid file is not removed immediately. A background subshell polls until the process actually
exits, then removes it (`rm-manager.sh:244`):

```bash
( while kill -0 "$pid" 2>/dev/null; do sleep 1; done; rm -f "$pidf" ) &
disown
```

If the pid file vanished right away, a `start` run in that window would see a free slot and
launch a second worker while the first is still shutting down. `stop` still returns
immediately.

> **Never `kill -9` here.** A hard kill orphans claims and containers. They are recoverable —
> the next worker startup reaps them — but you lose the graceful container shutdown and
> `status` is misleading until then.

### `status`

`rm-manager.sh:263-299`. **Two independent views that can legitimately disagree:**

- which worker *processes* are alive, from pid files
- what the *queue* looks like, read straight from the state directories — the same source of
  truth the workers use, so it is accurate even for workers started by hand

Plus live containers filtered by the `rmworker.sample` label, and the contents of `claimed/`.

The stage counts are reported separately:

```
queued  : 12
running : 2
modelled: 7
masked  : 5
failed  : 0
```

`modelled` and `masked` are **stages, not a total**: with `RUN_MASKER=1` a genome is only
finished when it appears in both. `masked` is printed either way, because markers left over
from an earlier `RUN_MASKER=1` run do not disappear when the setting is turned off — the line
is annotated in that case.

> `queued` is the **total** input count, not the remaining count. Remaining is
> `queued - done - failed - running`.

A claimed genome with no matching container usually means the worker is decompressing — or the
claim is stale.

---

## 7. Operating it

```bash
ls state/done | wc -l                 # genomes modelled
ls state/masked | wc -l               # genomes masked
ls -l state/claimed/                  # what is running, and since when
ls state/failed                       # what blew up
cat logs/<sample>.log                 # why the modelling blew up
cat logs/<sample>.masker.log          # why the masking blew up
rm state/masked/GCA_002110            # redo just its RepeatMasker run
rm state/done/GCA_002110 state/masked/GCA_002110    # redo the genome from scratch
rm state/failed/*                     # retry all failures on the next pass
```

> **Do not delete anything from `claimed/` while workers are running.** That makes a live
> genome look available and a second worker will start a duplicate run in a job directory
> already in use. Stop the worker instead.

### Sizing

Total cores ≈ `WORKERS × THREADS`, capped per container by `--cpus`. On 24 cores / 124 GB,
4 × 6 is the documented starting point.

**Disk is the real constraint, not RAM.** A work directory with all RECON rounds retained runs
20–80 GB per genome. Keep `KEEP_WORK=0` and put `$WORK_DIR` somewhere big, fast and local.

`LTRSTRUCT=1` roughly doubles wall time and disk. The archive's observed run with it enabled
has been observed to take ~45 hours, against the 8–26 hour range typical without it.

`RUN_MASKER=1` adds RepeatMasker's own runtime — typically an hour or two per genome, far
smaller than the modelling stage, but it is not free and it competes for the same cores.

---

## 8. Observations

**The duplicated config reader.** ~80 identical lines in both files, called out as deliberate
at `rm-manager.sh:86-92`: "these are two standalone scripts with no shared library." That is a
defensible trade — each file can be copied somewhere and still work — but it is a real
maintenance hazard. A fix to the parser has to be applied twice, and adding `RUN_MASKER` and
`KEEP_MASKED_FASTA` required editing both `CONFIG_KEYS` arrays and both validators. If you
change one, change both, and consider adding a test that diffs the two blocks.

**`usage()` parses its own source.** `worker.sh:161` does `sed -n '3,34p' "${BASH_SOURCE[0]}"`.
Editing the header comment silently changes the help output, and inserting lines above line 34
breaks it. The RepeatMasker change had to be written into the existing three description lines
for exactly this reason.

**No per-worker `--cpus` affinity.** `--cpus` caps total CPU time but does not pin cores. Four
workers at 6 threads on 24 cores will contend rather than partition. In practice RepeatModeler
is I/O-bound enough in places that this hasn't mattered, but it is not the same as
`--cpuset-cpus`.

**Logs are truncated on retry.** `process_one` does `: > "$logf"` (`worker.sh:733`) and
`: > "$maskf"` (`:745`). A retried stage loses the previous attempt's log for *that stage*.
Since the stages log separately a mask-only retry no longer destroys the modelling log, but if
you are debugging an intermittent failure, copy the log aside before retrying.

**The mask stage re-decompresses.** A mask-only pass wipes the job directory and decompresses
the genome again (`worker.sh:717`, `:719`) even though only RepeatMasker will run. That is a
few minutes against RepeatMasker's hour or two, and it keeps `process_one` to one code path —
but it is avoidable work if you ever need to mask a large batch in a hurry.
