#!/usr/bin/env bash
# Screenshot into the current hunt folder, numbered and labelled.
#
# ALWAYS SCREENSHOT BEFORE TAPPING. Button coordinates move between builds — a
# single padding change relocated every primary button in this app by ~126 px —
# so a tap replayed from an earlier run lands somewhere else. Blind taps in this
# session opened the launcher, opened Assistant, and started a fake call, and
# each one cost more time to diagnose than the screenshot would have.
set -euo pipefail
DIR="${HUNT_DIR:-/tmp/navalert-hunt}"
mkdir -p "$DIR"
LABEL="${1:-shot}"
N=$(printf '%02d' "$(( $(find "$DIR" -maxdepth 1 -name '*.png' | wc -l) + 1 ))")
OUT="$DIR/${N}_${LABEL//[^A-Za-z0-9_-]/-}.png"
adb exec-out screencap -p > "$OUT"
echo "$OUT"
