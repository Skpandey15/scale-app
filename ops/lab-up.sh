#!/usr/bin/env bash
# Normal start of the lab (the saved state is normal-sized: setup\lab-stop.ps1 makes sure of that).
# If the saved state was oversized after a crash or overload, use ops/recover.sh instead.
#
# Why nodes are started one at a time, in a fixed order (found by testing on this PC):
#  * `k3d cluster start` starts both workers at once. Docker can then hand out their IP addresses in a different order than
#    before, and the worker with the "wrong" IP shuts itself down cleanly: "failed to find interface with specified node ip".
#  * The k3d load balancer (nginx) crash-loops while a worker it points at is down, which makes the API unreachable from
#    the host. So: server first, then worker 0, then worker 1, then the load balancer.
#
#   bash ops/lab-up.sh
set -u
SRV=k3d-scale-server-0; AG0=k3d-scale-agent-0; AG1=k3d-scale-agent-1; LB=k3d-scale-serverlb
K="kubectl -n scale"

running()    { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }
node_ready() { docker exec "$SRV" kubectl get node "$1" --no-headers 2>/dev/null | grep -q ' Ready'; }

docker info >/dev/null 2>&1 || { echo "Docker is not running. On Windows use setup\\lab-start.ps1 (it starts Docker first)."; exit 1; }

# Only the server comes up with the Docker daemon; this script starts everything else, in order.
docker update --restart=no "$AG0" "$AG1" "$LB" >/dev/null 2>&1 || true

echo "== 1. server node"
docker start "$SRV" >/dev/null 2>&1 || true
for i in $(seq 1 60); do
  docker exec "$SRV" kubectl --request-timeout=10s get ns scale -o name >/dev/null 2>&1 && { echo "   API answers"; break; }
  [ "$i" = 60 ] && { echo "   API did not answer in 2 min"; exit 1; }
  sleep 2
done

echo "== 2. workers, one at a time"
for ag in "$AG0" "$AG1"; do
  ok=0
  for attempt in 1 2 3; do
    running "$ag" || docker start "$ag" >/dev/null 2>&1
    for i in $(seq 1 25); do
      if running "$ag" && node_ready "$ag"; then ok=1; break; fi
      running "$ag" || break                 # it exited: retry the start
      sleep 3
    done
    [ "$ok" = 1 ] && { echo "   $ag Ready"; break; }
    echo "   $ag did not come up (attempt $attempt/3), retrying"
    docker stop "$ag" >/dev/null 2>&1 || true
  done
  [ "$ok" = 1 ] || { echo "   $ag could not be started; see: docker logs $ag"; exit 1; }
done

echo "== 3. load balancer (API port on the host)"
docker restart "$LB" >/dev/null 2>&1 || docker start "$LB" >/dev/null 2>&1
for i in $(seq 1 40); do
  kubectl --request-timeout=10s get ns scale -o name >/dev/null 2>&1 && { echo "   API reachable from the host"; break; }
  [ "$i" = 40 ] && { echo "   API not reachable from the host; try: docker restart $LB"; exit 1; }
  sleep 3
done

echo "== 4. wait for the workloads (up to 8 min)"
$K wait --for=condition=Ready cluster/scale-pg --timeout=480s >/dev/null 2>&1 || echo "   (Postgres cluster not ready yet)"
for d in backend catalog web redis; do
  $K rollout status "deploy/$d" --timeout=240s 2>&1 | tail -n 1
done

echo "== status"
$K get pods --no-headers | awk '{print $1, $2, $3}' | grep -v Completed
free -m | awk 'NR==2{printf "WSL memory: used %d MB, available %d MB\n",$3,$7}'
