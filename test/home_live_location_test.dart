import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:navalert/viewmodels/home_viewmodel.dart';

/// R2 / UC-4 — the "you are here" dot must FOLLOW the rider.
///
/// Before this suite, [HomeViewModel] only ever took a one-shot
/// `Geolocator.getCurrentPosition` snapshot, from `refreshCurrentLocation()`,
/// which the Home screen called exactly twice: once on the first frame and once
/// per locate-button tap. So the blue dot was pinned to wherever the rider
/// happened to be when the app booted and never moved again — on a screen whose
/// entire job is showing them where they are before they pick a destination.
///
/// These tests drive the ViewModel from a MOCK position stream, so the live
/// tracking is verified headlessly — no device, no GPS hardware.
void main() {
  Position fix(double lat, double lng) => Position(
        latitude: lat,
        longitude: lng,
        timestamp: DateTime.now(),
        accuracy: 5,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 3,
        speedAccuracy: 0,
      );

  group('live location tracking', () {
    test('the dot follows every fix the stream delivers', () async {
      final controller = StreamController<Position>();
      addTearDown(controller.close);
      final vm = HomeViewModel(positionStreamFactory: (_) => controller.stream);
      vm.startLiveTracking();

      controller.add(fix(14.5979, 121.0108));
      await pumpEventQueue();
      expect(vm.currentLat, closeTo(14.5979, 1e-9));
      expect(vm.currentLng, closeTo(121.0108, 1e-9));

      // The rider moves — the dot must move with them, with no further call to
      // refreshCurrentLocation and no locate-button tap.
      controller.add(fix(14.6100, 121.0300));
      await pumpEventQueue();
      expect(vm.currentLat, closeTo(14.6100, 1e-9));
      expect(vm.currentLng, closeTo(121.0300, 1e-9));

      controller.add(fix(14.6250, 121.0500));
      await pumpEventQueue();
      expect(vm.currentLat, closeTo(14.6250, 1e-9));
      expect(vm.currentLng, closeTo(121.0500, 1e-9));
    });

    test('each fix notifies listeners so the marker repaints', () async {
      final controller = StreamController<Position>();
      addTearDown(controller.close);
      final vm = HomeViewModel(positionStreamFactory: (_) => controller.stream);
      var notifications = 0;
      vm.addListener(() => notifications++);
      vm.startLiveTracking();

      controller.add(fix(14.60, 121.02));
      await pumpEventQueue();
      controller.add(fix(14.61, 121.03));
      await pumpEventQueue();

      expect(notifications, greaterThanOrEqualTo(2),
          reason: 'a fix that does not notify leaves the dot painted at the '
              'old coordinates');
    });

    test('a live fix clears the fallback banner', () async {
      final controller = StreamController<Position>();
      addTearDown(controller.close);
      final vm = HomeViewModel(positionStreamFactory: (_) => controller.stream);
      // Simulate the state refreshCurrentLocation lands in when it could not
      // measure a real position: the map is centred on the PUP placeholder and
      // the banner is up.
      vm.locationIsFallback = true;
      vm.locationError = 'Could not get your location.';
      vm.startLiveTracking();

      controller.add(fix(14.60, 121.02));
      await pumpEventQueue();

      expect(vm.locationIsFallback, isFalse,
          reason: 'a real fix arrived — the position is no longer a guess');
      expect(vm.locationError, isNull);
    });

    test('a stream error leaves the last known dot in place', () async {
      final controller = StreamController<Position>();
      addTearDown(controller.close);
      final vm = HomeViewModel(positionStreamFactory: (_) => controller.stream);
      vm.startLiveTracking();

      controller.add(fix(14.60, 121.02));
      await pumpEventQueue();
      controller.addError(Exception('GPS dropped'));
      await pumpEventQueue();

      // Losing signal must not blank the map or throw — the last real position
      // is still the best answer available.
      expect(vm.currentLat, closeTo(14.60, 1e-9));
      expect(vm.currentLng, closeTo(121.02, 1e-9));
    });

    test('stopping tracking detaches the stream', () async {
      final controller = StreamController<Position>();
      addTearDown(controller.close);
      final vm = HomeViewModel(positionStreamFactory: (_) => controller.stream);
      vm.startLiveTracking();

      controller.add(fix(14.60, 121.02));
      await pumpEventQueue();
      await vm.stopLiveTracking();

      controller.add(fix(14.70, 121.09));
      await pumpEventQueue();

      expect(vm.currentLat, closeTo(14.60, 1e-9),
          reason: 'fixes after stopLiveTracking must be ignored');
    });

    test('starting twice does not stack two subscriptions', () async {
      final controller = StreamController<Position>.broadcast();
      addTearDown(controller.close);
      final vm = HomeViewModel(positionStreamFactory: (_) => controller.stream);
      var notifications = 0;
      vm.addListener(() => notifications++);

      vm.startLiveTracking();
      vm.startLiveTracking();
      controller.add(fix(14.60, 121.02));
      await pumpEventQueue();

      expect(notifications, 1,
          reason: 'a second subscription would double every GPS tick, and on '
              'dispose one of them would leak');
    });

    test('dispose cancels the subscription', () async {
      final controller = StreamController<Position>();
      addTearDown(controller.close);
      final vm = HomeViewModel(positionStreamFactory: (_) => controller.stream);
      vm.startLiveTracking();
      controller.add(fix(14.60, 121.02));
      await pumpEventQueue();

      vm.dispose();
      // A fix landing on a disposed ChangeNotifier would throw
      // "used after being disposed"; this must stay silent.
      controller.add(fix(14.70, 121.09));
      await pumpEventQueue();
    });
  });
}
