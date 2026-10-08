#!/usr/bin/env bash
# Shared helpers for the ops scripts. Postgres is now a CloudNativePG cluster: the primary can be any pod, so look it up.
K="kubectl -n scale"
pg_primary() { $K get pod -l cnpg.io/cluster=scale-pg,cnpg.io/instanceRole=primary -o name 2>/dev/null | head -n 1 | cut -d/ -f2; }
# psql as the postgres superuser on the current primary (local socket, no password). Extra args pass through to psql.
psqlx()   { $K exec "$(pg_primary)" -c postgres -- psql -U postgres -d app "$@"; }
psqlx_i() { $K exec -i "$(pg_primary)" -c postgres -- psql -U postgres -d app "$@"; }
psqlq()   { psqlx -tAc "$1" | tr -d '[:space:]'; }
