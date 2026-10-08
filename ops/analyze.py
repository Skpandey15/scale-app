#!/usr/bin/env python3
"""Combine JMeter results (client view) with sampled cluster/JVM/DB/cache/Kafka metrics (server view).
Usage: analyze.py <perf dir with samples.txt, phases.*> <scale-app dir>   -> prints markdown, writes loadtest/PERF_REPORT.md
"""
import csv, math, os, sys

OUT, ROOT = sys.argv[1], sys.argv[2]
APDEX_T = 100  # ms


def pct(sorted_vals, q):
    if not sorted_vals:
        return 0
    return sorted_vals[min(len(sorted_vals) - 1, max(0, math.ceil(q * len(sorted_vals)) - 1))]


# ---------- phases ----------
conf = {}
for line in open(os.path.join(OUT, "phases.conf")):
    n, th, ramp, dur, think = line.split()
    conf[n] = dict(threads=int(th), ramp=int(ramp), dur=int(dur), think=int(think))
win = {}
for line in open(os.path.join(OUT, "phases.log")):
    ts, name, kind = line.split()
    win.setdefault(name, {})[kind] = int(ts)
order = [n for n in conf if n in win and "end" in win[n]]

# ---------- client side (JMeter) ----------
client = {}
for n in order:
    path = os.path.join(ROOT, "loadtest", f"jmeter-{n}", "results.jtl")
    rows = []
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            if r["label"].startswith("seed:"):
                continue
            rows.append((int(r["timeStamp"]) / 1000.0, int(r["elapsed"]), r["label"], r["success"] == "true"))
    if not rows:
        continue
    t0 = min(r[0] for r in rows)
    steady = [r for r in rows if r[0] >= t0 + conf[n]["ramp"]]
    client[n] = dict(all=rows, steady=steady or rows, t0=t0)


def stats(rows):
    if not rows:
        return None
    lat = sorted(r[1] for r in rows)
    span = max(r[0] for r in rows) - min(r[0] for r in rows) or 1
    err = sum(1 for r in rows if not r[3])
    return dict(n=len(rows), rps=len(rows) / span, err=100.0 * err / len(rows), p50=pct(lat, .5), p90=pct(lat, .9),
                p95=pct(lat, .95), p99=pct(lat, .99), mx=lat[-1], avg=sum(lat) / len(lat))


def apdex(rows):
    g = [r for r in rows if r[2].startswith("GET")]
    if not g:
        return float("nan")
    s = sum(1 for r in g if r[3] and r[1] <= APDEX_T)
    t = sum(1 for r in g if r[3] and APDEX_T < r[1] <= 4 * APDEX_T)
    return (s + t / 2) / len(g)


# ---------- server side (samples) ----------
samples = []
cur = None
for line in open(os.path.join(OUT, "samples.txt")):
    line = line.rstrip("\n")
    if line.startswith("@ "):
        _, ts, phase = line.split(" ", 2)
        cur = dict(ts=int(ts), phase=phase, top={}, node={}, be={}, pg=None, redis={}, hpa=None,
                   restarts=0, outbox=None, lag=None)
        samples.append(cur)
        continue
    if cur is None or not line.strip():
        continue
    p = line.split()
    k = p[0]
    try:
        if k == "top" and len(p) >= 4:
            cpu = p[2]
            cpu_m = float(cpu[:-1]) if cpu.endswith("m") else float(cpu) * 1000
            cur["top"][p[1]] = (cpu_m, float(p[3].rstrip("Mi")))
        elif k == "node" and len(p) >= 4:
            cur["node"][p[1]] = (float(p[2].rstrip("%")), float(p[3].rstrip("%")))
        elif k == "hpa" and len(p) >= 3:
            cur["hpa"] = (int(p[1]), int(p[2]))
        elif k == "restarts":
            cur["restarts"] = int(p[1])
        elif k == "pg" and len(p) >= 11:
            cur["pg"] = [float(x) for x in p[1:11]]
        elif k == "outbox" and len(p) >= 2:
            cur["outbox"] = int(p[1])
        elif k == "redis":
            cur["redis"] = {kv.split("=")[0]: float(kv.split("=")[1]) for kv in p[1:] if "=" in kv}
        elif k == "be" and len(p) >= 3:
            cur["be"][p[1]] = {kv.split("=")[0]: float(kv.split("=")[1]) for kv in p[2:] if "=" in kv}
        elif k == "gen" and len(p) >= 4:
            cur.setdefault("gen", []).append(float(p[2].rstrip("%")))
        elif k == "lag" and len(p) >= 2:
            cur["lag"] = int(p[1])
    except ValueError:
        pass


def window(n):
    s = win[n]["start"] + conf[n]["ramp"]
    e = win[n]["end"]
    return [x for x in samples if s <= x["ts"] <= e]


def server(n):
    w = window(n)
    if len(w) < 2:
        return None
    d = {}
    dt = w[-1]["ts"] - w[0]["ts"] or 1
    be_cpu = [sum(v[0] for k, v in x["top"].items() if k.startswith("backend-")) for x in w]
    be_pods = [[v for k, v in x["top"].items() if k.startswith("backend-")] for x in w]
    d["be_cpu_avg"] = sum(be_cpu) / len(be_cpu)
    d["be_cpu_max"] = max(be_cpu)
    d["be_mem_avg"] = sum(sum(v[1] for v in ps) / len(ps) for ps in be_pods if ps) / max(1, sum(1 for ps in be_pods if ps))
    d["replicas_max"] = max((x["hpa"][0] for x in w if x["hpa"]), default=0)
    d["replicas_des"] = max((x["hpa"][1] for x in w if x["hpa"]), default=0)
    d["node_cpu_max"] = max((v[0] for x in w for v in x["node"].values()), default=0)
    d["node_mem_max"] = max((v[1] for x in w for v in x["node"].values()), default=0)
    d["restarts"] = w[-1]["restarts"] - w[0]["restarts"]
    pgx = [x for x in w if x["pg"]]
    if len(pgx) < 2:  # sampler occasionally returns nothing under heavy load: widen to the whole phase
        pgx = [x for x in samples if win[n]["start"] <= x["ts"] <= win[n]["end"] and x["pg"]]
    pgs = [x["pg"] for x in pgx]
    if len(pgs) >= 2:
        a, b = pgs[0], pgs[-1]
        tdb = (pgx[-1]["ts"] - pgx[0]["ts"]) or 1
        d["pg_tps"] = ((b[0] + b[1]) - (a[0] + a[1])) / tdb
        reads, hits = b[2] - a[2], b[3] - a[3]
        d["pg_hit"] = 100.0 * hits / (hits + reads) if hits + reads else 100.0
        d["pg_rows"] = (b[4] - a[4]) / tdb
        d["pg_deadlocks"] = b[7] - a[7]
        d["pg_conn_max"] = max(p[8] for p in pgs)
        d["pg_active_max"] = max(p[9] for p in pgs)
    rs = [x["redis"] for x in w if x["redis"]]
    if len(rs) >= 2:
        h, m = rs[-1]["hits"] - rs[0]["hits"], rs[-1]["misses"] - rs[0]["misses"]
        d["redis_hit"] = 100.0 * h / (h + m) if h + m else float("nan")
        d["redis_ops"] = max(r.get("ops", 0) for r in rs)
        d["redis_evicted"] = rs[-1]["evicted"] - rs[0]["evicted"]
        d["redis_mem_mb"] = max(r["mem"] for r in rs) / 1048576
    # per-pod JVM / pool / server-side HTTP
    pods = {}
    for x in w:
        for pod, m in x["be"].items():
            pods.setdefault(pod, []).append((x["ts"], m))
    hik_util, hik_pend, heap, gcfrac, http_rate, http_cnt, http_sum, http_max = [], [], [], [], 0.0, 0.0, 0.0, 0.0
    for pod, ser in pods.items():
        if len(ser) < 2:
            continue
        (t1, a), (t2, b) = ser[0], ser[-1]
        span = (t2 - t1) or 1
        hik_util.append(max(m["hik_active"] / m["hik_max"] if m["hik_max"] else 0 for _, m in ser))
        hik_pend.append(max(m["hik_pending"] for _, m in ser))
        heap.append(max(m["heap"] for _, m in ser) / 1048576)
        gcfrac.append(100.0 * (b["gc_sum"] - a["gc_sum"]) / span)
        http_rate += (b["http_cnt"] - a["http_cnt"]) / span
        http_cnt += b["http_cnt"] - a["http_cnt"]
        http_sum += b["http_sum"] - a["http_sum"]
        http_max = max(http_max, max(m["http_max"] for _, m in ser))
    if hik_util:
        d["hik_util_max"] = 100 * max(hik_util)
        d["hik_pending_max"] = max(hik_pend)
        d["heap_max_mb"] = max(heap)
        d["gc_pct_max"] = max(gcfrac)
        d["srv_rps"] = http_rate
        d["srv_avg_ms"] = 1000 * http_sum / http_cnt if http_cnt else 0
        d["srv_max_ms"] = 1000 * http_max
    d["gen_cpu_max"] = max((g for x in w for g in x.get("gen", [])), default=0)
    d["outbox_max"] = max((x["outbox"] or 0 for x in w), default=0)
    d["lag_max"] = max((x["lag"] or 0 for x in w if x["lag"] is not None), default=0)
    return d


# ---------- report ----------
L = []
P = L.append
P("# Performance & scalability report\n")
P("Environment: laptop, WSL2 (7.8 GB), k3d 1 server + 2 agents, JMeter 5.5 (3 CPUs / 1 GB heap) on the same machine. "
  "Numbers show mechanisms and relative scaling, not production capacity.\n")

P("## 1. Client-side (JMeter, steady state after ramp-up)\n")
P("| Phase | Users | Think (ms) | Throughput req/s | Errors % | p50 | p90 | p95 | p99 | max ms | Apdex(T=100ms, GETs) |")
P("|---|---|---|---|---|---|---|---|---|---|---|")
S = {}
for n in order:
    if n not in client:
        continue
    s = stats(client[n]["steady"])
    S[n] = s
    P(f"| {n} | {conf[n]['threads']} | {conf[n]['think']} | {s['rps']:.0f} | {s['err']:.2f} | {s['p50']} | {s['p90']} | {s['p95']} | {s['p99']} | {s['mx']} | {apdex(client[n]['steady']):.3f} |")

P("\n### Scalability (throughput vs users)\n")
P("| Phase | Users | req/s | Users x vs base | Throughput x vs base | Efficiency |")
P("|---|---|---|---|---|---|")
base = None
for n in order:
    if n in S and conf[n]["think"] > 0:
        if base is None:
            base = (conf[n]["threads"], S[n]["rps"])
        ux, tx = conf[n]["threads"] / base[0], S[n]["rps"] / base[1]
        P(f"| {n} | {conf[n]['threads']} | {S[n]['rps']:.0f} | {ux:.1f}x | {tx:.2f}x | {100 * tx / ux:.0f}% |")
P("\nEfficiency = throughput gain / user gain. 100% is linear scaling; a drop marks where the system stops scaling.\n")

if S:
    best = max(S, key=lambda n: S[n]["rps"])
    P(f"### Per-endpoint breakdown at the highest-throughput phase ({best})\n")
    P("| Endpoint | req/s | p50 | p95 | p99 | max | Errors % |")
    P("|---|---|---|---|---|---|---|")
    labels = sorted({r[2] for r in client[best]["steady"]})
    for lab in labels:
        s = stats([r for r in client[best]["steady"] if r[2] == lab])
        P(f"| {lab} | {s['rps']:.1f} | {s['p50']} | {s['p95']} | {s['p99']} | {s['mx']} | {s['err']:.2f} |")

P("\n## 2. Server-side resource use per phase\n")
P("| Phase | Backend CPU avg/peak (cores) | Replicas (max / HPA wants) | Backend mem/pod MiB | Node CPU peak % | Node mem peak % | Restarts | req/s per backend core | JMeter CPU peak % (300% = cap) |")
P("|---|---|---|---|---|---|---|---|---|")
SV = {}
for n in order:
    d = server(n)
    SV[n] = d
    if not d or n not in S:
        continue
    cores = d["be_cpu_avg"] / 1000
    P(f"| {n} | {cores:.2f} / {d['be_cpu_max'] / 1000:.2f} | {d['replicas_max']} / {d['replicas_des']} | {d['be_mem_avg']:.0f} | {d['node_cpu_max']:.0f} | {d['node_mem_max']:.0f} | {d['restarts']} | {S[n]['rps'] / cores if cores else 0:.0f} | {d['gen_cpu_max']:.0f} |")

P("\n## 3. JVM, connection pool and server-measured latency\n")
P("| Phase | Server req/s | Server avg ms | Server max ms | Hikari pool peak util % | Hikari pending peak | Heap peak MiB | GC pause ms per second (worst pod) |")
P("|---|---|---|---|---|---|---|---|")
for n in order:
    d = SV.get(n)
    if d and "srv_rps" in d:
        P(f"| {n} | {d['srv_rps']:.0f} | {d['srv_avg_ms']:.1f} | {d['srv_max_ms']:.0f} | {d['hik_util_max']:.0f} | {d['hik_pending_max']:.0f} | {d['heap_max_mb']:.0f} | {10 * d['gc_pct_max']:.1f} |")

P("\n## 4. Data tier: Postgres, Redis, Kafka, outbox\n")
P("| Phase | PG txn/s | PG cache hit % | PG rows read/s | PG conns peak (active) | Deadlocks | Redis hit % | Redis ops/s peak | Redis evictions | Kafka lag peak | Outbox backlog peak |")
P("|---|---|---|---|---|---|---|---|---|---|---|")
for n in order:
    d = SV.get(n)
    if d and "pg_tps" in d:
        rh = f"{d['redis_hit']:.1f}" if "redis_hit" in d and d["redis_hit"] == d["redis_hit"] else "n/a"
        P(f"| {n} | {d['pg_tps']:.0f} | {d['pg_hit']:.1f} | {d['pg_rows']:.0f} | {d['pg_conn_max']:.0f} ({d['pg_active_max']:.0f}) | {d['pg_deadlocks']:.0f} | {rh} | {d.get('redis_ops', 0):.0f} | {d.get('redis_evicted', 0):.0f} | {d['lag_max']} | {d['outbox_max']} |")

# ---------- findings ----------
P("\n## 5. Reading the results\n")
if S:
    ok = [n for n in order if n in S and conf[n]["think"] > 0]
    knee = None
    for n in ok:
        if S[n]["err"] > 1.0 or (ok and S[n]["p95"] > 3 * S[ok[0]]["p95"] and S[n]["p95"] > 100):
            knee = n
            break
    P(f"- Peak sustained throughput: **{max(S[n]['rps'] for n in S):.0f} req/s** ({max(S, key=lambda n: S[n]['rps'])}).")
    P(f"- First phase showing degradation (errors > 1% or p95 > 3x baseline and > 100 ms): **{knee or 'none in the tested range'}**.")
    sat = [n for n in order if SV.get(n) and SV[n].get("node_cpu_max", 0) > 85]
    P(f"- Phases with a node above 85% CPU (saturation): {', '.join(sat) if sat else 'none'}.")
    P("- Note: JMeter shares the machine with the cluster, so the highest phases may be limited by the load generator and the laptop, not the application.")
P("- `kubectl top` (metrics-server) has ~15-30 s resolution, so short CPU spikes are smoothed; counters (Postgres, Redis, JVM) are exact deltas.")

text = "\n".join(L)
print(text)
report_name = sys.argv[3] if len(sys.argv) > 3 else "PERF_REPORT.md"
open(os.path.join(ROOT, "loadtest", report_name), "w").write(text + "\n")
