import 'package:flutter_test/flutter_test.dart';
import 'package:navalert/models/guide_leg.dart';
import 'package:navalert/models/models.dart';
import 'package:navalert/services/guide_progress.dart';

/// Live commute guide — hybrid step advancement.
///
/// The load-bearing rule is that a synthetic leg (no coordinates) must NEVER
/// auto-advance: its "stops" are fictional points on a straight line, so
/// completing one from GPS would claim the rider passed somewhere they did not.
void main() {
  RouteStep step(int n, String mode) => RouteStep(
        stepId: 'st-$n',
        suggestionId: 's-1',
        stepNumber: n,
        transportMode: mode,
        instruction: 'Step $n',
      );

  // Cubao, roughly.
  const stopLat = 14.6200;
  const stopLng = 121.0530;

  GuideLeg gtfsLeg(int n) =>
      GuideLeg(step: step(n, 'jeepney'), endLat: stopLat, endLng: stopLng);
  GuideLeg syntheticLeg(int n) => GuideLeg(step: step(n, 'jeepney'));

  group('leg capability', () {
    test('a GTFS leg can auto-advance, a synthetic one cannot', () {
      expect(gtfsLeg(1).canAutoAdvance, isTrue);
      expect(syntheticLeg(1).canAutoAdvance, isFalse);
    });

    test('a half-specified leg is treated as unable to auto-advance', () {
      expect(GuideLeg(step: step(1, 'walk'), endLat: stopLat).canAutoAdvance,
          isFalse);
      expect(GuideLeg(step: step(1, 'walk'), endLng: stopLng).canAutoAdvance,
          isFalse);
    });
  });

  group('automatic advancement (GTFS legs)', () {
    test('advances once the rider reaches the alight stop', () {
      final p = GuideProgress([gtfsLeg(1), gtfsLeg(2)]);
      expect(p.currentIndex, 0);
      expect(p.update(stopLat, stopLng), isTrue);
      expect(p.currentIndex, 1);
    });

    test('does not advance while still far away', () {
      final p = GuideProgress([gtfsLeg(1), gtfsLeg(2)]);
      // ~1.1 km north of the stop.
      expect(p.update(stopLat + 0.01, stopLng), isFalse);
      expect(p.currentIndex, 0);
    });

    test('advances at most one leg per fix', () {
      final p = GuideProgress([gtfsLeg(1), gtfsLeg(2), gtfsLeg(3)]);
      p.update(stopLat, stopLng);
      expect(p.currentIndex, 1,
          reason: 'all legs share a stop, but one fix must not skip ahead');
    });

    test('never advances past the final leg', () {
      final p = GuideProgress([gtfsLeg(1)]);
      expect(p.update(stopLat, stopLng), isTrue);
      expect(p.isComplete, isTrue);
      // Further fixes at the same place must be inert.
      expect(p.update(stopLat, stopLng), isFalse);
      expect(p.currentIndex, 1);
    });

    test('never moves backwards once a leg is complete', () {
      final p = GuideProgress([gtfsLeg(1), syntheticLeg(2)]);
      p.update(stopLat, stopLng);
      expect(p.currentIndex, 1);
      // Rider drifts back past the previous stop — index must hold.
      p.update(stopLat, stopLng);
      expect(p.currentIndex, 1);
    });
  });

  group('synthetic legs never auto-advance', () {
    test('stays put even standing exactly on the nominal coordinates', () {
      final p = GuideProgress([syntheticLeg(1), syntheticLeg(2)]);
      expect(p.update(stopLat, stopLng), isFalse);
      expect(p.currentIndex, 0);
    });

    test('repeated fixes never nudge it forward', () {
      final p = GuideProgress([syntheticLeg(1), gtfsLeg(2)]);
      for (var i = 0; i < 50; i++) {
        p.update(stopLat, stopLng);
      }
      expect(p.currentIndex, 0,
          reason: 'a synthetic leg can only be completed by the rider');
    });
  });

  group('manual advancement', () {
    test('works on a synthetic leg', () {
      final p = GuideProgress([syntheticLeg(1), syntheticLeg(2)]);
      expect(p.markDone(), isTrue);
      expect(p.currentIndex, 1);
    });

    test('works on a GTFS leg, so an early auto-step can be corrected', () {
      final p = GuideProgress([gtfsLeg(1), gtfsLeg(2)]);
      expect(p.markDone(), isTrue);
      expect(p.currentIndex, 1);
    });

    test('stops at the end rather than running off', () {
      final p = GuideProgress([syntheticLeg(1)]);
      expect(p.markDone(), isTrue);
      expect(p.markDone(), isFalse);
      expect(p.currentIndex, 1);
      expect(p.isComplete, isTrue);
    });

    test('a mixed route can be walked through end to end', () {
      final p = GuideProgress([syntheticLeg(1), gtfsLeg(2), syntheticLeg(3)]);
      expect(p.markDone(), isTrue); // walk, tapped
      expect(p.update(stopLat, stopLng), isTrue); // ride, automatic
      expect(p.markDone(), isTrue); // final walk, tapped
      expect(p.isComplete, isTrue);
    });
  });

  group('empty guide', () {
    test('is inert and never reports completion', () {
      final p = GuideProgress([]);
      expect(p.isEmpty, isTrue);
      expect(p.currentLeg, isNull);
      expect(p.markDone(), isFalse);
      expect(p.update(stopLat, stopLng), isFalse);
      expect(p.isComplete, isFalse,
          reason: 'no guide is not a finished guide — the sheet just hides');
    });
  });
}
