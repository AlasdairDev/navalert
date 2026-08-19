#!/usr/bin/env bash
# Install a PERSISTENT KWin window rule that hides the Android emulator's
# separate toolbar window (a Utility-type window, NET::Utility) so the emulator
# shows as one clean phone window on every launch — no detached "doubled" bar.
#
# Why a rule and not a runtime minimize: the emulator re-creates/re-shows the
# toolbar, so minimizing it via script doesn't stick. A forced KWin rule
# re-applies at every window map. We match on window TYPE (Utility=256) + class
# "Emulator", NOT on title — at boot BOTH emulator windows briefly share the
# title "Emulator", so a title match would wrongly hide the device window too.
#
# Idempotent: does nothing if the rule is already present. KDE-only; no-ops
# elsewhere. Machine-local (lives in ~/.config/kwinrulesrc, not in the repo).
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
kwriteconfig6 --file kwinrulesrc --group "$uuid" --key minimize true
kwriteconfig6 --file kwinrulesrc --group "$uuid" --key minimizerule 2     # 2 = Force
kwriteconfig6 --file kwinrulesrc --group "$uuid" --key skiptaskbar true
kwriteconfig6 --file kwinrulesrc --group "$uuid" --key skiptaskbarrule 2
kwriteconfig6 --file kwinrulesrc --group "$uuid" --key skipswitcher true
kwriteconfig6 --file kwinrulesrc --group "$uuid" --key skipswitcherrule 2
kwriteconfig6 --file kwinrulesrc --group "$uuid" --key skippager true
kwriteconfig6 --file kwinrulesrc --group "$uuid" --key skippagerrule 2

qdbus-qt6 org.kde.KWin /KWin org.kde.KWin.reconfigure 2>/dev/null \
  || qdbus org.kde.KWin /KWin org.kde.KWin.reconfigure 2>/dev/null || true
echo "install-rule: installed (uuid $uuid)"
