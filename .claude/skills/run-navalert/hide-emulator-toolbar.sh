#!/usr/bin/env bash
# Arrange the emulator windows after launch (run AFTER the app is launched — the
# launch raises/replaces the windows). KDE/KWin only, no-ops elsewhere:
#   1. Move the Utility toolbar window OFF-SCREEN (minimize doesn't stick on it).
#   2. Size the device window to FIT the screen height (the phone's tall aspect
#      ratio otherwise makes it exceed the screen, cutting off the top), and dock
#      it flush to the RIGHT edge, fully on-screen. Height is derived from the
#      screen; width from the phone aspect (1080:2400) so the emulator doesn't
#      fight the size. Position/size only — still freely draggable/resizable.
set -uo pipefail

command -v gdbus >/dev/null 2>&1 || { echo "arrange: no gdbus (not KDE) — skipping"; exit 0; }

S="$(mktemp --suffix=.js)"
cat > "$S" <<'JS'
var list = (typeof workspace.windowList === 'function') ? workspace.windowList() : workspace.clientList();
var geo = { x: 0, y: 0, width: 1670, height: 939 };
try { if (workspace.screens && workspace.screens.length) geo = workspace.screens[0].geometry; } catch (e) {}

var vMargin = 30, hMargin = 12, titleBar = 40;
var frameH = geo.height - vMargin * 2;                 // fit within screen height
var contentH = frameH - titleBar;
var frameW = Math.round(contentH * 1080 / 2400);       // phone aspect -> width

for (var i = 0; i < list.length; i++) {
  var w = list[i];
  if (w.resourceClass !== "Emulator") continue;
  if (w.windowType === 8) {                 // Utility = toolbar -> off-screen
    try { w.frameGeometry = { x: -2000, y: 0, width: 100, height: 510 }; } catch (e) {}
  } else if (w.windowType === 0) {          // Normal = device -> fit + dock right
    try {
      w.frameGeometry = {
        x: geo.x + geo.width - frameW - hMargin,
        y: geo.y + vMargin,
        width: frameW, height: frameH
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
echo "arrange: toolbar off-screen, device fit + docked right"
