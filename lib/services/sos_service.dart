import 'dart:async';

import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import 'database_service.dart';
import 'geocoding_service.dart';
import '../models/models.dart';

/// Emergency SOS (Requirement R8, Specific Objective 4 — UC-7).
///
/// Sends the commuter's location — the reverse-geocoded street address (when a
/// data signal is available) plus the exact GPS coordinates — and a timestamp
/// to up to three pre-saved emergency contacts through **Native Android SMS**
/// (SmsManager via a platform channel). The SMS itself needs no mobile data or
/// internet; only the optional address lookup does, and it is skipped silently
/// when offline so the coordinates always go out.
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

  /// Fired when a queued SOS finally gives up, and when a retry succeeds.
  /// The rider MUST learn which happened: after the retries are exhausted
  /// nothing was ever delivered, and silently leaving them believing help is
  /// on the way is the worst possible failure for this feature.
  void Function(bool delivered, int contactCount)? onQueuedSosResolved;

  /// Returns the number of contacts the SOS was dispatched to.
  Future<int> triggerSos({String? tripId}) async {
    final contacts = await DatabaseService.instance.getContacts();
    if (contacts.isEmpty) {
      throw StateError('No emergency contacts saved.');
    }

    // R8 — SmsManager needs the SEND_SMS runtime permission; without it
    // every native send throws SecurityException and the automatic SOS
    // silently degrades to the manual composer. Request it here so the
    // first SOS asks once and every later SOS is fully automatic.
    if (!await Permission.sms.isGranted) {
      await Permission.sms.request();
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
    final locText = await _buildLocationText(lat, lng);
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

    // Queue-and-retry when nothing went out (UC-7 Exception 1). We do NOT open
    // the SMS composer intent here anymore: the SOS is meant to send silently
    // in the background (screen off, from the volume shortcut), where launching
    // a composer is blocked by Android's background-activity policy and would
    // never send. Direct native SmsManager + the background retry is the whole
    // point of R8 — no user interaction required.
    if (sent == 0) {
      _queueRetry(sosId, contacts.take(3).toList(), message);
    }
    return sent;
  }

  /// Builds the location line(s) for the SOS message: the exact street address
  /// (reverse-geocoded) plus the raw coordinates, so a contact reads a real
  /// place — "Jesus Street, Pandacan, Manila" — not a link they have to open.
  ///
  /// The reverse lookup is best-effort and short-timed. SOS is offline-first
  /// (R5) and time-critical: if there is no data signal, or the lookup is slow,
  /// it is skipped silently and the coordinates still go out — they are the
  /// reliable datum and must never be delayed or lost waiting on a name.
  Future<String> _buildLocationText(double? lat, double? lng) async {
    if (lat == null || lng == null) {
      return 'Location unavailable (Real-time GPS lost)';
    }
    String? address;
    try {
      address = await GeocodingService()
          .reverse(lat, lng)
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      address = null; // no signal / slow lookup — coordinates alone still help.
    }
    final coords = 'Coordinates: $lat, $lng';
    return address == null ? coords : 'Location: $address\n$coords';
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
        // Out of attempts: record the failure and tell the rider, so they can
        // fall back to Call 911 instead of waiting on help that never left.
        await _markQueuedSos('failed', 0);
        onQueuedSosResolved?.call(false, 0);
        return;
      }
      var sent = 0;
      for (final c in _queuedContacts) {
        if (await _sendNativeSms(c.phoneNumber, _queuedMessage)) sent++;
      }
      if (sent > 0) {
        t.cancel();
        await _markQueuedSos('active', sent);
        onQueuedSosResolved?.call(true, sent);
      }
    });
  }

  /// DO NOT MODIFY LOGIC: stops the queued-SOS retry. The timer fires every
  /// 30 s for minutes and calls [onQueuedSosResolved], which notifies the
  /// EmergencyViewModel — if that has been disposed in the meantime, the
  /// callback notifies a dead listener and throws. Cancel the retry with it.
  void dispose() {
    _retryTimer?.cancel();
    _retryTimer = null;
    onQueuedSosResolved = null;
  }

  /// Storage failures are swallowed: losing the audit row must never stop the
  /// rider being told what happened to their SOS.
  Future<void> _markQueuedSos(String status, int sent) async {
    final id = _queuedSosId;
    if (id == null) return;
    try {
      await (await DatabaseService.instance.db).update(
        'sos_events',
        {
          'contacts_notified_count': sent,
          'status': status,
          if (status == 'failed') 'resolved_at': DateTime.now().toIso8601String(),
        },
        where: 'sos_id = ?',
        whereArgs: [id],
      );
    } catch (_) {}
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
