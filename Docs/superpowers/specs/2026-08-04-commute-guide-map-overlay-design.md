# Commute Guide — Map Overlay & Camera Tracking

**Date:** 2026-08-04
**Status:** Approved, implementing
**Scope:** The guide-first (alarm OFF) Active Trip layout only.

---

## Problem

The directive that prompted this work states that "the Commute Guide view completely
obscures the map." The premise needed one correction before it could be designed
against: **the Active Trip screen has no map at all, and never had one.**

`ActiveTripView` renders a purple gradient wash (`_Monitoring._wash`). `FlutterMap`
appears only in `home_view.dart`, `route_view.dart` and `pin_on_map_view.dart`. So the
guide is not covering a map — there is nothing underneath it.

The real gap is the same one the directive identifies, one layer down: with the
destination alarm OFF, the rider is using NavAlert as a **navigation tool**, and a
navigation tool that cannot show you where you are is not one. The `_guideFirst`
layout gives the whole body to a static list of steps. A rider on a jeepney has no
way to answer "where am I on this route right now?"

This adds the live map, layers the guide over it as a bottom sheet, and makes the
camera track the rider.

## Non-goals

- The **alarm-ON** layout (Figure 24) is untouched. Its premise is *sleeping*
  ("Get some rest. We got you."), it is pixel-faithful to the mockups shown to the
  panel, and its 6.2% collapsed sheet already works. A map behind it would advertise
  a navigation screen to a rider who has handed the trip over.
- No change to any alarm stage, the overshoot prompt, or the arrival summary.
- No schema change. `GuideLeg` stays runtime-only.

---

## 1. Architecture

The guide-first layout becomes a three-layer `Stack` with a full-bleed map at the
bottom:

```
Stack
├─ [0] TripMapView                 full-screen FlutterMap
└─ [1] Column (transparent)
      ├─ header plate              En Route · destination · alarm chip · step counter
      ├─ Expanded                  transparent — map shows through
      │    └─ DraggableScrollableSheet   anchored to this region's bottom
      └─ footer plate              signal-lost/error · readouts · SOS/Fake Call · Slide-to-Stop
```

The footer is a **sibling below the sheet's region**, not a layer over it. The sheet
is therefore structurally incapable of reaching the safety controls — a stronger
guarantee than the `collapsedHeight` padding arithmetic it replaces on this path, and
it preserves the intent of the existing `DO NOT MODIFY LOGIC` guard
(`_collapsedFractionFor`, `snapSizes`) without editing it. That guard stays live and
unmodified for the alarm-ON path.

### Files

| File | Change |
|---|---|
| `lib/views/commute_sheet_layout.dart` | **new** — pure-Dart sheet geometry + `TripCameraTracker` |
| `lib/views/trip_map.dart` | **new** — `TripMapView` |
| `lib/views/active_trip_view.dart` | `_guideFirst` rewritten; everything else untouched |
| `lib/views/commute_guide_sheet.dart` | `inline` mode accepts an optional `ScrollController` |
| `lib/viewmodels/trip_viewmodel.dart` | additive `currentLat` / `currentLng` getters |
| `lib/core/map_support.dart` | `AnimatedMapMover.animateTo` gains optional `offset` |

`commute_sheet_layout.dart` follows the `HomeFabLayout` precedent: geometry pulled out
of the widget purely so the no-overlap rules can be asserted headlessly.

The leg cards are still rendered by `CommuteGuideSheet`'s own `_legCard`, so the
planning guide, the alarm-ON sheet and this screen remain **one component**. That is
the invariant `commute_guide_sheet.dart` was written to protect and this change keeps
it.

---

## 2. Sheet geometry

Fractions are declared against the **full screen** — that is what the requirement is
written in — and converted to the parent-relative fractions
`DraggableScrollableSheet` actually consumes.

```dart
restingScreenFraction = 0.36   // sheet + footer ≤ ~38% of screen at rest
minMapVisibleFraction = 0.22   // ≥22% of screen stays map at full extension
```

At rest the sheet plus footer occupy the bottom ~38% of the screen, leaving the top
half of the map clear. Dragged to full extension the sheet still stops short of the
top, so map context is never 100% lost.

Every conversion clamps into `(0, 1]` and enforces `min ≤ initial ≤ max`, including
on a degenerate screen or an unusually tall footer — the Signal Lost card inflates the
footer by ~90 px, which is a real runtime state, not a hypothetical. Violating that
ordering throws `ArgumentError` inside `DraggableScrollableSheet`: the same class of
crash the slider's `math.max(0.0, …)` floor guards against, on a screen the rider
cannot leave without the Slide-to-Stop control. It is asserted directly.

`snap: true` is kept with snap points at rest and full, matching the existing sheet.

---

## 3. Camera tracking & bottom padding

The blue dot is centred in the **visible band above the sheet**, not at the widget
centre.

- **Obscured height** = footer height + live sheet extent, tracked through
  `NotificationListener<DraggableScrollableNotification>`.
- **Offset** — `MapController.move(target, zoom, offset: Offset(0, -obscured / 2))`.
  flutter_map 7.0.2 documents `Offset(0, y)` as moving the intended centre *down* by
  `y`, so a negative `y` lifts the dot into the visible band's centre. Re-issued when
  the sheet is dragged, so the dot stays centred as the band grows and shrinks.
- **Follow state** — `TripCameraTracker`, a pure class. `following` defaults true;
  `onPositionChanged(hasGesture: true)` disengages; the recenter FAB re-engages.
  `AnimatedMapMover`'s programmatic moves report `hasGesture == false`, so there is no
  self-disengaging feedback loop.
- **Motion** — the dot reuses `LatLngGlide` so it travels between fixes instead of
  teleporting; the camera eases with `AnimatedMapMover`. Both are already tested.

### Why follow is escapable

A hard always-follow is what the directive literally asks for, and it is unusable: a
fix lands every ~1–2 s, so every attempt to look ahead down the route is yanked back
within seconds. Follow therefore disengages on a manual pan and offers a recenter FAB
— standard navigation behaviour, and it still satisfies "the camera must automatically
pan to keep the user centered" in the default state the rider is in unless they
deliberately leave it.

### No fix yet → no dot

The camera opens on `trip.origin` and the blue dot is **withheld** until
`vm.currentLat != null`. This matches the rule HomeView already states: a missing pin
is honest, a confident wrong pin is not — drawing the dot at the origin would present
a stale planning coordinate as the rider's live position.

---

## 4. Constraints

### Untouched

Every `DO NOT MODIFY LOGIC` / capstone-defense block: the `PopScope` back guard, the
`vm.phase` → widget switch, `_SlideToStop`'s gesture math and 60% threshold, the
SOS/Fake Call debouncers and their 40 px separation, `_AlarmToggleChip`'s wiring,
`markGuideLegDone`, and the alarm-ON sheet's collapsed-fraction arithmetic.

`TileCacheStore`, `NavAlertMap.tiles`, `_tileProvider`, `panBuffer` / `keepBuffer` and
`ncrConstraint` are consumed exactly as HomeView consumes them — no new tile provider,
no second Dio client, no new cache store. The offline map path is untouched.

### Styling

Every widget keeps its current colours, fonts, sizes and copy; `NavAlertColors` tokens
throughout. Two necessary additions:

- The header and footer get a `NavAlertColors.background` plate at ~0.92 alpha so text
  stays legible over OSM tiles — the same device HomeView's header already uses.
- The `_wash` gradient no longer covers the guide-first layout, because it would hide
  the map it now sits on. It is retained for the alarm-ON layout.

---

## 5. Testing

Headless, matching the suite's convention (only `marker_glide_test` uses
`testWidgets`, and it does so on an isolated widget with no map).

**`test/commute_sheet_layout_test.dart`**
- resting sheet + footer ≤ 40% of screen
- ≥22% of screen still map at full extension
- `min ≤ initial ≤ max` across screens 480–1200 px and footers 100–320 px
- degenerate inputs (zero/negative region, footer taller than the screen) still
  produce valid fractions rather than throwing

**`test/trip_camera_tracker_test.dart`**
- follow engaged by default
- a gesture disengages it
- a programmatic move does not
- recenter re-engages
- the camera offset is negative and half the obscured height

**`test/trip_flow_test.dart`** — the new `currentLat`/`currentLng` getters exercised
through the existing mock-GPS harness, including the no-fix-yet null case.

Then `flutter analyze` and the full suite.

### Verification limits

The layering, the tile rendering and the on-device feel of the camera cannot be
verified in this environment — there is no emulator. Geometry and follow-state are
proven by the headless tests above; the visual result is confirmed by the author on a
local Android emulator.
