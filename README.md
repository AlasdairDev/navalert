# NavAlert (Flutter/Dart)

> **NavAlert: An Integrated Route Optimization, Fare Estimation, Adaptive Destination
> Alarm, and Emergency Safety System for Metro Manila PUV Commuters**
>
> Capstone Project — BSIT, Polytechnic University of the Philippines.
> Dart/Flutter rewrite of the original C#/.NET MAUI prototype ("Alarma"),
> aligned with the Chapter 3 Methodology (Flutter + Dart, MVVM, SQLite,
> Nominatim API, OpenStreetMap).

## Feature map (paper → code)

| Requirement | Implementation |
|---|---|
| R1 Multi-stage escalating alarm | `services/sound_service.dart`, `views/active_trip_view.dart` (Stages 1–3, slide-to-dismiss) |
| R2 Continuous GPS monitoring | `viewmodels/trip_viewmodel.dart` (geolocator stream + Android foreground service) |
| R3 Speed-based adaptive trigger distance | `services/adaptive_alarm_engine.dart` (rolling avg speed × reaction window, 5 km cap) |
| R4 Behavioural learning | reaction time (`awake_seconds`) recorded per trip → widens/shrinks the reaction window |
| R5 Offline-first | SQLite (`data/database_service.dart`), offline GPS alarms, native SMS |
| R6 Commute guide + fares | `services/route_engine.dart` (LTFRB fare matrix, step-by-step guide, mode priority) |
| R7 Fake call | `views/fake_call_view.dart`, custom recordings via `record`, triple Volume-Down shortcut |
| R8 SOS via Native Android SMS | `services/sos_service.dart` + `MainActivity.kt` SmsManager channel, triple Volume-Up shortcut |
| Overshoot detection + rerouting | consecutive increasing-distance latch → Google Maps `google.navigation:` intent |
| Database schema (Tables 15–29) | `services/database_service.dart` — all 13 tables, FKs and unique indexes as specified |
| Lock Screen Widget (Figure 25) | `services/trip_notification_service.dart` — ongoing trip notification with distance/ETA + "Open in App"/"End trip" |
| Stage time-escalation (Fig. 27–28) | Stage 2 after 30 s unresponsive, Stage 3 after Stage 2 unresponsive or third snooze |
| "Signal Lost" fallback alarm (UC-1) | GPS watchdog in `viewmodels/trip_viewmodel.dart` fires a fallback alarm after 90 s without a fix |
| app_state prompts (Table 15) | incomplete-setup banner on Home; SOS insufficient-load warning on Emergency — both persist their dismissed flags |
| Call 911 logging (Table 27) | `sos_events.call_911_pressed` recorded by `services/sos_service.dart` |
| SOS queue-and-retry (UC-7) | failed SOS SMS retried every 30 s until delivered |
| Data Backup (Figure 33) | Settings → Import/Export JSON backups via `AppViewModel` |
| History calendar filter (Figure 30) | `viewmodels/history_viewmodel.dart` — keyword + date filter + sort |

Architecture: **MVVM (literal, per the Development Tools section)** —

```
lib/
  models/        Model        (domain entities, Data Dictionary Tables 15–27)
  views/         View         (all 20 screens, Figures 14–33)
  viewmodels/    ViewModel    (ChangeNotifier state via provider: app, home,
                               trip, emergency, history)
  services/      Domain/data  (SQLite database, adaptive alarm engine, route/
                               fare engine, Nominatim geocoding, SOS SMS,
                               sounds, lock-screen widget, volume keys)
  core/          Theme
```

Views never touch the database directly — every read/write goes through a
ViewModel, which exposes state the UI observes and reacts to.

## Prerequisites

- Flutter 3.x (`flutter doctor`)
- Android SDK (device or emulator, Android 8.0 / API 26+)

## Run it

```powershell
cd navalert_flutter
flutter pub get

# on a connected phone or a running emulator:
flutter run

# or build an installable debug APK:
flutter build apk --debug
adb install build\app\outputs\flutter-apk\app-debug.apk

# release APK for field testing:
flutter build apk --release
```

To start the bundled emulator first:

```powershell
flutter emulators --launch Pixel_6_2
flutter run
```

## Testing the alarm on the emulator

The adaptive alarm needs movement. On the emulator:

1. Open **Extended controls (⋯) → Location → Routes**, pick two points in
   Metro Manila, set playback speed, and **Play route** — or use
   `adb emu geo fix <lng> <lat>` to jump the GPS.
2. In NavAlert: search a destination along that route → *Show Commute
   Guide* → *Enable Alarm* → *Start Trip*.
3. Watch Stage 1 (vibration) → Stage 2 (sound) → Stage 3 (full-screen
   WAKE UP) fire as the simulated position approaches; drive past the
   destination to trigger the overshoot prompt.

SMS and vibration behave fully only on a **physical device** (the SOS SMS
needs a SIM with load; the emulator only simulates delivery).

## Unit tests

```powershell
flutter test
```

Covers the adaptive lead-radius math, stage escalation, the
consecutive-fix overshoot latch, behavioural window learning, and the
LTFRB fare matrix / mode-priority filters.

## Notes & limitations (per Scope and Limitations)

- The commute guide (search, route suggestions, fares) needs internet at
  planning time; alarms and SOS work offline afterwards.
- Route/fare figures are heuristic estimates (LTFRB rates + Metro Manila
  average PUV speeds) — informal PUV routes have no official GTFS feed.
- Android only; alarms are loud and escalating but no system can
  guarantee every rider wakes up.
