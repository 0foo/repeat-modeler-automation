#!/usr/bin/env bash
#==============================================================================
# rm-manager.sh
#
# Supervisor for worker.sh. Starts the configured number of workers as
# detached daemons, stops them cleanly, and reports progress.
#
# This script holds no state of its own beyond pid files. The workers
# coordinate with each other through $STATE_DIR (see the header of
# worker.sh); this is only a convenience wrapper for launching them.
#
#------------------------------------------------------------------------------
# USAGE
#
#   ./rm-manager.sh start        launch WORKERS workers
#   ./rm-manager.sh stop         SIGTERM all of them, gracefully
#   ./rm-manager.sh status       pid check + queue counts (the default)
#
# Those three words are the entire interface. There are no options, no
# arguments, and no environment variables: everything, including how many
# workers to run, comes from rmodeler.conf next to this script, and that file
# is required. See "CONFIGURATION" in worker.sh for the reasoning.
#
#------------------------------------------------------------------------------
# HOW MANY WORKERS
#
# Set WORKERS in rmodeler.conf. Total cores used is roughly WORKERS * THREADS,
# capped per container by --cpus. On a 24-core / 124 GB box, WORKERS=4 with
# THREADS=6 is the sane default.
#
# Raising WORKERS later is safe -- edit the config file and run `start` again.
# Slots already running are left alone and only the new ones are launched; a
# new worker just joins in and starts claiming unclaimed genomes. There is no
# need to stop the others first.
#
# Lowering WORKERS does not stop anything by itself. `stop` signals every
# worker it has a pid file for, whatever WORKERS currently says.
#
#------------------------------------------------------------------------------
# STOPPING
#
# `stop` sends SIGTERM, which each worker traps: it stops its running
# container, releases its claim WITHOUT writing a state marker, deletes that
# genome's scratch directory, and exits. Interrupted genomes are simply picked
# up again next time you start.
#
# Never use kill -9 here. A hard kill leaves claims and containers orphaned.
# They are recoverable -- the next worker startup reaps them -- but you lose
# the graceful container shutdown and it makes `status` misleading until then.
#
# `stop` returns as soon as the signals are sent. Containers take up to
# STOP_GRACE seconds to actually go away; watch `docker ps` if you need to
# know when the box is idle.
#
#==============================================================================

set -uo pipefail

# Resolve the worker next to this script, so it works from any cwd.
WORKER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/worker.sh"

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
# read, so `THREADS=2 ./rm-manager.sh start` has no effect whatsoever.
#
# The reader is duplicated from worker.sh on purpose: these are two
# standalone scripts with no shared library. Every setting it loads is
# exported, because the workers launched below inherit their configuration
# only through the environment -- but each worker then re-reads the same file
# itself, so a worker started by hand and one started here are configured
# identically.
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

# Pid files live under $RUN_DIR, one per worker slot.
mkdir -p "$RUN_DIR" "$LOG_DIR" || exit 1

#======================================================================= start
# Launch workers 1..WORKERS, skipping any slot whose worker is already alive.
# That makes `start` idempotent: run it again after one worker dies and only
# the dead slot is refilled.
start() {
    local i

    echo "config: $CONFIG_FILE"

    # Pull once, here, rather than letting the workers each start the same
    # download. The workers themselves refuse to run if the image is missing.
    if ! $DOCKER image inspect "$RM_IMAGE" >/dev/null 2>&1; then
        echo "pulling $RM_IMAGE ..."
        $DOCKER pull "$RM_IMAGE" || exit 1
    fi

    for (( i=1; i<=WORKERS; i++ )); do
        local pidf="$RUN_DIR/worker-$i.pid" pid=""

        # kill -0 sends no signal; it just asks whether that pid exists.
        [[ -f $pidf ]] && pid=$(cat "$pidf")
        if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
            echo "worker $i already running (pid $pid)"; continue
        fi

        # setsid    : new session, detached from this terminal
        # nohup     : ignore SIGHUP if the terminal goes away anyway
        # </dev/null: never block waiting on stdin
        # >>...out  : capture the worker's own log lines (stderr) per slot;
        #             per-genome container output goes to $LOG_DIR/<sample>.log
        setsid nohup "$WORKER" \
            >>"$LOG_DIR/worker-$i.out" 2>&1 < /dev/null &
        echo $! > "$pidf"

        # The pid is how you tie a slot back to the log lines: the worker tags
        # every line with <host>-<pid>, and records the same pid in the owner
        # file of each claim it takes.
        echo "started worker $i (pid $!)"

        # Stagger: without it the workers all decompress a genome at the same
        # instant and thrash the disk before any of them reaches RepeatModeler.
        sleep 2
    done
}

#======================================================================== stop
# SIGTERM each live worker. The worker's own trap does the real work -- stop
# the container, release the claim, exit -- so there is nothing to clean up
# here beyond the pid files.
#
# This walks the pid files rather than 1..WORKERS, so lowering WORKERS in the
# config file can never strand a running worker with nothing to stop it.
stop() {
    local pidf pid
    for pidf in "$RUN_DIR"/worker-*.pid; do
        [[ -f $pidf ]] || continue       # no matches: glob stays literal
        pid=$(cat "$pidf")
        if kill -0 "$pid" 2>/dev/null; then
            echo "stopping $(basename "$pidf" .pid) (pid $pid)"
            kill -TERM "$pid"
            # Don't remove the pid file until the worker has actually exited.
            # Containers take up to STOP_GRACE seconds to stop, and `stop`
            # itself is meant to return immediately -- if the pid file
            # disappeared right away, a `start` run in that window would see
            # a "free" slot and launch a second worker while the first is
            # still shutting down. Poll for exit in the background instead,
            # so `stop` still returns without waiting.
            ( while kill -0 "$pid" 2>/dev/null; do sleep 1; done; rm -f "$pidf" ) &
            disown
        else
            rm -f "$pidf"
        fi
    done
}

#====================================================================== status
# Two independent views, because they can legitimately disagree.
#
# The pid section says which worker PROCESSES are alive. The counts below say
# what the QUEUE looks like, read straight from the state directories -- the
# same source of truth the workers use, so it is accurate even for workers
# started by hand rather than through this script.
#
# A "dead (stale pidfile)" line means that worker exited without going through
# `stop`. If it was killed hard, its claim is still sitting in claimed/ and
# will be reaped the next time any worker starts.
status() {
    local pidf pid
    for pidf in "$RUN_DIR"/worker-*.pid; do
        [[ -f $pidf ]] || continue
        pid=$(cat "$pidf")
        if kill -0 "$pid" 2>/dev/null; then
            echo "$(basename "$pidf" .pid): running (pid $pid)"
        else
            echo "$(basename "$pidf" .pid): dead (stale pidfile)"
        fi
    done
    echo

    # queued is the TOTAL input count, not the remaining count. Remaining is
    # queued - done - failed - running. Uses $GLOB, same as worker.sh, so this
    # count matches what workers actually process even if GLOB is customized.
    echo "queued : $(find "$IN_DIR" -maxdepth 1 -name "$GLOB" | wc -l)"
    echo "running: $(find "$STATE_DIR/claimed" -maxdepth 1 -mindepth 1 -type d | wc -l)"
    echo "done   : $(find "$STATE_DIR/done"    -maxdepth 1 -type f | wc -l)"
    echo "failed : $(find "$STATE_DIR/failed"  -maxdepth 1 -type f | wc -l)"
    echo

    # Live containers, matched by the label worker.sh stamps on them so
    # nothing else running on this box gets listed.
    $DOCKER ps --filter label=rmworker.sample \
        --format '  container: {{.Names}}  {{.Status}}  {{.RunningFor}}' 2>/dev/null

    # Claimed genomes. A name here with no matching container usually means
    # the worker is decompressing, or the claim is stale.
    find "$STATE_DIR/claimed" -maxdepth 1 -mindepth 1 -type d -printf '  in progress: %f\n' 2>/dev/null
}

#=================================================================== dispatch
# Defaults to status, so a bare `./rm-manager.sh` is always safe to run. Extra
# arguments are rejected rather than ignored: `start 4` used to mean "four
# workers" and must not now be silently read as `start`.
(( $# > 1 )) && { echo "usage: $0 {start|stop|status}   (worker count is WORKERS in $CONFIG_FILE)" >&2; exit 2; }
case "${1:-status}" in
    start)  start ;;
    stop)   stop ;;
    status) status ;;
    *) echo "usage: $0 {start|stop|status}" >&2; exit 2 ;;
esac
