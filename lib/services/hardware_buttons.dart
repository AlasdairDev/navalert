import 'dart:async';

import 'package:flutter/services.dart';

/// Volume-button shortcuts (Specific Objective 4):
/// triple-press Volume-Up → SOS, triple-press Volume-Down → Fake Call.
/// Key events are forwarded from MainActivity through a platform channel.
class HardwareButtons {
  HardwareButtons._();
  static final HardwareButtons instance = HardwareButtons._();

  static const _channel = MethodChannel('navalert/keys');
  static const _window = Duration(milliseconds: 1600);

  final _sosController = StreamController<void>.broadcast();
  final _fakeCallController = StreamController<void>.broadcast();

  Stream<void> get onSosShortcut => _sosController.stream;
  Stream<void> get onFakeCallShortcut => _fakeCallController.stream;

  final List<DateTime> _upPresses = [];
  final List<DateTime> _downPresses = [];
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'volume') return;
      final now = DateTime.now();
      final list = call.arguments == 'up' ? _upPresses : _downPresses;
      list.add(now);
      list.removeWhere((t) => now.difference(t) > _window);
      if (list.length >= 3) {
        list.clear();
        if (call.arguments == 'up') {
          _sosController.add(null);
        } else {
          _fakeCallController.add(null);
        }
      }
    });
  }
}
