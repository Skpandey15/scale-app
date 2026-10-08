#!/usr/bin/env bash
# Safe cold start after a reboot or an overload (too many pods for the RAM).
# Order matters: control plane first, shrink the workloads while there is almost nothing running, THEN start the workers.
# Otherwise every pod starts at once, memory runs out, the machine swaps, and even `kubectl` stops answering.
#
#   bash ops/recover.sh
set -u
CLUSTER=scale
K="kubectl -n scale"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== 1. stop the worker nodes (frees their memory at once) and start only the control plane"
docker stop "k3d-$CLUSTER-agent-0" "k3d-$CLUSTER-agent-1" >/dev/null 2>&1 || true
docker start "k3d-$CLUSTER-server-0" "k3d-$CLUSTER-serverlb" >/dev/null

echo "== 2. wait for the Kubernetes API (up to 5 min)"
for i in $(seq 1 60); do
  if timeout 15 kubectl get --raw=/readyz >/dev/null 2>&1; then echo "   API is up"; break; fi
  [ "$i" = 60 ] && { echo "API did not come up. Try: wsl --shutdown, then run this again."; exit 1; }
  sleep 5
done

echo "== 3. shrink the workloads to a size that fits in RAM (while no workers are running)"
kubectl --request-timeout=60s -n scale delete hpa backend --ignore-not-found
$K scale deploy/backend --replicas=3
$K scale deploy/catalog --replicas=2
$K scale deploy/kafka-ui --replicas=0
# undo any leftover JVM experiment settings; the manifest is the source of truth
$K set env deploy/backend MALLOC_ARENA_MAX- JAVA_TOOL_OPTIONS=-XX:+UseG1GC >/dev/null 2>&1 || true

echo "== 4. start the workers and wait for the cluster"
docker start "k3d-$CLUSTER-agent-0" "k3d-$CLUSTER-agent-1" >/dev/null
for i in $(seq 1 60); do
  ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready')
  [ "${ready:-0}" -ge 3 ] && { echo "   3/3 nodes Ready"; break; }
  sleep 5
done
$K wait --for=condition=Ready cluster/scale-pg --timeout=600s >/dev/null 2>&1 || echo "   (Postgres cluster not ready yet; give it a few minutes)"
$K rollout status deploy/backend --timeout=600s || true

echo "== 5. recreate the autoscaler with the safe maximum from the manifest"
kubectl apply -f "$ROOT/k8s/10-app.yaml" 2>&1 | grep -i -E "autoscaler|error" || true

echo "== 6. remove test users left by the load/experiment scripts"
source "$ROOT/ops/lib.sh"
if [ -n "$(pg_primary)" ]; then
  psqlx -q -c "delete from outbox where msg_key like any (array['warm%','probe%','ha%','jm%','seed%','smoke%']);
               delete from posts where user_id in (select id from users where username like any (array['warm%','probe%','ha%','jm%','seed%','smoke%']));
               delete from users where username like any (array['warm%','probe%','ha%','jm%','seed%','smoke%']);" 2>/dev/null || true
fi

echo "== status"
$K get pods --no-headers | awk '{print $1, $2, $3}' | grep -v Completed
free -m | sed -n 2p | awk '{print "WSL memory: used "$3" MB, available "$7" MB"}'
echo "Kafka UI is paused to save memory; start it with: kubectl -n scale scale deploy/kafka-ui --replicas=1"
