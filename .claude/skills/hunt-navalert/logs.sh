#!/usr/bin/env bash
# What the app said about itself, and whether it died.
#
# NavAlert reports its own failures through debugPrint as "NavAlert: ..." —
# a bundled shape that would not load, a leg with no geometry, a notification
# that could not be cleared. Those lines are the app telling you where it hurt,
# and they are free evidence for a report.
#
# It also catches the thing a screenshot cannot: a CRASH. A Flutter exception
# leaves the last frame on screen, so a sweep can photograph a perfectly normal
# looking page belonging to a dead app and call it fine.
set -euo pipefail
PKG=ph.edu.pup.navalert

adb devices 2>/dev/null | grep -qE 'emulator-[0-9]+[[:space:]]+device' \
  || { echo "ERROR: no running emulator" >&2; exit 1; }

case "${1:-show}" in
  clear)
    adb logcat -c >/dev/null 2>&1 || true
    echo "logcat cleared — everything from here belongs to this hunt"
    exit 0 ;;
  show) ;;
  *) echo "usage: logs.sh [show|clear]" >&2; exit 2 ;;
esac

LOG=$(adb logcat -d 2>/dev/null | tr -d '\r' || true)

echo "=== NavAlert's own reports ==="
# Tag-scoped. A bare "NavAlert:" also matches the system volume dialog
# ("vol.VolumeDialogControl: onRemoteUpdate: NavAlert: 33 of 100"), which is the
# media session doing its job, not the app reporting a fault. debugPrint lands
# under the `flutter` tag.
APP=$(grep -E "flutter[^:]*: *NavAlert:" <<<"$LOG" | tail -40 || true)
[ -n "$APP" ] && printf '%s\n' "$APP" || echo "  (none — the app reported no failures)"

echo
echo "=== crashes / fatal errors ==="
# Flutter exceptions do not always reach the Android FATAL log, so both are
# checked: a Dart-level "Unhandled Exception" leaves the app running with a
# broken screen, which looks fine in a screenshot.
# DO NOT MODIFY LOGIC: match the LEVEL, not just the tag.
#
# A bare "AndroidRuntime" matches every ordinary uiautomator invocation — "Using
# default boot image", "Shutting down VM" — and uiautomator is what tap.sh runs
# on every single tap. The first version of this reported a crash on a perfectly
# healthy app, every time. A detector that always fires is worse than none: it
# teaches you to skip the one run where it was right.
#
# Real markers only: FATAL EXCEPTION, AndroidRuntime at ERROR level, and Dart
# exceptions. DioException is excluded because the tile layer raises one per
# tile whenever the device is offline, which is a supported state here.
CRASH=$(grep -E "FATAL EXCEPTION| E AndroidRuntime|E/AndroidRuntime|Unhandled Exception|E/flutter" <<<"$LOG" \
        | grep -v "DioException" | tail -25 || true)
if [ -n "$CRASH" ]; then
  printf '%s\n' "$CRASH"
  echo
  echo "VERDICT: something failed hard. A screenshot of the last frame will NOT"
  echo "         show this — investigate before trusting anything captured after it."
  exit 1
fi
echo "  (none)"

echo
echo "=== is the app still alive? ==="
if adb shell pidof "$PKG" >/dev/null 2>&1; then
  echo "  running, pid $(adb shell pidof $PKG | tr -d '\r')"
else
  echo "  NOT RUNNING — it exited or was killed. Anything captured after that"
  echo "  point is a stale frame, not the app."
  exit 1
fi
