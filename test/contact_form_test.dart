import 'package:flutter_test/flutter_test.dart';
import 'package:navalert/views/onboarding_flow.dart';

/// Emergency Contacts setup form validation (UC-2, Figure 17).
///
/// Regression cover for the "can't save then continue" bug: a row where only
/// ONE of name/phone was filled used to be skipped silently, so Continue
/// saved nothing — and outside onboarding it then closed the screen as if it
/// had worked. A half-filled row must be an explicit, named error.
void main() {
  group('half-filled rows are an error, never silently skipped', () {
    test('name typed but phone left empty', () {
      final r = validateContactRows(['Mama', '', ''], ['', '', '']);
      expect(r.entries, isEmpty);
      expect(r.error, isNotNull);
      expect(r.error, contains('1'));
      expect(r.error!.toLowerCase(), contains('phone'));
    });

    test('phone typed but name left empty', () {
      final r = validateContactRows(['', '', ''], ['09171234567', '', '']);
      expect(r.entries, isEmpty);
      expect(r.error, isNotNull);
      expect(r.error!.toLowerCase(), contains('name'));
    });

    test('whitespace-only counts as empty', () {
      final r = validateContactRows(['   ', '', ''], ['09171234567', '', '']);
      expect(r.error, isNotNull);
    });

    test('reports the row the rider actually filled', () {
      final r = validateContactRows(['', 'Papa', ''], ['', '', '']);
      expect(r.error, contains('2'));
    });
  });

  group('valid rows are collected with their contact order', () {
    test('a single complete row', () {
      final r = validateContactRows(['Mama', '', ''], ['09171234567', '', '']);
      expect(r.error, isNull);
      expect(r.entries.length, 1);
      expect(r.entries.first.order, 1);
      expect(r.entries.first.name, 'Mama');
      expect(r.entries.first.phone, '09171234567');
    });

    test('a gap between rows keeps each row on its own order', () {
      final r = validateContactRows(
          ['Mama', '', 'Ate'], ['09171234567', '', '09181234567']);
      expect(r.error, isNull);
      expect(r.entries.map((e) => e.order), [1, 3]);
    });

    test('values are trimmed before saving', () {
      final r = validateContactRows(['  Mama  ', '', ''],
          ['  09171234567  ', '', '']);
      expect(r.entries.first.name, 'Mama');
      expect(r.entries.first.phone, '09171234567');
    });
  });

  group('phone-number validation (UC-2 Flow A)', () {
    test('accepts common Philippine formats', () {
      for (final p in [
        '09171234567',
        '+639171234567',
        '0917 123 4567',
        '0917-123-4567',
      ]) {
        final r = validateContactRows(['Mama', '', ''], [p, '', '']);
        expect(r.error, isNull, reason: '$p should be accepted');
      }
    });

    test('rejects letters and stray punctuation', () {
      for (final p in ['not a number', '(0917)1234567', '0917_123']) {
        final r = validateContactRows(['Mama', '', ''], [p, '', '']);
        expect(r.error, isNotNull, reason: '$p should be rejected');
      }
    });

    test('rejects a too-short number', () {
      final r = validateContactRows(['Mama', '', ''], ['12345', '', '']);
      expect(r.error, isNotNull);
    });
  });

  group('an entirely blank form', () {
    test('is not an error and yields nothing to save', () {
      final r = validateContactRows(['', '', ''], ['', '', '']);
      expect(r.error, isNull);
      expect(r.entries, isEmpty);
    });
  });
}
