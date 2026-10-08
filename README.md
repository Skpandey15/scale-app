# Scale App

A read-heavy microblog (React + Spring Boot 3 / Java 21) built to practise and demonstrate **scalability, availability and
recoverability** on a local Kubernetes cluster (k3d: 1 server + 2 agents). Highlights: stateless API with JWT, Redis cache
(single-flight, debounced invalidation), transactional outbox to a 3-broker Kafka, HA Postgres (CloudNativePG + PgBouncer,
point-in-time recovery), sliding-window rate limiting, a restartable batch job, and a set of failure/load drills.

* Architecture, measured behaviour and honest limits: [ARCHITECTURE.md](ARCHITECTURE.md)
* Load-test results: [loadtest/PERF_FINDINGS.md](loadtest/PERF_FINDINGS.md) (tables in `loadtest/PERF_REPORT*.md`)

## Quick start on macOS

You need roughly **8 GB of RAM given to Docker** (10 GB is comfortable) and 4+ CPUs; the full stack runs ~15 pods.

```bash
brew install k3d kubectl                       # plus Docker Desktop, or:  brew install colima docker && colima start --cpu 4 --memory 10
git clone <this repo> && cd scale-app
k3d cluster create scale --servers 1 --agents 2 -p "8088:80@loadbalancer"
bash ops/deploy.sh                             # builds images, installs the Postgres operator, deploys everything (first run: 10-15 min)
open http://localhost:8088
```

* App: http://localhost:8088  (register, post, scroll the feed)
* Kafka UI: http://localhost:8088/kafka-ui  (user `admin`; password: `kubectl -n scale get secret kafka-ui-auth -o jsonpath='{.data.password}' | base64 --decode`)
* Tear down: `k3d cluster delete scale`

Secrets (JWT key, Kafka UI password, object-store keys) are generated randomly at deploy time by `ops/gen-secrets.sh`; none are in the repo.

## Try it

```bash
bash ops/ha-drill.sh all          # crash Postgres primary / PgBouncer / a Kafka broker, then point-in-time recovery
bash ops/dlq-replay-drill.sh      # outbox, dead-letter queue, replay
bash ops/batch-drill.sh           # restartable batch job (CronJob) with an injected failure
bash ops/chaos.sh                 # load + pod/node/Redis/Kafka/ingress failures (needs the k6 image)
bash ops/perf-suite.sh && python3 ops/analyze.py /tmp/perf .      # JMeter scalability suite with server-side metrics
bash ops/offsite-backup.sh [dir]  # copy Postgres backups + WAL out of the cluster
```

## Layout

| Path | What |
|---|---|
| `backend/` | Spring Boot API, Flyway migrations, outbox relay, batch job |
| `frontend/` | React (Vite) UI served by nginx |
| `k8s/` | Manifests, applied in order by `ops/deploy.sh` (Traefik HA, Redis, Kafka, object store, Postgres, app, Kafka UI, batch) |
| `ops/` | Deploy, drills, metric collection and analysis scripts |
| `loadtest/` | JMeter plan (`scale.jmx`), k6 script, reports and raw metric samples |
| `docker-compose.yml` | Legacy single-node dev stack (no Kafka/HA): use `k8s/` instead |

## Notes and caveats

* Developed and tested on Windows 11 + WSL2 (Linux). **The macOS path above has not been run** by the author; expect to fix small things.
* The drill scripts use GNU tools (`date +%N`, GNU `sed`/`awk`). On macOS: `brew install coreutils gawk gnu-sed` and put their `gnubin` first on `PATH`.
* The JMeter image (`justb4/jmeter`) is amd64-only, so it runs emulated on Apple Silicon: use fewer threads (`-Jthreads=...`).
* All "nodes" share one machine, so numbers show relative behaviour, not production capacity.
* CloudNativePG is pinned to 1.30.1: its native Barman backup integration is removed in 1.31 (migrate to the Barman Cloud plugin first).
* In this local setup the ingress hides the real client IP, so per-IP rate limits are approximate; per-account login limits are exact.
