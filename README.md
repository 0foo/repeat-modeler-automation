# repeat-modeler-automation

Runs **RepeatModeler** and then **RepeatMasker** over a directory of gzipped genome FASTAs,
across parallel workers, unattended.

It exists because a single genome takes **8–26 hours** (sometimes far longer) to model. At
that cost you cannot supervise a run, you cannot afford to lose one to a reboot, and you need
several genomes going at once. So this is a small piece of crash-tolerant infrastructure
rather than a script.

Each genome goes through two stages:

| Stage | Runs | Produces |
|---|---|---|
| **model** | `BuildDatabase` + `RepeatModeler` | `<sample>-families.fa` — the repeat library for that species |
| **mask** | `RepeatMasker -lib <families>` | `<sample>.rm.out` — where every copy of those repeats sits |

The mask stage runs only when `RUN_MASKER=1`. Each stage records its own state marker the
moment it succeeds, so the two restart independently — see [Restarting](#restarting).

---

## What you need

- **Docker** (or `podman`, or `sudo docker` — set `DOCKER` in the config)
- The **Dfam TE Tools** image, pulled in advance: `docker pull dfam/tetools:latest`
  (it bundles RepeatModeler, RepeatMasker, RECON, RepeatScout, TRF and rmblast — one image
  serves both stages)
- A directory of **gzipped genome FASTAs** (`*.fna.gz` by default)
- Scratch and state directories on **local disk, not NFS** — the locking depends on it

Roughly `WORKERS × THREADS` cores are used. Scratch runs **20–80 GB per genome in flight**.

---

## Quickstart

```bash
# 1. pull the image once, before starting any workers
docker pull dfam/tetools:latest

# 2. write your config
cp rmodeler.conf.example rmodeler.conf
$EDITOR rmodeler.conf          # set IN_DIR, WORK_DIR, OUT_DIR, STATE_DIR, LOG_DIR

# 3. try one worker in the foreground first — you see errors immediately
./worker.sh

# 4. when that looks right, run the real thing
./rm-manager.sh start
./rm-manager.sh status
```

---

## Commands

| Command | What it does |
|---|---|
| `./worker.sh` | Runs **one** worker in the foreground |
| `./worker.sh --help` | Prints the usage block from the top of the script |
| `./rm-manager.sh start` | Launches `WORKERS` workers as background daemons |
| `./rm-manager.sh status` | Worker pids, queue counts, live containers, what's in progress |
| `./rm-manager.sh stop` | Stops every worker gracefully |
| `./rm-manager.sh` | Same as `status` — the safe default |

`start` is idempotent: slots already running are left alone, only dead ones are refilled.
Raising `WORKERS` and running `start` again simply adds workers.

### Stopping

```bash
./rm-manager.sh stop     # SIGTERM — the right way
kill <pid>               # same thing, for a worker started by hand
```

**Never `kill -9` a worker.** A graceful stop stops the container, releases the genome
*without* marking it failed, and deletes its scratch — so it is simply picked up again next
time. A hard kill orphans claims and containers; they are recoverable on the next startup, but
`status` misleads you until then.

`stop` returns as soon as signals are sent. Containers take up to `STOP_GRACE` seconds to
disappear — watch `docker ps` if you need to know when the box is idle.

---

## Configuration

Everything lives in **`rmodeler.conf`**, next to the scripts. There are no command-line options
and no environment variables — `THREADS=2 ./worker.sh` does nothing, because inherited values
are discarded before the file is read. Several workers share `STATE_DIR`, `OUT_DIR` and
`WORK_DIR`, and they only behave if all of them agree; one mandatory file guarantees that.

Both scripts exit 2 if the file is missing, if a setting is missing, if a name is misspelled,
or if a value is nonsense.

| Setting | Meaning |
|---|---|
| `IN_DIR` | Where the genome `.fna.gz` files live; must exist |
| `WORK_DIR` | Per-genome scratch. Big, fast, **local** |
| `OUT_DIR` | Where results land |
| `STATE_DIR` | Progress tracking. Must be **local disk** |
| `LOG_DIR` | Logs |
| `RUN_DIR` | Worker pid files, written by `rm-manager.sh` |
| `RM_IMAGE` | Container image, e.g. `dfam/tetools:latest` |
| `DOCKER` | `docker`, `sudo docker`, or `podman` |
| `WORKERS` | How many workers `./rm-manager.sh start` launches |
| `THREADS` | Cores per genome; also the container `--cpus` cap |
| `MEM_LIMIT` | Per-container memory cap, e.g. `28g`. Empty = unlimited |
| `GLOB` | Which files in `IN_DIR` count as input |
| `LTRSTRUCT` | `1` adds `-LTRStruct`; roughly doubles wall time and disk |
| `RUN_MASKER` | `1` runs RepeatMasker after RepeatModeler |
| `KEEP_MASKED_FASTA` | `1` also copies the soft-masked genome to `OUT_DIR` (genome-sized) |
| `KEEP_WORK` | `1` keeps the scratch directories on success |
| `RETRY_FAILED` | `1` re-attempts genomes marked failed |
| `STOP_GRACE` | Seconds Docker waits before SIGKILLing a container on shutdown |

On a 24-core / 124 GB box, `WORKERS=4` with `THREADS=6` is a sane starting point.

---

## What you get

**Stage one (model)**

| Path | What it is |
|---|---|
| `$OUT_DIR/<sample>-families.fa` (and `.stk`) | The repeat library |
| `$STATE_DIR/done/<sample>` | Marker: RepeatModeler finished |
| `$LOG_DIR/<sample>.log` | Full BuildDatabase/RepeatModeler output |

**Stage two (mask), when `RUN_MASKER=1`**

| Path | What it is |
|---|---|
| `$OUT_DIR/<sample>.rm.out` | **The TE annotation table — the file downstream analysis wants** |
| `$OUT_DIR/<sample>.rm.tbl` | RepeatMasker's summary |
| `$OUT_DIR/<sample>.rm.masked.fa` | Soft-masked genome, only if `KEEP_MASKED_FASTA=1` |
| `$STATE_DIR/masked/<sample>` | Marker: RepeatMasker finished |
| `$LOG_DIR/<sample>.masker.log` | Full RepeatMasker output |

**Shared**

| Path | What it is |
|---|---|
| `$STATE_DIR/failed/<sample>` | A stage failed; scratch and logs kept for inspection |
| `$STATE_DIR/claimed/<sample>/` | Currently being worked on |
| `$WORK_DIR/<sample>/` | Scratch; deleted on success unless `KEEP_WORK=1`, kept on failure |

The mask stage runs `RepeatMasker -lib <sample>-families.fa -pa $THREADS -xsmall <sample>.fa`:
`-lib` makes it a **custom library** run against the repeats found in that genome;
`-xsmall` soft-masks, so the masked FASTA stays usable as sequence.

---

## Restarting

All progress is recorded as **empty files named after genomes**, so you manage it with `ls` and
`rm`:

```bash
ls $STATE_DIR/done    | wc -l     # genomes modelled
ls $STATE_DIR/masked  | wc -l     # genomes masked
ls $STATE_DIR/failed              # what went wrong
ls -l $STATE_DIR/claimed          # what is running, and since when

rm $STATE_DIR/masked/<sample>     # redo only the RepeatMasker run (keeps the library)
rm $STATE_DIR/done/<sample> $STATE_DIR/masked/<sample>    # redo from scratch
rm $STATE_DIR/failed/*            # retry everything that failed, next pass
```

Because the stages have separate markers:

- **Turning masking on later is cheap.** Set `RUN_MASKER=1` and restart; every genome with a
  `done/` marker becomes available for the mask stage alone. Nothing is re-modelled — the
  library is fetched back from `OUT_DIR`.
- **A failed mask does not cost you the model.** The retry is one RepeatMasker run, not another
  8–26 hours.
- **A clean stop mid-mask is an abort, not a failure.** No marker is written; the stage looks
  untouched next pass.

> **Do not delete anything from `claimed/` while workers are running.** That makes a live genome
> look available and a second worker will start a duplicate run in a directory already in use.
> Stop the workers first.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Exit 2 at startup | `rmodeler.conf` missing, a setting missing, a name misspelled, or a bad value — the message says which |
| Exit 127 | `docker` not on `PATH`, or `RM_IMAGE` not pulled locally. Workers refuse to pull rather than have N of them download at once |
| A genome fails suspiciously fast | If `MEM_LIMIT` is set, a cgroup OOM kill looks like an ordinary failure. **Check `dmesg`** before believing the log |
| Two workers on the same genome | `STATE_DIR` is on NFS. The locking uses atomic `mkdir`, which NFS does not guarantee |
| `status` shows a claim with no container | The worker is decompressing — or the claim is stale (a killed worker). Stale claims are reaped at the next worker startup |
| Masking fails with "no library" | The `done/` marker exists but `<sample>-families.fa` is gone from `OUT_DIR`. Clear `done/<sample>` to rebuild |

Logs: `$LOG_DIR/<sample>.log` for modelling, `$LOG_DIR/<sample>.masker.log` for masking,
`$LOG_DIR/worker-N.out` per worker when launched via the manager.

---

## Documentation

- **[docs/SOURCE.md](docs/SOURCE.md)** — the source code in detail: every function, the
  concurrency model, signal handling, container flags, and the known rough edges.
