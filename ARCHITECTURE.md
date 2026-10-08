# Scale App: architecture, resilience and operations

A read-heavy microblog (React + Spring Boot) built to demonstrate scalability, availability and recoverability on a
local k3d cluster (1 server + 2 agents). Everything below was exercised by the drills in `ops/`; numbers are from one laptop.

## Request path
```
Browser -> Traefik (2 replicas) -> backend pods (3..10, stateless, JWT)
                                      |- Redis        hot feed page (5s TTL, single-flight), rate-limit counters
                                      |- PgBouncer x2 -> Postgres primary (+ streaming replica, auto-failover)
                                      '- Kafka x3      post-created events (transactional outbox), DLT
Batch:  CronJob daily-stats (same image, chunked + checkpointed)
Backup: continuous WAL + daily base backups -> object store (SeaweedFS) -> copied off-cluster to the host disk
```

## What each concern uses

| Concern | Mechanism |
|---|---|
| Horizontal scale | Stateless pods, HPA 3-10 (fast scale-up policy), PDBs, topology spread |
| Read performance | Cursor pagination, Redis first-page cache with single-flight on miss, debounced Kafka-driven invalidation |
| Write safety | Transactional outbox: post + event commit together, relay publishes with `acks=all` to RF=3 topics |
| Consumer failures | 3 retries then dead-letter topic `post-created.DLT` |
| DB availability | CloudNativePG: primary + replica, automatic failover, PgBouncer (transaction pooling) |
| DB recoverability | WAL archiving (archive_timeout 60s) + daily base backup, point-in-time recovery, off-cluster copy |
| Kafka availability | 3 KRaft brokers, RF 3, min ISR 2: one broker can die with no loss and no producer errors |
| Abuse protection | Sliding-window limiter (global per client), per-IP and per-ACCOUNT login limits, BCrypt bulkhead |
| Secrets | Generated at deploy time (`ops/gen-secrets.sh`), none in the repo; Kafka UI behind a login |
| Probes | Liveness/readiness groups exclude Redis/Kafka so a soft dependency outage cannot unready every pod |

## Measured behaviour (see `loadtest/`)

* Peak about 3,100-3,250 req/s on 6 backend pods, p95 about 70 ms, 0 errors; linear scaling from 50 to 500 users.
* Postgres primary crash: automatic failover, writes unavailable about 28 s (24 s promotion + reconnect), 0 acknowledged writes lost.
* One Kafka broker killed: 0 failed requests, 0 lost events. One PgBouncer pod killed: about 4 s of errors.
* Point-in-time recovery restored exactly to a chosen instant in about 40 s (tiny dataset).

## Known limits (be upfront about these)

* One laptop: three "nodes" share the same CPU, RAM and disk; the cluster's failure domain is the machine.
* Redis is a single instance **by design**: it is only a cache/limiter and the app fails open (verified).
* Postgres replication is asynchronous: a failover could lose the last few unreplicated commits (none lost in the drills).
* Backups: the off-cluster copy goes to a local disk, not another region; run `ops/offsite-backup.sh` on a schedule.
* CloudNativePG's native Barman backup integration is deprecated and removed in 1.31: stay on 1.30.x or migrate to the
  Barman Cloud plugin (needs cert-manager) before upgrading.
* In this k3d setup the ingress path hides the real client IP (the app sees rotating internal hop addresses), so per-IP limits
  are approximate here; the per-account login limit does not depend on IPs. Behind a cloud load balancer per-IP limits are exact.
* HPA max 10 is configuration only: this machine's RAM supports about 6 backend pods alongside the HA data tier.

## Operating it

```
bash ops/deploy.sh                 # build image, apply manifests in order (needs CNPG operator v1.30.1 installed once)
bash ops/ha-drill.sh [failover|pooler|kafka|pitr|all]
bash ops/chaos.sh                  # load + pod/node/Redis/Kafka/ingress failures
bash ops/dlq-replay-drill.sh       # outbox, dead-letter queue, replay
bash ops/batch-drill.sh            # restartable batch job
bash ops/offsite-backup.sh         # copy backups to D:\scale-app-offsite-backups
bash ops/perf-suite.sh && python3 ops/analyze.py /tmp/perf .   # JMeter scalability suite + server-side metrics
kubectl -n scale get secret kafka-ui-auth -o jsonpath='{.data.password}' | base64 -d   # Kafka UI password (user: admin)
```
