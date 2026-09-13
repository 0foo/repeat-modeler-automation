# repeat-modeler-automation

Runs RepeatModeler (via the Dfam TE Tools Docker image) over a directory of gzipped genome FASTAs, spread across parallel workers.

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
| `KEEP_WORK` | `1` keeps the `RM_*` rounds dirs on success |
| `RETRY_FAILED` | `1` re-attempts samples marked failed |
| `STOP_GRACE` | Seconds Docker waits before SIGKILLing a container on shutdown |

Total cores used is roughly `WORKERS * THREADS`. On a 24-core / 124 GB box, `WORKERS=4` with `THREADS=6` is a sane starting point.

## Artifacts generated

- `$OUT_DIR/<sample>-families.fa` (and `.stk` if produced) -- the RepeatModeler result, one per genome
- `$STATE_DIR/done/<sample>` -- marker: genome finished successfully
- `$STATE_DIR/failed/<sample>` -- marker: genome failed (scratch dir + log kept for inspection)
- `$STATE_DIR/claimed/<sample>/` -- marker: genome currently being worked on
- `$LOG_DIR/<sample>.log` -- full BuildDatabase/RepeatModeler output for that genome
- `$LOG_DIR/worker-N.out` -- one per worker, only when launched via `rm-manager.sh`
- `$RUN_DIR/worker-N.pid` -- one per worker slot, written by `rm-manager.sh`
- `$WORK_DIR/<sample>/` -- scratch working directory; deleted automatically on success (unless `KEEP_WORK=1`), kept on failure for debugging

For everything else (concurrency model, crash recovery, operating it by hand), see the comments at the top of `worker.sh` and `rm-manager.sh`.
