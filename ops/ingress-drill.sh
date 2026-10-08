#!/usr/bin/env bash
# Kill ONE ingress (Traefik) replica while probing; then (for contrast) kill ALL replicas.
set -u
BASE=${BASE:-http://localhost:8088}
KS="kubectl -n kube-system"
run() { # $1=label  $2=kill command
  ok=0; bad=0
  ( sleep 6; eval "$2" >/dev/null 2>&1 ) &
  end=$((SECONDS+30))
  while [ $SECONDS -lt $end ]; do
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$BASE/api/posts")
    if [ "$c" = "200" ]; then ok=$((ok+1)); else bad=$((bad+1)); fi
    sleep 0.2
  done
  wait
  echo "$1: ok=$ok failed=$bad"
}
$KS rollout status deploy/traefik --timeout=60s >/dev/null
run "kill 1 of 2 traefik replicas" "$KS delete pod \$($KS get pods -l app.kubernetes.io/name=traefik -o name | head -n 1 | cut -d/ -f2) --wait=false"
$KS rollout status deploy/traefik --timeout=90s >/dev/null; sleep 5
run "kill ALL traefik replicas   " "$KS delete pod -l app.kubernetes.io/name=traefik --wait=false"
$KS rollout status deploy/traefik --timeout=90s >/dev/null
