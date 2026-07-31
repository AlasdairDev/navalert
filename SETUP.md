# NavAlert — Setup & Install Guide

**For groupmates and the UI team.** Two paths below: pick the one that matches
what you need. You do **not** need to download any dependency by hand — Flutter
fetches all 137 packages for you from the two files already in this repo.

---

## Path A — "I just want to run the app on my phone"

**You don't need Flutter, Android Studio, or any of this repo.** Just install
the APK.

1. Get `navalert-release.apk` (78 MB) from the group Drive folder.
2. Copy it to your Android phone (Android 8.0 / API 26 or newer).
3. Open it with the Files app and tap **Install**.
4. Android will warn about "unknown sources" — allow it for Files/Chrome, then
   tap Install again. This is normal for an app not from the Play Store.

**If install fails with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`:** you already have
an older NavAlert signed with a different key. **Uninstall the old one first**,
then install again.

**First launch:** the app asks for Location, Notifications, SMS and Bluetooth.
Grant **Location** at minimum — the destination alarm cannot work without it.
Every other permission is optional and the app still runs if you deny them.

> ⚠️ Real SMS is sent when you trigger SOS with contacts saved. Don't demo SOS
> with real contacts unless you mean it. It also needs prepaid load.

---

## Path B — "I need to edit the code" (UI team)

### 1. Install the toolchain

Match these versions. Version drift is the #1 cause of "it builds on your
machine but not mine."

| Tool | Version used to build this project | Get it |
|---|---|---|
| **Flutter SDK** | **3.41.9** (stable channel) | <https://docs.flutter.dev/get-started/install/windows> |
| **Dart SDK** | 3.11.5 — *ships with Flutter, don't install separately* | — |
| **Android Studio** | Latest — needed for the Android SDK + emulator | <https://developer.android.com/studio> |
| **Android SDK** | API 26 (Android 8.0) minimum · API 35 recommended | Android Studio → SDK Manager |
| **Java JDK** | 17 recommended (this machine has 1.8, see note below) | Bundled with Android Studio |
| **Git** | Any recent version | <https://git-scm.com/downloads> |
| **VS Code** *(optional)* | + Flutter and Dart extensions | <https://code.visualstudio.com> |

Gradle **8.14** is downloaded automatically by the wrapper — do not install it.

Verify before going further:

```powershell
flutter --version     # expect 3.41.9
flutter doctor        # every line should be a checkmark
```

`flutter doctor` must be clean for Flutter **and** Android toolchain. If it
reports Android licences, run `flutter doctor --android-licenses` and accept all.

### 2. Get the code

```powershell
git clone https://github.com/AlasdairDev/navalert.git
cd navalert
git checkout ui-handoff-baseline
```

`ui-handoff-baseline` is the locked, verified starting point for UI work.

### 3. Install dependencies — this is the "dependencies file" step

```powershell
flutter pub get
```

That single command reads `pubspec.yaml` + `pubspec.lock` and downloads **all
137 packages**. There is nothing to download manually and nothing to commit.

> **Do NOT run `flutter pub upgrade`.** `pubspec.lock` pins the exact package
> versions this project was built and tested against. Upgrading silently moves
> everyone onto different versions and is a classic source of "works on mine,
> broken on yours." If you genuinely need a new package, tell the team first.

### 4. Run it

```powershell
flutter devices                 # confirm your phone/emulator is listed
flutter run                     # debug build, hot reload enabled
```

Press `r` in the terminal to hot-reload after a change, `R` for a full restart,
`q` to quit.

No emulator yet? `flutter emulators --launch Pixel_6_2`, or create one in
Android Studio → Device Manager (API 26+).

### 5. Build a shareable APK

```powershell
flutter build apk --release
```

Output: `build\app\outputs\flutter-apk\app-release.apk`

Use `--release` for anything you hand to someone else — debug builds render
maps noticeably slower and look janky in a demo.

---

## Direct dependencies (21)

All are pulled automatically by `flutter pub get`. Listed here so you can see
what the app is built on.

| Package | Version | Purpose |
|---|---|---|
| `provider` | ^6.1.2 | MVVM state management |
| `sqflite_sqlcipher` | ^3.1.0+1 | SQLite encrypted with SQLCipher AES-256 |
| `flutter_secure_storage` | ^9.2.2 | DB key in the Android Keystore |
| `path` / `path_provider` | ^1.9.0 / ^2.1.4 | Filesystem paths |
| `http` | ^1.2.2 | Nominatim geocoding calls |
| `flutter_map` | ^7.0.2 | OpenStreetMap tile rendering |
| `flutter_map_cancellable_tile_provider` | ^3.0.2 | Cancels off-screen tile loads |
| `latlong2` | ^0.9.1 | Coordinate maths |
| `geolocator` | ^13.0.1 | GPS stream, speed, background service |
| `url_launcher` | ^6.3.0 | Google Maps reroute intent |
| `permission_handler` | ^11.3.1 | Runtime permissions |
| `uuid` | ^4.5.1 | Primary keys |
| `clock` | ^1.1.1 | Injectable clock (virtual time in tests) |
| `vibration` | ^2.0.0 | Alarm haptics |
| `audioplayers` | ^6.1.0 | Alarm + ringtone playback |
| `record` | ^6.0.0 | Custom fake-call recordings |
| `flutter_local_notifications` | ^17.2.3 | Lock-screen trip widget |
| `home_widget` | ^0.9.3 | Home-screen App Widget |
| `cupertino_icons` | ^1.0.8 | Icon set |

**Dev dependencies:** `flutter_test`, `integration_test`, `flutter_lints ^4.0.0`,
`fake_async ^1.3.1`.

---

## Before you commit (UI team)

```powershell
flutter analyze     # expect: No issues found
flutter test        # expect: 165 passing
```

If either regresses, your change touched logic rather than styling — revert and
restyle instead. See the **UI TEAM — HAND-OFF RULES** section in
[README.md](README.md), and respect every
`// DO NOT MODIFY LOGIC - CAPSTONE DEFENSE CRITICAL:` block.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `flutter: command not found` | Flutter's `bin` folder isn't on your PATH. Re-check the install guide, then reopen your terminal. |
| `flutter doctor` flags Android licences | `flutter doctor --android-licenses`, accept all. |
| Gradle build fails after pulling changes | `flutter clean` then `flutter pub get`. First build after a clean is slow (10+ min) — that's normal. |
| `Could not resolve all files for configuration` | You're offline or behind a proxy; Gradle needs internet on first build. |
| App installs but the map is blank | Map tiles need internet. Only the alarm and SOS work offline. |
| App builds but no GPS on emulator | Set a location in the emulator's ⋯ menu → Location, then press Set. |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | Uninstall the existing NavAlert first (different signing key). |
| Java version warnings during build | This machine builds with JDK 1.8; JDK 17 is recommended if you hit Gradle/Java errors. Point Android Studio at JDK 17 under Settings → Build Tools → Gradle. |

Still stuck? Run `flutter doctor -v` and send the full output to the group — it
shows exactly which part of the toolchain is missing.
