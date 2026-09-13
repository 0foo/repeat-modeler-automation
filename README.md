# repeat-modeler-automation

Runs RepeatModeler and then RepeatMasker (via the Dfam TE Tools Docker image) over a directory of gzipped genome FASTAs, spread across parallel workers.

Each genome goes through two stages:

| Stage | Runs | Produces |
|---|---|---|
| **model** | `BuildDatabase` + `RepeatModeler` | `<sample>-families.fa` — the repeat library for that species |
| **mask** | `RepeatMasker -lib <families>` | `<sample>.rm.out` — where every copy of those repeats sits |

The mask stage only runs when `RUN_MASKER=1`. Each stage records its own state marker as soon
as it succeeds, so the two are independently restartable — see **Stages and restarting** below.

## Configuration

Everything is configured in **`rmodeler.conf`**, next to the scripts. It is the only way to configure them: there are no command-line options and no environment variables. Both scripts refuse to start (exit 2) if the file is missing, if any setting is missing from it, if a setting name is misspelled, or if a value is nonsense.

```bash
cp rmodeler.conf.example rmodeler.conf
$EDITOR rmodeler.conf
```

Values inherited from the environment are discarded before the file is read, so `THREADS=2 ./worker.sh` has no effect. This is deliberate: workers share `STATE_DIR`, `OUT_DIR` and `WORK_DIR`, and they only behave if every one of them was configured identically.

## Commands

```bash
# one-time: pull the image
docker pull dfam/tetools:latest

# single worker, foreground -- good for a first test run
./worker.sh

# multiple workers via the supervisor
./rm-manager.sh start        # launch WORKERS workers
./rm-manager.sh status       # check progress (also runs if you pass nothing)
./rm-manager.sh stop         # stop all workers gracefully
```

## Inputs needed

- Docker installed (or `podman` / `sudo docker` -- set `DOCKER`), with `dfam/tetools:latest` already pulled
- `IN_DIR`: a directory of gzipped genome FASTAs (`*.fna.gz` by default, change with `GLOB`)
- `STATE_DIR` and `WORK_DIR` on a local filesystem, not NFS

Every setting in `rmodeler.conf` is required. `rmodeler.conf.example` is a complete, working file with all of them:

| Setting | Meaning |
|---|---|
| `IN_DIR` | Where the genome `.fna.gz` files live; must exist |
| `WORK_DIR` | Per-genome scratch space; needs to be big, fast, and local |
| `OUT_DIR` | Where the final output lands |
| `STATE_DIR` | Progress tracking; must be local disk |
| `LOG_DIR` | Logs |
| `RUN_DIR` | Worker pid files, written by `rm-manager.sh` |
| `RM_IMAGE` | Container image holding RepeatModeler |
| `DOCKER` | `docker`, `sudo docker`, or `podman` |
| `WORKERS` | How many workers `./rm-manager.sh start` launches |
| `THREADS` | Cores per genome; also the container `--cpus` cap |
| `MEM_LIMIT` | Per-container memory cap, e.g. `28g`. Empty = unlimited |
| `GLOB` | Which files in `IN_DIR` count as input |
| `LTRSTRUCT` | `1` adds `-LTRStruct`; roughly doubles wall time and disk |
| `RUN_MASKER` | `1` runs RepeatMasker after RepeatModeler, using the library it just built |
| `KEEP_MASKED_FASTA` | `1` also copies the soft-masked genome to `OUT_DIR`; it is genome-sized, so off by default |
| `KEEP_WORK` | `1` keeps the `RM_*` rounds dirs on success |
| `RETRY_FAILED` | `1` re-attempts samples marked failed |
| `STOP_GRACE` | Seconds Docker waits before SIGKILLing a container on shutdown |

Total cores used is roughly `WORKERS * THREADS`. On a 24-core / 124 GB box, `WORKERS=4` with `THREADS=6` is a sane starting point.

## Stages and restarting

The two stages have separate markers -- `done/<sample>` for modelling, `masked/<sample>` for
masking -- and that is what makes the pair restartable:

- **Turning masking on later is cheap.** Set `RUN_MASKER=1` and start the workers again: every
  genome that already has a `done/` marker becomes available for the mask stage alone. Nothing
  is re-modelled. The library is copied back out of `$OUT_DIR`, which is where it survives.
- **A failed mask does not cost you the model.** A genome that models in 20 hours and then
  fails during RepeatMasker keeps its `done/` marker and its library, so the retry is one
  RepeatMasker run, not another 20 hours.
- **A clean stop mid-mask is an abort, not a failure.** SIGTERM during RepeatMasker writes no
  marker at all; the mask stage simply looks untouched on the next pass.
- **The two stages log separately** (`<sample>.log` and `<sample>.masker.log`) so a mask-only
  retry cannot truncate the RepeatModeler log belonging to the library it is using.

To redo just the masking for one genome: `rm $STATE_DIR/masked/<sample>`.
To redo a genome from scratch: `rm $STATE_DIR/done/<sample> $STATE_DIR/masked/<sample>`.

## Artifacts generated

**Stage one (model)**

- `$OUT_DIR/<sample>-families.fa` (and `.stk` if produced) -- the RepeatModeler result, one per genome
- `$STATE_DIR/done/<sample>` -- marker: RepeatModeler finished successfully
- `$LOG_DIR/<sample>.log` -- full BuildDatabase/RepeatModeler output for that genome

**Stage two (mask), when `RUN_MASKER=1`**

- `$OUT_DIR/<sample>.rm.out` -- the RepeatMasker annotation table. **This is the file the rest
  of the project consumes**; it is RepeatMasker's own `<sample>.fa.out`, renamed on the way out
- `$OUT_DIR/<sample>.rm.tbl` -- RepeatMasker's summary table
- `$OUT_DIR/<sample>.rm.masked.fa` -- the soft-masked genome, only if `KEEP_MASKED_FASTA=1`
- `$STATE_DIR/masked/<sample>` -- marker: RepeatMasker finished successfully
- `$LOG_DIR/<sample>.masker.log` -- full RepeatMasker output for that genome

**Shared**

- `$STATE_DIR/failed/<sample>` -- marker: a stage failed (scratch dir + logs kept for inspection)
- `$STATE_DIR/claimed/<sample>/` -- marker: genome currently being worked on
- `$LOG_DIR/worker-N.out` -- one per worker, only when launched via `rm-manager.sh`
- `$RUN_DIR/worker-N.pid` -- one per worker slot, written by `rm-manager.sh`
- `$WORK_DIR/<sample>/` -- scratch working directory; deleted automatically on success (unless `KEEP_WORK=1`), kept on failure

### RepeatMasker flags

The mask stage runs `RepeatMasker -lib <sample>-families.fa -pa $THREADS -xsmall <sample>.fa`.

- `-lib` makes it a **custom library** run: the repeats annotated are the ones RepeatModeler
  found in this genome, not Dfam's stock set for the clade.
- `-pa` is RepeatMasker's own parallelism. Unlike RepeatModeler there is no `-threads`
  spelling to detect, and the container's `--cpus` ceiling still applies on top of it.
- `-xsmall` soft-masks: repeats come back lowercased instead of replaced with `N`, so the
  masked FASTA stays usable as sequence downstream. It has no effect on the `.out` table. for debugging

For everything else (concurrency model, crash recovery, operating it by hand), see the comments at the top of `worker.sh` and `rm-manager.sh`.
