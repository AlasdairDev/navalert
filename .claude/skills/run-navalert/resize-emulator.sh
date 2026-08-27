#!/usr/bin/env bash
# Resize the Android emulator device window WITHOUT the size-shifting jitter.
#
# Why this exists: the emulator's bundled Qt has only the `xcb` platform plugin,
# so it is always an XWayland client. This display runs a FRACTIONAL scale
# (1.15 = 23/20), and XWayland converts logical->device pixels by rounding.
# Only logical sizes that are multiples of the scale denominator (20 here) map to
# an exact device-pixel size; everything in between rounds NON-MONOTONICALLY --
# measured: logical width 503->568px, 504->570px (skips 569), 509->575, 510->577.
# Dragging a window edge therefore steps the client buffer unevenly by 1-2px and
# the device framebuffer re-letterboxes on every step: the "shifting sizes" bug.
# Krohnkite is NOT involved (ignoreClass already lists Emulator, and programmatic
# geometry is stable across repeated trials).
#
# Fix: only ever set sizes that are multiples of the scale denominator, and derive
# the width from the device aspect ratio so the phone fills the frame exactly.
#
# Usage:  resize-emulator.sh [fill|large|medium|small|<height-in-logical-px>]
# KDE/KWin only; no-ops elsewhere.
set -uo pipefail
MODE="${1:-fill}"
command -v gdbus >/dev/null 2>&1 || { echo "resize: no gdbus (not KDE) — skipping"; exit 0; }

# --- device aspect (from the running device, falls back to a 1080x2400 phone) ---
DEV="$(adb shell wm size 2>/dev/null | tr -d '\r' | grep -oE '[0-9]+x[0-9]+' | tail -1)"
DEV_W="${DEV%x*}"; DEV_H="${DEV#*x}"
[ -n "${DEV_W:-}" ] && [ -n "${DEV_H:-}" ] || { DEV_W=1080; DEV_H=2400; }

# --- display scale -> snap unit (denominator of the scale as a reduced fraction) ---
SCALE="$(kscreen-doctor -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -oE 'Scale:[[:space:]]*[0-9.]+' | grep -oE '[0-9.]+' | head -1)"
[ -n "${SCALE:-}" ] || SCALE=1
SNAP="$(awk -v s="$SCALE" 'BEGIN{
  for(q=1;q<=64;q++){v=s*q; if(v-int(v)<1e-6||int(v)+1-v<1e-6){print q; exit}}
  print 1}')"

echo "resize: device=${DEV_W}x${DEV_H} scale=${SCALE} snap=${SNAP}px mode=${MODE}"

S="$(mktemp --suffix=.js)"
cat > "$S" <<JS
var SNAP=${SNAP}, ASPECT=${DEV_W}/${DEV_H}, MODE="${MODE}";
var l=(typeof workspace.windowList==='function')?workspace.windowList():workspace.clientList();
var win=null;
for(var i=0;i<l.length;i++){var w=l[i];if(w.resourceClass==="Emulator"&&w.windowType===0){win=w;}}
if(win){
  var ca=workspace.clientArea(0, workspace.activeScreen, workspace.currentDesktop);
  // exact decoration overhead (titlebar + borders) in logical px
  var dW=0,dH=0;
  try{dW=win.frameGeometry.width-win.clientGeometry.width; dH=win.frameGeometry.height-win.clientGeometry.height;}catch(e){}
  if(!(dW>=0)||dW>200)dW=9; if(!(dH>=0)||dH>200)dH=29;

  var frac={fill:1.0,large:0.85,medium:0.7,small:0.55}[MODE];
  var H0;
  if(frac){ H0=ca.height*frac; } else { H0=parseFloat(MODE); if(!(H0>0)) H0=ca.height; }
  if(H0>ca.height) H0=ca.height;
  H0=Math.floor(H0/SNAP)*SNAP;

  // Both dimensions MUST be multiples of SNAP or the fractional scale rounds and
  // the window jitters. That leaves the aspect ratio slightly off, so try a few
  // heights near the target and keep whichever makes the snapped width land
  // closest to the exact device aspect (smallest letterbox).
  var H=H0, W=0, best=1e9;
  for(var k=0;k<=3;k++){
    var hc=H0-k*SNAP; if(hc<3*SNAP) continue;
    var ideal=(hc-dH)*ASPECT+dW;
    var wc=Math.round(ideal/SNAP)*SNAP;
    if(wc<SNAP||wc>ca.width) continue;
    var err=Math.abs(wc-ideal)/ideal + k*0.004;   // tiny bias toward the larger height
    if(err<best){ best=err; H=hc; W=wc; }
  }
  if(!W){ H=H0; W=Math.round(((H-dH)*ASPECT+dW)/SNAP)*SNAP; }
  if(W>ca.width){ W=Math.floor(ca.width/SNAP)*SNAP; }

  var x=Math.round(ca.x+ca.width-W-SNAP);          // park on the right, still draggable
  var y=Math.round(ca.y+(ca.height-H)/2);
  if(x<ca.x)x=ca.x; if(y<ca.y)y=ca.y;
  try{win.noBorder=false;}catch(e){}                // keep the titlebar for dragging
  win.frameGeometry={x:x,y:y,width:W,height:H};
  throw new Error("R>>> "+W+"x"+H+" at "+x+","+y+" deco="+dW+"x"+dH);
}
throw new Error("R>>> no-emulator-window");
JS
res="$("$(dirname "$0")/kwin-run.sh" "$S" 'R>>>')"
rm -f "$S"

# Report what actually happened. This used to be captured and silently dropped,
# so a failed resize looked identical to a successful one.
case "$res" in
  *no-emulator-window*) echo "resize: no emulator device window found — is it running?"; exit 1 ;;
  R\>\>\>*)             echo "resize: applied ${res#R>>> }" ;;
  *)                    echo "resize: FAILED (no reply from KWin)"; exit 1 ;;
esac