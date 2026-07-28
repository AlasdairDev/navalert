import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
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
    test('a vehicle closing on the stop drives Stage 1 → 2 → 3', () async {
      final vm = newVm();
      await vm.startTrip(buildTrip());
      expect(vm.phase, TripPhase.monitoring);

      // 5 m/s → Stage-1 radius 1200 m, Stage-2 600 m, Stage-3 150 m.
      gps.add(fixAt(1000));
      await pumpEventQueue();
      expect(vm.phase, TripPhase.alarmStage1);

      gps.add(fixAt(500));
      await pumpEventQueue();
      expect(vm.phase, TripPhase.alarmStage2);

      gps.add(fixAt(100));
      await pumpEventQueue();
      expect(vm.phase, TripPhase.alarmStage3);

      // Each stage was actually sounded, once, in order.
      expect(sound.stagesPlayed, [1, 2, 3]);
      // Every stage was logged to history with its distance.
      expect(db.alarmEvents.map((e) => e.stage), [1, 2, 3]);

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
      gps.add(fixAt(100));
      await pumpEventQueue();
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

    test('a snoozed alarm re-fires after the escalation window', () {
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
        expect(vm.phase, TripPhase.alarmStage1,
            reason: 'a snoozed alarm must come back');

        vm.dispose();
        gps.close();
      });
    });

    test('prolonged GPS loss raises the Signal Lost fallback alarm', () {
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
        expect(vm.signalLostAlarm, isTrue);
        expect(sound.stagesPlayed, contains(2));

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

  @override
  Future<double?> averageAwakeSeconds({int lastN = 10}) async => avgAwake;
  @override
  Future<void> updateTrip(Trip t) async => lastTrip = t;
  @override
  Future<void> insertAlarmEvent(AlarmEvent e) async => alarmEvents.add(e);
  @override
  Future<void> insertOvershootEvent(Map<String, Object?> row) async =>
      overshoots.add(row);
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
  @override
  VoidCallback? onEndTrip;

  @override
  Future<void> showTrip(
          {required String destination,
          required double distanceM,
          double? etaMinutes}) async =>
      distancesShown.add(distanceM);
  @override
  Future<void> cancel() async => cancelCount++;
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
