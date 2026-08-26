#!/usr/bin/env bash
# NavAlert environment check - macOS and Linux (incl. Aurora DX).
#
# Reports what is present, what is missing, and the exact command to fix each
# gap. Read-only: it installs nothing and changes nothing.
#
# Delegates the Android toolchain and JDK verdict to `flutter doctor`, which
# already resolves them correctly, and only adds the checks it does not make:
# the pinned Flutter version, the emulator binaries, whether an AVD exists, and
# KVM access (Linux).
#
# Usage:  ./doctor.sh

set -uo pipefail

PINNED_FLUTTER='3.41.9'
PINNED_JDK='17'

MISSING=()

case "$(uname -s)" in
  Darwin) OS=macos ;;
  Linux)  OS=linux ;;
  *)      OS=unknown ;;
esac

# Aurora / Bluefin and other Fedora Atomic images are read-only at /usr; the
# install advice differs completely, so detect them rather than guessing.
IS_ATOMIC=no
if [ "$OS" = linux ] && { [ -f /run/ostree-booted ] || command -v rpm-ostree >/dev/null 2>&1; }; then
  IS_ATOMIC=yes
fi

if [ -t 1 ]; then
  G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; N=$'\033[0m'
else
  G=''; Y=''; R=''; C=''; N=''
fi

report() { # status name detail fix
  local status=$1 name=$2 detail=$3 fix=${4:-}
  local mark colour
  case "$status" in
    ok)   mark='[ OK ]'; colour=$G ;;
    warn) mark='[WARN]'; colour=$Y ;;
    fail) mark='[FAIL]'; colour=$R ;;
  esac
  printf '%s%s %-22s %s%s\n' "$colour" "$mark" "$name" "$detail" "$N"
  if [ "$status" != ok ] && [ -n "$fix" ]; then
    MISSING+=("$name"$'\n      '"$fix")
  fi
}

echo
echo "${C}NavAlert environment check - ${OS}$( [ "$IS_ATOMIC" = yes ] && echo ' (atomic/immutable)')${N}"
echo "====================================="

# ---------- Flutter ----------
if ! command -v flutter >/dev/null 2>&1; then
  report fail 'Flutter' 'not on PATH' \
    "Install Flutter $PINNED_FLUTTER - see SKILL.md (no package manager ships it)"
else
  v=$(flutter --version 2>/dev/null | sed -n 's/^Flutter \([0-9.]*\).*/\1/p' | head -1)
  if [ "$v" = "$PINNED_FLUTTER" ]; then
    report ok 'Flutter' "$v (pinned)"
  else
    report warn 'Flutter' "${v:-unknown} - project pins $PINNED_FLUTTER" \
      "Version drift rewrites pubspec.lock on every machine. See SKILL.md."
  fi
fi

# ---------- JDK ----------
# JAVA_HOME, not `java -version`: the java on PATH is often a different (older)
# runtime than the one Gradle actually uses, so checking PATH reports a false
# failure on a machine that builds perfectly.
JH="${JAVA_HOME:-}"
if [ -z "$JH" ] && [ "$OS" = macos ] && [ -x /usr/libexec/java_home ]; then
  JH=$(/usr/libexec/java_home -v "$PINNED_JDK" 2>/dev/null || true)
fi

if [ -z "$JH" ]; then
  if [ "$OS" = macos ]; then
    report fail 'JDK (JAVA_HOME)' 'not set' "brew install openjdk@$PINNED_JDK"
  else
    report fail 'JDK (JAVA_HOME)' 'not set' "brew install openjdk@$PINNED_JDK"
  fi
elif [ ! -x "$JH/bin/java" ]; then
  report fail 'JDK (JAVA_HOME)' "points nowhere: $JH" "brew install openjdk@$PINNED_JDK"
else
  # Read the JDK's own release file - java prints its version to stderr, which
  # is awkward to capture portably.
  jv=''
  [ -f "$JH/release" ] && jv=$(sed -n 's/^JAVA_VERSION="\([^"]*\)".*/\1/p' "$JH/release")
  [ -z "$jv" ] && jv=$("$JH/bin/java" -version 2>&1 | sed -n '1s/.*"\([^"]*\)".*/\1/p')
  case "${jv:-unknown}" in
    "$PINNED_JDK".*) report ok 'JDK (JAVA_HOME)' "$jv" ;;
    *) report warn 'JDK (JAVA_HOME)' "${jv:-unknown} - project expects $PINNED_JDK" \
         "brew install openjdk@$PINNED_JDK" ;;
  esac
fi

# ---------- Android SDK ----------
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$SDK" ]; then
  if [ "$OS" = macos ]; then SDK="$HOME/Library/Android/sdk"; else SDK="$HOME/Android/Sdk"; fi
fi

if [ ! -d "$SDK" ]; then
  report fail 'Android SDK' 'not found' \
    'Install the command-line tools - see SKILL.md'
else
  if [ -n "${ANDROID_HOME:-}${ANDROID_SDK_ROOT:-}" ]; then
    report ok 'Android SDK' "$SDK"
  else
    # Flutter finds the SDK at the default path regardless - informational only.
    report ok 'Android SDK' "$SDK (default path; ANDROID_HOME unset)"
  fi

  for pair in "adb:platform-tools/adb" \
              "emulator:emulator/emulator" \
              "sdkmanager:cmdline-tools/latest/bin/sdkmanager"; do
    tool=${pair%%:*}; rel=${pair#*:}
    if [ -x "$SDK/$rel" ]; then
      report ok "$tool" 'present'
    else
      report fail "$tool" "missing ($rel)" \
        "sdkmanager --install 'platform-tools' 'emulator'  (or Android Studio > SDK Manager)"
    fi
  done
fi

# ---------- AVD ----------
avd_count=$(find "$HOME/.android/avd" -maxdepth 1 -name '*.ini' 2>/dev/null | wc -l | tr -d ' ')
if [ "${avd_count:-0}" -gt 0 ]; then
  report ok 'AVD' "$avd_count defined"
else
  report fail 'AVD' 'none defined' 'flutter emulators --create --name Pixel_6'
fi

# ---------- Hardware acceleration ----------
if [ "$OS" = linux ]; then
  if [ ! -e /dev/kvm ]; then
    report fail 'KVM' '/dev/kvm missing - virtualisation off in BIOS?' \
      'Enable VT-x/AMD-V in firmware; check: lsmod | grep kvm'
  elif [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    report ok 'KVM' 'present and writable'
  else
    report fail 'KVM' 'present but not writable by this user' \
      "sudo usermod -aG kvm \$USER   # then LOG OUT and back in - a new shell is not enough"
  fi
elif [ "$OS" = macos ]; then
  # macOS uses the Hypervisor framework; nothing to enable or join.
  report ok 'Emulator accel' 'Hypervisor.framework (no setup needed)'
fi

# ---------- flutter doctor (authoritative on the toolchain) ----------
if command -v flutter >/dev/null 2>&1; then
  echo
  echo "${C}flutter doctor summary:${N}"
  flutter doctor 2>/dev/null | grep '^\[' | sed 's/^/  /'
fi

# ---------- Result ----------
echo
if [ ${#MISSING[@]} -eq 0 ]; then
  echo "${G}Everything the project needs is present.${N}"
  echo 'Next: flutter pub get && flutter test    (expect 286 passing)'
  exit 0
fi

echo "${Y}${#MISSING[@]} item(s) need attention:${N}"
for m in "${MISSING[@]}"; do
  echo "  - $m"
done
echo
echo 'Run /setup-navalert and Claude will walk these through with you.'
exit 1
