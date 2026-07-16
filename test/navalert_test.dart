import 'package:flutter_test/flutter_test.dart';

import 'package:navalert/services/adaptive_alarm_engine.dart';
import 'package:navalert/services/route_engine.dart';
import 'package:navalert/data/models.dart';

void main() {
  group('AdaptiveAlarmEngine (R1–R4)', () {
    test('lead radius scales with speed and caps at 5 km', () {
      final engine = AdaptiveAlarmEngine();
      for (var i = 0; i < 12; i++) {
        engine.addSpeedSample(3.0); // ~11 km/h crawling jeepney
      }
      final slowRadius = engine.stage1RadiusM;

      final fast = AdaptiveAlarmEngine();
      for (var i = 0; i < 12; i++) {
        fast.addSpeedSample(25.0); // ~90 km/h highway bus
      }
      expect(fast.stage1RadiusM, greaterThan(slowRadius));
      expect(fast.stage1RadiusM, lessThanOrEqualTo(5000));
    });

    test('stages escalate 1 → 2 → 3 as distance shrinks', () {
      final engine = AdaptiveAlarmEngine();
      for (var i = 0; i < 6; i++) {
        engine.addSpeedSample(8.0);
      }
      expect(engine.stageFor(engine.stage1RadiusM + 500), 0);
      expect(engine.stageFor(engine.stage1RadiusM - 1), 1);
      expect(engine.stageFor(engine.stage2RadiusM - 1), 2);
      expect(engine.stageFor(100), 3);
    });

    test('overshoot latches only after consecutive increasing fixes', () {
      final engine = AdaptiveAlarmEngine();
      for (var i = 0; i < 6; i++) {
        engine.addSpeedSample(8.0);
      }
      // Approach then pass the stop.
      engine.checkOvershoot(900);
      engine.checkOvershoot(400);
      engine.checkOvershoot(120); // min distance
      expect(engine.checkOvershoot(200), isNull); // 1st increase
      expect(engine.checkOvershoot(290), isNull); // 2nd increase
      final past = engine.checkOvershoot(420); // 3rd increase ≥ 250 m past
      expect(past, isNotNull);
      expect(engine.overshootLatched, isTrue);
    });

    test('behavioural learning widens window for slow dismissers (R4)', () {
      final quick = AdaptiveAlarmEngine(avgHistoricReactionSec: 10);
      final sleepy = AdaptiveAlarmEngine(avgHistoricReactionSec: 90);
      expect(sleepy.reactionWindowSec, greaterThan(quick.reactionWindowSec));
    });
  });

  group('RouteEngine fares (R6)', () {
    final engine = RouteEngine();
    test('LTFRB jeepney fare: base ₱13 first 4 km + ₱1.80/km', () {
      expect(engine.jeepFare(3), 13.0);
      expect(engine.jeepFare(10), closeTo(13 + 6 * 1.80, 0.01));
    });
    test('suggestions honour disabled modes', () {
      final prefs = TransportPreferences(
          busEnabled: false, uvExpressEnabled: false, jeepneyEnabled: true);
      final sugg = engine.buildSuggestions(
        tripId: 't1',
        originLabel: 'PUP Sta. Mesa',
        destinationLabel: 'SM Masinag',
        distanceKm: 12,
        prefs: prefs,
      );
      expect(sugg, isNotEmpty);
      for (final s in sugg) {
        expect(s.steps.any((st) => st.transportMode == 'bus'), isFalse);
      }
    });
  });
}
