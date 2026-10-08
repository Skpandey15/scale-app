#!/usr/bin/env bash
# Copy Postgres backups + WAL out of the cluster to the host disk (default: D:\scale-app-offsite-backups).
# Run it on a schedule (e.g. Windows Task Scheduler: wsl -d Ubuntu-24.04 -- bash <this file>).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST=${1:-/mnt/d/scale-app-offsite-backups}
mkdir -p "$DEST"
kubectl -n scale port-forward svc/seaweedfs 8888:8888 >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null' EXIT
for i in $(seq 1 20); do curl -s -o /dev/null http://localhost:8888/ && break; sleep 1; done
python3 "$ROOT/ops/offsite-backup.py" "$DEST"
