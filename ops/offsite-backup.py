#!/usr/bin/env python3
"""Mirror the pg-backups bucket (base backups + WAL) from the in-cluster object store to a host directory.

Why: the object store runs inside the same cluster as the database, so losing the cluster would lose the backups too.
This copies them out of the cluster to a host folder. Use a DIFFERENT physical drive (external or network) to survive a drive failure: a second partition of the same SSD does not. Incremental: files already present with the same size are skipped.

Usage: offsite-backup.py <dest dir> [filer url]   (needs `kubectl -n scale port-forward svc/seaweedfs 8888:8888`;
ops/offsite-backup.sh does that for you)
"""
import json
import os
import sys
import urllib.request

DEST = sys.argv[1]
BASE = sys.argv[2] if len(sys.argv) > 2 else "http://localhost:8888"
ROOT = "/buckets/pg-backups"


def listing(path):
    entries, last = [], ""
    while True:
        req = urllib.request.Request(f"{BASE}{path}/?limit=1000&lastFileName={last}",
                                     headers={"Accept": "application/json"})
        data = json.load(urllib.request.urlopen(req, timeout=30))
        batch = data.get("Entries") or []
        entries += batch
        if not data.get("ShouldDisplayLoadMore") or not batch:
            return entries
        last = batch[-1]["FullPath"].rsplit("/", 1)[-1]


def walk(path):
    for e in listing(path):
        if e.get("Mode", 0) & (1 << 31):  # directory bit
            yield from walk(e["FullPath"])
        else:
            yield e


copied = skipped = total = 0
for e in walk(ROOT):
    rel = e["FullPath"][len(ROOT) + 1:]
    dst = os.path.join(DEST, rel)
    size = e.get("FileSize") or 0
    total += size
    if os.path.exists(dst) and os.path.getsize(dst) == size:
        skipped += 1
        continue
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    tmp = dst + ".part"
    with urllib.request.urlopen(f"{BASE}{e['FullPath']}", timeout=60) as r, open(tmp, "wb") as f:
        f.write(r.read())
    os.replace(tmp, dst)
    copied += 1

print(f"offsite copy: {copied} new, {skipped} unchanged, {total / 1048576:.1f} MiB total in {DEST}")
