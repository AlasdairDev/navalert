import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:vibration/vibration.dart';

/// Alarm-stage audio + haptics (Requirement R1).
///
/// Stage 1 — vibration-only gentle nudge.
/// Stage 2 — stronger vibration + chosen alarm sound at raised volume.
/// Stage 3 — maximum volume on the Android ALARM channel + continuous
///           maximum-intensity vibration until Slide-to-Stop.
class SoundService {
  SoundService._();
  static final SoundService instance = SoundService._();

  final AudioPlayer _alarmPlayer = AudioPlayer();
  final AudioPlayer _voicePlayer = AudioPlayer();
  bool _configured = false;

  static const Map<String, String> alarmCatalog = {
    'Digital Clock': 'sounds/digital_clock.wav',
    'Siren': 'sounds/siren.wav',
    'Buzzer': 'sounds/buzzer.wav',
    'Bell': 'sounds/bell.wav',
    'Air Horn': 'sounds/air_horn.wav',
  };

  Future<void> _configure() async {
    if (_configured) return;
    try {
      await _alarmPlayer.setAudioContext(AudioContext(
        android: const AudioContextAndroid(
          usageType: AndroidUsageType.alarm,
          audioFocus: AndroidAudioFocus.gainTransient,
          contentType: AndroidContentType.sonification,
        ),
      ));
    } catch (_) {/* non-Android or unsupported — play on default channel */}
    _configured = true;
  }

  /// Plays the escalating stage alarm. When [highIntensity] is set — a slow
  /// dismisser per behavioural learning (R4) — Stages 1–2 use a stronger
  /// vibration pattern and a louder volume so the alert is harder to sleep
  /// through, fulfilling UC-5 "Adjust Alarm Intensity".
  /// Haptics and audio are dispatched INDEPENDENTLY: each is wrapped so a
  /// failure in one can never suppress the other. This is the wake-up path —
  /// if the vibrator is missing or the plugin throws, the rider must still get
  /// sound, and if the OS blocks alarm audio the rider must still get the
  /// continuous maximum-intensity vibration (UC-6 Exception 2 "Audio Override
  /// Blocked"). Chaining them would let one silent failure kill both.
  Future<void> playAlarmStage(int stage, String soundName,
      {bool vibrationOnly = false, bool highIntensity = false}) async {
    await _configure();
    switch (stage) {
      case 1:
        if (highIntensity) {
          _buzz(pattern: [0, 500, 250, 500]);
          if (!vibrationOnly) await _loopSound(soundName, volume: 0.55);
        } else {
          _buzz(duration: 700);
        }
        break;
      case 2:
        _buzz(
            pattern: highIntensity
                ? [0, 900, 150, 900, 150, 1200]
                : [0, 500, 250, 500, 250, 800]);
        if (!vibrationOnly) {
          await _loopSound(soundName, volume: highIntensity ? 0.9 : 0.7);
        }
        break;
      case 3:
        // Stage 3 is already maximum intensity for everyone.
        _buzz(pattern: [0, 1000, 150, 1000, 150, 1500]);
        if (!vibrationOnly) await _loopSound(soundName, volume: 1.0);
        break;
    }
  }

  /// Fire-and-forget haptics. `repeat: 0` loops the pattern continuously until
  /// stopAll(), which is the "continuous maximum-intensity vibration" fallback.
  void _buzz({List<int>? pattern, int? duration}) {
    try {
      if (pattern != null) {
        Vibration.vibrate(pattern: pattern, repeat: 0);
      } else {
        Vibration.vibrate(duration: duration ?? 700);
      }
    } catch (_) {
      // No vibrator or plugin failure — the audio below still runs.
    }
  }

  Future<void> _loopSound(String soundName, {required double volume}) async {
    final asset = alarmCatalog[soundName] ?? alarmCatalog.values.first;
    try {
      await _alarmPlayer.stop();
      await _alarmPlayer.setReleaseMode(ReleaseMode.loop);
      await _alarmPlayer.play(AssetSource(asset), volume: volume);
    } catch (_) {
      // Audio blocked/unavailable — the vibration already started above is
      // the specified fallback, so fail quietly rather than killing the alarm.
    }
  }

  Future<void> previewAlarm(String soundName) async {
    await _configure();
    final asset = alarmCatalog[soundName] ?? alarmCatalog.values.first;
    await _alarmPlayer.stop();
    await _alarmPlayer.setReleaseMode(ReleaseMode.release);
    await _alarmPlayer.play(AssetSource(asset), volume: 0.8);
  }

  /// Fake-call ringtone + voice playback (Requirement R7).
  /// UC-8 Exception 1 — audio must never block the fake call. If the media
  /// player fails, the caller still shows the incoming-call interface and the
  /// rider keeps their visual excuse to leave; only the sound is lost. These
  /// methods therefore swallow playback errors instead of throwing, and still
  /// attempt the vibration that mimics an incoming call.
  Future<void> playRingtone() async {
    try {
      await _voicePlayer.stop();
      await _voicePlayer.setReleaseMode(ReleaseMode.loop);
      await _voicePlayer.play(AssetSource('sounds/ringtone.wav'), volume: 1.0);
    } catch (_) {
      // Silent "poor connection" state — the visual illusion carries it.
    }
    try {
      Vibration.vibrate(pattern: [0, 900, 600, 900, 600, 900], repeat: 0);
    } catch (_) {}
  }

  Future<void> playVoice(String filePath) async {
    try {
      await _voicePlayer.stop();
      await Vibration.cancel();
      await _voicePlayer.setReleaseMode(ReleaseMode.loop);
      if (filePath.startsWith('assets/')) {
        await _voicePlayer.play(
            AssetSource(filePath.replaceFirst('assets/', '')), volume: 1.0);
      } else if (File(filePath).existsSync()) {
        await _voicePlayer.play(DeviceFileSource(filePath), volume: 1.0);
      }
    } catch (_) {
      // Corrupt or undecodable recording — stay on the call screen muted.
    }
  }

  Future<void> stopVoice() async {
    try {
      await _voicePlayer.stop();
    } catch (_) {}
    try {
      await Vibration.cancel();
    } catch (_) {}
  }

  /// Runs on the dismiss/stop-trip path, so each teardown step is isolated:
  /// a failing player must not leave the alarm ringing or block the trip
  /// from ending.
  Future<void> stopAll() async {
    try {
      await _alarmPlayer.stop();
    } catch (_) {}
    try {
      await _voicePlayer.stop();
    } catch (_) {}
    try {
      await Vibration.cancel();
    } catch (_) {}
  }
}
