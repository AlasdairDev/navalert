import 'package:flutter_test/flutter_test.dart';
import 'package:navalert/services/trip_notification_service.dart';

/// Lock Screen Widget text (Figure 25).
///
/// showTrip() is called on EVERY GPS fix — one per second — so a 2-3 hour
/// Metro Manila commute posts thousands of updates. The service skips the
/// platform call when the composed text is unchanged, so these tests pin down
/// exactly when the text does and does not change: that identity IS the
/// battery optimisation (R5 / the paper's efficiency claim).
void main() {
  ({String title, String body}) text(double metres, {double? eta}) =>
      TripNotificationService.composeTripText(
          destination: 'PUP Sta. Mesa', distanceM: metres, etaMinutes: eta);

  group('redundant updates are suppressed', () {
    test('a stationary vehicle produces identical text', () {
      // Stuck in traffic: the distance does not move, so every one of those
      // per-second updates was redundant.
      expect(text(842).body, text(842).body);
    });

    test('sub-metre GPS jitter does not change the text', () {
      expect(text(842.2).body, text(841.8).body);
    });

    test('drift within the same 10 m bucket does not change the text', () {
      // Ten out of eleven updates in the final kilometre are suppressed.
      // (843 and 847 straddle the 845 midpoint, so those DO differ — the
      // bucket, not a fixed window, is what matters.)
      expect(text(841).body, text(844).body); // both -> 840 m
      expect(text(846).body, text(849).body); // both -> 850 m
    });

    test('crossing a 10 m boundary DOES change the text', () {
      expect(text(842).body, isNot(text(858).body));
    });
  });

  group('formatting', () {
    test('rounds sub-kilometre distance to 10 m', () {
      expect(text(846).body, contains('850 m away'));
      expect(text(844).body, contains('840 m away'));
    });

    test('switches to kilometres at 1 km with one decimal', () {
      expect(text(1000).body, contains('1.0 km away'));
      expect(text(7240).body, contains('7.2 km away'));
    });

    test('includes the destination and monitoring state', () {
      final t = text(500);
      expect(t.title, 'Approaching PUP Sta. Mesa');
      expect(t.body, contains('Monitoring'));
    });

    test('ETA is shown in whole minutes, and omitted when unknown', () {
      expect(text(500, eta: 8.4).body, contains('ETA 8 min'));
      expect(text(500).body, isNot(contains('ETA')));
    });
  });
}
