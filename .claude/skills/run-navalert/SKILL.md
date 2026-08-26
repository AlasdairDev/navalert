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
- **Emulator window layout is managed by two persistent KWin rules** (`install-toolbar-hide-rule.sh`, installed at boot; KDE-only, no-ops on Windows):
  - The **side toolbar** (a `NET::Utility` window) renders a buggy white/black strip on this KWin+Wayland+scaling setup, so it's forced **off-screen**. You navigate with the phone's own **on-screen 3-button nav** instead (`set-3button-nav.sh` → Back/Home/Recents). `hide-emulator-toolbar.sh` re-hides it after launch (launching can raise it; and minimize does NOT stick on this window — off-screen position does).
  - The **device window** kept getting tiled/snapped to a **left tile by Kröhnkite** (notably when the screenshot tool opened a window). Kröhnkite's `ignoreClass`/`ignoreTitle` do NOT match the emulator on this Wayland setup (it reads the window class too early), and a Force **position** rule can't beat Kröhnkite (script moves bypass rules). What works: Kröhnkite's per-window **Toggle-Float** action — `float-emulator.sh` focuses the device window and fires `KrohnkiteToggleFloat` (via `qdbus-qt6 org.kde.kglobalaccel /component/kwin invokeShortcut KrohnkiteToggleFloat`), making it a **free-floating, draggable** window Kröhnkite ignores, then places it on the right. A guard skips the toggle if it's already floating (so re-running never un-floats it). Run it AFTER launch (fresh launch starts tiled). **Update (2026-08-19):** `ignoreClass` in `~/.config/kwinrc` `[Script-krohnkite]` now *does* list `Emulator,qemu-system-x86_64` (plus `ignoreTitle=Emulator`), and with that in place the window is no longer re-tiled — programmatic geometry held exactly across dozens of trials. The float toggle is kept as belt-and-braces. Note the guard's heuristic is weak (it treats any `x >= 100` as "already floating"), so it would misread a right-hand tile as floating.
  - The toolbar rule matches on window **type** (Utility=256) + class `Emulator`, NOT title (both windows briefly share the title `Emulator` at boot).
  - **Resizing the device window used to "shift sizes"/jitter — that is a fractional-scaling bug, NOT Kröhnkite.** The emulator's bundled Qt ships only the `xcb` platform plugin (`~/Android/Sdk/emulator/lib64/qt/plugins/platforms/` has no Wayland plugin), so it is **always an XWayland client**. This display runs **scale 1.15 = 23/20**, and XWayland rounds logical->device pixels: only logical sizes that are **multiples of 20** convert exactly. In between the rounding is *non-monotonic* — measured logical width `503->568`, `504->570` (skips 569), `509->575`, `510->577` — so a smooth 1px drag steps the client buffer unevenly by 1-2px and the device framebuffer re-letterboxes on every step. Kröhnkite is cleared: `ignoreClass` already lists `Emulator,qemu-system-x86_64`, and programmatic geometry is stable across dozens of trials.
    - **`resize-emulator.sh [fill|large|medium|small|<height>]`** sets a size that is an exact multiple of the scale denominator *and* matches the device aspect, so there is no rounding and no letterbox. `fill` gives 400x900 here. This is the reliable way to resize — prefer it over dragging.
    - **`install-resize-snap.sh`** installs a persistent KWin script (`~/.local/share/kwin/scripts/navalert-emu-snap/`) that snaps the window to a clean size when you **finish** dragging its edge. It cannot make the drag itself smooth (inherent to XWayland + fractional scale) but the size you land on is always exact. Remove with `install-resize-snap.sh --remove`. Width is always re-derived from height, since the device has a fixed aspect.
    - **Separate bug, same script: *dragging* the window used to randomly resize it** ("small then big then medium"). That is **KWin's own tiling**, not Kröhnkite and not the scaling. This machine has custom tile zones configured in `~/.config/kwinrc` (`[Tiling][<desktop>][<output>]`, e.g. `0.25/0.5/0.25` and `0.5/0.5`) plus KWin's default drag-to-edge tiling, so dropping the window near an edge or zone snaps it to that tile — verified: quick-tile left/right gives `835x911`, top-left gives `835x456`. The window then carries a live `tile` object (`w.tile` was `KWin::Tile(0x...)`). `install-resize-snap.sh` now clears `w.tile` on `tileChanged`/`quickTileModeChanged` and restores the pre-drag size on `interactiveMoveResizeFinished`, so a drag can never change the size. Verified with real synthetic mouse drags (ydotool) to left/right/top/both corners: size preserved in all 6 cases.
    - Kröhnkite is **not** involved in either bug: `KrohnkiteNextLayout` / `Rotate` leave the emulator's geometry untouched. Polonium is installed but not loaded.
    - Alternative if you want genuinely smooth dragging: set the display to **100% scale** (System Settings -> Display), which removes the rounding entirely — at the cost of everything else being smaller.
  - **`kwin-run.sh` runs KWin JS one-shot and unloads it.** The helpers used to call `Scripting.loadScript()` with a fresh `mktemp` name every time and never unload; scripts accumulate in the compositor (56 were live after ~10 min) and results go stale/erratic. All helpers now go through `kwin-run.sh`.
  - **Debugging KWin scripts here: `print()` and `console.log()` do NOT reach the journal — only `throw new Error(...)` does.** But a `throw` tears down the script context, so a *persistent* script must not throw (its signal handlers die silently). Use `throw` only in one-shot probes via `kwin-run.sh`; verify persistent scripts by observing their effect instead.
  - To undo: delete the `NavAlert: emulator window rules` entry in System Settings → Window Rules; press **Super+F** on the emulator to toggle its float back; re-run `set-3button-nav.sh` swapping enable/disable back to `gestural` for gesture nav.
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

# On-screen 3-button nav (Back/Home/Recents) instead of the gesture pill,
# hide the buggy side toolbar, and make the device a floating/draggable window.
# Run these AFTER launch (launching raises the toolbar / re-tiles the window).
.claude/skills/run-navalert/set-3button-nav.sh
.claude/skills/run-navalert/hide-emulator-toolbar.sh
.claude/skills/run-navalert/float-emulator.sh
.claude/skills/run-navalert/resize-emulator.sh fill   # clean, jitter-free size
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
- **Display scale on the Linux laptop:** 1.15 (1920x1080 panel -> 1670x940 logical). Window sizes must be multiples of **20** logical px to avoid XWayland rounding jitter.
- Full root-cause notes on the Linux emulator crash live in Claude's project me