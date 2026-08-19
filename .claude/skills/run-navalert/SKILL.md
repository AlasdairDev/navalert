---
name: run-navalert
description: Launch and drive the NavAlert Android app on either dev machine — the Linux (Aurora DX / Fedora atomic) laptop or the Windows machine. Use when asked to run, start, screenshot, or verify the app in a real emulator/device. Handles the machine-specific emulator GPU crash and the missing-Flutter-on-Linux case automatically.
---

# Running NavAlert on either machine

This project is developed on **two machines that need different launch paths**:

- **Linux laptop** (Aurora DX / Fedora 44 atomic, Wayland, Intel Iris Xe): **no Flutter SDK installed.** Run a prebuilt APK on the emulator, and the emulator **must** use `-gpu host` or its qemu SIGSEGVs on boot (SwiftShader's software-GL JIT faults on this host).
- **Windows machine**: Flutter **is** installed. Use the normal `flutter run` toolchain; the emulator's default renderer works fine.

**Step 0 — detect the OS**, then follow the matching section.
```bash
uname -s   # "Linux" -> Linux path;  MINGW*/MSYS*/CYGWIN* or PowerShell -> Windows path
```
On Windows you'll typically be in PowerShell/cmd, not bash — use the Windows section's commands verbatim.

---

## Linux path (this laptop) — VERIFIED

Flutter is not on this host, so **do not** try `flutter run`. Boot the emulator, install the prebuilt APK, drive it.

### 1. Boot the emulator (the `-gpu host` fix is mandatory)
If `adb devices` already shows an `emulator-5554  device`, skip to step 2. Otherwise run the bundled helper (idempotent — no-ops if one is already up, waits for boot, fails loudly if qemu dies):
```bash
.claude/skills/run-navalert/boot-emulator.sh
```
Inline equivalent (what the helper runs):
```bash
DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/$(id -u) \
  nohup ~/Android/Sdk/emulator/emulator -avd Pixel_6 \
  -no-snapshot -no-boot-anim -no-audio -gpu host >/tmp/navalert-emu.log 2>&1 &
```
- **Why `-gpu host` and windowed:** with any software renderer (`swiftshader_indirect`, `guest`, `angle_indirect`, or headless `-no-window`) the emulator crashes ~20s into boot inside SwiftShader's `libGLESv2.so` JIT. `-gpu host` uses the real Intel GPU and never loads SwiftShader. It needs a visible window, so **do not** add `-no-window`.
- **Toolbar auto-hide:** the emulator always opens a *second* window — a control toolbar (a **Utility**-type window, `NET::Utility`) beside the device screen — which looks like a detached "doubled" bar under KWin. `boot-emulator.sh` installs a **persistent KWin window rule** (`install-toolbar-hide-rule.sh`) that force-hides that toolbar on every launch, so you get one clean phone window. The rule matches on window **type** (Utility) + class `Emulator`, **not** title — at boot both emulator windows briefly share the title `Emulator`, so a title match would wrongly hide the device too. `hide-emulator-toolbar.sh` is a runtime belt-and-suspenders for the current session. All KDE-specific (rule lives in `~/.config/kwinrulesrc`, machine-local); no-ops on other hosts / Windows. To undo: delete the `NavAlert: hide Android emulator toolbar` rule in System Settings → Window Management → Window Rules.
- Wait for boot:
```bash
adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do sleep 3; done
```
- If qemu still dies, re-check with `coredumpctl gdb` — a SwiftShader frame means the `-gpu host` flag didn't take.

### 2. Install the prebuilt APK
```bash
adb install -r -t build/app/outputs/flutter-apk/app-debug.apk
```
APKs live under `build/app/outputs/flutter-apk/` — **gitignored**, not in git: they're built on Windows and present on the shared DevSpace drive. On a fresh clone without them, rebuild on the Windows machine — this host can't build.

### 3. Launch and give it real data
```bash
PKG=ph.edu.pup.navalert
adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1
adb shell pm grant $PKG android.permission.ACCESS_FINE_LOCATION
adb shell pm grant $PKG android.permission.ACCESS_COARSE_LOCATION
adb emu geo fix 121.0244 14.5547     # Ayala Ave, Metro Manila — gives the map/blue-dot UI a location
```

### 4. Drive & verify
Onboarding is 3 gates before the home map: **Permissions**, **Add 3 Emergency Contacts**, **Fake Call Setup** — each has a "Skip for now". Flutter doesn't expose text to `uiautomator`, so tap by coordinate: dump bounds with
```bash
adb shell uiautomator dump /sdcard/ui.xml && adb shell cat /sdcard/ui.xml | tr '>' '\n' | grep -oE 'bounds="[^"]*"'
```
Screenshot and LOOK at it (a home screen shows "Where are you headed?", a search bar, the OSM map, a blue dot, and the History/Favorites/Home/Emergency/Settings nav):
```bash
adb exec-out screencap -p > /tmp/navalert-shot.png
```

---

## Windows path (the other machine) — Flutter present

Flutter builds and installs directly; no APK juggling and no GPU workaround needed.
```powershell
flutter devices                                   # is an emulator/device connected?
flutter emulators                                 # list AVDs
flutter emulators --launch Pixel_6                # boot one if none connected
flutter run                                       # builds, installs, launches, hot-reload
```
- To just install a prebuilt APK instead of building: `adb install -r build\app\outputs\flutter-apk\app-debug.apk`.
- If the emulator misbehaves, `-gpu host` is a safe default on Windows too, but the SwiftShader crash is Linux-specific — the default renderer normally works here.
- Same package/activity: `ph.edu.pup.navalert/.MainActivity`.

---

## Facts (both machines)
- **Package / activity:** `ph.edu.pup.navalert` / `.MainActivity`
- **AVD:** `Pixel_6` (android-35 google_apis x86_64)
- **Debug APK:** `build/app/outputs/flutter-apk/app-debug.apk`
- Full root-cause notes on the Linux emulator crash live in Claude's project memory (`emulator-gpu-host-fix`).
