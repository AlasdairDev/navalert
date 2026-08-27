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

Homebrew is the same route Aurora uses, so the JDK command is identical on both
— only the Android SDK and emulator differ. Match `doctor.sh`, which checks for
`openjdk@17`:

```bash
brew install openjdk@17                 # JDK 17 — same formula as Aurora
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

`openjdk@17` is keg-only, so Homebrew does not put it on `PATH` or set
`JAVA_HOME` — and `JAVA_HOME` is what Gradle and the doctor read. Export it:

```bash
echo 'export JAVA_HOME="$(brew --prefix openjdk@17)"' >> ~/.zshrc
echo 'export PATH="$JAVA_HOME/bin:$PATH"'             >> ~/.zshrc
```

macOS ships **bash 3.2**, which `doctor.sh` is written to tolerate — do not
"modernise" it with `${arr[@]}` on a possibly-empty array, which aborts there
under `set -u`.

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

## Low-RAM machines (the Aurora ThinkPad) — read before your first build

**The laptop freezing mid-build is a configuration problem, not bad luck.**

`android/gradle.properties` asks for `-Xmx8G` with `-XX:MaxMetaspaceSize=4G`.
That file is committed and was written on a high-RAM Windows machine. On the
8 GB ThinkPad it lets the Gradle daemon grow past everything the machine has,
and because the only swap here is **zram — compressed RAM, not disk** — there
is no real overflow to spill into. The kernel ends up reclaiming pages inside
RAM it does not have and the session **livelocks**: no cursor, no OOM kill, no
entry in the journal. A hard OOM would be kinder.

Do **not** edit the committed file — the Windows machine legitimately wants the
larger heap. Gradle reads `$GRADLE_USER_HOME/gradle.properties` *after* the
project's, so a host-level file wins without touching the repo:

```bash
mkdir -p ~/.gradle && cat > ~/.gradle/gradle.properties <<'EOF'
org.gradle.jvmargs=-Xmx2g -XX:MaxMetaspaceSize=768m -XX:ReservedCodeCacheSize=256m
org.gradle.workers.max=3
org.gradle.parallel=false
org.gradle.caching=true
kotlin.daemon.jvmargs=-Xmx1g
EOF
```

Any machine under roughly 16 GB wants this, macOS included.

### Budget the memory, not just the heap

Measured on the ThinkPad (8 GB total): VS Code alone held **3.25 GB**, the
emulator takes **~2 GB**, and Gradle wants whatever the heap allows. Those three
do not fit at once.

| Lever | Where | Effect |
|---|---|---|
| Gradle heap 8G → 2g | `~/.gradle/gradle.properties` | the single biggest win |
| Emulator cores 4 → 2 | `~/.android/avd/<avd>.avd/config.ini` | leaves CPU for the compiler |
| Don't run both at once | habit | build, *then* boot the emulator |
| Close spare editor windows | habit | reclaims GBs immediately |

`boot-emulator.sh` now warns when under 2600 MB is available rather than letting
you add 2 GB to a machine that has none.

### Add real swap

zram is not a substitute for disk swap on a machine this size — it buys about
2× on compressible pages and then thrashes. Real swap turns a freeze into
"slow", which is recoverable:

```bash
sudo btrfs filesystem mkswapfile --size 8g /var/swapfile   # ext4: fallocate + mkswap
sudo swapon /var/swapfile
```

Check with `swapon --show`: a `file` row alongside `/dev/zram0` means it worked.

---

## After the doctor is green

```bash
flutter pub get
flutter test          # 286 passing as of v1.1.1 build 4
```

### The AVD's *name* matters, not just that one exists

`run-navalert` boots an AVD by name and defaults to `Pixel_6`. The doctor prints
the names it finds, so a mismatch is visible immediately:

```
[ OK ] AVD    flutter_phone (skill default 'Pixel_6' absent - pass the name)
```

That is fine — `boot-emulator.sh` falls back to the only AVD present. With two
or more under other names, pass one: `boot-emulator.sh <name>`. To create the
default outright: `flutter emulators --create --name Pixel_6`.

The count rises as tests are added — what matters is that they all pass, not
that the number still reads 286. If they pass, the machine is genuinely ready — that exercises the analyzer,
the full dependency graph and the whole `TripViewModel` state machine.

### A fresh emulator has no GPS — set one

```bash
adb emu geo fix 121.0108 14.5979     # PUP Sta. Mesa — LONGITUDE FIRST
```

Without it the app says *"turn on GPS"* and will not plan a trip, which looks
like a broken install on a machine you have just set up. It is correct
behaviour: the app refuses to plan from a position it cannot verify rather than
substituting a placeholder, so a commute is never measured from the wrong place.

Longitude comes first and it is the usual mistake — reversed, the coordinate
lands in the Indian Ocean and the app reports the trip as outside its service
area.

This is also the **only** place a fixed demo location belongs. The emulator
reports it as a genuine GPS fix, so the app treats it as the commuter's real
location with no build variant and no debug flag — the APK you demonstrate is
byte-for-byte the one you release.

To launch the app, use **run-navalert**, which sets this automatically and
handles the per-machine emulator quirks (the Aurora laptop needs `-gpu host` or
qemu segfaults on boot).

## Common failures

| Symptom | Cause | Fix |
|---|---|---|
| `pubspec.lock` keeps changing after `pub get` | Flutter version drift between machines | Match the 3.41.9 pin on every machine |
| Emulator: "permission denied /dev/kvm" | Not in `kvm` group, or joined but never re-logged-in | `sudo usermod -aG kvm $USER`, then log out and back in |
| `sdkmanager: Could not determine SDK root` | cmdline-tools not under a `latest/` directory | Move them to `$ANDROID_HOME/cmdline-tools/latest/` |
| Gradle picks the wrong Java | `JAVA_HOME` points at a JRE or the wrong major version | Point `JAVA_HOME` at a real JDK 17 |
| Emulator boots then dies (Aurora) | Software GL segfaults on this hardware | Launch with `-gpu host` — run-navalert does this |
| `flutter pub get` fails offline | Planning a trip needs a network; the SDK fetch does too | Connect, then re-run |
