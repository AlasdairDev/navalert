import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../services/sos_service.dart';
import '../services/sound_service.dart';

/// Emergency ViewModel (Use Cases UC-7 Trigger SOS Alert and
/// UC-8 Activate Fake Call).
class EmergencyViewModel extends ChangeNotifier {
  final _sos = SosService();
  final _recorder = AudioRecorder();

  // ---- SOS press-and-hold (3 s) ----
  bool holdingSos = false;
  double holdProgress = 0;
  bool sending = false;
  String? statusMessage;
  Timer? _holdTimer;

  // ---- fake call ----
  bool fakeCallActive = false;
  bool fakeCallAnswered = false;

  // ---- recorder ----
  bool recording = false;

  void beginSosHold({String? tripId, VoidCallback? onFired}) {
    holdingSos = true;
    holdProgress = 0;
    _holdTimer?.cancel();
    _holdTimer = Timer.periodic(const Duration(milliseconds: 100), (t) {
      holdProgress += 0.1 / 3.0;
      if (holdProgress >= 1) {
        t.cancel();
        holdingSos = false;
        holdProgress = 0;
        fireSos(tripId: tripId).then((_) => onFired?.call());
      }
      notifyListeners();
    });
    notifyListeners();
  }

  /// Accidental-trigger guard: releasing before 3 s cancels the SOS.
  void cancelSosHold() {
    _holdTimer?.cancel();
    holdingSos = false;
    holdProgress = 0;
    notifyListeners();
  }

  Future<void> fireSos({String? tripId}) async {
    sending = true;
    statusMessage = null;
    notifyListeners();
    try {
      final n = await _sos.triggerSos(tripId: tripId);
      statusMessage = n > 0
          ? 'SOS sent — $n contact${n == 1 ? '' : 's'} notified with your GPS location.'
          : 'SOS queued — will retry when a cellular signal is available.';
    } on StateError {
      statusMessage = 'No emergency contacts saved. Add contacts in Settings.';
    } catch (_) {
      statusMessage = 'SOS failed — check SMS permission and prepaid load.';
    }
    sending = false;
    notifyListeners();
  }

  Future<void> call911() => _sos.call911();

  // ---------- fake call (R7) ----------
  Future<void> startFakeCall() async {
    fakeCallActive = true;
    fakeCallAnswered = false;
    notifyListeners();
    await SoundService.instance.playRingtone();
  }

  Future<void> answerFakeCall(String? recordingPath) async {
    fakeCallAnswered = true;
    notifyListeners();
    if (recordingPath != null) {
      await SoundService.instance.playVoice(recordingPath);
    } else {
      await SoundService.instance.stopVoice();
    }
  }

  Future<void> endFakeCall() async {
    fakeCallActive = false;
    fakeCallAnswered = false;
    await SoundService.instance.stopVoice();
    notifyListeners();
  }

  // ---------- custom recordings ----------
  Future<bool> startRecording() async {
    if (!await _recorder.hasPermission()) return false;
    final dir = await getApplicationDocumentsDirectory();
    final path =
        '${dir.path}/recording_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(const RecordConfig(), path: path);
    recording = true;
    notifyListeners();
    return true;
  }

  /// Stops recording and returns the saved file path.
  Future<String?> stopRecording() async {
    final path = await _recorder.stop();
    recording = false;
    notifyListeners();
    return path;
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _recorder.dispose();
    super.dispose();
  }
}
