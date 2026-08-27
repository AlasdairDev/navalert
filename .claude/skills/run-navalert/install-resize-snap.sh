#!/usr/bin/env bash
# Install a persistent KWin script that snaps the emulator window to a clean size
# whenever you FINISH dragging its edge.
#
# Root cause it addresses: the emulator's bundled Qt ships only the `xcb` platform
# plugin, so it is always an XWayland client. On a fractional display scale
# (here 1.15 = 23/20) XWayland rounds logical->device pixels, and only logical
# sizes that are multiples of the scale denominator (20) convert exactly. In
# between, the rounding is non-monotonic -- measured: logical width 503->568 dev,
# 504->570 (skips 569), 509->575, 510->577. So a smooth one-pixel drag moves the
# client buffer in uneven 1-2px steps and the device framebuffer re-letterboxes on
# every step: the "window shifts sizes" bug.
#
# This script cannot make the drag itself smooth (that is inherent to XWayland +
# fractional scaling), but it guarantees the size you END UP with is exact and
# keeps the phone's aspect ratio. Uninstall: install-resize-snap.sh --remove
set -uo pipefail
ID="navalert-emu-snap"
DIR="$HOME/.local/share/kwin/scripts/$ID"
reconfigure(){ gdbus call --session --dest org.kde.KWin --object-path /KWin \
  --method org.kde.KWin.reconfigure >/dev/null 2>&1 || true; }

if [ "${1:-}" = "--remove" ]; then
  kwriteconfig6 --file kwinrc --group Plugins --key "${ID}Enabled" false 2>/dev/null
  rm -rf "$DIR"; reconfigure; echo "snap: removed"; exit 0
fi
command -v kwriteconfig6 >/dev/null 2>&1 || { echo "snap: not KDE — skipping"; exit 0; }

DEV="$(adb shell wm size 2>/dev/null | tr -d '\r' | grep -oE '[0-9]+x[0-9]+' | tail -1)"
DEV_W="${DEV%x*}"; DEV_H="${DEV#*x}"
[ -n "${DEV_W:-}" ] && [ -n "${DEV_H:-}" ] || { DEV_W=1080; DEV_H=2400; }
SCALE="$(kscreen-doctor -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -oE 'Scale:[[:space:]]*[0-9.]+' | grep -oE '[0-9.]+' | head -1)"
[ -n "${SCALE:-}" ] || SCALE=1
SNAP="$(awk -v s="$SCALE" 'BEGIN{for(q=1;q<=64;q++){v=s*q;if(v-int(v)<1e-6||int(v)+1-v<1e-6){print q;exit}}print 1}')"

mkdir -p "$DIR/contents/code"
cat > "$DIR/metadata.json" <<META
{ "KPackageStructure": "KWin/Script",
  "KPlugin": {
    "Id": "$ID",
    "Name": "NavAlert emulator resize snap",
    "Description": "Snaps the Android emulator window to an exact fractional-scale size after resizing",
    "EnabledByDefault": true },
  "X-Plasma-API": "javascript",
  "X-Plasma-MainScript": "code/main.js" }
META
cat > "$DIR/contents/code/main.js" <<JS
var SNAP=$SNAP, ASPECT=$DEV_W/$DEV_H, DW=8.7, DH=28.7;

function isEmu(w){ try{ return w && w.resourceClass==="Emulator" && w.windowType===0; }catch(e){ return false; } }
function area(w){
  try{ return workspace.clientArea(0, w.output || workspace.activeScreen, workspace.currentDesktop); }
  catch(e){ try{ return workspace.clientArea(0, workspace.activeScreen, workspace.currentDesktop); }catch(e2){ return null; } }
}
function deco(w){
  try{ var f=w.frameGeometry,c=w.clientGeometry;
       var dw=f.width-c.width, dh=f.height-c.height;
       if(dw>=0&&dw<200&&dh>=0&&dh<200) return {w:dw,h:dh}; }catch(e){}
  return {w:DW,h:DH};
}
// A size is only free of fractional-scale rounding if both dims are multiples of SNAP.
function cleanSize(w,h){
  var ca=area(w), d=deco(w);
  var H=Math.round(h/SNAP)*SNAP;
  if(ca && H>ca.height) H=Math.floor(ca.height/SNAP)*SNAP;
  if(H<3*SNAP) H=3*SNAP;
  var W=Math.round(((H-d.h)*ASPECT+d.w)/SNAP)*SNAP;
  if(W<SNAP) W=SNAP;
  if(ca && W>ca.width) W=Math.floor(ca.width/SNAP)*SNAP;
  return {w:W,h:H};
}
function apply(w,W,H){
  var f=w.frameGeometry, ca=area(w);
  var x=Math.round(f.x), y=Math.round(f.y);
  if(ca){ if(x+W>ca.x+ca.width) x=ca.x+ca.width-W;
          if(y+H>ca.y+ca.height) y=ca.y+ca.height-H;
          if(x<ca.x) x=ca.x; if(y<ca.y) y=ca.y; }
  try{ w.tile=null; }catch(e){}                       // drop any tile KWin assigned
  if(f.width===W && f.height===H && f.x===x && f.y===y) return;
  w.frameGeometry={x:x,y:y,width:W,height:H};
}
function hook(w){
  if(!isEmu(w)) return;
  var st={w:0,h:0,resize:false,armed:false};
  // KWin's own tiling (custom tile zones + drag-to-edge) grabs this window when you
  // drop it near an edge and resizes it to the tile -- 835x911, 835x456, ... That is
  // what makes a plain DRAG randomly change the size. The emulator has a fixed device
  // aspect and must never be tiled, so drop any tile KWin assigns.
  function untile(){ try{ if(w.tile) w.tile=null; }catch(e){} }
  try{ w.tileChanged.connect(untile); }catch(e){}
  try{ w.quickTileModeChanged.connect(untile); }catch(e){}
  try{ w.interactiveMoveResizeStarted.connect(function(){
        var f=w.frameGeometry; st.w=f.width; st.h=f.height; st.armed=true;
        st.resize=false; try{ st.resize=!!w.resize; }catch(e){}
      }); }catch(e){}
  try{ w.interactiveMoveResizeFinished.connect(function(){
        var f=w.frameGeometry;
        untile();
        if(!st.armed || st.w<=0) return;
        st.armed=false;
        if(st.resize){
          // real edge-resize: land on a rounding-free, aspect-correct size
          var g=cleanSize(w, f.height); apply(w, g.w, g.h);
        } else if(f.width!==st.w || f.height!==st.h){
          // a plain drag must NEVER change the size -- put it back
          apply(w, st.w, st.h);
        }
      }); }catch(e){}
}
var list=(typeof workspace.windowList==='function')?workspace.windowList():workspace.clientList();
for(var i=0;i<list.length;i++) hook(list[i]);
workspace.windowAdded.connect(hook);
JS

kwriteconfig6 --file kwinrc --group Plugins --key "${ID}Enabled" true
reconfigure
sleep 1
echo "snap: installed (snap=${SNAP}px, aspect=${DEV_W}x${DEV_H})"
echo "snap: enabled=$(kreadconfig6 --file kwinrc --group Plugins --key "${ID}Enabled")"
