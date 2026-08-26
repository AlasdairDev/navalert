import 'dart:async';

import 'package:clock/clock.dart';
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
import '../services/home_widget_service.dart';
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
  final DatabaseService _db;
  final SoundService _sound;
  final TripNotificationService _lockWidget;
  final HomeWidgetService _homeWidget;
  final Stream<Position> Function(LocationSettings settings)?
      _positionStreamFactory;
  static const _uuid = Uuid();

  /// Every parameter is a test seam and defaults to the production singleton, so
  /// the app always constructs `TripViewModel()` unchanged. Tests inject stub
  /// collaborators plus a [positionStreamFactory] to drive the whole UC-5/UC-6
  /// trip flow from a mock GPS stream, headless — no device, DB, or audio.
  /// DO NOT MODIFY LOGIC: the defaults keep production behaviour identical.
  TripViewModel({
    DatabaseService? db,
    SoundService? sound,
    TripNotificationService? lockWidget,
    HomeWidgetService? homeWidget,
    Stream<Position> Function(LocationSettings settings)? positionStreamFactory,
  })  : _db = db ?? DatabaseService.instance,
        _sound = sound ?? SoundService.instance,
        _lockWidget = lockWidget ?? TripNotificationService.instance,
        _homeWidget = homeWidget ?? HomeWidgetService.instance,
        _positionStreamFactory = positionStreamFactory;

  /// Figure 26/27 — unresponsive window before the next stage fires.
  static const stageEscalationDelay = Duration(seconds: 30);

  /// Shortened window used when the distance ALREADY justifies a later stage.
  ///
  /// Stages must be shown in order (see the eligibility note in _onFix), but a
  /// commuter who set their destination late, or whose first fix only landed
  /// after boarding, can begin a trip already inside the Stage-2 radius. Making
  /// them sit through two full 30 s windows would put "WAKE UP" a minute away
  /// from a stop that is seconds away. The sequence is preserved and simply
  /// played at catch-up speed until it agrees with the distance again.
  static const catchUpEscalationDelay = Duration(seconds: 5);

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
  DateTime? _lastHomeWidgetPush;
  DateTime? _alarmShownAt;
  String? _activeAlarmId;
  double? _lastLat;
  double? _lastLng;
  final Set<int> _firedStages = {};
  int _snoozeCount = 0;

  bool get isActive => phase != TripPhase.ended;

  /// The rider's last real GPS fix, for the live trip map's blue dot and its
  /// follow-camera. Read-only views onto the coordinates `_onFix` was already
  /// recording to stamp alarm and overshoot rows — nothing new is tracked here.
  ///
  /// NULL until a fix has actually landed, deliberately. Falling back to the
  /// trip's ORIGIN would be the tempting shortcut, but that is a planning
  /// coordinate which may be minutes stale, and a map cannot distinguish it
  /// from a working fix: it would draw "you are here" over a place the rider
  /// has left. Same rule HomeView follows — a missing dot is honest, a
  /// confident wrong dot is not.
  double? get currentLat => _lastLat;
  double? get currentLng => _lastLng;

  /// Live commute guide for this trip (empty when none was supplied, e.g. a
  /// favourites shortcut). Memory-only — see [GuideLeg].
  GuideProgress guide = GuideProgress(const []);

  Future<void> startTrip(Trip t, {List<GuideLeg> guideLegs = const []}) async {
    // Re-entrancy guard. A second startTrip (double-tapped "Start Trip", or a
    // new trip begun before the old one ended) would otherwise overwrite _sub
    // and leak the previous GPS listener — leaving TWO streams calling _onFix,
    // which means duplicated stage evaluation and double alarms. Tear any live
    // monitoring down first so exactly one listener and one watchdog exist.
    await _teardownMonitoring();

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
    _pushHomeWidget(force: true);

    // distanceFilter 0: fixes keep arriving even when the vehicle is
    // stopped in traffic — otherwise a long red light would trip the
    // "Signal Lost" watchdog with GPS working perfectly.
    const settings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
    );
    // clock.now() is the real wall clock in production and the virtual clock
    // under fakeAsync — the watchdog compares two clock.now() readings, so a
    // test can fast-forward the "Signal Lost" gap without waiting 90 real
    // seconds. Must pair with the clock.now() read in the watchdog below.
    _lastFixAt = clock.now();
    _seedLastKnownPosition();
    // The factory is null in production, so this is exactly the same stream as
    // before; a test supplies a mock stream to drive the flow deterministically.
    final factory = _positionStreamFactory;
    final positionStream = factory != null
        ? factory(settings)
        : Geolocator.getPositionStream(
            locationSettings: _mobileSettings() ?? settings);
    _sub = positionStream.listen(_onFix, onError: (e) {
      error = 'GPS signal lost - keeping last known distance.';
      notifyListeners();
    });
    _startSignalWatchdog();
  }

  /// Fills the blue dot in from the OS's cached fix so the trip map is not
  /// dotless while the first real fix is acquired.
  ///
  /// A cold GPS in a jeepney can take 30 s or more to produce its first
  /// reading, and for that whole window the map had nothing to draw — which
  /// looks exactly like a missing location layer rather than a device still
  /// searching for satellites.
  ///
  /// DO NOT MODIFY LOGIC: this seeds from `getLastKnownPosition`, an actual
  /// GPS reading, and NOT from the trip's origin. The origin is a planning
  /// coordinate that can be minutes old and may be nowhere near the rider by
  /// the time they board; drawing it would state "you are here" about a place
  /// they have left. A cached fix can be stale too, so it is only ever used to
  /// fill the gap — the first real fix overwrites it, and it is never allowed
  /// to overwrite one (see the null guard).
  ///
  /// Deliberately not awaited: startTrip is on the path between "Start Trip"
  /// and the monitoring screen, and a plugin call must not delay the alarm
  /// arming. Fire-and-forget, and silent on failure.
  void _seedLastKnownPosition() {
    Geolocator.getLastKnownPosition().then((pos) {
      if (pos == null || !isActive) return;
      // A real fix has already landed — never step on it.
      if (_lastLat != null || _lastLng != null) return;
      _lastLat = pos.latitude;
      _lastLng = pos.longitude;
      notifyListeners();
    }).catchError((Object e) {
      debugPrint('NavAlert: no cached position to seed the map with — $e');
      return null;
    });
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
      if (clock.now().difference(last) > signalLostThreshold) {
        signalLostAlarm = true;
        error = 'Signal Lost - GPS unavailable for a prolonged period.';
        // SILENT by design. The warning banner, its Dismiss action and the
        // logging all stay; only the alarm tone is gone.
        //
        // A GPS gap is not evidence that the stop is near — tunnels, urban
        // canyons and a phone in a bag all produce one mid-trip — so sounding a
        // Stage-2 alarm at it woke commuters for something that was not their
        // destination and taught them to distrust the alarm that is. The
        // commuter is still told the fix was lost; they are simply not startled
        // by it.
        notifyListeners();
      }
    });
  }

  /// Arms or disarms the escalating alarm mid-trip (R1, now opt-in).
  ///
  /// DO NOT MODIFY LOGIC: disarming must SILENCE anything already sounding and
  /// stand the escalation timers down, otherwise the rider turns the alarm off
  /// and it keeps blaring — and a pending Stage-2/3 timer would re-fire it
  /// seconds later. Re-arming does not replay a missed stage; stages resume
  /// from the next GPS fix, which is what `_firedStages` already guarantees.
  Future<void> setAlarmEnabled(bool enabled) async {
    final t = trip;
    if (t == null || t.alarmEnabled == enabled) return;
    t.alarmEnabled = enabled;
    if (!enabled) {
      _cancelEscalation();
      try {
        await _sound.stopAll();
      } catch (e) {
        debugPrint('NavAlert: could not silence the alarm — $e');
      }
      // Drop back to monitoring if a stage was on screen; the trip continues.
      if (phase == TripPhase.alarmStage1 ||
          phase == TripPhase.alarmStage2 ||
          phase == TripPhase.alarmStage3) {
        phase = TripPhase.monitoring;
      }
    }
    notifyListeners();
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

    _lastFixAt = clock.now(); // see the watchdog note in startTrip
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
    _pushHomeWidget();

    // ARRIVAL outranks overshoot, which outranks staging.
    //
    // The paper defines an Overshoot as passing the destination "without the
    // passenger waking up or getting off" — so a commuter who has arrived
    // cannot, by definition, have overshot. Running the overshoot detector
    // first meant a commuter who reached their stop, got off and walked on was
    // told they had missed it, because nothing ever moved the trip to
    // `arrived`: that phase was previously reachable ONLY by dismissing a
    // Stage-3 alarm or stopping the trip by hand.
    //
    // Guarded on `monitoring` deliberately. If a stage is on screen the
    // commuter has NOT responded to it, and auto-completing the trip under a
    // sounding alarm would quietly stand down the one thing trying to wake a
    // sleeping commuter at the exact moment it matters. In that case the
    // escalation is left to run; dismissing Stage 3 still ends the trip as
    // arrived, exactly as before.
    if (phase == TripPhase.monitoring && distanceM <= engine.arrivalRadiusM) {
      await _arriveAtDestination();
      return;
    }

    final past = engine.checkOvershoot(distanceM, accuracyM: pos.accuracy);
    if (past != null && phase != TripPhase.overshootConfirmed) {
      overshotM = past;
      phase = TripPhase.overshootPrompt;
      _cancelEscalation();
      // DO NOT MODIFY LOGIC: the overshoot PROMPT always shows, but the alarm
      // SOUND respects the rider's choice. Someone who deliberately disabled
      // the alarm must not be blasted with a Stage-3 tone; they still need to
      // be told they went past their stop, and the event is still logged.
      if (t.alarmEnabled) {
        _sound.playAlarmStage(3, t.alarmSound,
            vibrationOnly: t.vibrationOnlyMode);
      }
      _logAlarm(3, 'Overshoot Alert', 'Did you miss your stop?');
      // The home widget was pushed above while the phase still read
      // "Monitoring", and this branch returns early — so without a forced
      // refresh the launcher kept claiming the trip was fine until the next
      // fix, or indefinitely if fixes stop arriving.
      _pushHomeWidget(force: true);
      notifyListeners();
      return;
    }

    if (phase == TripPhase.overshootPrompt ||
        phase == TripPhase.overshootConfirmed ||
        phase == TripPhase.arrived) {
      notifyListeners();
      return;
    }

    // DO NOT MODIFY LOGIC: the alarm is OPT-IN per trip (t.alarmEnabled).
    // Everything else on this screen keeps running when it is off — distance,
    // ETA, the lock-screen widget, overshoot detection and the commute guide —
    // only the escalating stages are suppressed. The rider can arm it mid-trip
    // from the Active Trip screen, and stages then fire from the next fix.
    // Stages fire ONE AT A TIME, in order, and distance alone can never reach
    // Stage 3.
    //
    // stageFor() returns the HIGHEST stage a distance qualifies for, and this
    // used to fire that stage directly. A first fix already inside the
    // Stage-2 or Stage-3 radius therefore opened on "Get Ready" or a
    // full-screen "WAKE UP" and the gentler stages never played at all — the
    // "minsan dumidiretso sa 3, minsan sa 2" report.
    //
    // Capping eligibility at 2 restores Figure 28, where Stage 3 has NO
    // distance trigger: it activates only when the commuter "remains
    // unresponsive after Stage 2, or upon the third snooze". Distance escalates
    // to Stage 2; time and snoozes carry it to Stage 3.
    final byDistance = engine.stageFor(distanceM);
    final eligible = byDistance >= 2 ? 2 : byDistance;
    if (t.alarmEnabled && eligible > highestStage) {
      _fireStage(highestStage + 1);
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

  /// Human-readable trip state for the home-screen widget.
  String get _homeWidgetStatus => switch (phase) {
        TripPhase.monitoring => 'Monitoring',
        TripPhase.alarmStage1 ||
        TripPhase.alarmStage2 ||
        TripPhase.alarmStage3 =>
          'Approaching stop',
        TripPhase.overshootPrompt ||
        TripPhase.overshootConfirmed =>
          'Overshoot',
        TripPhase.arrived => 'Arrived',
        TripPhase.ended => 'No active trip',
      };

  /// Pushes trip state to the home-screen App Widget. Throttled to ~15s during
  /// steady monitoring (a RemoteViews rebuild is far heavier than a state
  /// change), but [force] bypasses the throttle for lifecycle events — trip
  /// start, each alarm stage, and trip end — so those land immediately.
  void _pushHomeWidget({bool force = false}) {
    final t = trip;
    if (t == null) return;
    final now = DateTime.now();
    if (!force &&
        _lastHomeWidgetPush != null &&
        now.difference(_lastHomeWidgetPush!) < const Duration(seconds: 15)) {
      return;
    }
    _lastHomeWidgetPush = now;
    // Fire-and-forget: the widget is a convenience surface and must never
    // block or fault the monitoring loop.
    _homeWidget.showTrip(
      destination: t.destinationLabel,
      distanceM: distanceM,
      etaMinutes: etaMinutes,
      status: _homeWidgetStatus,
    );
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
    _pushHomeWidget(force: true);
    _scheduleEscalation(stage);
  }

  /// Figures 27–28: Stage 2 fires when Stage 1 is not dismissed within
  /// 30 seconds; Stage 3 when the rider remains unresponsive after Stage 2.
  void _scheduleEscalation(int fromStage) {
    _cancelEscalation();
    if (fromStage >= 3) return;
    _escalationTimer = Timer(_escalationDelayFrom(fromStage), () {
      final expectedPhase =
          fromStage == 1 ? TripPhase.alarmStage1 : TripPhase.alarmStage2;
      if (phase == expectedPhase) _fireStage(fromStage + 1);
    });
  }

  /// 30 s normally; [catchUpEscalationDelay] while the sequence is behind the
  /// distance. "Behind" means the commuter is already at least one radius
  /// closer than the stage now showing: past the Stage-2 radius while Stage 1
  /// is up, or inside the arrival radius while Stage 2 is up.
  Duration _escalationDelayFrom(int fromStage) {
    final engine = _engine;
    if (engine == null) return stageEscalationDelay;
    final byDistance = engine.stageFor(distanceM);
    final behind = fromStage == 1 ? byDistance >= 2 : byDistance >= 3;
    return behind ? catchUpEscalationDelay : stageEscalationDelay;
  }

  /// The trip reached its destination while the commuter was following it.
  ///
  /// Ticks off whatever guide steps remain — the last one is a synthetic walk
  /// that cannot complete itself (see [GuideProgress.completeAll]) — then ends
  /// the trip as arrived. Silence and timers are stood down first so nothing
  /// can fire against a trip that is already over.
  Future<void> _arriveAtDestination() async {
    _cancelEscalation();
    try {
      await _sound.stopAll();
    } catch (e) {
      debugPrint('NavAlert: could not silence on arrival — $e');
    }
    guide.completeAll();
    await _endTrip('arrived');
    phase = TripPhase.arrived;
    _pushHomeWidget(force: true);
    notifyListeners();
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
    // return, otherwise a drowsy commuter who taps Snooze once is never
    // warned again.
    //
    // It returns ONE STAGE LOUDER than the one snoozed: snoozing Stage 1 brings
    // back Stage 2, snoozing Stage 2 brings back Stage 3. Re-firing the same
    // stage let a commuter sit at the gentlest alert indefinitely while the
    // vehicle kept moving, which is the opposite of an escalating alarm. This
    // is the same direction of travel as the existing third-snooze rule above.
    if (snoozedStage > 0) {
      final nextStage = (snoozedStage + 1).clamp(1, 3);
      _snoozeTimer = Timer(stageEscalationDelay, () {
        if (phase == TripPhase.monitoring && isActive) {
          _fireStage(nextStage);
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
    // DO NOT MODIFY LOGIC: the audit row is secondary; acknowledging the
    // overshoot is what the rider is waiting on. This write was unguarded and
    // sat between the phase change and _endTrip, so a storage failure meant
    // "Yes" appeared to do nothing at all — the trip never ended and
    // notifyListeners never ran, leaving the rider stuck on the overshoot
    // prompt exactly like the Slide-to-Stop trap.
    try {
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
    } catch (e) {
      debugPrint('NavAlert: could not record the overshoot event — $e');
    }
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
        error = 'Google Maps unavailable - destination coordinates '
            'copied to clipboard.';
        notifyListeners();
      }
    }
  }

  /// DO NOT MODIFY LOGIC: stopping MUST always succeed. Slide-to-Stop is the
  /// only way off this screen — PopScope blocks Back by design — so anything
  /// that throws in here strands the rider in a trip they cannot end. Every
  /// step is isolated and the phase is set in a finally, so the trip ends even
  /// if the audio, the notification or the database misbehaves.
  Future<void> stopTrip() async {
    try {
      _cancelEscalation();
      // Same rule as dismissAlarm: silence first so a storage error can never
      // leave the rider stuck with an alarm they cannot stop.
      await _sound.stopAll();
      await _recordReaction();
      await _endTrip(highestStage > 0 ? 'arrived' : 'cancelled');
    } catch (e) {
      debugPrint('NavAlert: stopTrip cleanup failed — $e');
    } finally {
      phase = TripPhase.ended;
      notifyListeners();
    }
  }

  Future<void> closeSummary() async {
    phase = TripPhase.ended;
    notifyListeners();
  }

  /// Cancels the GPS subscription, the signal watchdog, and every alarm timer.
  /// The single teardown path shared by _endTrip, startTrip's re-entrancy
  /// guard, and dispose, so no orphaned listener can survive any of them.
  Future<void> _teardownMonitoring() async {
    // Isolated: a failing stream cancel must not stop the timers being killed,
    // or monitoring keeps running after the trip is over.
    try {
      await _sub?.cancel();
    } catch (e) {
      debugPrint('NavAlert: GPS unsubscribe failed — $e');
    }
    _sub = null;
    _signalWatchdog?.cancel();
    _signalWatchdog = null;
    _cancelEscalation();
  }

  Future<void> _endTrip(String status) async {
    await _teardownMonitoring();
    // Platform calls, so they CAN throw (a plugin channel error is enough).
    // Unguarded, this threw before the trip was marked ended, which is what
    // left Slide-to-Stop dead and the rider stuck on the trip screen.
    try {
      await _lockWidget.cancel();
    } catch (e) {
      debugPrint('NavAlert: could not clear the trip notification — $e');
    }
    _homeWidget.showIdle();
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
