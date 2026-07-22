/// NavAlert domain models — mirrors the Data Dictionary (Tables 15–27)
/// of the capstone methodology chapter.
library;

String _nowIso() => DateTime.now().toIso8601String();

/// Table 15 — app_state (singleton)
class AppState {
  bool onboardingCompleted;
  bool tutorialCompleted;
  bool incompleteSetupDismissed;
  bool sosLowLoadWarningDismissed;

  AppState({
    this.onboardingCompleted = false,
    this.tutorialCompleted = false,
    this.incompleteSetupDismissed = false,
    this.sosLowLoadWarningDismissed = false,
  });

  factory AppState.fromMap(Map<String, Object?> m) => AppState(
        onboardingCompleted: (m['onboarding_completed'] as int? ?? 0) == 1,
        tutorialCompleted: (m['tutorial_completed'] as int? ?? 0) == 1,
        incompleteSetupDismissed:
            (m['incomplete_setup_dismissed'] as int? ?? 0) == 1,
        sosLowLoadWarningDismissed:
            (m['sos_low_load_warning_dismissed'] as int? ?? 0) == 1,
      );

  Map<String, Object?> toMap() => {
        'id': 1,
        'onboarding_completed': onboardingCompleted ? 1 : 0,
        'tutorial_completed': tutorialCompleted ? 1 : 0,
        'incomplete_setup_dismissed': incompleteSetupDismissed ? 1 : 0,
        'sos_low_load_warning_dismissed': sosLowLoadWarningDismissed ? 1 : 0,
        'updated_at': _nowIso(),
      };
}

/// Table 16 — user_settings (singleton)
class UserSettings {
  String locationAccess;
  String optimizeBatteryUsage;
  String pushNotifications;
  String bluetoothEnabled;
  String alarmSound;

  UserSettings({
    this.locationAccess = 'Allow',
    this.optimizeBatteryUsage = 'Allow',
    this.pushNotifications = 'Allow',
    this.bluetoothEnabled = 'Allow',
    this.alarmSound = 'Digital Clock',
  });

  factory UserSettings.fromMap(Map<String, Object?> m) => UserSettings(
        locationAccess: m['location_access'] as String? ?? 'Allow',
        optimizeBatteryUsage:
            m['optimize_battery_usage'] as String? ?? 'Allow',
        pushNotifications: m['push_notifications'] as String? ?? 'Allow',
        bluetoothEnabled: m['bluetooth_enabled'] as String? ?? 'Allow',
        alarmSound: m['alarm_sound'] as String? ?? 'Digital Clock',
      );

  Map<String, Object?> toMap() => {
        'id': 1,
        'location_access': locationAccess,
        'optimize_battery_usage': optimizeBatteryUsage,
        'push_notifications': pushNotifications,
        'bluetooth_enabled': bluetoothEnabled,
        'alarm_sound': alarmSound,
        'updated_at': _nowIso(),
      };
}

/// Table 17 — transport_preferences (singleton)
class TransportPreferences {
  bool busEnabled;
  bool uvExpressEnabled;
  bool jeepneyEnabled;

  TransportPreferences({
    this.busEnabled = true,
    this.uvExpressEnabled = true,
    this.jeepneyEnabled = true,
  });

  factory TransportPreferences.fromMap(Map<String, Object?> m) =>
      TransportPreferences(
        busEnabled: (m['bus_enabled'] as int? ?? 1) == 1,
        uvExpressEnabled: (m['uv_express_enabled'] as int? ?? 1) == 1,
        jeepneyEnabled: (m['jeepney_enabled'] as int? ?? 1) == 1,
      );

  Map<String, Object?> toMap() => {
        'id': 1,
        'bus_enabled': busEnabled ? 1 : 0,
        'uv_express_enabled': uvExpressEnabled ? 1 : 0,
        'jeepney_enabled': jeepneyEnabled ? 1 : 0,
        'updated_at': _nowIso(),
      };
}

/// Table 18 — emergency_contacts
class EmergencyContact {
  final String contactId;
  String name;
  String phoneNumber;
  int contactOrder;

  EmergencyContact({
    required this.contactId,
    required this.name,
    required this.phoneNumber,
    required this.contactOrder,
  });

  factory EmergencyContact.fromMap(Map<String, Object?> m) => EmergencyContact(
        contactId: m['contact_id'] as String,
        name: m['name'] as String,
        phoneNumber: m['phone_number'] as String,
        contactOrder: m['contact_order'] as int,
      );

  Map<String, Object?> toMap() => {
        'contact_id': contactId,
        'name': name,
        'phone_number': phoneNumber,
        'contact_order': contactOrder,
        'created_at': _nowIso(),
        'updated_at': _nowIso(),
      };
}

/// Table 19 — recordings (fake-call audio)
class Recording {
  final String recordingId;
  final String title;
  final String filePath;
  final double durationSeconds;
  final bool isPreset;

  /// When the clip was recorded. Figure 32 shows this date under each custom
  /// recording, so it must survive a read/write round trip — writing "now"
  /// on every save would silently reset the rider's recording history.
  final DateTime recordedAt;

  Recording({
    required this.recordingId,
    required this.title,
    required this.filePath,
    this.durationSeconds = 0,
    this.isPreset = false,
    DateTime? recordedAt,
  }) : recordedAt = recordedAt ?? DateTime.now();

  factory Recording.fromMap(Map<String, Object?> m) => Recording(
        recordingId: m['recording_id'] as String,
        title: m['title'] as String,
        filePath: m['file_path'] as String,
        durationSeconds: (m['duration_seconds'] as num? ?? 0).toDouble(),
        isPreset: (m['is_preset'] as int? ?? 0) == 1,
        recordedAt: DateTime.tryParse(m['recorded_at'] as String? ?? ''),
      );

  Map<String, Object?> toMap() => {
        'recording_id': recordingId,
        'title': title,
        'file_path': filePath,
        'duration_seconds': durationSeconds,
        'is_preset': isPreset ? 1 : 0,
        'recorded_at': recordedAt.toIso8601String(),
      };
}

/// Table 20 — favorites
class Favorite {
  final String favoriteId;
  final String name;
  final String address;
  final double lat;
  final double lng;

  Favorite({
    required this.favoriteId,
    required this.name,
    required this.address,
    required this.lat,
    required this.lng,
  });

  factory Favorite.fromMap(Map<String, Object?> m) => Favorite(
        favoriteId: m['favorite_id'] as String,
        name: m['name'] as String,
        address: m['address'] as String,
        lat: (m['lat'] as num).toDouble(),
        lng: (m['lng'] as num).toDouble(),
      );

  Map<String, Object?> toMap() => {
        'favorite_id': favoriteId,
        'name': name,
        'address': address,
        'lat': lat,
        'lng': lng,
        'created_at': _nowIso(),
      };
}

/// Table 21 — fake_call_config (singleton)
class FakeCallConfig {
  String? recordingId;
  String callerName;

  FakeCallConfig({this.recordingId, this.callerName = 'Mom'});

  factory FakeCallConfig.fromMap(Map<String, Object?> m) => FakeCallConfig(
        recordingId: m['recording_id'] as String?,
        callerName: m['caller_name'] as String? ?? 'Mom',
      );

  Map<String, Object?> toMap() => {
        'id': 1,
        'recording_id': recordingId,
        'caller_name': callerName,
        'updated_at': _nowIso(),
      };
}

/// Table 22 — trips
class Trip {
  final String tripId;
  String? destinationFavoriteId;
  String? selectedRouteSuggestionId;
  final String originLabel;
  final double originLat;
  final double originLng;
  final String destinationLabel;
  final double destinationLat;
  final double destinationLng;
  double distanceKm;
  String alarmSound;
  bool vibrationOnlyMode;
  String status; // configured | active | arrived | overshot | cancelled
  double? etaMinutes;
  int? highestAlarmStage;
  int? awakeSeconds;
  DateTime? startedAt;
  DateTime? endedAt;

  Trip({
    required this.tripId,
    this.destinationFavoriteId,
    this.selectedRouteSuggestionId,
    required this.originLabel,
    required this.originLat,
    required this.originLng,
    required this.destinationLabel,
    required this.destinationLat,
    required this.destinationLng,
    this.distanceKm = 0,
    this.alarmSound = 'Digital Clock',
    this.vibrationOnlyMode = false,
    this.status = 'configured',
    this.etaMinutes,
    this.highestAlarmStage,
    this.awakeSeconds,
    this.startedAt,
    this.endedAt,
  });

  factory Trip.fromMap(Map<String, Object?> m) => Trip(
        tripId: m['trip_id'] as String,
        destinationFavoriteId: m['destination_favorite_id'] as String?,
        selectedRouteSuggestionId:
            m['selected_route_suggestion_id'] as String?,
        originLabel: m['origin_label'] as String,
        originLat: (m['origin_lat'] as num).toDouble(),
        originLng: (m['origin_lng'] as num).toDouble(),
        destinationLabel: m['destination_label'] as String,
        destinationLat: (m['destination_lat'] as num).toDouble(),
        destinationLng: (m['destination_lng'] as num).toDouble(),
        distanceKm: (m['distance_km'] as num? ?? 0).toDouble(),
        alarmSound: m['alarm_sound'] as String? ?? 'Digital Clock',
        vibrationOnlyMode: (m['vibration_only_mode'] as int? ?? 0) == 1,
        status: m['status'] as String? ?? 'configured',
        etaMinutes: (m['eta_minutes'] as num?)?.toDouble(),
        highestAlarmStage: m['highest_alarm_stage'] as int?,
        awakeSeconds: m['awake_seconds'] as int?,
        startedAt: m['started_at'] == null
            ? null
            : DateTime.tryParse(m['started_at'] as String),
        endedAt: m['ended_at'] == null
            ? null
            : DateTime.tryParse(m['ended_at'] as String),
      );

  Map<String, Object?> toMap() => {
        'trip_id': tripId,
        'destination_favorite_id': destinationFavoriteId,
        'selected_route_suggestion_id': selectedRouteSuggestionId,
        'origin_label': originLabel,
        'origin_lat': originLat,
        'origin_lng': originLng,
        'destination_label': destinationLabel,
        'destination_lat': destinationLat,
        'destination_lng': destinationLng,
        'distance_km': distanceKm,
        'alarm_sound': alarmSound,
        'vibration_only_mode': vibrationOnlyMode ? 1 : 0,
        'status': status,
        'eta_minutes': etaMinutes,
        'highest_alarm_stage': highestAlarmStage,
        'awake_seconds': awakeSeconds,
        'started_at': startedAt?.toIso8601String(),
        'ended_at': endedAt?.toIso8601String(),
        'created_at': _nowIso(),
      };
}

/// Table 23 — route_suggestions
class RouteSuggestion {
  final String suggestionId;
  final String tripId;
  final int rank;
  final String routeLabel;
  final String? tagPrimary;
  final String? tagSecondary;
  final double totalFarePhp;
  final double totalDurationMinutes;
  final String? transportSummary;
  final String status;
  final List<RouteStep> steps;

  RouteSuggestion({
    required this.suggestionId,
    required this.tripId,
    required this.rank,
    required this.routeLabel,
    this.tagPrimary,
    this.tagSecondary,
    required this.totalFarePhp,
    required this.totalDurationMinutes,
    this.transportSummary,
    this.status = 'suggested',
    this.steps = const [],
  });

  factory RouteSuggestion.fromMap(Map<String, Object?> m,
          {List<RouteStep> steps = const []}) =>
      RouteSuggestion(
        suggestionId: m['suggestion_id'] as String,
        tripId: m['trip_id'] as String,
        rank: m['rank'] as int,
        routeLabel: m['route_label'] as String,
        tagPrimary: m['tag_primary'] as String?,
        tagSecondary: m['tag_secondary'] as String?,
        totalFarePhp: (m['total_fare_php'] as num? ?? 0).toDouble(),
        totalDurationMinutes:
            (m['total_duration_minutes'] as num? ?? 0).toDouble(),
        transportSummary: m['transport_summary'] as String?,
        status: m['status'] as String? ?? 'suggested',
        steps: steps,
      );

  Map<String, Object?> toMap() => {
        'suggestion_id': suggestionId,
        'trip_id': tripId,
        'rank': rank,
        'route_label': routeLabel,
        'tag_primary': tagPrimary,
        'tag_secondary': tagSecondary,
        'total_fare_php': totalFarePhp,
        'total_duration_minutes': totalDurationMinutes,
        'transport_summary': transportSummary,
        'status': status,
        'generated_at': _nowIso(),
      };
}

/// Table 24 — route_steps
class RouteStep {
  final String stepId;
  final String suggestionId;
  final int stepNumber;
  final String transportMode; // walk | jeepney | bus | uv_express
  final String instruction;
  final String? fromStop;
  final String? toStop;
  final double farePhp;
  final double durationMinutes;

  RouteStep({
    required this.stepId,
    required this.suggestionId,
    required this.stepNumber,
    required this.transportMode,
    required this.instruction,
    this.fromStop,
    this.toStop,
    this.farePhp = 0,
    this.durationMinutes = 0,
  });

  factory RouteStep.fromMap(Map<String, Object?> m) => RouteStep(
        stepId: m['step_id'] as String,
        suggestionId: m['suggestion_id'] as String,
        stepNumber: m['step_number'] as int,
        transportMode: m['transport_mode'] as String,
        instruction: m['instruction'] as String,
        fromStop: m['from_stop'] as String?,
        toStop: m['to_stop'] as String?,
        farePhp: (m['fare_php'] as num? ?? 0).toDouble(),
        durationMinutes: (m['duration_minutes'] as num? ?? 0).toDouble(),
      );

  Map<String, Object?> toMap() => {
        'step_id': stepId,
        'suggestion_id': suggestionId,
        'step_number': stepNumber,
        'transport_mode': transportMode,
        'instruction': instruction,
        'from_stop': fromStop,
        'to_stop': toStop,
        'fare_php': farePhp,
        'duration_minutes': durationMinutes,
      };
}

/// Table 25 — alarm_events
class AlarmEvent {
  final String alarmId;
  final String tripId;
  final int stage;
  final String stageLabel;
  final String stageMessage;
  final double? kmFromDestination;
  final String? nearestStopName;

  /// Preparation checklist shown with the alert (Figure 26), stored so the
  /// trip record reflects what the rider was actually told to do.
  final List<String> checklistItems;
  final double triggeredLat;
  final double triggeredLng;
  bool dismissed;
  final DateTime triggeredAt;
  DateTime? dismissedAt;

  AlarmEvent({
    required this.alarmId,
    required this.tripId,
    required this.stage,
    required this.stageLabel,
    required this.stageMessage,
    this.kmFromDestination,
    this.nearestStopName,
    this.checklistItems = const [],
    required this.triggeredLat,
    required this.triggeredLng,
    this.dismissed = false,
    required this.triggeredAt,
    this.dismissedAt,
  });

  Map<String, Object?> toMap() => {
        'alarm_id': alarmId,
        'trip_id': tripId,
        'stage': stage,
        'stage_label': stageLabel,
        'stage_message': stageMessage,
        'km_from_destination': kmFromDestination,
        'nearest_stop_name': nearestStopName,
        'checklist_items': checklistItems.isEmpty ? null : checklistItems.join('\n'),
        'triggered_lat': triggeredLat,
        'triggered_lng': triggeredLng,
        'dismissed': dismissed ? 1 : 0,
        'triggered_at': triggeredAt.toIso8601String(),
        'dismissed_at': dismissedAt?.toIso8601String(),
      };
}

/// Search result returned by the Nominatim geocoding service.
class PlaceResult {
  final String name;
  final String displayName;
  final double lat;
  final double lng;

  PlaceResult({
    required this.name,
    required this.displayName,
    required this.lat,
    required this.lng,
  });
}
