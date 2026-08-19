#!/usr/bin/env bash
# Arrange the emulator windows after launch (run AFTER the app is launched — the
# launch raises/replaces the windows). Two jobs, KDE/KWin only, no-ops elsewhere:
#   1. Move the Utility toolbar window OFF-SCREEN (the persistent rule does this at
#      window-map, but launching can bring it back). Minimize does NOT stick on this
#      window; off-screen position does.
#   2. Move the device window to a fully-visible spot so its title bar is on-screen
#      and you can DRAG it. The emulator otherwise tends to open it with the title
#      bar above the top edge (ungrabbable). This only sets the position — you can
#      still drag it anywhere afterward.
# Screen here is 1670x939 logical; device placed at 1150,40 (right side, on-screen).
set -uo pipefail

command -v gdbus >/dev/null 2>&1 || { echo "arrange: no gdbus (not KDE) — skipping"; exit 0; }

S="$(mktemp --suffix=.js)"
cat > "$S" <<'JS'
var list = (typeof workspace.windowList === 'function') ? workspace.windowList() : workspace.clientList();
for (var i = 0; i < list.length; i++) {
  var w = list[i];
  if (w.resourceClass !== "Emulator") continue;
  if (w.windowType === 8) {                 // Utility = the toolbar -> off-screen
    try { w.frameGeometry = { x: -2000, y: 0, width: 100, height: 510 }; } catch (e) {}
  } else if (w.windowType === 0) {          // Normal = the device -> fully on-screen
    try { w.frameGeometry = { x: 1150, y: 40, width: 420, height: 860 }; } catch (e) {}
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
echo "arrange: toolbar off-screen, device on-screen"
