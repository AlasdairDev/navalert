#!/usr/bin/env bash
# Run a KWin JS snippet ONCE, under a stable plugin name, and unload it after.
#
# Why: these helpers used to call Scripting.loadScript() with a fresh mktemp name
# every invocation and never unload. Scripts accumulate in the compositor (56 were
# live after ~10 minutes of use), and results become erratic/stale. Reusing one
# plugin name and unloading on both sides keeps each run isolated.
#
# usage: kwin-run.sh <file.js> [grep-marker]   # echoes the marker line, if any
set -uo pipefail
JS="$1"; MARK="${2:-}"
NAME="${KWIN_RUN_NAME:-navalert-oneshot}"
DEST=(--session --dest org.kde.KWin --object-path /Scripting --method org.kde.kwin.Scripting)
gdbus call "${DEST[@]}".unloadScript "$NAME" >/dev/null 2>&1
gdbus call "${DEST[@]}".loadScript "$JS" "$NAME" >/dev/null 2>&1
gdbus call "${DEST[@]}".start >/dev/null 2>&1
sleep 0.6
if [ -n "$MARK" ]; then
  journalctl --user _COMM=kwin_wayland --no-pager --since '5 seconds ago' 2>/dev/null \
    | grep -oE "$MARK.*" | tail -1
fi
gdbus call "${DEST[@]}".unloadScript