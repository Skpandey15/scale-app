#!/usr/bin/env bash
# Re-check after the connection-pool fix: warm-up (lets the HPA reach its ceiling like the original suite) + the stress phase.
# Then:  python3 ops/analyze.py /tmp/perf-after <scale-app dir> PERF_REPORT_pool10.md
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT=${OUT:-/tmp/perf-after}
rm -rf "$OUT"; mkdir -p "$OUT"; : > "$OUT/phases.log"; : > "$OUT/phases.conf"

bash "$ROOT/ops/collect.sh" "$OUT" & COLL=$!
echo idle > "$OUT/phase"; sleep 24

phase() {
  echo "$1 $2 $3 $4 $5" >> "$OUT/phases.conf"
  echo "$1" > "$OUT/phase"
  echo "$(date +%s) $1 start" >> "$OUT/phases.log"
  bash "$ROOT/ops/jmeter.sh" "$1" -Jthreads="$2" -Jrampup="$3" -Jduration="$4" -Jthink="$5" -Jthinkrange="$6" >/dev/null 2>&1
  echo "$(date +%s) $1 end" >> "$OUT/phases.log"
  echo idle > "$OUT/phase"; sleep 24
}

[ "${SKIP_WARM:-0}" = "1" ] || phase "${WARM_NAME:-warm-300-pool10}" 300 20 80 200 300
phase "${STRESS_NAME:-stress-100-pool10}" 100 15 75 0 1

touch "$OUT/stop"; wait "$COLL" 2>/dev/null
echo "suite finished"
