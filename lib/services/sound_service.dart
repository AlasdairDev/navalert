import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
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

  /// DO NOT MODIFY LOGIC: earphone-only alarm routing (the paper's "Bluetooth /
  /// ear-phone only detection" toggle). Set from UserSettings.bluetoothEnabled
  /// by AppViewModel. When true AND a headset is connected, the alarm is routed
  /// through the earphones (USAGE_MEDIA) instead of the loud PUV speaker
  /// (USAGE_ALARM) — quiet and non-disruptive in a crowded vehicle. When it is
  /// false, or no headset is present, it falls back to the speaker.
  bool earphoneOnlyAlarm = false;

  /// Queries the native AudioManager for a connected headset (wired/BT/USB).
  static const _routeChannel = MethodChannel('navalert/audioroute');
  Future<bool> _isHeadsetConnected() async {
    try {
      return await _routeChannel.invokeMethod<bool>('isHeadsetConnected') ??
          false;
    } catch (_) {
      return false; // channel not ready / non-Android — assume speaker.
    }
  }

  /// Read-only public view of the same native query, for UI that needs to SHOW
  /// the headset state rather than route audio with it — the Main Screen's
  /// "Earphones connected" pill (GUI Page 8, the visible half of the paper's
  /// "Bluetooth / ear-phone only detection" toggle).
  ///
  /// Deliberately a thin delegate: the alarm's route stays owned exclusively by
  /// [_applyAlarmRoute], so a UI read can never change where the alarm plays.
  Future<bool> isHeadsetConnected() => _isHeadsetConnected();

  /// Tracks the last audio-context routing applied so we only re-apply it when
  /// the earphone/speaker decision actually flips. null forces the first apply.
  bool? _lastEarphoneRoute;

  /// DO NOT MODIFY LOGIC: Batch 2 fix for "alarm triggers visually but makes no
  /// sound". Tells the native MediaButtonService to pause its silent keep-alive
  /// AudioTrack while an alarm or ringtone is playing, then resume it after.
  /// The keep-alive (which holds the volume-shortcut session's priority) was
  /// occupying the media audio path and suppressing the alarm sound. Every
  /// play* path must _yieldAudio(true) before playing and every stop* must
  /// _yieldAudio(false) after — drop either half and the alarm goes silent
  /// again or the volume shortcuts lose priority.
  static const _yieldChannel = MethodChannel('navalert/audioyield');
  Future<void> _yieldAudio(bool active) async {
    try {
      await _yieldChannel.invokeMethod('setAlarmActive', active);
    } catch (_) {/* channel not ready / non-Android — ignore */}
  }

  static const Map<String, String> alarmCatalog = {
    'Digital Clock': 'sounds/digital_clock.wav',
    'Siren': 'sounds/siren.wav',
    'Buzzer': 'sounds/buzzer.wav',
    'Bell': 'sounds/bell.wav',
    'Air Horn': 'sounds/air_horn.wav',
  };

  /// DO NOT MODIFY LOGIC: decides the alarm's audio route. If earphone-only
  /// routing is enabled AND a headset is connected, the alarm plays on the
  /// MEDIA usage (which the OS routes to the earphones); otherwise it plays on
  /// the ALARM usage (the loud speaker channel). Re-applies the audio context
  /// only when the decision flips, so a mid-trip headset unplug on the next
  /// stage escalation correctly falls back to the speaker.
  Future<void> _applyAlarmRoute() async {
    final earphone = earphoneOnlyAlarm && await _isHeadsetConnected();
    if (_lastEarphoneRoute == earphone) return;
    try {
      await _alarmPlayer.setAudioContext(AudioContext(
        android: AudioContextAndroid(
          usageType:
              earphone ? AndroidUsageType.media : AndroidUsageType.alarm,
          audioFocus: AndroidAudioFocus.gainTransient,
          contentType: earphone
              ? AndroidContentType.music
              : AndroidContentType.sonification,
        ),
      ));
      _lastEarphoneRoute = earphone;
    } catch (_) {/* non-Android or unsupported — play on default channel */}
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
    // Free the audio path from the shortcut keep-alive so the alarm is audible.
    await _yieldAudio(true);
    await _applyAlarmRoute();
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

  /// Every OTHER play* path wraps its player calls; this one did not, and it is
  /// the only one invoked fire-and-forget (the Settings and Trip-Settings sound
  /// dropdowns do not await it). An unplayable asset therefore surfaced as an
  /// UNHANDLED async error — a red frame in front of the panel — rather than
  /// simply not previewing. A preview is cosmetic; it must never be louder than
  /// the failure it is reporting.
  Future<void> previewAlarm(String soundName) async {
    await _yieldAudio(true);
    await _applyAlarmRoute();
    final asset = alarmCatalog[soundName] ?? alarmCatalog.values.first;
    try {
      await _alarmPlayer.stop();
      await _alarmPlayer.setReleaseMode(ReleaseMode.release);
      await _alarmPlayer.play(AssetSource(asset), volume: 0.8);
    } catch (_) {/* unplayable asset — silently skip the preview */}
  }

  /// Fake-call ringtone + voice playback (Requirement R7).
  /// UC-8 Exception 1 — audio must never block the fake call. If the media
  /// player fails, the caller still shows the incoming-call interface and the
  /// rider keeps their visual excuse to leave; only the sound is lost. These
  /// methods therefore swallow playback errors instead of throwing, and still
  /// attempt the vibration that mimics an incoming call.
  /// DO NOT MODIFY LOGIC: the voice player had NO audio context, so it fell
  /// back to audioplayers' default, which requests PERMANENT audio focus
  /// (AndroidAudioFocus.gain). Negotiating that against whatever else holds
  /// focus is what made a tapped recording sit silent and then start playing on
  /// its own a while later. gainTransient is both the correct semantic for a
  /// call-like sound and released cleanly on stop; speech content type keeps it
  /// on the speaker rather than the earpiece.
  bool _voiceConfigured = false;
  Future<void> _configureVoice() async {
    if (_voiceConfigured) return;
    try {
      await _voicePlayer.setAudioContext(AudioContext(
        android: const AudioContextAndroid(
          usageType: AndroidUsageType.media,
          contentType: AndroidContentType.speech,
          audioFocus: AndroidAudioFocus.gainTransient,
        ),
      ));
    } catch (_) {/* non-Android or unsupported — default context is fine */}
    _voiceConfigured = true;
  }

  Future<void> playRingtone() async {
    await _yieldAudio(true);
    await _configureVoice();
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
    // DO NOT MODIFY LOGIC: like every other play* path, free the media output
    // from the shortcut keep-alive AudioTrack first — without this the built-in
    // Mom/Dad voice (and any recording) plays silently, because the always-on
    // volume-shortcut session still occupies the audio path.
    await _yieldAudio(true);
    await _configureVoice();
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
    await _yieldAudio(false); // fake call ended — restore shortcut keep-alive
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
    await _yieldAudio(false); // alarm ended — restore the shortcut keep-alive
  }
}
