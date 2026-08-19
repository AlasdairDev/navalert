#!/usr/bin/env bash
# Arrange the emulator windows after launch (run AFTER the app is launched — the
# launch raises/replaces the windows). Two jobs, KDE/KWin only, no-ops elsewhere:
#   1. Move the Utility toolbar window OFF-SCREEN (the persistent rule does this at
#      window-map, but launching can bring it back). Minimize does NOT stick on this
#      window; off-screen position does.
#   2. Dock the device window to the RIGHT side of the screen, fully on-screen so its
#      title bar (drag/close) is reachable. Position is computed from the screen
#      width, so it works at any resolution. This only sets the position — you can
#      still drag it anywhere afterward.
set -uo pipefail

command -v gdbus >/dev/null 2>&1 || { echo "arrange: no gdbus (not KDE) — skipping"; exit 0; }

S="$(mktemp --suffix=.js)"
cat > "$S" <<'JS'
var list = (typeof workspace.windowList === 'function') ? workspace.windowList() : workspace.clientList();
// screen bounds (fall back to 1670x939 logical if unavailable)
var geo = { x: 0, y: 0, width: 1670, height: 939 };
try { if (workspace.screens && workspace.screens.length) geo = workspace.screens[0].geometry; } catch (e) {}
var margin = 12;
var dw = 420, dh = 860;
for (var i = 0; i < list.length; i++) {
  var w = list[i];
  if (w.resourceClass !== "Emulator") continue;
  if (w.windowType === 8) {                 // Utility = the toolbar -> off-screen
    try { w.frameGeometry = { x: -2000, y: 0, width: 100, height: 510 }; } catch (e) {}
  } else if (w.windowType === 0) {          // Normal = the device -> flush right, on-screen
    try {
      w.frameGeometry = {
        x: geo.x + geo.width - dw - margin,
        y: geo.y + margin,
        width: dw, height: dh
      };
    } catch (e) {}
  }
}
JS

for attempt in 1 2 3; do
  gdbus call --session --dest org.kde.KWin --object-path /Scripting \
    --method org.kde.kwin.Scripting.loadScript "$S" >/dev/null 2>&1 || true
  gdbus call --session --dest org.kde.KWin --object-path /Scripting \
    --method org.kde.kwin.Scripting.start >/dev/null 2>&1 || true
  sleep 1
done
rm -f "$S"
echo "arrange: toolbar off-screen, device docked right"
