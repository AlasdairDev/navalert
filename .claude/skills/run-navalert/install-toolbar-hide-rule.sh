#!/usr/bin/env bash
# Install a PERSISTENT KWin window rule that force-moves the Android emulator's
# separate control-toolbar window OFF-SCREEN, so the emulator shows as one clean
# phone window. (You navigate with the phone's own on-screen 3-button nav — see
# the nav-mode step in the skill — so the side toolbar isn't needed.)
#
# Why off-screen and not minimize: the toolbar is a Utility-type window that
# REFUSES to stay minimized (KWin/Qt immediately un-minimizes it). Forcing an
# off-screen position sticks. Match on window TYPE (Utility=256) + class
# "Emulator", NOT title — at boot both emulator windows briefly share the title
# "Emulator", so a title match would move the device window off-screen too.
#
# Idempotent; KDE-only (no-ops elsewhere); machine-local (~/.config/kwinrulesrc).
set -uo pipefail

command -v kwriteconfig6 >/dev/null 2>&1 || { echo "install-rule: no kwriteconfig6 (not KDE) — skipping"; exit 0; }

MARKER="NavAlert: hide Android emulator toolbar"
RC="$HOME/.config/kwinrulesrc"

if grep -q "$MARKER" "$RC" 2>/dev/null; then
  echo "install-rule: already installed"
  exit 0
fi

uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
current="$(kreadconfig6 --file kwinrulesrc --group General --key rules 2>/dev/null || true)"
count="$(kreadconfig6 --file kwinrulesrc --group General --key count 2>/dev/null || echo 0)"
[ -n "$count" ] || count=0

kwriteconfig6 --file kwinrulesrc --group General --key rules "${current:+$current,}$uuid"
kwriteconfig6 --file kwinrulesrc --group General --key count "$((count + 1))"

kwriteconfig6 --file kwinrulesrc --group "$uuid" --key Description "$MARKER (Utility window)"
kwriteconfig6 --file kwinrulesrc --group "$uuid" --key wmclass "Emulator"
kwriteconfig6 --file kwinrulesrc --group "$uuid" --key wmclasscomplete false
kwriteconfig6 --file kwinrulesrc --group "$uuid" --key wmclassmatch 1
kwriteconfig6 --file kwinrulesrc --group "$uuid" --key titlematch 0
kwriteconfig6 --file kwinrulesrc --group "$uuid" --key types 256          # NET::UtilityMask -> only the toolbar
kwriteconfig6 --file kwinrulesrc --group "$uuid" --key position -- "-2000,0"  # force off-screen
kwriteconfig6 --file kwinrulesrc --group "$uuid" --key positionrule 2      # 2 = Force
kwriteconfig6 --file kwinrulesrc --group "$uuid" --key skiptaskbar true
kwriteconfig6 --file kwinrulesrc --group "$uuid" --key skiptaskbarrule 2
kwriteconfig6 --file kwinrulesrc --group "$uuid" --key skipswitcher true
kwriteconfig6 --file kwinrulesrc --group "$uuid" --key skipswitcherrule 2
kwriteconfig6 --file kwinrulesrc --group "$uuid" --key skippager true
kwriteconfig6 --file kwinrulesrc --group "$uuid" --key skippagerrule 2

qdbus-qt6 org.kde.KWin /KWin org.kde.KWin.reconfigure 2>/dev/null \
  || qdbus org.kde.KWin /KWin org.kde.KWin.reconfigure 2>/dev/null || true
echo "install-rule: installed (uuid $uuid)"
