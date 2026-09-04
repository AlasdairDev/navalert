#!/usr/bin/env bash
# One command to start a hunt.
#
# The skill's method needs a person (or Claude) reading screenshots and judging
# what is wrong — that part cannot be scripted. This gets you to the point where
# that judgement can begin: a prepared emulator, the app running, and every
# top-level screen already captured.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${HUNT_DIR:=/tmp/navalert-hunt-$(date +%Y%m%d-%H%M%S)}"
export HUNT_DIR

usage() {
  cat <<USAGE
usage: hunt.sh [--rebuild] [--help]

Prepares the emulator, launches NavAlert, and captures every top-level screen
into a fresh hunt folder.

  --rebuild   force a rebuild first (takes the emulator down; see prep-device.sh)
  --help      this text

Then read the captures and drive the stateful flows by hand:

  \$H/gps.sh find "CUBAO"
  \$H/gps.sh route "MURPHY 15TH AVE - STOP N SHOP" 2 16
  \$H/shot.sh label

Set HUNT_DIR to choose where captures land. See SKILL.md for the method and
the report format.
USAGE
}

REBUILD=()
while [ $# -gt 0 ]; do
  case "$1" in
    --rebuild) REBUILD=(--rebuild) ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option '$1'" >&2; echo >&2; usage >&2; exit 2 ;;
  esac
  shift
done

echo "### hunt -> $HUNT_DIR"
echo
"$HERE/prep-device.sh" "${REBUILD[@]+"${REBUILD[@]}"}"
echo
"$HERE/sweep-ui.sh"
echo
cat <<NEXT
### next

  1. LOOK at every capture in $HUNT_DIR before anything else.
  2. Rule out the environment before calling anything a bug — SKILL.md opens
     with the four checks, and two "bugs" in the first sweep of this app were
     the hunter's own stray taps.
  3. Drive the stateful flows: alarm stages, overshoot, offline, empty states.
     Screenshot before each tap; button positions move between builds.
NEXT
