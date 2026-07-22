import 'package:flutter_test/flutter_test.dart';
import 'package:navalert/models/models.dart';

/// Data Dictionary conformance (Tables 15–27).
///
/// These are the column names SQLite is keyed on: a silent rename or a field
/// that is never written shows up here as a failure rather than as data that
/// quietly goes missing from the rider's trip history.
void main() {
  group('Table 15 — app_state', () {
    test('flags default to "not yet done" and survive a round trip', () {
      final fresh = AppState();
      expect(fresh.onboardingCompleted, isFalse);
      expect(fresh.tutorialCompleted, isFalse);
      expect(fresh.incompleteSetupDismissed, isFalse);
      expect(fresh.sosLowLoadWarningDismissed, isFalse);

      final restored = AppState.fromMap(AppState(
        onboardingCompleted: true,
        tutorialCompleted: true,
        incompleteSetupDismissed: true,
        sosLowLoadWarningDismissed: true,
      ).toMap());

      expect(restored.onboardingCompleted, isTrue);
      expect(restored.tutorialCompleted, isTrue);
      expect(restored.incompleteSetupDismissed, isTrue);
      expect(restored.sosLowLoadWarningDismissed, isTrue);
    });

    test('booleans persist as the 0/1 integers the schema declares', () {
      final map = AppState(onboardingCompleted: true).toMap();
      expect(map['onboarding_completed'], 1);
      expect(map['tutorial_completed'], 0);
    });
  });

  group('Table 16 — user_settings', () {
    test('defaults match the documented values', () {
      final s = UserSettings();
      expect(s.locationAccess, 'Allow');
      expect(s.optimizeBatteryUsage, 'Allow');
      expect(s.pushNotifications, 'Allow');
      expect(s.bluetoothEnabled, 'Allow');
      expect(s.alarmSound, 'Digital Clock');
    });

    test('round trips every column', () {
      final restored = UserSettings.fromMap(UserSettings(
        locationAccess: 'Deny',
        optimizeBatteryUsage: 'Deny',
        pushNotifications: 'Deny',
        bluetoothEnabled: 'Deny',
        alarmSound: 'Air Horn',
      ).toMap());
      expect(restored.locationAccess, 'Deny');
      expect(restored.optimizeBatteryUsage, 'Deny');
      expect(restored.pushNotifications, 'Deny');
      expect(restored.bluetoothEnabled, 'Deny');
      expect(restored.alarmSound, 'Air Horn');
    });
  });

  group('Table 17 — transport_preferences', () {
    test('all three modes are enabled by default', () {
      final p = TransportPreferences();
      expect(p.busEnabled, isTrue);
      expect(p.uvExpressEnabled, isTrue);
      expect(p.jeepneyEnabled, isTrue);
    });

    test('round trips a partially disabled selection', () {
      final restored = TransportPreferences.fromMap(TransportPreferences(
        busEnabled: false,
        uvExpressEnabled: true,
        jeepneyEnabled: false,
      ).toMap());
      expect(restored.busEnabled, isFalse);
      expect(restored.uvExpressEnabled, isTrue);
      expect(restored.jeepneyEnabled, isFalse);
    });

    test('is a singleton row keyed on id = 1', () {
      expect(TransportPreferences().toMap()['id'], 1);
    });
  });

  group('Table 18 — emergency_contacts', () {
    test('round trips including the unique contact_order', () {
      final restored = EmergencyContact.fromMap(EmergencyContact(
        contactId: 'c-1',
        name: 'Mama',
        phoneNumber: '+639171234567',
        contactOrder: 2,
      ).toMap());
      expect(restored.contactId, 'c-1');
      expect(restored.name, 'Mama');
      expect(restored.phoneNumber, '+639171234567');
      expect(restored.contactOrder, 2);
    });
  });

  group('Table 19 — recordings', () {
    test('round trips and defaults to a non-preset clip', () {
      final r = Recording(
          recordingId: 'r-1', title: 'Mom call', filePath: '/audio/mom.m4a');
      expect(r.isPreset, isFalse);
      expect(r.durationSeconds, 0);

      final restored = Recording.fromMap(Recording(
        recordingId: 'r-2',
        title: 'Dad call',
        filePath: 'assets/sounds/dad.wav',
        durationSeconds: 12.5,
        isPreset: true,
      ).toMap());
      expect(restored.recordingId, 'r-2');
      expect(restored.title, 'Dad call');
      expect(restored.filePath, 'assets/sounds/dad.wav');
      expect(restored.durationSeconds, 12.5);
      expect(restored.isPreset, isTrue);
    });
  });

  group('Table 20 — favorites', () {
    test('round trips coordinates without losing precision', () {
      final restored = Favorite.fromMap(Favorite(
        favoriteId: 'f-1',
        name: 'PUP',
        address: 'Anonas St, Sta. Mesa, Manila',
        lat: 14.5979,
        lng: 121.0108,
      ).toMap());
      expect(restored.favoriteId, 'f-1');
      expect(restored.name, 'PUP');
      expect(restored.address, 'Anonas St, Sta. Mesa, Manila');
      expect(restored.lat, 14.5979);
      expect(restored.lng, 121.0108);
    });
  });

  group('Table 21 — fake_call_config', () {
    test('defaults the caller to "Mom" as documented', () {
      expect(FakeCallConfig().callerName, 'Mom');
      expect(FakeCallConfig().recordingId, isNull);
    });

    test('round trips a chosen recording and caller name', () {
      final restored = FakeCallConfig.fromMap(
          FakeCallConfig(recordingId: 'r-9', callerName: 'Ate').toMap());
      expect(restored.recordingId, 'r-9');
      expect(restored.callerName, 'Ate');
    });
  });

  group('Table 22 — trips', () {
    Trip sample() => Trip(
          tripId: 't-1',
          originLabel: 'PUP Sta. Mesa',
          originLat: 14.5979,
          originLng: 121.0108,
          destinationLabel: 'SM Megamall',
          destinationLat: 14.5850,
          destinationLng: 121.0568,
        );

    test('a new trip starts in the configured state', () {
      final t = sample();
      expect(t.status, 'configured');
      expect(t.alarmSound, 'Digital Clock');
      expect(t.vibrationOnlyMode, isFalse);
      expect(t.startedAt, isNull);
      expect(t.endedAt, isNull);
      expect(t.highestAlarmStage, isNull);
      expect(t.awakeSeconds, isNull);
    });

    test('round trips a completed trip including behavioural fields', () {
      final started = DateTime(2026, 7, 22, 8, 15);
      final ended = DateTime(2026, 7, 22, 9, 02);
      final t = sample()
        ..selectedRouteSuggestionId = 's-1'
        ..distanceKm = 7.2
        ..status = 'arrived'
        ..etaMinutes = 41
        ..highestAlarmStage = 3
        ..awakeSeconds = 67
        ..vibrationOnlyMode = true
        ..alarmSound = 'Siren'
        ..startedAt = started
        ..endedAt = ended;

      final restored = Trip.fromMap(t.toMap());
      expect(restored.tripId, 't-1');
      expect(restored.selectedRouteSuggestionId, 's-1');
      expect(restored.originLat, 14.5979);
      expect(restored.destinationLng, 121.0568);
      expect(restored.distanceKm, 7.2);
      expect(restored.status, 'arrived');
      expect(restored.etaMinutes, 41);
      expect(restored.highestAlarmStage, 3);
      expect(restored.awakeSeconds, 67,
          reason: 'reaction time feeds behavioural learning (R4)');
      expect(restored.vibrationOnlyMode, isTrue);
      expect(restored.alarmSound, 'Siren');
      expect(restored.startedAt, started);
      expect(restored.endedAt, ended);
    });
  });

  group('Table 25 — alarm_events', () {
    AlarmEvent event({List<String> checklist = const [], String? stop}) =>
        AlarmEvent(
          alarmId: 'a-1',
          tripId: 't-1',
          stage: 1,
          stageLabel: 'Approaching Stop',
          stageMessage: 'Get ready to go down.',
          kmFromDestination: 1.2,
          nearestStopName: stop,
          checklistItems: checklist,
          triggeredLat: 14.5979,
          triggeredLng: 121.0108,
          triggeredAt: DateTime(2026, 7, 22, 8, 40),
        );

    test('writes every documented column', () {
      final map = event(checklist: ['Gather belongings'], stop: 'Cubao').toMap();
      for (final column in [
        'alarm_id',
        'trip_id',
        'stage',
        'stage_label',
        'stage_message',
        'km_from_destination',
        'nearest_stop_name',
        'checklist_items',
        'triggered_lat',
        'triggered_lng',
        'dismissed',
        'triggered_at',
        'dismissed_at',
      ]) {
        expect(map.containsKey(column), isTrue, reason: 'missing $column');
      }
    });

    test('records the nearest transit stop rather than only coordinates', () {
      expect(event(stop: 'Cubao').toMap()['nearest_stop_name'], 'Cubao');
    });

    test('checklist items persist as newline-separated text', () {
      final map =
          event(checklist: ['Gather belongings', 'Stay alert']).toMap();
      expect(map['checklist_items'], 'Gather belongings\nStay alert');
    });

    test('an empty checklist stores NULL rather than an empty string', () {
      // Stages 2 and 3 carry no checklist; a blank string would be a lie.
      expect(event().toMap()['checklist_items'], isNull);
    });

    test('a freshly fired alarm is not yet dismissed', () {
      final map = event().toMap();
      expect(map['dismissed'], 0);
      expect(map['dismissed_at'], isNull);
    });
  });

  group('Table 23/24 — route_suggestions and route_steps', () {
    test('a step round trips its fare and stops', () {
      final restored = RouteStep.fromMap(RouteStep(
        stepId: 'st-1',
        suggestionId: 's-1',
        stepNumber: 2,
        transportMode: 'jeepney',
        instruction: 'Ride a Jeep from Cubao',
        fromStop: 'Cubao',
        toStop: 'Sta. Mesa',
        farePhp: 24.0,
        durationMinutes: 35,
      ).toMap());
      expect(restored.stepId, 'st-1');
      expect(restored.suggestionId, 's-1');
      expect(restored.stepNumber, 2);
      expect(restored.transportMode, 'jeepney');
      expect(restored.fromStop, 'Cubao');
      expect(restored.toStop, 'Sta. Mesa');
      expect(restored.farePhp, 24.0);
      expect(restored.durationMinutes, 35);
    });

    test('a suggestion round trips with its steps reattached', () {
      final suggestion = RouteSuggestion(
        suggestionId: 's-1',
        tripId: 't-1',
        rank: 1,
        routeLabel: 'Option A: via Jeepney',
        tagPrimary: 'Fastest',
        tagSecondary: 'Cheapest',
        totalFarePhp: 24.0,
        totalDurationMinutes: 44,
        transportSummary: 'Walk + Jeep',
        steps: const [],
      );
      final restored =
          RouteSuggestion.fromMap(suggestion.toMap(), steps: const []);
      expect(restored.suggestionId, 's-1');
      expect(restored.tripId, 't-1');
      expect(restored.rank, 1);
      expect(restored.tagPrimary, 'Fastest');
      expect(restored.tagSecondary, 'Cheapest');
      expect(restored.totalFarePhp, 24.0);
      expect(restored.totalDurationMinutes, 44);
      expect(restored.transportSummary, 'Walk + Jeep');
    });
  });
}
