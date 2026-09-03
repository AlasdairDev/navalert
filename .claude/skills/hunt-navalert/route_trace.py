#!/usr/bin/env python3
"""Coordinates for a GPS trace, taken from the bundled GTFS feed.

Traces must come from the feed rather than from guesses. The app matches a route
by proximity to its stops (800 m), advances guide steps by proximity to the leg
end (100/150 m) and draws geometry OSRM generated through those same stops. A
hand-invented trace misses all three and produces symptoms — no match, a step
that never advances, a line beside the road — that look exactly like app bugs
and are not.

Prints `lat,lng lat,lng ...` for gps.sh, or a listing for a human.
"""
import argparse
import gzip
import json
import os
import sys

FEED = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "..",
    "assets", "gtfs", "routes.json.gz")


def load():
    try:
        with gzip.open(FEED, "rt", encoding="utf-8") as fh:
            return json.load(fh)
    except OSError as exc:
        sys.exit(f"cannot read the bundled feed at {FEED}: {exc}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", help="exact route name")
    ap.add_argument("--find", help="substring search over route names")
    ap.add_argument("--list", action="store_true", help="list stops, readable")
    ap.add_argument("--from", dest="first", type=int, default=0)
    ap.add_argument("--to", dest="last", type=int, default=-1)
    args = ap.parse_args()
    routes = load()

    if args.find:
        needle = args.find.lower()
        hits = [r for r in routes if needle in r["n"].lower()]
        if not hits:
            sys.exit(f"no route name contains {args.find!r}")
        for r in hits[:40]:
            print(f'{len(r["s"]):4d} stops  {r["m"]:8s}  {r["n"]}')
        if len(hits) > 40:
            print(f"... and {len(hits) - 40} more")
        return

    if not args.name:
        sys.exit("pass --name or --find")
    match = next((r for r in routes if r["n"] == args.name), None)
    if match is None:
        # Near-miss help: an exact-name requirement with no hint is a dead end.
        close = [r["n"] for r in routes if args.name.lower() in r["n"].lower()]
        hint = ("\ndid you mean:\n  " + "\n  ".join(close[:5])) if close else ""
        sys.exit(f"no route named {args.name!r}{hint}")

    stops = match["s"]
    last = len(stops) if args.last < 0 else min(args.last + 1, len(stops))
    first = max(0, min(args.first, last - 1))
    picked = stops[first:last]

    if args.list:
        print(f'{match["n"]}  ({match["m"]}, {len(stops)} stops)')
        for i, (name, lat, lng) in enumerate(stops):
            print(f"  {i:3d}  {lat:.4f},{lng:.4f}  {name}")
        return

    print(" ".join(f"{lat},{lng}" for _name, lat, lng in picked))


if __name__ == "__main__":
    main()
