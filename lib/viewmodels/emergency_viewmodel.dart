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
    // DO NOT MODIFY LOGIC: the slow retry never gives up, so the "could NOT be
    // sent" message below can no longer fire on its own. Without this the rider
    // would be left in silence assuming the SOS went out. Say plainly that it
    // has not, and point at Call 911.
    _sos.onSosRetryBackoff = (attempts) {
      statusIsError = true;
      final why = _sos.lastFailureReason;
      statusMessage = 'Failed: SOS not delivered after $attempts attempts'
          '${why == null ? ' — no cellular signal' : ' — $why'}. '
          'NavAlert will keep retrying every 15 minutes, but use Call 911 if '
          'you are in danger.';
      notifyListeners();
    };
    _sos.onQueuedSosResolved = (delivered, count) {
      statusIsError = !delivered;
      statusMessage = delivered
          ? 'Emergency SMS Sent — signal restored, $count '
              'contact${count == 1 ? '' : 's'} notified.'
          : 'Failed: SOS could NOT be sent after several attempts. Use Call 911 '
              'if you are in danger.';
      notifyListeners();
    };
  }

  // ---- SOS press-and-hold (3 s) ----
  bool holdingSos = false;
  bool sending = false;
  String? statusMessage;

  /// True when [statusMessage] reports a FAILURE rather than progress, so the
  /// View can colour the SnackBar accordingly instead of parsing the string.
  bool statusIsError = false;
  Timer? _holdTimer;

  /// The accidental-trigger guard (R8): how long the rider must hold.
  ///
  /// The View's ring animation is driven from this same constant, so the bar
  /// filling up and the SOS actually firing can never disagree about how long
  /// three seconds is.
  static const Duration sosHoldDuration = Duration(seconds: 3);

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

  /// DO NOT MODIFY LOGIC: the [sosHoldDuration] hold IS the accidental-trigger
  /// guard (R8) — a stray touch must never fire real SMS to every contact.
  ///
  /// This is a SINGLE timer, not the 100 ms periodic one it replaced. That old
  /// timer did double duty: it counted down AND advanced a `holdProgress`
  /// value the ring was painted from, so it rebuilt the entire Emergency screen
  /// ten times a second and still produced a visibly stepped ring. The ring is
  /// now an AnimationController in the View, repainting only itself; this timer
  /// is left with the one job that actually matters — deciding when the SOS
  /// fires.
  void beginSosHold({String? tripId, VoidCallback? onFired}) {
    holdingSos = true;
    _holdTimer?.cancel();
    _holdTimer = Timer(sosHoldDuration, () {
      holdingSos = false;
      notifyListeners();
      fireSos(tripId: tripId).then((_) => onFired?.call());
    });
    notifyListeners();
  }

  /// Accidental-trigger guard: releasing before [sosHoldDuration] cancels it.
  void cancelSosHold() {
    _holdTimer?.cancel();
    holdingSos = false;
    notifyListeners();
  }

  /// DO NOT MODIFY LOGIC: the in-flight guard. Without it a double tap (or the
  /// on-screen button racing the volume shortcut / home-widget SOS) fires the
  /// whole batch twice — duplicate SMS to every contact, and double the prepaid
  /// load, which the rider may not have. The native shortcut already enforces a
  /// cooldown for the same reason; this covers every other trigger.
  Future<void> fireSos({String? tripId}) async {
    if (sending) return;
    sending = true;
    statusMessage = null;
    // DO NOT MODIFY LOGIC: `sending` is BOTH the progress flag and the
    // in-flight guard, so it must always be released — see the finally below.
    // It was cleared on the normal path only; anything throwing before that
    // (this notify, on a disposed listener) latched it true and disabled SOS
    // for the rest of the session, silently.
    try {
      notifyListeners();
      final n = await _sos.triggerSos(tripId: tripId);
      if (n > 0) {
        statusIsError = false;
        statusMessage = 'Emergency SMS Sent — $n contact'
            '${n == 1 ? '' : 's'} notified with your GPS location.';
      } else {
        // DO NOT MODIFY LOGIC: name the ACTUAL fault. This branch used to read
        // "SOS queued — will retry when a cellular signal is available" for
        // every failure, including a missing SEND_SMS grant, which no amount of
        // retrying fixes. Telling a rider in trouble to wait for a signal that
        // was never the problem is the worst outcome this screen can produce.
        statusIsError = true;
        final why = _sos.lastFailureReason;
        statusMessage = why == null
            ? 'SOS queued — no cellular signal. Retrying in the background.'
            : 'Failed: $why. NavAlert will keep retrying — use Call 911 if you '
                'are in danger.';
      }
    } on StateError {
      statusIsError = true;
      statusMessage = 'Failed: No emergency contacts saved. Add contacts in '
          'Settings.';
    } catch (e) {
      statusIsError = true;
      statusMessage = 'Failed: $e';
    } finally {
      sending = false;
      notifyListeners();
    }
  }

  Future<void> call911() => _sos.call911();

  // ---------- fake call (R7) ----------
  /// [callerName] is shown on the lock-screen call UI, so it must match the
  /// name the in-app screen displays (Table 21, default 'Mom').
  /// Returns false when a fake call is ALREADY running, so the caller knows not
  /// to push a second call screen.
  ///
  /// DO NOT MODIFY LOGIC: the `fakeCallActive` gate is a panic-tap guard. All
  /// three entry points (the Emergency recording list, the trip screen's Fake
  /// Call button, and the triple-Volume-Down shortcut) used to push FakeCallView
  /// unconditionally, so five taps stacked five call screens over five
  /// overlapping ringtones — each needing its own dismissal, at precisely the
  /// moment the rider is trying to look calm and get out.
  Future<bool> startFakeCall({String callerName = 'Mom'}) async {
    if (fakeCallActive) return false;
    fakeCallActive = true;
    fakeCallAnswered = false;
    notifyListeners();
    // UC-8 Exception 2 — raise the call over the keyguard so the shortcut
    // works with the phone locked, not only with NavAlert already open.
    await FakeCallScreenService.instance.present(callerName);
    await SoundService.instance.playRingtone();
    return true;
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

  /// DO NOT MODIFY LOGIC: every teardown step is isolated. This is called
  /// fire-and-forget from the call screen (which pops first so the End button
  /// feels instant), so a throw here would be an unhandled async error — and
  /// worse, it would skip the remaining teardown, leaving NavAlert still
  /// drawing over the lock screen after the call was ended.
  Future<void> endFakeCall() async {
    fakeCallActive = false;
    fakeCallAnswered = false;
    try {
      await SoundService.instance.stopVoice();
    } catch (_) {}
    try {
      // Drop the notification and stop NavAlert rendering over the lock screen.
      await FakeCallScreenService.instance.dismiss();
    } catch (_) {}
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
    // Cancels the queued-SOS retry too: it would otherwise keep firing and
    // notify this disposed ViewModel.
    _sos.dispose();
    _recorder.dispose();
    super.dispose();
  }
}
