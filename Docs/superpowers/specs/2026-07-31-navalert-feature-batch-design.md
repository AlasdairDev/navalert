# NavAlert — Feature Batch Design (post-baseline)

**Date:** 2026-07-31
**Baseline:** `d69760a` (branch `ui-handoff-baseline`)
**Status:** Approved by user, pending spec review

Eight changes requested after the UI hand-off baseline was locked. Grouped by
risk so the safe work can land first.

> **Scope note.** `README.md` currently declares the backend "feature-frozen".
> This batch changes that. The README must be updated when this work lands, or
> it misrepresents the project to the panel.

---

## Constraints that shape every decision here

1. **`test/` and `integration_test/` are off-limits.** No test file may be
   created or modified. Any change that would break an existing test must be
   designed around instead — there is no option to update the test.
2. **165 unit tests must stay green.** In particular `trip_flow_test.dart` (17
   tests) asserts that alarm stages fire, and `schema_guard_test.dart` (3 tests)
   asserts the database has exactly 13 tables.
3. **Safety guards are annotated.** Every `DO NOT MODIFY LOGIC - CAPSTONE
   DEFENSE CRITICAL:` block must survive this work intact.

---

## Group A — Low risk, presentation layer

### A1. Delete a custom fake-call recording

**Problem.** Custom recordings can be created but never removed.

**Design.** `DatabaseService.deleteRecording(String id)` already exists, so this
is a UI addition in `FakeCallSetupView` (and the Emergency tab list).

- Delete affordance appears **only** on custom rows (`isPreset == false`).
  Built-in presets are not deletable.
- Confirm dialog first, matching the existing destructive-action pattern used by
  trip and favourite deletion.
- Deletion must do three things together, or it leaves broken state:
  1. delete the `recordings` row,
  2. delete the `.m4a` file from disk (otherwise storage leaks on every delete),
  3. if the deleted recording was the one selected in `fakeCallConfig`, clear the
     selection and fall back to the first preset.

**Failure mode guarded:** without step 3, `fakeCallConfig.recordingId` points at
a missing file and the fake call — a safety feature — silently plays nothing.

### A2. Search returns 5 well-ranked suggestions

**Problem.** Nominatim ranks by its own "importance" score, so results are often
not the closest or most relevant to what was typed.

**Design.** Keep one API call. Request 10 results instead of 6, then rank locally
and take the top 5:

1. exact / prefix match on the typed text ranks highest,
2. substring match next,
3. tie-break by distance from the rider's current position.

Requires passing current lat/lng into `GeocodingService.search`; `HomeViewModel`
already holds them. Local ranking means no extra network cost and no change to
the Nominatim usage policy.

**Explicitly not doing:** live per-keystroke autocomplete. The existing 600 ms
debounce and 3-character minimum stay — Nominatim's usage policy discourages
per-keystroke querying.

### A3. Current location pinned correctly before searching

**Problem.** `HomeView` draws the blue "you are here" dot at
`LatLng(vm.currentLat ?? 14.5979, vm.currentLng ?? 121.0108)`. With no GPS fix
that renders the **PUP Sta. Mesa fallback as though it were the rider's real
position** — an authoritative-looking pin on a location they are nowhere near.

**Design.**

- When `vm.locationIsFallback` is true, **do not draw the current-location
  marker at all.** The existing warning banner already explains why. A missing
  pin is honest; a wrong pin is not.
- When a real fix arrives, drop the pin and animate the camera to it.
- Keep the map centred on the fallback coordinates (the map needs *somewhere* to
  look) — just without the "this is you" marker.

**Related:** the first-frame acquisition uses `promptIfDisabled: false`, so with
location services off it falls through to the banner rather than ejecting the
rider into Android Settings. That behaviour stays.

### A4. NCR out-of-service message

**Problem.** `_composeSuggestions` requires **both** origin and destination
inside NCR. A rider starting in Bulacan/Cavite/Rizal and travelling into Metro
Manila gets "No commute guide available — NavAlert covers Metro Manila (NCR)
only", which implies the destination is at fault.

**Decision: keep the restriction.** The GTFS feed and LTFRB fare matrix genuinely
cover NCR only. Routing from outside would mean inventing routes and fares a
rider might actually try to pay.

**Design.** Change the message only. It must:

- name **which end** is out of range ("Your starting point is outside Metro
  Manila"), and
- state plainly that the **destination alarm still works anywhere** — that is
  already true and is the reassurance the current copy buries.

---

## Group B — Touches tested core

### B1. Alarm optional, disabled by default

**Requirement.** Trips start with the alarm off; the rider can enable it at any
time, including mid-trip.

**The constraint.** `trip_flow_test.dart` has 17 tests that call `startTrip()`
and assert stages fire. Defaulting the model field to `false` breaks all of
them, and `test/` cannot be edited.

**Design.**

- Add `bool alarmEnabled` to the `Trip` model, **defaulting to `true`**. Existing
  tests and existing behaviour are untouched.
- The **Trip Settings sheet explicitly sets `alarmEnabled = false`** when
  starting a trip, unless the rider turns the toggle on. This delivers
  off-by-default in the real app without touching a single test.
- Add an alarm on/off control to the Active Trip screen so it can be toggled
  mid-trip.
- In `TripViewModel._onFix`, skip stage evaluation when `alarmEnabled` is false.
  Distance, ETA, overshoot detection and the commute guide continue to run — only
  the alarm stages are suppressed.

**Persistence: none.** `alarmEnabled` is in-memory only, held on the `Trip`
object for the life of the trip. No column, no migration, no risk to
`schema_guard_test`'s 13-table assertion.

**Accepted risk, stated for the record:** the destination alarm is the app's
headline feature and this ships it off by default. The user confirmed this
deliberately. Expect the panel to ask.

---

## Group C — Safety-critical

### C1. SOS retry cadence

**Current:** one immediate send; on failure, 5 retries 30 seconds apart, then
give up.

**Required:** 3 attempts, then every 15 minutes until delivered.

**Design.**

- Attempt 1 — immediate (the existing initial send).
- Attempts 2 and 3 — 30 seconds apart.
- After 3 failed attempts, switch to a **15-minute periodic retry that continues
  until the SMS is delivered** or the trip/app is torn down.

**Consequence that must be handled:** "until delivered" means the retry never
gives up, so the existing "SOS could NOT be sent" failure message would never
fire, leaving the rider believing help is coming. Therefore: when the 3 fast
attempts fail and it drops into slow-retry, **notify the rider once** that
delivery is still pending and they should consider Call 911.

`SosService.dispose()` must still cancel the timer — a 15-minute periodic timer
outliving the ViewModel would call back into a dead listener.

### C2. Separate the three emergency triggers

**Reported:** SOS SMS, the fake-call recording, and Call 911 fire together.

**Investigation finding.** Static reading shows **no shared code path**:
`fireSos()` never touches audio; only `startFakeCall()` (ringtone) and
`answerFakeCall()` (voice recording) play anything. The three are already
separate in Dart.

**Therefore the root cause is not yet known** and no fix is designed here.
Candidate causes to test on-device, in order:

1. The native `MediaButtonService` emitting both `sos` and `fakecall` on the
   volume shortcut.
2. Touch-target overlap on the Emergency tab — the SOS hold area, the Call 911
   button and the recording rows are vertically adjacent.
3. A stale `SoundService` handle replaying the last voice clip.

**Implementation step 1 is reproduction with logging at each boundary**, using
the systematic-debugging process. No fix until the failing component is
identified.

**Target behaviour once the cause is known** — three distinct, deliberate
triggers:

| Action | Trigger | Guard |
|---|---|---|
| SOS SMS | 3-second press-and-hold | existing R8 hold |
| Fake call | explicit recording selection | in-flight gate |
| Call 911 | dedicated button | **confirm dialog (new)** |

**Separate finding, worth fixing regardless:** `Call 911` currently launches the
dialer on a **single tap with no confirmation**, on a screen used by people in
distress. This is very likely part of the reported behaviour. Add a confirm step.

### C3. SOS action on the lock-screen notification

**Requested:** the home-widget card — destination, distance, ETA, Monitoring
status, and an "SOS — send my location" button — reproduced on the lock screen.

**Constraint, stated plainly.** The screenshot is the **home-screen App Widget**,
which uses a custom `RemoteViews` layout. A lock-screen **notification** is
rendered by the Android system: title, body, small icon, and action buttons in
the system's style. Android 12+ reformats custom notification views. **A
pixel-identical purple card with a red pill button is not achievable as a
notification.**

**Design — match the function, accept the system styling.**
`TripNotificationService` already posts destination, distance, ETA and
"Monitoring" with `visibility: public` and actions **Open in App** and **End
trip**. Add a third action: **"SOS — send my location"**.

Implementation notes:

- The action must work with the device locked, which is the entire point. That
  means a background notification-response handler
  (`onDidReceiveBackgroundNotificationResponse` with a top-level
  `@pragma('vm:entry-point')` function), because the app may be backgrounded or
  killed.
- The background isolate does not share state with the UI isolate; the handler
  needs its own path to the database and the SMS platform channel.
- **Do not break the update-dedupe guard.** `showTrip` is called on every GPS fix
  and skips posting when the text is unchanged; that guard is annotated as
  battery-critical and must survive.
- **Accidental-trigger note:** this is a one-tap SOS, which is weaker than the
  3-second hold R8 mandates. It matches the existing home-widget behaviour, and
  one-tap is arguably correct for an emergency shortcut, but it is a real
  pocket-tap risk on a lock screen and is recorded here as an accepted trade-off.

---

## Recommended order

1. **Group A** (A1–A4) — low risk, visible, no test exposure.
2. **B1** — alarm optional; verify all 165 tests still pass immediately after.
3. **C2 investigation** — reproduce before designing a fix.
4. **C1**, then **C3** — the two emergency changes, one at a time.

Verification gate after every group: `flutter analyze` clean and
`flutter test` at 165/165.
