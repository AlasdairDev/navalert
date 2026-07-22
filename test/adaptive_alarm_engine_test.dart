import 'package:flutter_test/flutter_test.dart';
import 'package:navalert/services/adaptive_alarm_engine.dart';

/// Adaptive Alarm Engine — Requirements R1–R4 and UC-5 / UC-6.
///
/// This is the safety-critical core: if the lead radius or the stage
/// thresholds are wrong the rider is woken too late (missed stop) or far too
/// early (alarm fatigue), so the arithmetic is pinned down explicitly rather
/// than asserted loosely.
void main() {
  group('R3 — speed-adaptive lead radius', () {
    test('rolling average drives the Stage-1 radius', () {
      final engine = AdaptiveAlarmEngine();
      for (var i = 0; i < 12; i++) {
        engine.addSpeedSample(3.0); // ~11 km/h crawling jeepney
      }
      expect(engine.avgSpeedMs, 3.0);
      // 3 m/s × 240 s window = 720 m.
      expect(engine.stage1RadiusM, 720.0);
    });

    test('radius is capped at 5 km however fast the vehicle moves', () {
      final engine = AdaptiveAlarmEngine();
      for (var i = 0; i < 12; i++) {
        engine.addSpeedSample(40.0); // 144 km/h — far beyond any PUV
      }
      expect(engine.stage1RadiusM, 5000.0);
    });

    test('radius never drops below the 600 m floor when barely moving', () {
      final engine = AdaptiveAlarmEngine();
      for (var i = 0; i < 12; i++) {
        engine.addSpeedSample(0.1); // stuck in gridlock
      }
      // Speed is floored at 2 m/s, so 2 × 240 = 480 m -> floored to 600 m.
      expect(engine.avgSpeedMs, 2.0);
      expect(engine.stage1RadiusM, 600.0);
    });

    test('assumes a default PUV speed before any GPS fix arrives', () {
      expect(AdaptiveAlarmEngine().avgSpeedMs, 4.0);
    });

    test('rejects NaN and negative speed samples', () {
      final engine = AdaptiveAlarmEngine();
      engine.addSpeedSample(double.nan);
      engine.addSpeedSample(-5.0);
      // Both ignored, so the default is still in effect.
      expect(engine.avgSpeedMs, 4.0);

      engine.addSpeedSample(10.0);
      expect(engine.avgSpeedMs, 10.0);
    });

    test('speed window slides so old samples stop counting', () {
      final engine = AdaptiveAlarmEngine();
      for (var i = 0; i < 12; i++) {
        engine.addSpeedSample(20.0); // fast highway bus
      }
      expect(engine.avgSpeedMs, 20.0);
      // Vehicle enters heavy traffic: 12 slow samples must fully replace them.
      for (var i = 0; i < 12; i++) {
        engine.addSpeedSample(2.0);
      }
      expect(engine.avgSpeedMs, 2.0);
    });
  });

  group('R1 — multi-stage escalation thresholds', () {
    test('stages escalate 0 → 1 → 2 → 3 as the distance shrinks', () {
      final engine = AdaptiveAlarmEngine();
      for (var i = 0; i < 12; i++) {
        engine.addSpeedSample(5.0); // stage1 = 1200 m, stage2 = 600 m
      }
      expect(engine.stage1RadiusM, 1200.0);
      expect(engine.stage2RadiusM, 600.0);
      expect(engine.stage3RadiusM, 150.0);

      expect(engine.stageFor(5000), 0, reason: 'far away — no alarm yet');
      expect(engine.stageFor(1000), 1);
      expect(engine.stageFor(500), 2);
      expect(engine.stageFor(100), 3);
    });

    test('stage boundaries are inclusive at the threshold itself', () {
      final engine = AdaptiveAlarmEngine();
      for (var i = 0; i < 12; i++) {
        engine.addSpeedSample(5.0);
      }
      expect(engine.stageFor(1200), 1, reason: 'exactly at the lead radius');
      expect(engine.stageFor(600), 2);
      expect(engine.stageFor(150), 3, reason: 'exactly at arrival radius');
      expect(engine.stageFor(1200.01), 0);
    });

    test('Stage 2 keeps a 300 m floor so it cannot collapse into Stage 3', () {
      final engine = AdaptiveAlarmEngine();
      for (var i = 0; i < 12; i++) {
        engine.addSpeedSample(0.1);
      }
      // stage1 floors at 600 m; half of that is 300 m, the documented floor.
      expect(engine.stage2RadiusM, 300.0);
      expect(engine.stage2RadiusM, greaterThan(engine.stage3RadiusM));
    });
  });

  group('R4 — behavioural learning', () {
    test('a slow dismisser gets a wider reaction window than a quick one', () {
      final quick = AdaptiveAlarmEngine(avgHistoricReactionSec: 10);
      final sleepy = AdaptiveAlarmEngine(avgHistoricReactionSec: 90);
      expect(quick.reactionWindowSec, 200.0); // 240 + (10-20)*4
      expect(sleepy.reactionWindowSec, 520.0); // 240 + (90-20)*4
      expect(sleepy.reactionWindowSec, greaterThan(quick.reactionWindowSec));
    });

    test('the window is clamped so history cannot produce absurd radii', () {
      expect(AdaptiveAlarmEngine(avgHistoricReactionSec: 600).reactionWindowSec,
          600.0, reason: 'upper clamp');
      expect(AdaptiveAlarmEngine(avgHistoricReactionSec: 0).reactionWindowSec,
          160.0);
      expect(AdaptiveAlarmEngine(avgHistoricReactionSec: -100).reactionWindowSec,
          150.0, reason: 'lower clamp');
    });

    test('no history falls back to the base window', () {
      expect(AdaptiveAlarmEngine().reactionWindowSec, 240.0);
    });

    test('high-intensity mode engages at the 60 s reaction threshold', () {
      expect(AdaptiveAlarmEngine().highIntensity, isFalse,
          reason: 'unknown rider — do not blast them by default');
      expect(AdaptiveAlarmEngine(avgHistoricReactionSec: 59).highIntensity,
          isFalse);
      expect(AdaptiveAlarmEngine(avgHistoricReactionSec: 60).highIntensity,
          isTrue, reason: 'threshold is inclusive');
      expect(AdaptiveAlarmEngine(avgHistoricReactionSec: 120).highIntensity,
          isTrue);
    });
  });

  group('UC-6 — overshoot detection', () {
    AdaptiveAlarmEngine movingEngine() {
      final engine = AdaptiveAlarmEngine();
      for (var i = 0; i < 6; i++) {
        engine.addSpeedSample(8.0);
      }
      return engine;
    }

    test('latches only after consecutive increasing fixes past the threshold',
        () {
      final engine = movingEngine();
      engine.checkOvershoot(900);
      engine.checkOvershoot(400);
      engine.checkOvershoot(120); // closest approach
      expect(engine.checkOvershoot(200), isNull, reason: '1st increase');
      expect(engine.checkOvershoot(290), isNull, reason: '2nd increase');
      final past = engine.checkOvershoot(420); // 3rd increase, ≥250 m past
      expect(past, isNotNull);
      expect(past, closeTo(300, 0.001)); // 420 − 120 minimum distance
      expect(engine.overshootLatched, isTrue);
    });

    test('a single noisy fix never triggers an overshoot', () {
      final engine = movingEngine();
      engine.checkOvershoot(500);
      engine.checkOvershoot(100);
      expect(engine.checkOvershoot(900), isNull,
          reason: 'one wild GPS jump is not an overshoot');
      expect(engine.overshootLatched, isFalse);
    });

    test('approaching the destination never counts as overshooting', () {
      final engine = movingEngine();
      for (final d in [2000.0, 1500.0, 900.0, 400.0, 150.0, 60.0]) {
        expect(engine.checkOvershoot(d), isNull);
      }
      expect(engine.overshootLatched, isFalse);
    });

    test('moving away without ever getting close is not an overshoot', () {
      final engine = movingEngine();
      // The rider never approached, so minDistance is never inside the lead
      // radius — this is someone travelling in the wrong direction from the
      // start, not someone who slept through their stop.
      for (final d in [9000.0, 9400.0, 9800.0, 10500.0, 11000.0]) {
        expect(engine.checkOvershoot(d), isNull);
      }
      expect(engine.overshootLatched, isFalse);
    });

    test('fires at most once so the prompt cannot spam every GPS fix', () {
      final engine = movingEngine();
      engine.checkOvershoot(900);
      engine.checkOvershoot(120);
      engine.checkOvershoot(200);
      engine.checkOvershoot(290);
      expect(engine.checkOvershoot(420), isNotNull);
      // Subsequent fixes must stay silent while the prompt is on screen.
      expect(engine.checkOvershoot(600), isNull);
      expect(engine.checkOvershoot(900), isNull);
    });

    test('jitter below the accuracy gate does not accumulate', () {
      final engine = movingEngine();
      engine.checkOvershoot(900);
      engine.checkOvershoot(300, accuracyM: 50);
      // Drift smaller than half the fix accuracy must not count as movement.
      expect(engine.checkOvershoot(310, accuracyM: 50), isNull);
      expect(engine.checkOvershoot(320, accuracyM: 50), isNull);
      expect(engine.checkOvershoot(330, accuracyM: 50), isNull);
      expect(engine.overshootLatched, isFalse);
    });

    test('false overshoot (UC-6 flow A) keeps the learned speed window', () {
      final engine = AdaptiveAlarmEngine();
      for (var i = 0; i < 6; i++) {
        engine.addSpeedSample(14.0); // fast bus
      }
      final radiusOnApproach = engine.stage1RadiusM;
      expect(radiusOnApproach, greaterThan(1000));

      engine.resetOvershootTracking();

      expect(engine.overshootLatched, isFalse);
      // Clearing speeds here would collapse the radius to the 4 m/s default
      // and rob the rider of warning distance on the real approach.
      expect(engine.stage1RadiusM, radiusOnApproach);
    });

    test('full reset clears both the detector and the speed history', () {
      final engine = movingEngine();
      engine.checkOvershoot(900);
      engine.reset();
      expect(engine.overshootLatched, isFalse);
      expect(engine.avgSpeedMs, 4.0, reason: 'back to the default assumption');
    });
  });
}
