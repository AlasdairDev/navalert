#!/usr/bin/env bash
# Install PERSISTENT KWin window rules so the emulator behaves, every launch:
#   1. Toolbar (Utility window) forced OFF-SCREEN — the buggy white/black side bar.
#   2. Device (Normal window) FORCE-pinned docked-right, lowered, sized to fit the
#      screen. Force means nothing can move it — not Kröhnkite tiling, not your
#      screenshot tool (which otherwise snapped it to the left), not focus changes.
#      Trade-off: it can't be dragged; edit/remove the rule in System Settings ->
#      Window Rules if you want to move it.
# Match on window TYPE (Utility=256 / Normal=1) + class "Emulator", NOT title (both
# emulator windows briefly share the title "Emulator" at boot).
# Idempotent; KDE-only (no-ops elsewhere); machine-local (~/.config/kwinrulesrc).
set -uo pipefail

command -v kwriteconfig6 >/dev/null 2>&1 || { echo "install-rule: no kwriteconfig6 (not KDE) — skipping"; exit 0; }

MARKER="NavAlert: emulator window rules"
RC="$HOME/.config/kwinrulesrc"

if grep -q "$MARKER" "$RC" 2>/dev/null; then
  echo "install-rule: already installed"
  exit 0
fi

# --- work out a docked-right, on-screen position from the primary screen size ---
SW=1670; SH=939   # fallbacks (logical px)
if command -v gdbus >/dev/null 2>&1; then
  J="$(mktemp --suffix=.js)"
  cat > "$J" <<'JS'
var g = { width: 1670, height: 939 };
try { if (workspace.screens && workspace.screens.length) g = workspace.screens[0].geometry; } catch (e) {}
throw new Error("SCR>>> " + Math.round(g.width) + " " + Math.round(g.height));
JS
  gdbus call --session --dest org.kde.KWin --object-path /Scripting --method org.kde.kwin.Scripting.loadScript "$J" >/dev/null 2>&1 || true
  gdbus call --session --dest org.kde.KWin --object-path /Scripting --method org.kde.kwin.Scripting.start >/dev/null 2>&1 || true
  line="$(journalctl --user _COMM=kwin_wayland --no-pager --since '4 seconds ago' 2>/dev/null | grep -oE 'SCR>>> [0-9]+ [0-9]+' | tail -1)"
  rm -f "$J"
  [ -n "$line" ] && { SW="$(echo "$line" | awk '{print $2}')"; SH="$(echo "$line" | awk '{print $3}')"; }
fi
DH=$(( SH - 100 ));            [ "$DH" -gt 900 ] && DH=900   # device height fits screen
DW=$(( DH * 1080 / 2400 ));                                  # width from phone aspect
DX=$(( SW - DW - 15 ));                                       # dock right
DY=70                                                         # lowered from the top

add_rule() {  # $1=uuid $2..: key=value pairs
  local uuid="$1"; shift
  local cur cnt; cur="$(kreadconfig6 --file kwinrulesrc --group General --key rules 2>/dev/null || true)"
  cnt="$(kreadconfig6 --file kwinrulesrc --group General --key count 2>/dev/null || echo 0)"; [ -n "$cnt" ] || cnt=0
  kwriteconfig6 --file kwinrulesrc --group General --key rules "${cur:+$cur,}$uuid"
  kwriteconfig6 --file kwinrulesrc --group General --key count "$((cnt + 1))"
  local kv; for kv in "$@"; do kwriteconfig6 --file kwinrulesrc --group "$uuid" --key "${kv%%=*}" -- "${kv#*=}"; done
}

# 1. Toolbar -> off-screen
add_rule "$(cat /proc/sys/kernel/random/uuid)" \
  "Description=$MARKER (toolbar off-screen)" \
  "wmclass=Emulator" "wmclasscomplete=false" "wmclassmatch=1" "titlematch=0" \
  "types=256" "position=-2000,0" "positionrule=2" \
  "skiptaskbar=true" "skiptaskbarrule=2" "skipswitcher=true" "skipswitcherrule=2" \
  "skippager=true" "skippagerrule=2"

# 2. Device -> Force pinned docked-right, on-screen, fit
add_rule "$(cat /proc/sys/kernel/random/uuid)" \
  "Description=$MARKER (device pinned right)" \
  "wmclass=Emulator" "wmclasscomplete=false" "wmclassmatch=1" "titlematch=0" \
  "types=1" "position=$DX,$DY" "positionrule=2" "size=$DW,$DH" "sizerule=2"

qdbus-qt6 org.kde.KWin /KWin org.kde.KWin.reconfigure 2>/dev/null \
  || qdbus org.kde.KWin /KWin org.kde.KWin.reconfigure 2>/dev/null || true
echo "install-rule: installed (device ${DW}x${DH} @ ${DX},${DY} on ${SW}x${SH})"
