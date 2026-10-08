# Catalog service: curated media metadata

A second service in the same cluster, modelled on a metadata-curation problem: several feeds describe the same movies and
series with different spellings and partial data; the service folds them into one trusted record per title and serves it
over **REST and GraphQL**.

```
feeds --POST /catalog/api/ingest (X-API-Key)--> Kafka metadata-raw (RF 3, keyed by canonical id)
                                                     |-> catalog-normalizer: validate + entity-resolve + merge --> MongoDB (titles)
                                                     |-> Kafka Streams: records per source per minute --> ingest-rate-1m --> Mongo (ingest_stats)
clients --GET /catalog/api/titles/{id} | /catalog/graphql--> Redis (fresh 60s + stale 1d) --circuit breaker--> MongoDB
```

## Behaviour

| Concern | How |
|---|---|
| Entity resolution | Canonical id = type + accent/punctuation-folded lower-case name + year, so "The Matrix", "THE MATRIX!" and "Amélie"/"Amelie" collapse. Not fuzzy ("Matrix, The" would not match). |
| Merge | Union of genres and sources, richest description wins, confidence = 50 + 20 per distinct source (max 100). |
| Idempotent | A replay that adds nothing writes nothing (document version unchanged), so at-least-once delivery and DLT replays are safe. Concurrent merges use optimistic locking with bounded retry. |
| Poison records | Unparseable or invalid records go straight to `metadata-raw.DLT`; they never block the partition. |
| Infrastructure failures | If Mongo is down the consumer retries with capped backoff **forever** (offsets uncommitted), so outages never push good records to the DLT or lose them. |
| Read path | Redis cache-aside behind a circuit breaker. Mongo failing or breaker open: serve the **stale** copy (flagged `stale: true`) if one exists, otherwise a fast 503. |
| GraphQL | `title(id)`, `searchTitles(q, first, after)` with cursor pagination (`first` capped at 50), introspection off, query cost limit 100. |
| Streams | Per-source ingest counts in 1-minute tumbling windows (10 s grace), in-memory store; exposed at `/catalog/api/stats/ingest-rate`. |
| Security | Ingest needs `X-API-Key` (constant-time compare, random key from `catalog-secrets`); reads are public; actuator is on a private port (8081) that the Service and Ingress do not publish; Mongo uses a least-privilege app user. |

## Try it

```bash
KEY=$(kubectl -n scale get secret catalog-secrets -o jsonpath='{.data.CATALOG_API_KEY}' | base64 --decode)
curl -X POST localhost:8088/catalog/api/ingest -H "X-API-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"source":"studioA","type":"movie","name":"The Matrix","year":1999,"genres":["sci-fi"]}'
curl localhost:8088/catalog/api/titles/movie:thematrix:1999
curl -X POST localhost:8088/catalog/graphql -H 'Content-Type: application/json' \
  -d '{"query":"{ searchTitles(q:\"matrix\", first:5) { items { id name sources confidence } nextCursor } }"}'
bash ops/catalog-drill.sh all      # security, entity resolution, idempotency, GraphQL, poison records, stats, Mongo outage
bash ops/catalog-perf.sh           # rough read throughput + pod-kill test
```

## Measured (one desktop PC, all components share it)

| Drill | Result |
|---|---|
| Entity resolution | 15 records from 3 feeds -> 8 titles; Matrix/Breaking Bad merged from 3 feeds (confidence 100); Amélie/Amelie merged |
| Replay of the same 15 records | 0 document versions changed |
| 2 poison records | both on `metadata-raw.DLT` within seconds; next good record processed normally |
| Streams | per-source counts matched what was sent (studioA 12, tvguide 10, indexdb 8 after two seeds) |
| GraphQL | pagination across 2 pages; introspection blocked; 150-alias query rejected (cost 300 > 100) |
| Mongo down | stale copy served; unread titles 503 after ~1 s timeouts until the breaker opened (then ~10 ms); ingest still 202; consumer lag 0 -> 2, DLT unchanged; after recovery both records present, breaker closed |
| Kill one of two pods under 10 req/s | 0 of 250 requests failed |
| Read speed (curl clients, so client-limited) | REST cache hit p50 20 ms / p99 72 ms; GraphQL text search p50 39 ms / p99 102 ms |

## Limits to be upfront about

* **Mongo is a single node** (RAM). The service tolerates its outage (stale reads, buffered writes) but does not make Mongo itself highly available; a 3-member replica set is the next step.
* The breaker is **per pod** and needs about 5 failing calls to open, so each pod's first requests in an outage pay the 1 s Mongo timeout.
* Entity resolution is exact-match after normalisation, not fuzzy or ML-based.
* Text search covers name and description only (genres are not in the text index).
* The ingest API key is static: fine for a lab, a real feed gateway would use per-feed credentials and quotas.
* Load figures are rough (curl-based, shared machine); there is no JMeter suite for this service.
