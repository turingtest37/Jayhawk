#! /bin/sh
#
# Ephemeral in-memory Apache Jena Fuseki for testing Jayhawk.
#
#   ./bin/fuseki-test.sh start|stop|status|load|reset|url
#
# Everything lives in memory and dies with the process: no TDB2 files, no state
# carried between runs, nothing to clean up.
#
# Why `java -cp ... FusekiMainCmd` instead of the shipped `fuseki-server` script:
# that script sets FUSEKI_BASE="${FUSEKI_BASE:-$PWD/run}", so it either scatters a
# `run/` directory into whatever the working directory happens to be, or -- when run
# from the install directory -- mounts the existing 192MB FakeMoney and moneygraph
# TDB2 datasets alongside ours. FusekiMainCmd touches no `run/` directory at all.
#
# Overridable: FUSEKI_TEST_PORT (3030), FUSEKI_TEST_DATASET (jayhawk), FUSEKI_JAR.

set -e

FUSEKI_JAR="${FUSEKI_JAR:-$HOME/dev/apache-jena-fuseki-5.6.0/fuseki-server.jar}"
PORT="${FUSEKI_TEST_PORT:-3040}"
DATASET="${FUSEKI_TEST_DATASET:-jayhawk}"
GRAPH="urn:ontology"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
STATE="${TMPDIR:-/tmp}/jayhawk-fuseki"
PIDFILE="$STATE/fuseki-$PORT.pid"
LOGFILE="$STATE/fuseki-$PORT.log"

# FusekiMainCmd serves SPARQL query on the BARE dataset path. There is no
# /$DATASET/sparql and no /$/ping -- both 404. Verified, not assumed.
BASE="http://localhost:$PORT/$DATASET"
UPDATE="$BASE/update"
DATA="$BASE/data"

usage() {
    cat <<EOF
usage: $0 <command>

  start    launch an in-memory server on port $PORT with dataset /$DATASET
  stop     shut it down
  status   report whether it is up, and how many triples it holds
  load     load resource/gistAcct3.0.0.ttl into <$GRAPH>
  reset    drop every graph, leaving the server running
  url      print the query endpoint (for JAYHAWK_SPARQL_SERVICE)

Endpoints when running:
  query   $BASE
  update  $UPDATE
  data    $DATA        (SPARQL Graph Store Protocol)
EOF
}

# Readiness probe: an ASK against the dataset. /$/ping is an admin route and does
# not exist under FusekiMainCmd.
is_up() {
    curl -sf -G "$BASE" \
        --data-urlencode 'query=ASK {}' \
        -H 'Accept: application/sparql-results+json' \
        -o /dev/null 2>/dev/null
}

require_up() {
    is_up || { echo "fuseki is not running on port $PORT (try: $0 start)" >&2; exit 1; }
}

triple_count() {
    curl -s -G "$BASE" \
        --data-urlencode "query=SELECT (COUNT(*) AS ?n) WHERE { GRAPH <$GRAPH> { ?s ?p ?o } }" \
        -H 'Accept: application/sparql-results+json' \
    | sed -n 's/.*"value" *: *"\([0-9]*\)".*/\1/p' | head -1
}

cmd_start() {
    if is_up; then
        echo "already running: $BASE"
        return 0
    fi
    [ -f "$FUSEKI_JAR" ] || { echo "fuseki jar not found: $FUSEKI_JAR" >&2; exit 1; }
    mkdir -p "$STATE"

    # cd to STATE so that even an unexpected code path cannot drop a run/ dir in the repo.
    #
    # `cd X && nohup java ... &` would background the whole AND-list, making $! the
    # PID of the subshell rather than of java -- so `stop` would kill the wrapper and
    # leave the server running. Keeping `cd` as its own statement means the only
    # backgrounded command is java itself.
    (
        cd "$STATE" || exit 1
        nohup java -Xmx2G -cp "$FUSEKI_JAR" \
            org.apache.jena.fuseki.main.cmds.FusekiMainCmd \
            --port "$PORT" --mem --update "/$DATASET" > "$LOGFILE" 2>&1 &
        echo $! > "$PIDFILE"
    )

    i=0
    while [ $i -lt 40 ]; do
        if is_up; then
            echo "started: $BASE  (pid $(cat "$PIDFILE"), log $LOGFILE)"
            return 0
        fi
        i=$((i + 1))
        sleep 0.5
    done
    echo "failed to become ready within 20s; last log lines:" >&2
    tail -20 "$LOGFILE" >&2
    exit 1
}

cmd_stop() {
    if [ -f "$PIDFILE" ]; then
        pid=$(cat "$PIDFILE")
        kill "$pid" 2>/dev/null || echo "pid $pid was not running"
        rm -f "$PIDFILE"
    elif ! is_up; then
        echo "no pidfile at $PIDFILE; nothing to stop"
        return 0
    fi

    # Trust the port, not the exit status of kill. A stale or wrong pidfile would
    # otherwise let `stop` report success while the server kept serving.
    i=0
    while [ $i -lt 20 ]; do
        is_up || { echo "stopped"; return 0; }
        i=$((i + 1))
        sleep 0.5
    done

    echo "still answering on port $PORT after kill." >&2
    echo "the listener is:" >&2
    lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | tail -n +2 >&2
    exit 1
}

cmd_status() {
    if is_up; then
        echo "up:   $BASE"
        echo "graph <$GRAPH> holds $(triple_count) triples"
    else
        echo "down: nothing answering on port $PORT"
        exit 1
    fi
}

cmd_load() {
    require_up
    # The script moved from resource/ to bin/, so the fixtures are no longer beside it.
    for f in gistAcct3.0.0.ttl; do
        path="$SCRIPT_DIR/../resource/$f"
        [ -f "$path" ] || { echo "missing fixture: $path" >&2; exit 1; }
        code=$(curl -s -o /dev/null -w '%{http_code}' \
            -X POST -H 'Content-Type: text/turtle;charset=utf-8' \
            --data-binary "@$path" \
            "$DATA?graph=$(printf %s "$GRAPH" | sed 's/:/%3A/g')")
        case "$code" in
            200|201|204) echo "loaded $f ($code)" ;;
            *) echo "FAILED to load $f (HTTP $code)" >&2; exit 1 ;;
        esac
    done
    echo "graph <$GRAPH> now holds $(triple_count) triples"
}

cmd_reset() {
    require_up
    curl -sf -X POST -H 'Content-Type: application/sparql-update' \
        --data-binary 'DROP ALL' "$UPDATE" > /dev/null
    echo "dropped all graphs"
}

case "${1:-}" in
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    load)   cmd_load ;;
    reset)  cmd_reset ;;
    url)    echo "$BASE" ;;
    ""|-h|--help|help) usage ;;
    *) echo "unknown command: $1" >&2; usage >&2; exit 2 ;;
esac
