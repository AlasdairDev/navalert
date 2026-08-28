import 'package:flutter_test/flutter_test.dart';
import 'package:navalert/core/geo.dart';

/// Search must be able to recognise "the place I am standing in" by
/// COORDINATES, not only by text. Text matching reads the reverse-geocoded
/// street address, so it cannot see a name the address never mentions ("PUP")
/// and it goes dead entirely when the address lookup fails. These lock in the
/// distance rule that covers those cases.
void main() {
  // PUP Sta. Mesa — the project's standard demo origin. LONGITUDE second here;
  // metersBetween takes (lat, lng).
  const pupLat = 14.5979, pupLng = 121.0108;

  group('metersBetween', () {
    test('is zero for the same point', () {
      expect(metersBetween(pupLat, pupLng, pupLat, pupLng), closeTo(0, 0.001));
    });

    test('is symmetric', () {
      final a = metersBetween(pupLat, pupLng, 14.5995, 121.0125);
      final b = metersBetween(14.5995, 121.0125, pupLat, pupLng);
      expect(a, closeTo(b, 0.001));
    });

    test('matches a known short distance', () {
      // ~0.001 degrees of latitude is ~111 m anywhere on Earth.
      final d = metersBetween(pupLat, pupLng, pupLat + 0.001, pupLng);
      expect(d, closeTo(111, 2));
    });
  });

  group('isAtLocation', () {
    test('the exact spot counts as being there', () {
      expect(isAtLocation(pupLat, pupLng, pupLat, pupLng), isTrue);
    });

    test('a point well inside the radius counts', () {
      // ~55 m north.
      expect(isAtLocation(pupLat, pupLng, pupLat + 0.0005, pupLng), isTrue);
    });

    test('a point beyond the radius does not', () {
      // ~333 m north — a neighbouring block, not where you are standing.
      expect(isAtLocation(pupLat, pupLng, pupLat + 0.003, pupLng), isFalse);
    });

    test('the boundary is inclusive', () {
      expect(
        isAtLocation(pupLat, pupLng, pupLat, pupLng, radiusM: 0),
        isTrue,
        reason: 'the same point is within any radius, including zero',
      );
    });

    test('an unknown position never matches', () {
      // UC-4 Exception 2: a position we do not have must never be reported as
      // the commuter's location — that would name a place they were never at.
      expect(isAtLocation(null, pupLng, pupLat, pupLng), isFalse);
      expect(isAtLocation(pupLat, null, pupLat, pupLng), isFalse);
      expect(isAtLocation(null, null, pupLat, pupLng), isFalse);
    });

    test('a custom radius is honoured', () {
      final far = pupLat + 0.003; // ~333 m
      expect(isAtLocation(pupLat, pupLng, far, pupLng), isFalse);
      expect(isAtLocation(pupLat, pupLng, far, pupLng, radiusM: 500), isTrue);
    });
  });
}
