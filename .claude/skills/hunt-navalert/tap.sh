#!/usr/bin/env bash
# Tap a control BY LABEL, not by coordinate.
#
# WHY: coordinates are the single largest source of wasted time in a hunt. Button
# positions move between builds — one padding change in this app relocated every
# primary button by ~126 px — and a stale coordinate lands on the navigation bar,
# on whatever a dismissed dialog was covering, or on nothing. In one sweep that
# opened the launcher, opened Assistant, and started a fake call, each of which
# then had to be diagnosed as "not a bug".
#
# Flutter exposes its semantics to uiautomator as `content-desc` (NOT `text`),
# so a label can be resolved to real bounds and tapped at its true centre.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<USAGE
usage: tap.sh <label>       tap the control whose label contains <label>
       tap.sh --list        list every label currently on screen
       tap.sh --where <l>   print bounds and centre without tapping

Matching is a case-insensitive substring, so "Commute Guide" finds
"Show Commute Guide". An ambiguous match lists the candidates and taps nothing.
USAGE
}

need_device() {
  adb devices 2>/dev/null | grep -qE 'emulator-[0-9]+[[:space:]]+device' \
    || { echo "ERROR: no running emulator" >&2; exit 1; }
}

# DO NOT MODIFY LOGIC: wake the screen BEFORE dumping.
#
# uiautomator fails on a sleeping screen with "null root node returned by
# UiTestAutomationBridge" — a message that says nothing about the actual cause
# and sends you looking for a broken app. `svc power stayon true` is not enough:
# an emulator left idle still sleeps. Wake, dismiss the keyguard, retry once.
dump() {
  need_device
  local xml=/sdcard/navalert-ui.xml
  if ! adb shell uiautomator dump "$xml" 2>&1 | grep -q "dumped to"; then
    adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
    adb shell wm dismiss-keyguard   >/dev/null 2>&1 || true
    sleep 2
    adb shell uiautomator dump "$xml" 2>&1 | grep -q "dumped to" || {
      echo "ERROR: uiautomator could not read the screen." >&2
      echo "       Check: is an app in the foreground? Run check-env.sh." >&2
      exit 1; }
  fi
  adb shell cat "$xml" 2>/dev/null | tr -d '\r'
}

list_labels() {
  dump | tr '>' '\n' | grep -oE 'content-desc="[^"]+"' \
    | sed 's/content-desc="//; s/"$//' | sed 's/&#10;/ · /g' | sort -u
}

# Emits "label<TAB>x<TAB>y" for every node whose label matches.
find_matches() {
  local needle="$1"
  dump | tr '>' '\n' | grep 'content-desc="' | grep 'bounds="' \
  | python3 -c '
import sys, re
needle = sys.argv[1].lower()
for line in sys.stdin:
    d = re.search(r'"'"'content-desc="([^"]*)"'"'"', line)
    b = re.search(r'"'"'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"'"'"', line)
    if not d or not b:
        continue
    label = d.group(1).replace("&#10;", " · ")
    if needle not in label.lower():
        continue
    x1, y1, x2, y2 = map(int, b.groups())
    if x2 <= x1 or y2 <= y1:      # zero-area nodes are not tappable
        continue
    print(f"{label}\t{(x1+x2)//2}\t{(y1+y2)//2}")
' "$needle"
}

case "${1:-}" in
  ""|-h|--help) usage; exit "${1:+0}"; exit 2 ;;
  --list) list_labels; exit 0 ;;
  --where) shift; [ $# -ge 1 ] || { usage >&2; exit 2; }
           find_matches "$*"; exit 0 ;;
esac

NEEDLE="$*"
MATCHES="$(find_matches "$NEEDLE")"
COUNT=$(printf '%s' "$MATCHES" | grep -c . || true)

if [ "$COUNT" -eq 0 ]; then
  echo "ERROR: no control matching '$NEEDLE'. On screen now:" >&2
  list_labels | sed 's/^/  /' >&2
  exit 1
fi
if [ "$COUNT" -gt 1 ]; then
  # Never guess between candidates — guessing is the failure this replaces.
  echo "ERROR: '$NEEDLE' matches $COUNT controls; be more specific:" >&2
  printf '%s\n' "$MATCHES" | cut -f1 | sed 's/^/  /' >&2
  exit 1
fi

LABEL=$(printf '%s' "$MATCHES" | cut -f1)
X=$(printf '%s' "$MATCHES" | cut -f2)
Y=$(printf '%s' "$MATCHES" | cut -f3)
adb shell input tap "$X" "$Y"
echo "tapped '$LABEL' at $X,$Y"
