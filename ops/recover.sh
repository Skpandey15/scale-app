#!/usr/bin/env bash
# EMERGENCY start after an overload / run-away autoscaler / crash, when the saved desired state is too big for the RAM.
# (For a normal start use ops/lab-up.sh.)
#
# Lessons built in (found by testing this on a 16 GB PC):
#  * Everything before the shrink goes through `docker exec k3d-scale-server-0 kubectl`. The k3d load balancer crash-loops
#    while the worker containers are stopped, so the API is NOT reachable from outside until the workers are up.
#  * The server node itself runs about a third of the pods, so "control plane only" is not workload-free: shrink FAST.
#  * Pods on a node that is NotReady for 5 minutes are evicted onto the remaining nodes: do not keep the workers down for long.
#
#   bash ops/recover.sh
set -u
CLUSTER=scale
SRV="k3d-$CLUSTER-server-0"
AG0="k3d-$CLUSTER-agent-0"; AG1="k3d-$CLUSTER-agent-1"; LB="k3d-$CLUSTER-serverlb"
KS="docker exec $SRV kubectl --request-timeout=20s -n scale"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

docker info >/dev/null 2>&1 || { echo "Docker is not running. On Windows use setup\\lab-start.ps1 (it starts Docker first)."; exit 1; }

echo "== 1. hold the workers back; start only the server (the load balancer is parked until the workers exist)"
docker update --restart=no "$AG0" "$AG1" >/dev/null 2>&1 || true
docker stop "$AG0" "$AG1" "$LB" >/dev/null 2>&1 || true
docker start "$SRV" >/dev/null

echo "== 2. wait for the API inside the server container (up to 3 min)"
for i in $(seq 1 90); do
  if docker exec "$SRV" kubectl --request-timeout=10s get ns scale -o name >/dev/null 2>&1; then echo "   API answers"; break; fi
  [ "$i" = 90 ] && { echo "API did not answer. Try: wsl --shutdown, then run setup\\lab-start.ps1 again."; exit 1; }
  sleep 2
done

echo "== 3. shrink the workloads immediately"
$KS delete hpa backend --ignore-not-found
$KS scale deploy/backend --replicas=3
$KS scale deploy/catalog --replicas=2
$KS scale deploy/kafka-ui --replicas=0
$KS set env deploy/backend MALLOC_ARENA_MAX- JAVA_TOOL_OPTIONS=-XX:+UseG1GC >/dev/null 2>&1 || true

echo "== 4. start the workers (retry if one exits) and the load balancer"
for attempt in 1 2 3; do
  docker start "$AG0" "$AG1" >/dev/null 2>&1
  sleep 15
  up=$(docker ps --format '{{.Names}}' | grep -c -E "^($AG0|$AG1)$")
  [ "$up" = 2 ] && break
  echo "   a worker exited, retrying ($attempt/3)"
done
docker start "$LB" >/dev/null 2>&1
for i in $(seq 1 60); do
  ready=$(docker exec "$SRV" kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready')
  [ "${ready:-0}" -ge 3 ] && { echo "   3/3 nodes Ready"; break; }
  sleep 5
done
docker restart "$LB" >/dev/null 2>&1       # now that the workers resolve, nginx starts cleanly
for i in $(seq 1 30); do kubectl --request-timeout=10s get ns scale -o name >/dev/null 2>&1 && { echo "   API reachable from the host again"; break; }; sleep 3; done

echo "== 5. wait for the workloads, then recreate the autoscaler with the safe maximum from the manifest"
K="kubectl -n scale"
$K wait --for=condition=Ready cluster/scale-pg --timeout=600s >/dev/null 2>&1 || echo "   (Postgres cluster not ready yet; give it a few minutes)"
$K rollout status deploy/backend --timeout=600s 2>&1 | tail -n 1
kubectl apply -f "$ROOT/k8s/10-app.yaml" 2>&1 | grep -i -E "autoscaler|error" || true

echo "== 6. remove test users left by load/experiment scripts"
source "$ROOT/ops/lib.sh"
if [ -n "$(pg_primary)" ]; then
  psqlx -q -c "delete from outbox where msg_key like any (array['warm%','probe%','ha%','jm%','seed%','smoke%']);
               delete from posts where user_id in (select id from users where username like any (array['warm%','probe%','ha%','jm%','seed%','smoke%']));
               delete from users where username like any (array['warm%','probe%','ha%','jm%','seed%','smoke%']);" 2>/dev/null || true
fi

echo "== status"
$K get pods --no-headers | awk '{print $1, $2, $3}' | grep -v Completed
free -m | awk 'NR==2{printf "WSL memory: used %d MB, available %d MB\n",$3,$7}'
echo "Kafka UI is paused to save memory; start it with: kubectl -n scale scale deploy/kafka-ui --replicas=1"
