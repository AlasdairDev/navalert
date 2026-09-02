import 'package:flutter_test/flutter_test.dart';
import 'package:navalert/models/guide_leg.dart';
import 'package:navalert/models/models.dart';
import 'package:navalert/services/gtfs_service.dart';
import 'package:navalert/services/guide_progress.dart';
import 'package:navalert/services/route_engine.dart';
import 'package:navalert/services/transit_router.dart';

/// The live commute guide, SEGMENTED.
///
/// Two reports drove this, and they are the same defect seen from two sides:
///
///  * the trip map drew the whole journey from the moment the trip started, so
///    a rider walking to the terminal was shown the entire jeepney ride too and
///    could not tell which part of the line was theirs — the "live" map looked
///    identical to the preview they had already read;
///  * the guide had to be advanced by hand, because the step a rider spends the
///    longest on — the final walk to the door — was the one leg built without
///    coordinates, so it could never complete itself.
///
/// Both are fixed by the same thing: every leg knows where it starts and where
/// it ends. This file pins that down, because a leg quietly losing its
/// coordinates costs no test and no analyzer warning — it just silently goes
/// back to being tapped.
void main() {
  const origin = (lat: 14.6500, lng: 121.0700);
  const destination = (lat: 14.5979, lng: 121.0108);
  const board = GtfsStop('Cubao', 14.6200, 121.0530);
  const alight = GtfsStop('Sta. Mesa', 14.6000, 121.0150);

  final engine = RouteEngine();
  final prefs = TransportPreferences(
      busEnabled: true, jeepneyEnabled: true, uvExpressEnabled: true);

  group('GTFS-matched legs are drawable end to end', () {
    final legsOut = <String, List<GuideLeg>>{};
    final out = engine.buildFromGtfs(
      tripId: 't-1',
      destinationLabel: 'PUP Sta. Mesa',
      matches: [
        GtfsRouteMatch(
          route: const GtfsRoute('CUBAO - SANTA MESA', 'jeepney', [board, alight]),
          boardStop: board,
          alightStop: alight,
          walkToBoardM: 300,
          walkFromAlightM: 250,
          rideKm: 4.2,
        ),
      ],
      legsOut: legsOut,
      originLat: origin.lat,
      originLng: origin.lng,
      destinationLat: destination.lat,
      destinationLng: destination.lng,
    );
    final legs = legsOut[out.single.suggestionId]!;

    test('every leg carries both of its own endpoints', () {
      expect(legs, hasLength(3));
      for (final leg in legs) {
        expect(leg.hasStart, isTrue,
            reason: '${leg.step.instruction} cannot be drawn without a start');
        expect(leg.canAutoAdvance, isTrue,
            reason: '${leg.step.instruction} cannot complete itself');
      }
    });

    test('the legs join up — each one starts where the last ended', () {
      for (var i = 1; i < legs.length; i++) {
        expect(legs[i].startLat, legs[i - 1].endLat);
        expect(legs[i].startLng, legs[i - 1].endLng);
      }
    });

    test('the first leg starts at the origin and the last ends at the '
        'destination', () {
      expect(legs.first.startLat, origin.lat);
      expect(legs.first.startLng, origin.lng);
      expect(legs.last.endLat, destination.lat);
      expect(legs.last.endLng, destination.lng);
    });

    test('the final walk can now complete itself', () {
      // This is the regression the groupmates hit. The walk to the door is the
      // step a rider spends longest on, and it used to be built with no
      // coordinates at all — so it sat there un-ticked until someone tapped it.
      expect(legs.last.step.transportMode, 'walk');
      expect(legs.last.canAutoAdvance, isTrue,
          reason: 'the destination is not a guess — there was never a reason '
              'to withhold it from the leg that ends there');
    });

    test('the ride leg spans board stop to alight stop, so its line is the '
        'ride and not the journey', () {
      final ride = legs[1];
      expect(ride.step.transportMode, isNot('walk'));
      expect(ride.startLat, board.lat);
      expect(ride.startLng, board.lng);
      expect(ride.endLat, alight.lat);
      expect(ride.endLng, alight.lng);
    });
  });

  group('journey legs (Dijkstra over the real network)', () {
    PlannedLeg leg(String mode, double fromLat, double toLat) => PlannedLeg(
          routeName: mode == 'walk' ? null : 'SOME ROUTE',
          mode: mode,
          fromStop: 'A',
          toStop: 'B',
          fromLat: fromLat,
          fromLng: 121.05,
          toLat: toLat,
          toLng: 121.02,
          km: 2,
          minutes: 10,
        );

    test('carry a start as well as an end, so each can be drawn alone', () {
      final legsOut = <String, List<GuideLeg>>{};
      final out = engine.buildFromJourneys(
        tripId: 't-2',
        destinationLabel: 'PUP Sta. Mesa',
        journeys: [
          PlannedJourney(
            legs: [
              leg('walk', 14.65, 14.62),
              leg('jeepney', 14.62, 14.60),
              leg('walk', 14.60, 14.5979),
            ],
            totalMinutes: 40,
          ),
        ],
        legsOut: legsOut,
      );
      final legs = legsOut[out.single.suggestionId]!;
      expect(legs, hasLength(3));
      for (final l in legs) {
        expect(l.hasStart, isTrue);
        expect(l.canAutoAdvance, isTrue);
      }
    });
  });

  group('synthetic suggestions keep the fictional-coordinate invariant', () {
    final legsOut = <String, List<GuideLeg>>{};
    final out = engine.buildSuggestions(
      tripId: 't-3',
      originLabel: 'Home',
      destinationLabel: 'PUP Sta. Mesa',
      distanceKm: 12,
      prefs: prefs,
      legsOut: legsOut,
      originLat: origin.lat,
      originLng: origin.lng,
      destinationLat: destination.lat,
      destinationLng: destination.lng,
    );
    final legs = legsOut[out.first.suggestionId]!;

    test('the two real ends are given real coordinates', () {
      expect(legs.first.startLat, origin.lat,
          reason: 'the rider really does start at the origin');
      expect(legs.last.endLat, destination.lat,
          reason: 'and really does finish at the destination');
      expect(legs.last.canAutoAdvance, isTrue);
    });

    test('the invented middle stays coordinate-free and tap-only', () {
      // A synthetic route's "Transfer point" and "nearest boarding point" are
      // places the engine made up from a distance estimate. Completing one from
      // GPS would claim the rider passed somewhere that does not exist, so the
      // rule holds: no coordinates, no automatic advance.
      expect(legs.length, greaterThan(2));
      for (final middle in legs.sublist(1, legs.length - 1)) {
        expect(middle.canAutoAdvance, isFalse,
            reason: '"${middle.step.instruction}" is a fictional point');
      }
    });

    test('omitting the coordinates leaves every leg manual, as before', () {
      final bare = <String, List<GuideLeg>>{};
      final built = engine.buildSuggestions(
        tripId: 't-4',
        originLabel: 'Home',
        destinationLabel: 'PUP Sta. Mesa',
        distanceKm: 12,
        prefs: prefs,
        legsOut: bare,
      );
      expect(bare[built.first.suggestionId]!.every((l) => !l.canAutoAdvance),
          isTrue);
    });
  });

  group('arrival radius differs by mode', () {
    RouteStep step(String mode) => RouteStep(
          stepId: 'st',
          suggestionId: 's',
          stepNumber: 1,
          transportMode: mode,
          instruction: 'go',
        );
    GuideLeg legOf(String mode) =>
        GuideLeg(step: step(mode), endLat: 14.62, endLng: 121.053);

    test('a ride turns over early, which is the cue to stand up', () {
      expect(GuideProgress.radiusFor(legOf('jeepney')),
          GuideProgress.arrivalRadiusM);
      expect(GuideProgress.radiusFor(legOf('bus')),
          GuideProgress.arrivalRadiusM);
    });

    test('a walk has to actually be finished', () {
      expect(GuideProgress.radiusFor(legOf('walk')),
          GuideProgress.walkArrivalRadiusM);
      expect(GuideProgress.walkArrivalRadiusM,
          lessThan(GuideProgress.arrivalRadiusM));
    });

    test('a walk still completes at a distance urban GPS can reach', () {
      // Tightening this below the app's own "you are standing here" radius
      // trades one failure for a worse one: a guide that strands the rider on a
      // step they have finished, which is what automatic advancement is for.
      expect(GuideProgress.walkArrivalRadiusM, greaterThanOrEqualTo(100));
    });

    test('the radii are actually applied, per leg', () {
      const lat = 14.62, lng = 121.053;
      // ~120 m north: inside the ride radius, outside the walk radius.
      const nearLat = lat + 0.00108;
      expect(GuideProgress([legOf('jeepney')]).update(nearLat, lng), isTrue);
      expect(GuideProgress([legOf('walk')]).update(nearLat, lng), isFalse);
      // Standing on it completes either.
      expect(GuideProgress([legOf('walk')]).update(lat, lng), isTrue);
    });
  });

  group('geometry is fitted to a leg without disturbing it', () {
    test('withPath keeps every coordinate the leg already had', () {
      final leg = GuideLeg(
        step: RouteStep(
            stepId: 'st',
            suggestionId: 's',
            stepNumber: 1,
            transportMode: 'jeepney',
            instruction: 'Ride jeepney "X" and alight at Y'),
        startLat: 14.62,
        startLng: 121.053,
        endLat: 14.60,
        endLng: 121.015,
      );
      expect(leg.path, isEmpty);
      final drawn = leg.withPath(const [
        [14.62, 121.053],
        [14.61, 121.03],
        [14.60, 121.015],
      ]);
      expect(drawn.path, hasLength(3));
      expect(drawn.startLat, leg.startLat);
      expect(drawn.startLng, leg.startLng);
      expect(drawn.endLat, leg.endLat);
      expect(drawn.endLng, leg.endLng);
      expect(drawn.canAutoAdvance, isTrue);
      expect(identical(drawn.step, leg.step), isTrue);
    });

    test('a leg missing an endpoint is not drawable on its own', () {
      final half = GuideLeg(
        step: RouteStep(
            stepId: 'st',
            suggestionId: 's',
            stepNumber: 1,
            transportMode: 'walk',
            instruction: 'Walk'),
        startLat: 14.62,
        startLng: 121.053,
      );
      expect(half.hasStart, isTrue);
      expect(half.canAutoAdvance, isFalse,
          reason: 'the map falls back to a straight line to the destination, '
              'and the leg waits for a tap');
    });
  });
}
