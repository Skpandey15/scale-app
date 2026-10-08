#!/usr/bin/env bash
# Build the images, load them into k3d, and apply everything in dependency order. Safe to re-run.
# Works on a fresh k3d cluster:   k3d cluster create scale --servers 1 --agents 2 -p "8088:80@loadbalancer"
set -eu
K="kubectl -n scale"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CNPG_VERSION=1.30.1

docker build -q -t scale-backend:1.0 backend
docker build -q -t scale-web:1.0 frontend
docker build -q -t scale-catalog:1.0 catalog
k3d image import scale-backend:1.0 scale-web:1.0 scale-catalog:1.0 -c scale >/dev/null 2>&1

# Postgres operator (once). Pinned: its native Barman backup integration is removed in 1.31.
if ! kubectl get crd clusters.postgresql.cnpg.io >/dev/null 2>&1; then
  kubectl apply --server-side -f "https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v${CNPG_VERSION}/cnpg-${CNPG_VERSION}.yaml" >/dev/null
fi
kubectl -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout=300s

bash ops/gen-secrets.sh
kubectl apply -f k8s/05-traefik-ha.yaml -f k8s/00-infra.yaml -f k8s/01-kafka.yaml -f k8s/03-objectstore.yaml
kubectl apply -f k8s/02-postgres.yaml 2>&1 | grep -v -E "unchanged|Warning|deprecated|CloudNativePG|Barman" || true
$K rollout status sts/kafka --timeout=600s
$K wait --for=condition=Ready cluster/scale-pg --timeout=900s >/dev/null
kubectl apply -f k8s/10-app.yaml -f k8s/20-kafka-ui.yaml -f k8s/30-batch.yaml
kubectl apply -f k8s/40-mongo.yaml
$K rollout status sts/mongo --timeout=300s
kubectl apply -f k8s/50-catalog.yaml
$K rollout restart deploy/backend deploy/kafka-ui deploy/catalog >/dev/null    # pick up freshly imported images / new secrets
$K rollout status deploy/backend --timeout=600s
$K rollout status deploy/catalog --timeout=600s
kubectl -n kube-system rollout status deploy/traefik --timeout=180s
$K get pods -o wide --no-headers | awk '{print $1, $2, $3, $7}'
echo
echo "Ready:  http://localhost:8088        Kafka UI: http://localhost:8088/kafka-ui  (user: admin)"
