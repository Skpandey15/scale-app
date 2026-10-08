# Performance & scalability report

Environment: desktop PC (Dell Inspiron 3910, i5-12400, 16 GB RAM), WSL2 (7.8 GB), k3d 1 server + 2 agents, JMeter 5.5 (3 CPUs / 1 GB heap) on the same machine. Numbers show mechanisms and relative scaling, not production capacity.

## 1. Client-side (JMeter, steady state after ramp-up)

| Phase | Users | Think (ms) | Throughput req/s | Errors % | p50 | p90 | p95 | p99 | max ms | Apdex(T=100ms, GETs) |
|---|---|---|---|---|---|---|---|---|---|---|
| ha-warm-300 | 300 | 200 | 833 | 0.00 | 4 | 19 | 33 | 79 | 259 | 0.999 |
| ha-stress-100 | 100 | 0 | 2669 | 0.00 | 30 | 69 | 89 | 149 | 435 | 0.991 |

### Scalability (throughput vs users)

| Phase | Users | req/s | Users x vs base | Throughput x vs base | Efficiency |
|---|---|---|---|---|---|
| ha-warm-300 | 300 | 833 | 1.0x | 1.00x | 100% |

Efficiency = throughput gain / user gain. 100% is linear scaling; a drop marks where the system stops scaling.

### Per-endpoint breakdown at the highest-throughput phase (ha-stress-100)

| Endpoint | req/s | p50 | p95 | p99 | max | Errors % |
|---|---|---|---|---|---|---|
| GET feed deep page | 667.3 | 35 | 87 | 124 | 240 | 0.00 |
| GET feed first page | 1868.3 | 27 | 74 | 109 | 231 | 0.00 |
| POST create post | 106.7 | 62 | 143 | 196 | 321 | 0.00 |
| POST login | 26.7 | 163 | 270 | 328 | 435 | 0.00 |

## 2. Server-side resource use per phase

| Phase | Backend CPU avg/peak (cores) | Replicas (max / HPA wants) | Backend mem/pod MiB | Node CPU peak % | Node mem peak % | Restarts | req/s per backend core | JMeter CPU peak % (300% = cap) |
|---|---|---|---|---|---|---|---|---|
| ha-warm-300 | 4.40 / 6.50 | 4 / 4 | 458 | 30 | 33 | 0 | 189 | 78 |
| ha-stress-100 | 4.98 / 6.31 | 4 / 4 | 486 | 34 | 35 | 0 | 536 | 71 |

## 3. JVM, connection pool and server-measured latency

| Phase | Server req/s | Server avg ms | Server max ms | Hikari pool peak util % | Hikari pending peak | Heap peak MiB | GC pause ms per second (worst pod) |
|---|---|---|---|---|---|---|---|
| ha-warm-300 | 814 | 4.1 | 399 | 30 | 0 | 89 | 3.9 |
| ha-stress-100 | 2325 | 22.4 | 434 | 100 | 3 | 131 | 16.5 |

## 4. Data tier: Postgres, Redis, Kafka, outbox

| Phase | PG txn/s | PG cache hit % | PG rows read/s | PG conns peak (active) | Deadlocks | Redis hit % | Redis ops/s peak | Redis evictions | Kafka lag peak | Outbox backlog peak |
|---|---|---|---|---|---|---|---|---|---|---|
| ha-warm-300 | 269 | 100.0 | 8835 | 18 (2) | 0 | 98.6 | 2428 | 0 | 0 | 17 |
| ha-stress-100 | 737 | 100.0 | 27061 | 40 (3) | 0 | 97.7 | 7406 | 0 | 14 | 43 |

## 5. Reading the results

- Peak sustained throughput: **2669 req/s** (ha-stress-100).
- First phase showing degradation (errors > 1% or p95 > 3x baseline and > 100 ms): **none in the tested range**.
- Phases with a node above 85% CPU (saturation): none.
- Note: JMeter shares the machine with the cluster, so the highest phases may be limited by the load generator and the desktop, not the application.
- `kubectl top` (metrics-server) has ~15-30 s resolution, so short CPU spikes are smoothed; counters (Postgres, Redis, JVM) are exact deltas.
