import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../services/fake_call_screen_service.dart';
import '../services/sos_service.dart';
import '../services/sound_service.dart';

/// Emergency ViewModel (Use Cases UC-7 Trigger SOS Alert and
/// UC-8 Activate Fake Call).
class EmergencyViewModel extends ChangeNotifier {
  final _sos = SosService();
  final _recorder = AudioRecorder();

  EmergencyViewModel() {
    // A queued SOS resolves minutes later, long after fireSos() returned.
    // Report the outcome either way — especially the failure, so the rider
    // stops waiting on an SMS that was never delivered and can Call 911.
    _sos.onQueuedSosResolved = (delivered, count) {
      statusMessage = delivered
          ? 'Signal restored — SOS sent to $count '
              'contact${count == 1 ? '' : 's'}.'
          : 'SOS could NOT be sent — still no cellular signal after several '
              'attempts. Use Call 911 if you are in danger.';
      notifyListeners();
    };
  }

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

  /// Proactively secures the SEND_SMS permission BEFORE any emergency, so
  /// the SOS button is always armed and the permission dialog never appears
  /// mid-crisis on the safety-critical path (R8). Called when the rider
  /// first opens the Emergency tab. No-op once granted.
  Future<void> ensureSmsReady() async {
    if (!await Permission.sms.isGranted) {
      await Permission.sms.request();
    }
  }

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
  /// [callerName] is shown on the lock-screen call UI, so it must match the
  /// name the in-app screen displays (Table 21, default 'Mom').
  Future<void> startFakeCall({String callerName = 'Mom'}) async {
    fakeCallActive = true;
    fakeCallAnswered = false;
    notifyListeners();
    // UC-8 Exception 2 — raise the call over the keyguard so the shortcut
    // works with the phone locked, not only with NavAlert already open.
    await FakeCallScreenService.instance.present(callerName);
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
    // Drop the notification and stop NavAlert rendering over the lock screen.
    await FakeCallScreenService.instance.dismiss();
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
