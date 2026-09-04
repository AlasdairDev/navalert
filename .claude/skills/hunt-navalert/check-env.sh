#!/usr/bin/env bash
# Rule out the environment before calling anything a bug.
#
# SKILL.md opens with this rule because it is the one that cost the most: two
# "bugs" in the first sweep of this app were the hunter's own doing — taps
# landing outside a button, and a tap hitting a row after a dialog dismissed
# underneath it. A third looked like a frozen UI and was a sleeping screen,
# which surfaces as uiautomator's meaningless "null root node".
#
# Four checks, one verdict. Run it the moment something looks wrong.
set -euo pipefail
PKG=ph.edu.pup.navalert
FAIL=0
say() { printf '%-26s %s\n' "$1" "$2"; }

adb devices 2>/dev/null | grep -qE 'emulator-[0-9]+[[:space:]]+device' || {
  say "device" "NO EMULATOR — nothing else is meaningful"; exit 1; }
say "device" "$(adb devices | grep -oE 'emulator-[0-9]+' | head -1)"

WIN=$(adb shell dumpsys window 2>/dev/null | tr -d '\r')
if grep -q "screenState=SCREEN_STATE_ON" <<<"$WIN"; then
  say "screen" "on"
else
  say "screen" "OFF  <-- a sleeping screen pauses Flutter, stopping its timers."
  echo "                           A timer-driven bug cannot be observed here."
  echo "                           Fix: adb shell input keyevent KEYCODE_WAKEUP"
  FAIL=1
fi

if grep -q "isKeyguardShowing=true" <<<"$WIN"; then
  say "keyguard" "SHOWING  <-- taps go to the lock screen, not the app"
  echo "                           Fix: adb shell wm dismiss-keyguard"
  FAIL=1
else
  say "keyguard" "dismissed"
fi

TOP=$(adb shell dumpsys activity activities 2>/dev/null | tr -d '\r' \
      | grep -m1 topResumedActivity || true)
if grep -q "$PKG" <<<"$TOP"; then
  say "foreground" "NavAlert"
else
  say "foreground" "NOT NavAlert  <-- your taps are going somewhere else"
  echo "                           ${TOP:-  (nothing resumed)}"
  echo "                           Fix: adb shell am start -n $PKG/.MainActivity"
  FAIL=1
fi

# No `exit` inside awk: it closes the pipe early, `top` takes SIGPIPE, and under
# `set -o pipefail` the whole script dies at 141 having printed only half its
# report. Take the first match with head instead, and tolerate no match at all.
CPU=$(adb shell top -n 1 -b 2>/dev/null | tr -d '\r' \
      | awk -v p="$PKG" '$0 ~ p {print $9}' | head -1 || true)
say "app cpu" "${CPU:-unknown}%"
echo "                           idle + resumed + screen on = a real finding."
echo "                           busy = still working; wait before judging."

echo
if [ "$FAIL" -eq 0 ]; then
  echo "VERDICT: environment is clean. Anything odd now is worth investigating."
else
  echo "VERDICT: environment is NOT clean. Fix the above before filing anything."
  exit 1
fi
