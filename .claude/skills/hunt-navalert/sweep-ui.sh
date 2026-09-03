#!/usr/bin/env bash
# Capture every top-level screen, so a sweep cannot silently skip one.
#
# WHY MECHANICAL: the first sweep of this app was driven by whatever the hunter
# thought of next, and it missed the alarm-escalation bug entirely — it only
# surfaced when someone asked for a second pass. An enumerated walk cannot get
# bored or distracted.
#
# Tab positions are COMPUTED from the device size, not hardcoded. The five shell
# tabs sit in equal slots above the navigation bar; a fixed y from another device
# lands on the system bar and silently does nothing.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG=ph.edu.pup.navalert
: "${HUNT_DIR:=/tmp/navalert-hunt-$(date +%H%M%S)}"
export HUNT_DIR
mkdir -p "$HUNT_DIR"

adb devices | grep -qE 'emulator-[0-9]+\s+device' || { echo "ERROR: no device" >&2; exit 1; }

SIZE=$(adb shell wm size | tr -d '\r' | awk -F': ' '{print $2}')
W=${SIZE%x*}; H=${SIZE#*x}
# The bottom navigation sits just above the system bar. Measured against this
# project's 1080x2400 reference (tabs at y=2196 of 2400) and expressed as a
# ratio so it survives a different panel.
TAB_Y=$(awk -v h="$H" 'BEGIN{printf "%d", h*0.915}')
tab_x() { awk -v w="$W" -v i="$1" 'BEGIN{printf "%d", w*(2*i+1)/10}'; }

shot() { "$HERE/shot.sh" "$1" >/dev/null; echo "  captured $1"; }

echo "device ${W}x${H}  tabs at y=$TAB_Y  -> $HUNT_DIR"
adb shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1
sleep 8

# The SOS warning dialog greets a cold launch; dismiss it so it does not sit on
# top of every capture below.
adb shell input tap $((W/2)) $((H*53/100)) >/dev/null 2>&1 || true
sleep 2

i=0
for name in history favorites home emergency settings; do
  adb shell input tap "$(tab_x $i)" "$TAB_Y"
  sleep 4
  shot "tab-$name"
  i=$((i+1))
done

# Settings is the only tab that scrolls past one screen.
adb shell input tap "$(tab_x 4)" "$TAB_Y"; sleep 3
adb shell input swipe $((W/2)) $((H*75/100)) $((W/2)) $((H*25/100)) 500; sleep 2
adb shell input swipe $((W/2)) $((H*75/100)) $((W/2)) $((H*30/100)) 500; sleep 3
shot "tab-settings-bottom"

cat <<NOTE

captured the five tabs and the settings tail into:
  $HUNT_DIR

READ EVERY ONE before going further — look for anything clipped by the
navigation bar, text overflowing its card, or a control that is drawn but
unreachable. Then drive the flows that need state, which cannot be walked
blind because their button positions move between builds:

  search -> suggestions -> commute guide -> trip settings
  monitoring with the alarm ON, and with it OFF
  live map, alarm stages 1/2/3, overshoot prompt + confirmation, arrival
  pin-on-map, add favourite, emergency contacts, fake call

Screenshot before each tap. See SKILL.md.
NOTE
