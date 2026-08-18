#!/usr/bin/env bash
# Hide the Android emulator's *separate* control-toolbar window on KDE/KWin so the
# emulator shows as one clean phone window (no detached "doubled" bar).
#
# The emulator always opens TWO windows, both resourceClass "Emulator":
#   - caption "Android Emulator - Pixel_6:5554"  -> the device screen (keep)
#   - caption "Emulator"                          -> the toolbar (minimize)
# This is runtime-only and KDE-specific; it no-ops cleanly on non-KDE hosts.
# Safe to re-run. Retries because the toolbar window can appear a moment after boot.
set -uo pipefail

command -v gdbus >/dev/null 2>&1 || { echo "hide-toolbar: no gdbus (not KDE) — skipping"; exit 0; }

S="$(mktemp --suffix=.js)"
cat > "$S" <<'JS'
var list = (typeof workspace.windowList === 'function') ? workspace.windowList() : workspace.clientList();
for (var i = 0; i < list.length; i++) {
  var w = list[i];
  if (w.resourceClass === "Emulator" && w.caption === "Emulator") {
    try { w.minimized = true; } catch (e) {}
  }
}
JS

for attempt in 1 2 3 4 5; do
  gdbus call --session --dest org.kde.KWin --object-path /Scripting \
    --method org.kde.kwin.Scripting.loadScript "$S" >/dev/null 2>&1 || true
  gdbus call --session --dest org.kde.KWin --object-path /Scripting \
    --method org.kde.kwin.Scripting.start >/dev/null 2>&1 || true
  sleep 1
done
rm -f "$S"
echo "hide-toolbar: done"
