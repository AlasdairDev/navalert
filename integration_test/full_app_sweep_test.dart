import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:navalert/main.dart' as app;
import 'package:navalert/views/settings_view.dart';

/// GHOST-USER UI SWEEP — drives the real app on a device/emulator.
///
/// Run with:
///   flutter test integration_test/full_app_sweep_test.dart -d <device-id>
///
/// Why it is written the way it is:
///
///  * `pumpAndSettle` is used nowhere. The Home screen streams map tiles and
///    the trip screen animates, so "settle" may never arrive — a timeout there
///    reads as a failure when nothing is actually broken. Instead every wait is
///    a `waitFor`, which polls until the thing appears or a deadline passes.
///    That survives a slow network without padding the run with fixed sleeps.
///
///  * Tab assertions use `.hitTestable()`. The shell is an IndexedStack, so all
///    five tabs are in the widget tree at all times — a bare `find.text` matches
///    a screen that is not on screen, which would pass no matter what. Only the
///    painted tab answers a hit test, so `.hitTestable()` is what actually
///    proves a screen is visible.
///
///  * The sweep does NOT tap anything that hands control to the OS (the battery
///    toggle opens Android Settings, Call 911 opens the dialer). Once the app
///    loses foreground the driver can no longer find its widgets, so those are
///    asserted as *present and live* rather than pressed. That limit is stated
///    here rather than hidden.
///
///  * Emergency contacts are deliberately left EMPTY before the SOS test, so
///    firing SOS takes the "no contacts saved" path and no real SMS is ever
///    sent to anyone.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // ───────────────────────────── helpers ─────────────────────────────

  /// Pump for a bounded time. Safe on screens that never go idle.
  Future<void> settle(WidgetTester t, [int ms = 800]) async {
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(Duration(milliseconds: ms));
  }

  /// Pumps until [finder] matches or [timeout] elapses. Returns whether it
  /// showed up. This replaces fixed sleeps: a fast device moves on immediately,
  /// a slow network still gets its full budget.
  Future<bool> waitFor(WidgetTester t, Finder finder,
      {Duration timeout = const Duration(seconds: 10)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await t.pump(const Duration(milliseconds: 200));
      if (finder.evaluate().isNotEmpty) return true;
    }
    return finder.evaluate().isNotEmpty;
  }

  /// Pumps until [finder] matches NOTHING, or [timeout] elapses.
  ///
  /// The inverse of [waitFor], and not interchangeable with it: `!waitFor(...)`
  /// returns the moment the widget is STILL present, so it reports "never went
  /// away" against a screen that simply has not finished tearing down yet.
  /// Stopping a trip writes to the database and tears down the notification and
  /// the GPS stream, which is comfortably slower than one pump.
  Future<bool> waitForAbsent(WidgetTester t, Finder finder,
      {Duration timeout = const Duration(seconds: 15)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await t.pump(const Duration(milliseconds: 200));
      if (finder.evaluate().isEmpty) return true;
    }
    return finder.evaluate().isEmpty;
  }

  /// Fails the test if the framework raised anything while [screen] was up —
  /// this is what catches a RenderFlex overflow ("BOTTOM OVERFLOWED BY N
  /// PIXELS") or a build-time crash, and names the screen that caused it.
  void expectNoRenderErrors(WidgetTester t, String screen) {
    final error = t.takeException();
    expect(error, isNull,
        reason: 'RENDER ERROR ON "$screen" (overflow or crash): $error');
  }

  /// Drags [scrollable] upward in steps until [finder] appears.
  ///
  /// Needed because Settings is a lazy `ListView`: a section below the fold is
  /// genuinely not in the widget tree until it is scrolled to, so asserting on
  /// it directly fails even when the screen is perfectly healthy. `tester
  /// .scrollUntilVisible` is unusable here — it calls `pumpAndSettle`, and the
  /// Home tab's map keeps scheduling frames behind the IndexedStack, so settle
  /// never arrives.
  Future<bool> scrollTo(WidgetTester t, Finder finder, Finder scrollable,
      {int maxDrags = 12}) async {
    for (var i = 0; i < maxDrags; i++) {
      if (finder.evaluate().isNotEmpty) return true;
      await t.drag(scrollable, const Offset(0, -260), warnIfMissed: false);
      await t.pump(const Duration(milliseconds: 400));
    }
    return finder.evaluate().isNotEmpty;
  }

  /// Discards exceptions left over from the PREVIOUS test's teardown.
  ///
  /// Every test restarts the app with `app.main()`, so the old widget tree is
  /// finalized while this one is starting — and a SnackBar still animating on
  /// the way out throws as its ScaffoldMessenger deactivates. Those belong to
  /// the test that created them, not this one; without this drain they get
  /// misattributed to whatever screen this test checks first. Everything
  /// discarded is printed, so nothing is hidden.
  void drainStaleErrors(WidgetTester t) {
    for (var i = 0; i < 10; i++) {
      final e = t.takeException();
      if (e == null) return;
      debugPrint('NavAlert sweep: discarded stale teardown error — $e');
    }
  }

  /// Every piece of text currently painted on screen, for failure messages.
  /// Without this a "screen never opened" failure says nothing about where the
  /// ghost user actually ended up.
  String onScreenText(WidgetTester t) {
    final seen = <String>[];
    for (final e in find.byType(Text).hitTestable().evaluate()) {
      final data = (e.widget as Text).data?.trim();
      if (data != null && data.isNotEmpty && !seen.contains(data)) {
        seen.add(data);
      }
    }
    final spinner = find.byType(CircularProgressIndicator).evaluate().length;
    return '[spinners: $spinner] ${seen.take(30).join(' | ')}';
  }

  /// Taps [finder] if present. Returns whether it was there.
  Future<bool> tapIfPresent(WidgetTester t, Finder finder,
      {int settleMs = 900}) async {
    if (finder.evaluate().isEmpty) return false;
    await t.tap(finder.first, warnIfMissed: false);
    await settle(t, settleMs);
    return true;
  }

  /// Walks the onboarding chain via its Skip controls and lands on the shell.
  /// Onboarding only appears on a fresh install; on a second run the app boots
  /// straight to Home, so every step is optional by design.
  Future<void> passOnboarding(WidgetTester t) async {
    // Splash gate: LaunchView waits for the DB, min 1.4 s, hard cap 12 s.
    await waitFor(
        t,
        find.byWidgetPredicate(
            (w) => w is PageView || w is BottomNavigationBar),
        timeout: const Duration(seconds: 20));

    // 1. Tutorial — assert it rendered, then skip.
    if (find.text('Skip').evaluate().isNotEmpty) {
      expect(find.byType(PageView), findsOneWidget,
          reason: 'Tutorial should show a paged walkthrough');
      expectNoRenderErrors(t, 'Tutorial');
      await tapIfPresent(t, find.text('Skip'));
    }

    // 2. Permissions — the Battery toggle lives here.
    if (await waitFor(t, find.text('Optimize Battery'),
        timeout: const Duration(seconds: 4))) {
      expect(find.byType(SwitchListTile), findsNWidgets(4),
          reason: 'All four permission toggles should render as switches');

      // The Battery toggle must exist AND be live. It is deliberately NOT
      // tapped: it opens Android's battery-optimisation settings page, which
      // takes the app out of the foreground and ends the driver session. So we
      // assert the handler is wired instead — that is what "dead button" means.
      final batteryTile = t.widget<SwitchListTile>(
        find.ancestor(
          of: find.text('Optimize Battery'),
          matching: find.byType(SwitchListTile),
        ),
      );
      expect(batteryTile.onChanged, isNotNull,
          reason: 'Battery toggle is DEAD — it has no onChanged handler');

      expectNoRenderErrors(t, 'Permissions');
      await tapIfPresent(t, find.text('Skip for now ›'));
    }

    // 3. Emergency contacts — intro card, then the form. Left blank on purpose
    //    (see the SOS note at the top).
    if (await waitFor(t, find.text('Add 3 Emergency Contacts'),
        timeout: const Duration(seconds: 4))) {
      await tapIfPresent(t, find.text('Continue'));
    }
    if (find.text('Add Emergency Contacts').evaluate().isNotEmpty) {
      expect(find.byType(TextField), findsNWidgets(6),
          reason: 'Contacts form should offer 3 name + 3 phone fields');
      expectNoRenderErrors(t, 'Emergency Contacts setup');
      await tapIfPresent(t, find.text('Skip for now ›'));
    }

    // 4. Fake call setup — the recording dropdown must have real entries, or
    //    the rider reaches the app with no fake call available at all.
    if (await waitFor(t, find.text('Fake Call Setup'),
        timeout: const Duration(seconds: 4))) {
      expect(find.text('No recordings available'), findsNothing,
          reason: 'Preset recordings missing — the dropdown is dead');
      expectNoRenderErrors(t, 'Fake Call setup');
      await tapIfPresent(t, find.text('Skip for now ›'), settleMs: 2000);
    }

    // Landed in the app, not stuck on a setup screen.
    final reachedShell = await waitFor(t, find.byType(BottomNavigationBar),
        timeout: const Duration(seconds: 15));
    expect(reachedShell, isTrue,
        reason: 'NEVER REACHED THE MAIN SHELL — onboarding trapped the user');
    await settle(t, 1200);
    drainStaleErrors(t);
  }

  /// Switches tabs and waits for that tab to actually be the painted one.
  Future<void> openTab(WidgetTester t, String label) async {
    final tab = find.text(label);
    expect(tab, findsWidgets, reason: '"$label" tab is missing from the shell');
    await t.tap(tab.last, warnIfMissed: false);
    await settle(t, 1200);
  }

  // ───────────────────────────── the sweep ─────────────────────────────

  group('ghost-user sweep', () {
    testWidgets('onboarding is passable and the shell renders', (t) async {
      app.main();
      await passOnboarding(t);

      for (final tab in [
        'History',
        'Favorites',
        'Home',
        'Emergency',
        'Settings'
      ]) {
        expect(find.text(tab), findsWidgets, reason: '"$tab" tab missing');
      }
      expectNoRenderErrors(t, 'Shell');
    });

    testWidgets('every tab renders on screen without overflowing', (t) async {
      app.main();
      await passOnboarding(t);

      // `.hitTestable()` matters here — see the note at the top of the file.
      await openTab(t, 'History');
      expect(find.text('Trip History').hitTestable(), findsOneWidget,
          reason: 'History screen did not become visible');
      expectNoRenderErrors(t, 'History');

      await openTab(t, 'Favorites');
      expect(find.widgetWithText(AppBar, 'Favorites').hitTestable(),
          findsOneWidget,
          reason: 'Favorites screen did not become visible');
      expectNoRenderErrors(t, 'Favorites');

      await openTab(t, 'Settings');
      expect(find.widgetWithText(AppBar, 'Settings').hitTestable(),
          findsOneWidget,
          reason: 'Settings screen did not become visible');
      expect(find.byType(SwitchListTile), findsWidgets,
          reason: 'Settings toggles did not render');
      // Every documented Settings section must be present (Figure 33). The
      // body is a lazy ListView, so these have to be scrolled to — they are not
      // built until they come into view.
      final settingsList = find
          .descendant(
              of: find.byType(SettingsView), matching: find.byType(Scrollable))
          .first;
      for (final section in ['Terms & Conditions', 'Privacy Policy']) {
        expect(await scrollTo(t, find.text(section), settingsList), isTrue,
            reason: '$section is missing from Settings');
      }
      expectNoRenderErrors(t, 'Settings');

      await openTab(t, 'Emergency');
      expect(find.text('SOS').hitTestable(), findsOneWidget,
          reason: 'Emergency screen did not become visible');
      expectNoRenderErrors(t, 'Emergency');

      await openTab(t, 'Home');
      expect(find.text('Where are you headed?').hitTestable(), findsOneWidget,
          reason: 'Home screen did not become visible');
      expect(find.text('Search'), findsWidgets,
          reason: 'Home search bar did not render');
      expectNoRenderErrors(t, 'Home');
    });

    testWidgets('SOS press-and-hold fires without sending a real SMS',
        (t) async {
      app.main();
      await passOnboarding(t);
      await openTab(t, 'Emergency');

      expect(find.text('SOS'), findsWidgets, reason: 'SOS button is missing');
      expect(find.text('Press & Hold to Activate'), findsOneWidget,
          reason: 'SOS hold hint is missing');

      // Call 911 is asserted, not pressed — it launches the system dialer and
      // would end the driver session.
      expect(find.text('Call 911'), findsWidgets,
          reason: 'Call 911 button is missing');
      expect(
          t
              .widget<TextButton>(find.ancestor(
                  of: find.text('Call 911'), matching: find.byType(TextButton)))
              .onPressed,
          isNotNull,
          reason: 'Call 911 is DEAD — it has no onPressed handler');

      // Hold past the 3-second accidental-trigger guard (the hold timer ticks
      // every 100 ms and needs 30 ticks). Contacts were skipped, so this takes
      // the "no contacts saved" path — nothing is actually sent.
      final gesture = await t.startGesture(t.getCenter(find.text('SOS').first));
      for (var i = 0; i < 45; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      await gesture.up();
      await settle(t, 2000);

      // The app must respond, and must still be alive afterwards.
      expect(find.byType(BottomNavigationBar), findsOneWidget,
          reason: 'App left the shell or crashed after SOS');
      expectNoRenderErrors(t, 'Emergency (after SOS)');
    });

    testWidgets('fake call opens and the End button closes it', (t) async {
      app.main();
      await passOnboarding(t);
      await openTab(t, 'Emergency');

      // Tapping a recording row starts the fake call. The presets are seeded as
      // "Mom call recording" / "Dad call recording".
      final recording = find.textContaining('call recording');
      expect(recording, findsWidgets,
          reason: 'No fake-call recordings listed — presets are missing');
      await t.tap(recording.first, warnIfMissed: false);

      // The call screen must actually appear.
      final ended = await waitFor(t, find.byIcon(Icons.call_end),
          timeout: const Duration(seconds: 10));
      expect(ended, isTrue,
          reason: 'Fake call screen never opened (no End button on screen)');
      expect(find.text('Incoming call'), findsOneWidget,
          reason: 'Fake call does not read as a real incoming call');
      expectNoRenderErrors(t, 'Fake Call');

      // End the call — this must return to the app, not hang.
      await t.tap(find.byIcon(Icons.call_end).first, warnIfMissed: false);

      // Same race as Slide-to-Stop: the screen pops first but the native
      // teardown (audio, lock-screen window) runs after, so poll for absence
      // rather than asserting on the very next frame.
      final dismissed = await waitForAbsent(t, find.byIcon(Icons.call_end),
          timeout: const Duration(seconds: 10));
      expect(dismissed, isTrue,
          reason: 'END CALL DID NOT DISMISS the call screen');
      expect(find.byType(BottomNavigationBar), findsOneWidget,
          reason: 'Did not return to the shell after ending the call');
      expectNoRenderErrors(t, 'Shell (after fake call)');
    });

    testWidgets('search, start a trip, and Slide-to-Stop actually stops it',
        (t) async {
      app.main();
      await passOnboarding(t);
      await openTab(t, 'Home');

      // ── Open destination search ──────────────────────────────────────
      await t.tap(find.text('Search').first, warnIfMissed: false);
      await settle(t, 1200);
      expect(find.widgetWithText(AppBar, 'Where to?'), findsOneWidget,
          reason: 'Search screen did not open');
      expectNoRenderErrors(t, 'Search');

      // The field debounces 600 ms and needs >= 3 characters.
      await t.enterText(find.byType(TextField).first, 'PUP');

      // Match on the navigation avatar, NOT on ListTile. The "Pin on the map"
      // card is also a ListTile and is on screen from the moment the search
      // opens — matching ListTile alone "finds results" that do not exist, and
      // then taps the pin card, which opens the map picker instead of a route.
      final resultRow = find.ancestor(
          of: find.byIcon(Icons.navigation), matching: find.byType(ListTile));
      final gotResults = await waitFor(t, resultRow,
          timeout: const Duration(seconds: 25)); // Nominatim round trip

      if (!gotResults) {
        final why = find.textContaining('No results').evaluate().isNotEmpty
            ? 'Nominatim returned nothing for "PUP"'
            : find.textContaining('Network error').evaluate().isNotEmpty
                ? 'the device has no internet'
                : 'the search never came back';
        markTestSkipped('No destination results — $why. The trip and '
            'Slide-to-Stop paths were NOT exercised.');
        return;
      }

      await t.tap(resultRow.first, warnIfMissed: false);

      // ── Route screen ─────────────────────────────────────────────────
      final onRoute = await waitFor(t, find.widgetWithText(AppBar, 'Hello, there!'),
          timeout: const Duration(seconds: 30)); // Dijkstra isolate
      expect(onRoute, isTrue,
          reason: 'Route screen never opened after picking a destination. '
              'On screen instead: ${onScreenText(t)}');
      await settle(t, 2000);
      expectNoRenderErrors(t, 'Route');

      if (find.text('Outside the service area').evaluate().isNotEmpty) {
        markTestSkipped('Destination resolved outside NCR — there are no route '
            'suggestions, so no trip can be started. Trip and Slide-to-Stop '
            'were NOT exercised.');
        return;
      }

      // A route suggestion MUST be selected first: "Show Commute Guide" is
      // disabled (onPressed: null) until home.selectedSuggestion is set, so
      // tapping it before selecting silently does nothing.
      final suggestion = find.textContaining('total');
      if (suggestion.evaluate().isEmpty) {
        markTestSkipped('No route suggestions returned — cannot start a trip.');
        return;
      }
      await t.tap(suggestion.first, warnIfMissed: false);
      await settle(t, 1200);

      final guideButton = find.widgetWithText(ElevatedButton, 'Show Commute Guide');
      expect(
          t.widget<ElevatedButton>(guideButton).onPressed, isNotNull,
          reason: 'Show Commute Guide stayed DISABLED after selecting a route '
              'suggestion — the selection did not register');
      await t.tap(guideButton, warnIfMissed: false);
      await settle(t, 1200);

      expect(find.text('Step-by-Step Commute Guide'), findsOneWidget,
          reason: 'Commute guide did not open');
      expectNoRenderErrors(t, 'Commute Guide');

      // ── Trip settings sheet → start ──────────────────────────────────
      // The guide's primary action is "Start Trip", not "Enable Alarm": the
      // commute guide is the feature being started, and the destination alarm
      // is one optional switch inside the sheet this opens (off by default).
      await t.tap(find.text('Start Trip'), warnIfMissed: false);
      final sheet = await waitFor(t, find.text('Trip Settings'),
          timeout: const Duration(seconds: 8));
      expect(sheet, isTrue, reason: 'Trip Settings sheet did not open');
      expectNoRenderErrors(t, 'Trip Settings');

      // Both the guide footer and the sheet's confirm button now read "Start
      // Trip", and the guide is still mounted behind the modal — so a bare
      // find.text would match two widgets and throw. The sheet's route is
      // pushed last, so its button is the last match in the tree.
      await t.tap(find.text('Start Trip').last, warnIfMissed: false);

      // ── Monitoring screen ────────────────────────────────────────────
      final started = await waitFor(t, find.text('Slide to Stop'),
          timeout: const Duration(seconds: 20));
      expect(started, isTrue,
          reason: 'Active trip screen did not render Slide-to-Stop');
      expect(find.text('En Route'), findsOneWidget,
          reason: 'Monitoring screen did not render');
      expectNoRenderErrors(t, 'Active Trip (monitoring)');

      // ── Drag the slider ──────────────────────────────────────────────
      // The trip is started with the destination alarm OFF (it is opt-in), so
      // this lands on the GUIDE-FIRST monitoring layout: the commute guide
      // fills the body, with "En Route", the readouts strip and Slide-to-Stop
      // around it. Both layouts carry the same two anchors asserted above.
      //
      // Sliding is still the only way to END the trip. The back arrow added to
      // this screen leaves the trip RUNNING (it just pops the route), and the
      // system Back gesture is still blocked by the PopScope — so a failure
      // here means the trip cannot be stopped at all.
      //
      // The control tracks the finger's ABSOLUTE localPosition inside the pill
      // and completes at 60% of travel, so the drag must start near the pill's
      // left edge and run to its right edge. Stepped moves, not one jump, so
      // the horizontal drag recognizer wins the gesture arena the way a real
      // thumb makes it.
      final pill = find.ancestor(
        of: find.text('Slide to Stop'),
        matching: find.byType(GestureDetector),
      );
      final box = t.getRect(pill.first);
      final startPoint = Offset(box.left + 28, box.center.dy);
      final endX = box.right - 6;

      final drag = await t.startGesture(startPoint);
      await t.pump(const Duration(milliseconds: 60));
      const steps = 14;
      final stepX = (endX - startPoint.dx) / steps;
      for (var i = 0; i < steps; i++) {
        await drag.moveBy(Offset(stepX, 0));
        await t.pump(const Duration(milliseconds: 30));
      }
      await drag.up();
      await settle(t, 3000);

      final stopped = await waitForAbsent(t, find.text('Slide to Stop'),
          timeout: const Duration(seconds: 20));
      expect(stopped, isTrue,
          reason: 'SLIDE-TO-STOP FROZE — the trip could not be ended. The back '
              'arrow only leaves the screen with the trip still running, so '
              'this gesture is the rider\'s only way to actually stop it');
      expect(find.byType(BottomNavigationBar), findsOneWidget,
          reason: 'Did not return to the shell after stopping the trip');
      expectNoRenderErrors(t, 'Shell (after trip)');
    });
  });
}
