import 'dart:async';

import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../data/database_service.dart';
import '../data/models.dart';

/// Emergency SOS (Requirement R8, Specific Objective 4 — UC-7).
///
/// Sends the commuter's exact GPS coordinates + timestamp to up to three
/// pre-saved emergency contacts through **Native Android SMS** (SmsManager
/// via a platform channel) — no mobile data or internet required.
///
/// UC-7 Exception 1: when no cellular signal is available the message is
/// queued and retried in the background until it can be dispatched.
class SosService {
  static const _channel = MethodChannel('navalert/sms');
  static const _uuid = Uuid();

  Timer? _retryTimer;
  int _retriesLeft = 0;
  List<EmergencyContact> _queuedContacts = [];
  String _queuedMessage = '';
  String? _queuedSosId;

  /// Returns the number of contacts the SOS was dispatched to.
  Future<int> triggerSos({String? tripId}) async {
    final contacts = await DatabaseService.instance.getContacts();
    if (contacts.isEmpty) {
      throw StateError('No emergency contacts saved.');
    }

    Position? pos;
    try {
      pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
    } catch (_) {
      // UC-7 Exception 2: fall back to the last known cached location.
      pos = await Geolocator.getLastKnownPosition();
    }

    final lat = pos?.latitude;
    final lng = pos?.longitude;
    final stamp = DateTime.now();
    final locText = lat == null
        ? 'Location unavailable (Real-time GPS lost)'
        : 'Location: $lat, $lng\nhttps://maps.google.com/?q=$lat,$lng';
    final message = 'NAVALERT SOS — I need help!\n'
        '$locText\n'
        'Time: ${stamp.toLocal().toString().substring(0, 16)}';

    var sent = 0;
    for (final c in contacts.take(3)) {
      if (await _sendNativeSms(c.phoneNumber, message)) sent++;
    }

    final sosId = _uuid.v4();
    await DatabaseService.instance.insertSosEvent({
      'sos_id': sosId,
      'trip_id': tripId,
      'triggered_location_label': null,
      'triggered_lat': lat ?? 0,
      'triggered_lng': lng ?? 0,
      'contacts_notified_count': sent,
      'call_911_pressed': 0,
      'status': sent > 0 ? 'active' : 'queued',
      'triggered_at': stamp.toIso8601String(),
    });

    // Queue-and-retry when nothing went out (UC-7 Exception 1).
    if (sent == 0) {
      _queueRetry(sosId, contacts.take(3).toList(), message);
      // Also offer the SMS composer as an immediate manual fallback.
      final to = contacts.map((c) => c.phoneNumber).join(';');
      final uri = Uri(
          scheme: 'smsto', path: to, queryParameters: {'body': message});
      if (await canLaunchUrl(uri)) await launchUrl(uri);
    }
    return sent;
  }

  void _queueRetry(
      String sosId, List<EmergencyContact> contacts, String message) {
    _queuedSosId = sosId;
    _queuedContacts = contacts;
    _queuedMessage = message;
    _retriesLeft = 5;
    _retryTimer?.cancel();
    _retryTimer = Timer.periodic(const Duration(seconds: 30), (t) async {
      if (_retriesLeft-- <= 0) {
        t.cancel();
        return;
      }
      var sent = 0;
      for (final c in _queuedContacts) {
        if (await _sendNativeSms(c.phoneNumber, _queuedMessage)) sent++;
      }
      if (sent > 0) {
        t.cancel();
        await (await DatabaseService.instance.db).update(
          'sos_events',
          {'contacts_notified_count': sent, 'status': 'active'},
          where: 'sos_id = ?',
          whereArgs: [_queuedSosId],
        );
      }
    });
  }

  Future<bool> _sendNativeSms(String phone, String message) async {
    try {
      final ok = await _channel.invokeMethod<bool>(
          'sendSms', {'phone': phone, 'message': message});
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Figure 32 — "Call 911". Recorded in sos_events.call_911_pressed
  /// (Data Dictionary Table 27).
  Future<void> call911() async {
    Position? pos;
    try {
      pos = await Geolocator.getLastKnownPosition();
    } catch (_) {}
    await DatabaseService.instance.insertSosEvent({
      'sos_id': _uuid.v4(),
      'trip_id': null,
      'triggered_location_label': null,
      'triggered_lat': pos?.latitude ?? 0,
      'triggered_lng': pos?.longitude ?? 0,
      'contacts_notified_count': 0,
      'call_911_pressed': 1,
      'status': 'active',
      'triggered_at': DateTime.now().toIso8601String(),
    });
    final uri = Uri(scheme: 'tel', path: '911');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  Future<List<EmergencyContact>> contacts() =>
      DatabaseService.instance.getContacts();
}
