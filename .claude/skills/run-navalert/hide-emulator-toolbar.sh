#!/usr/bin/env bash
# Runtime belt-and-suspenders (run AFTER the app is launched — launching can raise
# the toolbar back): move the emulator's Utility toolbar window OFF-SCREEN. The
# persistent KWin rule does this at window-map too, but the runtime pass catches
# it if launching brought it forward. Minimize does NOT stick on this window;
# off-screen position does. The device window is handled by its own Force rule
# (see install-toolbar-hide-rule.sh) — nothing to do here for it.
# KDE-only; no-ops elsewhere. Safe to re-run.
set -uo pipefail

command -v gdbus >/dev/null 2>&1 || { echo "hide-toolbar: no gdbus (not KDE) — skipping"; exit 0; }

S="$(mktemp --suffix=.js)"
cat > "$S" <<'JS'
var list = (typeof workspace.windowList === 'function') ? workspace.windowList() : workspace.clientList();
for (var i = 0; i < list.length; i++) {
  var w = list[i];
  if (w.resourceClass === "Emulator" && w.windowType === 8) {   // 8 = Utility = toolbar
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
