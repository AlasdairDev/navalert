#!/usr/bin/env bash
# Boot the Pixel_6 emulator on the Linux dev host (Aurora DX / Fedora atomic).
# The -gpu host flag is mandatory: any software renderer (swiftshader/guest/angle,
# or headless -no-window) SIGSEGVs ~20s into boot inside SwiftShader's libGLESv2 JIT.
set -euo pipefail

AVD="${1:-Pixel_6}"
EMU="$HOME/Android/Sdk/emulator/emulator"
LOG="/tmp/navalert-emu.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Make Kröhnkite float the emulator (else it snaps it to a left tile), and install
# the persistent KWin rules (toolbar off-screen + device pinned right). KDE-only.
"$SCRIPT_DIR/ensure-krohnkite-ignore.sh" 2>/dev/null || true
"$SCRIPT_DIR/install-toolbar-hide-rule.sh" 2>/dev/null || true

# Already have a running emulator? Do nothing.
if adb devices | grep -qE 'emulator-[0-9]+\s+device'; then
  echo "Emulator already running:"; adb devices | grep emulator
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
