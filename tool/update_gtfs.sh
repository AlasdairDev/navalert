#!/usr/bin/env bash
# Refresh BOTH bundled GTFS assets from a new feed, in the right order.
#
# WHY THIS EXISTS
# routes.json.gz and shapes.db are coupled: the shapes are keyed on the route
# NAMES in the feed. Regenerate one without the other and every shape lookup
# misses silently — the map falls back to straight lines and nothing says the
# offline geometry stopped working. test/gtfs_assets_consistency_test.dart
# catches that, but only after the fact. This does it in the right order so it
# never happens.
#
# Usage:  tool/update_gtfs.sh <path-to-new-gtfs-dir>
set -euo pipefail

FEED="${1:-}"
if [ -z "$FEED" ] || [ ! -d "$FEED" ]; then
  echo "usage: tool/update_gtfs.sh <path-to-gtfs-dir>" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OSRM_DIR="$HOME/osrm-build"
OSRM_NAME="navalert-osrm"
OSRM_URL="http://127.0.0.1:5000"
RUNTIME="$(command -v podman || command -v docker)"

echo "==> 1/4  feed -> assets/gtfs/routes.json.gz"
python3 tool/gen_gtfs.py "$FEED"

echo "==> 2/4  local OSRM"
if curl -s -m 5 -o /dev/null "$OSRM_URL/route/v1/driving/121.01,14.59;121.02,14.60"; then
  echo "    already serving on $OSRM_URL"
elif [ -f "$OSRM_DIR/ncr.osrm" ]; then
  echo "    starting $OSRM_NAME from $OSRM_DIR"
  "$RUNTIME" rm -f "$OSRM_NAME" >/dev/null 2>&1 || true
  "$RUNTIME" run -d --name "$OSRM_NAME" -m 2g -p 5000:5000 \
    -v "$OSRM_DIR:/data:Z" docker.io/osrm/osrm-backend \
    osrm-routed --algorithm mld --max-viaroute-size 500 /data/ncr.osrm >/dev/null
  until curl -s -m 3 -o /dev/null "$OSRM_URL/route/v1/driving/121.01,14.59;121.02,14.60"; do
    sleep 2
  done
  echo "    up"
else
  cat >&2 <<'EOF'
    No OSRM graph at ~/osrm-build/ncr.osrm. Build it once (~10 min):

      mkdir -p ~/osrm-build && cd ~/osrm-build
      curl -L -O https://download.geofabrik.de/asia/philippines-latest.osm.pbf
      podman run --rm -v "$PWD:/data:Z" docker.io/stefda/osmium-tool \
        osmium extract -b 120.83,14.25,121.23,14.87 \
        -o /data/ncr.osm.pbf /data/philippines-latest.osm.pbf
      for step in extract:-p\ /opt/car.lua partition customize; do :; done
      podman run --rm -v "$PWD:/data:Z" docker.io/osrm/osrm-backend osrm-extract -p /opt/car.lua /data/ncr.osm.pbf
      podman run --rm -v "$PWD:/data:Z" docker.io/osrm/osrm-backend osrm-partition /data/ncr.osrm
      podman run --rm -v "$PWD:/data:Z" docker.io/osrm/osrm-backend osrm-customize /data/ncr.osrm

    The clip to NCR is not optional on an 8 GB machine: the full Philippines
    extract is 577 MB and the graph build will not fit.
EOF
  exit 1
fi

echo "==> 3/4  routes -> assets/gtfs/shapes.db"
rm -f assets/gtfs/shapes.db
python3 tool/gen_shapes.py --server "$OSRM_URL"

echo "==> 4/4  verifying the two assets agree"
flutter test test/gtfs_assets_consistency_test.dart

echo
echo "Done. Both assets regenerated together."
echo "Stop the server when finished:  $RUNTIME rm -f $OSRM_NAME"
