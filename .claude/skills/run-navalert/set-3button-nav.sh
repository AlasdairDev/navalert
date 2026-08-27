#!/usr/bin/env bash
# Switch the emulator to Android's on-screen 3-button navigation (Back / Home /
# Recents) instead of the default gesture pill, so you have visible nav buttons
# on the phone itself (the side toolbar is hidden — see install-toolbar-hide-rule.sh).
# The setting persists in the AVD's userdata across reboots; re-running is harmless.
set -uo pipefail

adb shell cmd overlay enable  com.android.internal.systemui.navbar.threebutton >/dev/null 2>&1 || true
adb shell cmd overlay disable com.android.internal.systemui.navbar.gestural    >/dev/null 2>&1 || true
echo "nav-mode: 3-button enabled"
