#!/usr/bin/env bash
# Scalability suite: stepped load (50 -> 500 users) + zero-think-time stress, with server-side metric collection.
# Usage (inside WSL):  bash ops/perf-suite.sh      then:  python3 ops/analyze.py /tmp/perf <scale-app dir>
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT=${OUT:-/tmp/perf}
rm -rf "$OUT"; mkdir -p "$OUT"; : > "$OUT/phases.log"; : > "$OUT/phases.conf"

bash "$ROOT/ops/collect.sh" "$OUT" & COLL=$!
echo idle > "$OUT/phase"; sleep 24

# name threads rampup duration think thinkrange
phase() {
  echo "$1 $2 $3 $4 $5" >> "$OUT/phases.conf"
  echo "$1" > "$OUT/phase"
  echo "$(date +%s) $1 start" >> "$OUT/phases.log"
  bash "$ROOT/ops/jmeter.sh" "$1" -Jthreads="$2" -Jrampup="$3" -Jduration="$4" -Jthink="$5" -Jthinkrange="$6" >/dev/null 2>&1
  echo "$(date +%s) $1 end" >> "$OUT/phases.log"
  echo idle > "$OUT/phase"; sleep 24
}

phase step-50     50  15  75 200 300
phase step-150   150  20  80 200 300
phase step-300   300  30  90 200 300
phase step-500   500  40 100 200 300
phase stress-100 100  15  75   0   1

touch "$OUT/stop"; wait "$COLL" 2>/dev/null
echo "suite finished"
