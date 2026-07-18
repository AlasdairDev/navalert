import 'dart:math' as math;

/// Core Adaptive Alarm Engine (Requirements R1–R4).
///
/// * Speed-based adaptive trigger distance — a rolling-average GPS speed ×
///   reaction window gives the Stage-1 lead radius (capped at 5 km), so the
///   alarm arms earlier on a fast bus and later in crawling traffic (R3).
/// * Behavioural learning — the rider's historical alarm reaction time
///   stretches or shrinks the reaction window (R4).
/// * Overshoot detection — consecutive increasing-distance fixes past the
///   minimum observed distance latch an overshoot (Specific Objective 2),
///   never a single noisy reading.
class AdaptiveAlarmEngine {
  AdaptiveAlarmEngine({
    this.baseReactionWindowSec = 240,
    this.arrivalRadiusM = 150,
    this.overshootThresholdM = 250,
    double? avgHistoricReactionSec,
  }) {
    _avgReactionSec = avgHistoricReactionSec;
    // Behavioural adjustment: slower dismissers get a wider window.
    if (avgHistoricReactionSec != null) {
      final adj = (avgHistoricReactionSec - 20) * 4; // 4s of lead per extra s
      reactionWindowSec =
          (baseReactionWindowSec + adj).clamp(150.0, 600.0);
    } else {
      reactionWindowSec = baseReactionWindowSec.toDouble();
    }
  }

  /// Reaction time (seconds) at or above which the alarm escalates its
  /// loudness and vibration to "High" for that rider (R4 behavioural
  /// intensity — mirrors the paper's HighIntensityReactionSeconds rule).
  static const double highIntensityReactionSec = 60;

  final int baseReactionWindowSec;
  final double arrivalRadiusM;
  final double overshootThresholdM;
  late double reactionWindowSec;
  double? _avgReactionSec;

  /// R4 — whether this rider's history warrants stronger vibration and
  /// louder alerts (a slow dismisser). Drives UC-5 "Adjust Alarm Intensity".
  bool get highIntensity =>
      (_avgReactionSec ?? 0) >= highIntensityReactionSec;

  final List<double> _speeds = <double>[]; // m/s rolling window
  double _minDistanceM = double.infinity;
  double? _lastDistanceM;
  int _increasingFixes = 0;
  bool overshootLatched = false;

  /// Rolling average speed in m/s (floor 2 m/s ≈ crawling traffic).
  double get avgSpeedMs {
    if (_speeds.isEmpty) return 4.0; // ~14 km/h default PUV speed
    final avg = _speeds.reduce((a, b) => a + b) / _speeds.length;
    return math.max(2.0, avg);
  }

  /// Stage-1 adaptive lead radius in metres, capped at 5 km (R3).
  double get stage1RadiusM =>
      math.min(5000.0, math.max(600.0, avgSpeedMs * reactionWindowSec));

  /// Stage-2 fires at half the lead radius.
  double get stage2RadiusM => math.max(300.0, stage1RadiusM * 0.5);

  /// Stage-3 (Emergency full-screen) fires at the arrival radius.
  double get stage3RadiusM => arrivalRadiusM;

  void addSpeedSample(double speedMs) {
    if (speedMs.isNaN || speedMs < 0) return;
    _speeds.add(speedMs);
    if (_speeds.length > 12) _speeds.removeAt(0);
  }

  /// Returns the alarm stage (1–3) the given distance now qualifies for,
  /// or 0 when no stage threshold has been crossed yet.
  int stageFor(double distanceM) {
    if (distanceM <= stage3RadiusM) return 3;
    if (distanceM <= stage2RadiusM) return 2;
    if (distanceM <= stage1RadiusM) return 1;
    return 0;
  }

  /// Feeds a distance fix into the overshoot detector. Returns the metres
  /// overshot when the overshoot latches on this fix, otherwise null.
  double? checkOvershoot(double distanceM, {double accuracyM = 20}) {
    if (overshootLatched) return null;
    _minDistanceM = math.min(_minDistanceM, distanceM);

    final last = _lastDistanceM;
    _lastDistanceM = distanceM;
    if (last == null) return null;

    // Jitter gate: ignore movement smaller than the fix accuracy (min 8 m).
    final gate = math.max(8.0, accuracyM);
    if (distanceM > last + gate * 0.5) {
      _increasingFixes++;
    } else if (distanceM < last) {
      _increasingFixes = 0;
    }

    final pastBy = distanceM - _minDistanceM;
    if (_increasingFixes >= 3 &&
        pastBy >= overshootThresholdM &&
        _minDistanceM < stage1RadiusM) {
      overshootLatched = true;
      return pastBy;
    }
    return null;
  }

  void reset() {
    _speeds.clear();
    _minDistanceM = double.infinity;
    _lastDistanceM = null;
    _increasingFixes = 0;
    overshootLatched = false;
  }
}
