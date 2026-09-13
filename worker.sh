#!/usr/bin/env bash
#==============================================================================
# worker.sh
#
# One RepeatModeler worker. It walks a directory of gzipped genome FASTAs,
# claims one genome at a time, and runs BuildDatabase + RepeatModeler on it
# inside the Dfam TE Tools container.
#
# Run as many copies as you have cores for. There is no coordinator process,
# no queue server, and no shared state file -- see "CONCURRENCY" below.
#
#------------------------------------------------------------------------------
# USAGE
#
#   This script takes no arguments and reads no environment variables. All
#   configuration lives in rmodeler.conf, next to this script, and that file
#   is required -- see "CONFIGURATION" below.
#
#   Pull the image once, before starting any workers:
#       docker pull dfam/tetools:latest
#
#   Foreground (one worker, useful for a first test run):
#       ./worker.sh
#
#   Daemonized:
#       setsid nohup ./worker.sh >>/data/rmodeler/logs/w1.out 2>&1 </dev/null &
#
#   Several at once -- just launch it more than once, or use rm-manager.sh,
#   which handles pid files, staggering, and stop/status:
#       ./rm-manager.sh start
#
#   Stop a worker with SIGTERM (plain `kill`, no -9). It stops the running
#   container, leaves that genome unclaimed for a later retry, and exits.
#
#------------------------------------------------------------------------------
# CONFIGURATION
#
# Copy rmodeler.conf.example to rmodeler.conf and edit it. Every setting it
# lists must be present; the script exits 2 if the file is missing, if a
# setting is missing, if a name is misspelled, or if a value is nonsense.
#
# Nothing can be set any other way. `THREADS=2 ./worker.sh` does not work --
# inherited values are discarded before the file is read -- and there are no
# command-line flags. Workers sharing a $STATE_DIR must agree on where
# everything is, and one mandatory file is the only way to guarantee they do.
#
#------------------------------------------------------------------------------
# CONCURRENCY
#
# All run state lives in the *names of directories* under $STATE_DIR. Nothing
# is ever read to decide what to work on next, so there is no file for workers
# to disagree about and nothing to keep in sync:
#
#   claimed/<sample>/owner   in progress; owner file records host + pid
#   done/<sample>            finished OK, families files are in $OUT_DIR
#   failed/<sample>          failed; scratch dir and log kept for inspection
#
# A genome named in none of the three is available. That fourth state is not
# recorded anywhere -- it is the absence of the other three, recomputed from
# $IN_DIR on every pass.
#
# Mutual exclusion is a single mkdir. On a local filesystem mkdir is atomic:
# the kernel does the does-it-exist check and the create as one indivisible
# operation, so when N workers race for the same genome exactly one gets exit
# status 0 and the rest get EEXIST. There is deliberately no `if [ -d ... ]`
# test before it -- that would reintroduce the window this design exists to
# avoid. The workers try, and the return code decides.
#
# The done/ and failed/ checks in the main loop are only an optimization to
# skip pointless mkdir attempts. They are allowed to be stale. The mkdir is
# the only step whose answer is authoritative.
#
# CAUTION: $STATE_DIR must be on a local filesystem. mkdir atomicity is not
# dependable over NFS.
#
#------------------------------------------------------------------------------
# CRASH RECOVERY
#
# A clean stop (SIGTERM) releases the claim and writes no marker, so the
# genome simply looks untouched on the next pass.
#
# A `kill -9`, an OOM kill, or a reboot leaves the claim directory behind with
# no owner alive. reap_stale_claims() at startup finds those -- claims whose
# recorded host is this host and whose recorded pid no longer exists -- kills
# any container they orphaned, and releases them. The host check matters: pid
# 4823 here tells you nothing about pid 4823 on another machine.
#
#------------------------------------------------------------------------------
# OPERATING IT BY HAND
#
# State is just files, so use the tools you already have:
#
#   ls state/done | wc -l                 # progress
#   ls -l state/claimed/                  # what is running, and since when
#   ls state/failed                       # what blew up
#   rm state/done/GCA_002110              # redo one genome
#   rm state/failed/*                     # retry all failures on the next pass
#
# Do NOT delete anything from claimed/ while workers are running. That makes a
# live genome look available and a second worker will start a duplicate run in
# a job directory already in use. Stop the worker instead.
#
#------------------------------------------------------------------------------
# SIZING
#
# RepeatModeler spawns more threads than you ask it to, so THREADS is enforced
# with a --cpus ceiling on the container rather than trusted. On a 24-core /
# 124 GB box, 4 workers x THREADS=6 is the sane starting point.
#
# Disk is the real constraint, not RAM: a work directory with all RECON rounds
# retained runs 20-80 GB per genome. Keep KEEP_WORK=0 and put $WORK_DIR
# somewhere big and fast.
#
#------------------------------------------------------------------------------
# EXIT STATUS
#
#   0    queue exhausted, worker finished normally
#   2    configuration problem: no rmodeler.conf, or a bad/missing setting
#   127  docker missing, or the image is not present locally
#   143  stopped by SIGTERM (128 + 15)
#
#==============================================================================

# -u  : an unset variable is a fatal error rather than an empty string.
# -o pipefail : a pipeline fails if ANY stage failed, not just the last one.
# Deliberately no -e: one genome failing must not kill the worker.
set -uo pipefail

#======================================================================= usage
# This script takes no arguments, so any argument is a mistake -- and a silent
# one, because the mistaken command still starts a full worker: it claims a
# genome and launches containers when all you wanted was to read the help.
# `./worker.sh --help` did exactly that. Reject arguments before anything else
# happens, and answer the help flags people actually type.
usage() {
    sed -n '3,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    echo "Settings: $(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rmodeler.conf"
}
case "${1:-}" in
    "")        ;;                                  # the only correct invocation
    -h|--help) usage; exit 0 ;;
    *)         echo "worker.sh takes no arguments (got: $*)" >&2
               echo "It is configured only by rmodeler.conf. Try --help." >&2
               exit 2 ;;
esac

#=================================================================== config file
# There are no command-line options and no environment overrides. Every
# setting comes from rmodeler.conf, which sits next to this script and is
# mandatory: if it is missing, or if any setting is missing from it, the
# script refuses to start rather than quietly falling back to a default.
#
# Why it is this strict: several workers share $STATE_DIR, $OUT_DIR and
# $WORK_DIR, and they only behave if every one of them was configured
# identically. A per-invocation override is exactly how two workers end up
# disagreeing about where the queue lives. One file, one answer, for every
# worker on the box.
#
# Format is plain KEY=value lines -- '#' starts a comment, blank lines are
# ignored, values may be quoted. This is a small hand-rolled reader, not
# `source`: the file cannot execute shell commands, only set the names below.
#
# Values inherited from the environment are discarded before the file is
# read, so `THREADS=2 ./worker.sh` has no effect whatsoever -- it does not
# override the file, and it does not survive as a leftover either.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE="$HERE/rmodeler.conf"

# The complete set of recognised settings. Both scripts accept all of them --
# a few are only used by one of the two -- so a single config file serves
# both. Anything else in the file is a typo, and treated as one.
CONFIG_KEYS=(IN_DIR WORK_DIR OUT_DIR STATE_DIR LOG_DIR RUN_DIR
             RM_IMAGE DOCKER THREADS MEM_LIMIT GLOB
             LTRSTRUCT KEEP_WORK RETRY_FAILED STOP_GRACE WORKERS)

die() { printf 'config error: %s\n' "$*" >&2; exit 2; }

load_config() {
    [[ -f $CONFIG_FILE ]] || die "no config file at $CONFIG_FILE
  Copy rmodeler.conf.example to rmodeler.conf and edit it. The config file is
  the only way to configure these scripts; there are no options or env vars."

    # Drop anything inherited from the environment first, so the file is the
    # only thing that can set these names.
    local k
    for k in "${CONFIG_KEYS[@]}"; do unset "$k"; done

    local -A seen=()
    local lineno=0 line key value
    while IFS= read -r line || [[ -n $line ]]; do
        (( ++lineno ))
        line="${line%%#*}"                          # strip comment
        line="${line#"${line%%[![:space:]]*}"}"     # trim leading whitespace
        line="${line%"${line##*[![:space:]]}"}"     # trim trailing whitespace
        [[ -z $line ]] && continue

        [[ $line == *=* ]] || die "$CONFIG_FILE line $lineno: not a KEY=value line: $line"
        key="${line%%=*}"
        value="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"        # allow "KEY = value"
        value="${value#"${value%%[![:space:]]*}"}"

        # A bad key is a hard error, not a skipped line: a typo'd setting that
        # is silently ignored looks exactly like one that was applied.
        [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "$CONFIG_FILE line $lineno: bad setting name: $key"
        [[ " ${CONFIG_KEYS[*]} " == *" $key "* ]] || die "$CONFIG_FILE line $lineno: unknown setting: $key"
        [[ -z ${seen[$key]+x} ]] || die "$CONFIG_FILE line $lineno: $key set more than once"

        if [[ $value == \"*\" ]]; then value="${value#\"}"; value="${value%\"}"
        elif [[ $value == \'*\' ]]; then value="${value#\'}"; value="${value%\'}"
        fi

        printf -v "$key" '%s' "$value"
        export "$key"
        seen[$key]=1
    done < "$CONFIG_FILE"

    # Every setting must be present. No built-in defaults: a value you never
    # wrote down is a value you cannot check when a run goes wrong.
    local missing=()
    for k in "${CONFIG_KEYS[@]}"; do
        [[ -n ${seen[$k]+x} ]] || missing+=("$k")
    done
    (( ${#missing[@]} )) && die "$CONFIG_FILE is missing: ${missing[*]}"
}

# Catch the bad values here, once, rather than as a puzzling failure three
# hours into a run.
validate_config() {
    local k
    for k in IN_DIR WORK_DIR OUT_DIR STATE_DIR LOG_DIR RUN_DIR RM_IMAGE DOCKER GLOB; do
        [[ -n ${!k} ]] || die "$k must not be empty"
    done
    for k in THREADS WORKERS; do
        [[ ${!k} =~ ^[1-9][0-9]*$ ]] || die "$k must be a positive integer (got '${!k}')"
    done
    for k in LTRSTRUCT KEEP_WORK RETRY_FAILED; do
        [[ ${!k} == 0 || ${!k} == 1 ]] || die "$k must be 0 or 1 (got '${!k}')"
    done
    [[ $STOP_GRACE =~ ^[0-9]+$ ]] || die "STOP_GRACE must be a whole number of seconds (got '$STOP_GRACE')"
    [[ -d $IN_DIR ]] || die "IN_DIR does not exist: $IN_DIR"
}

load_config
validate_config

# Identifies this worker in its own log lines and in the owner file of every
# claim it takes. Derived, never configured: workers on one box must be
# distinguishable, and a pid is the one thing guaranteed to differ. Match a
# tag back to an rm-manager.sh slot through $RUN_DIR/worker-N.pid.
WORKER_ID="$(hostname -s)-$$"

# Brace expansion: the shell turns the second line into three separate
# arguments before mkdir ever runs. -p makes this idempotent, so every worker
# can do it at startup without caring who got there first.
mkdir -p "$WORK_DIR" "$OUT_DIR" "$LOG_DIR" \
         "$STATE_DIR"/{claimed,done,failed} || exit 1

#===================================================================== logging
# Worker chatter goes to stderr, timestamped and tagged with WORKER_ID, so
# several workers writing to one file stay readable. Container stdout/stderr
# is separate -- that goes to $LOG_DIR/<sample>.log, see docker_run().
log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$WORKER_ID" "$*" >&2; }

#============================================================ signal handling
# Three globals track what is in flight so the trap knows what to clean up.
SHUTDOWN=0             # set to 1 once a stop has been requested
CHILD_PID=""           # pid of the backgrounded `docker run` client
CURRENT_CONTAINER=""   # name of the container currently running, if any

# Runs on SIGTERM (plain `kill`, and what rm-manager.sh stop sends) or SIGINT
# (Ctrl-C). Two jobs: flag the shutdown so the main loop stops taking new work,
# and stop the running container.
#
# The container must be stopped BY NAME. It is a child of the Docker daemon,
# not of this script, so killing the `docker run` client here would leave
# RepeatModeler running and chewing cores with nothing watching it.
on_term() {
    SHUTDOWN=1
    log "shutdown signal received"
    if [[ -n $CURRENT_CONTAINER ]]; then
        log "stopping container $CURRENT_CONTAINER"
        # CURRENT_CONTAINER is set just before `docker run` is launched (see
        # docker_run), but the container may not exist in the daemon yet if
        # the signal lands in that brief window. Retry briefly instead of
        # giving up on the first failed `stop` -- otherwise the container
        # would run unmanaged to completion despite the shutdown request.
        local tries=0
        until $DOCKER stop -t "$STOP_GRACE" "$CURRENT_CONTAINER" >/dev/null 2>&1; do
            (( ++tries >= 20 )) && { log "gave up waiting for $CURRENT_CONTAINER to appear"; break; }
            [[ -n $CHILD_PID ]] && ! kill -0 "$CHILD_PID" 2>/dev/null && break
            sleep 0.25
        done
    fi
}
trap on_term TERM INT

# HUP is swallowed so closing the terminal you launched from does not kill a
# worker that was started without nohup.
trap 'log "HUP ignored"' HUP

#============================================================= docker plumbing
# Run one tool from the container and block until it finishes.
#
#   docker_run <container-name> <logfile> <jobdir> <cmd> [args...]
#
# Returns the container's exit status.
#
# Flags, and why each one is here:
#   --rm        delete the container on exit; 300 genomes x 2 stages would
#               otherwise leave 600 dead containers behind
#   --init      a real pid 1 inside to reap zombies. RepeatModeler forks a lot
#   --name      needed so on_term can stop it, and so a stale claim's orphan
#               can be found and removed at startup
#   --label     lets `docker ps --filter label=rmworker.sample` list our
#               containers without matching anything else on the box
#   --user      without this every output file is owned by root, which makes
#               cleanup across 300 genomes miserable. It also means the
#               container has no valid home directory, hence -e HOME below
#   --cpus      a hard ceiling. RepeatModeler ignores thread counts in places,
#               so this is what actually stops N workers oversubscribing
#   -v same:same  the job directory is mounted at the identical path it has on
#               the host, the way dfam-tetools.sh does it. RepeatModeler writes
#               absolute paths into its round logs and errors; matching paths
#               means a trace you can follow on the host without translating
#   -e HOME     points home at the job directory, which is writable
#
# NOTE on MEM_LIMIT: a cgroup OOM kill surfaces as a plain non-zero exit, so a
# genome killed that way lands in failed/ with a truncated log and no obvious
# cause. If one fails suspiciously fast, check `dmesg` before believing the log.
docker_run() {
    local cname=$1 logf=$2 jobdir=$3; shift 3
    local mem=()
    [[ -n $MEM_LIMIT ]] && mem=(--memory "$MEM_LIMIT" --memory-swap "$MEM_LIMIT")

    printf '\n=== %s : %s ===\n' "$(date '+%F %T')" "$*" >>"$logf"

    # Set before launching: if the signal lands between here and the run
    # starting, on_term still knows which container name to stop.
    CURRENT_CONTAINER=$cname

    $DOCKER run --rm --init \
        --name "$cname" \
        --label rmworker.sample="$cname" \
        --user "$(id -u):$(id -g)" \
        --cpus "$THREADS" "${mem[@]}" \
        -v "$jobdir:$jobdir" \
        -w "$jobdir" \
        -e HOME="$jobdir" \
        "$RM_IMAGE" "$@" >>"$logf" 2>&1 &
    CHILD_PID=$!

    # Why this is a loop and not a bare `wait`:
    #
    # When a trapped signal arrives while bash is blocked in wait, bash
    # abandons the wait, runs the trap, and has wait return 128 + signum. But
    # the child is often still alive -- docker stop takes up to STOP_GRACE
    # seconds. Returning here while the container still runs would let the
    # caller move on and start a second container in the same job directory.
    #
    # So: if the status is above 128 AND the process still exists, wait again.
    # kill -0 sends no signal, it only tests whether the pid is there.
    local rc
    while :; do
        wait "$CHILD_PID"; rc=$?
        if (( rc > 128 )) && kill -0 "$CHILD_PID" 2>/dev/null; then continue; fi
        break
    done

    CHILD_PID=""
    CURRENT_CONTAINER=""
    return "$rc"
}

# Reduce a sample name to characters Docker accepts in --name, capped at a
# length that leaves room for the "-db" / "-rm" suffixes.
#
# printf, not a <<< here-string: a here-string appends its own trailing
# newline to the input, and `tr -c` would transliterate that newline too,
# leaving every generated name with a spurious trailing "_".
safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_' | cut -c1-100; }

#======================================================= RepeatModeler flavour
# -pa was deprecated in RepeatModeler 2.0.4 in favour of -threads. Rather than
# assume which one the image has, ask it once at startup and cache the answer
# in an array (an array so it expands to two separate arguments later, not one
# string with a space in it).
#
# On an old build, -pa counted 4-core BLAST jobs rather than cores, so the
# requested thread count is divided by four to get the equivalent.
#
# Which flag the image supports is a property of $RM_IMAGE, not of this
# worker, so the answer is cached under $STATE_DIR: with N workers sharing
# one image, only the first to ask has to actually launch a probe container.
# A lost race just means two workers happen to probe instead of one -- still
# cheaper than every worker probing, and harmless either way.
RM_THREAD_ARGS=()
detect_thread_flag() {
    local cache="$STATE_DIR/.thread_flag_mode" mode=""
    [[ -s $cache ]] && mode=$(<"$cache")

    if [[ $mode != threads && $mode != pa ]]; then
        local help
        help=$($DOCKER run --rm "$RM_IMAGE" RepeatModeler -help 2>&1 | head -200)
        if grep -q -- '-threads' <<<"$help"; then
            mode="threads"
        else
            mode="pa"
        fi
        printf '%s\n' "$mode" > "$cache.$$" 2>/dev/null && mv -f "$cache.$$" "$cache" 2>/dev/null
    fi

    if [[ $mode == threads ]]; then
        RM_THREAD_ARGS=(-threads "$THREADS")
    else
        local pa=$(( THREADS / 4 )); (( pa < 1 )) && pa=1
        RM_THREAD_ARGS=(-pa "$pa")
        log "older RepeatModeler in image: using -pa $pa (~$((pa*4)) cores)"
    fi
}

#========================================================== claim management
# Try to take ownership of a sample. Returns 0 if we got it, 1 if someone else
# already has it.
#
# The mkdir IS the lock -- see CONCURRENCY in the header. It is atomic, so the
# race resolves in the kernel with exactly one winner. Note there is no
# existence test before it; adding one would break the whole scheme.
#
# The owner file is written after winning, and exists only so a later worker
# can tell a live claim from one abandoned by a killed process.
#
# "container=" records the BASE name (safe_name(sample)) -- run_pipeline
# always launches containers as "<base>-db" / "<base>-rm", never the bare
# base name itself. reap_stale_claims() below must add those same suffixes
# when it goes looking for an orphan to remove.
claim() {           # $1 = sample -> 0 if we got it
    mkdir "$STATE_DIR/claimed/$1" 2>/dev/null || return 1
    printf 'host=%s\npid=%s\nworker=%s\ncontainer=%s\nstart=%s\n' \
        "$(hostname -s)" "$$" "$WORKER_ID" "$(safe_name "$1")" "$(date '+%F %T')" \
        > "$STATE_DIR/claimed/$1/owner"
}

# Release a claim. Called for every outcome -- success, failure, and abort --
# because it is the done/ or failed/ marker, not the claim, that keeps a
# genome from being picked up again.
#
# ${VAR:?} makes the expansion fail loudly rather than expand to nothing, so a
# bug can never turn this into `rm -rf /claimed/`.
unclaim() { rm -rf "${STATE_DIR:?}/claimed/${1:?}"; }

# Release claims abandoned by workers that no longer exist: SIGKILL, OOM kill,
# reboot. Without this a genome caught by one of those stays claimed forever,
# invisible to every worker.
#
# Only claims recorded against THIS host are considered. A pid from another
# machine means nothing here, and releasing it would put a genome another box
# is actively working back into the pool.
#
# Runs once at startup, before the main loop.
reap_stale_claims() {
    local d sample host pid cname
    for d in "$STATE_DIR"/claimed/*/; do
        [[ -d $d ]] || continue          # no matches: the glob stays literal
        sample=$(basename "$d")

        # No owner file means a worker died in the split second between the
        # mkdir and the write. Leave it alone rather than guess -- clear it by
        # hand once you are sure nothing is running.
        [[ -f $d/owner ]] || { log "claim $sample has no owner file, skipping"; continue; }

        host=$(awk -F= '/^host=/{print $2}'      "$d/owner")
        pid=$(awk  -F= '/^pid=/{print $2}'       "$d/owner")
        cname=$(awk -F= '/^container=/{print $2}' "$d/owner")

        [[ $host == "$(hostname -s)" ]] || continue
        if ! kill -0 "$pid" 2>/dev/null; then
            log "reaping stale claim: $sample (dead pid $pid)"
            # The live container is named "<cname>-db" or "<cname>-rm", never
            # bare $cname -- try both suffixes; whichever doesn't exist just
            # errors harmlessly under the redirect.
            [[ -n $cname ]] && $DOCKER rm -f "${cname}-db" "${cname}-rm" >/dev/null 2>&1
            unclaim "$sample"
        fi
    done
}

#================================================================== processing
# The actual work for one genome: decompress, BuildDatabase, RepeatModeler,
# collect output.
#
#   $1 = sample name   $2 = path to the .fna.gz   $3 = log file   $4 = job dir
#
# Returns 0 on success, 130 if a shutdown interrupted it, 1 on any real error.
# 130 is this script's private "aborted, not failed" code -- process_one()
# treats it completely differently from a failure.
run_pipeline() {
    local sample=$1 gz=$2 logf=$3 jobdir=$4
    local cname; cname=$(safe_name "$sample")
    local ltr=() rc=0
    (( LTRSTRUCT )) && ltr=(-LTRStruct)

    # Decompression happens on the host, which means $IN_DIR never has to be
    # mounted into the container. The container only ever sees one genome's
    # scratch directory.
    log "[$sample] decompressing"
    if ! zcat "$gz" > "$jobdir/$sample.fa"; then
        log "[$sample] decompression failed"; return 1
    fi
    if [[ ! -s $jobdir/$sample.fa ]]; then
        log "[$sample] empty FASTA after decompression"; return 1
    fi

    # Decompression of a large genome is not instant either, so a stop
    # request can already be pending by the time it finishes. Check before
    # committing to BuildDatabase rather than only between the two stages
    # below.
    (( SHUTDOWN )) && return 130

    # No -engine: current RepeatModeler (checked against 2.0.9) dropped
    # AB-Blast support and removed the option from BuildDatabase's argument
    # list, so passing it is a hard "Unknown option: engine" failure. The
    # database is always built with makeblastdb now. RepeatModeler itself
    # still parses -engine but hardcodes rmblast and ignores the value, so
    # the flag is gone from both calls rather than only from this one.
    log "[$sample] BuildDatabase"
    docker_run "${cname}-db" "$logf" "$jobdir" \
        BuildDatabase -name "$sample" "$sample.fa" \
        || { rc=$?
             # A non-zero exit caused by US stopping the container (SIGTERM
             # landed while BuildDatabase was running) is an abort, not a
             # failure -- same reasoning as the RepeatModeler check below.
             # Without this, every shutdown that lands mid-BuildDatabase
             # would wrongly mark its in-flight genome failed.
             (( SHUTDOWN )) && return 130
             log "[$sample] BuildDatabase failed (rc $rc)"; return 1; }

    # A stop request lands here, between the two long stages, rather than
    # partway through a multi-hour RepeatModeler run.
    (( SHUTDOWN )) && return 130

    log "[$sample] RepeatModeler (${RM_THREAD_ARGS[*]})"
    docker_run "${cname}-rm" "$logf" "$jobdir" \
        RepeatModeler -database "$sample" \
        "${RM_THREAD_ARGS[@]}" "${ltr[@]}" \
        || { rc=$?
             # A non-zero exit caused by US stopping the container is an abort,
             # not a failure. Without this check every clean shutdown would
             # wrongly mark its in-flight genome failed.
             (( SHUTDOWN )) && return 130
             log "[$sample] RepeatModeler failed (rc $rc)"; return 1; }

    # RepeatModeler can exit 0 having produced nothing usable, so verify the
    # output exists before calling this a success.
    if [[ ! -s $jobdir/$sample-families.fa ]]; then
        log "[$sample] no families file produced"; return 1
    fi

    cp -f "$jobdir/$sample-families.fa" "$OUT_DIR/" || return 1
    [[ -s $jobdir/$sample-families.stk ]] && cp -f "$jobdir/$sample-families.stk" "$OUT_DIR/"
    return 0
}

# Bookkeeping around run_pipeline: fresh job directory, fresh log, then record
# the outcome as a state marker.
#
#   $1 = path to the .fna.gz   $2 = sample name
#
# The three outcomes are handled differently on purpose:
#
#   success  -> done/ marker written, scratch deleted (unless KEEP_WORK)
#   abort    -> NO marker written, scratch deleted. The genome looks untouched
#               and any future run picks it up
#   failure  -> failed/ marker written, scratch and log KEPT so you can see
#               what happened
process_one() {
    local gz=$1 sample=$2
    local jobdir="$WORK_DIR/$sample"
    local logf="$LOG_DIR/$sample.log"
    local rc=0 t0=$SECONDS

    # Wipe first: a retry must not inherit a half-finished RM_* directory from
    # a previous attempt, which RepeatModeler would trip over.
    rm -rf "$jobdir" && mkdir -p "$jobdir" || return 1
    : > "$logf"

    run_pipeline "$sample" "$gz" "$logf" "$jobdir"; rc=$?

    if (( rc == 0 )); then
        log "[$sample] done in $(( (SECONDS - t0) / 60 )) min"
        date '+%F %T' > "$STATE_DIR/done/$sample"
        (( KEEP_WORK )) || rm -rf "$jobdir"
    elif (( rc == 130 )); then
        log "[$sample] aborted by shutdown, leaving unclaimed for a retry"
        rm -rf "$jobdir"
    else
        log "[$sample] FAILED - work kept at $jobdir, log at $logf"
        date '+%F %T' > "$STATE_DIR/failed/$sample"
    fi
    return "$rc"
}

#======================================================================== main

# Startup checks. ${DOCKER%% *} strips any arguments, so "sudo docker" tests
# for "sudo".
command -v "${DOCKER%% *}" >/dev/null || { log "$DOCKER not on PATH"; exit 127; }

# Refuse rather than pull: four workers starting together would otherwise each
# kick off the same download.
if ! $DOCKER image inspect "$RM_IMAGE" >/dev/null 2>&1; then
    log "image $RM_IMAGE not present locally - run: $DOCKER pull $RM_IMAGE"
    exit 127
fi

detect_thread_flag
reap_stale_claims

log "starting: config=$CONFIG_FILE IN_DIR=$IN_DIR IMAGE=$RM_IMAGE THREADS=$THREADS LTRSTRUCT=$LTRSTRUCT"

processed=0

# The loop body reads work from the process substitution at the bottom. Read
# that line first: `< <(find ... | shuf)`.
#
# It is written as process substitution rather than `find | while read`
# because a pipeline runs the loop in a SUBSHELL, where `processed` would be
# discarded at the end and the traps would not behave.
#
# shuf matters more than it looks. Without it every worker walks the identical
# list in the identical order, so workers 2..N lose the race on genome 1, then
# on genome 2, then on genome 3 -- hundreds of wasted mkdir calls before they
# find open work. Shuffling scatters them so collisions are rare.
while IFS= read -r gz; do
    (( SHUTDOWN )) && break
    [[ -e $gz ]] || continue     # file vanished since find ran

    # Strip the extensions to get the sample name, tolerating .fna/.fa/.fasta
    # and a trailing .rm (e.g. some-genome.rm.fna.gz -> some-genome), so state
    # markers, logs, and output filenames don't carry it.
    sample=$(basename "$gz")
    sample=${sample%.gz}; sample=${sample%.fna}; sample=${sample%.fa}; sample=${sample%.fasta}
    sample=${sample%.rm}

    # Cheap skips. These are allowed to be stale -- the mkdir in claim() is
    # the authoritative step.
    [[ -e $STATE_DIR/done/$sample ]] && continue
    if [[ -e $STATE_DIR/failed/$sample ]]; then
        (( RETRY_FAILED )) || continue
        rm -f "$STATE_DIR/failed/$sample"
    fi

    # The one line that resolves the race. Lost it? Someone else owns this
    # genome; move on.
    claim "$sample" || continue

    process_one "$gz" "$sample"
    rc=$?
    unclaim "$sample"
    (( rc == 0 )) && (( processed++ ))
done < <(find "$IN_DIR" -maxdepth 1 -name "$GLOB" -type f | shuf)

log "exiting: $processed genome(s) completed this run"
(( SHUTDOWN )) && exit 143    # 128 + 15, the convention for "killed by SIGTERM"
exit 0