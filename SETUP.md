# NavAlert — Setup & Defense Preparation

Installation and verification guide for developers and Capstone panelists
testing **v1.1.0** on physical hardware.

> **Note on filename.** This repository is developed on a case-insensitive
> filesystem, where `setup.md` and `SETUP.md` are the same file. Git tracks it
> as `SETUP.md`; linking to `setup.md` will resolve to this document.

---

## 1. Mandatory prerequisite: uninstall any previous build

**Do this first. It is not housekeeping.**

```bash
adb uninstall ph.edu.pup.navalert
```

Two things make this mandatory rather than advisory:

1. **Notification channel state is locked.** A `NotificationChannel`'s
   importance is fixed the moment the channel first exists on the device —
   Android deliberately ignores later changes so a user's own setting is never
   overridden. Earlier builds created `navalert_trip` at `IMPORTANCE_LOW`, which
   Android 12+ files under "Silent" and most devices hide from the lock screen.
   v1.0.0 posts on a new `navalert_trip_v2` channel, but **the stale channel
   survives an in-place upgrade**, and on some devices the old one continues to
   shadow the behaviour. A clean install is the only way to guarantee the
   lock-screen notification behaves as designed.

2. **Signature mismatch.** Release builds are signed with the debug key (see
   [§5](#5-signing)), so installing over a build from a different machine fails
   with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`.

Uninstalling also clears granted permissions, which is exactly the state you
want for the restricted-settings test in [§4](#4-testing-checklist).

---

## 2. Installation over USB

Install with `adb`, not by copying the APK to the phone and tapping it:

```bash
adb install NavAlert-release.apk
```

Or from a fresh build:

```bash
flutter build apk --release
adb install build/app/outputs/apk/release/NavAlert-release.apk
```

### Why USB rather than tapping the file

Android 13+ (API 33+) treats apps installed by a non-store installer as
**sideloaded** and gates sensitive permissions behind *Restricted Settings*,
refusing the grant with **"App was denied access to SMS."** Packages installed
through `adb` are generally not flagged this way, so the SMS permission can be
granted through the normal in-app prompt and the SOS works immediately.

> **If you are blocked anyway** — behaviour varies by OEM and Android version,
> so treat USB install as the smoother path, not a guarantee. NavAlert detects
> the blocked state and handles it: the Emergency screen shows an **"SOS cannot
> send SMS"** banner, and its **Fix** button opens the app's Settings page with
> the exact steps. Manually:
>
> `Settings → Apps → NavAlert → ⋮ (top-right) → Allow restricted settings`,
> then grant SMS.

### Permissions

Grant **Location** at minimum — the destination alarm cannot work without it.
Everything else is optional and the app runs if you deny it.

> ⚠️ Triggering SOS with real contacts saved sends **real SMS** and consumes
> prepaid load. Use a test contact for demonstrations.

---

## 3. Building from source

### Check the machine first

The repo ships an environment checker. It is read-only — it installs nothing and
changes nothing — and it reports every gap with the command that closes it:

```bash
# macOS / Linux
.claude/skills/setup-navalert/doctor.sh

# Windows
powershell -ExecutionPolicy Bypass -File .claude\skills\setup-navalert\doctor.ps1
```

Exit code 0 means the machine is ready. **These are ordinary scripts — you do
not need Claude Code to run them.** Users of it get the same thing as
`/setup-navalert`, which also walks the installs, and `/run-navalert` to launch
the app.

On **Aurora DX** or another Fedora Atomic image, `install-aurora.sh` beside them
installs everything into `$HOME`. Do not `rpm-ostree install` the toolchain:
`/usr` is read-only there and layering slows every later image update, whereas
nothing NavAlert needs has to live outside your home directory.

Two results the doctor deliberately does **not** flag, because neither is a
fault — do not "fix" them:

- `java -version` reporting an old JRE. Gradle uses `JAVA_HOME`, not PATH.
- `ANDROID_HOME` being unset. Flutter finds the SDK at the default path anyway.

### Toolchain

| Tool | Version used for v1.1.0 |
|---|---|
| Flutter SDK | **3.41.9** (stable) |
| Dart SDK | 3.11.5 — ships with Flutter |
| Android SDK | API 26 minimum · compiled and targeted at **API 36** |
| JDK | 17 recommended |

Gradle 8.14 is fetched by the wrapper — do not install it separately.

**Match the Flutter version.** It is pinned because it decides how
`pubspec.lock` resolves: a machine on a different Flutter rewrites the lockfile
on every `pub get`, and it then collides on every merge.

```bash
flutter --version     # expect 3.41.9
flutter doctor        # Flutter and Android toolchain must be clean
```

### Build

```bash
git clone https://github.com/AlasdairDev/navalert.git
cd navalert
flutter pub get
flutter build apk --release
```

`flutter pub get` reads `pubspec.yaml` + `pubspec.lock` and fetches all 152
packages. Nothing is downloaded by hand.

> **Do not run `flutter pub upgrade`.** `pubspec.lock` pins the exact versions
> v1.1.0 was built and tested against.

The build produces two byte-identical copies:

| Path | Filename |
|---|---|
| `build/app/outputs/apk/release/` | **`NavAlert-release.apk`** ← distribute this |
| `build/app/outputs/flutter-apk/` | `app-release.apk` |

### Before committing

```bash
flutter analyze     # expect: No issues found
flutter test        # expect: 286 passing
```

Respect every `// DO NOT MODIFY LOGIC - CAPSTONE DEFENSE CRITICAL:` block —
there are 15 across 8 files (Dart and Kotlin), each naming what it protects and
what breaks without it.

---

## 4. Testing checklist

Run these on a **physical handset with a SIM**. None can be verified on an
emulator: an AVD has no radio, no carrier, no audio sink, and cannot deliver
volume-key events to a media session.

Set up first: complete onboarding, save **one test emergency contact**, and plan
a trip (search a destination → *Show Commute Guide* → *Start Trip*).

### 4.1 Lock-screen notification

1. Start a trip.
2. Lock the phone.

**Expect:** the trip card on the lock screen showing destination, remaining
distance and ETA, with **SOS · Open in App · End trip** actions — contents
visible, not replaced by "Contents hidden."

**If it fails:** you almost certainly upgraded in place. Uninstall
([§1](#1-mandatory-prerequisite-uninstall-any-previous-build)) and reinstall.

### 4.2 Blue dot and auto-recenter

1. Start a trip with the destination alarm **off** — the map layout only appears
   in guide-first mode.
2. Confirm the blue dot is present immediately, centred in the map band above
   the guide sheet.
3. Drag the map away from the dot. A **recenter** button appears.
4. Stop touching the map and wait **12 seconds**.

**Expect:** the camera returns to the dot on its own; the dot tracks you as you
move.

**If it fails, note *when*** — it distinguishes two different mechanisms:

- Missing from the moment the screen opens → cold-start GPS seeding.
- Disappears only after you touch the map → the 12 s follow re-arm.

### 4.3 Volume shortcuts

The fake call fires on a **squeeze** — Volume-Up and Volume-Down within 500 ms —
not a triple Volume-Down. The shortcuts only arm while the screen is off **or**
NavAlert is backgrounded, so press Home first.

1. With the app backgrounded, **press both volume buttons together**.

**Expect:** the fake call screen appears.

2. Now press **Volume Down** three times quickly, as if turning music down.

**Expect:** nothing happens — only the volume changes. This is the regression
being guarded: three taps in one direction used to launch a fake call, and on a
real commute the phone is always pocketed or backgrounded, so ordinary volume
adjustment kept triggering it.

3. Press **Volume Up** three times quickly.

**Expect:** SOS fires. This one is still a triple-press, so **use a test contact**
— it sends a real SMS.

### 4.4 Fake call volume

1. Trigger a fake call (Emergency screen, or the squeeze above).
2. While it rings, press **Volume Down** several times.

**Expect:** the volume lowers and **stays** lowered. No slider flashing
repeatedly, no level running up and down on its own.

### 4.5 SMS delivery and offline fallback

Enable **Airplane Mode**, then hold SOS for 3 seconds.

**Expect:** *"Failed: Phone radio is off — turn off Airplane Mode"* — **not** a
success message. This is the whole point of the delivery-tracking work: the app
must never claim an SMS was sent when it was not.

Then disable Airplane Mode and repeat.

**Expect:** *"Emergency SMS Sent"* **and** the message actually arriving on the
contact's phone. Verify both — the first without the second is the failure mode
this feature exists to eliminate.

Also worth confirming: with no prepaid load, the failure names the load rather
than blaming the signal.

### 4.6 Restricted settings (fresh sideload only)

Only reproducible if the install was flagged as sideloaded — see
[§2](#2-installation-over-usb).

1. Open the **Emergency** tab.

**Expect:** an amber **"SOS cannot send SMS"** banner. Tapping **Fix** shows the
⋮-menu walkthrough and deep-links to Settings; the banner clears on return once
the permission is allowed.

---

## 5. Signing

The release APK is signed with the **debug key** — the Flutter template default
in `android/app/build.gradle.kts` was deliberately kept.

This is appropriate for an academic defense: the APK installs and runs normally.
It is **not** Play Store publishable, and it is why swapping between builds from
different machines throws `INSTALL_FAILED_UPDATE_INCOMPATIBLE`. Adding a
production keystore is a `signingConfigs` block whenever it is needed.

---

## 6. Troubleshooting

| Problem | Fix |
|---|---|
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | Uninstall the existing build first — different signing key. |
| Lock-screen notification still missing | You upgraded in place; the old `navalert_trip` channel persists. Uninstall and reinstall. |
| "App was denied access to SMS" | Restricted settings. Use the in-app **Fix** button, or `Settings → Apps → NavAlert → ⋮ → Allow restricted settings`. |
| Map blank on **first** load | Tiles need internet once. Afterwards they render from disk, including after a force-close. |
| Map goes grey mid-session on an **emulator** | Emulator DNS flaking, not a code fault. Check `adb logcat -s flutter:*` for `Failed host lookup`. Restart with `emulator -avd <name> -dns-server 8.8.8.8`. |
| No GPS on emulator | `adb emu geo fix 121.0108 14.5979` — **longitude first**. Anything outside Metro Manila is outside the service area. |
| Blue dot missing on Home | The dot renders only for a **real** fix; a fallback position deliberately shows no dot rather than a confident wrong one. |
| Gradle fails after pulling changes | `flutter clean && flutter pub get`. The first build after a clean is slow — that is normal. |
| `classes.dex … used by another process` (Windows) | Stale Gradle daemon: `cd android && ./gradlew --stop`, then rebuild. |
| Want a clean first-run state without reinstalling | `adb shell pm clear ph.edu.pup.navalert` — wipes database, settings and tile cache, and revokes permissions. |

Still stuck? Run `flutter doctor -v` and share the full output — it shows
exactly which part of the toolchain is missing.
