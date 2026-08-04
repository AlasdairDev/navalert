# NavAlert

![Platform](https://img.shields.io/badge/platform-Android%208.0%2B-3DDC84)
![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B)
![Dart](https://img.shields.io/badge/Dart-3.5-0175C2)
![Architecture](https://img.shields.io/badge/architecture-MVVM-7C6BC4)
![Tests](https://img.shields.io/badge/tests-262%20passing-success)
![Offline](https://img.shields.io/badge/maps-offline%20capable-B39DDB)

> **NavAlert: An Integrated Route Optimization, Fare Estimation, Adaptive
> Destination Alarm, and Emergency Safety System for Metro Manila PUV Commuters**
>
> Capstone Project — BSIT, Polytechnic University of the Philippines.
> A Dart/Flutter implementation of the Chapter 3 Methodology (Flutter + Dart,
> **MVVM**, SQLite + SQLCipher, Nominatim, OpenStreetMap, Native Android SMS,
> Google Maps Intent), rewritten from the earlier C#/.NET MAUI prototype.

NavAlert plans a Metro Manila commute over **real jeepney and bus routes**,
prices it against the **LTFRB fare matrix**, and guides the rider through it
step by step. For riders who doze off on long, unpredictable PUV rides, an
**optional** destination alarm can be armed on top — and for late-night safety,
an SOS and a fake incoming call are always one discreet gesture away.

---

## Architecture: a commute guide first, an alarm second

**This ordering is deliberate and is enforced throughout the app.** The
Step-by-Step Commute Guide is the product; the alarm is an add-on the rider may
never switch on.

| | Primary | Secondary |
|---|---|---|
| **What** | Route optimization · step-by-step guidance · fare estimation | Adaptive destination alarm |
| **Default** | Always on — every trip runs the guide | **Off.** Opt-in per trip |
| **Where** | `route_view.dart`, `commute_guide_sheet.dart`, `transit_router.dart` | `adaptive_alarm_engine.dart`, `active_trip_view.dart` |

How that shows up concretely:

- **The primary action says "Start Trip", not "Enable Alarm."** What the button
  begins is trip *monitoring*, which is what carries the live guide. Naming it
  after the alarm made an optional add-on look like the subject of the app.
- **The Trip Settings sheet leads with the trip.** "Monitoring to *X*. Your
  step-by-step guide runs for the whole trip." The destination alarm is one
  switch below it, **off by default**, with the alarm sound and vibration
  controls disabled until it is turned on.
- **The Active Trip screen is contextual.** With the alarm **off** the rider is
  navigating, so the screen becomes a **live map with the guide floating over
  it** — steps in a draggable sheet, the map tracking the rider above it, and
  the monitoring readouts demoted to a strip. Nothing is watching for them, so a
  large "Monitoring" badge would be advertising a service that is switched off.
  With the alarm **on**, the screen becomes the reassurance layout of Figure 24
  (moon badge, "Get some rest. We got you.") and the guide collapses to a
  handle — that rider has handed the trip over and is expected to sleep, so a
  map would be answering a question they are not asking.
- **The alarm can be armed mid-trip** from a chip on the monitoring screen, so
  starting without it is never a dead end.

---

## Project status

| Layer | Status |
|---|---|
| Core routing engine (GTFS + Dijkstra, fares) | ✅ Complete |
| State management (MVVM ViewModels) | ✅ Complete |
| Background alarm & trip monitoring services | ✅ Complete |
| Android native integration (SMS, volume shortcuts, widgets) | ✅ Complete |
| Local persistence (SQLCipher schema) | ✅ Complete |
| Offline map tile cache | ✅ Complete |
| Live trip map + camera tracking | ✅ Complete |
| UI / UX visual polish | ✅ Complete |
| Automated tests | ✅ **262 / 262 passing** |

Verify at any time:

```powershell
flutter analyze   # expect: No issues found
flutter test      # expect: 262/262 passing
```

---

## Technical achievements

### 1. Offline resilience (R5) — a hand-written disk tile cache

The paper requires the map to keep working where there is poor or no cellular
signal. The previous cache was in memory, which cannot satisfy that: it dies
with the process, so a commuter who force-closes the app in a dead zone loses
every tile they had already loaded.

**`services/tile_cache_store.dart`** implements `CacheStore` directly and
persists OpenStreetMap tiles to disk. It was written by hand because no
packaged option can work on this stack — `dio_cache_interceptor_file_store` is
pinned to `dio_cache_interceptor ^3.x` while `flutter_map_cache 2.x` requires
`^4.0.0`, and the older `flutter_map_cache 1.x` that pairs with the 3.x store
needs `flutter_map ^6` against this project's `^7`.

| Concern | Approach |
|---|---|
| **Format** | One file per tile: `[4-byte BE length][JSON metadata][raw body]`. Metadata stays inspectable; the body stays raw so a PNG is not inflated ~33% by base64. |
| **Crash safety** | Writes go to `.tmp` then `rename` — atomic within a filesystem, so a kill mid-write leaves the old entry or the new one, never half of either. Orphaned `.tmp` files are swept on init; a torn file is detected on read, deleted, and reported as a miss. |
| **Bounded** | 64 MB ceiling, evicting oldest-first to 80%. Eviction order uses an in-memory write counter, not filesystem mtime, whose one-second resolution makes "oldest" ambiguous for tiles written in the same burst. An entry larger than the whole budget is skipped rather than evicting everything and still not fitting. |
| **Safe filenames** | FNV-1a 64 emitted as two *unsigned* 32-bit halves. Hashing means a key containing `..` or `/` can never walk out of the cache directory; because a collision would return the **wrong tile**, the full key is stored in metadata and re-checked on read. |
| **Storage location** | The application-support directory, **not** the cache directory — Android reclaims cache dirs under storage pressure, which would silently empty the offline map exactly when a rider depends on it. |

Also offline: the SQLite database (below), GPS alarms, and SOS SMS. Only the
guide's *planning* step (Nominatim search, OSRM road geometry, tile download)
needs a connection.

> **Verified end to end on an emulator:** loaded the map online (56 tiles,
> 2.1 MB written to the app's private directory), force-stopped the app, then
> disabled networking — confirmed down, not assumed: `Network is unreachable`
> for 8.8.8.8 and DNS failing for `tile.openstreetmap.org`. On cold boot the
> map rendered completely. **Control:** still offline, recentring onto an area
> never loaded online rendered blank, which rules out the alternative
> explanation and proves the rendered tiles came from disk.

### 2. Multimodal transit routing (R6)

Real Metro Manila jeepney/bus routes from the bundled DOTC/Sakay.ph GTFS feed
(0.77 MB gzipped) are decompressed once and built into a graph searched with
**Dijkstra** over a long-lived **worker isolate**.

- **Graph model.** 74,018 stop-points collapse to **4,781 unique coordinates**.
  Nodes are `(stop, route)` pairs — "aboard route R at stop S" — so
  boarding-based fares are modelled correctly, plus one **hub node** per
  coordinate (**78,799 nodes**). Transfers route *through* the hub
  (`alight → hub → board`), keeping them O(k) per stop instead of O(k²); the
  graph lands at **230,419 edges**. Adjacency is flat **CSR typed arrays**
  (`Int32List`/`Float32List`/`Uint8List`) — never boxed objects, which would
  balloon the heap on a 4 GB budget phone (~3–5 MB resident).
- **Search.** Two passes — one minimising time, one an approximate fare proxy —
  so the UI gets genuinely different *Fastest* and *Cheapest* options. Boarding
  count lives in the search state, capped at **4 boardings = 3 transfers**, so
  the cap stays provably optimal rather than a heuristic prune. Each transfer
  costs a **5-minute penalty** (Jeon et al., 2018 — routers that skip this
  return paths passengers reject).
- **Fare: approximate to search, exact to display.** Real fare is
  state-dependent (₱13 covers the *first 4 km of each boarding*), so it cannot
  be an exact edge weight. The proxy keeps Dijkstra valid; the displayed price
  is computed exactly from the LTFRB matrix per contiguous leg, so two
  boardings are charged two base fares.
- **Performance** on the real 1,711-route feed: graph builds in **≈151 ms**, a
  full two-pass NCR search in **≈141 ms**. Any failure falls back to a synthetic
  estimate (explicitly labelled as such), then to an out-of-area message —
  routing never blocks the guide, and never blocks the alarm.

### 3. Emergency native hooks (R7 / R8) — MediaSession volume shortcuts

Triple **Volume-Up → SOS**, triple **Volume-Down → fake call**, and they must
work with the screen off and the phone in a pocket.
`Activity.dispatchKeyEvent` only sees keys while the app has window focus, so
that path is dead when locked. **`MediaButtonService.kt`** (a `mediaPlayback`
foreground service) solves it:

- **Capture.** An always-active `MediaSession` with a **remote
  `VolumeProvider`** receives volume keys even while asleep, because Android
  handles them in `interceptKeyBeforeQueueing` and routes them to the active
  remote-volume session. Each press is relayed to the real audio stream, so
  device volume still works normally.
- **Priority vs. other media (the "Spotify problem").** Volume keys route to
  the highest-priority session declaring *remote* volume, which considers
  **only** remote-volume sessions — locally-playing apps like Spotify are never
  candidates, so they cannot steal the keys *as long as our session stays
  active*. A **silent, zero-volume keep-alive track** (requesting **no audio
  focus**, so it never pauses or ducks the rider's music) plus a 20 s
  playing-state re-assertion keep it from ageing out.
- **Background Activity Launch resolution.** Android 10+ blocks `startActivity`
  from a backgrounded service. The fake call / SOS surface via a
  **full-screen-intent notification** instead — BAL-exempt, auto-launching over
  the keyguard when the screen is off, a tappable heads-up when it is on.
- **Detection & safety.** Triple-press timing (1600 ms window) runs natively so
  it is independent of the Flutter engine, with a **3 s cooldown** so a key
  burst cannot double-fire — a double SOS would send duplicate SMS and cost the
  rider real prepaid load. A ghost-trigger guard only treats presses as a
  shortcut when the screen is off **or** the app is not foregrounded, so
  ordinary volume changes while using the app are never misread.
- **SOS payload.** `sos_service.dart` takes a GPS fix (falling back to the last
  known position), builds a message carrying the reverse-geocoded address *and*
  raw coordinates, and hands it to native **`SmsManager`** over a platform
  channel — no internet required. Failures are queued and retried.

### 4. Background tracking & always-visible trip state

- **Foreground service GPS stream.** `TripViewModel` runs a
  `bestForNavigation` position stream with a wake lock and a foreground
  notification, so monitoring survives the screen going off.
- **Lock-screen trip widget (Figure 25).** An ongoing notification shows the
  destination, remaining distance and ETA, with **SOS · Open in App · End
  trip** actions. SOS is listed first because Android collapses the action row
  on narrow lock screens and drops trailing actions — the emergency action must
  never be the one that gets cut. Updates are deduplicated: the text is
  recomputed on every GPS fix but only posted when it visibly changed, cutting
  what would otherwise be ~7,000–10,000 redundant notification updates over a
  2–3 hour commute.
- **Home-screen App Widget.** `NavAlertWidgetProvider.kt` renders live
  destination / distance / ETA / status via `RemoteViews`, plus a **one-tap
  SOS** that routes into the same `fireSos` path as the volume shortcut.
  Pushes are forced on trip start, each alarm stage and trip end, and throttled
  to ~15 s during steady monitoring.
- **Live location that actually follows the rider.** The Home map's blue dot
  subscribes to a continuous position stream (`high` accuracy, 5 m distance
  filter, 2 s interval — deliberately gentler than trip monitoring, with no
  wake lock, because Home is a browsing screen). **`LatLngGlide`** interpolates
  between fixes over 400 ms so the marker travels the gap instead of teleporting
  across it; a fix landing mid-glide re-aims from the current painted position
  rather than snapping backwards. Only the marker moves — the camera stays put,
  because yanking the map back every tick would make an unusable browsing
  screen. (The **trip** map is the opposite case; see below.)

### 5. The commute guide over a live, tracking map

The guide-first Active Trip layout used to be an opaque list on a gradient wash.
It answered "what do I do next" and nothing else — a rider following
turn-by-turn directions could read the instruction but had no way to see where
they actually *were*, which is the one question a navigation tool has to answer.

The guide now floats over a full-bleed map as a `DraggableScrollableSheet`:

| Concern | Approach |
|---|---|
| **Layering** | Three layers: map, a transparent overlay column, the sheet. The safety footer (SOS · Fake Call · Slide-to-Stop) is a **sibling below** the sheet's region, not a layer over it — so the sheet is *structurally* incapable of reaching the safety controls however far it is dragged. Stronger than height arithmetic, which can be got wrong. |
| **Visibility budget** | `commute_sheet_layout.dart` resolves the sheet's fractions from the screen, the region and the **measured** footer height. The sheet plus footer may never cover more than half the screen; ≥22% stays map even fully extended. A tall footer (the "Signal Lost" card adds ~90 dp) shrinks the guide rather than eating the map. |
| **Camera tracking** | The camera follows the rider, offset so the dot sits centred in the band of map left *visible above the sheet* rather than behind it. The offset is resolved into a camera centre **once** per move — re-applying it per animation tick compounds, walking the camera off the rider within a few fixes. |
| **Escapable follow** | A fix lands every 1–2 s, so an unconditional follow makes looking ahead impossible. A manual pan releases the camera and a recenter button restores it. `MapController.move` reports `hasGesture == false`, so the follow cannot switch *itself* off. |
| **Degenerate geometry** | Every fraction is clamped and re-ordered so `min ≤ initial ≤ max` holds by construction. `DraggableScrollableSheet` asserts that ordering, and the assertion would fire on the one screen a rider cannot leave except by Slide-to-Stop. |

Both the geometry and the follow-state are pure Dart (no Flutter, no plugins),
so they are unit-tested headlessly — on a device these rules are only observable
by watching a moving map on a moving jeepney; as arithmetic they are provable.
The layering itself is checked against the *mounted* widget tree, because a
correct calculation wired to nothing looks identical from the outside.

> **Measured on a 360×800 screen** (`commute_guide_overlay_test`): unobstructed
> map 318 px (39.8%), guide at rest 229 px (28.6%), safety footer 170 px
> (21.3%), and 177 px (22.1%) still map at full extension. The resting sheet is
> slightly under the 30–40% originally specified, and cannot be otherwise here:
> with a 170 px footer, a 30% sheet would obscure 410 px — just over half — and
> break the half-map rule. The map wins, and the sheet takes every pixel the
> budget leaves.

### 6. Adaptive three-stage alarm (R1–R4) — the optional layer

A GPS stream feeds an engine that sizes the trigger radius from the vehicle's
*live* speed and the rider's learned historic reaction time. Stages escalate on
distance **and** on unresponsiveness (30 s windows), ending in a
hard-to-dismiss full-screen alert. A watchdog raises a fallback alarm after 90 s
of GPS loss, and a consecutive-fix latch detects overshoot and offers a Google
Maps return route.

### 7. Privacy & persistence

SQLite encrypted at rest with **SQLCipher**, the key held in the Android
Keystore. All personal data — trips, contacts, behavioural profile, favourites
— stays on-device. **There is no backend server** (RA 10173 / Data Privacy Act
of 2012 compliance).

---

## Tech stack

| Layer | Choice |
|---|---|
| Language | **Dart** |
| Framework | **Flutter** |
| Architecture | **MVVM** (Model · View · ViewModel via `provider` / `ChangeNotifier`) |
| Local database | **SQLite** encrypted with **SQLCipher** (`sqflite_sqlcipher`, key in Android Keystore via `flutter_secure_storage`) |
| Map tiles | **OpenStreetMap** (`flutter_map`) + custom disk cache |
| Destination search | **Nominatim API** (search + reverse geocoding) |
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
| **R6 Commute guide + fares** | **Dijkstra multimodal router** over real GTFS (`transit_graph.dart`, `transit_router.dart`) in a worker isolate (`routing_isolate.dart`); exact LTFRB fares via `route_engine.dart`; synthetic estimate as fallback |
| **R5 Offline-first** | `tile_cache_store.dart` (disk map tiles), SQLite (`database_service.dart`), offline GPS alarms, native SMS |
| R1 Multi-stage escalating alarm | `sound_service.dart`, `active_trip_view.dart` (Stages 1–3, slide-to-dismiss) |
| R2 Continuous GPS monitoring | `trip_viewmodel.dart` (geolocator stream + Android foreground service); live Home marker via `home_viewmodel.dart` + `LatLngGlide` |
| **R6 Live trip map + camera tracking** | `trip_map.dart` (map, route polyline, tracking blue dot, recenter) + `commute_sheet_layout.dart` (sheet geometry + follow state); guide overlays it via `active_trip_view.dart` |
| R3 Speed-based adaptive trigger distance | `adaptive_alarm_engine.dart` (rolling avg speed × reaction window, 5 km cap) |
| R4 Behavioural learning | reaction time (`awake_seconds`) per trip widens the trigger distance **and** raises alarm loudness/vibration |
| **R7 Fake call** | `fake_call_view.dart`, custom recordings via `record`; triple Volume-Down via `MediaButtonService` |
| **R8 SOS via Native Android SMS** | `sos_service.dart` + `MainActivity.kt` SmsManager channel; triple Volume-Up via `MediaButtonService` |
| UC-4 Pin drop-off on map | `pin_on_map_view.dart` (tap the map, reverse-geocode, confirm) |
| Overshoot detection + rerouting | consecutive increasing-distance latch → Google Maps intent (clipboard fallback) |
| Database schema (Tables 15–29) | `database_service.dart` — all 13 tables, 8 FKs, unique indexes |
| Lock Screen Widget (Figure 25) | `trip_notification_service.dart` |
| Home Screen App Widget | `home_widget_service.dart` + `NavAlertWidgetProvider.kt` |
| "Signal Lost" fallback alarm (UC-1) | GPS watchdog fires a fallback alarm after 90 s without a fix |
| SOS queue-and-retry (UC-7) | failed SOS SMS retried every 30 s, then backed off — never silently abandoned |
| Data Backup (Figure 33) | Settings → Import/Export JSON (with confirmation before overwrite) |
| History (Figure 30) | keyword + calendar-date filter + sort; delete a trip with confirmation |

All 20 GUI screens (Figures 14–33) are implemented under `lib/views/`.

---

## Project structure

```
navalert/
├── lib/
│   ├── main.dart                       # entry point + provider wiring + tile-cache init
│   ├── core/
│   │   ├── theme.dart                  # 11 colour tokens + ThemeData (the style hub)
│   │   └── map_support.dart            # shared TileLayer, NCR geofence, LatLngGlide,
│   │                                   #   camera mover (with bottom-padding offset)
│   ├── models/
│   ├── views/                          # all 20 screens (Figures 14–33)
│   │   ├── shell.dart                  #   bottom-nav shell + volume-key wiring
│   │   ├── home_view.dart              #   map + search + live location marker
│   │   ├── route_view.dart             #   route map · mode priority · trip config
│   │   ├── commute_guide_sheet.dart    #   live step-by-step guide (sheet + inline modes)
│   │   ├── trip_map.dart               #   ⭐ live trip map · route line · tracking blue dot
│   │   ├── commute_sheet_layout.dart   #   ⭐ sheet geometry + camera follow state (pure Dart)
│   │   ├── active_trip_view.dart       #   monitoring (contextual) · alarm stages · overshoot
│   │   ├── emergency_view.dart         #   SOS hold · Call 911 · fake-call recordings
│   │   └── …                           #   search · favorites · history · settings · onboarding
│   ├── viewmodels/                     # app · home · trip · emergency · history
│   └── services/
│       ├── tile_cache_store.dart       #   ⭐ custom disk cache for OSM tiles (R5)
│       ├── database_service.dart       #   SQLite + SQLCipher (13 tables)
│       ├── adaptive_alarm_engine.dart  #   R1–R4 alarm math
│       ├── transit_graph.dart          #   CSR routing graph from GTFS
│       ├── transit_router.dart         #   Dijkstra multimodal search (2 passes)
│       ├── routing_isolate.dart        #   long-lived worker isolate
│       ├── route_engine.dart           #   exact LTFRB fares + synthetic fallback
│       ├── sos_service.dart            #   native SMS SOS + queue/retry + Call 911
│       ├── trip_notification_service.dart  # lock-screen trip widget
│       ├── home_widget_service.dart    #   home-screen App Widget bridge
│       └── hardware_buttons.dart       #   volume-button shortcut channel
│
├── android/app/src/main/
│   ├── AndroidManifest.xml
│   ├── res/                            # launcher icon, dark launch screen, widget layout
│   └── kotlin/ph/edu/pup/navalert/
│       ├── MainActivity.kt             #   SMS · lock-screen · shortcut · audio-route bridges
│       ├── MediaButtonService.kt       #   ⭐ screen-off volume shortcuts (R7/R8)
│       └── NavAlertWidgetProvider.kt   #   home-screen App Widget
│
├── test/                               # 19 suites, 262 tests
├── integration_test/                   # on-device full-app sweep
├── assets/                             # sounds · GTFS feed · images
└── tool/                               # gen_gtfs.py · gen_sounds.dart
```

**Quick "where is…?" guide**

| I want to change… | Go to |
|---|---|
| Colours / fonts / button styles | `lib/core/theme.dart` |
| Map tiles, retina mode, offline cache | `lib/core/map_support.dart`, `lib/services/tile_cache_store.dart` |
| A specific screen's look | `lib/views/<screen>_view.dart` |
| What a button *does* | its ViewModel in `lib/viewmodels/` |
| Alarm timing / distance / intensity | `lib/services/adaptive_alarm_engine.dart` |
| Route planning (Dijkstra) | `lib/services/transit_router.dart`, `transit_graph.dart` |
| App permissions | `android/app/src/main/AndroidManifest.xml` |

---

## Running it

**Prerequisites:** Flutter 3.x (`flutter doctor`), Android SDK, and a device or
emulator on Android 8.0 (API 26)+. The Flutter project **is the repository
root** (no subfolder).

```powershell
flutter pub get

# on a connected phone or a running emulator
flutter run

# release APK (smooth maps — use this for field testing)
flutter build apk --release
adb install -r build\app\outputs\flutter-apk\app-release.apk
```

Start the bundled emulator first if needed:

```powershell
flutter emulators --launch Pixel_6_2
```

### Exercising the features on an emulator

```powershell
# Put the device inside the NCR service area (longitude first)
adb emu geo fix 121.0108 14.5979
```

- **Commute guide:** search a destination → *Show Commute Guide* → *Start Trip*.
- **Destination alarm:** in Trip Settings, switch **Destination alarm** on (it
  is off by default) before *Start Trip*, then feed a moving track with
  repeated `adb emu geo fix` calls to drive Stage 1 → 2 → 3.
- **Offline map:** load the map online, `adb shell am force-stop
  ph.edu.pup.navalert`, disable networking, then cold-boot — tiles render from
  disk.

> **Needs real hardware:** the volume-button shortcuts cannot be exercised with
> `adb shell input keyevent`. Injected key events do not reach a remote
> `VolumeProvider` (they enter the pipeline after
> `interceptKeyBeforeQueueing`), so neither the audio stream nor the session
> volume moves. Likewise, audible fake-call playback and real SMS delivery need
> a physical device — an AVD has no functional audio sink and no carrier.

---

## Testing

```powershell
flutter analyze   # No issues found
flutter test      # 262/262 passing
```

**19 suites** covering the alarm engine (speed→radius, escalation thresholds,
behavioural learning, overshoot latch), the fare matrix and NCR bounds, the
Dijkstra router against the **real production GTFS feed**, the full
`TripViewModel` state machine driven from a mock GPS stream on a virtual clock,
the guide's leg progression, the database schema against the Data Dictionary,
live-location tracking, marker interpolation, FAB/pill collision geometry, and
the disk tile cache (round-trip, persistence across a new store, eviction
bounds, truncated files, orphaned temp files, hostile keys).

The trip-map overlay adds three suites, split by what each can actually prove:

| Suite | Proves |
|---|---|
| `commute_sheet_layout_test.dart` | The **arithmetic** — resting height, the half-map budget, the top margin at full extension, and that `min ≤ initial ≤ max` survives every screen size, footer height and degenerate input. |
| `trip_camera_tracker_test.dart` | The **follow state** — engaged by default, released by a gesture, *not* released by a programmatic move, restored by recenter, and the offset's sign and magnitude. |
| `commute_guide_overlay_test.dart` | That the arithmetic is **wired to the screen** — mounts the real Active Trip view and measures it: map present and full-bleed, sheet resting below the halfway line, safety controls never covered, last step scrollable clear of the seam. |

That third suite exists because a correct calculation fed to nothing looks
identical, from the outside, to a broken one. It mounts the **real** map, so the
real `CachedTileProvider` runs and flutter_test's sandboxed HTTP client logs one
`DioException` per tile — expected output, and itself evidence that the shared
tile/cache path is genuinely wired in rather than stubbed for the test.

They do **not** cover pixel-level rendering. That is verified by running the app
on a device and by the on-device sweep in `integration_test/`:

```powershell
flutter test integration_test\full_app_sweep_test.dart
```

---

## UI hand-off rules

The behaviour underneath is finished and tested. Three annotation markers
appear throughout `lib/views/`:

| Marker | Meaning |
|---|---|
| `// TODO (UI Team):` | 🟢 Style this freely. |
| `// USE THEME:` | 🟡 Pull the value from `NavAlertColors` / `ThemeData` instead of hardcoding it. |
| `// DO NOT MODIFY LOGIC:` | 🔴 Wired to the backend. Restyle *around* it; never change the marked call. |
| `// DO NOT MODIFY LOGIC - CAPSTONE DEFENSE CRITICAL:` | ⛔ Hard stop. A safety guard demonstrated live to the panel. |

There are **13 `CAPSTONE DEFENSE CRITICAL` markers across 6 files**
(`active_trip_view` · `emergency_view` · `fake_call_view` · `route_view` ·
`search_view` · `add_favorite_view`). Each is a boxed comment naming exactly
what it protects and what breaks without it.

**Never do these:**

- ❌ Unwrap or delete a `PopScope` — the Back button then silently cancels a
  live trip or an emergency sequence.
  *(Not a violation: the Active Trip screen's own back arrow. `PopScope`
  intercepts the **system** back gesture only, never a programmatic
  `Navigator.pop()` — which is why Slide-to-Stop and the summary buttons have
  always closed that route. The arrow leaves the trip **running**; monitoring
  lives in `TripViewModel`, and the shell's "View Active Trip" pill returns to
  it.)*
- ❌ Replace `onPressed: <flag> ? null : ...` with a plain handler — that is the
  debouncer; removing it lets a panicking rider send duplicate SOS texts and
  stack fake-call screens.
- ❌ Remove `math.max(0.0, width - height)` in `_SlideToStop` — it throws
  `ArgumentError` on the one control that ends a trip.
- ❌ Remove a keyboard `GestureDetector` wrapper or its `HitTestBehavior.opaque`.
- ❌ "Simplify" `canPop: !sosInFlight` in `emergency_view.dart` to
  `canPop: false`. It looks tidier and **breaks the Back button across the
  entire app** — that screen is a tab in an `IndexedStack`, so its `PopScope` is
  mounted even while another tab is showing.
- ❌ Set a custom `icon:` on the trip notification without re-testing a
  **release** build. The plugin resolves it by name at runtime, which R8
  minification defeats — the notification then silently stops posting. See the
  note in `trip_notification_service.dart`.

**Rule of thumb:** `onPressed` / `onTap` / `controller` / `context.read|watch` /
`Navigator` / `setState` / `.listen` → **logic, leave it.** Everything visual →
yours. Start at `lib/core/theme.dart`; one change restyles every screen.

---

## Notes & limitations

- The commute guide's **planning** step (destination search, road geometry,
  first tile download) needs internet. Once planned, the guide, the alarm, the
  cached map and SOS all work **offline**.
- GTFS coverage is **jeepney + bus**. UV Express is absent from the feed and
  falls back to a synthetic LTFRB-rate estimate, explicitly labelled as such.
  Fares and times are estimates, not live data.
- Routing and fares are scoped to **Metro Manila (NCR)**; outside it the app
  says so plainly rather than showing an empty guide.
- **Android only.** Alarms are loud and escalating, but no system can guarantee
  every rider wakes up.
- SOS SMS requires a SIM with sufficient prepaid load. The app warns about this
  on the Home screen before a trip, not on the Emergency screen — by the time
  the rider opens Emergency it is too late to top up.
- The trip notification's small icon is the launcher icon, so Android's
  alpha-mask rendering shows it as a filled shape. A dedicated monochrome icon
  was tried and reverted because it broke notification posting in release
  builds (see above) — a cosmetic flaw was preferred over losing Figure 25.

---

## Attribution

Transit data © Department of Transportation (DOTC/DOTr), Philippines, via the
Philippine Transit App Challenge and Sakay.ph, used under the DOTC Developer
License Agreement for assisting mass-transportation riders. Map tiles ©
OpenStreetMap contributors — cached locally in line with the OSM tile usage
policy, which asks clients to cache rather than re-request. Geocoding ©
Nominatim / OpenStreetMap. Road geometry © OSRM.
