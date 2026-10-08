# Performance & scalability report

Environment: desktop PC (Dell Inspiron 3910, i5-12400, 16 GB RAM), WSL2 (7.8 GB), k3d 1 server + 2 agents, JMeter 5.5 (3 CPUs / 1 GB heap) on the same machine. Numbers show mechanisms and relative scaling, not production capacity.

## 1. Client-side (JMeter, steady state after ramp-up)

| Phase | Users | Think (ms) | Throughput req/s | Errors % | p50 | p90 | p95 | p99 | max ms | Apdex(T=100ms, GETs) |
|---|---|---|---|---|---|---|---|---|---|---|
| warm-300-pool10 | 300 | 200 | 799 | 0.00 | 7 | 51 | 82 | 293 | 1618 | 0.981 |
| stress-100-pool10 | 100 | 0 | 2881 | 0.00 | 28 | 62 | 78 | 128 | 399 | 0.994 |

### Scalability (throughput vs users)

| Phase | Users | req/s | Users x vs base | Throughput x vs base | Efficiency |
|---|---|---|---|---|---|
| warm-300-pool10 | 300 | 799 | 1.0x | 1.00x | 100% |

Efficiency = throughput gain / user gain. 100% is linear scaling; a drop marks where the system stops scaling.

### Per-endpoint breakdown at the highest-throughput phase (stress-100-pool10)

| Endpoint | req/s | p50 | p95 | p99 | max | Errors % |
|---|---|---|---|---|---|---|
| GET feed deep page | 720.3 | 26 | 68 | 100 | 209 | 0.00 |
| GET feed first page | 2016.3 | 28 | 74 | 108 | 233 | 0.00 |
| POST create post | 115.3 | 42 | 101 | 139 | 291 | 0.00 |
| POST login | 28.9 | 140 | 220 | 270 | 399 | 0.00 |

## 2. Server-side resource use per phase

| Phase | Backend CPU avg/peak (cores) | Replicas (max / HPA wants) | Backend mem/pod MiB | Node CPU peak % | Node mem peak % | Restarts | req/s per backend core | JMeter CPU peak % (300% = cap) |
|---|---|---|---|---|---|---|---|---|
| warm-300-pool10 | 6.83 / 9.26 | 6 / 6 | 382 | 33 | 28 | 0 | 117 | 45 |
| stress-100-pool10 | 5.55 / 7.38 | 6 / 6 | 451 | 28 | 30 | 0 | 519 | 78 |

## 3. JVM, connection pool and server-measured latency

| Phase | Server req/s | Server avg ms | Server max ms | Hikari pool peak util % | Hikari pending peak | Heap peak MiB | GC pause ms per second (worst pod) |
|---|---|---|---|---|---|---|---|
| warm-300-pool10 | 856 | 13.7 | 1612 | 20 | 0 | 93 | 11.7 |
| stress-100-pool10 | 2950 | 18.0 | 1612 | 60 | 0 | 94 | 20.6 |

## 4. Data tier: Postgres, Redis, Kafka, outbox

| Phase | PG txn/s | PG cache hit % | PG rows read/s | PG conns peak (active) | Deadlocks | Redis hit % | Redis ops/s peak | Redis evictions | Kafka lag peak | Outbox backlog peak |
|---|---|---|---|---|---|---|---|---|---|---|
| warm-300-pool10 | 299 | 100.0 | 140859 | 58 (3) | 0 | 93.2 | 1499 | 0 | 0 | 9 |
| stress-100-pool10 | 1164 | 100.0 | 43739 | 61 (4) | 0 | 87.0 | 5719 | 0 | 46 | 37 |

## 5. Reading the results

- Peak sustained throughput: **2881 req/s** (stress-100-pool10).
- First phase showing degradation (errors > 1% or p95 > 3x baseline and > 100 ms): **none in the tested range**.
- Phases with a node above 85% CPU (saturation): none.
- Note: JMeter shares the machine with the cluster, so the highest phases may be limited by the load generator and the desktop, not the application.
- `kubectl top` (metrics-server) has ~15-30 s resolution, so short CPU spikes are smoothed; counters (Postgres, Redis, JVM) are exact deltas.
