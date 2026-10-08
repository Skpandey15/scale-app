# Performance & scalability report

Environment: laptop, WSL2 (7.8 GB), k3d 1 server + 2 agents, JMeter 5.5 (3 CPUs / 1 GB heap) on the same machine. Numbers show mechanisms and relative scaling, not production capacity.

## 1. Client-side (JMeter, steady state after ramp-up)

| Phase | Users | Think (ms) | Throughput req/s | Errors % | p50 | p90 | p95 | p99 | max ms | Apdex(T=100ms, GETs) |
|---|---|---|---|---|---|---|---|---|---|---|
| stress-100-pool10-warm | 100 | 0 | 3140 | 0.00 | 26 | 55 | 70 | 117 | 367 | 0.997 |

### Scalability (throughput vs users)

| Phase | Users | req/s | Users x vs base | Throughput x vs base | Efficiency |
|---|---|---|---|---|---|

Efficiency = throughput gain / user gain. 100% is linear scaling; a drop marks where the system stops scaling.

### Per-endpoint breakdown at the highest-throughput phase (stress-100-pool10-warm)

| Endpoint | req/s | p50 | p95 | p99 | max | Errors % |
|---|---|---|---|---|---|---|
| GET feed deep page | 785.0 | 24 | 62 | 89 | 174 | 0.00 |
| GET feed first page | 2198.0 | 26 | 66 | 94 | 210 | 0.00 |
| POST create post | 125.6 | 37 | 88 | 124 | 218 | 0.00 |
| POST login | 31.4 | 132 | 203 | 249 | 367 | 0.00 |

## 2. Server-side resource use per phase

| Phase | Backend CPU avg/peak (cores) | Replicas (max / HPA wants) | Backend mem/pod MiB | Node CPU peak % | Node mem peak % | Restarts | req/s per backend core | JMeter CPU peak % (300% = cap) |
|---|---|---|---|---|---|---|---|---|
| stress-100-pool10-warm | 6.11 / 6.78 | 6 / 6 | 464 | 26 | 30 | 0 | 514 | 83 |

## 3. JVM, connection pool and server-measured latency

| Phase | Server req/s | Server avg ms | Server max ms | Hikari pool peak util % | Hikari pending peak | Heap peak MiB | GC pause ms per second (worst pod) |
|---|---|---|---|---|---|---|---|
| stress-100-pool10-warm | 3225 | 16.9 | 324 | 50 | 0 | 98 | 22.2 |

## 4. Data tier: Postgres, Redis, Kafka, outbox

| Phase | PG txn/s | PG cache hit % | PG rows read/s | PG conns peak (active) | Deadlocks | Redis hit % | Redis ops/s peak | Redis evictions | Kafka lag peak | Outbox backlog peak |
|---|---|---|---|---|---|---|---|---|---|---|
| stress-100-pool10-warm | 1337 | 100.0 | 52155 | 61 (4) | 0 | 85.8 | 5785 | 0 | 25 | 61 |

## 5. Reading the results

- Peak sustained throughput: **3140 req/s** (stress-100-pool10-warm).
- First phase showing degradation (errors > 1% or p95 > 3x baseline and > 100 ms): **none in the tested range**.
- Phases with a node above 85% CPU (saturation): none.
- Note: JMeter shares the machine with the cluster, so the highest phases may be limited by the load generator and the laptop, not the application.
- `kubectl top` (metrics-server) has ~15-30 s resolution, so short CPU spikes are smoothed; counters (Postgres, Redis, JVM) are exact deltas.
