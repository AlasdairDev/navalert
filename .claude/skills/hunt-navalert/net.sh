#!/usr/bin/env bash
# Take the emulator offline or back online, completely.
#
# Airplane mode alone is not enough on an emulator — wifi and data can survive
# it. Forgetting one leaves a "verified offline" run that was quietly online,
# which is worse than not testing it: it manufactures false confidence in the
# exact capability this app is built around.
set -euo pipefail
adb devices 2>/dev/null | grep -qE 'emulator-[0-9]+[[:space:]]+device' \
  || { echo "ERROR: no running emulator" >&2; exit 1; }

case "${1:-}" in
  off)
    adb shell svc wifi disable >/dev/null 2>&1 || true
    adb shell svc data disable >/dev/null 2>&1 || true
    adb shell cmd connectivity airplane-mode enable >/dev/null 2>&1 || true
    sleep 5 ;;
  on)
    adb shell cmd connectivity airplane-mode disable >/dev/null 2>&1 || true
    adb shell svc wifi enable >/dev/null 2>&1 || true
    adb shell svc data enable >/dev/null 2>&1 || true
    sleep 6 ;;
  *) echo "usage: net.sh off|on" >&2; exit 2 ;;
esac

# Report what is actually true, not what was asked for.
if adb shell ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
  echo "network: ONLINE"
  [ "$1" = "off" ] && { echo "  WARNING: asked for offline and it is still reachable" >&2; exit 1; }
else
  echo "network: OFFLINE"
  [ "$1" = "on" ] && { echo "  WARNING: asked for online and it is unreachable" >&2; exit 1; }
fi
exit 0
