#!/usr/bin/env bash
# Creates the cluster secrets with random values. Idempotent: existing secrets are left untouched.
# Nothing sensitive is printed or stored in the repo.
set -eu
K="kubectl -n scale"
kubectl get ns scale >/dev/null 2>&1 || kubectl create ns scale >/dev/null
rand() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "$1"; }

if ! $K get secret app-secrets >/dev/null 2>&1; then
  $K create secret generic app-secrets --from-literal=JWT_SECRET="$(head -c 64 /dev/urandom | base64 | tr -d '\n')" >/dev/null
  echo "created app-secrets (random JWT signing key)"
fi

if ! $K get secret kafka-ui-auth >/dev/null 2>&1; then
  $K create secret generic kafka-ui-auth --from-literal=username=admin --from-literal=password="$(rand 24)" >/dev/null
  echo "created kafka-ui-auth (read the password with: kubectl -n scale get secret kafka-ui-auth -o jsonpath='{.data.password}' | base64 --decode)"
fi

if ! $K get secret catalog-secrets >/dev/null 2>&1; then
  $K create secret generic catalog-secrets \
    --from-literal=MONGO_ROOT_PASSWORD="$(rand 28)" \
    --from-literal=MONGO_APP_PASSWORD="$(rand 28)" \
    --from-literal=CATALOG_API_KEY="$(rand 40)" >/dev/null
  echo "created catalog-secrets (Mongo passwords + feed API key; read the key with: kubectl -n scale get secret catalog-secrets -o jsonpath='{.data.CATALOG_API_KEY}' | base64 --decode)"
fi

if ! $K get secret backup-s3 >/dev/null 2>&1; then
  AK="$(rand 20)"; SK="$(rand 40)"
  $K create secret generic backup-s3 --from-literal=ACCESS_KEY_ID="$AK" --from-literal=ACCESS_SECRET_KEY="$SK" >/dev/null
  cat > /tmp/s3.json <<EOF
{"identities":[{"name":"backup","credentials":[{"accessKey":"$AK","secretKey":"$SK"}],"actions":["Admin","Read","Write","List","Tagging"]}]}
EOF
  $K create secret generic seaweedfs-s3-config --from-file=s3.json=/tmp/s3.json >/dev/null
  rm -f /tmp/s3.json
  echo "created backup-s3 + seaweedfs-s3-config (object-store credentials)"
fi
