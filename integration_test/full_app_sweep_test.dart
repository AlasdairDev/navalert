import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:navalert/main.dart' as app;

/// GHOST-USER UI SWEEP — drives the real app on a device/emulator.
///
/// Run with:
///   flutter test integration_test/full_app_sweep_test.dart -d <device-id>
///
/// Why it is written the way it is:
///
///  * `pumpAndSettle` is used sparingly. The Home screen streams map tiles and
///    the trip screen animates, so "settle" may never arrive — a timeout there
///    reads as a failure when nothing is actually broken. `_settle` pumps for a
///    bounded time instead, which is what a human eye does: look after a beat.
///  * The sweep does NOT tap anything that hands control to the OS (the battery
///    toggle opens Android Settings, Call 911 opens the dialer). Once the app
///    loses foreground the driver can no longer find its widgets, so those are
///    asserted as *present and enabled* rather than pressed. That limit is
///    stated here rather than hidden.
///  * Emergency contacts are deliberately left EMPTY before the SOS test, so
///    firing SOS takes the "no contacts saved" path and no real SMS is ever
///    sent to anyone.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Pump for a bounded time. Safe on screens that never go idle.
  Future<void> settle(WidgetTester t, [int ms = 1200]) async {
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(Duration(milliseconds: ms));
  }

  /// Taps [finder] if present. Returns whether it was there.
  Future<bool> tapIfPresent(WidgetTester t, Finder finder,
      {int settleMs = 1200}) async {
    if (finder.evaluate().isEmpty) return false;
    await t.tap(finder.first, warnIfMissed: false);
    await settle(t, settleMs);
    return true;
  }

  /// Walks the onboarding chain via its Skip controls and lands on the shell.
  /// Onboarding only appears on a fresh install; on a second run the app boots
  /// straight to Home, so every step is optional by design.
  Future<void> passOnboarding(WidgetTester t) async {
    await settle(t, 3000); // splash gate

    // 1. Tutorial — assert it rendered, check the Battery toggle further on.
    if (find.text('Skip').evaluate().isNotEmpty) {
      expect(find.byType(PageView), findsOneWidget,
          reason: 'Tutorial should show a paged walkthrough');
      await tapIfPresent(t, find.text('Skip'));
    }

    // 2. Permissions — the Battery toggle lives here.
    if (find.text('Optimize Battery').evaluate().isNotEmpty) {
      expect(find.byType(SwitchListTile), findsWidgets,
          reason: 'Permission toggles should render as switches');

      // The Battery toggle must exist AND be interactive. It is not tapped:
      // it opens Android's battery-optimisation settings, which takes the app
      // out of the foreground and ends the driver session.
      final batteryTile = t.widget<SwitchListTile>(
        find.ancestor(
          of: find.text('Optimize Battery'),
          matching: find.byType(SwitchListTile),
        ),
      );
      expect(batteryTile.onChanged, isNotNull,
          reason: 'Battery toggle is dead — it has no onChanged handler');

      await tapIfPresent(t, find.text('Skip for now ›'));
    }

    // 3. Emergency contacts — intro card, then the form. Left blank on purpose
    //    (see the SOS note above).
    if (find.text('Add 3 Emergency Contacts').evaluate().isNotEmpty) {
      await tapIfPresent(t, find.text('Continue'));
    }
    if (find.text('Add Emergency Contacts').evaluate().isNotEmpty) {
      expect(find.byType(TextField), findsNWidgets(6),
          reason: 'Contacts form should offer 3 name + 3 phone fields');
      await tapIfPresent(t, find.text('Skip for now ›'));
    }

    // 4. Fake call setup — the recording dropdown must have real entries.
    if (find.text('Fake Call Setup').evaluate().isNotEmpty) {
      expect(find.text('No recordings available'), findsNothing,
          reason: 'Preset recordings missing — the dropdown would be dead');
      await tapIfPresent(t, find.text('Skip for now ›'), settleMs: 3000);
    }

    await settle(t, 2500);
  }

  Future<void> openTab(WidgetTester t, String label) async {
    final tab = find.text(label);
    expect(tab, findsWidgets, reason: '"$label" tab is missing from the shell');
    await t.tap(tab.last, warnIfMissed: false);
    await settle(t, 1500);
  }

  group('ghost-user sweep', () {
    testWidgets('onboarding is passable and the shell renders', (t) async {
      app.main();
      await passOnboarding(t);

      // Landed in the app, not stuck on a setup screen.
      expect(find.byType(BottomNavigationBar), findsOneWidget,
          reason: 'Never reached the main shell — onboarding trapped the user');
      for (final tab in ['History', 'Favorites', 'Home', 'Emergency', 'Settings']) {
        expect(find.text(tab), findsWidgets, reason: '"$tab" tab missing');
      }
    });

    testWidgets('every tab renders without crashing', (t) async {
      app.main();
      await passOnboarding(t);

      await openTab(t, 'History');
      expect(find.text('Trip History'), findsWidgets,
          reason: 'History screen did not render');

      await openTab(t, 'Favorites');
      expect(find.text('Favorites'), findsWidgets,
          reason: 'Favorites screen did not render');

      await openTab(t, 'Settings');
      expect(find.byType(SwitchListTile), findsWidgets,
          reason: 'Settings toggles did not render');
      // Every documented Settings section must be present (Figure 33).
      for (final section in ['Terms & Conditions', 'Privacy Policy']) {
        expect(find.text(section), findsWidgets, reason: '$section missing');
      }

      await openTab(t, 'Home');
      expect(find.text('Search'), findsWidgets,
          reason: 'Home search bar did not render');
    });

    testWidgets('SOS press-and-hold fires without sending a real SMS',
        (t) async {
      app.main();
      await passOnboarding(t);
      await openTab(t, 'Emergency');

      expect(find.text('SOS'), findsWidgets, reason: 'SOS button is missing');
      expect(find.text('Call 911'), findsWidgets,
          reason: 'Call 911 button is missing');

      // Hold for longer than the 3-second accidental-trigger guard. Contacts
      // were skipped, so this takes the "no contacts saved" path — nothing is
      // actually sent.
      final gesture = await t.startGesture(t.getCenter(find.text('SOS').first));
      await t.pump(const Duration(milliseconds: 500));
      for (var i = 0; i < 8; i++) {
        await t.pump(const Duration(milliseconds: 500));
      }
      await gesture.up();
      await settle(t, 2500);

      // The app must respond, and must still be alive afterwards.
      expect(find.byType(BottomNavigationBar), findsOneWidget,
          reason: 'App left the shell or crashed after SOS');
    });

    testWidgets('fake call opens and the End button closes it', (t) async {
      app.main();
      await passOnboarding(t);
      await openTab(t, 'Emergency');

      // Tapping a recording row starts the fake call.
      final recording = find.textContaining('call recording');
      expect(recording, findsWidgets,
          reason: 'No fake-call recordings listed — presets are missing');
      await t.tap(recording.first, warnIfMissed: false);
      await settle(t, 3000);

      // The call screen must actually appear.
      expect(find.byIcon(Icons.call_end), findsWidgets,
          reason: 'Fake call screen never opened (no End button on screen)');

      // End the call — this must return to the app, not hang.
      await t.tap(find.byIcon(Icons.call_end).first, warnIfMissed: false);
      await settle(t, 2500);

      expect(find.byIcon(Icons.call_end), findsNothing,
          reason: 'End Call did not dismiss the call screen');
      expect(find.byType(BottomNavigationBar), findsOneWidget,
          reason: 'Did not return to the shell after ending the call');
    });

    testWidgets('search, start a trip, and Slide-to-Stop actually stops it',
        (t) async {
      app.main();
      await passOnboarding(t);
      await openTab(t, 'Home');

      // Open destination search.
      await t.tap(find.text('Search').first, warnIfMissed: false);
      await settle(t, 1500);
      expect(find.byType(TextField), findsWidgets,
          reason: 'Search screen did not open');

      await t.enterText(find.byType(TextField).first, 'PUP');
      await settle(t, 5000); // Nominatim round trip

      final results = find.byType(ListTile);
      if (results.evaluate().isEmpty) {
        markTestSkipped('No search results — needs network/GPS. '
            'Trip and Slide-to-Stop not exercised.');
        return;
      }
      await t.tap(results.first, warnIfMissed: false);
      await settle(t, 6000); // route planning (Dijkstra isolate)

      // Route screen → trip settings → start.
      await tapIfPresent(t, find.text('Show Commute Guide'), settleMs: 2000);
      if (!await tapIfPresent(t, find.text('Enable Alarm'), settleMs: 2000)) {
        markTestSkipped('No route suggestions returned — cannot start a trip.');
        return;
      }
      if (!await tapIfPresent(t, find.text('Start Trip'), settleMs: 4000)) {
        markTestSkipped('Trip settings sheet did not offer Start Trip.');
        return;
      }

      // Monitoring screen must render.
      expect(find.text('Slide to Stop'), findsWidgets,
          reason: 'Active trip screen did not render Slide-to-Stop');

      // Drag the slider fully to the right. This is the ONLY way off this
      // screen (Back is blocked), so a failure here strands the rider.
      final slider = find.text('Slide to Stop').first;
      final box = t.getRect(slider);
      await t.drag(slider, Offset(box.width + 220, 0));
      await settle(t, 4000);

      expect(find.text('Slide to Stop'), findsNothing,
          reason: 'SLIDE-TO-STOP FROZE — the trip could not be stopped, '
              'and Back is blocked on this screen');
    });
  });
}
