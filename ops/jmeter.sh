#!/usr/bin/env bash
# Run the JMeter plan headless in Docker (heap and CPU capped), producing a JTL and an HTML dashboard.
# Usage: ops/jmeter.sh <run-name> [extra -J args...]     e.g.  ops/jmeter.sh ramp -Jthreads=300 -Jrampup=120 -Jduration=240
set -eu
NAME=${1:?run name}; shift
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/loadtest/jmeter-$NAME"
rm -rf "$RUN"; mkdir -p "$RUN"

# MIN_ID lets deep-page requests target the real id range (important when the table was bulk-seeded).
source "$ROOT/ops/lib.sh"
MIN_ID=$(psqlq "select coalesce(min(id),2) from posts")

# Linux/WSL: share the host network so localhost:8088 works. Docker Desktop on macOS has no usable host networking,
# so there the container reaches the published port through host.docker.internal instead.
if [ "$(uname)" = "Darwin" ]; then NET=(); TARGET=(-Jhost=host.docker.internal); else NET=(--network host); TARGET=(); fi

docker run --rm --name "jmeter-$NAME" "${NET[@]}" --cpus 3 --memory 1536m \
  -e JVM_ARGS="${JMETER_JVM_ARGS:--Xms512m -Xmx1g}" \
  -v "$ROOT/loadtest:/work" justb4/jmeter:5.5 \
  -n -t /work/scale.jmx \
  -l "/work/jmeter-$NAME/results.jtl" -e -o "/work/jmeter-$NAME/report" \
  -j "/work/jmeter-$NAME/jmeter.log" \
  -JMIN_ID="$MIN_ID" "${TARGET[@]}" "$@"
