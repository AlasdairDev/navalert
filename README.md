# NavAlert

**Offline-Capable Commute Monitoring & Personal Safety System**

![Platform](https://img.shields.io/badge/platform-Android%208.0%2B-3DDC84)
![Flutter](https://img.shields.io/badge/Flutter-3.41-02569B)
![Dart](https://img.shields.io/badge/Dart-3.11-0175C2)
![Kotlin](https://img.shields.io/badge/native-Kotlin-7F52FF)
![Architecture](https://img.shields.io/badge/architecture-MVVM-7C6BC4)
![Tests](https://img.shields.io/badge/tests-372%20passing-success)
![Version](https://img.shields.io/badge/release-v2.1.0-B39DDB)

> Capstone Project — BSIT, Polytechnic University of the Philippines.
>
> *An Integrated Route Optimization, Fare Estimation, Adaptive Destination
> Alarm, and Emergency Safety System for Metro Manila PUV Commuters.*

NavAlert plans a Metro Manila commute over **real jeepney and bus routes**,
prices it against the **LTFRB fare matrix**, and guides the commuter through it
step by step over a live map. For commuters who doze off on long, unpredictable PUV
rides, an **optional** destination alarm can be armed on top — and for
late-night safety, an SOS and a fake incoming call are always one discreet
gesture away.

---

## Architecture: a commute guide first, an alarm second

**This ordering is deliberate and enforced throughout the app.** The
step-by-step commute guide is the product; the alarm is an add-on the commuter may
never switch on.

| | Primary | Secondary |
|---|---|---|
| **What** | Route optimization · step-by-step guidance · fare estimation | Adaptive destination alarm |
| **Default** | Always on — every trip runs the guide | **Off.** Opt-in per trip |
| **Where** | `route_view.dart`, `commute_guide_sheet.dart`, `transit_router.dart` | `adaptive_alarm_engine.dart`, `active_trip_view.dart` |

The primary action reads **"Start Trip"**, not "Enable Alarm" — what the button
begins is trip *monitoring*, which is what carries the live guide. With the
alarm **off**, the Active Trip screen is a live map with the guide floating over
it. With the alarm **on**, it *opens* on the reassurance layout (moon badge,
"Get some rest. We got you.") and the guide collapses to a handle, because that
commuter has handed the trip over and is expected to sleep.

That resting screen is a **face, not a mode.** It used to be the only screen an
alarm-armed trip had, which made the alarm and the live tracking mutually
exclusive: arming the alarm removed the map and the guide outright, and testers
reported the tracking as simply missing. The header's **Live map** button opens
the full tracking layout with the alarm still armed, and its moon button returns
to the resting face — the choice is the commuter's, per moment, not per trip.

### The map shows the leg, not the journey

Once a trip starts, the map draws **one segment at a time**: the walk to the
terminal, then the ride, then the walk to the door, changing over as the guide
does. Drawing the whole route is right on the planning screen, where the
commuter is comparing options — and wrong afterwards, because a commuter walking
to the terminal was also shown the entire jeepney ride with nothing to say which
part of that line was theirs. The live map looked identical to the preview they
had already read.

A whole-journey polyline cannot be cut up after the fact: nothing in it marks
where the walk ends and the ride begins. So each `GuideLeg` carries its **own**
geometry, resolved once at Start Trip from the bundled shapes on disk. Rides are
solid and drawn from the shape of the route the guide names, trimmed to the
stops actually boarded and alighted at; walks are dotted straight lines, which
say "head this way" rather than claiming a surveyed road.

### Steps advance themselves

Every leg knows where it ends, so the guide ticks over from GPS and the commuter
does not have to. Rides complete within 150 m — early on purpose, since the step
turning over as the vehicle nears the stop is the cue to stand up — and walks
within 100 m, the same radius the rest of the app means by "you are standing
here". A short haptic pulse marks each change, because on a moving jeepney the
commuter's eyes are usually not on the phone.

The one exception is deliberate. A *synthetic* suggestion's middle "transfer
points" are places the fallback engine invented from a distance estimate;
completing one from GPS would claim the commuter passed somewhere that does not
exist. Those legs stay tap-only. Their two real ends — the origin and the
destination — are not invented, and do advance. "Done" remains on every step as
the override for a leg the GPS calls early or late.

### Escalation is sequential, and Stage 3 is earned

The alarm has three stages (Figures 26–28): a gentle alert, a louder one, and a
full-screen "WAKE UP". **Distance can raise the alarm to Stage 2 at most.**
Stage 3 is reached only when the commuter stays unresponsive after Stage 2, or on
the third snooze — it has no distance trigger of its own.

That matters because the engine's `stageFor()` reports the highest stage a
distance qualifies for. Firing that stage directly meant a trip begun already
close to the stop — a destination set late, or a first GPS fix that only landed
after boarding — opened straight on "Get Ready" or a full-screen alarm, and the
gentler stages never played. Stages now advance one at a time, and a trip that
starts inside the radius plays the whole sequence at a 5-second catch-up pace
rather than the usual 30.

Three rules follow from the same principle:

- **Snoozing returns one stage louder**, never the same stage. Re-firing Stage 1
  let a commuter idle at the gentlest alert while the vehicle kept closing.
- **Arrival outranks overshoot.** Reaching the destination radius completes the
  trip and ticks off any guide steps still open — the backstop for a synthetic
  leg, which has no coordinates and so can never complete itself. Without that,
  arriving and walking on latched the overshoot detector and announced a missed
  stop the commuter had not missed. It is guarded on *monitoring*: if a stage is on screen
  the commuter has not answered it, and a sounding alarm is never stood down
  automatically.
- **A stage must announce itself.** `_fireStage` notifies from inside, not at
  its call sites. Fired from the GPS handler that is invisible — the fix handler
  notifies once it returns — but fired from the escalation TIMER nothing did, so
  an unattended Stage 1 advanced the model, played the Stage 2 tone and wrote the
  alarm row while the SCREEN stayed on Stage 1 until the next fix rebuilt it.
  With a live stream that is a second of lag; with fixes stalled in a tunnel it
  is a commuter shown a Snooze button for an alarm that has reached Stage 3.

**Signal Lost is silent.** Losing GPS still raises the banner, its Dismiss
action and the log entry, but no longer sounds an alarm. A GPS gap is not
evidence the stop is near — tunnels, urban canyons and a phone in a bag all
produce one mid-trip — and waking a commuter for it taught them to distrust the
alarm that matters.

---

## Core features

### Verified SMS architecture

The SOS does not report success until **the radio says so**.

The native bridge sends each message with a `PendingIntent` per multipart part
and waits for the sent-intent `BroadcastReceiver` before answering Flutter. It
distinguishes `RESULT_OK` from `RESULT_ERROR_NO_SERVICE`, `RESULT_ERROR_RADIO_OFF`
(airplane mode), `RESULT_ERROR_GENERIC_FAILURE` (typically insufficient prepaid
load) and `RESULT_ERROR_NULL_PDU`, and each surfaces as text the commuter can act
on rather than a generic failure.

This replaced a handler that answered `success(true)` the moment `SmsManager`
accepted the request. That is only a handoff to the radio — with no signal or no
load the message is accepted synchronously and dies asynchronously with nothing
listening, so the app reported *"Emergency SMS Sent"* for a message that never
left the phone. **On this feature a false success is worse than a failure**,
because it stops the commuter seeking help.

### Intelligent map tracking

The commute guide floats over a full-bleed map as a `DraggableScrollableSheet`.

- **Bottom-padded camera.** The blue dot is centred in the band of map left
  *visible above the sheet*, not behind it. The offset is resolved into a camera
  centre once per move — re-applying it per animation frame compounds and walks
  the camera off the commuter within a few fixes.
- **Cold-start GPS seeding.** A cold GPS can take 30 s to produce its first
  reading. The map seeds from the OS's cached fix so it is never blank — an
  actual GPS reading, never the trip's origin, and never allowed to overwrite a
  live fix.
- **12-second auto-recenter.** Follow releases on a manual pan so the commuter can
  look ahead, and re-arms after 12 s without a touch. Without that, one finger
  grazing the map while reaching for the guide sheet strands the camera
  permanently and the dot simply slides off screen.
- **Structural safety.** The SOS / Fake Call / Slide-to-Stop footer is a sibling
  *below* the sheet's region, not a layer over it, so the sheet is structurally
  incapable of covering the safety controls however far it is dragged.

### Public lock-screen notifications

The live trip status (destination, remaining distance, ETA, and **SOS · Open ·
End trip** actions) has to be readable while the commuter is asleep.

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
re-entry path. Nothing in NavAlert writes a volume level, so a commuter turning the
ringtone down mid-call has it stay down.

### A shortcut that adjusting the volume cannot fire

The fake call is triggered by a **squeeze** — Volume-Up and Volume-Down within
500 ms of each other — not by a triple-press of Volume-Down.

Triple-press could not survive the context it runs in. The shortcuts arm
whenever the screen is off **or** NavAlert is backgrounded, which on an actual
commute is the normal state: phone in a pocket, music playing. Every ordinary
"turn it down" of three quick taps landed inside the detection window and
launched a fake call. A squeeze cannot be produced by adjusting volume, because
adjusting only ever travels in one direction — nobody raises and lowers within
half a second — while staying a single discreet press of the phone's side.

SOS remains a **triple Volume-Up**.

### Restoring a backup never destroys what is already there

Settings → Data Backup → **Import merges**; it does not overwrite.

- **Contacts** match on a normalised phone number, so the same number saved as
  `+639171234567`, `639171234567` or `09171234567` is recognised rather than
  duplicated. Numbers already saved are left untouched; numbers only in the
  backup fill the free slots of the three the Emergency Contacts screen holds.
- **Favourites** are added when the place is not already saved.
- **Settings, preferences and the caller name** take the backup's value only
  where the current one is still the factory default — so a fresh install
  restores in full, while a commuter who has since chosen their own alarm sound
  keeps it.

Import used to replace whatever was on the phone. Emergency contacts are the one
thing in NavAlert whose loss is discovered only during an emergency, so a
restore that silently dropped them was the wrong default.

### Your own location is searchable

Search recognises "where I am standing" **two ways**, because each covers the
other's blind spot.

**By address text**, matched locally against the reverse-geocoded address and
the words people actually type for themselves — `here`, `me`, `my location`.
Because the match is local it appears instantly, before Nominatim answers. This
is what catches a house or a street: reverse geocoding returns exactly that
kind of string.

**By position.** A street address names the *road*, never the place. Standing
inside PUP the address still reads *Anonas Street, Santa Mesa, Manila*, so
typing `PUP` matched nothing at all. Search now also compares each result's
coordinates against the current fix and flags anything within
`kAtLocationRadiusM` (100 m) as the commuter's own position. Because it reads
coordinates rather than text, it recognises a named place the address never
mentions, and it keeps working when the reverse lookup failed — that lookup is
best-effort and silently leaves the generic label behind when the network is
down.

Distance was added *alongside* the text match rather than replacing it. A
street's map point can sit hundreds of metres from the house on it, so distance
alone would have made the home case worse, not better.

Where a real result **is** the commuter's position, that result is flagged and
raised rather than adding a second row — same place, but carrying the name the
map knows it by.

A fallback position is never offered, and an unknown one never matches — that
is a guess, not a fix, and handing it back as a destination would name a place
the commuter was never at.

Search opens on the prompt, not on the commuter's own address: an empty box
matches nothing.

### Proactive permission UI

Android 13+ marks SMS a **restricted setting** for apps installed outside a
store, and refuses the grant with *"App was denied access to SMS"* — the in-app
request returns denied however many times it is asked, so re-prompting is
useless and silence is dangerous, because the commuter believes SOS is armed.

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
  map survives a force-close in a dead zone, and the corridor along a planned
  route is **warmed while the phone is still online** — see *Offline map tiles*
  below.
- **Route polyline** rendered on-device over those tiles, with the origin dot
  and destination pin.
- **Adaptive launcher icon** generated across all five density buckets, with the
  emblem sized into the 72 dp safe zone so no launcher mask clips it.
- **60 fps SOS ring** driven by an `AnimationController` rather than a 100 ms
  timer, repainting only the indicator instead of the whole screen.

---

## Offline road geometry (bundled PUV shapes)

The route polyline used to come from OSRM at runtime and fell back to a
straight line when the request failed. A commute is when the network is worst,
so the map stopped showing the real road exactly when it mattered, and said
nothing about it.

Road geometry for **all 1,711 routes** in the bundled feed is now pre-computed
at build time and shipped inside the app.

**Phase 1 — `tool/gen_shapes.py`, on a laptop.** Every stop of a route is sent
to OSRM as a waypoint. Routing terminal-to-terminal instead would return the
*fastest* road between the endpoints, not the road the jeepney drives — a
43-stop route through side streets comes back as a run down the highway. That
shape is confidently wrong, which is worse than a straight line, because a
straight line is visibly an approximation.

Simplified with Douglas–Peucker at 8 m and stored as encoded polylines:

| | |
|---|---|
| Routes | 1,711 (0 failed) |
| Points | 396,316 (avg 231/route) |
| Database | **1.9 MB** |
| Generation | 81.6 s against a local OSRM |

**Phase 2 — at runtime.** The shape is looked up by the route name the commute
guide tells the rider to board, then trimmed to the portion actually ridden. A
stored shape runs terminal to terminal; drawing all of it puts tens of
kilometres of line on the map for a two-kilometre trip. During a trip the trim
is done **per leg**, between that leg's own boarding and alighting stops, which
is what lets the map show one segment at a time.

Two details that are not obvious:

- **A route name is not unique.** The feed files most corridors more than once:
  798 names carry several shapes, covering 1,622 of the 1,711 routes, and they
  genuinely differ — one name has variants of 342, 287, 13 and 9 points.
  Variants are ranked by distance from the *worse* of the trip's two ends, so a
  shape must serve both. Taking the first match would sometimes draw a
  nine-point stub twelve kilometres away.
- **A walking suggestion draws no PUV shape at all.** Matching by proximity
  drew whichever route ran near both ends, asserting a ride that was never
  suggested.

Verified on a device in **airplane mode**: a *Jeep: MURPHY 15TH AVE - STOP N
SHOP* trip drew its real road geometry with the network unreachable — and, since
v2.1.0, over a fully rendered basemap rather than blank grey (see below).

### Regenerating

`routes.json.gz` and `shapes.db` are **coupled** — the shapes are keyed on the
feed's route names. Refresh one without the other and every lookup misses
silently, falling back to straight lines with nothing on screen to say so. Use:

```bash
tool/update_gtfs.sh <path-to-new-gtfs-dir>
```

which regenerates both in order and runs the consistency test. The generator
also refuses to resume across a feed change: resume is keyed on route index, so
continuing would keep old shapes under new indices and mix two feeds.

### Offline map tiles

Two findings from v2.1.0, both counter-intuitive enough to be worth recording.

**The slow map was not the server.** The obvious suspect was
`tile.openstreetmap.org` — rate-limited, no Southeast Asia presence. Measured
over six tiles each, it answered in **35 ms** against MapTiler's **550 ms**, so
moving the light basemap to MapTiler would have made it roughly fifteen times
worse. The real cost was `retinaMode`: flutter_map only serves cheap retina when
the URL carries a `{r}` placeholder pointing at a real @2x endpoint. OSM has
none, so it *simulated* retina by fetching one zoom level deeper — **4× the
tiles**, on every high-density phone. Retina is now decided per source: MapTiler
takes the native @2x path, OSM turns it off.

**The trip map was blank offline even with a full cache.** The Home map rendered
Cubao from disk in airplane mode while the Active Trip map, on the same cache and
the same area seconds later, rendered nothing. A `TileLayer` does not request the
camera's zoom, it requests `zoom.round()`. Every other screen sits on a whole
number — Home opens at 14 — so every other screen cached exactly what it
displayed. The trip camera follows at **16.5, which rounds to 17**, and nothing
had ever fetched zoom 17. `NavAlertMap.tripFollowZoom` is now the single source
of truth and the prefetcher derives its zooms from it, so retuning the camera
moves the warmed tiles with it.

**Pre-caching is a ribbon, not a download.** OSM's Tile Usage Policy prohibits
bulk fetching, so `TilePrefetchService` walks only the tiles the drawn route
passes through, three wide, at two zooms, ordered from the START of the journey
so a warm cut short caches the leg reached first — capped at 320 and issued four
at a time. Measured on a device: **133 tiles** for a 5.2 km commute, after which
the whole trip renders with the radio off.

---

## What actually works offline

| Capability | Offline? |
|---|---|
| Step-by-step commute guide (once planned) | ✅ |
| Destination alarm, GPS monitoring, overshoot detection | ✅ |
| Map tiles along a planned route | ✅ (pre-cached at planning time) |
| Map tiles already viewed anywhere else | ✅ (disk cache) |
| SOS SMS | ✅ (native `SmsManager`, no data required) |
| Encrypted trip history / contacts / favourites | ✅ |
| Destination **search** (Nominatim) | ❌ needs network |
| Road **geometry** for the route polyline | ✅ (bundled shapes) |
| **First** download of a tile away from the planned route | ❌ needs network |

Planning a trip needs a connection **for search only**. Riding it does not, and
neither does drawing the road it follows.

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

Package id: `ph.edu.pup.navalert` · Version **1.1.0+2**

### Native Kotlin integrations

| File | Responsibility |
|---|---|
| `MainActivity.kt` | SMS bridge with `PendingIntent` delivery tracking · lock-screen flags · audio-route queries |
| `MediaButtonService.kt` | Screen-off volume shortcuts via an always-active `MediaSession` with a remote `VolumeProvider` — **triple Volume-Up → SOS**, **squeeze Volume-Up + Volume-Down → fake call** |
| `NavAlertWidgetProvider.kt` | Home-screen App Widget (`RemoteViews`) with one-tap SOS |

---

## Getting started

See **[SETUP.md](SETUP.md)** for the full installation guide, the mandatory
uninstall step, and the hardware testing checklist.

```bash
flutter pub get
flutter run
```

New machine? Check it first — read-only, and no Claude Code required:

```bash
.claude/skills/setup-navalert/doctor.sh                       # macOS / Linux
powershell -File .claude\skills\setup-navalert\doctor.ps1     # Windows
```

It reports every missing or mismatched tool with the command that fixes it, and
covers Aurora DX / Fedora Atomic, where the toolchain must be installed into
`$HOME` rather than layered onto the read-only system image.

### Skills shipped with the repo

Three of them, committed under `.claude/skills/` so they arrive with a clone —
nothing to install, nothing to copy into `~/.claude/`:

| | |
|---|---|
| **`/setup-navalert`** | get a machine building (Windows · macOS · Fedora Atomic) |
| **`/run-navalert`** | get the app onto an emulator or handset |
| **`/hunt-navalert`** | drive simulated GPS through whole commutes and hunt for bugs |

Every helper inside them also runs from a plain shell, with no Claude Code
involved. See **[SKILLS.md](SKILLS.md)** for what each one does and, more
usefully, *why each is shaped the way it is* — most of those decisions are a
failure somebody already paid for.

---

## Testing

```bash
flutter analyze   # expect: No issues found
flutter test      # expect: 372/372 passing
```

**26 suites, 372 tests**, covering the adaptive alarm engine, the fare matrix
and NCR bounds, the Dijkstra router against the real production GTFS feed, the
full `TripViewModel` state machine driven from a mock GPS stream on a virtual
clock, the commute-guide overlay geometry measured against a mounted widget
tree, guide segmentation — that every leg carries its own endpoints, that the
map draws the leg the commuter is on and swaps it over when the step does, and
that a synthetic route's invented middle stays tap-only — the route tile
prefetcher, including the drift guard that the zoom it warms is the zoom the
trip map actually asks for, the escalation NOTIFICATION driven purely by
virtual time with no GPS fix delivered, the SOS failure-code contract, the three-second accidental-trigger guard,
the disk tile cache, the distance rule behind current-location matching —
including that an unknown position never counts as a match — and the offline
route-shape geometry: polyline decoding against the Google reference vector and
a real generated shape, trimming to the ridden portion, and picking between
same-named route variants.

They do **not** cover pixel rendering or radio behaviour. Those are verified on
hardware — see the checklist in [SETUP.md](SETUP.md).

---

## Attribution

Transit data © Department of Transportation (DOTC/DOTr), Philippines, via the
Philippine Transit App Challenge and Sakay.ph. Map tiles © OpenStreetMap
contributors, cached locally in line with the OSM tile usage policy. Geocoding ©
Nominatim / OpenStreetMap. Road geometry © OSRM.
