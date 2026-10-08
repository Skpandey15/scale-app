#!/usr/bin/env bash
# Quick (curl-based, NOT a JMeter-grade) check of the catalog read API plus a pod-kill test.
# Usage: ops/catalog-perf.sh      Rough numbers only: client and cluster share one machine.
set -u
K="kubectl -n scale"
BASE=${BASE:-http://localhost:8088}
TMP=$(mktemp -d)

pct() { python3 - "$1" <<'PY'
import sys
v = sorted(float(x) for x in open(sys.argv[1]) if x.strip())
if not v: print("no data"); raise SystemExit
q = lambda p: v[min(len(v)-1, int(p*len(v)))]*1000
print("n=%d  p50=%.0fms  p95=%.0fms  p99=%.0fms  max=%.0fms" % (len(v), q(.5), q(.95), q(.99), v[-1]*1000))
PY
}

run_load() { # $1 label  $2 total  $3 parallel  $4.. curl args generator function name
  local label=$1 total=$2 par=$3 gen=$4 start end
  start=$(date +%s.%N)
  seq 1 "$total" | xargs -P "$par" -I{} bash -c "$gen {}" > "$TMP/$label.times"
  end=$(date +%s.%N)
  awk -v n="$total" -v s="$start" -v e="$end" -v l="$label" 'BEGIN{printf "  %-28s %6.0f req/s  ", l, n/(e-s)}'
  awk '$2!="200"{bad++} END{printf "non-200: %d  ", bad+0}' "$TMP/$label.times"
  awk '{print $1}' "$TMP/$label.times" > "$TMP/$label.t"; pct "$TMP/$label.t"
}

cached_get() { curl -s -o /dev/null -w "%{time_total} %{http_code}\n" "$BASE/catalog/api/titles/movie:inception:2010"; }
gql_search() {
  words=(hacker thief teacher dreams simulation chemistry); w=${words[$(( $1 % 6 ))]}
  curl -s -o /dev/null -w "%{time_total} %{http_code}\n" -X POST "$BASE/catalog/graphql" -H 'Content-Type: application/json' \
    -d "{\"query\":\"{ searchTitles(q:\\\"$w\\\", first:10) { items { id name } nextCursor } }\"}"
}
export -f cached_get gql_search; export BASE

echo "== read API, 2 catalog pods, curl clients =="
cached_get >/dev/null
run_load "REST get (cache hit)"        3000 30 cached_get
run_load "GraphQL search (Mongo text)" 1000 20 gql_search

echo "== kill one catalog pod during steady traffic (10 req/s for ~25 s) =="
( for i in $(seq 1 250); do curl -s -o /dev/null -w "%{http_code}\n" --max-time 3 "$BASE/catalog/api/titles/movie:inception:2010"; sleep 0.1; done > "$TMP/kill.codes" ) &
PROBE=$!
sleep 5
$K delete pod "$($K get pods -l app=catalog -o name | head -n 1 | cut -d/ -f2)" --wait=false >/dev/null
wait "$PROBE"
echo "  requests: $(wc -l < "$TMP/kill.codes"), non-200: $(grep -vc '^200$' "$TMP/kill.codes")"
$K rollout status deploy/catalog --timeout=120s >/dev/null 2>&1
echo "  pods: $($K get pods -l app=catalog --no-headers | awk '{print $2}' | tr '\n' ' ')"
