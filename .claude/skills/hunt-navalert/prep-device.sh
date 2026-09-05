#!/usr/bin/env bash
# Build, boot and prepare an emulator for a hunt.
#
# ORDER MATTERS ON AN 8 GB MACHINE. Gradle and qemu must never be resident at
# the same time: this laptop's only swap is zram (compressed RAM, not disk), so
# there is no real overflow and the kernel LIVELOCKS instead of OOM-killing
# anything. When a build IS needed, the emulator goes down first.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
PKG=ph.edu.pup.navalert
APK="$REPO/build/app/outputs/flutter-apk/app-debug.apk"

usage() {
  cat <<USAGE
usage: prep-device.sh [--rebuild] [--no-launch] [--help]

Prepares an emulator for a hunt: build if needed, boot, install, grant
permissions, keep the screen awake, and launch the app.

  --rebuild     force a rebuild even if the APK is already current.
                Takes the emulator DOWN first — Gradle and qemu must not
                overlap on an 8 GB machine.
  --no-launch   stop after installing; do not start the app.
  --help        this text.

By default nothing is rebuilt and no running emulator is disturbed when the
APK is already newer than lib/, assets/ and pubspec.
USAGE
}

REBUILD=0
LAUNCH=1
# DO NOT MODIFY LOGIC: unknown flags must ABORT, never fall through.
# An earlier version accepted only `--no-build` and treated everything else —
# including `--help` — as "build", so asking for help killed a running emulator
# and started a full Gradle build. Anything unrecognised now stops here.
while [ $# -gt 0 ]; do
  case "$1" in
    --rebuild)   REBUILD=1 ;;
    --no-launch) LAUNCH=0 ;;
    --no-build)  REBUILD=0 ;;   # accepted for compatibility; now the default
    -h|--help)   usage; exit 0 ;;
    *) echo "ERROR: unknown option '$1'" >&2; echo >&2; usage >&2; exit 2 ;;
  esac
  shift
done

cd "$REPO"
command -v adb >/dev/null 2>&1 || { echo "ERROR: adb not on PATH" >&2; exit 1; }

emulator_up() { adb devices 2>/dev/null | grep -qE 'emulator-[0-9]+[[:space:]]+device'; }

# Is the APK newer than everything that goes into it?
apk_current() {
  [ -f "$APK" ] || return 1
  local newer
  newer=$(find lib assets pubspec.yaml pubspec.lock android/app/src/main \
            -newer "$APK" -type f 2>/dev/null | head -1)
  [ -z "$newer" ]
}

if [ "$REBUILD" -eq 1 ] || ! apk_current; then
  if [ "$REBUILD" -eq 1 ]; then
    echo "==> rebuild requested"
  else
    echo "==> APK is missing or older than the sources; rebuilding"
  fi
  if emulator_up; then
    echo "==> stopping the emulator first (Gradle and qemu must not overlap)"
    adb emu kill >/dev/null 2>&1 || true
    sleep 4
  fi
  # Debug, not release: debugPrint reaches logcat, which is how NavAlert reports
  # its own failures ("NavAlert: ..."). Release strips them and a hunt goes blind.
  flutter build apk --debug
  # NEVER `pkill -f GradleDaemon` — the pattern matches the shell running this
  # script and kills it (exit 144). Ask Gradle to stop instead.
  ./android/gradlew --stop >/dev/null 2>&1 || true
  sleep 2
else
  echo "==> APK is current; no build, and any running emulator is left alone"
fi

[ -f "$APK" ] || { echo "ERROR: no APK at $APK" >&2; exit 1; }

if emulator_up; then
  echo "==> emulator already running"
else
  echo "==> booting the emulator (memory-capped scope)"
  "$REPO/.claude/skills/run-navalert/boot-emulator.sh" "${AVD:-}" || true
fi
emulator_up || { echo "ERROR: no emulator after boot" >&2; exit 1; }

echo "==> installing"
adb install -r "$APK" | tail -1

echo "==> permissions"
for p in ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION POST_NOTIFICATIONS SEND_SMS; do
  adb shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1 || true
done

# Keep the device awake for the whole hunt. A screen that sleeps pauses the
# Flutter engine, which stops its timers — and a stopped escalation timer looks
# exactly like an alarm refusing to escalate. It also renders the emulator window
# solid black, which reads as a crashed app rather than a dark screen.
#
# DO NOT MODIFY LOGIC: all three lines are needed, and `svc power stayon true`
# ALONE DOES NOTHING HERE. It sets stay_on_while_plugged_in=15, meaning "stay on
# while plugged in" — and an emulator reports `AC powered: false`, so it is never
# plugged in and the flag never applies. Measured: with stayon set to 15 the
# screen still slept and the window went black.
#
# `dumpsys battery set ac 1` makes the device report itself on AC, which is what
# finally makes stayon mean something. The timeout is raised too, so the screen
# survives even if the battery state is reset by something else.
echo "==> stay awake"
adb shell svc power stayon true >/dev/null 2>&1 || true
adb shell dumpsys battery set ac 1 >/dev/null 2>&1 || true
adb shell settings put system screen_off_timeout 2147483647 >/dev/null 2>&1 || true
# Report it, rather than claiming it. This step used to say "stay awake" and then
# let the screen sleep half an hour later.
_awake=$(adb shell dumpsys window 2>/dev/null | tr -d '\r' | grep -c "screenState=SCREEN_STATE_ON" || true)
[ "${_awake:-0}" -gt 0 ] && echo "    screen on, sleep disabled" \
                        || echo "    WARNING: screen still reports off" >&2

echo "==> network on (go offline later with: adb shell cmd connectivity airplane-mode enable)"
adb shell cmd connectivity airplane-mode disable >/dev/null 2>&1 || true
adb shell svc wifi enable  >/dev/null 2>&1 || true
adb shell svc data enable  >/dev/null 2>&1 || true

if [ "$LAUNCH" -eq 1 ]; then
  echo "==> launching"
  adb shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1 || true
  # The emulator has no GPS until one is set, and the app refuses to plan from an
  # unknown position rather than inventing one — without this you get "turn on
  # GPS", not a map. Longitude first; see gps.sh.
  adb emu geo fix 121.0108 14.5979 >/dev/null 2>&1 || true
  echo "    started, GPS seeded at PUP Sta. Mesa (14.5979, 121.0108)"
fi

echo "==> free RAM:"
free -h 2>/dev/null | head -2 || true
echo "ready."
