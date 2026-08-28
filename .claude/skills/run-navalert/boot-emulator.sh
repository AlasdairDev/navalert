#!/usr/bin/env bash
# Boot the Android emulator on the Linux dev host (Aurora DX / Fedora atomic).
# The -gpu host flag is mandatory: any software renderer (swiftshader/guest/angle,
# or headless -no-window) SIGSEGVs ~20s into boot inside SwiftShader's libGLESv2 JIT.
set -euo pipefail

DEFAULT_AVD='Pixel_6'
LOG="/tmp/navalert-emu.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the SDK rather than hardcoding one machine's layout: macOS puts it
# under ~/Library/Android/sdk, Linux under ~/Android/Sdk.
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$SDK" ]; then
  case "$(uname -s)" in
    Darwin) SDK="$HOME/Library/Android/sdk" ;;
    *)      SDK="$HOME/Android/Sdk" ;;
  esac
fi
EMU="$SDK/emulator/emulator"

if [ ! -x "$EMU" ]; then
  echo "ERROR: no emulator binary at $EMU" >&2
  echo "Set ANDROID_HOME, or install it: sdkmanager --install emulator" >&2
  exit 1
fi

# Pick an AVD that actually exists. A wrong name makes qemu exit instantly while
# `adb wait-for-device` blocks forever, so validate BEFORE launching.
AVDS=$("$EMU" -list-avds 2>/dev/null | tr -d '\r' | grep -v '^[[:space:]]*$' || true)
if [ -z "$AVDS" ]; then
  echo "ERROR: no AVD defined. Create one:" >&2
  echo "  flutter emulators --create --name $DEFAULT_AVD" >&2
  exit 1
fi

if [ -n "${1:-}" ]; then
  AVD="$1"
elif printf '%s\n' "$AVDS" | grep -qx "$DEFAULT_AVD"; then
  AVD="$DEFAULT_AVD"
elif [ "$(printf '%s\n' "$AVDS" | wc -l)" -eq 1 ]; then
  AVD="$AVDS"                     # only one on this machine - use it
  echo "Note: '$DEFAULT_AVD' not found; using the only AVD present: $AVD"
else
  echo "ERROR: '$DEFAULT_AVD' not found and several AVDs exist. Pass one:" >&2
  printf '  %s\n' $AVDS >&2
  exit 1
fi

if ! printf '%s\n' "$AVDS" | grep -qx "$AVD"; then
  echo "ERROR: unknown AVD '$AVD'. Available:" >&2
  printf '  %s\n' $AVDS >&2
  exit 1
fi

# Install the persistent KWin rule that hides the emulator's side toolbar
# off-screen (KDE-only). The device window is made floating/draggable after launch
# by float-emulator.sh (see the launch step) — Kröhnkite's ignoreClass can't match
# the emulator, but its Toggle-Float action can.
"$SCRIPT_DIR/install-toolbar-hide-rule.sh" 2>/dev/null || true

# Already have a running emulator? Do nothing.
if adb devices | grep -qE 'emulator-[0-9]+\s+device'; then
  echo "Emulator already running:"; adb devices | grep emulator
  exit 0
fi

# Low-memory guard. This laptop has 8 GB and its only swap is zram (compressed
# RAM, NOT disk), so there is no real overflow: an emulator started on top of a
# Gradle build pushes the kernel into reclaiming pages inside RAM it does not
# have, and the machine LIVELOCKS rather than OOM-killing anything. Warn before
# adding ~2 GB rather than after the freeze.
AVAIL_MB=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 9999)
if [ "$AVAIL_MB" -lt 2600 ]; then
  echo "WARNING: only ${AVAIL_MB} MB available; the emulator needs ~2 GB." >&2
  echo "         Close editor windows or stop the Gradle daemon first:" >&2
  echo "           ./gradlew --stop   (or: pkill -f GradleDaemon)" >&2
  echo "         Continuing in 5s — Ctrl-C to abort." >&2
  sleep 5
fi

echo "Booting $AVD with -gpu host (log: $LOG, ${AVAIL_MB} MB free) ..."
# Launch in its OWN systemd scope, not as a child of whatever started this.
#
# WHY: run from a terminal inside VS Code, qemu lands in VS Code's cgroup
# (app-code-NNNN.scope). When the machine hit a global OOM the kernel killed
# qemu - the largest process - and systemd then tore down the WHOLE scope for
# failing with oom-kill, taking the editor and every unsaved buffer with it:
#
#   kernel: Out of memory: Killed process (qemu-system-x86)
#           task_memcg=/user.slice/.../app.slice/app-code-3305.scope
#   systemd: app-code-3305.scope: Failed with result 'oom-kill'.
#
# Its own scope confines that blast radius to the emulator. MemoryMax caps it
# so it is reclaimed before the machine goes global-OOM at all, and
# it is killed alone rather than dragging the session down with it if the
# machine ever does go global-OOM.
if command -v systemd-run >/dev/null 2>&1; then
  systemd-run --user --scope --quiet \
    --unit="navalert-emulator-$$" \
    -p MemoryMax=3G -p MemorySwapMax=1G \
    --setenv=DISPLAY="${DISPLAY:-:0}" \
    --setenv=WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
    --setenv=XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
    "$EMU" -avd "$AVD" -no-snapshot -no-boot-anim -no-audio -gpu host \
    >"$LOG" 2>&1 &
else
  DISPLAY="${DISPLAY:-:0}" \
  WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
  XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
    nohup "$EMU" -avd "$AVD" -no-snapshot -no-boot-anim -no-audio -gpu host \
    >"$LOG" 2>&1 &
fi

EMU_PID=$!
echo -n "Waiting for boot"
# Poll for boot AND for the process staying alive. `adb wait-for-device` alone
# blocks forever when qemu exits early (bad AVD, no KVM), so never gate on it.
while :; do
  if ! kill -0 "$EMU_PID" 2>/dev/null; then
    echo; echo "ERROR: emulator process died. Last log lines:"; tail -12 "$LOG"; exit 1
  fi
  if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then
    break
  fi
  echo -n .; sleep 3
done
echo; echo "Booted. $(adb devices | grep emulator)"
