#!/usr/bin/env bash
# Drive the emulator's GPS.
#
# WHY THIS WRAPPER EXISTS: `adb emu geo fix` takes LONGITUDE FIRST. Every
# coordinate a human writes, every coordinate in the bundled GTFS feed, and
# every coordinate in this codebase is lat,lng. Passing them straight through
# puts the rider in the Pacific with no error message and a map that simply
# renders nothing — which reads as a broken app rather than a swapped argument.
# Every command here takes lat lng in that order and flips it at the boundary.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
DWELL="${DWELL:-4}"

die() { echo "ERROR: $*" >&2; exit 1; }

need_device() {
  command -v adb >/dev/null 2>&1 || die "adb not on PATH"
  adb devices | grep -qE 'emulator-[0-9]+\s+device' \
    || die "no running emulator (use prep-device.sh)"
}

# fix LAT LNG — one position.
cmd_fix() {
  [ $# -eq 2 ] || die "usage: gps.sh fix <lat> <lng>"
  need_device
  adb emu geo fix "$2" "$1" >/dev/null    # <-- lng lat, the flip
  echo "gps: $1, $2"
}

# drive LAT,LNG LAT,LNG ...  — a trace, one fix per point.
#
# Repeats each fix. A single `geo fix` is delivered once; a screen that only
# updates on a fix can miss it, and the app's own speed estimate needs more than
# one sample to be anything but zero.
cmd_drive() {
  [ $# -ge 1 ] || die "usage: gps.sh drive <lat,lng> [lat,lng ...]"
  need_device
  local i=0
  for p in "$@"; do
    local lat="${p%%,*}" lng="${p##*,}"
    [ "$lat" != "$p" ] || die "point '$p' is not lat,lng"
    i=$((i+1))
    adb emu geo fix "$lng" "$lat" >/dev/null
    sleep 1
    adb emu geo fix "$lng" "$lat" >/dev/null
    echo "  [$i/$#] $lat, $lng"
    sleep "$DWELL"
  done
}

# route "NAME" [first] [last] — drive along a REAL route from the bundled feed.
#
# Invented coordinates are the fastest way to a false bug report: a trace that
# does not follow a road produces geometry mismatches, overshoot latches and
# guide steps that never advance, none of which the app is at fault for. The
# feed is the ground truth the app itself was built from, so traces come from it.
cmd_route() {
  [ $# -ge 1 ] || die "usage: gps.sh route \"<ROUTE NAME>\" [firstStop] [lastStop]"
  need_device
  local pts
  pts="$(python3 "$HERE/route_trace.py" --name "$1" --from "${2:-0}" --to "${3:--1}")" \
    || die "no such route — try: gps.sh find <substring>"
  # shellcheck disable=SC2086
  cmd_drive $pts
}

cmd_find()  { python3 "$HERE/route_trace.py" --find "${1:?usage: gps.sh find <substring>}"; }
cmd_stops() { python3 "$HERE/route_trace.py" --name "${1:?usage: gps.sh stops <NAME>}" --list; }

case "${1:-}" in
  fix)   shift; cmd_fix "$@" ;;
  drive) shift; cmd_drive "$@" ;;
  route) shift; cmd_route "$@" ;;
  find)  shift; cmd_find "$@" ;;
  stops) shift; cmd_stops "$@" ;;
  *) cat >&2 <<USAGE
usage:
  gps.sh fix   <lat> <lng>                  one position
  gps.sh drive <lat,lng> [lat,lng ...]      a trace (DWELL=seconds, default 4)
  gps.sh route "<ROUTE NAME>" [from] [to]   drive a real route from the feed
  gps.sh find  <substring>                  search route names
  gps.sh stops "<ROUTE NAME>"               list a route's stops

All coordinates are lat lng. The adb argument flip is handled here.
USAGE
     exit 2 ;;
esac
