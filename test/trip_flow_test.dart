import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:navalert/models/guide_leg.dart';
import 'package:navalert/models/models.dart';
import 'package:navalert/services/database_service.dart';
import 'package:navalert/services/home_widget_service.dart';
import 'package:navalert/services/sound_service.dart';
import 'package:navalert/services/trip_notification_service.dart';
import 'package:navalert/viewmodels/trip_viewmodel.dart';

/// Full trip-flow simulation (UC-5 Handle Proximity Alarm, UC-6 Handle
/// Overshoot Event, UC-1 Exception 2 Signal Lost).
///
/// The adaptive-alarm *arithmetic* is pinned down in
/// adaptive_alarm_engine_test.dart; this suite drives the whole [TripViewModel]
/// state machine end-to-end from a **mock GPS stream**, with the DB / audio /
/// notification / widget collaborators stubbed, so the phase transitions, the
/// escalation timers, snooze re-fire, overshoot latch and signal-lost watchdog
/// are all exercised headlessly — no device, no database, no sound hardware.
void main() {
  // Destination: a fixed point in Manila. Positions are placed a known number of
  // metres due north so distance-to-destination is controllable to the metre.
  const destLat = 14.5995;
  const destLng = 120.9842;
  const metresPerDegLat = 111320.0;

  /// A mock fix [metresNorth] of the destination, reporting [speed] m/s.
  Position fixAt(double metresNorth, {double speed = 5.0}) => Position(
        latitude: destLat + metresNorth / metresPerDegLat,
        longitude: destLng,
        timestamp: DateTime.now(),
        accuracy: 5,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: speed,
        speedAccuracy: 0,
      );

  Trip buildTrip() => Trip(
        tripId: 'trip-test',
        originLabel: 'Origin',
        // ~2 km north of the destination.
        originLat: destLat + 2000 / metresPerDegLat,
        originLng: destLng,
        destinationLabel: 'PUP Sta. Mesa',
        destinationLat: destLat,
        destinationLng: destLng,
        alarmSound: 'Digital Clock',
      );

  RouteStep step(String mode, int n) => RouteStep(
        stepId: 'step-$n',
        suggestionId: 'sug',
        stepNumber: n,
        transportMode: mode,
        instruction: '$mode leg $n',
      );

  /// A GTFS-matched guide leg that alights [metresNorth] of the destination
  /// (auto-advances once the rider comes within 150 m of it).
  GuideLeg gtfsLeg(String mode, double metresNorth, int n) => GuideLeg(
        step: step(mode, n),
        endLat: destLat + metresNorth / metresPerDegLat,
        endLng: destLng,
      );

  late _FakeDb db;
  late _FakeSound sound;
  late _FakeLockWidget lock;
  late _FakeHomeWidget home;
  late StreamController<Position> gps;

  setUp(() {
    db = _FakeDb();
    sound = _FakeSound();
    lock = _FakeLockWidget();
    home = _FakeHomeWidget();
    // Broadcast so a re-started trip can attach a fresh listener after the
    // previous subscription is torn down (a single-sub stream can't relisten),
    // which also lets the leak test prove only ONE listener stays active.
    gps = StreamController<Position>.broadcast();
  });

  TripViewModel newVm() => TripViewModel(
        db: db,
        sound: sound,
        lockWidget: lock,
        homeWidget: home,
        positionStreamFactory: (_) => gps.stream,
      );

  group('UC-5 — proximity alarm escalates by distance', () {
    test('a vehicle closing on the stop drives Stage 1 → 2, never straight to 3',
        () async {
      final vm = newVm();
      await vm.startTrip(buildTrip());
      expect(vm.phase, TripPhase.monitoring);

      // 5 m/s → Stage-1 radius 1200 m, Stage-2 600 m, arrival radius 150 m.
      gps.add(fixAt(1000));
      await pumpEventQueue();
      expect(vm.phase, TripPhase.alarmStage1);

      gps.add(fixAt(500));
      await pumpEventQueue();
      expect(vm.phase, TripPhase.alarmStage2);

      // Figure 28: Stage 3 activates when the commuter "remains unresponsive
      // after Stage 2, or upon the third snooze" — it has NO distance trigger.
      // Closing further must not skip the escalation and slam straight into the
      // full-screen alarm.
      gps.add(fixAt(200));
      await pumpEventQueue();
      expect(vm.phase, TripPhase.alarmStage2);

      // Each stage was actually sounded, once, in order.
      expect(sound.stagesPlayed, [1, 2]);
      // Every stage was logged to history with its distance.
      expect(db.alarmEvents.map((e) => e.stage), [1, 2]);

      await vm.stopTrip();
      vm.dispose();
    });

    test('a first fix already past the Stage-2 radius still opens at Stage 1',
        () async {
      final vm = newVm();
      await vm.startTrip(buildTrip());

      // Destination set late, or the first fix only landed after boarding: the
      // commuter is already deep inside the Stage-2 radius. The gentle alert
      // must still be the one that plays first.
      gps.add(fixAt(300));
      await pumpEventQueue();

      expect(vm.phase, TripPhase.alarmStage1);
      expect(sound.stagesPlayed, [1]);

      await vm.stopTrip();
      vm.dispose();
    });

    test('a far-away fix never raises an alarm', () async {
      final vm = newVm();
      await vm.startTrip(buildTrip());

      gps.add(fixAt(3000)); // well beyond the 1200 m lead radius
      await pumpEventQueue();

      expect(vm.phase, TripPhase.monitoring);
      expect(sound.stagesPlayed, isEmpty);

      await vm.stopTrip();
      vm.dispose();
    });

    test('the same stage is not re-fired on subsequent fixes', () async {
      final vm = newVm();
      await vm.startTrip(buildTrip());

      gps.add(fixAt(1000));
      await pumpEventQueue();
      gps.add(fixAt(900)); // still inside Stage 1, not yet Stage 2
      await pumpEventQueue();

      expect(vm.phase, TripPhase.alarmStage1);
      expect(sound.stagesPlayed, [1], reason: 'Stage 1 fires exactly once');

      await vm.stopTrip();
      vm.dispose();
    });
  });

  group('UC-5 — dismiss / snooze / live readouts', () {
    test('dismissing Stage 3 ends the trip as arrived and records reaction',
        () async {
      final vm = newVm();
      await vm.startTrip(buildTrip());

      // Stage 3 is no longer reachable by distance alone (Figure 28), so climb
      // the escalation the way an unresponsive commuter actually would.
      gps.add(fixAt(1000));
      await pumpEventQueue();
      expect(vm.phase, TripPhase.alarmStage1);

      gps.add(fixAt(500));
      await pumpEventQueue();
      expect(vm.phase, TripPhase.alarmStage2);

      // Third snooze escalates straight to Stage 3.
      await vm.snoozeAlarm();
      await vm.snoozeAlarm();
      await vm.snoozeAlarm();
      expect(vm.phase, TripPhase.alarmStage3);

      await vm.dismissAlarm();

      expect(vm.phase, TripPhase.arrived);
      expect(sound.stopAllCount, greaterThan(0));
      expect(db.dismissed, isNotEmpty, reason: 'alarm marked dismissed');
      expect(db.lastTrip?.status, 'arrived');
      expect(home.idleCount, greaterThan(0), reason: 'widget reset to idle');
      expect(lock.cancelCount, greaterThan(0));

      vm.dispose();
    });

    test('reaching the destination auto-completes the trip as arrived',
        () async {
      final vm = newVm();
      await vm.startTrip(buildTrip());

      // Inside the 150 m arrival radius while still monitoring: the commuter is
      // following the trip and has plainly arrived, so the trip completes
      // itself instead of running on until the overshoot detector latches.
      gps.add(fixAt(100));
      await pumpEventQueue();

      expect(vm.phase, TripPhase.arrived);
      expect(db.lastTrip?.status, 'arrived');
      expect(vm.overshotM, 0, reason: 'arriving is not overshooting');

      vm.dispose();
    });

    test('distance, ETA and both widgets update on every fix', () async {
      final vm = newVm();
      await vm.startTrip(buildTrip());

      gps.add(fixAt(600));
      await pumpEventQueue();

      expect(vm.distanceM, closeTo(600, 1.0));
      expect(vm.etaMinutes, isNotNull);
      expect(vm.speedKmh, closeTo(18, 0.5)); // 5 m/s
      expect(lock.distancesShown, isNotEmpty);
      expect(home.statuses, contains('Approaching stop'));

      await vm.stopTrip();
      vm.dispose();
    });
  });

  group('UC-6 — overshoot detection from a mock track', () {
    test('sleeping past the stop latches the overshoot prompt', () async {
      final vm = newVm();
      await vm.startTrip(buildTrip());

      // Approach, reach closest point, then sail past with rising distance.
      for (final m in [900.0, 400.0, 120.0, 200.0, 300.0, 450.0]) {
        gps.add(fixAt(m));
        await pumpEventQueue();
      }

      expect(vm.phase, TripPhase.overshootPrompt);
      expect(vm.overshotM, greaterThan(0));

      // Confirming the miss records the event and ends the trip.
      await vm.answerOvershoot(true);
      expect(vm.phase, TripPhase.overshootConfirmed);
      expect(db.overshoots, isNotEmpty);
      expect(db.lastTrip?.status, 'overshot');

      vm.dispose();
    });

    // Same trap as Slide-to-Stop: the audit write sat between the phase change
    // and _endTrip, so a storage failure made "Yes" appear to do nothing and
    // stranded the rider on the overshoot prompt.
    test('confirming an overshoot still ends the trip when the write fails',
        () async {
      db.failWrites = true;
      final vm = newVm();
      await vm.startTrip(buildTrip());
      for (final m in [900.0, 400.0, 120.0, 200.0, 300.0, 450.0]) {
        gps.add(fixAt(m));
        await pumpEventQueue();
      }
      expect(vm.phase, TripPhase.overshootPrompt);

      await vm.answerOvershoot(true); // must not throw

      expect(vm.phase, TripPhase.overshootConfirmed);
      expect(db.lastTrip?.status, 'overshot',
          reason: 'the trip must still be closed out');
      vm.dispose();
    });

    test('answering "no" to a false overshoot resumes monitoring', () async {
      final vm = newVm();
      await vm.startTrip(buildTrip());
      for (final m in [900.0, 400.0, 120.0, 200.0, 300.0, 450.0]) {
        gps.add(fixAt(m));
        await pumpEventQueue();
      }
      expect(vm.phase, TripPhase.overshootPrompt);

      await vm.answerOvershoot(false);
      expect(vm.phase, TripPhase.monitoring);
      expect(db.overshoots, isEmpty);

      await vm.stopTrip();
      vm.dispose();
    });
  });

  group('time-based safety timers (virtual clock)', () {
    test('an unattended Stage 1 auto-escalates to Stage 2 after 30 s', () {
      fakeAsync((async) {
        final vm = newVm();
        vm.startTrip(buildTrip());
        async.flushMicrotasks();

        gps.add(fixAt(1000));
        async.flushMicrotasks();
        expect(vm.phase, TripPhase.alarmStage1);

        // Rider does nothing; Figure 27 says Stage 2 must fire itself.
        async.elapse(const Duration(seconds: 31));
        expect(vm.phase, TripPhase.alarmStage2);

        vm.dispose();
        gps.close();
      });
    });

    test('a snoozed alarm comes back ONE STAGE LOUDER', () {
      fakeAsync((async) {
        final vm = newVm();
        vm.startTrip(buildTrip());
        async.flushMicrotasks();

        gps.add(fixAt(1000));
        async.flushMicrotasks();
        expect(vm.phase, TripPhase.alarmStage1);

        vm.snoozeAlarm();
        async.flushMicrotasks();
        expect(vm.phase, TripPhase.monitoring, reason: 'silenced by snooze');

        async.elapse(const Duration(seconds: 31));
        expect(vm.phase, TripPhase.alarmStage2,
            reason: 'snoozing Stage 1 must bring back Stage 2, not Stage 1 - '
                're-firing the same stage lets a commuter idle at the gentlest '
                'alert while the vehicle keeps closing on the stop');

        vm.dispose();
        gps.close();
      });
    });

    test('prolonged GPS loss raises a SILENT Signal Lost warning', () {
      fakeAsync((async) {
        final vm = newVm();
        vm.startTrip(buildTrip());
        async.flushMicrotasks();

        // One fix, then silence — no further positions arrive.
        gps.add(fixAt(1500));
        async.flushMicrotasks();
        expect(vm.signalLostAlarm, isFalse);

        // UC-1 Exception 2: after 90 s without a fix the watchdog fires.
        async.elapse(const Duration(seconds: 120));
        expect(vm.signalLostAlarm, isTrue, reason: 'the warning still raises');
        expect(sound.stagesPlayed, isEmpty,
            reason: 'a GPS gap is not evidence the stop is near - the commuter '
                'is told, not startled');

        vm.dispose();
        gps.close();
      });
    });

    test('a fresh fix clears a raised Signal Lost alarm', () {
      fakeAsync((async) {
        final vm = newVm();
        vm.startTrip(buildTrip());
        async.flushMicrotasks();
        gps.add(fixAt(1500));
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 120));
        expect(vm.signalLostAlarm, isTrue);

        // Signal returns.
        gps.add(fixAt(1400));
        async.flushMicrotasks();
        expect(vm.signalLostAlarm, isFalse);

        vm.dispose();
        gps.close();
      });
    });
  });

  group('lifecycle safety', () {
    test('re-starting a trip does not leak the previous GPS listener',
        () async {
      final vm = newVm();
      await vm.startTrip(buildTrip());
      // A second start must tear the first monitoring down (one listener only).
      await vm.startTrip(buildTrip());

      gps.add(fixAt(1000));
      await pumpEventQueue();

      // Exactly one Stage 1, proving a single active _onFix path.
      expect(sound.stagesPlayed, [1]);

      await vm.stopTrip();
      vm.dispose();
    });

    // Slide-to-Stop is the ONLY way off the monitoring screen (PopScope blocks
    // Back), so if stopTrip throws, the rider is trapped in a trip they cannot
    // end. It must therefore never throw, whatever the teardown hits.
    test('the trip still ends when notification teardown fails', () async {
      lock.failOnCancel = true;
      final vm = newVm();
      await vm.startTrip(buildTrip());
      expect(vm.isActive, isTrue);

      await vm.stopTrip(); // must not throw

      expect(vm.phase, TripPhase.ended);
      expect(vm.isActive, isFalse);
      expect(lock.cancelCount, greaterThan(0), reason: 'teardown was attempted');
      vm.dispose();
    });

    test('isActive tracks the trip lifecycle', () async {
      final vm = newVm();
      expect(vm.isActive, isFalse);
      await vm.startTrip(buildTrip());
      expect(vm.isActive, isTrue);
      await vm.stopTrip();
      expect(vm.isActive, isFalse);
      vm.dispose();
    });
  });

  group('R6 — live commute guide with a transfer', () {
    test('the guide advances leg-by-leg through a jeepney → bus transfer while '
        'the alarm escalates in parallel', () async {
      final vm = newVm();
      // walk → ride jeepney (alight to transfer) → ride bus → walk to the stop.
      // The bus leg following the jeepney leg IS the transfer.
      final legs = [
        gtfsLeg('walk', 1600, 1),
        gtfsLeg('jeepney', 1000, 2), // alight here to transfer
        gtfsLeg('bus', 200, 3), // boarded after the transfer
        gtfsLeg('walk', 20, 4), // final walk to the destination
      ];
      await vm.startTrip(buildTrip(), guideLegs: legs);
      expect(vm.guide.currentIndex, 0);
      expect(vm.guide.currentLeg?.step.transportMode, 'walk');

      // Still 200 m short of the first alight point — no advance yet.
      gps.add(fixAt(1800));
      await pumpEventQueue();
      expect(vm.guide.currentIndex, 0);
      expect(vm.phase, TripPhase.monitoring);

      // Reach the first alight → board the jeepney.
      gps.add(fixAt(1600));
      await pumpEventQueue();
      expect(vm.guide.currentIndex, 1);
      expect(vm.guide.currentLeg?.step.transportMode, 'jeepney');

      // Reach the transfer point → the guide switches jeepney → bus, and the
      // proximity alarm's Stage 1 fires on the same fix.
      gps.add(fixAt(1000));
      await pumpEventQueue();
      expect(vm.guide.currentIndex, 2);
      expect(vm.guide.currentLeg?.step.transportMode, 'bus',
          reason: 'the transfer leg is now active');
      expect(vm.phase, TripPhase.alarmStage1);

      // Alight the bus onto the final walk; Stage 2 fires.
      gps.add(fixAt(200));
      await pumpEventQueue();
      expect(vm.guide.currentIndex, 3);
      expect(vm.guide.currentLeg?.step.transportMode, 'walk');
      expect(vm.phase, TripPhase.alarmStage2);

      // Arrive: the guide completes. The alarm does NOT jump to Stage 3 - an
      // unanswered Stage 2 is still on screen, so the trip is not auto-completed
      // either (that would stand the alarm down for a commuter who has not
      // responded to it); Stage 3 is left to the escalation timer.
      gps.add(fixAt(100));
      await pumpEventQueue();
      expect(vm.guide.isComplete, isTrue);
      expect(vm.phase, TripPhase.alarmStage2);
      // Each stage was sounded once, in order, with none skipped.
      expect(sound.stagesPlayed, [1, 2]);

      await vm.stopTrip();
      vm.dispose();
    });

    test('a synthetic transfer leg waits for a manual tap, then GPS resumes',
        () async {
      final vm = newVm();
      // The middle leg has no coordinates (synthetic fallback) — a rider must
      // confirm the transfer by tapping, because GPS can't know they boarded.
      final legs = [
        gtfsLeg('jeepney', 1000, 1),
        GuideLeg(step: step('bus', 2)), // synthetic: no endLat/endLng
        gtfsLeg('walk', 100, 3),
      ];
      await vm.startTrip(buildTrip(), guideLegs: legs);

      // Alight the jeepney → advance onto the synthetic bus (transfer) leg.
      gps.add(fixAt(1000));
      await pumpEventQueue();
      expect(vm.guide.currentIndex, 1);
      expect(vm.guide.currentLeg?.canAutoAdvance, isFalse);

      // GPS alone must never move past a synthetic leg, even standing on the
      // final leg's coordinates.
      gps.add(fixAt(100));
      await pumpEventQueue();
      expect(vm.guide.currentIndex, 1,
          reason: 'a synthetic transfer leg never auto-advances');

      // Rider taps "Done" to confirm the transfer → onto the final walk leg.
      vm.markGuideLegDone();
      expect(vm.guide.currentIndex, 2);
      expect(vm.guide.currentLeg?.step.transportMode, 'walk');

      // A fresh fix by the destination now completes the guide.
      gps.add(fixAt(90));
      await pumpEventQueue();
      expect(vm.guide.isComplete, isTrue);

      await vm.stopTrip();
      vm.dispose();
    });
  });

  // The trip map draws the rider's blue dot and pans the camera to follow it,
  // so the live position has to leave the ViewModel. It was already tracked
  // privately (_lastLat/_lastLng, used to stamp alarm and overshoot rows); these
  // getters only publish what the monitoring loop was recording anyway.
  group('live position for the trip map', () {
    test('is never the trip origin, whatever else happens', () async {
      final vm = newVm();
      final trip = buildTrip();
      await vm.startTrip(trip);

      // The origin is the tempting shortcut for filling the map's blue dot in
      // before the first fix arrives — and it is the one value that must never
      // be used. It is a PLANNING coordinate: it can be minutes old and the
      // rider may have walked well away from it by the time they board, so
      // drawing it says "you are here" about a place they have left.
      //
      // startTrip may seed the dot from the OS's cached fix (an actual GPS
      // reading, which the origin is not) — that is why this asserts the
      // origin is excluded rather than asserting null. With no platform in a
      // test the seed simply fails and the value stays null.
      expect(vm.currentLat, isNot(closeTo(trip.originLat, 1e-9)));
      expect(vm.currentLng, isNot(closeTo(trip.originLng, 1e-9)));

      await vm.stopTrip();
      vm.dispose();
    });

    test('follows every fix the stream delivers', () async {
      final vm = newVm();
      await vm.startTrip(buildTrip());

      gps.add(fixAt(1500));
      await pumpEventQueue();
      expect(vm.currentLat, closeTo(destLat + 1500 / metresPerDegLat, 1e-9));
      expect(vm.currentLng, closeTo(destLng, 1e-9));

      // The rider moves — the dot must move with them, which is the whole
      // premise of camera tracking.
      gps.add(fixAt(800));
      await pumpEventQueue();
      expect(vm.currentLat, closeTo(destLat + 800 / metresPerDegLat, 1e-9));

      await vm.stopTrip();
      vm.dispose();
    });

    test('keeps the last known position when the signal drops', () async {
      final vm = newVm();
      await vm.startTrip(buildTrip());

      gps.add(fixAt(1500));
      await pumpEventQueue();
      gps.addError(Exception('GPS dropped'));
      await pumpEventQueue();

      // Blanking the dot on a dropped fix would erase the rider from a map
      // they are still navigating by. The last real position is still the best
      // answer available.
      expect(vm.currentLat, closeTo(destLat + 1500 / metresPerDegLat, 1e-9));
      expect(vm.currentLng, closeTo(destLng, 1e-9));

      await vm.stopTrip();
      vm.dispose();
    });
  });
}

// ── Stub collaborators ────────────────────────────────────────────────────
// `implements` + noSuchMethod lets each fake satisfy the concrete singleton's
// type while overriding only the members TripViewModel actually calls — no
// changes to the production services required.

class _FakeDb implements DatabaseService {
  double? avgAwake;
  final alarmEvents = <AlarmEvent>[];
  final overshoots = <Map<String, Object?>>[];
  final dismissed = <String>[];
  Trip? lastTrip;
  /// Simulates the encrypted database being unavailable on the device.
  bool failWrites = false;

  @override
  Future<double?> averageAwakeSeconds({int lastN = 10}) async => avgAwake;
  @override
  Future<void> updateTrip(Trip t) async => lastTrip = t;
  @override
  Future<void> insertAlarmEvent(AlarmEvent e) async => alarmEvents.add(e);
  @override
  Future<void> insertOvershootEvent(Map<String, Object?> row) async {
    if (failWrites) throw Exception('local storage unavailable');
    overshoots.add(row);
  }
  @override
  Future<void> markAlarmDismissed(String id) async => dismissed.add(id);
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _FakeSound implements SoundService {
  final stagesPlayed = <int>[];
  int stopAllCount = 0;

  @override
  Future<void> playAlarmStage(int stage, String soundName,
          {bool vibrationOnly = false, bool highIntensity = false}) async =>
      stagesPlayed.add(stage);
  @override
  Future<void> stopAll() async => stopAllCount++;
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _FakeLockWidget implements TripNotificationService {
  final distancesShown = <double>[];
  int cancelCount = 0;
  /// Simulates the notification plugin channel throwing on teardown.
  bool failOnCancel = false;
  @override
  VoidCallback? onEndTrip;

  @override
  Future<void> showTrip(
          {required String destination,
          required double distanceM,
          double? etaMinutes}) async =>
      distancesShown.add(distanceM);
  @override
  Future<void> cancel() async {
    cancelCount++;
    if (failOnCancel) throw Exception('notification channel unavailable');
  }
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _FakeHomeWidget implements HomeWidgetService {
  final statuses = <String>[];
  int idleCount = 0;

  @override
  Future<void> showTrip(
          {required String destination,
          required double distanceM,
          double? etaMinutes,
          required String status}) async =>
      statuses.add(status);
  @override
  Future<void> showIdle() async => idleCount++;
  @override
  dynamic noSuchMethod(Invocation i) => null;
}
