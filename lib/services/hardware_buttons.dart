import 'dart:async';

import 'package:flutter/services.dart';

/// Volume-button shortcuts (Specific Objective 4, R7/R8):
/// triple-press Volume-Up → SOS, squeeze Volume-Up + Volume-Down → Fake Call.
///
/// Fake Call moved off triple-press-Volume-Down because the shortcuts are armed
/// whenever the screen is off or NavAlert is backgrounded — the normal state
/// during a commute — so ordinary volume adjustment kept launching it. Pressing
/// both directions at once cannot happen while adjusting, which only ever
/// travels one way. See `MediaButtonService.detectShortcut`.
///
/// The press detection lives natively in `MediaButtonService`, so it works
/// with the screen off and the phone in a pocket — an Activity cannot see the
/// keys in that state. This class only receives the decoded high-level event
/// ('sos' / 'fakecall') over the `navalert/keys` channel and re-emits it as a
/// stream the UI already listens to.
class HardwareButtons {
  HardwareButtons._();
  static final HardwareButtons instance = HardwareButtons._();

  static const _channel = MethodChannel('navalert/keys');

  final _sosController = StreamController<void>.broadcast();
  final _fakeCallController = StreamController<void>.broadcast();

  Stream<void> get onSosShortcut => _sosController.stream;
  Stream<void> get onFakeCallShortcut => _fakeCallController.stream;

  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'shortcut') _emit(call.arguments as String?);
    });

    // The app may have been cold-launched BY a shortcut while no Flutter engine
    // existed to receive the live call (screen off, activity killed). Pull any
    // shortcut the native side stashed, now that this listener is ready.
    try {
      _emit(await _channel.invokeMethod<String>('consumePendingShortcut'));
    } catch (_) {/* channel not ready on this platform — ignore */}
  }

  void _emit(String? type) {
    if (type == 'sos') {
      _sosController.add(null);
    } else if (type == 'fakecall') {
      _fakeCallController.add(null);
    }
  }
}
