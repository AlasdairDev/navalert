import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navalert/core/theme.dart';
import 'package:navalert/models/guide_leg.dart';
import 'package:navalert/models/models.dart';
import 'package:navalert/services/database_service.dart';
import 'package:navalert/services/guide_progress.dart';
import 'package:navalert/services/home_widget_service.dart';
import 'package:navalert/services/sound_service.dart';
import 'package:navalert/services/trip_notification_service.dart';
import 'package:navalert/viewmodels/app_viewmodel.dart';
import 'package:navalert/viewmodels/emergency_viewmodel.dart';
import 'package:navalert/viewmodels/home_viewmodel.dart';
import 'package:navalert/viewmodels/trip_viewmodel.dart';
import 'package:navalert/views/active_trip_view.dart';
import 'package:navalert/views/commute_guide_sheet.dart';
import 'package:provider/provider.dart';

/// The commute guide must LAYER over the live map, not replace it.
///
/// commute_sheet_layout_test proves the arithmetic; this suite proves the
/// arithmetic is actually wired to the screen — that the map is really mounted
/// underneath, that the sheet really rests where the geometry says, and that the
/// safety controls really are outside its reach. Those are three different
/// failures (a correct calculation fed to nothing looks identical to a broken
/// one from the outside), so they are checked against the mounted widget tree
/// rather than the numbers.
///
/// EXPECTED CONSOLE NOISE: this suite mounts the REAL map, so the real
/// `CachedTileProvider` runs, and flutter_test's HttpClient answers every
/// request with 400 — one `DioException [bad response]` per tile. That output
/// is the tile layer failing to reach the network in a sandbox, not a failing
/// assertion, and it is worth keeping: it is the proof that the shared
/// NavAlertMap.tiles / TileCacheStore path is genuinely wired into this screen
/// rather than stubbed out for the test.
void main() {
  const screenW = 360.0;
  const screenH = 800.0;

  Trip buildTrip() => Trip(
        tripId: 'trip-overlay',
        originLabel: 'PUP Sta. Mesa',
        originLat: 14.5979,
        originLng: 121.0108,
        destinationLabel: 'SM North EDSA',
        destinationLat: 14.6560,
        destinationLng: 121.0300,
        alarmSound: 'Digital Clock',
        // The guide-first layout is the alarm-OFF case: the rider is using
        // NavAlert to navigate, not as an alarm clock.
        alarmEnabled: false,
      );

  List<GuideLeg> buildLegs() => [
        for (var i = 1; i <= 4; i++)
          GuideLeg(
            step: RouteStep(
              stepId: 'step-$i',
              suggestionId: 'sug',
              stepNumber: i,
              transportMode: i.isEven ? 'bus' : 'walk',
              instruction: 'Guide step number $i',
              fromStop: i.isEven ? 'Terminal $i' : null,
              durationMinutes: 10,
              farePhp: i.isEven ? 15 : 0,
            ),
            endLat: 14.60 + i / 100,
            endLng: 121.02,
          ),
      ];

  late TripViewModel trip;

  setUp(() {
    // The monitoring STATE is assembled directly rather than by calling
    // startTrip. This is a layout suite: it needs the screen the rider sees,
    // not the machinery behind it — and startTrip additionally arms the 15 s
    // Signal Lost watchdog, which flutter_test flags as a pending timer at the
    // end of every test (that check runs before tearDown, so it cannot be
    // cleaned up afterwards). trip_flow_test already drives the real
    // startTrip path end to end.
    trip = TripViewModel(
      db: _FakeDb(),
      sound: _FakeSound(),
      lockWidget: _FakeLockWidget(),
      homeWidget: _FakeHomeWidget(),
    )
      ..trip = buildTrip()
      ..phase = TripPhase.monitoring
      ..guide = GuideProgress(buildLegs())
      ..distanceM = 4200
      ..speedKmh = 18
      ..etaMinutes = 14;
  });

  tearDown(() => trip.dispose());

  Future<void> pumpGuide(WidgetTester t) async {
    t.view.physicalSize = const Size(screenW, screenH);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    await t.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<TripViewModel>.value(value: trip),
        ChangeNotifierProvider(create: (_) => HomeViewModel()),
        ChangeNotifierProvider(create: (_) => AppViewModel()),
        ChangeNotifierProvider(create: (_) => EmergencyViewModel()),
      ],
      child: MaterialApp(
        theme: buildNavAlertTheme(),
        home: const ActiveTripView(),
      ),
    ));
    // Two settles: the footer is MEASURED, so the sheet only appears on the
    // frame after its height is known.
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
  }

  /// The sheet's top edge in screen coordinates.
  double sheetTop(WidgetTester t) =>
      t.getTopLeft(find.byType(DraggableScrollableSheet).last).dy;

  /// The visible top edge of the sheet's own plate, which is what actually
  /// covers the map — DraggableScrollableSheet itself fills the whole region.
  double plateTop(WidgetTester t) => t
      .getTopLeft(find.descendant(
        of: find.byType(DraggableScrollableSheet),
        matching: find.byType(CommuteGuideSheet),
      ))
      .dy;

  testWidgets('the map is mounted underneath the guide', (t) async {
    await pumpGuide(t);

    // The whole point of the change. Before it, this screen had no map at all.
    expect(find.byType(FlutterMap), findsOneWidget);
    // And the guide is on screen at the same time — layered, not swapped.
    expect(find.byType(CommuteGuideSheet), findsOneWidget);
    expect(find.text('Guide step number 1'), findsOneWidget);
  });

  testWidgets('the map fills the screen behind the overlay', (t) async {
    await pumpGuide(t);

    final map = t.getRect(find.byType(FlutterMap));
    expect(map.width, closeTo(screenW, 0.5));
    expect(map.height, closeTo(screenH, 0.5),
        reason: 'the map must be full-bleed behind the header and footer '
            'plates, not letterboxed into the gap between them');
  });

  testWidgets('at rest the sheet leaves the top half of the map visible',
      (t) async {
    await pumpGuide(t);

    expect(plateTop(t), greaterThanOrEqualTo(screenH * 0.5),
        reason: 'the resting guide reaches above the halfway line — the map '
            'is no longer readable at a glance');
  });

  testWidgets('dragged fully up, the sheet still leaves a top margin',
      (t) async {
    await pumpGuide(t);

    await t.drag(find.byType(CommuteGuideSheet), const Offset(0, -screenH));
    await t.pumpAndSettle();

    final top = plateTop(t);
    expect(top, greaterThan(0),
        reason: 'the guide covered the entire screen — map context is 100% '
            'lost, which is the failure this layout exists to prevent');
    expect(top, greaterThanOrEqualTo(screenH * 0.15));
  });

  testWidgets('the sheet can never cover the safety controls', (t) async {
    await pumpGuide(t);

    final slider = t.getRect(find.text('Slide to Stop'));
    final sos = t.getRect(find.text('SOS'));

    // Fully extended is the worst case: if the sheet clears the controls here,
    // it clears them everywhere.
    await t.drag(find.byType(CommuteGuideSheet), const Offset(0, -screenH));
    await t.pumpAndSettle();

    final sheetBottom = t
        .getRect(find.descendant(
          of: find.byType(DraggableScrollableSheet),
          matching: find.byType(CommuteGuideSheet),
        ))
        .bottom;

    expect(sheetBottom, lessThanOrEqualTo(slider.top),
        reason: 'the guide sits on Slide-to-Stop — the only control that ends '
            'a trip, on a screen where Back is blocked by design');
    expect(sheetBottom, lessThanOrEqualTo(sos.top),
        reason: 'the guide sits on the SOS button');
  });

  testWidgets('the safety controls stay on screen at every drag height',
      (t) async {
    await pumpGuide(t);

    for (final drag in [0.0, -300.0, -screenH, 300.0]) {
      if (drag != 0) {
        await t.drag(find.byType(CommuteGuideSheet), Offset(0, drag));
        await t.pumpAndSettle();
      }
      expect(find.text('Slide to Stop'), findsOneWidget);
      expect(find.text('SOS'), findsOneWidget);
      expect(find.text('Fake Call'), findsOneWidget);
    }
  });

  testWidgets('the trip context stays readable above the map', (t) async {
    await pumpGuide(t);

    // The header replaces the moon badge as the "where am I" anchor, and the
    // readouts stay honest about distance even though the map now carries the
    // navigation.
    expect(find.text('En Route'), findsOneWidget);
    expect(find.text('SM North EDSA'), findsOneWidget);
    expect(find.text('Step 1 of 4'), findsOneWidget);
    expect(find.textContaining('km away'), findsOneWidget);
  });

  testWidgets('sheetTop is the full region, so the plate is what covers',
      (t) async {
    await pumpGuide(t);
    // Documents the distinction the assertions above rely on: the
    // DraggableScrollableSheet widget expands to its whole region, and only its
    // fractionally-sized child actually obscures the map.
    expect(sheetTop(t), lessThan(plateTop(t)));
  });

  testWidgets('the unobstructed map band is the real measure, not the sheet',
      (t) async {
    await pumpGuide(t);

    // The header plate covers map too. Checking only the sheet's top edge
    // would score this layout as "half the map visible" while the top tenth of
    // it sits under the trip-context header — so the band that is genuinely
    // free of chrome is measured end to end.
    final headerBottom = sheetTop(t);
    final band = plateTop(t) - headerBottom;

    expect(headerBottom, greaterThan(0));
    expect(band / screenH, greaterThanOrEqualTo(0.35),
        reason: 'less than a third of the screen is actually usable map at '
            'rest — the overlay has stopped earning the space it takes');
  });

  testWidgets('the last step can be scrolled clear of the footer seam',
      (t) async {
    await pumpGuide(t);

    // Expand the sheet, then keep dragging so the list itself scrolls to its
    // end. A DraggableScrollableSheet consumes the drag until it is fully
    // extended, so the second drag is the one that moves the list.
    await t.drag(find.byType(CommuteGuideSheet), const Offset(0, -screenH));
    await t.pumpAndSettle();
    await t.drag(find.byType(CommuteGuideSheet), const Offset(0, -screenH));
    await t.pumpAndSettle();

    final plate = t.getRect(find.descendant(
        of: find.byType(DraggableScrollableSheet),
        matching: find.byType(CommuteGuideSheet)));
    final lastCard = t.getRect(find
        .ancestor(
            of: find.text('Guide step number 4'), matching: find.byType(Card))
        .first);

    // The sheet's bottom edge is a hard clip against the safety footer. A card
    // that ends flush with it is guillotined mid-content, and because the
    // footer is a different colour the slice reads as the text sliding UNDER
    // the footer rather than as the end of a scroll.
    expect(lastCard.bottom, lessThanOrEqualTo(plate.bottom - 16),
        reason: 'the final step cannot be scrolled clear of the seam — it '
            'stays cut off against the footer no matter how far the rider '
            'scrolls');
  });

  // ── Arming the alarm must not take the tracking away ──────────────────
  //
  // Reported after v2.0.0: "the real time commuter tracking is not showing when
  // the alarm is enabled... the commute guide that shows real time tracking
  // cannot be seen anywhere."
  //
  // It was accurate. The monitoring screen picked its layout off
  // trip.alarmEnabled alone, so arming the alarm swapped the whole map-and-
  // guide layout out for the resting Figure 24 face and there was no way back
  // to it. The two features were mutually exclusive, which neither the
  // requirements nor the mockups ever asked for: Figure 24 is the screen for a
  // rider who is asleep, not the only screen a rider with an alarm may have.
  group('with the alarm armed', () {
    setUp(() => trip.trip!.alarmEnabled = true);

    testWidgets('the resting face opens first, and offers the way to the map',
        (t) async {
      await pumpGuide(t);

      // Figure 24, unchanged — this is still what an alarm-armed trip opens on.
      expect(find.text('Get some rest. We got you.'), findsOneWidget);
      expect(find.byType(FlutterMap), findsNothing);
      // ...but the tracking is now reachable, which is the whole report.
      expect(find.text('Live map'), findsOneWidget);
    });

    testWidgets('opening the live map keeps the alarm armed', (t) async {
      await pumpGuide(t);
      await t.tap(find.text('Live map'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));

      expect(find.byType(FlutterMap), findsOneWidget,
          reason: 'the tracking map is what the rider went looking for');
      expect(find.byType(CommuteGuideSheet), findsOneWidget);
      expect(find.text('Guide step number 1'), findsOneWidget);
      // The point of the fix: they did not have to give up the alarm for it.
      expect(trip.trip!.alarmEnabled, isTrue);
      expect(trip.showLiveTracking, isTrue);
    });

    testWidgets('the guide appears exactly once, never doubled', (t) async {
      await pumpGuide(t);
      await t.tap(find.text('Live map'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));

      // ActiveTripView stacks a collapsed guide sheet over the RESTING face.
      // If that condition ignored live tracking, the rider would get the
      // inline guide plus that sheet — two copies, the second sitting on the
      // safety controls.
      expect(find.byType(CommuteGuideSheet), findsOneWidget);
      expect(find.text('Guide step number 1'), findsOneWidget);
    });

    testWidgets('the moon button goes back to the resting face', (t) async {
      await pumpGuide(t);
      await t.tap(find.text('Live map'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));

      await t.tap(find.byTooltip('Back to the resting screen'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));

      expect(find.text('Get some rest. We got you.'), findsOneWidget);
      expect(find.byType(FlutterMap), findsNothing);
      expect(trip.trip!.alarmEnabled, isTrue);
    });

    testWidgets('the safety controls survive the switch', (t) async {
      await pumpGuide(t);
      await t.tap(find.text('Live map'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));

      expect(find.text('Slide to Stop'), findsOneWidget);
      expect(find.text('SOS'), findsOneWidget);
      expect(find.text('Fake Call'), findsOneWidget);
    });

    testWidgets('with the alarm OFF there is no moon button, because there is '
        'no resting face to return to', (t) async {
      trip.trip!.alarmEnabled = false;
      await pumpGuide(t);

      expect(find.byType(FlutterMap), findsOneWidget);
      expect(find.byTooltip('Back to the resting screen'), findsNothing);
    });
  });

  // ── One leg on the map, not the journey ───────────────────────────────
  //
  // Reported alongside the above: "after starting, the full preview is still
  // there and not yet segmented... it should not show the whole path to the
  // destination but only the path of the certain transport type."
  group('the map draws the leg the rider is on', () {
    // Three legs with visibly different geometry, so which one is drawn can be
    // read straight off the rendered polyline.
    List<GuideLeg> segmentedLegs() => [
          GuideLeg(
            step: RouteStep(
                stepId: 's1',
                suggestionId: 'sug',
                stepNumber: 1,
                transportMode: 'walk',
                instruction: 'Walk to Terminal'),
            startLat: 14.60,
            startLng: 121.00,
            endLat: 14.61,
            endLng: 121.01,
            path: const [
              [14.60, 121.00],
              [14.61, 121.01],
            ],
          ),
          GuideLeg(
            step: RouteStep(
                stepId: 's2',
                suggestionId: 'sug',
                stepNumber: 2,
                transportMode: 'jeepney',
                instruction: 'Ride jeepney "SOME ROUTE" and alight at Stop'),
            startLat: 14.61,
            startLng: 121.01,
            endLat: 14.64,
            endLng: 121.04,
            path: const [
              [14.61, 121.01],
              [14.62, 121.02],
              [14.63, 121.03],
              [14.64, 121.04],
            ],
          ),
          GuideLeg(
            step: RouteStep(
                stepId: 's3',
                suggestionId: 'sug',
                stepNumber: 3,
                transportMode: 'walk',
                instruction: 'Walk to SM North EDSA'),
            startLat: 14.64,
            startLng: 121.04,
            endLat: 14.6560,
            endLng: 121.0300,
            path: const [
              [14.64, 121.04],
              [14.6560, 121.0300],
            ],
          ),
        ];

    /// The route line actually rendered — the coloured stroke, not the white
    /// casing drawn beneath it.
    List<LatLng> drawnLine(WidgetTester t) {
      final layer = t.widget<PolylineLayer>(find.byType(PolylineLayer).first);
      return layer.polylines.last.points;
    }

    setUp(() => trip.guide = GuideProgress(segmentedLegs()));

    testWidgets('on step 1 it draws the walk, not the whole journey',
        (t) async {
      await pumpGuide(t);

      final line = drawnLine(t);
      expect(line, hasLength(2),
          reason: 'the walk to the terminal is a two-point line; anything '
              'longer means the ride was drawn along with it');
      expect(line.first.latitude, closeTo(14.60, 1e-9));
      expect(line.last.latitude, closeTo(14.61, 1e-9));
    });

    testWidgets('advancing to the ride swaps the line over', (t) async {
      await pumpGuide(t);
      trip.markGuideLegDone();
      await t.pump();

      final line = drawnLine(t);
      expect(line, hasLength(4), reason: 'the jeepney shape is now the line');
      expect(line.last.latitude, closeTo(14.64, 1e-9));
      expect(line.first.latitude, closeTo(14.61, 1e-9),
          reason: 'the line starts where the rider boards, not at the origin — '
              'the walk they already finished is no longer on the map');
    });

    testWidgets('a leg with no geometry still gets a line to head along',
        (t) async {
      // Synthetic suggestions have no shape for their fictional middle legs.
      // Drawing nothing would leave the rider on a bare basemap with no
      // indication of direction, which is worse than a visible approximation.
      trip.guide = GuideProgress([
        GuideLeg(
          step: RouteStep(
              stepId: 's1',
              suggestionId: 'sug',
              stepNumber: 1,
              transportMode: 'walk',
              instruction: 'Walk'),
          endLat: 14.61,
          endLng: 121.01,
        ),
      ]);
      await pumpGuide(t);

      expect(drawnLine(t), hasLength(2));
    });
  });
}

// ── Stub collaborators ────────────────────────────────────────────────────
// Same `implements` + noSuchMethod pattern as trip_flow_test: satisfy the
// concrete singleton's type while overriding only what TripViewModel calls.

class _FakeDb implements DatabaseService {
  @override
  Future<double?> averageAwakeSeconds({int lastN = 10}) async => null;
  @override
  Future<void> updateTrip(Trip t) async {}
  @override
  Future<void> insertAlarmEvent(AlarmEvent e) async {}
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _FakeSound implements SoundService {
  @override
  Future<void> playAlarmStage(int stage, String soundName,
      {bool vibrationOnly = false, bool highIntensity = false}) async {}
  @override
  Future<void> stopAll() async {}
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _FakeLockWidget implements TripNotificationService {
  @override
  VoidCallback? onEndTrip;
  @override
  Future<void> showTrip(
      {required String destination,
      required double distanceM,
      double? etaMinutes}) async {}
  @override
  Future<void> cancel() async {}
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _FakeHomeWidget implements HomeWidgetService {
  @override
  Future<void> showTrip(
      {required String destination,
      required double distanceM,
      double? etaMinutes,
      required String status}) async {}
  @override
  Future<void> showIdle() async {}
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

