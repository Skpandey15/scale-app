#!/usr/bin/env bash
# Catalog service drills.   Usage: ops/catalog-drill.sh [resolve|idempotent|graphql|poison|stats|security|outage|all]
#  resolve:    15 records from 3 feeds (with duplicates and spelling variants) must fold into 8 titles
#  idempotent: replaying the same records must change nothing (no version bump)
#  graphql:    queries, cursor pagination, depth limit, introspection off
#  poison:     unparseable / invalid records go to the dead-letter topic without blocking good ones
#  stats:      Kafka Streams per-source ingest counts
#  security:   API key required for ingest, input validated
#  outage:     Mongo down -> stale cache + fast 503s (circuit breaker), writes keep being accepted and are applied on recovery
set -u
K="kubectl -n scale"
BASE=${BASE:-http://localhost:8088}
WHICH=${1:-all}
KEY=$($K get secret catalog-secrets -o jsonpath='{.data.CATALOG_API_KEY}' | base64 --decode)
ROOTPW=$($K get secret catalog-secrets -o jsonpath='{.data.MONGO_ROOT_PASSWORD}' | base64 --decode)
mongo_eval() { $K exec mongo-0 -- mongosh --quiet -u root -p "$ROOTPW" --authenticationDatabase admin catalog --eval "$1" 2>/dev/null | tail -n 1; }
offsets() { $K exec kafka-0 -- /opt/kafka/bin/kafka-get-offsets.sh --bootstrap-server localhost:9092 --topic "$1" 2>/dev/null | awk -F: '{s+=$3} END{print s+0}'; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
ingest() { curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/catalog/api/ingest/batch" -H "X-API-Key: $KEY" -H 'Content-Type: application/json' -d "$1"; }
gql() { curl -s -X POST "$BASE/catalog/graphql" -H 'Content-Type: application/json' -d "$1"; }
wait_title() { for i in $(seq 1 40); do [ "$(code "$BASE/catalog/api/titles/$1")" = 200 ] && return 0; sleep 1; done; return 1; }
show() { python3 -c "import sys,json; d=json.load(sys.stdin); print('   ', {k:d[k] for k in ('id','name','sources','confidence','genres','stale') if k in d})"; }

SEED='[
 {"source":"studioA","type":"movie","name":"The Matrix","year":1999,"genres":["sci-fi","action"],"description":"A hacker learns reality is a simulation."},
 {"source":"tvguide","type":"movie","name":"THE MATRIX!","year":1999,"genres":["Action"],"description":"A computer hacker learns from mysterious rebels about the true nature of his reality and his role in the war against its controllers."},
 {"source":"indexdb","type":"movie","name":"The Matrix","year":1999,"genres":["Thriller"]},
 {"source":"studioA","type":"movie","name":"Inception","year":2010,"genres":["sci-fi","thriller"],"description":"A thief steals secrets through dreams."},
 {"source":"tvguide","type":"movie","name":"Inception","year":2010,"genres":["Action"]},
 {"source":"studioA","type":"series","name":"Breaking Bad","year":2008,"genres":["drama","crime"]},
 {"source":"tvguide","type":"series","name":"Breaking Bad","year":2008,"genres":["Thriller"],"description":"A chemistry teacher turns to making methamphetamine."},
 {"source":"indexdb","type":"series","name":"breaking bad","year":2008},
 {"source":"studioA","type":"movie","name":"Amélie","year":2001,"genres":["romance","comedy"]},
 {"source":"tvguide","type":"movie","name":"Amelie","year":2001},
 {"source":"studioA","type":"movie","name":"Parasite","year":2019,"genres":["thriller","drama"]},
 {"source":"tvguide","type":"movie","name":"Spirited Away","year":2001,"genres":["animation"]},
 {"source":"indexdb","type":"movie","name":"The Godfather","year":1972,"genres":["crime","drama"]},
 {"source":"studioA","type":"movie","name":"Interstellar","year":2014,"genres":["sci-fi"]},
 {"source":"indexdb","type":"movie","name":"Interstellar","year":2014,"genres":["Adventure"]}
]'
MATRIX="movie:thematrix:1999"

if [ "$WHICH" = security ] || [ "$WHICH" = all ]; then
  echo "== security / validation =="
  echo "  ingest without a key:        HTTP $(code -X POST "$BASE/catalog/api/ingest/batch" -H 'Content-Type: application/json' -d '[]')   (expect 401)"
  echo "  ingest with a wrong key:     HTTP $(code -X POST "$BASE/catalog/api/ingest/batch" -H 'X-API-Key: nope' -H 'Content-Type: application/json' -d '[]')   (expect 401)"
  echo "  invalid record (year 1500):  HTTP $(code -X POST "$BASE/catalog/api/ingest" -H "X-API-Key: $KEY" -H 'Content-Type: application/json' -d '{"source":"x","type":"movie","name":"Old","year":1500}')   (expect 400)"
  echo "  invalid type:                HTTP $(code -X POST "$BASE/catalog/api/ingest" -H "X-API-Key: $KEY" -H 'Content-Type: application/json' -d '{"source":"x","type":"song","name":"S","year":2000}')   (expect 400)"
  echo "  reads need no key:           HTTP $(code "$BASE/catalog/api/titles?q=matrix")   (expect 200 or 503 if Mongo is down)"
  echo "  actuator via ingress:        HTTP $(code "$BASE/catalog/actuator/prometheus")   (expect 404: it lives on a private port)"
fi

if [ "$WHICH" = resolve ] || [ "$WHICH" = all ]; then
  echo "== entity resolution: 15 records from 3 feeds -> expect 8 titles =="
  echo "  ingest batch -> HTTP $(ingest "$SEED")   (expect 202)"
  wait_title "$MATRIX" || echo "  (matrix did not appear in 40s)"
  sleep 4
  echo "  titles in Mongo: $(mongo_eval 'db.titles.countDocuments()')   (expect 8)"
  echo "  The Matrix (3 feeds: 'The Matrix', 'THE MATRIX!', 'The Matrix'):"
  curl -s "$BASE/catalog/api/titles/$MATRIX" | show
  echo "  Amelie (accent folding: 'Amélie' + 'Amelie'):"
  curl -s "$BASE/catalog/api/titles/movie:amelie:2001" | show
  echo "  Breaking Bad ('Breaking Bad' x2 + 'breaking bad'):"
  curl -s "$BASE/catalog/api/titles/series:breakingbad:2008" | show
  echo "  richest description kept for The Matrix: $(curl -s "$BASE/catalog/api/titles/$MATRIX" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["description"] or ""), "chars")')"
fi

if [ "$WHICH" = idempotent ] || [ "$WHICH" = all ]; then
  echo "== idempotency: replay the same 15 records =="
  V0=$(mongo_eval "db.titles.find({}, {version:1}).sort({_id:1}).toArray().map(d=>d._id+'='+d.version).join(',')")
  echo "  replay -> HTTP $(ingest "$SEED")"; sleep 8
  V1=$(mongo_eval "db.titles.find({}, {version:1}).sort({_id:1}).toArray().map(d=>d._id+'='+d.version).join(',')")
  [ "$V0" = "$V1" ] && echo "  document versions unchanged after the replay: replays are no-ops" || { echo "  versions CHANGED:"; echo "   before: $V0"; echo "   after:  $V1"; }
  echo "  titles in Mongo: $(mongo_eval 'db.titles.countDocuments()')   (still 8)"
fi

if [ "$WHICH" = graphql ] || [ "$WHICH" = all ]; then
  echo "== GraphQL =="
  echo "  title(id):"
  gql '{"query":"{ title(id:\"movie:inception:2010\") { id name year genres sources confidence stale } }"}' | python3 -c 'import sys,json; print("   ", json.load(sys.stdin)["data"]["title"])'
  echo "  searchTitles over name + description (OR of words), 2 per page, following the cursor:"
  R1=$(gql '{"query":"{ searchTitles(q:\"hacker thief teacher\", first:2) { items { id } nextCursor } }"}')
  echo "$R1" | python3 -c 'import sys,json; d=json.load(sys.stdin)["data"]["searchTitles"]; print("    page1:", [i["id"] for i in d["items"]], "next:", d["nextCursor"])'
  CUR=$(echo "$R1" | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"]["searchTitles"]["nextCursor"] or "")')
  if [ -n "$CUR" ]; then
    gql "{\"query\":\"{ searchTitles(q:\\\"hacker thief teacher\\\", first:2, after:\\\"$CUR\\\") { items { id } nextCursor } }\"}" \
      | python3 -c 'import sys,json; d=json.load(sys.stdin)["data"]["searchTitles"]; print("    page2:", [i["id"] for i in d["items"]], "next:", d["nextCursor"])'
  fi
  echo "  introspection disabled:  $(gql '{"query":"{ __schema { types { name } } }"}' | python3 -c 'import sys,json; d=json.load(sys.stdin); print("blocked" if d.get("errors") else "OPEN (unexpected)")')"
  FLOOD='{'; for n in $(seq 1 150); do FLOOD="$FLOOD a$n:title(id:\\\"x\\\"){id}"; done; FLOOD="$FLOOD }"
  echo "  150-alias query (cost limit 100): $(gql "{\"query\":\"$FLOOD\"}" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("rejected: "+str(d.get("errors",[{}])[0].get("message",""))[:80] if d.get("errors") and not d.get("data") else "ACCEPTED (limit not applied)")')"
fi

if [ "$WHICH" = poison ] || [ "$WHICH" = all ]; then
  echo "== poison records -> dead-letter topic =="
  D0=$(offsets metadata-raw.DLT)
  printf 'this-is-not-json\n{"source":"x","type":"movie","name":"Too Old","year":1500}\n' | $K exec -i kafka-0 -- /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 --topic metadata-raw >/dev/null 2>&1
  sleep 8
  D1=$(offsets metadata-raw.DLT)
  echo "  messages on metadata-raw.DLT: $D0 -> $D1   (expect +2: no retries, no blocking)"
  echo "  a good record right after still flows: ingest HTTP $(ingest '[{"source":"studioA","type":"movie","name":"Whiplash","year":2014,"genres":["drama"]}]')"
  wait_title "movie:whiplash:2014" && echo "  Whiplash appeared in the catalog: yes" || echo "  Whiplash did not appear (BAD)"
fi

if [ "$WHICH" = stats ] || [ "$WHICH" = all ]; then
  echo "== Kafka Streams: ingest rate per source per minute =="
  sleep 3
  curl -s "$BASE/catalog/api/stats/ingest-rate?minutes=30" | python3 -c '
import sys, json
rows = json.load(sys.stdin)
if not rows: print("   (no windows yet)")
for r in sorted(rows, key=lambda r: (r["windowStart"], r["source"])): print("   ", r["windowStart"], r["source"].ljust(8), r["count"])'
fi

if [ "$WHICH" = outage ] || [ "$WHICH" = all ]; then
  echo "== Mongo outage: circuit breaker, stale cache, buffered writes =="
  breaker() { $K exec deploy/catalog -- wget -qO- localhost:8081/actuator/prometheus 2>/dev/null | grep '^resilience4j_circuitbreaker_state{' | grep ' 1.0' | sed -E 's/.*state="([a-z_]+)".*/\1/' | tr '\n' ' '; }
  curl -s -o /dev/null "$BASE/catalog/api/titles/$MATRIX"                     # warm: fills fresh + stale caches
  echo "  breaker before: $(breaker)"
  $K scale sts/mongo --replicas=0 >/dev/null; $K wait --for=delete pod/mongo-0 --timeout=60s >/dev/null 2>&1
  $K exec deploy/redis -- redis-cli del "catalog:fresh:$MATRIX" >/dev/null     # force a Mongo attempt for the cached title
  echo "  Mongo is DOWN. The Matrix (fresh cache evicted, stale copy exists):"
  curl -s "$BASE/catalog/api/titles/$MATRIX" | show
  echo "  titles never read before (no stale copy): latency per request, watch the breaker open:"
  i=0; for id in movie:parasite:2019 movie:spiritedaway:2001 movie:thegodfather:1972 movie:interstellar:2014 movie:whiplash:2014 movie:amelie:2001 movie:inception:2010 series:breakingbad:2008 movie:parasite:2019 movie:parasite:2019; do
    i=$((i+1)); curl -s -o /dev/null -w "    #$i  HTTP %{http_code}  %{time_total}s\n" "$BASE/catalog/api/titles/$id"
  done
  echo "  breaker now: $(breaker)"
  L0=$($K exec kafka-0 -- /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --group catalog-normalizer 2>/dev/null | awk '$6 ~ /^[0-9]+$/ {s+=$6} END{print s+0}')
  D0=$(offsets metadata-raw.DLT)
  echo "  ingest during the outage -> HTTP $(ingest '[{"source":"studioA","type":"movie","name":"Outage Test One","year":2020},{"source":"tvguide","type":"movie","name":"Outage Test Two","year":2021}]')   (Kafka still accepts: expect 202)"
  sleep 6
  L1=$($K exec kafka-0 -- /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --group catalog-normalizer 2>/dev/null | awk '$6 ~ /^[0-9]+$/ {s+=$6} END{print s+0}')
  echo "  consumer lag: $L0 -> $L1   (records wait; the consumer retries instead of dead-lettering)"
  echo "  dead-letter count unchanged: $D0 -> $(offsets metadata-raw.DLT)"
  $K scale sts/mongo --replicas=1 >/dev/null; $K rollout status sts/mongo --timeout=180s >/dev/null 2>&1
  for i in $(seq 1 60); do [ "$(code "$BASE/catalog/api/titles/movie:outagetestone:2020")" = 200 ] && break; sleep 2; done
  echo "  Mongo is back. Outage Test One present: HTTP $(code "$BASE/catalog/api/titles/movie:outagetestone:2020"), Two: HTTP $(code "$BASE/catalog/api/titles/movie:outagetesttwo:2021")   (expect 200 200: nothing lost)"
  echo "  breaker after recovery: $(breaker)   (closed)"
  echo "  The Matrix again: $(curl -s "$BASE/catalog/api/titles/$MATRIX" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("stale="+str(d["stale"]))')"
fi
