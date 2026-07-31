# Group A — UI Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the four low-risk, presentation-layer changes from the feature batch — recording deletion, better search ranking, an honest location pin, and a clearer out-of-service message.

**Architecture:** All four changes live in the view and service layers. None touches `TripViewModel`, the alarm state machine, the routing isolate, or the database schema. Each task is independently shippable and independently revertible.

**Tech Stack:** Flutter 3.41.9 · Dart 3.11.5 · provider (MVVM) · flutter_map · Nominatim · sqflite_sqlcipher

**Spec:** `Docs/superpowers/specs/2026-07-31-navalert-feature-batch-design.md` (Group A)

## Global Constraints

- **NEVER create or modify any file under `test/` or `integration_test/`.** This is a standing user instruction and it overrides this skill's default TDD structure. Where this plan would normally say "write a failing test", it instead specifies a regression check plus an explicit on-device verification.
- **`flutter test` must report 165/165 passing after every task.** Any drop means the change reached logic it should not have.
- **`flutter analyze` must report "No issues found" after every task.**
- **Every `// DO NOT MODIFY LOGIC - CAPSTONE DEFENSE CRITICAL:` block must survive intact.** Do not unwrap, reorder, or "simplify" any annotated guard.
- **No database schema changes.** `schema_guard_test.dart` asserts exactly 13 tables.
- Working branch: `ui-handoff-baseline`. Baseline commit: `f6cdffa`.
- Emulator for verification: `emulator-5554`.

---

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `lib/viewmodels/app_viewmodel.dart` | Add `removeRecording` — DB row + file + selection fallback | 1 |
| `lib/views/onboarding_flow.dart` | Delete affordance in `FakeCallSetupView` | 1 |
| `lib/services/geocoding_service.dart` | Fetch 10, rank locally, return 5 | 2 |
| `lib/viewmodels/home_viewmodel.dart` | Pass origin into search; reword NCR message | 2, 4 |
| `lib/views/home_view.dart` | Suppress the fallback location marker | 3 |

---

### Task 1: Delete a custom fake-call recording

> **CORRECTION (found during execution).** `removeRecording` **already
> existed** at `app_viewmodel.dart:183` as dead code — nothing called it. This
> task therefore *hardens the existing method*; adding a second one would not
> compile. The existing version had three defects: no preset guard, no `.m4a`
> file cleanup, and it nulled the selection instead of falling back to a
> recording that still exists. A fourth issue surfaced on implementation:
> `SoundService.stopVoice()` must run before deletion, or a previewed file is
> still open and Android can refuse the delete.

**Files:**
- Modify: `lib/viewmodels/app_viewmodel.dart:183` (harden the existing `removeRecording`)
- Modify: `lib/views/onboarding_flow.dart` (`_FakeCallSetupViewState`, recording dropdown area ~line 853)

**Interfaces:**
- Consumes: `DatabaseService.deleteRecording(String id)` — already exists at `database_service.dart:504`
- Produces: `AppViewModel.removeRecording(String recordingId) → Future<void>`

- [ ] **Step 1: Add `removeRecording` to AppViewModel**

Insert directly after the existing `addRecording` method (`app_viewmodel.dart:171-180`):

```dart
  /// Deletes a CUSTOM recording: the database row, the audio file on disk, and
  /// the selection if it pointed here.
  ///
  /// DO NOT MODIFY LOGIC: all three must happen together. Leaving the file
  /// behind leaks storage on every delete; leaving `fakeCallConfig.recordingId`
  /// pointing at a deleted row makes the fake call — a safety feature — play
  /// nothing at the moment the rider needs it. Presets are never deletable.
  Future<void> removeRecording(String recordingId) async {
    final target = recordings.where((r) => r.recordingId == recordingId);
    if (target.isEmpty || target.first.isPreset) return;
    final path = target.first.filePath;

    await _db.deleteRecording(recordingId);
    recordings = await _db.getRecordings();

    // Best-effort: a missing or locked file must not fail the delete the user
    // already confirmed. The row is gone either way.
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {/* row already removed — storage cleanup is secondary */}

    // Selection fallback: point at the first remaining recording (a preset),
    // never at a row that no longer exists.
    if (fakeCallConfig.recordingId == recordingId) {
      fakeCallConfig.recordingId =
          recordings.isEmpty ? null : recordings.first.recordingId;
      try {
        await saveFakeCallConfig();
      } catch (_) {/* not persisted — in-memory selection is still correct */}
    }
    notifyListeners();
  }
```

`dart:io` is already imported at `app_viewmodel.dart:2`. Confirm before running.

- [ ] **Step 2: Verify it compiles**

Run: `flutter analyze`
Expected: `No issues found!`

- [ ] **Step 3: Add the delete affordance to FakeCallSetupView**

In `lib/views/onboarding_flow.dart`, inside `_FakeCallSetupViewState.build`, immediately **after** the `Card` containing the recording `DropdownButton` (the widget ending around line 877), insert:

```dart
              // Delete the selected CUSTOM recording. Presets have no delete
              // affordance at all — the row simply does not render for them.
              if (app.selectedRecording != null &&
                  !app.selectedRecording!.isPreset)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _deleteSelectedRecording,
                    icon: const Icon(Icons.delete_outline,
                        size: 18, color: NavAlertColors.danger),
                    label: const Text('Delete this recording',
                        style: TextStyle(color: NavAlertColors.danger)),
                  ),
                ),
```

- [ ] **Step 4: Add the confirm-then-delete handler**

In the same class, add after `_preview()` (~line 769):

```dart
  /// Click-to-confirm deletion, matching the trip/favorite pattern: nothing is
  /// removed until the rider explicitly confirms.
  Future<void> _deleteSelectedRecording() async {
    final app = context.read<AppViewModel>();
    final rec = app.selectedRecording;
    if (rec == null || rec.isPreset) return;
    final messenger = ScaffoldMessenger.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this recording?'),
        content: Text(
          '${rec.title}\n\nThis permanently removes the recording from your '
          'device. This cannot be undone.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete',
                style: TextStyle(
                    color: NavAlertColors.danger,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await app.removeRecording(rec.recordingId);
      messenger.showSnackBar(
          SnackBar(content: Text('${rec.title} deleted.')));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Could not delete — storage is unavailable.')));
    }
    if (mounted) setState(() {});
  }
```

- [ ] **Step 5: Verify analyze + full regression**

Run: `flutter analyze`
Expected: `No issues found!`

Run: `flutter test`
Expected: `+165: All tests passed!`

- [ ] **Step 6: Verify on device**

Run: `flutter run -d emulator-5554`

Check, in order:
1. Settings → Fake Call → View. With a **preset** selected, no delete row is visible.
2. Record a new clip. It becomes selected and the delete row appears.
3. Tap Delete → Cancel. Recording still present.
4. Tap Delete → Delete. Recording disappears, snackbar confirms, dropdown falls back to a preset.
5. Trigger a fake call. It still plays — the selection fallback worked.

- [ ] **Step 7: Commit**

```bash
git add lib/viewmodels/app_viewmodel.dart lib/views/onboarding_flow.dart
git commit -m "feat: allow deleting custom fake-call recordings

Deletes the row, the .m4a on disk, and falls back to a preset when the
deleted clip was the selected one. Presets remain undeletable."
```

---

### Task 2: Search returns 5 well-ranked suggestions

**Files:**
- Modify: `lib/services/geocoding_service.dart:17-57` (`search`)
- Modify: `lib/viewmodels/home_viewmodel.dart:196-212` (`search`)

**Interfaces:**
- Produces: `GeocodingService.search(String query, {double? nearLat, double? nearLng}) → Future<List<PlaceResult>>` — returns **at most 5**, ranked. The added parameters are optional, so the existing call in `add_favorite_view.dart:58` keeps compiling unchanged.

- [ ] **Step 1: Widen the fetch and add ranking parameters**

In `lib/services/geocoding_service.dart`, change the signature at line 17 and the `limit` at line 22:

```dart
  /// Returns at most [maxResults] places, ranked locally.
  ///
  /// Nominatim orders by its own "importance" score, which surfaces large
  /// distant landmarks above the small nearby place the rider actually typed.
  /// We over-fetch and re-rank instead: text match first, then proximity to
  /// [nearLat]/[nearLng] when a position is known.
  static const int maxResults = 5;

  Future<List<PlaceResult>> search(String query,
      {double? nearLat, double? nearLng}) async {
    if (query.trim().isEmpty) return [];
    final uri = Uri.parse(_base).replace(queryParameters: {
      'q': query,
      'format': 'jsonv2',
      'limit': '10', // over-fetch, then rank locally down to maxResults
```

Leave every other query parameter (`countrycodes`, `viewbox`, `bounded`, `addressdetails`) exactly as-is.

- [ ] **Step 2: Rank and trim before returning**

In the same file, replace the final `return results;` (line 57) with:

```dart
    _rank(results, query, nearLat, nearLng);
    return results.length <= maxResults
        ? results
        : results.sublist(0, maxResults);
  }

  /// Sorts in place: better text match first, then nearer.
  ///
  /// Score is deliberately simple and total-ordered so the sort is stable and
  /// predictable: 0 = name starts with the query, 1 = name contains it,
  /// 2 = only the full address contains it, 3 = no textual match.
  static void _rank(List<PlaceResult> results, String query, double? lat,
      double? lng) {
    final q = query.trim().toLowerCase();

    int textScore(PlaceResult p) {
      final name = p.name.toLowerCase();
      if (name.startsWith(q)) return 0;
      if (name.contains(q)) return 1;
      if (p.displayName.toLowerCase().contains(q)) return 2;
      return 3;
    }

    // Squared degree distance — no need for real haversine to order candidates
    // that are all inside one metro region.
    double proximity(PlaceResult p) {
      if (lat == null || lng == null) return 0;
      final dLat = p.lat - lat;
      final dLng = p.lng - lng;
      return dLat * dLat + dLng * dLng;
    }

    results.sort((a, b) {
      final byText = textScore(a).compareTo(textScore(b));
      if (byText != 0) return byText;
      return proximity(a).compareTo(proximity(b));
    });
  }
```

- [ ] **Step 3: Pass the rider's position from HomeViewModel**

In `lib/viewmodels/home_viewmodel.dart`, in `search` (line 201), replace:

```dart
      results = await _geocoder.search(query);
```

with:

```dart
      // Rank against the rider's own position so nearby places win ties.
      // Null when there is no fix yet — ranking then falls back to text only.
      results = await _geocoder.search(query,
          nearLat: locationIsFallback ? null : currentLat,
          nearLng: locationIsFallback ? null : currentLng);
```

Passing `null` when `locationIsFallback` is deliberate: ranking by a fallback position would sort results around PUP Sta. Mesa for a rider who is nowhere near it.

- [ ] **Step 4: Verify analyze + full regression**

Run: `flutter analyze`
Expected: `No issues found!`

Run: `flutter test`
Expected: `+165: All tests passed!` (`gtfs_service_test` and `route_engine_test` must be unaffected — this touches neither)

- [ ] **Step 5: Verify on device**

Run: `flutter run -d emulator-5554`

Check: Home → Search → type `Bagumbong`. At most **5** results. The closest/most exact match is first, not a distant landmark.

- [ ] **Step 6: Commit**

```bash
git add lib/services/geocoding_service.dart lib/viewmodels/home_viewmodel.dart
git commit -m "feat: rank search results locally and cap at 5

Over-fetch 10 from Nominatim, then rank by text match and proximity to
the rider. Ignores a fallback position so results are not sorted around
a location the rider is not at."
```

---

### Task 3: Never draw a location pin the rider is not at

**Files:**
- Modify: `lib/views/home_view.dart:99-118` (the `MarkerLayer`)

**Interfaces:**
- Consumes: `HomeViewModel.locationIsFallback` (bool, already exists at `home_viewmodel.dart:93`)

- [ ] **Step 1: Make the marker conditional**

In `lib/views/home_view.dart`, replace the whole `MarkerLayer(markers: [...])` block with:

```dart
              // DO NOT MODIFY LOGIC: the "you are here" dot renders ONLY for a
              // real GPS fix. `center` falls back to PUP Sta. Mesa when there is
              // no fix, and drawing the blue dot there presented a hardcoded
              // location as the rider's own — indistinguishable from a working
              // fix, on the screen where they choose where they are going. A
              // missing pin is honest; a confident wrong pin is not. The
              // fallback banner below already explains the situation.
              MarkerLayer(markers: [
                if (!vm.locationIsFallback && vm.currentLat != null)
                  Marker(
                    point: center,
                    width: 22,
                    height: 22,
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        // TODO (UI Team): the current-location dot style.
                        // Google-Maps-style blue is intentional and widely
                        // recognised; 0xFF4285F4 is a deliberate keep.
                        color: const Color(0xFF4285F4),
                        border: Border.all(color: Colors.white, width: 3),
                        boxShadow: const [
                          BoxShadow(color: Colors.black38, blurRadius: 4),
                        ],
                      ),
                    ),
                  ),
              ]),
```

The map still centres on `center` — it needs somewhere to look. Only the "this is you" claim is withheld.

- [ ] **Step 2: Verify analyze + full regression**

Run: `flutter analyze`
Expected: `No issues found!`

Run: `flutter test`
Expected: `+165: All tests passed!`

- [ ] **Step 3: Verify both states on device**

Run: `flutter run -d emulator-5554`

**Fallback state** — in the emulator's ⋯ menu → Location, do **not** set a position (or disable location):
- Expect: **no blue dot**, and the orange "Using your last known location…" / "Could not get your location…" banner is visible.

**Real-fix state** — set a location in the emulator and tap the locate FAB:
- Expect: blue dot appears at that position and the camera animates to it.

- [ ] **Step 4: Commit**

```bash
git add lib/views/home_view.dart
git commit -m "fix: do not draw the current-location pin on a fallback position

The blue you-are-here dot rendered at the PUP fallback whenever GPS had
no fix, presenting a hardcoded location as the rider's own. It now
renders only for a real fix; the existing banner covers the other case."
```

---

### Task 4: Say which end is outside the service area

**Files:**
- Modify: `lib/viewmodels/home_viewmodel.dart:276-282` (`_composeSuggestions` NCR guard)

**Interfaces:**
- Produces: `HomeViewModel.guideUnavailableReason` — same field, unchanged type. `route_view.dart:447` already renders it verbatim, so no view change is needed.

- [ ] **Step 1: Distinguish the origin case from the destination case**

Replace lines 276-282 of `lib/viewmodels/home_viewmodel.dart` with:

```dart
    final originInNcr =
        RouteEngine.isWithinNcr(trip.originLat, trip.originLng);
    final destInNcr =
        RouteEngine.isWithinNcr(trip.destinationLat, trip.destinationLng);
    if (!originInNcr || !destInNcr) {
      // Name the end that is actually out of range. The old copy always blamed
      // the destination, so a rider starting in Bulacan and travelling INTO
      // Metro Manila — a very common commute — was told their destination was
      // unsupported when it was perfectly fine. Also lead with what still
      // works: the alarm is the product, the guide is the convenience.
      final which = !originInNcr && !destInNcr
          ? 'Your starting point and destination are'
          : !originInNcr
              ? 'Your starting point is'
              : 'Your destination is';
      guideUnavailableReason =
          '$which outside Metro Manila. Route and fare data cover NCR only, '
          'so there is no commute guide for this trip — but your destination '
          'alarm will still work normally.';
      return [];
    }
```

- [ ] **Step 2: Verify analyze + full regression**

Run: `flutter analyze`
Expected: `No issues found!`

Run: `flutter test`
Expected: `+165: All tests passed!`

`route_engine_test.dart` covers `isWithinNcr` and must be unaffected — the boundary logic is unchanged, only the message differs.

- [ ] **Step 3: Verify on device**

Run: `flutter run -d emulator-5554`

Set the emulator location to somewhere outside NCR (e.g. Baguio, `16.4023, 120.5960`), then search for a Metro Manila destination and open the route screen.

Expect: "Outside the service area" panel reading **"Your starting point is outside Metro Manila…"** and confirming the alarm still works.

- [ ] **Step 4: Commit**

```bash
git add lib/viewmodels/home_viewmodel.dart
git commit -m "fix: name which end of the trip is outside NCR

The out-of-service message always implied the destination was at fault,
so a rider starting outside NCR and travelling into Metro Manila was
misled. Now names the offending end and leads with the fact that the
destination alarm still works."
```

---

## Definition of done for Group A

- [ ] All four tasks committed.
- [ ] `flutter analyze` → `No issues found!`
- [ ] `flutter test` → `+165: All tests passed!`
- [ ] Every `CAPSTONE DEFENSE CRITICAL` block still present: verify with
      `grep -rc "CAPSTONE DEFENSE CRITICAL" lib/views/*.dart` → 10 total across 6 files.
- [ ] On-device pass of all four verification sections above.

**Not in this plan** — these are separate plans with their own gates:
- Group B: alarm optional / off by default (touches `TripViewModel`)
- Group C: SOS retry cadence, emergency trigger separation, lock-screen SOS action
