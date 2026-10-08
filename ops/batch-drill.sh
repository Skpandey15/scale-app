#!/usr/bin/env bash
# Batch drill: run the nightly rollup, kill it mid-way, prove it resumes from the checkpoint with correct totals.
set -u
K="kubectl -n scale"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/ops/lib.sh"

echo "== seed =="
if [ "$(psqlq 'select count(*) from posts')" -lt 100000 ]; then
  psqlx_i -q < "$ROOT/ops/seed.sql"
fi
echo "posts: $(psqlq 'select count(*) from posts')"
psqlx -qc "truncate daily_post_stats; delete from batch_checkpoint;"
$K delete job drill-stats drill-stats-rerun --ignore-not-found >/dev/null

echo "== run 1: failure injected after 5 chunks (50k rows); Job controller retries with a fresh pod =="
t0=$(date +%s)
$K create job drill-stats --from=cronjob/daily-stats --dry-run=client -o yaml \
  | $K set env --local -f - APP_BATCH_FAIL_ONCE_AFTER_CHUNKS=5 -o yaml | $K apply -f - >/dev/null
for i in $(seq 1 90); do
  ok=$($K get job drill-stats -o jsonpath='{.status.succeeded}' 2>/dev/null)
  [ "$ok" = "1" ] && break
  sleep 3
done
echo "job finished in $(( $(date +%s) - t0 ))s (incl. JVM startup x2)"
$K get pods -l job-name=drill-stats --no-headers
for p in $($K get pods -l job-name=drill-stats -o name --sort-by=.metadata.creationTimestamp); do
  echo "--- $p"; $K logs "$p" | grep -E 'daily-stats (start|DONE|FAILED)|injected' | sed -E 's/^.{24}//' | cut -c1-160
done

echo "== verify =="
CP=$(psqlq "select last_id from batch_checkpoint where job='daily-stats'")
echo "checkpoint            : $CP"
echo "posts with id<=cp     : $(psqlq "select count(*) from posts where id <= $CP")"
echo "sum(daily_post_stats) : $(psqlq 'select coalesce(sum(posts),0) from daily_post_stats')"

echo "== run 2: re-run on same data must be a no-op (idempotent) =="
$K create job drill-stats-rerun --from=cronjob/daily-stats >/dev/null
for i in $(seq 1 60); do
  [ "$($K get job drill-stats-rerun -o jsonpath='{.status.succeeded}' 2>/dev/null)" = "1" ] && break
  sleep 3
done
$K logs -l job-name=drill-stats-rerun | grep -E 'daily-stats (start|DONE)' | sed -E 's/^.{24}//' | cut -c1-160
echo "sum(daily_post_stats) after re-run: $(psqlq 'select coalesce(sum(posts),0) from daily_post_stats')"
