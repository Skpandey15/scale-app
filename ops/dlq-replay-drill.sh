#!/usr/bin/env bash
# (1) Outbox guarantees: a Kafka outage loses no events.  (2) Poison message -> retries -> DLT.  (3) Replay from the outbox.
set -u
K="kubectl -n scale"
BASE=${BASE:-http://localhost:8088}
KAFKA="$K exec kafka-0 --"
source "$(dirname "$0")/lib.sh"
offsets() { $KAFKA /opt/kafka/bin/kafka-get-offsets.sh --bootstrap-server localhost:9092 --topic "$1" 2>/dev/null | awk -F: '{s+=$3} END{print s+0}'; }

U="dq$RANDOM"; PW="pw-$RANDOM-$RANDOM-xxxxxxxx"
TOKEN=$(curl -s -X POST "$BASE/api/auth/register" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$U\",\"password\":\"$PW\"}" | sed -E 's/.*"token":"([^"]+)".*/\1/')
post() { curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/posts" -H 'Content-Type: application/json' \
         -H "Authorization: Bearer $TOKEN" -d "{\"content\":\"$1\"}"; }

echo "== 1. Kafka outage with the outbox =="
E0=$(offsets post-created); P0=$(psqlq "select count(*) from posts")
$K scale sts/kafka --replicas=0 >/dev/null; sleep 8
codes=""; for i in $(seq 1 20); do codes="$codes $(post "during-outage-$i")"; done
echo "20 writes while Kafka is DOWN -> status codes:$codes"
echo "outbox pending (should be ~20): $(psqlq 'select count(*) from outbox where sent_at is null')"
$K scale sts/kafka --replicas=3 >/dev/null
$K rollout status sts/kafka --timeout=240s >/dev/null
for i in $(seq 1 60); do [ "$(psqlq 'select count(*) from outbox where sent_at is null')" = "0" ] && break; sleep 2; done
E1=$(offsets post-created); P1=$(psqlq "select count(*) from posts")
echo "outbox pending after Kafka recovered: $(psqlq 'select count(*) from outbox where sent_at is null')"
echo "posts created: $((P1-P0)), events delivered: $((E1-E0))  (equal => nothing lost)"

echo "== 2. Poison message -> retry x3 -> DLT =="
D0=$(offsets post-created.DLT)
echo 'this-is-not-json' | $K exec -i kafka-0 -- /opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server localhost:9092 --topic post-created >/dev/null 2>&1
sleep 10
D1=$(offsets post-created.DLT)
echo "messages on post-created.DLT: $D0 -> $D1"
echo "healthy messages still flowing: HTTP $(post after-poison)"

echo "== 3. Replay from the outbox =="
O0=$(offsets post-created)
psqlx -qc \
  "update outbox set sent_at=null where id in (select id from outbox order by id desc limit 25)"
sleep 6
O1=$(offsets post-created)
echo "re-sent: $((O1-O0)) events (consumers are idempotent, so duplicates are harmless)"
