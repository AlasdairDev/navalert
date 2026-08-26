---
name: setup-navalert
description: Use when a machine cannot build or run NavAlert because Flutter, the Android SDK, the emulator, a JDK or KVM access is missing or the wrong version, when setting up the project on a new or unfamiliar laptop, or when `flutter pub get`, `flutter test` or a Gradle build fails on what looks like a toolchain problem rather than a code problem. Covers Windows, macOS and Aurora DX / Fedora Atomic.
---

# Setting up a machine to build NavAlert

**Always run the doctor first.** It is read-only, takes seconds, and tells you
which of the steps below you actually need. Most "it won't build" reports turn
out to be one missing item, not a full install.

```bash
# macOS / Linux
.claude/skills/setup-navalert/doctor.sh

# Windows
powershell -ExecutionPolicy Bypass -File .claude\skills\setup-navalert\doctor.ps1
```

Exit code 0 means the machine is ready. Exit code 1 lists each gap with the
command that closes it.

## Pinned versions

| Tool | Version | Why pinned |
|---|---|---|
| Flutter | **3.41.9** | Drives `pubspec.lock` resolution |
| Dart | 3.11.5 | Ships with Flutter — never installed separately |
| JDK | **17** | Gradle 8.14 / AGP 8.11 |
| Android SDK | API 36 (min 26) | `compileSdk` / `targetSdk` |
| Gradle | 8.14 | Fetched by the wrapper — **do not install** |

**The Flutter pin is the one that matters.** A machine on a different Flutter
resolves `pubspec.lock` differently, so the lockfile is rewritten on every
`pub get` and collides on every merge. If the doctor reports a Flutter mismatch,
fix it before touching anything else.

## Two things the doctor deliberately does NOT flag

Both look like failures and are not. Do not "fix" them:

- **`java -version` showing an old JRE.** Gradle uses `JAVA_HOME`, not PATH. A
  machine with JRE 8 on PATH and JDK 17 in `JAVA_HOME` builds perfectly. The
  doctor checks `JAVA_HOME` for exactly this reason.
- **`ANDROID_HOME` being unset.** Flutter finds the SDK at the platform's
  default path anyway. Setting it is tidy, not required.

## Windows

There is **no `winget` package for Flutter** — searching returns apps *built
with* Flutter, not the SDK. Flutter is installed by hand; the rest is winget.

1. **Flutter** — download the pinned SDK from
   [docs.flutter.dev/release/archive](https://docs.flutter.dev/release/archive),
   extract to `C:\src\flutter`, add `C:\src\flutter\bin` to PATH.
2. **JDK 17** — `winget install Microsoft.OpenJDK.17` (sets `JAVA_HOME`).
3. **Android SDK + emulator** — `winget install Google.AndroidStudio`, then
   open it once and let the SDK Manager fetch API 36 + a system image.
4. **Acceleration** — enable *Windows Hypervisor Platform* in Windows Features,
   then reboot. The doctor asks the emulator itself via `-accel-check`, so it
   reports the truth without needing an admin shell.

## macOS

> **UNVERIFIED.** Written from Homebrew and Flutter documentation; nobody has
> run it on a Mac yet. Treat failures as bugs in this file and report them.

```bash
brew install --cask temurin@17          # JDK 17
brew install --cask android-commandlinetools
sdkmanager --licenses
sdkmanager "platform-tools" "emulator" "platforms;android-36" \
           "system-images;android-36;google_apis;arm64-v8a"
```

Flutter is installed by hand, same as Windows — clone the pinned tag:

```bash
git clone --depth 1 --branch 3.41.9 https://github.com/flutter/flutter.git ~/flutter
export PATH="$PATH:$HOME/flutter/bin"
```

Apple silicon needs the `arm64-v8a` system image, not `x86_64`. No hypervisor
setup — macOS uses Hypervisor.framework directly.

## Aurora DX / Fedora Atomic

```bash
.claude/skills/setup-navalert/install-aurora.sh
```

Idempotent — safe to re-run; every step skips what is already present.

**Never `rpm-ostree install` any of this.** Aurora is Fedora Atomic: `/usr` is
read-only, and Aurora's own docs steer users away from layering because it slows
and complicates every later image update. Everything NavAlert needs lives in
`$HOME`, so layering buys nothing and costs update speed permanently.

| Need | Route |
|---|---|
| JDK 17 | `brew install openjdk@17` — the pattern Aurora's docs name |
| Flutter | Pinned git clone into `~/flutter` |
| Android SDK | cmdline-tools into `~/Android/Sdk` |
| KVM | `sudo usermod -aG kvm $USER` — **the only step needing root** |

**KVM needs a full log out and back in.** Group membership is established at
login, so a new terminal is not enough. The emulator will keep failing with a
permissions error until you actually log out — this is the step people miss.

Two things the script will stop and ask you about rather than decide for you:

- **SDK licences.** `sdkmanager --licenses` is interactive on purpose. Accepting
  Google's licences on someone's behalf is not this script's call.
- **The sudo for KVM.** It prints the command; you run it.

## After the doctor is green

```bash
flutter pub get
flutter test          # expect 284 passing
```

If the tests pass, the machine is genuinely ready — that exercises the analyzer,
the full dependency graph and the whole `TripViewModel` state machine.

To launch the app, use **run-navalert**, which handles the per-machine emulator
quirks (the Aurora laptop needs `-gpu host` or qemu segfaults on boot).

## Common failures

| Symptom | Cause | Fix |
|---|---|---|
| `pubspec.lock` keeps changing after `pub get` | Flutter version drift between machines | Match the 3.41.9 pin on every machine |
| Emulator: "permission denied /dev/kvm" | Not in `kvm` group, or joined but never re-logged-in | `sudo usermod -aG kvm $USER`, then log out and back in |
| `sdkmanager: Could not determine SDK root` | cmdline-tools not under a `latest/` directory | Move them to `$ANDROID_HOME/cmdline-tools/latest/` |
| Gradle picks the wrong Java | `JAVA_HOME` points at a JRE or the wrong major version | Point `JAVA_HOME` at a real JDK 17 |
| Emulator boots then dies (Aurora) | Software GL segfaults on this hardware | Launch with `-gpu host` — run-navalert does this |
| `flutter pub get` fails offline | Planning a trip needs a network; the SDK fetch does too | Connect, then re-run |
