import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The two bundled GTFS assets must be regenerated TOGETHER.
///
/// `shapes.db` is keyed on the route names in `routes.json.gz`. If the feed is
/// refreshed without re-running `tool/gen_shapes.py`, names shift and every
/// shape lookup misses — and it misses SILENTLY: the map simply falls back to
/// straight lines, exactly as it did before the feature existed. Nothing on
/// screen says the offline geometry stopped working.
///
/// That is a demo-day failure with no error message, so it is caught here
/// instead. This test reads the asset files directly rather than through
/// rootBundle, so it needs no Flutter binding.
void main() {
  final routes = File('assets/gtfs/routes.json.gz');
  final shapes = File('assets/gtfs/shapes.db');

  test('both GTFS assets are present', () {
    expect(routes.existsSync(), isTrue,
        reason: 'assets/gtfs/routes.json.gz is missing');
    expect(shapes.existsSync(), isTrue,
        reason: 'assets/gtfs/shapes.db is missing — run tool/gen_shapes.py');
  });

  test('every route in the feed has road geometry', () {
    final feed = json.decode(
        utf8.decode(gzip.decode(routes.readAsBytesSync()))) as List<dynamic>;
    final feedNames = <String>{
      for (final r in feed) (r as Map<String, dynamic>)['n'] as String
    };

    // shapes.db is SQLite; names are stored as plain text, so they can be
    // found without a database engine. Reading the bytes keeps this test free
    // of a sqlite dependency while still checking the real shipped file.
    //
    // Decoded as UTF-8, not latin1: SQLite stores text as UTF-8 and several
    // route names carry Spanish characters ("Las Pinas" is spelled with an
    // n-tilde in the feed). latin1 split those into two characters and the
    // lookup missed, reporting drift that did not exist.
    final blob = shapes.readAsBytesSync();
    final text = utf8.decode(blob, allowMalformed: true);

    final missing = <String>[];
    for (final n in feedNames) {
      if (!text.contains(n)) missing.add(n);
    }

    expect(
      missing,
      isEmpty,
      reason: 'These routes exist in routes.json.gz but have no shape in '
          'shapes.db, so the map will silently fall back to straight lines '
          'for them. Re-run: python tool/gen_shapes.py --server '
          'http://127.0.0.1:5000\nFirst few: ${missing.take(5).toList()}',
    );
  });

  test('the shape database is a real, non-trivial dataset', () {
    // Guards against a partial spike file being committed by accident — a
    // 12-route database looks fine until a commuter travels anywhere else.
    expect(shapes.lengthSync(), greaterThan(500 * 1024),
        reason: 'shapes.db is suspiciously small; it may be a partial '
            '--limit/--only run rather than the full feed');
  });
}
