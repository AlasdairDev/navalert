"""Preprocess a Philippine GTFS feed into NavAlert's compact commute-guide asset.

Source feed: DOTC Philippine GTFS (jeepney + bus + rail for Metro Manila),
released for the Philippine Transit App Challenge and maintained by Sakay.ph
(https://github.com/sakayph/gtfs). Used under the DOTC Developer License
Agreement, which permits reproduction/distribution for apps that assist mass
transportation riders and promote public transportation.

This is a stopgap dataset until fresher official GTFS is available.

Usage:
    python tool/gen_gtfs.py <path-to-gtfs-dir>
        -> writes assets/gtfs/routes.json.gz

Output format (JSON, gzipped): a list of routes, each:
    {"n": route name, "m": "jeepney"|"bus", "s": [[stop_name, lat, lng], ...]}
Only road PUVs in NavAlert's scope (jeepney PUJ, bus PUB) are kept; rail and
UV Express (absent from this feed) fall back to the synthetic route engine.
"""
import csv
import collections
import gzip
import json
import os
import sys


def route_mode(route_id: str):
    if "_PUJ" in route_id:
        return "jeepney"
    if "_PUB" in route_id:
        return "bus"
    return None  # rail / other — out of scope


def main(gtfs_dir: str) -> None:
    def path(name):
        return os.path.join(gtfs_dir, name)

    stops = {}
    with open(path("stops.txt"), encoding="utf-8") as f:
        for s in csv.DictReader(f):
            try:
                stops[s["stop_id"]] = (
                    s["stop_name"],
                    round(float(s["stop_lat"]), 5),
                    round(float(s["stop_lon"]), 5),
                )
            except (KeyError, ValueError):
                pass

    first_trip = {}  # route_id -> representative trip_id
    with open(path("trips.txt"), encoding="utf-8") as f:
        for t in csv.DictReader(f):
            first_trip.setdefault(t["route_id"], t["trip_id"])

    want = set(first_trip.values())
    seq = collections.defaultdict(list)  # trip_id -> [(seq, stop_id)]
    with open(path("stop_times.txt"), encoding="utf-8") as f:
        for st in csv.DictReader(f):
            tid = st["trip_id"]
            if tid in want:
                try:
                    seq[tid].append((int(st["stop_sequence"]), st["stop_id"]))
                except (KeyError, ValueError):
                    pass

    routes = {}
    with open(path("routes.txt"), encoding="utf-8") as f:
        for r in csv.DictReader(f):
            routes[r["route_id"]] = r

    out = []
    for rid, tid in first_trip.items():
        mode = route_mode(rid)
        if not mode:
            continue
        r = routes.get(rid, {})
        name = (r.get("route_short_name") or r.get("route_long_name") or rid).strip()
        pts = []
        for _, sid in sorted(seq.get(tid, [])):
            if sid in stops:
                nm, la, lo = stops[sid]
                pts.append([nm, la, lo])
        if len(pts) >= 2:
            out.append({"n": name, "m": mode, "s": pts})

    js = json.dumps(out, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    out_dir = os.path.join(os.path.dirname(__file__), "..", "assets", "gtfs")
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "routes.json.gz")
    with open(out_path, "wb") as f:
        f.write(gzip.compress(js, 9))
    print(f"Wrote {out_path}")
    print(f"  routes: {len(out)}  stop-points: {sum(len(o['s']) for o in out)}")
    print(f"  gzipped size: {os.path.getsize(out_path) / 1e6:.2f} MB")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: python tool/gen_gtfs.py <path-to-gtfs-dir>")
    main(sys.argv[1])
