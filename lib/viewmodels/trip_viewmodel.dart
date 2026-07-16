import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../models/models.dart';
import '../services/adaptive_alarm_engine.dart';
import '../services/database_service.dart';
import '../services/sound_service.dart';
import '../services/trip_notification_service.dart';

enum TripPhase { monitoring, alarmStage1, alarmStage2, alarmStage3, overshootPrompt, overshootConfirmed, arrived, ended }

/// Active-trip ViewModel (Use Cases UC-5 Handle Proximity Alarm and
/// UC-6 Handle Overshoot Event).
///
/// Continuously monitors offline GPS, drives the speed-based adaptive
/// three-stage alarm (with the Figure 27/28 time-escalation rules:
/// Stage 2 fires if Stage 1 is not dismissed within 30 seconds and
/// Stage 3 if the rider stays unresponsive after Stage 2 or on the third
/// snooze), records behavioural reaction times, keeps the lock-screen
/// widget (Figure 25) updated, detects destination overshoot with
/// return-route assistance via Google Maps, and raises the "Signal Lost"
/// fallback alarm when GPS drops out (UC-1 Exception 2).
class TripViewModel extends ChangeNotifier {
  final _db = DatabaseService.instance;
  final _sound = SoundService.instance;
  final _lockWidget = TripNotificationService.instance;
  static const _uuid = Uuid();

  /// Figure 26/27 — unresponsive window before the next stage fires.
  static const stageEscalationDelay = Duration(seconds: 30);

  /// UC-1 Exception 2 — prolonged GPS loss before the fallback alarm.
  static const signalLostThreshold = Duration(seconds: 90);

  Trip? trip;
  TripPhase phase = TripPhase.ended;
  double distanceM = 0;
  double speedKmh = 0;
  double overshotM = 0;
  int highestStage = 0;
  double? etaMinutes;
  String? error;
  bool signalLostAlarm = false;

  AdaptiveAlarmEngine? _engine;
  StreamSubscription<Position>? _sub;
  Timer? _escalationTimer;
  Timer? _signalWatchdog;
  DateTime? _lastFixAt;
  DateTime? _alarmShownAt;
  String? _activeAlarmId;
  double? _lastLat;
  double? _lastLng;
  final Set<int> _firedStages = {};
  int _snoozeCount = 0;

  bool get isActive => phase != TripPhase.ended;

  Future<void> startTrip(Trip t) async {
    final avgReaction = await _db.averageAwakeSeconds();
    _engine = AdaptiveAlarmEngine(avgHistoricReactionSec: avgReaction);
    _firedStages.clear();
    _snoozeCount = 0;
    highestStage = 0;
    overshotM = 0;
    error = null;
    signalLostAlarm = false;
    etaMinutes = t.etaMinutes;

    trip = t
      ..status = 'active'
      ..startedAt = DateTime.now();
    await _db.updateTrip(trip!);

    phase = TripPhase.monitoring;
    notifyListeners();

    _lockWidget.onEndTrip = () => stopTrip();
    distanceM = Geolocator.distanceBetween(
        t.originLat, t.originLng, t.destinationLat, t.destinationLng);
    await _lockWidget.showTrip(
        destination: t.destinationLabel,
        distanceM: distanceM,
        etaMinutes: etaMinutes);

    const settings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 2,
    );
    _lastFixAt = DateTime.now();
    _sub = Geolocator.getPositionStream(
            locationSettings: _mobileSettings() ?? settings)
        .listen(_onFix, onError: (e) {
      error = 'GPS signal lost — keeping last known distance.';
      notifyListeners();
    });
    _startSignalWatchdog();
  }

  LocationSettings? _mobileSettings() {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    return AndroidSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 2,
      intervalDuration: const Duration(seconds: 1),
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'NavAlert trip monitoring',
        notificationText: 'Tracking your commute so you never miss your stop.',
        enableWakeLock: true,
      ),
    );
  }

  // ---------- UC-1 Exception 2: Signal Lost fallback alarm ----------
  void _startSignalWatchdog() {
    _signalWatchdog?.cancel();
    _signalWatchdog = Timer.periodic(const Duration(seconds: 15), (_) {
      final last = _lastFixAt;
      if (last == null || !isActive || signalLostAlarm) return;
      if (phase != TripPhase.monitoring) return;
      if (DateTime.now().difference(last) > signalLostThreshold) {
        signalLostAlarm = true;
        error = 'Signal Lost — GPS unavailable for a prolonged period.';
        _sound.playAlarmStage(2, trip?.alarmSound ?? 'Digital Clock',
            vibrationOnly: trip?.vibrationOnlyMode ?? false);
        notifyListeners();
      }
    });
  }

  Future<void> dismissSignalLostAlarm() async {
    signalLostAlarm = false;
    error = null;
    await _sound.stopAll();
    notifyListeners();
  }

  void _onFix(Position pos) {
    final t = trip;
    final engine = _engine;
    if (t == null || engine == null) return;

    _lastFixAt = DateTime.now();
    if (signalLostAlarm) dismissSignalLostAlarm();

    _lastLat = pos.latitude;
    _lastLng = pos.longitude;
    engine.addSpeedSample(pos.speed);
    speedKmh = (pos.speed.isNaN ? 0 : pos.speed) * 3.6;

    distanceM = Geolocator.distanceBetween(
        pos.latitude, pos.longitude, t.destinationLat, t.destinationLng);
    etaMinutes = distanceM / engine.avgSpeedMs / 60;
    _lockWidget.showTrip(
        destination: t.destinationLabel,
        distanceM: distanceM,
        etaMinutes: etaMinutes);

    // Overshoot detection first — a bypassed stop outranks staging.
    final past = engine.checkOvershoot(distanceM, accuracyM: pos.accuracy);
    if (past != null && phase != TripPhase.overshootConfirmed) {
      overshotM = past;
      phase = TripPhase.overshootPrompt;
      _cancelEscalation();
      _sound.playAlarmStage(3, t.alarmSound,
          vibrationOnly: t.vibrationOnlyMode);
      _logAlarm(3, 'Overshoot Alert', 'Did you miss your stop?');
      notifyListeners();
      return;
    }

    if (phase == TripPhase.overshootPrompt ||
        phase == TripPhase.overshootConfirmed ||
        phase == TripPhase.arrived) {
      notifyListeners();
      return;
    }

    final stage = engine.stageFor(distanceM);
    if (stage > 0 && !_firedStages.contains(stage) && stage > highestStage) {
      _fireStage(stage);
    }
    notifyListeners();
  }

  void _fireStage(int stage) {
    final t = trip!;
    _firedStages.add(stage);
    highestStage = stage;
    t.highestAlarmStage = stage;
    _alarmShownAt = DateTime.now();

    switch (stage) {
      case 1:
        phase = TripPhase.alarmStage1;
        _logAlarm(1, 'Approaching Stop', 'Get ready to go down.');
        break;
      case 2:
        phase = TripPhase.alarmStage2;
        _logAlarm(2, 'Get Ready', 'You are near your destination.');
        break;
      case 3:
        phase = TripPhase.alarmStage3;
        _logAlarm(3, 'WAKE UP', 'You might miss your stop.');
        break;
    }
    _sound.playAlarmStage(stage, t.alarmSound,
        vibrationOnly: t.vibrationOnlyMode);
    _scheduleEscalation(stage);
  }

  /// Figures 27–28: Stage 2 fires when Stage 1 is not dismissed within
  /// 30 seconds; Stage 3 when the rider remains unresponsive after Stage 2.
  void _scheduleEscalation(int fromStage) {
    _cancelEscalation();
    if (fromStage >= 3) return;
    _escalationTimer = Timer(stageEscalationDelay, () {
      final expectedPhase =
          fromStage == 1 ? TripPhase.alarmStage1 : TripPhase.alarmStage2;
      if (phase == expectedPhase) _fireStage(fromStage + 1);
    });
  }

  void _cancelEscalation() {
    _escalationTimer?.cancel();
    _escalationTimer = null;
  }

  Future<void> _logAlarm(int stage, String label, String message) async {
    final t = trip;
    if (t == null) return;
    _activeAlarmId = _uuid.v4();
    await _db.insertAlarmEvent(AlarmEvent(
      alarmId: _activeAlarmId!,
      tripId: t.tripId,
      stage: stage,
      stageLabel: label,
      stageMessage: message,
      kmFromDestination: distanceM / 1000,
      triggeredLat: _lastLat ?? t.originLat,
      triggeredLng: _lastLng ?? t.originLng,
      triggeredAt: DateTime.now(),
    ));
  }

  /// Snooze — escalates to Stage 3 on the third snooze (Figure 28).
  Future<void> snoozeAlarm() async {
    _snoozeCount++;
    _cancelEscalation();
    await _sound.stopAll();
    if (_snoozeCount >= 3 && phase != TripPhase.alarmStage3) {
      _fireStage(3);
    } else {
      phase = TripPhase.monitoring;
    }
    notifyListeners();
  }

  /// Dismiss — records the rider's reaction time for behavioural learning.
  Future<void> dismissAlarm() async {
    _cancelEscalation();
    await _recordReaction();
    await _sound.stopAll();
    if (phase == TripPhase.alarmStage3) {
      await _endTrip('arrived');
      phase = TripPhase.arrived;
    } else {
      phase = TripPhase.monitoring;
    }
    notifyListeners();
  }

  Future<void> _recordReaction() async {
    final shownAt = _alarmShownAt;
    final t = trip;
    if (shownAt != null && t != null) {
      final secs = DateTime.now().difference(shownAt).inSeconds;
      t.awakeSeconds = secs;
      await _db.updateTrip(t);
    }
    final id = _activeAlarmId;
    if (id != null) await _db.markAlarmDismissed(id);
    _activeAlarmId = null;
  }

  // ---------- overshoot handling (UC-6) ----------
  Future<void> answerOvershoot(bool missed) async {
    final t = trip;
    if (t == null) return;
    await _sound.stopAll();
    if (!missed) {
      // False overshoot — vehicle detouring; resume monitoring.
      _engine?.reset();
      phase = TripPhase.monitoring;
      notifyListeners();
      return;
    }
    phase = TripPhase.overshootConfirmed;
    await _db.insertOvershootEvent({
      'overshoot_id': _uuid.v4(),
      'trip_id': t.tripId,
      'destination_name': t.destinationLabel,
      'overshot_km': overshotM / 1000,
      'triggered_lat': _lastLat ?? t.destinationLat,
      'triggered_lng': _lastLng ?? t.destinationLng,
      'acknowledged': 1,
      'triggered_at': DateTime.now().toIso8601String(),
      'acknowledged_at': DateTime.now().toIso8601String(),
    });
    await _endTrip('overshot');
    notifyListeners();
  }

  /// One-tap return-route assistance through the Google Maps intent
  /// (zero network required by NavAlert itself).
  Future<void> openRerouteInGoogleMaps() async {
    final t = trip;
    if (t == null) return;
    final nav = Uri.parse(
        'google.navigation:q=${t.destinationLat},${t.destinationLng}&mode=w');
    final web = Uri.parse(
        'https://www.google.com/maps/dir/?api=1&destination=${t.destinationLat},${t.destinationLng}&travelmode=walking');
    try {
      if (!await launchUrl(nav, mode: LaunchMode.externalApplication)) {
        await launchUrl(web, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      try {
        await launchUrl(web, mode: LaunchMode.externalApplication);
      } catch (_) {
        // UC-6 Exception 1 — rerouting interface unavailable: copy the
        // return coordinates to the clipboard and surface an error.
        await Clipboard.setData(ClipboardData(
            text: '${t.destinationLat},${t.destinationLng}'));
        error = 'Google Maps unavailable — destination coordinates '
            'copied to clipboard.';
        notifyListeners();
      }
    }
  }

  Future<void> stopTrip() async {
    _cancelEscalation();
    await _recordReaction();
    await _sound.stopAll();
    await _endTrip(highestStage > 0 ? 'arrived' : 'cancelled');
    phase = TripPhase.ended;
    notifyListeners();
  }

  Future<void> closeSummary() async {
    phase = TripPhase.ended;
    notifyListeners();
  }

  Future<void> _endTrip(String status) async {
    await _sub?.cancel();
    _sub = null;
    _signalWatchdog?.cancel();
    _signalWatchdog = null;
    _cancelEscalation();
    await _lockWidget.cancel();
    final t = trip;
    if (t != null && t.endedAt == null) {
      t
        ..status = status
        ..etaMinutes = etaMinutes
        ..endedAt = DateTime.now();
      await _db.updateTrip(t);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _signalWatchdog?.cancel();
    _escalationTimer?.cancel();
    super.dispose();
  }
}
