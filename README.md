# NavAlert

**Offline-Capable Commute Monitoring & Personal Safety System**

![Platform](https://img.shields.io/badge/platform-Android%208.0%2B-3DDC84)
![Flutter](https://img.shields.io/badge/Flutter-3.41-02569B)
![Dart](https://img.shields.io/badge/Dart-3.11-0175C2)
![Kotlin](https://img.shields.io/badge/native-Kotlin-7F52FF)
![Architecture](https://img.shields.io/badge/architecture-MVVM-7C6BC4)
![Tests](https://img.shields.io/badge/tests-280%20passing-success)
![Version](https://img.shields.io/badge/release-v1.0.0-B39DDB)

> Capstone Project — BSIT, Polytechnic University of the Philippines.
>
> *An Integrated Route Optimization, Fare Estimation, Adaptive Destination
> Alarm, and Emergency Safety System for Metro Manila PUV Commuters.*

NavAlert plans a Metro Manila commute over **real jeepney and bus routes**,
prices it against the **LTFRB fare matrix**, and guides the rider through it
step by step over a live map. For riders who doze off on long, unpredictable PUV
rides, an **optional** destination alarm can be armed on top — and for
late-night safety, an SOS and a fake incoming call are always one discreet
gesture away.

---

## Architecture: a commute guide first, an alarm second

**This ordering is deliberate and enforced throughout the app.** The
step-by-step commute guide is the product; the alarm is an add-on the rider may
never switch on.

| | Primary | Secondary |
|---|---|---|
| **What** | Route optimization · step-by-step guidance · fare estimation | Adaptive destination alarm |
| **Default** | Always on — every trip runs the guide | **Off.** Opt-in per trip |
| **Where** | `route_view.dart`, `commute_guide_sheet.dart`, `transit_router.dart` | `adaptive_alarm_engine.dart`, `active_trip_view.dart` |

The primary action reads **"Start Trip"**, not "Enable Alarm" — what the button
begins is trip *monitoring*, which is what carries the live guide. With the
alarm **off**, the Active Trip screen is a live map with the guide floating over
it. With the alarm **on**, it becomes the reassurance layout (moon badge, "Get
some rest. We got you.") and the guide collapses to a handle, because that rider
has handed the trip over and is expected to sleep.

---

## Core features

### Verified SMS architecture

The SOS does not report success until **the radio says so**.

The native bridge sends each message with a `PendingIntent` per multipart part
and waits for the sent-intent `BroadcastReceiver` before answering Flutter. It
distinguishes `RESULT_OK` from `RESULT_ERROR_NO_SERVICE`, `RESULT_ERROR_RADIO_OFF`
(airplane mode), `RESULT_ERROR_GENERIC_FAILURE` (typically insufficient prepaid
load) and `RESULT_ERROR_NULL_PDU`, and each surfaces as text the rider can act
on rather than a generic failure.

This replaced a handler that answered `success(true)` the moment `SmsManager`
accepted the request. That is only a handoff to the radio — with no signal or no
load the message is accepted synchronously and dies asynchronously with nothing
listening, so the app reported *"Emergency SMS Sent"* for a message that never
left the phone. **On this feature a false success is worse than a failure**,
because it stops the rider seeking help.

### Intelligent map tracking

The commute guide floats over a full-bleed map as a `DraggableScrollableSheet`.

- **Bottom-padded camera.** The blue dot is centred in the band of map left
  *visible above the sheet*, not behind it. The offset is resolved into a camera
  centre once per move — re-applying it per animation frame compounds and walks
  the camera off the rider within a few fixes.
- **Cold-start GPS seeding.** A cold GPS can take 30 s to produce its first
  reading. The map seeds from the OS's cached fix so it is never blank — an
  actual GPS reading, never the trip's origin, and never allowed to overwrite a
  live fix.
- **12-second auto-recenter.** Follow releases on a manual pan so the rider can
  look ahead, and re-arms after 12 s without a touch. Without that, one finger
  grazing the map while reaching for the guide sheet strands the camera
  permanently and the dot simply slides off screen.
- **Structural safety.** The SOS / Fake Call / Slide-to-Stop footer is a sibling
  *below* the sheet's region, not a layer over it, so the sheet is structurally
  incapable of covering the safety controls however far it is dragged.

### Public lock-screen notifications

The live trip status (destination, remaining distance, ETA, and **SOS · Open ·
End trip** actions) has to be readable while the rider is asleep.

It posts on a `navalert_trip_v2` channel at `IMPORTANCE_DEFAULT` with
`VISIBILITY_PUBLIC`. The version suffix is load-bearing: **a notification
channel's importance is fixed once the channel exists on the device** — Android
ignores later changes so a user's own setting is never overridden — so raising
importance without a new channel id changes nothing on an existing install.
Android 12+ files `IMPORTANCE_LOW` under "Silent", which most devices hide from
the lock screen entirely.

The two genuine foreground-service notifications (the volume-shortcut service
and the location stream) also declare `VISIBILITY_PUBLIC`, so a secured lock
screen no longer replaces them with "Contents hidden."

### Audio stability

Triggering a fake call used to make the system volume slider flash repeatedly
while the level ran away on its own.

The cause was **re-entrancy**, not the app fighting the user. The volume relay
called `adjustSuggestedStreamVolume(…, USE_DEFAULT_STREAM_TYPE, …)`, and
`USE_DEFAULT_STREAM_TYPE` resolves to the active **remote-volume media session**
when one exists — which this app holds permanently for the volume-button
shortcuts. Every relay routed straight back into its own handler and relayed
again.

Naming `STREAM_MUSIC` explicitly isolates the real stream, which is never
re-routed through a media session, and a `@Volatile` latch closes any other
re-entry path. Nothing in NavAlert writes a volume level, so a rider turning the
ringtone down mid-call has it stay down.

### Proactive permission UI

Android 13+ marks SMS a **restricted setting** for apps installed outside a
store, and refuses the grant with *"App was denied access to SMS"* — the in-app
request returns denied however many times it is asked, so re-prompting is
useless and silence is dangerous, because the rider believes SOS is armed.

NavAlert detects the permanently-denied state and surfaces it two ways: a
standing banner on the Emergency screen so it is discovered **before** an
emergency, and a walkthrough dialog naming the three-dot ⋮ menu step explicitly,
deep-linking to the app's own Settings page and re-checking the permission on
return.

### Offline routing and UI polish

- **On-device multimodal routing.** Real Metro Manila jeepney/bus routes from a
  bundled GTFS feed are searched with **Dijkstra** over a long-lived worker
  isolate — no server, no network.
- **Disk-cached OSM tiles.** A hand-written `CacheStore` persists tiles so the
  map survives a force-close in a dead zone.
- **Route polyline** rendered on-device over those tiles, with the origin dot
  and destination pin.
- **Adaptive launcher icon** generated across all five density buckets, with the
  emblem sized into the 72 dp safe zone so no launcher mask clips it.
- **60 fps SOS ring** driven by an `AnimationController` rather than a 100 ms
  timer, repainting only the indicator instead of the whole screen.

---

## What actually works offline

| Capability | Offline? |
|---|---|
| Step-by-step commute guide (once planned) | ✅ |
| Destination alarm, GPS monitoring, overshoot detection | ✅ |
| Map tiles already viewed | ✅ (disk cache) |
| SOS SMS | ✅ (native `SmsManager`, no data required) |
| Encrypted trip history / contacts / favourites | ✅ |
| Destination **search** (Nominatim) | ❌ needs network |
| Road **geometry** for the polyline (OSRM) | ❌ needs network |
| **First** download of a given map tile | ❌ needs network |

Planning a trip needs a connection. Riding it does not.

---

## Tech stack

| Layer | Choice |
|---|---|
| Language | **Dart** + **Kotlin** (native Android) |
| Framework | **Flutter** 3.41 |
| Architecture | **MVVM** (`provider` / `ChangeNotifier`) |
| Local database | **SQLite** + **SQLCipher**, key in the Android Keystore |
| Map tiles | **OpenStreetMap** via `flutter_map` + custom disk cache |
| Destination search | **Nominatim** |
| Road geometry | **OSRM** |
| Transit data | **DOTC / Sakay.ph GTFS** (bundled) + LTFRB fare matrix |
| Emergency SMS | Native **`SmsManager`** with sent-intent delivery tracking |
| Min / target SDK | Android 8.0 (API 26) / Android 16 (API 36) |

Package id: `ph.edu.pup.navalert` · Version **1.0.0+1**

### Native Kotlin integrations

| File | Responsibility |
|---|---|
| `MainActivity.kt` | SMS bridge with `PendingIntent` delivery tracking · lock-screen flags · audio-route queries |
| `MediaButtonService.kt` | Screen-off volume shortcuts via an always-active `MediaSession` with a remote `VolumeProvider` |
| `NavAlertWidgetProvider.kt` | Home-screen App Widget (`RemoteViews`) with one-tap SOS |

---

## Getting started

See **[SETUP.md](SETUP.md)** for the full installation guide, the mandatory
uninstall step, and the hardware testing checklist.

```bash
flutter pub get
flutter run
```

---

## Testing

```bash
flutter analyze   # expect: No issues found
flutter test      # expect: 280/280 passing
```

**20 suites, 280 tests**, covering the adaptive alarm engine, the fare matrix
and NCR bounds, the Dijkstra router against the real production GTFS feed, the
full `TripViewModel` state machine driven from a mock GPS stream on a virtual
clock, the commute-guide overlay geometry measured against a mounted widget
tree, the SOS failure-code contract, the three-second accidental-trigger guard,
and the disk tile cache.

They do **not** cover pixel rendering or radio behaviour. Those are verified on
hardware — see the checklist in [SETUP.md](SETUP.md).

---

## Attribution

Transit data © Department of Transportation (DOTC/DOTr), Philippines, via the
Philippine Transit App Challenge and Sakay.ph. Map tiles © OpenStreetMap
contributors, cached locally in line with the OSM tile usage policy. Geocoding ©
Nominatim / OpenStreetMap. Road geometry © OSRM.
