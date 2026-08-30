"""Phase 1 — pre-compute road geometry for every PUV route, offline.

WHY THIS EXISTS
`RoutePathService` asks OSRM for road geometry at runtime and falls back to a
STRAIGHT LINE when offline. A commute is exactly when the network is worst, so
the map quietly stopped showing the real road path at the moment it mattered.
This moves that work to build time: the shapes ship inside the app and the
commute feature never touches the network again.

Usage
    # spike first — 20 routes, measures size and time honestly
    python tool/gen_shapes.py --limit 20

    # full run against a LOCAL OSRM (see --server); resumable
    python tool/gen_shapes.py --server http://localhost:5000

    -> writes assets/gtfs/shapes.db

ON THE OSRM SERVER
The public demo server is rate-limited and its acceptable-use policy does not
cover 1,711 multi-waypoint requests. Run one locally instead:

    docker run -t -i -p 5000:5000 -v "$PWD/osrm:/data" \
        osrm/osrm-backend osrm-routed --algorithm mld /data/philippines.osrm

and pass --server http://localhost:5000. The default is the demo server, which
is fine for a small --limit spike and nothing more.

WHY WAYPOINTS, NOT TERMINALS
Routing terminal-to-terminal returns the FASTEST path between the endpoints,
which is not the route the jeepney drives — a 43-stop route through side
streets comes back as a run down the highway. Every stop is sent as a waypoint
so the geometry follows the real stop sequence. That shape is confidently
wrong otherwise, which is worse than a straight line: a straight line at least
looks like an approximation.
"""
import argparse
import gzip
import json
import math
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROUTES = os.path.join("assets", "gtfs", "routes.json.gz")
OUT = os.path.join("assets", "gtfs", "shapes.db")
DEMO = "https://router.project-osrm.org"
UA = "NavAlert-Capstone/1.0 (PUP BSIT; contact: navalert@pup.edu.ph)"

# OSRM's demo server caps a request at 100 coordinates. Long routes are split
# and stitched, overlapping by one stop so the joint has no gap.
MAX_WAYPOINTS = 100

# Douglas-Peucker tolerance. 8 m is below what is visible at street zoom on a
# phone, and cuts the point count by roughly an order of magnitude.
SIMPLIFY_M = 8.0


def encode_polyline(points, precision=5):
    """Google encoded polyline. ~6x smaller than JSON floats."""
    factor = 10 ** precision
    out, prev_lat, prev_lng = [], 0, 0
    for lat, lng in points:
        ilat, ilng = round(lat * factor), round(lng * factor)
        for d in (ilat - prev_lat, ilng - prev_lng):
            d = ~(d << 1) if d < 0 else (d << 1)
            while d >= 0x20:
                out.append(chr((0x20 | (d & 0x1F)) + 63))
                d >>= 5
            out.append(chr(d + 63))
        prev_lat, prev_lng = ilat, ilng
    return "".join(out)


def _perp_m(p, a, b):
    """Perpendicular distance p->segment(a,b) in metres (local flat approx)."""
    ky = 111320.0
    kx = ky * math.cos(math.radians(p[0]))
    px, py = p[1] * kx, p[0] * ky
    ax, ay = a[1] * kx, a[0] * ky
    bx, by = b[1] * kx, b[0] * ky
    dx, dy = bx - ax, by - ay
    if dx == 0 and dy == 0:
        return math.hypot(px - ax, py - ay)
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def simplify(points, tol=SIMPLIFY_M):
    """Iterative Douglas-Peucker — recursion blows the stack on long shapes."""
    if len(points) < 3:
        return points
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        lo, hi = stack.pop()
        worst, idx = 0.0, -1
        for i in range(lo + 1, hi):
            d = _perp_m(points[i], points[lo], points[hi])
            if d > worst:
                worst, idx = d, i
        if idx != -1 and worst > tol:
            keep[idx] = True
            stack.append((lo, idx))
            stack.append((idx, hi))
    return [p for p, k in zip(points, keep) if k]


def osrm_geometry(server, coords, retries=4):
    """Road geometry through ALL of coords, as [(lat, lng), ...]."""
    path = ";".join(f"{lng:.6f},{lat:.6f}" for lat, lng in coords)
    url = (f"{server}/route/v1/driving/{path}"
           "?overview=full&geometries=geojson&continue_straight=false")
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=60) as r:
                data = json.load(r)
            if data.get("code") != "Ok" or not data.get("routes"):
                return None
            return [(c[1], c[0])
                    for c in data["routes"][0]["geometry"]["coordinates"]]
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as e:
            code = getattr(e, "code", None)
            if code == 429 or code is None:          # rate limited / transient
                time.sleep(2 ** attempt)
                continue
            return None
        except Exception:
            return None
    return None


def route_shape(server, stops, throttle):
    """Full geometry for one route, stitching chunks of <= MAX_WAYPOINTS."""
    pts = [(s[1], s[2]) for s in stops]
    if len(pts) < 2:
        return None
    out = []
    i = 0
    while i < len(pts) - 1:
        chunk = pts[i:i + MAX_WAYPOINTS]
        if len(chunk) < 2:
            break
        geom = osrm_geometry(server, chunk)
        if geom is None:
            return None
        out.extend(geom[1:] if out else geom)
        if throttle:
            time.sleep(throttle)
        i += MAX_WAYPOINTS - 1                        # overlap one stop
    return out or None


def open_db(path):
    db = sqlite3.connect(path)
    db.executescript("""
        CREATE TABLE IF NOT EXISTS shapes(
            id       INTEGER PRIMARY KEY,
            name     TEXT NOT NULL,
            mode     TEXT NOT NULL,
            polyline TEXT NOT NULL,
            points   INTEGER NOT NULL
        );
        -- R-tree over each shape's bounding box. This is what makes the live
        -- lookup cheap: without it, "which routes are near me" is a
        -- point-to-polyline test against every shape (~1.7M distance
        -- calculations per GPS fix). The index narrows it to a handful first.
        CREATE VIRTUAL TABLE IF NOT EXISTS shape_bbox USING rtree(
            id, min_lat, max_lat, min_lng, max_lng
        );
    """)
    return db


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", default=DEMO)
    ap.add_argument("--limit", type=int, default=0, help="spike on N routes")
    ap.add_argument("--throttle", type=float, default=None,
                    help="seconds between requests (default: 1.0 on the demo "
                         "server, 0 on a local one)")
    ap.add_argument("--out", default=OUT)
    args = ap.parse_args()

    throttle = args.throttle
    if throttle is None:
        throttle = 1.0 if args.server.rstrip("/") == DEMO else 0.0
    if args.server.rstrip("/") == DEMO and not args.limit:
        print("REFUSING: a full 1,711-route run against the public demo server "
              "would be rate-limited and is outside its acceptable-use policy.\n"
              "Use --limit for a spike, or --server with a local OSRM.",
              file=sys.stderr)
        return 2

    with gzip.open(ROUTES, "rt", encoding="utf-8") as f:
        routes = json.load(f)
    if args.limit:
        routes = routes[:args.limit]

    db = open_db(args.out)
    done = {r[0] for r in db.execute("SELECT id FROM shapes")}
    if done:
        print(f"resuming — {len(done)} routes already stored")

    ok = failed = 0
    t0 = time.time()
    for idx, r in enumerate(routes):
        if idx in done:
            continue
        stops = r.get("s") or []
        geom = route_shape(args.server, stops, throttle)
        if not geom:
            failed += 1
            print(f"  [{idx}] {r['n'][:40]}: no geometry", file=sys.stderr)
            continue
        pts = simplify(geom)
        lats = [p[0] for p in pts]
        lngs = [p[1] for p in pts]
        db.execute(
            "INSERT OR REPLACE INTO shapes(id,name,mode,polyline,points) "
            "VALUES(?,?,?,?,?)",
            (idx, r["n"], r["m"], encode_polyline(pts), len(pts)))
        db.execute(
            "INSERT OR REPLACE INTO shape_bbox VALUES(?,?,?,?,?)",
            (idx, min(lats), max(lats), min(lngs), max(lngs)))
        db.commit()
        ok += 1
        print(f"  [{idx}] {r['n'][:40]}: {len(geom)} -> {len(pts)} pts")

    db.execute("VACUUM")
    db.close()
    size = os.path.getsize(args.out)
    print(f"\n{ok} shapes, {failed} failed, {time.time()-t0:.1f}s")
    print(f"{args.out}: {size/1024:.0f} KB")
    if ok:
        print(f"~{size/ok/1024:.1f} KB per route "
              f"-> ~{size/ok*1711/1048576:.1f} MB for all 1,711")
    return 0


if __name__ == "__main__":
    sys.exit(main())
