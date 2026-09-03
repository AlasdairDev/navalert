#!/usr/bin/env bash
# Build, boot and prepare an emulator for a hunt.
#
# ORDER MATTERS ON AN 8 GB MACHINE. Gradle and qemu must never be resident at
# the same time: this laptop's only swap is zram (compressed RAM, not disk), so
# there is no real overflow and the kernel LIVELOCKS instead of OOM-killing
# anything. Build with the emulator down, stop the Gradle daemon, then boot.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
PKG=ph.edu.pup.navalert
APK="$REPO/build/app/outputs/flutter-apk/app-debug.apk"
SKIP_BUILD=0
[ "${1:-}" = "--no-build" ] && SKIP_BUILD=1

cd "$REPO"

if [ "$SKIP_BUILD" -eq 0 ]; then
  echo "==> stopping any emulator first (Gradle and qemu must not overlap)"
  adb emu kill >/dev/null 2>&1 || true
  sleep 4
  echo "==> building debug APK"
  # Debug, not release: debugPrint reaches logcat, which is how NavAlert reports
  # its own failures ("NavAlert: ..."). Release strips them and a hunt goes blind.
  flutter build apk --debug
  # NEVER `pkill -f GradleDaemon` — the pattern matches the shell running this
  # script and kills it (exit 144). Ask Gradle to stop instead.
  ./android/gradlew --stop >/dev/null 2>&1 || true
  sleep 2
fi

[ -f "$APK" ] || { echo "ERROR: no APK at $APK" >&2; exit 1; }

echo "==> booting the emulator (memory-capped scope)"
"$REPO/.claude/skills/run-navalert/boot-emulator.sh" "${AVD:-}" || true
adb devices | grep -qE 'emulator-[0-9]+\s+device' || { echo "ERROR: no device" >&2; exit 1; }

echo "==> installing"
adb install -r "$APK" | tail -1

echo "==> permissions"
for p in ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION POST_NOTIFICATIONS SEND_SMS; do
  adb shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1 || true
done

# Keep the device awake for the whole hunt. A screen that sleeps pauses the
# Flutter engine, which stops its timers — and a stopped escalation timer looks
# exactly like an alarm that refuses to escalate. Rule the environment out by
# construction rather than re-deriving it mid-report.
echo "==> stay awake"
adb shell svc power stayon true >/dev/null 2>&1 || true
adb shell settings put system screen_off_timeout 1800000 >/dev/null 2>&1 || true

echo "==> network on (go offline later with: adb shell cmd connectivity airplane-mode enable)"
adb shell cmd connectivity airplane-mode disable >/dev/null 2>&1 || true
adb shell svc wifi enable  >/dev/null 2>&1 || true
adb shell svc data enable  >/dev/null 2>&1 || true

echo "==> free RAM after boot:"
free -h 2>/dev/null | head -2 || true
echo "ready — launch with: adb shell am start -n $PKG/.MainActivity"
