import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navalert/services/sos_service.dart';
import 'package:navalert/viewmodels/emergency_viewmodel.dart';

/// R8 — the SOS must never fail quietly, and must never fail *early*.
///
/// Two separate risks are covered here.
///
/// **Diagnosis.** The native bridge used to answer every fault with a bare
/// `false`, so a missing SEND_SMS grant was indistinguishable from a dead
/// cell signal and the rider was told "queued — will retry when a cellular
/// signal is available." That advice is actively harmful for a permission
/// fault: no amount of waiting fixes it, and the rider waits instead of
/// pressing Call 911. [SosService.describeFailure] is the mapping that turns a
/// native failure code back into something they can act on.
///
/// **The accidental-trigger guard.** The three-second hold is what stops a
/// stray touch firing real SMS to every saved contact. Its timer was rewritten
/// (a 100 ms periodic ticker became a single one-shot, with the ring moved to
/// an AnimationController in the View), so the duration is pinned down here
/// rather than trusted.
void main() {
  // EmergencyViewModel builds an AudioRecorder in its constructor, which talks
  // to a MethodChannel — that needs a binding even in a pure Dart test.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('failure diagnosis', () {
    test('a missing permission is named, not blamed on the signal', () {
      final msg = SosService.describeFailure('PERMISSION_DENIED', null);
      expect(msg, contains('Permission Denied'));
      // The rider needs to know where to go, mid-emergency.
      expect(msg.toLowerCase(), contains('permissions'));
      expect(msg.toLowerCase(), isNot(contains('signal')),
          reason: 'a permission fault reported as a signal problem tells the '
              'rider to wait for something that will never arrive');
    });

    test('a rejected number is named', () {
      expect(SosService.describeFailure('INVALID_NUMBER', null),
          contains('Invalid contact number'));
    });

    test('empty arguments are named', () {
      expect(SosService.describeFailure('INVALID_ARGS', null),
          contains('empty'));
    });

    test('a missing native bridge is named', () {
      expect(SosService.describeFailure('MissingPluginException', null),
          contains('SMS bridge'));
    });

    // These arrive from the sent-intent broadcast — they are what the RADIO
    // said, not what the API call returned. Before delivery tracking existed
    // none of them could be observed at all: the send was reported as a success
    // the moment SmsManager accepted it.
    test('no cellular service is named and points somewhere useful', () {
      final msg = SosService.describeFailure('NO_SERVICE', null);
      expect(msg, contains('No cellular service'));
      expect(msg.toLowerCase(), contains('signal'));
    });

    test('a disabled radio names Airplane Mode', () {
      expect(SosService.describeFailure('RADIO_OFF', null),
          contains('Airplane Mode'));
    });

    test('a network rejection points at prepaid load', () {
      // GENERIC_FAILURE is the radio's catch-all, and in the field the usual
      // cause is an empty load balance — the one thing the rider can fix.
      expect(SosService.describeFailure('GENERIC_FAILURE', null),
          contains('prepaid load'));
    });

    test('a missing confirmation is not reported as success', () {
      expect(SosService.describeFailure('TIMEOUT', null),
          contains('No delivery confirmation'));
    });

    test('an unencodable message is named', () {
      expect(SosService.describeFailure('NULL_PDU', null), contains('encoded'));
    });

    test('an unmapped failure still surfaces the native message', () {
      // The point is that nothing is swallowed: an unrecognised code must
      // still reach the rider rather than collapsing to a generic failure.
      expect(SosService.describeFailure('SomeNewException', 'radio is off'),
          'radio is off');
    });

    test('an unmapped failure with no message falls back to the code', () {
      expect(SosService.describeFailure('SomeNewException', null),
          'SomeNewException');
    });

    test('a completely empty failure still says something', () {
      expect(SosService.describeFailure(null, null), 'Unknown error');
      expect(SosService.describeFailure(null, ''), 'Unknown error');
    });
  });

  group('every native failure code has a human mapping', () {
    // The exact set MainActivity.kt can emit. If a code is added there without
    // a case in describeFailure it falls through to the raw native string —
    // which is developer text, in an emergency, on a screen the rider is
    // panicking at. This is the contract between the two files.
    const nativeCodes = [
      'PERMISSION_DENIED',
      'INVALID_NUMBER',
      'INVALID_ARGS',
      'NO_SERVICE',
      'RADIO_OFF',
      'NULL_PDU',
      'GENERIC_FAILURE',
      'TIMEOUT',
      'MissingPluginException',
    ];

    test('each maps to distinct, non-technical prose', () {
      final seen = <String>{};
      for (final code in nativeCodes) {
        final msg = SosService.describeFailure(code, 'raw native detail');
        expect(msg, isNot(equals(code)),
            reason: '$code fell through to the raw code');
        expect(msg, isNot(equals('raw native detail')),
            reason: '$code fell through to the raw native message');
        expect(msg, isNot('Unknown error'), reason: '$code is unmapped');
        expect(seen.add(msg), isTrue,
            reason: '$code shares wording with another cause, so the rider '
                'cannot tell which fault they are looking at');
      }
    });

    test('a failure code is recorded alongside the prose', () {
      // The UI branches on the CODE (to raise the restricted-settings
      // walkthrough) and displays the PROSE. Both start clear.
      final sos = SosService();
      expect(sos.lastFailureCode, isNull);
      expect(sos.lastFailureReason, isNull);
    });
  });

  group('accidental-trigger guard (R8)', () {
    test('the hold is three seconds', () {
      expect(EmergencyViewModel.sosHoldDuration, const Duration(seconds: 3));
    });

    test('the hold does not complete early', () {
      fakeAsync((async) {
        final vm = EmergencyViewModel();
        vm.beginSosHold();
        expect(vm.holdingSos, isTrue);

        async.elapse(const Duration(milliseconds: 2999));
        expect(vm.holdingSos, isTrue,
            reason: 'the SOS armed before the full three seconds — the guard '
                'against a stray touch firing real SMS is short');

        vm.cancelSosHold();
        vm.dispose();
      });
    });

    test('releasing before three seconds cancels it entirely', () {
      fakeAsync((async) {
        final vm = EmergencyViewModel();
        vm.beginSosHold();
        async.elapse(const Duration(milliseconds: 2900));
        vm.cancelSosHold();
        expect(vm.holdingSos, isFalse);

        // Well past the original deadline: a cancelled hold must never fire
        // later. A one-shot timer that was stopped but not cleared would.
        async.elapse(const Duration(seconds: 30));
        expect(vm.sending, isFalse);
        expect(vm.statusMessage, isNull,
            reason: 'a released hold still sent an SOS');

        vm.dispose();
      });
    });

    test('re-holding does not stack two pending fires', () {
      fakeAsync((async) {
        final vm = EmergencyViewModel();
        vm.beginSosHold();
        async.elapse(const Duration(milliseconds: 1500));
        // Second press without releasing — the first timer must be replaced,
        // not joined by a second one that fires 1.5 s earlier.
        vm.beginSosHold();
        async.elapse(const Duration(milliseconds: 2999));
        expect(vm.holdingSos, isTrue,
            reason: 'an earlier timer survived and is still counting down');

        vm.cancelSosHold();
        vm.dispose();
      });
    });
  });
}
