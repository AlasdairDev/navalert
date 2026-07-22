import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../models/guide_leg.dart';
import '../models/models.dart';
import '../services/adaptive_alarm_engine.dart';
import '../services/database_service.dart';
import '../services/gtfs_service.dart';
import '../services/guide_progress.dart';
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
  Timer? _snoozeTimer;
  Timer? _signalWatchdog;
  DateTime? _lastFixAt;
  DateTime? _alarmShownAt;
  String? _activeAlarmId;
  double? _lastLat;
  double? _lastLng;
  final Set<int> _firedStages = {};
  int _snoozeCount = 0;

  bool get isActive => phase != TripPhase.ended;

  /// Live commute guide for this trip (empty when none was supplied, e.g. a
  /// favourites shortcut). Memory-only — see [GuideLeg].
  GuideProgress guide = GuideProgress(const []);

  Future<void> startTrip(Trip t, {List<GuideLeg> guideLegs = const []}) async {
    guide = GuideProgress(guideLegs);
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

    // distanceFilter 0: fixes keep arriving even when the vehicle is
    // stopped in traffic — otherwise a long red light would trip the
    // "Signal Lost" watchdog with GPS working perfectly.
    const settings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
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
      distanceFilter: 0,
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

  Future<void> _onFix(Position pos) async {
    final t = trip;
    final engine = _engine;
    if (t == null || engine == null) return;

    _lastFixAt = DateTime.now();
    // Await the fallback-alarm teardown: its stopAll() must finish before a
    // destination stage can start playing below, or the late stop lands on
    // top of the new alarm and silences the alert meant to wake the rider.
    if (signalLostAlarm) await dismissSignalLostAlarm();
    if (!isActive || trip == null) return;

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

    // Commute guide LAST, and isolated. The guide is a convenience; the alarm
    // is the product. A fault in step-advancement must never be able to stop a
    // stage from firing, so it runs after the alarm logic and swallows errors.
    try {
      guide.update(pos.latitude, pos.longitude);
    } catch (e) {
      debugPrint('NavAlert: guide advance failed — $e');
    }

    notifyListeners();
  }

  /// Rider tapped "Done" on the current commute-guide leg.
  void markGuideLegDone() {
    if (guide.markDone()) notifyListeners();
  }

  void _fireStage(int stage) {
    // Reached from timers as well as GPS fixes, so the trip may already be
    // over by the time this runs — never force-unwrap here.
    final t = trip;
    if (t == null || !isActive) return;
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
        vibrationOnly: t.vibrationOnlyMode,
        highIntensity: _engine?.highIntensity ?? false);
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
    _snoozeTimer?.cancel();
    _snoozeTimer = null;
  }

  /// Preparation reminders shown alongside the gentle alert (Figure 26).
  /// Kept here (not in the View) so the same list is displayed and logged.
  static const alarmChecklist = ['Gather belongings', 'Stay alert'];

  Future<void> _logAlarm(int stage, String label, String message) async {
    final t = trip;
    if (t == null) return;
    _activeAlarmId = _uuid.v4();
    final lat = _lastLat ?? t.originLat;
    final lng = _lastLng ?? t.originLng;
    await _db.insertAlarmEvent(AlarmEvent(
      alarmId: _activeAlarmId!,
      tripId: t.tripId,
      stage: stage,
      stageLabel: label,
      stageMessage: message,
      kmFromDestination: distanceM / 1000,
      nearestStopName: GtfsService.instance.nearestStopName(lat, lng),
      checklistItems: stage == 1 ? alarmChecklist : const [],
      triggeredLat: lat,
      triggeredLng: lng,
      triggeredAt: DateTime.now(),
    ));
  }

  /// Snooze — silences the alarm for the escalation window, then re-fires
  /// the same stage if the rider is still en route. Escalates straight to
  /// Stage 3 on the third snooze (Figure 28).
  Future<void> snoozeAlarm() async {
    _snoozeCount++;
    final snoozedStage = switch (phase) {
      TripPhase.alarmStage1 => 1,
      TripPhase.alarmStage2 => 2,
      _ => 0,
    };
    _cancelEscalation();
    await _sound.stopAll();
    if (_snoozeCount >= 3 && phase != TripPhase.alarmStage3) {
      _fireStage(3);
      notifyListeners();
      return;
    }
    phase = TripPhase.monitoring;
    // Bring the alarm back after the snooze window — a snoozed alarm must
    // return, otherwise a drowsy rider who taps Snooze once is never
    // warned again.
    if (snoozedStage > 0) {
      _snoozeTimer = Timer(stageEscalationDelay, () {
        if (phase == TripPhase.monitoring && isActive) {
          _fireStage(snoozedStage);
          notifyListeners();
        }
      });
    }
    notifyListeners();
  }

  /// Dismiss — records the rider's reaction time for behavioural learning.
  Future<void> dismissAlarm() async {
    _cancelEscalation();
    // Silence BEFORE persisting. UC-5 Exception 2: a failed behaviour-profile
    // write must never disrupt the rider — if the DB write came first and
    // threw, the alarm below would keep blaring with no way to stop it.
    await _sound.stopAll();
    await _recordReaction();
    if (phase == TripPhase.alarmStage3) {
      await _endTrip('arrived');
      phase = TripPhase.arrived;
    } else {
      phase = TripPhase.monitoring;
    }
    notifyListeners();
  }

  /// Records the rider's reaction time (R4 behavioural learning). Storage
  /// failures are logged and swallowed, never surfaced: UC-5 Exception 2 says
  /// the alarm is still dismissed and the error logged "without disrupting the
  /// immediate user experience".
  Future<void> _recordReaction() async {
    final shownAt = _alarmShownAt;
    final t = trip;
    try {
      if (shownAt != null && t != null) {
        t.awakeSeconds = DateTime.now().difference(shownAt).inSeconds;
        await _db.updateTrip(t);
      }
      final id = _activeAlarmId;
      if (id != null) await _db.markAlarmDismissed(id);
    } catch (e) {
      debugPrint('NavAlert: behaviour profile update failed — $e');
    }
    _activeAlarmId = null;
  }

  // ---------- overshoot handling (UC-6) ----------
  Future<void> answerOvershoot(bool missed) async {
    final t = trip;
    if (t == null) return;
    await _sound.stopAll();
    if (!missed) {
      // False overshoot — vehicle detouring; resume monitoring. Keep the
      // learned speed window so the lead radius stays correct.
      _engine?.resetOvershootTracking();
      phase = TripPhase.monitoring;
      notifyListeners();
      return;
    }
    phase = TripPhase.overshootConfirmed;
    final lat = _lastLat ?? t.destinationLat;
    final lng = _lastLng ?? t.destinationLng;
    await _db.insertOvershootEvent({
      'overshoot_id': _uuid.v4(),
      'trip_id': t.tripId,
      'destination_name': t.destinationLabel,
      'nearest_stop_name': GtfsService.instance.nearestStopName(lat, lng),
      'overshot_km': overshotM / 1000,
      'triggered_lat': lat,
      'triggered_lng': lng,
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
    // Same rule as dismissAlarm: silence first so a storage error can never
    // leave the rider stuck with an alarm they cannot stop.
    await _sound.stopAll();
    await _recordReaction();
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
      // A failed write loses one history row; letting it throw would leave the
      // trip permanently "active" with the UI stuck on the monitoring screen.
      try {
        await _db.updateTrip(t);
      } catch (e) {
        debugPrint('NavAlert: could not persist trip end — $e');
      }
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _signalWatchdog?.cancel();
    // _cancelEscalation clears the snooze timer too — a pending snooze that
    // outlived disposal would call notifyListeners() on a dead notifier.
    _cancelEscalation();
    super.dispose();
  }
}
