# NavAlert — Development & Optimization Changelog

### Functional Engineering Phase

**Project:** NavAlert — An Integrated Route Optimization, Fare Estimation,
Adaptive Destination Alarm, and Emergency Safety System for Metro Manila PUV
Commuters
**Programme:** BSIT, Polytechnic University of the Philippines
**Platform:** Flutter / Dart (MVVM), Android (min SDK 26 / target SDK 35)
**Document status:** Final for the functional phase; prepared as a software
engineering appendix.

---

## 1. Purpose and Scope

This changelog documents the engineering work completed during the **functional
hardening phase** of NavAlert, in which the application's core logic, data
layer, routing engine, and emergency subsystems were implemented, corrected,
and verified prior to user-interface refinement. Each entry records the
*objective*, *design rationale*, *implementation*, and *verification evidence*
so that the work can be independently assessed.

**Verification methodology.** Two complementary methods were used throughout:
(i) an automated unit-test suite executed via `flutter test` (124 passing
tests); and (ii) on-device black-box validation on an Android emulator
(Pixel 6, API 35) using simulated GPS (`adb emu geo fix`) and process
inspection (`adb logcat`, `dumpsys`). Safety-critical native behaviours that
the emulator cannot reproduce faithfully — screen-off key delivery and
media-session priority against a live audio stream — were confirmed on physical
hardware.

---

## 2. Multimodal Route Optimization Engine (Requirement R6)

### 2.1 Objective

Replace the initial direct-route matcher — a linear scan incapable of planning
transfers — with a graph-based shortest-path engine, as mandated by the project
specification and justified by Narboneta and Teknomo (2016), who report that
Metro Manila commuters average three transport modes per trip.

### 2.2 Graph Model

A naïve stop-only graph cannot price a journey correctly, because jeepney fare
is computed as a base charge covering the first four kilometres *of each
boarding*. The graph therefore uses a composite node model:

| Node type | Meaning | Count |
|---|---|---|
| Ride node `(stop, route)` | "aboard route *R* at stop *S*" | 74,018 |
| Hub node `(stop)` | "standing at stop *S*, not aboard" | 4,781 |

Transfers are routed *through* the hub node (`alight → hub → board`), reducing
the transfer topology from O(*k*²) pairwise edges per stop to O(*k*). Empirical
graph construction over the bundled Metro Manila GTFS feed:

| Metric | Value |
|---|---|
| Unique coordinates (hubs) | 4,781 (15.5× deduplication of 74,018 stop-points) |
| Total nodes | 78,799 |
| Total edges | 230,419 |
| Graph construction time | ≈ 151 ms |
| **Two-pass search time (full NCR)** | **≈ 141 ms** |

### 2.3 Search Algorithm

Dijkstra's algorithm is executed in **two passes** to satisfy the Figure 22
requirement for distinct *Fastest* and *Cheapest* suggestions:

- **Pass 1 — time:** minimises in-vehicle time + walking time + boarding wait
  (7 min) + a **transfer penalty of 5 minutes** per additional boarding. The
  transfer penalty is grounded in Jeon et al. (2018), who show that routers
  ignoring transfer cost return paths passengers reject.
- **Pass 2 — fare:** minimises an approximate fare proxy.

The boarding count is encoded directly into the Dijkstra label
`(node, boardingsSoFar)` and capped at **4 boardings (3 transfers)**, aligning
with the three-modes finding while keeping the result provably optimal within
the cap (a heuristic prune would not).

### 2.4 Fare Computation — Approximate to Search, Exact to Display

Because fare is state-dependent it cannot serve as an exact edge weight. The
search uses a monotonic, non-negative proxy to preserve Dijkstra's correctness;
the fare presented to the commuter is then computed **exactly** from the LTFRB
matrix over each contiguous same-route leg of the returned path. Consequently
two boardings are charged two base fares, and the displayed price is never
wrong even where the proxy selects a marginally sub-optimal path.

### 2.5 Defect Resolved During Implementation

The distance array was initially typed `Float32List` while path costs are
double-precision. Truncation caused the stale-entry guard to discard nodes it
had just settled, silently losing most of the graph. Corrected to `Float64List`.
The defect was surfaced by a fixture with a *known* optimal answer rather than a
"returns something" assertion.

**Verification.** Unit suites `transit_router_test.dart` and
`transit_graph_real_test.dart` (the latter routing over the full 1,711-route
feed); on-device confirmation of a real cross-city plan (*"Jeep: SAN JUAN –
CUBAO via N DOMINGO"*, 30 min, ₱13.00).

---

## 3. Isolate-Based CSR Memory Architecture

### 3.1 Objective

Execute graph routing on constrained hardware (target: 4 GB RAM) without
out-of-memory conditions or UI-thread jank.

### 3.2 Design

- **Compressed Sparse Row (CSR) adjacency** stored as flat typed arrays —
  `Int32List` (row offsets, edge targets), `Float32List` (edge weights),
  `Uint8List` (edge kind). Object-per-edge representation was rejected as it
  would box ≈ 230,000 allocations onto the heap. Estimated resident footprint:
  3–5 MB.
- A **long-lived worker isolate** owns the graph: it decompresses the 0.77 MB
  gzip asset and builds the CSR structure **once**, then serves queries over a
  message port. The graph is never rebuilt per request and never resides on the
  UI heap. Only small `(origin, destination, preferences)` requests and result
  paths cross the port.
- The isolate is **spawned lazily** on first search and **disposed after five
  minutes idle**, so a commuter who never opens the guide incurs no cost.

**Verification.** Confirmed on device that route planning does not block the
UI; graph build (≈ 151 ms) and search (≈ 141 ms) measured within the isolate.

---

## 4. Route Deduplication and NCR Geofencing

### 4.1 Route Suggestion Deduplication

The two search passes could return the same sequence of vehicles via slightly
different boarding/alighting stops, producing visually identical suggestion
cards. Journeys are now deduplicated on a **route signature** — the ordered
sequence of ridden route identifiers, disregarding walking legs and exact stops
— retaining the fastest variant. Genuinely distinct route sets are preserved.

### 4.2 National Capital Region Geofencing

The application's transit data and LTFRB fare structure are valid only within
Metro Manila (NCR). A single bounding box (14.30°–14.82° N, 120.88°–121.18° E)
is now the shared authority for three enforcement points:

1. **Search** — the Nominatim query sets `bounded=1` with an NCR `viewbox`,
   converting the previous soft bias into a hard restriction. (Previously
   `bounded=0` permitted out-of-region results such as Baguio City.)
2. **Map panning** — `CameraConstraint.contain` fences the interactive map to
   the NCR bounds, preventing scrolling into unserviced provinces.
3. **Pin validation** — a drop-off pin outside the bounds is rejected with an
   explanatory message.

Where no route can be produced, the commute guide displays an *"Outside the
service area"* notice while the destination alarm — which has no regional
dependency — remains fully available.

**Verification.** `route_engine_test.dart` NCR-boundary cases (accepts NCR
cities; rejects Baguio, Cebu, Batangas, Tarlac; inclusive edges). On device, a
"Baguio" search no longer returns Baguio City.

---

## 5. Map Rendering and Performance Optimization

### 5.1 Tile Resolution

All three `flutter_map` instances (Home, Pin-on-map, Route) left
`TileLayer.retinaMode` unset, causing 256 px tiles to be upscaled ~2.6× on
high-density screens and rendered soft. As the OpenStreetMap endpoint has no
`@2x` tile, **simulated retina mode** (`RetinaMode.isHighDensity`) is enabled —
the package fetches the next zoom level and downscales — yielding crisp labels.
Zoom is bounded (`maxNativeZoom = 19`, `maxZoom = 20`).

### 5.2 Tile Buffering and Animated Camera

- `keepBuffer` increased to **8** so previously fetched tiles are retained in
  memory across pan/zoom, eliminating re-fetch "pop-in" on revisited areas;
  `panBuffer` set to **2** to pre-load the immediate ring around the viewport.
- Programmatic camera movements (locate button, initial GPS fix) use a
  dependency-free eased interpolator (`AnimatedMapMover`) rather than an
  instantaneous jump.

Disk-level tile caching (e.g., FMTC) was deliberately **not** adopted, to avoid
a heavy native dependency inconsistent with the application's offline-first,
lightweight design; in-memory retention addresses the in-session case.

**Verification.** On-device comparison confirmed legible street labels where
tiles were previously blurred.

---

## 6. State-Management Integrity and Background-Service Lifecycle

### 6.1 Active-Trip Listener Re-entrancy

`TripViewModel.startTrip` assigned the GPS position-stream subscription without
first cancelling any live subscription. A second invocation — a double-tapped
"Start Trip", or a new trip begun before the previous ended — orphaned the prior
listener, resulting in **two streams driving the alarm evaluation** and
potential duplicate alarms. A single teardown path, `_teardownMonitoring()`
(cancelling the GPS subscription, the signal-loss watchdog, and all alarm
timers), is now invoked at the head of `startTrip` and within `_endTrip`.

**Verification.** Instrumented on-device measurement of GPS-fix callbacks across
a complete *start → stop → restart* cycle confirmed a constant single-listener
rate (≈ 1 fix s⁻¹) with exactly one alarm per stage and zero orphaned listeners.

### 6.2 Interrupted-Trip Reconciliation

A trip terminated by an OS process kill, crash, or force-stop never executed its
end-of-trip persistence, leaving the record permanently `active` and displaying
a phantom ongoing trip in Trip History. A reconciliation step now runs once on
database open (`onOpen`), closing any interrupted trip using the `cancelled`
status already defined in the Data Dictionary.

**Verification.** On device, a trip force-stopped mid-monitoring correctly
appears as *CANCELLED* with an end time on next launch.

### 6.3 Foreground-Service Continuity (Doze Resilience)

Continuous trip monitoring uses the `geolocator` foreground-service
configuration — a persistent notification and wake-lock under the
`FOREGROUND_SERVICE_LOCATION` type — which is exempt from Doze location
throttling. This was audited and confirmed to be the architecturally correct
mechanism for surviving aggressive OS battery management during long commutes.

---

## 7. Discreet Emergency Trigger — MediaSession Hardware-Shortcut Architecture (R7 / R8)

### 7.1 Problem Statement

The triple-Volume shortcuts (Volume-Up ×3 → SOS; Volume-Down ×3 → fake call)
were implemented via `Activity.dispatchKeyEvent`, which receives key events only
while the activity holds window focus. The shortcuts were therefore inoperative
with the screen off and the device locked in a pocket — precisely the condition
the "discreet triggering" requirement targets. `AccessibilityService` was
rejected as excessively invasive.

### 7.2 Capture Mechanism

A dedicated foreground service (`MediaButtonService`, `mediaPlayback` type)
hosts an always-active `MediaSession` declaring **remote volume control**
(`setPlaybackToRemote` with a `VolumeProvider`). Android handles volume keys in
`PhoneWindowManager.interceptKeyBeforeQueueing`, which executes even while the
device is asleep, and routes them to the active remote-volume session's
`onAdjustVolume` callback. This delivers volume keys to the application with the
screen off — confirmed on physical hardware.

An implementation prerequisite was discovered on device: the session requires a
`MediaSession.Callback` to be registered before the framework treats it as
controllable and routes keys to it; without it, `onAdjustVolume` never fires.

### 7.3 Priority Retention Against Concurrent Media (Audio Keep-Alive)

Commuters frequently play music while in transit, raising the risk that another
application seizes volume-key priority. The architecture prevents this by
construction: Android routes volume keys to the highest-priority session
declaring *remote* volume via `MediaSessionStack.getDefaultVolumeSession()`,
which considers **only remote-volume sessions**. Music applications (e.g.,
Spotify, YouTube) play **local** audio and are therefore never candidates for
that routing slot — provided NavAlert's session remains active and non-stale.

Two mechanisms guarantee that condition:

- A **silent, zero-volume keep-alive track** (`AudioTrack`, `USAGE_MEDIA`,
  looped in hardware). It requests **no audio focus** — a deliberate design
  choice so that it mixes silently alongside, and never pauses or ducks, the
  commuter's music.
- A **periodic (20 s) re-assertion** of the session's playing state, preventing
  it from ageing out of the priority stack when another application becomes
  active.

**Verification.** On physical hardware with a live Spotify stream playing, the
shortcut fired and intercepted the volume keys without interrupting playback.
On device, `dumpsys media_session` reported NavAlert as the "Media button
session" while YouTube played three active audio tracks.

### 7.4 Background Activity Launch (BAL) Resolution

On Android 10+, a backgrounded foreground service cannot invoke `startActivity`
(observed: `Background activity launch blocked … BAL_BLOCK`), causing the fake
call and SOS-fallback to fail silently in the pocket scenario. The service now
surfaces the interface via a **full-screen-intent notification** — the
sanctioned incoming-call mechanism, which is BAL-exempt. It auto-launches over
the keyguard when the screen is off and presents as a tappable heads-up when the
screen is on (content and full-screen intents target the same activity).

### 7.5 Delivery Path and Concurrency

- **Native triple-press detection** (1,600 ms window) runs in the service,
  independent of the Flutter engine's lifecycle, with a **3-second cooldown**
  after a trigger to prevent a key burst from firing twice — critical for SOS,
  as a double trigger would dispatch duplicate SMS to every contact.
- **SOS** is delivered silently to the running Flutter engine over the platform
  channel when attached (no screen wake), reusing the existing SMS/GPS logic;
  otherwise it falls back to the full-screen intent.
- Each volume press is **relayed to the real audio stream**
  (`adjustSuggestedStreamVolume`), so device volume control continues to
  function while the session owns the keys.
- MediaSession callbacks were moved onto a dedicated `HandlerThread`, keeping
  the audio-relay work off the main (Flutter UI) thread.

---

## 8. Additional Correctness Hardening

The following defects were identified and resolved during systematic review and
edge-case auditing:

| Area | Correction |
|---|---|
| Adaptive alarm (UC-5/6 Ex.) | Silence-before-persist ordering so a storage failure cannot leave an un-dismissable alarm; guarded behaviour-profile writes. |
| Signal-lost race | Awaited fallback-alarm teardown so a late `stopAll()` cannot silence a subsequent wake-up alarm. |
| Overshoot false-positive | Preserves the learned speed window on a "false overshoot", retaining warning distance. |
| Sound service | Audio and haptics dispatched independently; playback failures no longer block the alarm (UC-6 Ex. 2). |
| Fake call (UC-8 Ex.) | Lock-screen full-screen-intent presentation; audio failure degrades to a silent visual call. |
| SOS delivery | Queued-retry exhaustion now records a `failed` outcome and notifies the commuter to Call 911, rather than failing silently. |
| Trip History | Read-failure error state with retry, preventing an indefinite spinner and a misleading empty list. |
| Data Dictionary fidelity | `alarm_events.nearest_stop_name`, `checklist_items`, and `recordings.recorded_at` now round-trip rather than being discarded. |
| GPS acquisition | Highest-accuracy primary fix with a graceful high-accuracy fallback; building-level reverse-geocoding; explicit user notification when a fallback position is shown. |
| Onboarding permissions | Declared `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` and `BLUETOOTH_CONNECT`, restoring the Figure 16 toggles. |
| Slide-to-Stop | Gesture target widened to the full control so the active trip can be reliably exited. |

---

## 9. Automated Test Suite

`flutter analyze`: no issues. `flutter test`: **124 tests passing**.

| Suite | Coverage |
|---|---|
| `adaptive_alarm_engine_test.dart` | R1–R4 alarm mathematics, staging, overshoot latching, behavioural learning |
| `route_engine_test.dart` | LTFRB fare matrix, mode priority, Figure 22 tagging, NCR boundary, guide-leg coordinates |
| `transit_router_test.dart` | Dijkstra correctness, transfer penalty, transfer cap, deduplication, mode preferences |
| `transit_graph_real_test.dart` | Graph construction and routing over the full production GTFS feed |
| `guide_progress_test.dart` | Live commute-guide step advancement (GTFS vs. synthetic legs) |
| `models_test.dart` | Data Dictionary (Tables 15–25) round-trip fidelity |
| `gtfs_service_test.dart` | Non-blocking nearest-stop lookup contract |
| `assets_test.dart` | Bundled alarm/transit asset integrity and `pubspec` declarations |

---

## Appendix A — Commit Ledger (Functional Phase)

| Commit | Summary |
|---|---|
| `f234c21` | Implement Dijkstra multimodal transit router (R6) |
| `1a69847` | Dijkstra multimodal router design specification |
| `327ad73` | Deduplicate route suggestions by route identity |
| `9548bb0` | GPS precision, NCR enforcement, shared map configuration, animated centering |
| `5273310` | Fix blurry OSM tiles: retina mode and bounded zoom |
| `829f563` | Live commute guide during active trips |
| `d59c312` | Live-guide design spec; reconcile interrupted trips on DB open |
| `478303b` | Fix battery/Bluetooth toggles, Slide-to-Stop, NCR guide limit |
| `94826ff` | SOS delivery-outcome reporting; Trip History read-failure state |
| `9874a0f` | Fallback-location surfacing; coarse-accuracy retry |
| `c225d42` | Shorten place labels on Trip History cards |
| `c0b7b76` | Make `startTrip` re-entrancy-safe against orphaned GPS listeners |
| `68d9e37` | MediaSession service for screen-off volume shortcuts (R7/R8) |
| `f119d9e` | Volume-shortcut hardening: media-priority retention + BAL resolution |
| `86475b9` | Run MediaSession volume callbacks off the main thread |

---

## Appendix B — Verification Boundary

The following behaviours depend on physical-hardware conditions the emulator
cannot fully reproduce and were confirmed on a physical device: (i) volume-key
delivery with the screen off; (ii) media-session volume priority against a live
audio stream; (iii) full-screen-intent presentation over the keyguard. All
remaining behaviours were verified by the automated suite and on-device
black-box testing as described in §1.
