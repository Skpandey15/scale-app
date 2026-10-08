# Performance findings (JMeter suite, two identical runs)

Raw tables: `PERF_REPORT.md` (second run). Raw samples: `perf-raw/`. JMeter HTML dashboards: `jmeter-<phase>/report/index.html`.
Environment: one desktop PC (i5-12400: 6 cores / 12 threads, 16 GB RAM, WSL2 capped at 7.8 GB), k3d 1 server + 2 agents, JMeter on the same machine. Treat as relative scaling, not production capacity.

## Headline numbers (steady state)

| Metric | Result |
|---|---|
| Peak throughput | ~3,250 req/s (100 closed-loop users, no think time); run 1 gave 3,171 |
| Sustained mixed load | 1,410 req/s at 500 users with think time, 0 errors |
| Latency at 1,410 req/s | p50 2 ms, p95 6 ms, p99 61 ms |
| Latency at ~3,250 req/s | p50 25 ms, p95 67 ms, p99 115 ms |
| Errors | 0.00% in every phase, both runs |
| Scaling (50 -> 500 users) | 100% efficient: 10x users = 10.0x throughput |
| Apdex (T=100 ms, GETs) | 1.00 up to 500 users, 0.997 at peak |
| Postgres cache hit | 100% |
| Redis hit ratio | 96-98% normally, fell to 87.6% at peak writes |
| GC (Serial) | at most ~19 ms of pause per second (1.9%) |
| Heap per pod | peak ~90 MiB of a 640 MiB limit |
| Backend CPU per request | ~550 req/s per core at peak, ~80 at idle-ish load |
| Kafka lag / outbox backlog | lag peak 54, outbox peak 30 (both drained) |

## Where it bends

1. **Postgres connection slots are the first hard limit.** 6 pods x pool of 20 = 120 potential connections vs `max_connections=100`.
   Peak reading was 100 connections with only 3 active; afterwards even `psql` was refused ("too many clients already").
   Fix: Hikari pool 10 or less (3 were active), PgBouncer in transaction mode, and/or a higher `max_connections`.
2. **Autoscaler ceiling.** HPA wanted 5 replicas during the first step and 6 (its max) from 150 users on. Throughput kept scaling, but headroom beyond 6 pods is capped by configuration.
   Scale-out took roughly 1-2 minutes, so a sudden spike is served by existing pods first.
3. **Cache hit ratio drops with write rate.** Every post invalidates the first-page cache (outbox -> Kafka -> Redis delete), so at ~130 posts/s Redis hit rate fell to 87.6% and Postgres did 46k rows/s.
   Options: invalidate per page key, version the cache key, or accept 5 s staleness without invalidation.
4. **Login is the most expensive call** (p50 131 ms, p95 209 ms at peak) because of BCrypt. Rate-limit it separately and consider scaling auth independently.
5. **JVM ergonomics:** the backend runs the Serial GC because of the small container (640 MiB limit, 200m CPU request). It is fine here (<2% pause) but a larger container with G1 would behave differently.

## Fix applied and verified: connection pool 20 -> 10 per pod (min idle 5 -> 2)

| | Before (pool 20) | After (pool 10, warm pods) |
|---|---|---|
| Peak Postgres connections | 100 (at the limit; admin `psql` refused) | 61 |
| Hikari pending threads | 0 | 0 |
| Hikari peak utilisation | 35% (of 20) | 50% (of 10) |
| Stress throughput | 3,171 / 3,249 req/s (two runs) | 3,140 req/s |
| Stress p95 / p99 | 67 / 115 ms | 70 / 117 ms |
| Errors | 0% | 0% |

Throughput and latency are unchanged within run-to-run noise (~3%); the DB now keeps 40 free slots at 6 pods.
An earlier "cold" post-fix run measured 2,881 req/s, but that was freshly restarted pods with unwarmed JVMs while the autoscaler was still scaling out, so it is not comparable.
Reports: `PERF_REPORT_pool10.md` (cold), `PERF_REPORT_pool10_warm.md` (warm, the fair comparison).
Still open: if the HPA ceiling is raised above ~9 pods, or batch jobs and the relay add connections, put PgBouncer in front of Postgres.

## After the HA / efficiency changes (`PERF_REPORT_ha.md`, 4 backend pods because of RAM)

Changes under test: PgBouncer in front of Postgres, debounced cache invalidation, single-flight cache loads, G1 GC.
Throughput is not comparable (4 pods here vs 6 earlier; per-core efficiency was the same, ~536 vs ~514-546 req/s per core), so compare per-request cost:

| Zero-think stress phase | Before (6 pods) | After (4 pods) |
|---|---|---|
| Redis hit ratio | 85.8-87.6% | **97.7%** |
| Postgres rows read per request | ~16.6 | **~10.1** |
| Postgres transactions per request | ~0.43 | **~0.28** |
| Peak Postgres connections | 61 (after pool fix) / 100 (before) | **40** |
| GC pause, worst pod | ~20-22 ms/s (Serial) | ~16.5 ms/s (G1) |
| Errors | 0% | 0% |

Observation: with 100 zero-think users the Hikari pool (10 per pod) reaches 100% for a moment with up to 3 waiting threads. Realistic think-time load peaked at 30%.
Since PgBouncer now caps real DB connections, raising the pool to ~20 is safe if that load shape matters, but it was not measured, so it was left at 10.

## What was NOT the bottleneck

- JMeter: peak 88% of its 300% CPU cap, so the generator was not saturated.
- Memory: nodes ~30%, heap tiny, no restarts or OOMs.
- Postgres cache/IO: 100% buffer hits, 0 deadlocks.

## Probable limiting resource at peak (inferred, not directly measured)

Total CPU demand at peak is about 6 cores (backend) + ~2.6 (JMeter) + Postgres/Redis/Kafka on a 12-logical-CPU desktop that also runs Windows.
Host-level CPU was not sampled, so "the desktop CPU" is an inference from those figures.

## Caveats

- Both load generator and system under test share one machine.
- `kubectl top` is 15-30 s resolution; Hikari/heap are instantaneous gauges sampled every ~10 s, so true peaks are probably higher than shown. Counter-based metrics (Postgres, Redis, JVM GC, request counts) are exact deltas.
- Postgres sampling returned an empty reading a few times under peak load; those samples were skipped.
- The first run had two collector bugs (heap/GC parsing); the second run fixed them. Client-side numbers matched between runs within ~3%.
