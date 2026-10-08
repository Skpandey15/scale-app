#!/usr/bin/env bash
# High-availability drills.   Usage: ops/ha-drill.sh [failover|pooler|kafka|pitr|all]
#  failover: crash the Postgres primary under write traffic -> outage window + any acknowledged write lost?
#  pooler:   kill one PgBouncer pod                          -> failed requests
#  kafka:    kill one of three brokers                       -> writes keep flowing, no event lost
#  pitr:     restore the database to a past instant into a scratch cluster -> RTO + correctness
set -u
source "$(dirname "$0")/lib.sh"
BASE=${BASE:-http://localhost:8088}
OUT=${OUT:-/tmp/ha}; mkdir -p "$OUT"
now() { date +%s.%N; }
since() { echo "$(now) $1" | awk '{printf "%.1f", $1-$2}'; }
WHICH=${1:-all}

U="ha$RANDOM"; PW="pw-$RANDOM-$RANDOM-xxxxxxxx"
TOKEN=$(curl -s -X POST "$BASE/api/auth/register" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$U\",\"password\":\"$PW\"}" | sed -E 's/.*"token":"([^"]+)".*/\1/')
post() { curl -s -o /dev/null -w '%{http_code}' --max-time 3 -X POST "$BASE/api/posts" -H 'Content-Type: application/json' \
         -H "Authorization: Bearer $TOKEN" -d "{\"content\":\"$1\"}"; }
offsets() { $K exec kafka-0 -- /opt/kafka/bin/kafka-get-offsets.sh --bootstrap-server localhost:9092 --topic "$1" 2>/dev/null | awk -F: '{s+=$3} END{print s+0}'; }

# Writer + reader probes in the background; each write has a unique body so we can audit for lost writes afterwards.
start_probes() { # $1 = tag
  : > "$OUT/$1.writes"; : > "$OUT/$1.reads"
  ( n=0; while [ ! -f "$OUT/$1.stop" ]; do n=$((n+1)); s=$(now); c=$(post "$1-$n"); echo "$s $n $c" >> "$OUT/$1.writes"; sleep 0.2; done ) &
  W=$!
  ( while [ ! -f "$OUT/$1.stop" ]; do s=$(now); c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$BASE/api/posts?before=999999999&size=5"); echo "$s $c" >> "$OUT/$1.reads"; sleep 0.2; done ) &
  R=$!
}
stop_probes() { touch "$OUT/$1.stop"; wait "$W" "$R" 2>/dev/null; rm -f "$OUT/$1.stop"; }
report_probes() { # $1 = tag
  local w r
  w=$(awk '{t++; if ($3!="200") f++} END{printf "%d writes, %d failed", t, f+0}' "$OUT/$1.writes")
  r=$(awk '{t++; if ($2!="200") f++} END{printf "%d reads, %d failed", t, f+0}' "$OUT/$1.reads")
  echo "  probes: $w; $r"
  awk '$3!="200" {if (!a) a=$1; b=$1} END{if (a) printf "  write outage window: %.1fs (first failure -> last failure)\n", b-a; else print "  write outage window: none"}' "$OUT/$1.writes"
}
audit_writes() { # $1 = tag : every write we got HTTP 200 for must be in the database
  local acked found
  acked=$(awk '$3=="200" {print "'"$1"'-" $2}' "$OUT/$1.writes" | sort)
  found=$(psqlx -tAc "select content from posts where content like '$1-%'" | sort)
  echo "  acknowledged writes: $(echo "$acked" | grep -c .), present in database: $(echo "$found" | grep -c .), LOST: $(comm -23 <(echo "$acked") <(echo "$found") | grep -c .)"
}
wait_cluster_ready() { $K wait --for=condition=Ready cluster/"$1" --timeout=600s >/dev/null 2>&1; }

if [ "$WHICH" = failover ] || [ "$WHICH" = all ]; then
  echo "== 1. Postgres primary crash under write traffic =="
  OLD=$(pg_primary); echo "  primary before: $OLD"
  start_probes failover; sleep 5
  t0=$(now); $K delete pod "$OLD" --grace-period=0 --force >/dev/null 2>&1
  for i in $(seq 1 120); do NEW=$(pg_primary); [ -n "$NEW" ] && [ "$NEW" != "$OLD" ] && break; sleep 1; done
  echo "  new primary: $NEW (label set $(since $t0)s after the crash)"
  rec=""
  for i in $(seq 1 180); do      # wait until 5 consecutive writes succeed
    if [ "$(tail -n 5 "$OUT/failover.writes" | awk '$3=="200"' | wc -l)" = 5 ]; then
      rec=$(tail -n 5 "$OUT/failover.writes" | head -n 1 | awk '{print $1}'); break
    fi
    sleep 1
  done
  [ -n "$rec" ] && echo "  writes healthy again $(echo "$rec $t0" | awk '{printf "%.1f", $1-$2}')s after the crash" \
                || echo "  writes did NOT recover within 180s"
  sleep 8; stop_probes failover
  report_probes failover
  wait_cluster_ready scale-pg
  audit_writes failover
  echo "  cluster: $($K get cluster scale-pg -o jsonpath='{.status.phase}')"
  echo "  top backend errors during the drill:"
  $K logs -l app=backend --since=4m --tail=2000 2>/dev/null | grep -E "Exception|ERROR" \
    | sed -E 's/^[0-9T:.Z-]+ +//; s/[0-9]{4,}/N/g' | cut -c1-170 | sort | uniq -c | sort -rn | head -n 4
fi

if [ "$WHICH" = pooler ] || [ "$WHICH" = all ]; then
  echo "== 2. Kill one PgBouncer pod =="
  start_probes pooler; sleep 4
  $K delete pod "$($K get pods -l cnpg.io/poolerName=scale-pg-pooler-rw -o name | head -n 1 | cut -d/ -f2)" --grace-period=0 --force >/dev/null 2>&1
  sleep 20; stop_probes pooler
  report_probes pooler
  audit_writes pooler
fi

if [ "$WHICH" = kafka ] || [ "$WHICH" = all ]; then
  echo "== 3. Kill one of three Kafka brokers =="
  E0=$(offsets post-created); P0=$(psqlq "select count(*) from posts")
  start_probes kafka; sleep 5
  $K delete pod kafka-1 --grace-period=0 --force >/dev/null 2>&1
  sleep 40; stop_probes kafka
  report_probes kafka
  $K rollout status sts/kafka --timeout=240s >/dev/null 2>&1
  for i in $(seq 1 60); do [ "$(psqlq 'select count(*) from outbox where sent_at is null')" = "0" ] && break; sleep 2; done
  E1=$(offsets post-created); P1=$(psqlq "select count(*) from posts")
  echo "  outbox pending after recovery: $(psqlq 'select count(*) from outbox where sent_at is null')"
  echo "  posts created: $((P1-P0)), events in Kafka: $((E1-E0)) (equal => none lost)"
  $K exec kafka-0 -- /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic post-created 2>/dev/null \
    | awk '/Partition:/ {n++; if ($0 ~ /Isr: 1,2,3|Isr: [123],[123],[123]/) ok++} END{printf "  partitions fully in sync: %d/%d\n", ok, n}'
fi

if [ "$WHICH" = pitr ] || [ "$WHICH" = all ]; then
  echo "== 4. Point-in-time recovery into a scratch cluster =="
  for i in 1 2 3 4 5; do post "pitr-before-$i" >/dev/null; done
  sleep 2
  T=$(psqlx -tAc "select to_char(now() at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS.US')||'+00'" | tr -d '\r')
  echo "  recovery target: $T"
  sleep 2
  for i in 1 2 3 4 5; do post "pitr-after-$i" >/dev/null; done
  psqlx -tAc "select pg_switch_wal()" >/dev/null     # push the WAL holding both batches to the archive now
  sleep 15
  $K delete cluster scale-pg-restore --ignore-not-found >/dev/null 2>&1
  r0=$(now)
  cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: scale-pg-restore, namespace: scale }
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:16
  storage: { size: 3Gi }
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits: { memory: 512Mi }
  bootstrap:
    recovery:
      source: origin
      recoveryTarget: { targetTime: "$T" }
  externalClusters:
    - name: origin
      barmanObjectStore:
        serverName: scale-pg
        destinationPath: s3://pg-backups/
        endpointURL: http://seaweedfs.scale.svc.cluster.local:8333
        s3Credentials:
          accessKeyId: { name: backup-s3, key: ACCESS_KEY_ID }
          secretAccessKey: { name: backup-s3, key: ACCESS_SECRET_KEY }
EOF
  if wait_cluster_ready scale-pg-restore; then
    echo "  restore cluster ready after $(since $r0)s (RTO for this data size)"
    q() { $K exec scale-pg-restore-1 -c postgres -- psql -U postgres -d app -tAc "$1" | tr -d '[:space:]'; }
    echo "  rows 'pitr-before-*' in restored DB: $(q "select count(*) from posts where content like 'pitr-before-%'") (expected 5)"
    echo "  rows 'pitr-after-*'  in restored DB: $(q "select count(*) from posts where content like 'pitr-after-%'") (expected 0)"
    echo "  rows 'pitr-after-*'  in live DB:     $(psqlq "select count(*) from posts where content like 'pitr-after-%'") (expected 5)"
  else
    echo "  restore cluster did not become ready in time"; $K get cluster scale-pg-restore 2>&1 | tail -n 2
  fi
  $K delete cluster scale-pg-restore --wait=false >/dev/null 2>&1
fi
