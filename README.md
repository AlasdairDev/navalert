# NavAlert (Flutter / Dart)

> **NavAlert: An Integrated Route Optimization, Fare Estimation, Adaptive
> Destination Alarm, and Emergency Safety System for Metro Manila PUV Commuters**
>
> Capstone Project — BSIT, Polytechnic University of the Philippines.
> A Dart/Flutter implementation of the Chapter 3 Methodology (Flutter + Dart,
> **MVVM**, SQLite + SQLCipher, Nominatim, OpenStreetMap, Native Android SMS,
> Google Maps Intent), rewritten from the earlier C#/.NET MAUI prototype.

NavAlert helps commuters who doze off on long, unpredictable PUV rides. It plans
the trip (real jeepney/bus routes + fares), then watches GPS and wakes the rider
with an escalating alarm timed to the vehicle's real speed — plus offline
emergency tools (SOS SMS, fake call) for late-night safety.

---

## Tech stack (per the paper's *Development Tools*)

| Layer | Choice |
|---|---|
| Language | **Dart** |
| Framework | **Flutter** |
| Architecture | **MVVM** (Model · View · ViewModel via `provider` / `ChangeNotifier`) |
| Local database | **SQLite** encrypted at rest with **SQLCipher** (`sqflite_sqlcipher`, key in Android Keystore via `flutter_secure_storage`) |
| Destination search | **Nominatim API** (search + reverse geocoding) |
| Map tiles | **OpenStreetMap** (`flutter_map`) |
| Road route line | **OSRM** (free/open-source, OSM-based) |
| Transit routes & fares | **DOTC / Sakay.ph Philippine GTFS** (bundled) + LTFRB fare matrix |
| Emergency alerts | **Native Android SMS** (`SmsManager` via platform channel) |
| Return-route assist | **Google Maps Intent** (`url_launcher`) |
| Min. target | Android 8.0 (API 26) |

Package id: `ph.edu.pup.navalert`.

---

## Feature map (paper → code)

| Requirement | Implementation |
|---|---|
| R1 Multi-stage escalating alarm | `services/sound_service.dart`, `views/active_trip_view.dart` (Stages 1–3, slide-to-dismiss) |
| R2 Continuous GPS monitoring | `viewmodels/trip_viewmodel.dart` (geolocator stream + Android foreground service) |
| R3 Speed-based adaptive trigger distance | `services/adaptive_alarm_engine.dart` (rolling avg speed × reaction window, 5 km cap) |
| R4 Behavioural learning | reaction time (`awake_seconds`) per trip **widens the trigger distance *and* raises alarm loudness/vibration** for slow dismissers |
| R5 Offline-first | SQLite (`services/database_service.dart`), offline GPS alarms, native SMS |
| R6 Commute guide + fares | **real GTFS jeepney/bus routes** (`services/gtfs_service.dart`) with LTFRB fares; synthetic `services/route_engine.dart` as fallback |
| R7 Fake call | `views/fake_call_view.dart`, custom recordings via `record`, triple Volume-Down shortcut |
| R8 SOS via Native Android SMS | `services/sos_service.dart` + `MainActivity.kt` SmsManager channel, triple Volume-Up shortcut |
| UC-4 Pin drop-off on map | `views/pin_on_map_view.dart` (tap the map, reverse-geocode, confirm) |
| Overshoot detection + rerouting | consecutive increasing-distance latch → Google Maps `google.navigation:` intent (clipboard fallback) |
| Database schema (Tables 15–29) | `services/database_service.dart` — all 13 tables, 8 FKs, unique indexes |
| Lock Screen Widget (Figure 25) | `services/trip_notification_service.dart` — ongoing trip notification + "Open in App" / "End trip" |
| Stage time-escalation (Fig. 27–28) | Stage 2 after 30 s unresponsive; Stage 3 after Stage 2 unresponsive or third snooze; snoozed alarms re-fire |
| "Signal Lost" fallback alarm (UC-1) | GPS watchdog fires a fallback alarm after 90 s without a fix |
| app_state prompts (Table 15) | incomplete-setup banner (Home) + SOS insufficient-load warning (Emergency), dismissals persisted |
| SOS queue-and-retry (UC-7) | failed SOS SMS retried every 30 s; SMS permission requested proactively on the Emergency tab |
| Data Backup (Figure 33) | Settings → Import/Export JSON (with confirmation before overwrite) |
| History (Figure 30) | keyword + calendar-date filter + sort; delete a trip with confirmation |

All 20 GUI screens (Figures 14–33) are implemented under `lib/views/`.

---

## Architecture — MVVM (literal, per the *Development Tools* section)

```
lib/
  models/        Model        domain entities (Data Dictionary Tables 15–27)
  views/         View         all 20 screens (Figures 14–33)
  viewmodels/    ViewModel    ChangeNotifier state via provider:
                              app · home · trip · emergency · history
  services/      Domain/data  SQLite+SQLCipher database, adaptive alarm engine,
                              route/fare engine, GTFS service, Nominatim
                              geocoding, OSRM road path, SOS SMS, sounds,
                              lock-screen widget, volume-key channel
  core/          Theme        colours + component styling (the polish hub)
```

Views never touch the database directly — every read/write goes through a
ViewModel, which exposes state the UI observes and reacts to.

> **Polishing the UI?** Each view file has a `UI/UX MAP` header comment
> classifying its parts as `[NEED]` (functional wiring — don't remove),
> `[EDIT]` (free to restyle), or `[WANT]` (polish ideas). The legend and the
> whole colour/style surface live in `lib/core/theme.dart`.

---

## Prerequisites

- Flutter 3.x (`flutter doctor`)
- Android SDK — a device or emulator on Android 8.0 (API 26)+

## Run it

The Flutter project **is the repository root** (no subfolder).

```powershell
flutter pub get

# on a connected phone or a running emulator:
flutter run

# debug APK:
flutter build apk --debug
adb install build\app\outputs\flutter-apk\app-debug.apk

# release APK (smooth maps; use this for field testing):
flutter build apk --release
```

Start the bundled emulator first, if needed:

```powershell
flutter emulators --launch Pixel_6_2
flutter run
```

> If the emulator ever shows a black screen, **Cold Boot** it
> (Device Manager → ⌄ → Cold Boot Now) — it's a stale-snapshot issue, not the app.

---

## Run it in VS Code (step-by-step — easiest)

This is the recommended way to develop: you get **hot reload** (see code changes
in ~1 second without restarting), breakpoints, and the device picker.

### 1. One-time setup

1. **Install the Flutter SDK** (if you haven't): <https://docs.flutter.dev/get-started/install>
   — and make sure `flutter` works in a terminal: `flutter doctor`.
2. **Install VS Code**: <https://code.visualstudio.com/>
3. In VS Code, open the **Extensions** panel (`Ctrl+Shift+X`) and install:
   - **Flutter** (by Dart Code) — this also installs the **Dart** extension.
4. Make sure an Android device is available:
   - **Emulator:** open **Android Studio → Device Manager → Create/▶ a device** (any phone, API 26+), **or**
   - **Real phone:** enable **Developer options → USB debugging**, plug it in, tap **Allow**.

### 2. Open the project

- **File → Open Folder…** and pick the project's **root folder** (the one that
  contains `pubspec.yaml` — that's this folder, *not* a subfolder).
- VS Code will detect Flutter. If it pops up *"Get packages / Run pub get?"*,
  click **Yes**. (Or run it yourself — see next step.)

### 3. Get the dependencies

- Open `pubspec.yaml` and hit **Save** (VS Code auto-runs `flutter pub get`), **or**
- Open the terminal (`` Ctrl+` ``) and run:
  ```powershell
  flutter pub get
  ```

### 4. Pick a device

- Look at the **bottom-right of the VS Code status bar** — it shows the current
  device (e.g. *"No Device"* or *"Chrome"*).
- **Click it** → a menu appears at the top → choose your **emulator** or
  **connected phone**. (If your emulator isn't running yet, this menu can start
  it for you.)

### 5. Run it ▶

- Press **F5** (**Run → Start Debugging**) — builds, installs, and launches the
  app with the debugger attached. First build takes a couple of minutes; after
  that it's fast.
- Prefer no debugger? Press **Ctrl+F5** (**Run Without Debugging**).

### 6. Make changes live (hot reload)

- Edit any file under `lib/` and **Save** (`Ctrl+S`) → the app updates instantly
  (**hot reload** ⚡). The little status area also has buttons for:
  - **Hot Reload** (⚡) — keep app state, apply UI/logic changes.
  - **Hot Restart** (🔄) — restart the app fresh (use after changing `main()`,
    providers, or startup code).
  - **Stop** (⏹).

### 7. First-run permissions

On first launch the app asks for **Location** (and, when you open the Emergency
tab, **SMS**). Tap **Allow** so GPS tracking and SOS work.

### VS Code quick reference

| Action | Shortcut |
|---|---|
| Run with debugger | `F5` |
| Run without debugging | `Ctrl+F5` |
| Hot reload (save also does this) | `Ctrl+S` |
| Hot restart | `Ctrl+Shift+F5` |
| Stop | `Shift+F5` |
| Command palette (search any command) | `Ctrl+Shift+P` → type "Flutter" |
| Open terminal | `` Ctrl+` `` |

### If something goes wrong

- **"No devices"** → click the device name in the status bar and start/select
  one; or run `flutter devices` in the terminal.
- **Red squiggles / packages not found** → run `flutter pub get`, then
  **Ctrl+Shift+P → "Dart: Restart Analysis Server"**.
- **Emulator black screen** → cold-boot it (Device Manager → ⌄ → **Cold Boot Now**).
- **General health check** → run `flutter doctor` and fix anything with an ✗.
- **Clean rebuild** → `flutter clean` then `flutter pub get`, then run again.

## Editing the UI/UX live (hot reload)

You can see UI changes **in real time (~1 second)** while you edit — this is the
normal Flutter workflow, no rebuild needed.

1. **Run the app once** (F5) on the emulator or a phone, and leave it running.
2. Edit any file under `lib/views/` or `lib/core/theme.dart` — change a colour,
   text, padding, icon, etc.
3. **Save** (`Ctrl+S`) → the app **redraws instantly** on the device and keeps
   its current screen/state. Edit → save → glance → repeat.

**Hot Reload ⚡ vs Hot Restart 🔄**

- **Hot Reload** (automatic on save): applies changes to `build()` methods —
  colours, text, layout, styling. This is ~99% of UI/UX work and it's instant.
- **Hot Restart** (`Ctrl+Shift+F5`): needed after changing `main()`, providers,
  `initState`, **or adding a new image to `pubspec.yaml`**. Resets app state.

> **Tip:** almost all styling lives in `lib/core/theme.dart` (the colour tokens
> and component styles, each tagged `[EDIT]`). Change a colour there + save and
> **every screen restyles at once**, live.

**Helpful extras**

- **Widget Inspector** — click a widget in the running app to jump to the code
  that draws it (`Ctrl+Shift+P → "Dart: Open DevTools"` → Inspector). Great for
  "which file is this box in?".
- The **⚡ / 🔄 / ⏹** buttons appear in VS Code while the app runs.

**Notes**

- There's no drag-and-drop visual designer — you edit code and see the result
  live (hot reload *is* the preview).
- Preview on the **emulator or a real phone** for accurate rendering; a real
  Android phone is the smoothest and most accurate way to hot-reload the UI.
- See the per-screen `UI/UX MAP` header comment in each `lib/views/*.dart` file
  for what's safe to restyle (`[EDIT]`) vs. functional wiring to leave alone
  (`[NEED]`). The legend is at the top of `lib/core/theme.dart`.

## Testing the alarm on the emulator

The adaptive alarm needs movement:

1. **Extended controls (⋯) → Location → Routes**, pick two points in Metro
   Manila and *Play route* — or `adb emu geo fix <lng> <lat>` to jump the GPS.
2. In NavAlert: search a destination → *Show Commute Guide* → *Enable Alarm*
   → *Start Trip*.
3. Watch Stage 1 (vibration) → Stage 2 (sound) → Stage 3 (full-screen WAKE UP)
   fire as the position approaches; drive past to trigger the overshoot prompt.

SMS, wake-locks, and battery behave fully only on a **physical device** — the
emulator only simulates SMS delivery and can't hold a locked-screen background
service over a real commute.

## Unit tests

```powershell
flutter test
```

Covers the adaptive lead-radius math, stage escalation, the consecutive-fix
overshoot latch, behavioural window learning, and the LTFRB fare matrix /
mode-priority filters.

---

## Transit data (GTFS)

The commute guide matches trips against real Metro Manila jeepney and bus
routes from the **DOTC Philippine GTFS feed** (maintained by
[Sakay.ph](https://github.com/sakayph/gtfs)), bundled as a compact 0.77 MB
gzipped asset at `assets/gtfs/routes.json.gz`. It's decompressed and parsed once
in a background isolate, then used to find direct routes with real boarding /
alighting stops. Trips with no direct GTFS route fall back to the synthetic
route engine. See `assets/gtfs/NOTICE.md` for attribution and license terms.

To regenerate the asset from a fresher GTFS feed:

```powershell
python tool/gen_gtfs.py <path-to-gtfs-dir>
```

The alarm/ringtone audio assets are generated by `dart run tool/gen_sounds.dart`.

---

## Notes & limitations (per *Scope and Limitations*)

- The commute guide (search, routes, fares) needs internet at **planning time**;
  the alarm and SOS work **offline** afterwards.
- GTFS coverage is **jeepney + bus** and **direct routes only** — trips needing
  a transfer, or served only by UV Express (absent from the feed), use the
  synthetic LTFRB-rate estimate. Fares/times are estimates, not live data.
- **Android only.** Alarms are loud and escalating, but no system can guarantee
  every rider wakes up.
- The **volume-button SOS/fake-call shortcut** works while the app is
  foregrounded; a locked-screen/background interceptor is future work.
- SOS SMS requires a SIM with sufficient prepaid load.

## Attribution

Transit data © Department of Transportation (DOTC/DOTr), Philippines, via the
Philippine Transit App Challenge and Sakay.ph, used under the DOTC Developer
License Agreement for assisting mass-transportation riders. Map tiles ©
OpenStreetMap contributors. Geocoding © Nominatim / OpenStreetMap.
