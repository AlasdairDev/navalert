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
