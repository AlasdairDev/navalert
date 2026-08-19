#!/usr/bin/env bash
# Make sure Kröhnkite (the KWin tiling script) floats the emulator instead of
# tiling/snapping it to a left tile. Two parts:
#   1. Ensure "Emulator" is in Kröhnkite's ignoreClass (idempotent).
#   2. FULLY reload Kröhnkite — a running instance keeps a STALE ignoreClass, and
#      `reconfigure` alone does NOT reload it, so the emulator gets snapped to the
#      left (e.g. when the screenshot tool opens a window) until Kröhnkite restarts.
# KDE-only; no-ops elsewhere. Skips the (disruptive) reload if Kröhnkite isn't
# configured. Reloading briefly re-tiles your other windows — that's expected.
set -uo pipefail

command -v kreadconfig6 >/dev/null 2>&1 || { echo "krohnkite: not KDE — skipping"; exit 0; }
cur="$(kreadconfig6 --file kwinrc --group Script-krohnkite --key ignoreClass 2>/dev/null || true)"
[ -z "$cur" ] && { echo "krohnkite: not configured — skipping"; exit 0; }

# Kröhnkite matches the emulator by its Wayland app_id "qemu-system-x86_64"
# (resourceName), NOT the resourceClass "Emulator" — so BOTH must be listed.
# Without qemu-system-x86_64, Kröhnkite tiles/snaps the emulator to a left tile.
for cls in Emulator qemu-system-x86_64; do
  case ",$cur," in
    *,"$cls",*) ;;                                                # already present
    *) cur="${cur},$cls"; kwriteconfig6 --file kwinrc --group Script-krohnkite --key ignoreClass "$cur" ;;
  esac
done

# Full restart so the live instance re-reads ignoreClass.
kwriteconfig6 --file kwinrc --group Plugins --key krohnkiteEnabled false
qdbus-qt6 org.kde.KWin /KWin org.kde.KWin.reconfigure 2>/dev/null || true
gdbus call --session --dest org.kde.KWin --object-path /Scripting \
  --method org.kde.kwin.Scripting.unloadScript "krohnkite" >/dev/null 2>&1 || true
kwriteconfig6 --file kwinrc --group Plugins --key krohnkiteEnabled true
qdbus-qt6 org.kde.KWin /KWin org.kde.KWin.reconfigure 2>/dev/null || true
qdbus-qt6 org.kde.KWin /KWin org.kde.KWin.reconfigure 2>/dev/null || true   # 2nd tick loads it
echo "krohnkite: emulator ignored + reloaded"
