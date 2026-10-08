#!/usr/bin/env bash
# Samples cluster, JVM, Postgres, Redis and Kafka metrics every INTERVAL seconds until $OUT/stop exists.
# Usage: ops/collect.sh <outdir>      (the current phase label is read from $OUT/phase)
set -u
OUT=${1:?out dir}; INTERVAL=${INTERVAL:-8}
source "$(dirname "$0")/lib.sh"
mkdir -p "$OUT"; : > "$OUT/samples.txt"; rm -f "$OUT/stop"

PROM='
/^hikaricp_connections_active/  {a+=$NF}
/^hikaricp_connections_pending/ {p+=$NF}
/^hikaricp_connections_max/     {mx+=$NF}
/^jvm_memory_used_bytes\{area="heap"/ {h+=$NF}
/^jvm_gc_pause_seconds_count/   {gc+=$NF}
/^jvm_gc_pause_seconds_sum/     {gs+=$NF}
/^process_cpu_usage/            {pc=$NF}
/^jvm_threads_live_threads/     {th=$NF}
/^http_server_requests_seconds_count/ {hc+=$NF}
/^http_server_requests_seconds_sum/   {hs+=$NF}
/^http_server_requests_seconds_max/   {if ($NF>hm) hm=$NF}
END{printf "hik_active=%d hik_pending=%d hik_max=%d heap=%.0f gc_cnt=%d gc_sum=%.4f proc_cpu=%.3f threads=%d http_cnt=%d http_sum=%.4f http_max=%.4f\n", a,p,mx,h,gc,gs,pc,th,hc,hs,hm}'

PGQ="select xact_commit, xact_rollback, blks_read, blks_hit, tup_returned, tup_fetched, tup_inserted, deadlocks, \
(select count(*) from pg_stat_activity where datname='app'), \
(select count(*) from pg_stat_activity where datname='app' and state='active') \
from pg_stat_database where datname='app'"

cycle=0
while [ ! -f "$OUT/stop" ]; do
  ts=$(date +%s)
  {
    echo "@ $ts $(cat "$OUT/phase" 2>/dev/null || echo none)"
    $K top pods --no-headers 2>/dev/null | awk '{print "top",$1,$2,$3}'
    kubectl top nodes --no-headers 2>/dev/null | awk '{print "node",$1,$3,$5}'
    echo "hpa $($K get hpa backend -o jsonpath='{.status.currentReplicas} {.status.desiredReplicas}' 2>/dev/null)"
    echo "restarts $($K get pods --no-headers 2>/dev/null | awk '{s+=$4} END{print s+0}')"
    PRI=$(pg_primary)
    echo "pg $($K exec "$PRI" -c postgres -- psql -U postgres -d app -tA -F ' ' -c "$PGQ" 2>/dev/null)"
    echo "outbox $($K exec "$PRI" -c postgres -- psql -U postgres -d app -tAc "select count(*) from outbox where sent_at is null" 2>/dev/null)"
    echo "redis $($K exec deploy/redis -- sh -c 'redis-cli info stats; redis-cli info memory' 2>/dev/null | tr -d '\r' | awk -F: '/^keyspace_hits/ {h=$2} /^keyspace_misses/ {m=$2} /^evicted_keys/ {e=$2} /^instantaneous_ops_per_sec/ {o=$2} /^used_memory:/ {u=$2} END{printf "hits=%d misses=%d evicted=%d ops=%d mem=%d", h,m,e,o,u}')"
    for pod in $($K get pods -l app=backend --field-selector=status.phase=Running -o name 2>/dev/null | cut -d/ -f2); do
      echo "be $pod $($K exec "$pod" -- wget -qO- localhost:8080/actuator/prometheus 2>/dev/null | awk "$PROM")"
    done
    docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemPerc}}' 2>/dev/null | awk '/^jmeter/ {print "gen",$1,$2,$3}'
    if [ $((cycle % 3)) -eq 0 ]; then
      echo "lag $($K exec kafka-0 -- /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --group feed-cache-invalidator 2>/dev/null | awk '$6 ~ /^[0-9]+$/ {s+=$6} END{print s+0}')"
    fi
  } >> "$OUT/samples.txt"
  cycle=$((cycle+1)); sleep "$INTERVAL"
done
