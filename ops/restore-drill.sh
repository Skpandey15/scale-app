#!/usr/bin/env bash
# Recoverability drill: (A) Postgres pod crash -> RTO, (B) backup + restore into a scratch pod -> RTO/RPO.
set -u
K="kubectl -n scale"
BASE=${BASE:-http://localhost:8088}
psqlq() { $K exec postgres-0 -- psql -U app -d app -tAc "$1" | tr -d '[:space:]'; }
now() { date +%s.%N; }

if [ "${SKIP_A:-0}" != "1" ]; then
echo "== A. Postgres pod crash (data on PVC) =="
U="rd$RANDOM"; PW="pw-$RANDOM-$RANDOM-xxxxxxxx"
TOKEN=$(curl -s -X POST "$BASE/api/auth/register" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$U\",\"password\":\"$PW\"}" | sed -E 's/.*"token":"([^"]+)".*/\1/')
BEFORE=$(psqlq "select count(*) from posts")
t0=$(now); $K delete pod postgres-0 --wait=false >/dev/null
first_fail=""; recovered=""
for i in $(seq 1 240); do
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 -X POST "$BASE/api/posts" \
      -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" -d '{"content":"rto probe"}')
  if [ "$c" != "200" ] && [ -z "$first_fail" ]; then first_fail=$(now); fi
  if [ "$c" = "200" ] && [ -n "$first_fail" ]; then recovered=$(now); break; fi
  sleep 0.5
done
if [ -n "$recovered" ]; then
  echo "write outage: $(echo "$recovered $first_fail" | awk '{printf "%.1f", $1-$2}')s (first failed write -> first successful write)"
else
  echo "write path did not recover within 120s"
fi
$K wait --for=condition=Ready pod/postgres-0 --timeout=120s >/dev/null
AFTER=$(psqlq "select count(*) from posts")
echo "posts before crash: $BEFORE, after: $AFTER (RPO for pod crash: committed rows survive on the PVC)"
fi

echo "== B. Backup job + restore into scratch pod =="
J="backup-drill-$RANDOM"
b0=$(now); $K create job "$J" --from=cronjob/pg-backup >/dev/null
$K wait --for=condition=complete "job/$J" --timeout=180s >/dev/null
echo "backup took $(echo "$(now) $b0" | awk '{printf "%.1f", $1-$2}')s: $($K logs job/$J | tail -n 1)"
SRC_USERS=$(psqlq "select count(*) from users"); SRC_POSTS=$(psqlq "select count(*) from posts")

$K delete pod pg-restore-test --ignore-not-found >/dev/null
cat <<'EOF' | $K apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: pg-restore-test, namespace: scale }
spec:
  restartPolicy: Never
  containers:
    - name: pg
      image: postgres:16
      env: [{ name: POSTGRES_PASSWORD, value: restore }]
      volumeMounts:
        - { name: backup, mountPath: /backup, readOnly: true }
  volumes:
    - { name: backup, persistentVolumeClaim: { claimName: pg-backups, readOnly: true } }
EOF
r0=$(now)
$K wait --for=condition=Ready pod/pg-restore-test --timeout=120s >/dev/null
for i in $(seq 1 30); do $K exec pg-restore-test -- pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
$K exec pg-restore-test -- sh -c 'createdb -U postgres app && pg_restore --no-owner --no-privileges --exit-on-error -U postgres -d app "$(ls -t /backup/app-*.dump | head -n 1)" && echo "pg_restore: clean (exit 0)"' 2>&1 | tail -n 3
echo "restore into fresh instance took $(echo "$(now) $r0" | awk '{printf "%.1f", $1-$2}')s (RTO for this data size)"
RS_USERS=$($K exec pg-restore-test -- psql -U postgres -d app -tAc "select count(*) from users" | tr -d '[:space:]')
RS_POSTS=$($K exec pg-restore-test -- psql -U postgres -d app -tAc "select count(*) from posts" | tr -d '[:space:]')
echo "source  users=$SRC_USERS posts=$SRC_POSTS"
echo "restore users=$RS_USERS posts=$RS_POSTS"
$K delete pod pg-restore-test --wait=false >/dev/null
$K delete job "$J" --wait=false >/dev/null
