#!/usr/bin/env bash
# Runtime belt-and-suspenders: move the emulator's Utility toolbar window
# off-screen NOW (the persistent KWin rule does this at window-map, but launching
# the app can raise the toolbar back, so run this AFTER the app is launched).
# Minimize does NOT work on this window (it un-minimizes itself); moving it
# off-screen does. KDE-only; no-ops elsewhere. Safe to re-run.
set -uo pipefail

command -v gdbus >/dev/null 2>&1 || { echo "hide-toolbar: no gdbus (not KDE) — skipping"; exit 0; }

S="$(mktemp --suffix=.js)"
cat > "$S" <<'JS'
var list = (typeof workspace.windowList === 'function') ? workspace.windowList() : workspace.clientList();
for (var i = 0; i < list.length; i++) {
  var w = list[i];
  if (w.resourceClass === "Emulator" && w.windowType === 8) {   // 8 = Utility = the toolbar
    try { w.frameGeometry = { x: -2000, y: 0, width: 100, height: 510 }; } catch (e) {}
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
echo "hide-toolbar: done"
