import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The database self-heals by rebuilding when its schema is incomplete
/// (DatabaseService._openOrRecover). That check is only as good as the table
/// list it compares against: a table added to the schema but forgotten in
/// _requiredTables would never be verified, so a stale database missing that
/// table would open, pass the check, and then fail every query at runtime —
/// exactly the "could not open local storage" failure the check exists to
/// prevent. This test keeps the two in step.
void main() {
  final source =
      File('lib/services/database_service.dart').readAsStringSync();

  Set<String> createdTables() => RegExp(r'CREATE TABLE (\w+)')
      .allMatches(source)
      .map((m) => m.group(1)!)
      .toSet();

  Set<String> requiredTables() {
    final block = RegExp(r'_requiredTables = \{([^}]*)\}', dotAll: true)
        .firstMatch(source)
        ?.group(1);
    expect(block, isNotNull, reason: '_requiredTables set not found');
    return RegExp(r"'(\w+)'")
        .allMatches(block!)
        .map((m) => m.group(1)!)
        .toSet();
  }

  group('schema integrity check', () {
    test('every table the schema creates is verified on open', () {
      final missing = createdTables().difference(requiredTables());
      expect(missing, isEmpty,
          reason: 'these tables are created but never checked: $missing');
    });

    test('no phantom tables are checked for', () {
      final phantom = requiredTables().difference(createdTables());
      expect(phantom, isEmpty,
          reason: 'these tables are checked but never created: $phantom');
    });

    test('covers the full Data Dictionary (13 tables)', () {
      expect(createdTables().length, 13);
    });
  });
}
