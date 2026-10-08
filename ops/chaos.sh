#!/usr/bin/env bash
# Chaos drill: steady load + independent read/write probes while failures are injected.
# Run from WSL:  bash ops/chaos.sh      Results: $OUT/{events,probe_read,probe_write}.log + summary
set -u
K="kubectl -n scale"
OUT=${OUT:-/tmp/chaos}
BASE=${BASE:-http://localhost:8088}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$OUT"; : > "$OUT/events.log"; : > "$OUT/probe_read.log"; : > "$OUT/probe_write.log"

ev() { echo "$(date +%s.%N) $*" | tee -a "$OUT/events.log"; }
restore() {
  $K scale sts/kafka --replicas=3 >/dev/null 2>&1
  $K scale deploy/redis --replicas=1 >/dev/null 2>&1
  kubectl uncordon k3d-scale-agent-1 >/dev/null 2>&1
  [ -n "${READ_PID:-}" ] && kill "$READ_PID" "$WRITE_PID" 2>/dev/null
  docker rm -f k6chaos >/dev/null 2>&1
}
trap restore EXIT

sum_offsets() { $K exec kafka-0 -- /opt/kafka/bin/kafka-get-offsets.sh --bootstrap-server localhost:9092 --topic post-created 2>/dev/null | awk -F: '{s+=$3} END{print s+0}'; }
source "$ROOT/ops/lib.sh"
count_posts() { psqlq "select count(*) from posts"; }

POSTS0=$(count_posts); EVENTS0=$(sum_offsets)

# writer identity for the write probe
U="probe$RANDOM"; PW="pw-$RANDOM-$RANDOM-xxxxxxxx"
TOKEN=$(curl -s -X POST "$BASE/api/auth/register" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$U\",\"password\":\"$PW\"}" | sed -E 's/.*"token":"([^"]+)".*/\1/')

( while true; do
    s=$(date +%s.%N)
    r=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 3 "$BASE/api/posts" || echo "000 3")
    echo "$s $r" >> "$OUT/probe_read.log"; sleep 0.2
  done ) & READ_PID=$!
( while true; do
    s=$(date +%s.%N)
    r=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 3 -X POST "$BASE/api/posts" \
        -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" -d '{"content":"write probe"}' || echo "000 3")
    echo "$s $r" >> "$OUT/probe_write.log"; sleep 0.5
  done ) & WRITE_PID=$!

docker run -d --name k6chaos --network host --cpus 2 --memory 1g -v "$ROOT/loadtest:/scripts" \
  grafana/k6 run /scripts/chaos.js >/dev/null
sleep 20

ev "baseline"; sleep 20
ev "kill-1-backend-pod"
$K delete pod "$($K get pods -l app=backend -o name | head -n 1 | cut -d/ -f2)" --wait=false >/dev/null; sleep 25
ev "settle"; sleep 10
ev "kill-2-backend-pods"
for p in $($K get pods -l app=backend -o name | head -n 2 | cut -d/ -f2); do $K delete pod "$p" --wait=false >/dev/null; done; sleep 30
ev "settle"; sleep 10
ev "drain-node-agent-1"
kubectl drain k3d-scale-agent-1 --ignore-daemonsets --delete-emptydir-data --force --timeout=60s >/dev/null 2>&1
ev "drain-done(node-out)"; sleep 20
ev "uncordon-agent-1"; kubectl uncordon k3d-scale-agent-1 >/dev/null; sleep 25
ev "settle"; sleep 10
ev "redis-down(20s)"; $K scale deploy/redis --replicas=0 >/dev/null; sleep 20
ev "redis-up"; $K scale deploy/redis --replicas=1 >/dev/null; sleep 25
ev "kafka-ALL-brokers-down(25s)"; $K scale sts/kafka --replicas=0 >/dev/null; sleep 25
ev "kafka-up"; $K scale sts/kafka --replicas=3 >/dev/null; sleep 70
ev "settle"; sleep 10
ev "kill-traefik-ingress-pod"
kubectl -n kube-system delete pod "$(kubectl -n kube-system get pods -l app.kubernetes.io/name=traefik -o name | head -n 1 | cut -d/ -f2)" --wait=false >/dev/null; sleep 35
ev "end"
kill "$READ_PID" "$WRITE_PID" 2>/dev/null
docker logs k6chaos 2>&1 | tail -n 30 > "$OUT/k6_tail.txt"
docker wait k6chaos >/dev/null 2>&1

summarize() { # $1=label $2=file
  awk -v label="$1" 'NR==FNR{n++; et[n]=$1; $1=""; en[n]=$0; next}
    { idx=0; for(i=1;i<=n;i++) if($1>=et[i]) idx=i;
      tot[idx]++; if($2!="200") fail[idx]++; ms=$3*1000; sum[idx]+=ms; if(ms>mx[idx]) mx[idx]=ms }
    END{ for(i=0;i<=n;i++) if(tot[i]) printf "%-6s %-34s req=%-4d fail=%-4d avg=%4.0fms max=%5.0fms\n",
         label, (i==0?"before-baseline":en[i]), tot[i], fail[i]+0, sum[i]/tot[i], mx[i] }' "$OUT/events.log" "$2"
}
{
  summarize READ "$OUT/probe_read.log"
  summarize WRITE "$OUT/probe_write.log"
  POSTS1=$(count_posts); EVENTS1=$(sum_offsets)
  echo "posts created during drill : $((POSTS1-POSTS0))"
  echo "kafka events delivered     : $((EVENTS1-EVENTS0))"
  echo "events lost                : $(( (POSTS1-POSTS0) - (EVENTS1-EVENTS0) ))"
} | tee "$OUT/summary.txt"
