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
  int _attemptsMade = 0;
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
    //
    // DO NOT MODIFY LOGIC: the request MUST be time-boxed. This is the primary
    // R8 path and it runs from the volume shortcut with the SCREEN OFF, where
    // Android cannot show a permission dialog at all — the future can simply
    // never complete. triggerSos would then never return, so the `finally` in
    // EmergencyViewModel.fireSos that clears `sending` never runs, and because
    // `sending` is ALSO the in-flight guard the SOS button is dead for the rest
    // of the session while the ring reads "SENDING…" forever. The onboarding
    // flow already time-boxes this very call for the far less critical case of
    // not blocking Continue; the emergency path needs it more, not less.
    // Proceeding unpermitted is safe: the native send simply fails and the
    // queue-and-retry below (UC-7 Exception 1) takes over.
    try {
      if (!await Permission.sms.isGranted
          .timeout(const Duration(seconds: 5))) {
        await Permission.sms.request().timeout(const Duration(seconds: 10));
      }
    } catch (_) {/* denied, stalled, or headless — send anyway, then queue */}

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
    // Cleared per trigger so a stale reason from an earlier SOS can never be
    // reported against this one.
    lastFailureReason = null;
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

  /// Fast attempts made before backing off, INCLUDING the initial send in
  /// [triggerSos]. So: send, then two 30-second retries.
  static const int fastAttempts = 3;
  static const Duration fastRetryGap = Duration(seconds: 30);

  /// Back-off gap once the fast attempts are exhausted. Retrying continues at
  /// this interval until the SMS is delivered.
  static const Duration slowRetryGap = Duration(minutes: 15);

  /// Fired once when the fast attempts fail and the SOS drops into slow retry.
  ///
  /// DO NOT MODIFY LOGIC: because slow retry never gives up, the "SOS could NOT
  /// be sent" message can no longer fire — so without this the rider would sit
  /// in silence believing help is on the way. They must be told delivery is
  /// still pending so they can Call 911 instead of waiting.
  void Function(int attemptsMade)? onSosRetryBackoff;

  /// UC-7 Exception 1 — queue and retry when no SMS could be dispatched.
  ///
  /// DO NOT MODIFY LOGIC: [fastAttempts] quick tries, then a [slowRetryGap]
  /// retry that continues UNTIL DELIVERED. There is deliberately no give-up
  /// path: a queued SOS that quietly expires is the worst outcome for this
  /// feature. The timer is cancelled by [dispose] and by a successful send.
  void _queueRetry(
      String sosId, List<EmergencyContact> contacts, String message) {
    _queuedSosId = sosId;
    _queuedContacts = contacts;
    _queuedMessage = message;
    // The initial send in triggerSos already counted as attempt 1.
    _attemptsMade = 1;
    _retryTimer?.cancel();
    _scheduleRetry(fastRetryGap);
  }

  void _scheduleRetry(Duration gap) {
    _retryTimer?.cancel();
    // One-shot rather than periodic: the gap CHANGES once the fast attempts run
    // out, and a periodic timer cannot switch its own interval.
    _retryTimer = Timer(gap, _attemptRetry);
  }

  Future<void> _attemptRetry() async {
    var sent = 0;
    for (final c in _queuedContacts) {
      if (await _sendNativeSms(c.phoneNumber, _queuedMessage)) sent++;
    }
    _attemptsMade++;

    if (sent > 0) {
      _retryTimer?.cancel();
      _retryTimer = null;
      await _markQueuedSos('active', sent);
      onQueuedSosResolved?.call(true, sent);
      return;
    }

    if (_attemptsMade == fastAttempts) {
      // Fast attempts exhausted — tell the rider once, then back off.
      onSosRetryBackoff?.call(_attemptsMade);
    }
    _scheduleRetry(
        _attemptsMade < fastAttempts ? fastRetryGap : slowRetryGap);
  }

  /// DO NOT MODIFY LOGIC: stops the queued-SOS retry. The timer fires every
  /// 30 s for minutes and calls [onQueuedSosResolved], which notifies the
  /// EmergencyViewModel — if that has been disposed in the meantime, the
  /// callback notifies a dead listener and throws. Cancel the retry with it.
  void dispose() {
    _retryTimer?.cancel();
    _retryTimer = null;
    onQueuedSosResolved = null;
    // The slow retry runs every 15 minutes indefinitely, so this callback would
    // outlive the ViewModel by far longer than the old 30-second one. Clear it
    // with the others or it notifies a disposed listener.
    onSosRetryBackoff = null;
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

  /// Why the most recent send attempt failed, in words the rider can act on.
  /// Null when the last attempt succeeded or none has run.
  ///
  /// DO NOT MODIFY LOGIC: this exists because "it did not send" and "it did not
  /// send BECAUSE the permission is missing" call for opposite responses from
  /// the rider — wait, versus fix it now / Call 911. Collapsing every failure
  /// into `false` (as this did) left the UI announcing "queued, will retry when
  /// a cellular signal is available" for faults that no amount of waiting fixes.
  String? lastFailureReason;

  /// Maps a native failure code to something a commuter can act on. The raw
  /// codes come from MainActivity.kt's `sendSms` handler — the first group are
  /// refusals before the message ever reached the radio, the second are what
  /// the NETWORK reported back through the sent-intent broadcast.
  static String describeFailure(String? code, String? message) {
    switch (code) {
      // ── refused locally ───────────────────────────────────────────────
      case 'PERMISSION_DENIED':
        return 'Permission Denied — allow SMS in App Info › Permissions';
      case 'INVALID_NUMBER':
        return 'Invalid contact number';
      case 'INVALID_ARGS':
        return 'Contact number or message was empty';
      case 'MissingPluginException':
        return 'SMS bridge unavailable on this build';
      // ── reported by the network ───────────────────────────────────────
      case 'NO_SERVICE':
        return 'No cellular service — move to an area with signal';
      case 'RADIO_OFF':
        return 'Phone radio is off — turn off Airplane Mode';
      case 'GENERIC_FAILURE':
        // The catch-all the radio returns for a rejected send. Insufficient
        // prepaid load is by far the most common cause in the field, and it is
        // the one the rider can actually do something about.
        return 'Network rejected the message — check your prepaid load';
      case 'NULL_PDU':
        return 'The message could not be encoded';
      case 'TIMEOUT':
        return 'No delivery confirmation from the network';
      default:
        final detail = (message == null || message.isEmpty) ? code : message;
        return detail == null || detail.isEmpty ? 'Unknown error' : detail;
    }
  }

  /// True only once the NETWORK has confirmed the message left the phone.
  ///
  /// The native side blocks on a sent-intent broadcast rather than returning as
  /// soon as SmsManager accepts the request, so this can take a second or two —
  /// and, in the pathological case where the radio never reports, up to the
  /// native 30 s timeout. That latency buys the one thing this feature cannot
  /// do without: a "sent" that means sent.
  Future<bool> _sendNativeSms(String phone, String message) async {
    try {
      final ok = await _channel.invokeMethod<bool>(
          'sendSms', {'phone': phone, 'message': message});
      if (ok ?? false) return true;
      lastFailureReason = 'The SMS was not accepted by the device';
      return false;
    } on PlatformException catch (e) {
      lastFailureReason = describeFailure(e.code, e.message);
      return false;
    } on MissingPluginException {
      lastFailureReason = describeFailure('MissingPluginException', null);
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
