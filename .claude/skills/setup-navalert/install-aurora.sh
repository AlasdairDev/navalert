#!/usr/bin/env bash
# NavAlert dependency install - Aurora DX (and other Fedora Atomic images).
#
# WHY THIS FILE EXISTS
# Aurora is Fedora Atomic: /usr is read-only and the Aurora docs steer users
# away from layering packages, because layering slows and complicates every
# subsequent image update. Their sanctioned routes are Homebrew for CLI tools,
# Flatpak for GUI apps, and containers for dev workloads.
#
# That suits NavAlert, because everything the project needs lives in $HOME:
#   JDK 17        -> brew (the pattern Aurora's own docs name)
#   Flutter       -> pinned tarball in $HOME
#   Android SDK   -> command-line tools in $HOME/Android/Sdk
# The single exception is KVM group membership, which is host state and needs
# sudo plus a full re-login.
#
# NEVER `rpm-ostree install` any of this. It is not needed, and it makes the
# machine slower to update forever after.
#
# Idempotent: every step checks first and skips what is already there.
# Usage:  ./install-aurora.sh

set -euo pipefail

PINNED_FLUTTER='3.41.9'
PINNED_JDK='17'
FLUTTER_DIR="$HOME/flutter"
SDK_DIR="$HOME/Android/Sdk"
CMDLINE_TOOLS_VERSION='13114758'   # cmdline-tools 17.0, Android 16 era

say()  { printf '\n\033[36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m    %s\033[0m\n' "$*"; }
warn() { printf '\033[33m    %s\033[0m\n' "$*"; }
die()  { printf '\033[31m!!  %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- sanity
if [ ! -f /run/ostree-booted ] && ! command -v rpm-ostree >/dev/null 2>&1; then
  warn "This does not look like a Fedora Atomic system."
  warn "On a traditional distro use your package manager instead; nothing here needs to run."
  exit 1
fi

say "Aurora DX / Fedora Atomic detected - installing into \$HOME only"

# ---------------------------------------------------------------- homebrew
if ! command -v brew >/dev/null 2>&1; then
  if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    ok "Homebrew found; added to this shell"
  else
    die "Homebrew is missing. Aurora ships it by default - reinstall via
    https://docs.getaurora.dev/guides/software/ then re-run this script."
  fi
else
  ok "Homebrew present"
fi

# ---------------------------------------------------------------- jdk 17
say "JDK $PINNED_JDK"
if brew list "openjdk@$PINNED_JDK" >/dev/null 2>&1; then
  ok "openjdk@$PINNED_JDK already installed"
else
  brew install "openjdk@$PINNED_JDK"
  ok "installed openjdk@$PINNED_JDK"
fi
BREW_PREFIX="$(brew --prefix)"
JAVA_HOME_LINE="export JAVA_HOME=\"$BREW_PREFIX/opt/openjdk@$PINNED_JDK\""

# ---------------------------------------------------------------- flutter
say "Flutter $PINNED_FLUTTER"
if [ -x "$FLUTTER_DIR/bin/flutter" ]; then
  have=$("$FLUTTER_DIR/bin/flutter" --version 2>/dev/null | sed -n 's/^Flutter \([0-9.]*\).*/\1/p' | head -1)
  if [ "$have" = "$PINNED_FLUTTER" ]; then
    ok "Flutter $PINNED_FLUTTER already at $FLUTTER_DIR"
  else
    warn "Flutter $have is at $FLUTTER_DIR but the project pins $PINNED_FLUTTER."
    warn "Switch with:  cd $FLUTTER_DIR && git checkout $PINNED_FLUTTER && flutter --version"
  fi
else
  # A shallow clone of the exact tag: smaller than full history, and it leaves a
  # working `git checkout <version>` for later version bumps, which the tarball
  # does not.
  say "Cloning Flutter $PINNED_FLUTTER into $FLUTTER_DIR (this pulls a few hundred MB)"
  git clone --depth 1 --branch "$PINNED_FLUTTER" \
    https://github.com/flutter/flutter.git "$FLUTTER_DIR"
  ok "Flutter $PINNED_FLUTTER cloned"
fi

# ---------------------------------------------------------------- android sdk
say "Android command-line tools"
if [ -x "$SDK_DIR/cmdline-tools/latest/bin/sdkmanager" ]; then
  ok "cmdline-tools already at $SDK_DIR"
else
  tmp=$(mktemp -d)
  zip="$tmp/cmdline-tools.zip"
  url="https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_VERSION}_latest.zip"
  say "Downloading command-line tools (~150 MB)"
  curl -fL --progress-bar -o "$zip" "$url" || die "download failed: $url"
  mkdir -p "$SDK_DIR/cmdline-tools"
  unzip -q "$zip" -d "$tmp"
  # The zip expands to `cmdline-tools/`; sdkmanager insists on being under a
  # version directory named `latest`, or every later command fails with a
  # "Could not determine SDK root" that names nothing useful.
  mv "$tmp/cmdline-tools" "$SDK_DIR/cmdline-tools/latest"
  rm -rf "$tmp"
  ok "cmdline-tools installed to $SDK_DIR/cmdline-tools/latest"
fi

# ---------------------------------------------------------------- shell rc
say "Shell environment"
RC="$HOME/.bashrc"
[ -n "${ZSH_VERSION:-}" ] && RC="$HOME/.zshrc"

if grep -q 'NavAlert dev environment' "$RC" 2>/dev/null; then
  ok "$RC already configured"
else
  cat >> "$RC" <<EOF

# --- NavAlert dev environment (added by setup-navalert) ---
$JAVA_HOME_LINE
export ANDROID_HOME="$SDK_DIR"
export PATH="\$PATH:$FLUTTER_DIR/bin:\$ANDROID_HOME/cmdline-tools/latest/bin:\$ANDROID_HOME/platform-tools:\$ANDROID_HOME/emulator"
# --- end NavAlert ---
EOF
  ok "appended PATH/JAVA_HOME/ANDROID_HOME to $RC"
  warn "Run:  source $RC     (or open a new terminal)"
fi

export JAVA_HOME="$BREW_PREFIX/opt/openjdk@$PINNED_JDK"
export ANDROID_HOME="$SDK_DIR"
export PATH="$PATH:$FLUTTER_DIR/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator"

# ---------------------------------------------------------------- sdk packages
say "Android SDK packages"
warn "sdkmanager will ask you to accept Google's SDK licences."
warn "Read them and answer yourself - this script will not auto-accept on your behalf."
sdkmanager --licenses || true
sdkmanager "platform-tools" "emulator" "platforms;android-36" "build-tools;36.0.0" \
           "system-images;android-36;google_apis;x86_64"
ok "SDK packages installed"

# ---------------------------------------------------------------- kvm
say "KVM access (the one step that needs sudo)"
if [ ! -e /dev/kvm ]; then
  warn "/dev/kvm does not exist - virtualisation is probably disabled in firmware."
  warn "Enable VT-x / AMD-V in BIOS, then check:  lsmod | grep kvm"
elif [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
  ok "/dev/kvm already accessible"
else
  warn "You are not in the kvm group. Run:"
  echo
  echo "    sudo usermod -aG kvm \$USER"
  echo
  warn "Then LOG OUT and back in. A new terminal is not enough - group membership"
  warn "is established at login, so the emulator will keep failing until you do."
fi

# ---------------------------------------------------------------- verify
say "Verifying"
flutter --version
flutter doctor

cat <<'EOF'

Next steps:
  source ~/.bashrc                 # or open a new terminal
  cd <the navalert repo>
  flutter pub get
  flutter test                     # expect 286 passing

Then use /run-navalert to launch the app. Note that on this machine the
emulator must start with `-gpu host` or qemu segfaults on boot - run-navalert
already handles that.
EOF
