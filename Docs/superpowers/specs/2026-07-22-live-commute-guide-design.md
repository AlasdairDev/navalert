# Live Commute Guide — Design

**Date:** 2026-07-22
**Status:** Approved, ready for implementation

## Problem

NavAlert tracks position in real time, but the commute guide is static. Once
the rider taps **Start Trip**, the step list (walk → ride → alight → walk)
disappears entirely — `active_trip_view.dart` renders no steps. A rider who
forgets which jeepney to board, or where to transfer, has no way to check
mid-trip without abandoning the monitoring screen.

The alarm answers *"when do I get off?"*. Nothing answers *"what do I do now?"*.

## Goal

Keep the commute guide available and current during an active trip, advancing
automatically where the data supports it and by tap where it does not — without
touching the alarm path or the Data Dictionary.

## Non-goals

Explicitly out of scope, to keep the change small and safe:

- Re-routing mid-trip
- Per-step notifications
- Any change to `adaptive_alarm_engine.dart` or `sound_service.dart`
- Any change to the database schema
- Resuming a guide after the app is killed (no active-trip resume exists)

## Key constraint: no coordinates in the schema

Table 24 (`route_steps`) stores stop **names** only — no latitude or longitude.
Figure 34 matches. We are not changing either, so geographic step-advancement
cannot read coordinates from the database.

However, the coordinates already exist at planning time and are being thrown
away: `RouteEngine.buildFromGtfs()` receives `GtfsRouteMatch` objects whose
`boardStop` and `alightStop` are `GtfsStop` values carrying `lat`/`lng`. It
keeps the names and discards the rest.

Because a trip is planned and started in the same session, those coordinates
only need to survive for the duration of the trip. **They live in memory.** The
database, Table 24, and Figure 34 are untouched.

## Coverage: why this must be a hybrid

Auto-advance only works for GTFS-matched routes. When `GtfsService.directRoutes`
finds no match — short hops below its `rideM >= 300` threshold, or areas the feed
does not cover — `HomeViewModel._composeSuggestions()` falls back to the
synthetic `RouteEngine.buildSuggestions()`. Synthetic legs are fractions of a
straight line and their stops ("… Terminal", "Transfer point") are fictional.

This is not hypothetical: a 0.5 km test trip from PUP produced synthetic steps,
not GTFS ones. Auto-advancing on a synthetic leg would invent a location the
rider never passes.

So:

| Leg source | Advancement |
|---|---|
| GTFS-matched (has coordinates) | Automatic within 150 m of the alight stop |
| Synthetic (no coordinates) | Rider taps "Done" |

The rider can **always** tap to advance or correct, on either kind. A mistimed
auto-advance is a display error the rider overrides — never a trap.

## Architecture

Follows the existing MVVM layering. No new patterns.

### New runtime type

```dart
/// Runtime-only. NOT a Data Dictionary table and never persisted —
/// toMap()/fromMap() deliberately do not exist.
class GuideLeg {
  final RouteStep step;
  final double? endLat;   // present only for GTFS-matched legs
  final double? endLng;
  bool get canAutoAdvance => endLat != null && endLng != null;
}
```

Wrapping `RouteStep` rather than adding nullable fields to it keeps the
persisted/runtime boundary explicit: nothing about `GuideLeg` can leak into
SQLite by accident.

### Layer changes

- **`RouteEngine`** — `buildFromGtfs()` and `buildSuggestions()` gain an
  optional `Map<String, List<GuideLeg>>? legsOut` parameter, populated per
  suggestion id when supplied. Optional so existing callers and tests are
  unaffected.
- **`HomeViewModel`** — retains the map from `_composeSuggestions()`; exposes
  `List<GuideLeg> legsFor(String suggestionId)`.
- **`route_view`** — passes the selected suggestion's legs into
  `tripVm.startTrip(trip, guide: legs)`.
- **`TripViewModel`** — holds `guideLegs` and `currentLegIndex`; exposes
  `markLegDone()`; calls a guarded `_advanceGuide()` from the existing `_onFix`.
- **`lib/views/commute_guide_sheet.dart`** (new file) — the sheet. A new file
  rather than growing `active_trip_view.dart`, which already covers monitoring,
  three alarm stages, and overshoot.

## UI

A `DraggableScrollableSheet` on the monitoring screen, **collapsed to a drag
handle by default**. Collapsed, the screen is visually identical to Figure 24 —
the paper's GUI documentation stays accurate, and the "Get some rest. We got
you." premise is preserved.

Pulled up, it lists the legs with the current one highlighted and a "Done"
button. It is rendered **only during monitoring** — never over an alarm stage or
the overshoot prompt, where the screen must be the alert.

## Data flow

1. Rider plans a trip; `_composeSuggestions()` builds suggestions and legs.
2. Rider picks a suggestion and starts the trip; legs are handed to
   `TripViewModel`.
3. Each GPS fix (1 Hz, already running) updates the alarm as today, then — after
   the alarm logic — checks whether the current leg can auto-advance and whether
   the rider is within 150 m of its end.
4. Rider may tap "Done" at any time to advance manually.

## Error handling

- **No guide supplied** (favorites shortcut, or no suggestion selected) →
  `guideLegs` is empty → the sheet does not render at all. No empty state.
- **Auto-advance is monotonic** — never moves backwards, never past the last leg.
- **Manual tap always wins** over auto-advance.
- **Guide logic runs after alarm logic and is wrapped so it cannot throw into
  it.** This is the load-bearing safety rule: a bug in the guide must never
  prevent an alarm stage from firing. The guide is a convenience; the alarm is
  the product.

## Testing

`GuideLeg` advancement is pure logic — unit-testable without plugins, like the
alarm engine:

- advances when within 150 m of a GTFS leg's end
- does **not** auto-advance a synthetic leg (null coordinates) at any distance
- never advances past the final leg; never moves backwards
- manual advance works on both leg kinds
- an empty guide is a no-op
- a failure inside guide advancement does not propagate to the caller

Mutation-check the suite by breaking the logic and confirming the tests fail.

## Known limitations

- Guide progress is in memory; killing the app loses it. There is no active-trip
  resume in NavAlert today, so the trip itself is lost regardless.
- 150 m may fire slightly early where Manila stops sit close together.
- GPS drifts in urban canyons.

## Related, deliberately not bundled

`route_steps` rows are written but never read back — the table is currently
write-only. This design does not fix that (coordinates must come from memory
regardless, so a database read would add a code path with no consumer). Worth
addressing separately.
