#!/usr/bin/env bash
# Boot the Pixel_6 emulator on the Linux dev host (Aurora DX / Fedora atomic).
# The -gpu host flag is mandatory: any software renderer (swiftshader/guest/angle,
# or headless -no-window) SIGSEGVs ~20s into boot inside SwiftShader's libGLESv2 JIT.
set -euo pipefail

AVD="${1:-Pixel_6}"
EMU="$HOME/Android/Sdk/emulator/emulator"
LOG="/tmp/navalert-emu.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Make sure the persistent toolbar-hide KWin rule is installed (idempotent).
"$SCRIPT_DIR/install-toolbar-hide-rule.sh" 2>/dev/null || true

# Already have a running emulator? Just make sure the toolbar stays hidden.
if adb devices | grep -qE 'emulator-[0-9]+\s+device'; then
  echo "Emulator already running:"; adb devices | grep emulator
  "$SCRIPT_DIR/hide-emulator-toolbar.sh" 2>/dev/null || true
  exit 0
fi

echo "Booting $AVD with -gpu host (log: $LOG) ..."
DISPLAY="${DISPLAY:-:0}" \
WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
  nohup "$EMU" -avd "$AVD" -no-snapshot -no-boot-anim -no-audio -gpu host \
  >"$LOG" 2>&1 &

adb wait-for-device
echo -n "Waiting for boot"
until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do
  if ! pgrep -f "qemu-system.*$AVD" >/dev/null && ! pgrep -f 'qemu-system' >/dev/null; then
    echo; echo "ERROR: emulator process died. Last log lines:"; tail -8 "$LOG"; exit 1
  fi
  echo -n .; sleep 3
done
echo; echo "Booted. $(adb devices | grep emulator)"

# The persistent KWin rule (installed above) hides the toolbar at window map.
# Also run the runtime minimize as a belt-and-suspenders for the current session
# (KDE/KWin only; no-ops elsewhere). Backgrounded so it doesn't delay return.
"$SCRIPT_DIR/hide-emulator-toolbar.sh" >/dev/null 2>&1 &
