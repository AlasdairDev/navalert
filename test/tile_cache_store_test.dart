import 'dart:convert';
import 'dart:io';

import 'package:dio_cache_interceptor/dio_cache_interceptor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navalert/services/tile_cache_store.dart';

/// The paper requires the map to work in areas with poor or no signal. An
/// in-memory cache dies with the process, so a commuter who force-closes the
/// app in a dead zone loses every tile. [TileCacheStore] persists them to disk.
///
/// These tests run against a REAL temporary directory — no mocked filesystem —
/// because the whole point of this class is what survives on disk.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('navalert_tiles_test');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  /// A tile-sized cache entry. [bytes] pads the body so eviction can be tested
  /// with predictable sizes.
  CacheResponse tile(
    String key, {
    int bytes = 32,
    DateTime? maxStale,
    CachePriority priority = CachePriority.normal,
    String url = 'https://tile.openstreetmap.org/16/1/2.png',
  }) {
    final now = DateTime.now();
    return CacheResponse(
      cacheControl: CacheControl(maxAge: 3600, privacy: 'public'),
      content: List<int>.filled(bytes, 7),
      date: now,
      eTag: 'etag-$key',
      expires: now.add(const Duration(days: 1)),
      headers: utf8.encode('{"content-type":["image/png"]}'),
      key: key,
      lastModified: 'Mon, 03 Aug 2026 12:00:00 GMT',
      maxStale: maxStale,
      priority: priority,
      requestDate: now.subtract(const Duration(milliseconds: 200)),
      responseDate: now,
      url: url,
      statusCode: 200,
    );
  }

  group('round trip', () {
    test('stores and returns every field it was given', () async {
      final store = TileCacheStore(dir.path);
      final original = tile('tile-a');
      await store.set(original);

      final read = await store.get('tile-a');
      expect(read, isNotNull);
      expect(read!.key, original.key);
      expect(read.url, original.url);
      expect(read.statusCode, original.statusCode);
      expect(read.content, original.content);
      expect(read.headers, original.headers);
      expect(read.eTag, original.eTag);
      expect(read.lastModified, original.lastModified);
      expect(read.priority, original.priority);
      expect(read.cacheControl.maxAge, original.cacheControl.maxAge);
      expect(read.cacheControl.privacy, original.cacheControl.privacy);
      // Dates round trip to the millisecond, not to the microsecond.
      expect(read.responseDate.millisecondsSinceEpoch,
          original.responseDate.millisecondsSinceEpoch);
      expect(read.expires!.millisecondsSinceEpoch,
          original.expires!.millisecondsSinceEpoch);
    });

    test('an unknown key is a miss, not an error', () async {
      final store = TileCacheStore(dir.path);
      expect(await store.get('never-written'), isNull);
      expect(await store.exists('never-written'), isFalse);
    });

    test('exists tracks writes and deletes', () async {
      final store = TileCacheStore(dir.path);
      await store.set(tile('tile-b'));
      expect(await store.exists('tile-b'), isTrue);
      await store.delete('tile-b');
      expect(await store.exists('tile-b'), isFalse);
      expect(await store.get('tile-b'), isNull);
    });
  });

  group('persistence — the offline requirement', () {
    test('tiles survive a brand-new store over the same directory', () async {
      final first = TileCacheStore(dir.path);
      await first.set(tile('survivor', bytes: 64));
      await first.close();

      // A cold boot: nothing carried over in memory, only what is on disk.
      final second = TileCacheStore(dir.path);
      final read = await second.get('survivor');

      expect(read, isNotNull,
          reason: 'a tile written before a restart must still be readable '
              'after one — this is the whole offline requirement');
      expect(read!.content, List<int>.filled(64, 7));
      expect(read.url, 'https://tile.openstreetmap.org/16/1/2.png');
    });

    test('many tiles all survive, and are counted after the reopen', () async {
      final first = TileCacheStore(dir.path);
      for (var i = 0; i < 12; i++) {
        await first.set(tile('t$i', bytes: 100));
      }
      await first.close();

      final second = TileCacheStore(dir.path);
      for (var i = 0; i < 12; i++) {
        expect(await second.get('t$i'), isNotNull, reason: 't$i was lost');
      }
      // The reopened store must know how big it already is, or eviction would
      // never fire again after a restart.
      expect(await second.currentSizeBytes(), greaterThanOrEqualTo(1200));
    });
  });

  group('eviction keeps the cache bounded', () {
    test('stays under the byte budget as tiles are added', () async {
      // Budget fits roughly 10 x 1000-byte tiles.
      final store = TileCacheStore(dir.path, maxBytes: 10000);
      for (var i = 0; i < 40; i++) {
        await store.set(tile('big$i', bytes: 1000));
      }
      expect(await store.currentSizeBytes(), lessThanOrEqualTo(10000),
          reason: 'the cache must not grow without bound');
    });

    test('evicts the oldest and keeps the newest', () async {
      final store = TileCacheStore(dir.path, maxBytes: 6000);
      for (var i = 0; i < 20; i++) {
        await store.set(tile('seq$i', bytes: 1000));
      }
      // The most recent write must still be there; the very first must not.
      expect(await store.get('seq19'), isNotNull,
          reason: 'the newest tile was evicted');
      expect(await store.get('seq0'), isNull,
          reason: 'the oldest tile should have been evicted first');
    });

    test('an entry larger than the whole budget is simply not stored',
        () async {
      final store = TileCacheStore(dir.path, maxBytes: 500);
      await store.set(tile('huge', bytes: 5000));
      expect(await store.get('huge'), isNull);
      expect(await store.currentSizeBytes(), lessThanOrEqualTo(500));
    });
  });

  group('corruption and partial writes', () {
    test('a truncated file reads as a miss and is cleaned up', () async {
      final store = TileCacheStore(dir.path);
      await store.set(tile('torn', bytes: 200));

      // Simulate a write interrupted by a kill: chop the file in half.
      final f = dir
          .listSync()
          .whereType<File>()
          .firstWhere((f) => f.path.endsWith(TileCacheStore.entrySuffix));
      final bytes = await f.readAsBytes();
      await f.writeAsBytes(bytes.sublist(0, bytes.length ~/ 2), flush: true);

      expect(await store.get('torn'), isNull,
          reason: 'a half-written entry must not be returned as a tile');
      expect(f.existsSync(), isFalse,
          reason: 'the corrupt entry should be removed, not left to rot');
    });

    test('garbage in the directory does not break the store', () async {
      File('${dir.path}/not-a-tile.txt').writeAsStringSync('hello');
      File('${dir.path}/half.${TileCacheStore.entrySuffix}')
          .writeAsBytesSync([0, 0, 0]);

      final store = TileCacheStore(dir.path);
      // Must still function normally.
      await store.set(tile('ok'));
      expect(await store.get('ok'), isNotNull);
    });

    test('a leftover temp file is ignored and swept', () async {
      final tmp = File('${dir.path}/orphan${TileCacheStore.tempSuffix}');
      tmp.writeAsBytesSync(List<int>.filled(50, 1));

      final store = TileCacheStore(dir.path);
      await store.set(tile('after-crash'));
      expect(await store.get('after-crash'), isNotNull);
      expect(tmp.existsSync(), isFalse,
          reason: 'orphaned temp files from a crashed write must be swept');
    });
  });

  group('deletion and cleaning', () {
    test('staleOnly delete spares a fresh entry', () async {
      final store = TileCacheStore(dir.path);
      await store.set(tile('fresh',
          maxStale: DateTime.now().add(const Duration(days: 1))));
      await store.delete('fresh', staleOnly: true);
      expect(await store.get('fresh'), isNotNull);
    });

    test('staleOnly delete removes an expired entry', () async {
      final store = TileCacheStore(dir.path);
      await store.set(tile('old',
          maxStale: DateTime.now().subtract(const Duration(days: 1))));
      await store.delete('old', staleOnly: true);
      expect(await store.get('old'), isNull);
    });

    test('clean empties the cache', () async {
      final store = TileCacheStore(dir.path);
      await store.set(tile('x'));
      await store.set(tile('y'));
      await store.clean();
      expect(await store.get('x'), isNull);
      expect(await store.get('y'), isNull);
      expect(await store.currentSizeBytes(), 0);
    });

    test('clean staleOnly keeps what is still fresh', () async {
      final store = TileCacheStore(dir.path);
      await store.set(tile('keep',
          maxStale: DateTime.now().add(const Duration(days: 1))));
      await store.set(tile('drop',
          maxStale: DateTime.now().subtract(const Duration(days: 1))));
      await store.clean(staleOnly: true);
      expect(await store.get('keep'), isNotNull);
      expect(await store.get('drop'), isNull);
    });

    test('clean respects a priority ceiling', () async {
      final store = TileCacheStore(dir.path);
      await store.set(tile('lo', priority: CachePriority.low));
      await store.set(tile('hi', priority: CachePriority.high));
      await store.clean(priorityOrBelow: CachePriority.low);
      expect(await store.get('lo'), isNull);
      expect(await store.get('hi'), isNotNull);
    });
  });

  group('path queries', () {
    test('getFromPath returns only entries whose url matches', () async {
      final store = TileCacheStore(dir.path);
      await store.set(tile('a', url: 'https://tile.openstreetmap.org/16/1/2.png'));
      await store.set(tile('b', url: 'https://example.com/other.png'));

      final found = await store.getFromPath(
          RegExp(r'https://tile\.openstreetmap\.org/.*'));
      expect(found.map((e) => e.key), contains('a'));
      expect(found.map((e) => e.key), isNot(contains('b')));
    });

    test('deleteFromPath removes only matching entries', () async {
      final store = TileCacheStore(dir.path);
      await store.set(tile('a', url: 'https://tile.openstreetmap.org/16/1/2.png'));
      await store.set(tile('b', url: 'https://example.com/other.png'));

      await store.deleteFromPath(
          RegExp(r'https://tile\.openstreetmap\.org/.*'));
      expect(await store.get('a'), isNull);
      expect(await store.get('b'), isNotNull);
    });
  });

  group('key safety', () {
    test('entry filenames are plain hex, never leading "-"', () async {
      final store = TileCacheStore(dir.path);
      // Enough keys that a negative 64-bit hash is near-certain.
      for (var i = 0; i < 60; i++) {
        await store.set(tile('https://tile.openstreetmap.org/16/$i/$i.png'));
      }
      final names = dir
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((n) => n.endsWith(TileCacheStore.entrySuffix))
          .toList();
      expect(names, isNotEmpty);
      for (final n in names) {
        expect(n, matches(RegExp(r'^[0-9a-f]{16}\.tile$')),
            reason: 'a name starting with "-" is read as a flag by shell '
                'tooling (rm, find), which makes the cache dir hostile to '
                'maintain and inspect');
      }
    });

    test('keys with filesystem-hostile characters round trip', () async {
      final store = TileCacheStore(dir.path);
      const nasty = 'https://x/y?a=1&b=2/../..\\z:*?"<>|';
      await store.set(tile(nasty));
      final read = await store.get(nasty);
      expect(read, isNotNull);
      expect(read!.key, nasty);
      // Nothing may escape the cache directory.
      expect(dir.listSync().whereType<File>().every((f) =>
          File(f.path).parent.resolveSymbolicLinksSync() ==
          dir.resolveSymbolicLinksSync()), isTrue);
    });
  });
}
