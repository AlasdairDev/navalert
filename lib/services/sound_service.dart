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

  Future<void> playAlarmStage(int stage, String soundName,
      {bool vibrationOnly = false}) async {
    await _configure();
    switch (stage) {
      case 1:
        await Vibration.vibrate(duration: 700);
        break;
      case 2:
        Vibration.vibrate(pattern: [0, 500, 250, 500, 250, 800], repeat: 0);
        if (!vibrationOnly) await _loopSound(soundName, volume: 0.7);
        break;
      case 3:
        Vibration.vibrate(pattern: [0, 1000, 150, 1000, 150, 1500], repeat: 0);
        if (!vibrationOnly) await _loopSound(soundName, volume: 1.0);
        break;
    }
  }

  Future<void> _loopSound(String soundName, {required double volume}) async {
    final asset = alarmCatalog[soundName] ?? alarmCatalog.values.first;
    await _alarmPlayer.stop();
    await _alarmPlayer.setReleaseMode(ReleaseMode.loop);
    await _alarmPlayer.play(AssetSource(asset), volume: volume);
  }

  Future<void> previewAlarm(String soundName) async {
    await _configure();
    final asset = alarmCatalog[soundName] ?? alarmCatalog.values.first;
    await _alarmPlayer.stop();
    await _alarmPlayer.setReleaseMode(ReleaseMode.release);
    await _alarmPlayer.play(AssetSource(asset), volume: 0.8);
  }

  /// Fake-call ringtone + voice playback (Requirement R7).
  Future<void> playRingtone() async {
    await _voicePlayer.stop();
    await _voicePlayer.setReleaseMode(ReleaseMode.loop);
    await _voicePlayer.play(AssetSource('sounds/ringtone.wav'), volume: 1.0);
    Vibration.vibrate(pattern: [0, 900, 600, 900, 600, 900], repeat: 0);
  }

  Future<void> playVoice(String filePath) async {
    await _voicePlayer.stop();
    await Vibration.cancel();
    await _voicePlayer.setReleaseMode(ReleaseMode.loop);
    if (filePath.startsWith('assets/')) {
      await _voicePlayer
          .play(AssetSource(filePath.replaceFirst('assets/', '')), volume: 1.0);
    } else if (File(filePath).existsSync()) {
      await _voicePlayer.play(DeviceFileSource(filePath), volume: 1.0);
    }
  }

  Future<void> stopVoice() async {
    await _voicePlayer.stop();
    await Vibration.cancel();
  }

  Future<void> stopAll() async {
    await _alarmPlayer.stop();
    await _voicePlayer.stop();
    await Vibration.cancel();
  }
}
