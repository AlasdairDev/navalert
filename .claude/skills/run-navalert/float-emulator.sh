#!/usr/bin/env bash
# Make the emulator a free-floating, DRAGGABLE window (like a dialog/popup) that
# Kröhnkite won't tile or snap to the left. Kröhnkite's ignoreClass does NOT match
# the emulator on this Wayland setup (it reads the window class too early), but its
# per-window "Toggle Float" action does work — so we focus the emulator and fire
# that action at it. Run once after launch. A guard checks the window is currently
# TILED (near the left edge) before toggling, so re-running never un-floats it.
# KDE/Kröhnkite only; no-ops elsewhere.
set -uo pipefail
command -v gdbus     >/dev/null 2>&1 || { echo "float: no gdbus (not KDE) — skipping"; exit 0; }
command -v qdbus-qt6 >/dev/null 2>&1 || { echo "float: no qdbus-qt6 — skipping"; exit 0; }

probe_x() {
  local S; S="$(mktemp --suffix=.js)"
  cat > "$S" <<'JS'
var l=(typeof workspace.windowList==='function')?workspace.windowList():workspace.clientList();
for(var i=0;i<l.length;i++){var w=l[i];if(w.resourceClass==="Emulator"&&w.windowType===0){throw new Error("X>>> "+Math.round(w.frameGeometry.x));}}
throw new Error("X>>> none");
JS
  gdbus call --session --dest org.kde.KWin --object-path /Scripting --method org.kde.kwin.Scripting.loadScript "$S" >/dev/null 2>&1
  gdbus call --session --dest org.kde.KWin --object-path /Scripting --method org.kde.kwin.Scripting.start >/dev/null 2>&1
  rm -f "$S"
  journalctl --user _COMM=kwin_wayland --no-pager --since '3 seconds ago' 2>/dev/null | grep -oE 'X>>> -?[0-9]+' | tail -1 | awk '{print $2}'
}

# focus the emulator device window
S="$(mktemp --suffix=.js)"
cat > "$S" <<'JS'
var l=(typeof workspace.windowList==='function')?workspace.windowList():workspace.clientList();
for(var i=0;i<l.length;i++){var w=l[i];if(w.resourceClass==="Emulator"&&w.windowType===0){workspace.activeWindow=w;}}
JS
gdbus call --session --dest org.kde.KWin --object-path /Scripting --method org.kde.kwin.Scripting.loadScript "$S" >/dev/null 2>&1
gdbus call --session --dest org.kde.KWin --object-path /Scripting --method org.kde.kwin.Scripting.start >/dev/null 2>&1
rm -f "$S"

# only toggle-float if it's currently tiled (near the left edge)
x="$(probe_x || echo '')"
if [ -n "$x" ] && [ "$x" != "none" ] && [ "$x" -lt 100 ] 2>/dev/null; then
  qdbus-qt6 org.kde.kglobalaccel /component/kwin invokeShortcut KrohnkiteToggleFloat >/dev/null 2>&1 || true
  echo "float: toggled float (was tiled at x=$x)"
else
  echo "float: already floating (x=$x) — left as is"
fi

# Place it on one side of the screen, draggable afterward.
#
# LEFT by default. It used to be hard-coded right, which put the phone on top of
# whatever was over there — on this setup that is the editor. Override per run
# with EMU_SIDE=right, or pass `left`/`right` as the first argument.
SIDE="${EMU_SIDE:-left}"
case "${1:-}" in left|right) SIDE="$1" ;; esac
[ "$SIDE" = "left" ] || [ "$SIDE" = "right" ] || SIDE=left

S2="$(mktemp --suffix=.js)"
printf 'var SIDE=%s;\n' "\"$SIDE\"" > "$S2"
cat >> "$S2" <<'JS'
var l=(typeof workspace.windowList==='function')?workspace.windowList():workspace.clientList();
// Use the panel-aware work area so the whole phone fits on screen.
var geo={x:0,y:0,width:1670,height:939};
try{if(workspace.screens&&workspace.screens.length)geo=workspace.screens[0].geometry;}catch(e){}
try{var ca=workspace.clientArea(0, workspace.activeScreen, workspace.currentDesktop); if(ca&&ca.height){geo=ca;}}catch(e){}
var topM=14, botM=18, titleBar=38;
var frameH=Math.round(geo.height-topM-botM);              // fill the height
var frameW=Math.round((frameH-titleBar)*1080/2400);       // width from phone aspect
for(var i=0;i<l.length;i++){var w=l[i];if(w.resourceClass==="Emulator"&&w.windowType===0){
  try{w.noBorder=false;}catch(e){}   // ensure a title bar so it can be dragged/closed
  var fx = (SIDE==="left") ? Math.round(geo.x+14)
                          : Math.round(geo.x+geo.width-frameW-14);
  w.frameGeometry={x:fx,y:Math.round(geo.y+topM),width:frameW,height:frameH};
}}
JS
gdbus call --session --dest org.kde.KWin --object-path /Scripting --method org.kde.kwin.Scripting.loadScript "$S2" >/dev/null 2>&1
gdbus call --session --dest org.kde.KWin --object-path /Scripting --method org.kde.kwin.Scripting.start >/dev/null 2>&1
rm -f "$S2"
echo "float: placed on the $SIDE (draggable)"
