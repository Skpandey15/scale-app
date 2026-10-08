# Performance & scalability report

Environment: desktop PC (Dell Inspiron 3910, i5-12400, 16 GB RAM), WSL2 (7.8 GB), k3d 1 server + 2 agents, JMeter 5.5 (3 CPUs / 1 GB heap) on the same machine. Numbers show mechanisms and relative scaling, not production capacity.

## 1. Client-side (JMeter, steady state after ramp-up)

| Phase | Users | Think (ms) | Throughput req/s | Errors % | p50 | p90 | p95 | p99 | max ms | Apdex(T=100ms, GETs) |
|---|---|---|---|---|---|---|---|---|---|---|
| step-50 | 50 | 200 | 141 | 0.00 | 4 | 9 | 12 | 62 | 289 | 1.000 |
| step-150 | 150 | 200 | 422 | 0.00 | 3 | 8 | 10 | 63 | 205 | 1.000 |
| step-300 | 300 | 200 | 846 | 0.00 | 3 | 6 | 7 | 29 | 99 | 1.000 |
| step-500 | 500 | 200 | 1410 | 0.00 | 2 | 5 | 6 | 61 | 96 | 1.000 |
| stress-100 | 100 | 0 | 3249 | 0.00 | 25 | 54 | 67 | 115 | 347 | 0.997 |

### Scalability (throughput vs users)

| Phase | Users | req/s | Users x vs base | Throughput x vs base | Efficiency |
|---|---|---|---|---|---|
| step-50 | 50 | 141 | 1.0x | 1.00x | 100% |
| step-150 | 150 | 422 | 3.0x | 3.00x | 100% |
| step-300 | 300 | 846 | 6.0x | 6.01x | 100% |
| step-500 | 500 | 1410 | 10.0x | 10.02x | 100% |

Efficiency = throughput gain / user gain. 100% is linear scaling; a drop marks where the system stops scaling.

### Per-endpoint breakdown at the highest-throughput phase (stress-100)

| Endpoint | req/s | p50 | p95 | p99 | max | Errors % |
|---|---|---|---|---|---|---|
| GET feed deep page | 812.3 | 23 | 60 | 86 | 209 | 0.00 |
| GET feed first page | 2274.5 | 25 | 64 | 92 | 233 | 0.00 |
| POST create post | 130.0 | 35 | 84 | 123 | 222 | 0.00 |
| POST login | 32.5 | 131 | 209 | 257 | 347 | 0.00 |

## 2. Server-side resource use per phase

| Phase | Backend CPU avg/peak (cores) | Replicas (max / HPA wants) | Backend mem/pod MiB | Node CPU peak % | Node mem peak % | Restarts | req/s per backend core | JMeter CPU peak % (300% = cap) |
|---|---|---|---|---|---|---|---|---|
| step-50 | 1.73 / 5.03 | 5 / 5 | 434 | 30 | 25 | 0 | 81 | 36 |
| step-150 | 1.78 / 2.23 | 6 / 6 | 431 | 11 | 31 | 0 | 237 | 41 |
| step-300 | 2.15 / 2.62 | 6 / 6 | 442 | 12 | 30 | 0 | 393 | 31 |
| step-500 | 3.13 / 3.48 | 6 / 6 | 446 | 16 | 30 | 0 | 451 | 57 |
| stress-100 | 5.95 / 6.70 | 6 / 6 | 454 | 26 | 31 | 0 | 546 | 88 |

## 3. JVM, connection pool and server-measured latency

| Phase | Server req/s | Server avg ms | Server max ms | Hikari pool peak util % | Hikari pending peak | Heap peak MiB | GC pause ms per second (worst pod) |
|---|---|---|---|---|---|---|---|
| step-50 | 151 | 4.0 | 288 | 0 | 0 | 79 | 6.2 |
| step-150 | 411 | 3.4 | 551 | 0 | 0 | 84 | 4.1 |
| step-300 | 846 | 2.5 | 551 | 5 | 0 | 83 | 1.9 |
| step-500 | 1305 | 2.4 | 101 | 5 | 0 | 83 | 2.4 |
| stress-100 | 2777 | 16.5 | 327 | 35 | 0 | 89 | 18.8 |

## 4. Data tier: Postgres, Redis, Kafka, outbox

| Phase | PG txn/s | PG cache hit % | PG rows read/s | PG conns peak (active) | Deadlocks | Redis hit % | Redis ops/s peak | Redis evictions | Kafka lag peak | Outbox backlog peak |
|---|---|---|---|---|---|---|---|---|---|---|
| step-50 | 58 | 100.0 | 2760 | 59 (1) | 0 | 96.4 | 265 | 0 | 2 | 3 |
| step-150 | 147 | 100.0 | 6540 | 71 (2) | 0 | 97.6 | 753 | 0 | 0 | 6 |
| step-300 | 281 | 100.0 | 12083 | 45 (1) | 0 | 98.3 | 1494 | 0 | 0 | 12 |
| step-500 | 432 | 100.0 | 18962 | 52 (2) | 0 | 98.0 | 2483 | 0 | 0 | 30 |
| stress-100 | 1255 | 100.0 | 46468 | 100 (3) | 0 | 87.6 | 5744 | 0 | 54 | 0 |

## 5. Reading the results

- Peak sustained throughput: **3249 req/s** (stress-100).
- First phase showing degradation (errors > 1% or p95 > 3x baseline and > 100 ms): **none in the tested range**.
- Phases with a node above 85% CPU (saturation): none.
- Note: JMeter shares the machine with the cluster, so the highest phases may be limited by the load generator and the desktop, not the application.
- `kubectl top` (metrics-server) has ~15-30 s resolution, so short CPU spikes are smoothed; counters (Postgres, Redis, JVM) are exact deltas.
