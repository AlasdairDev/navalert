import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio_cache_interceptor/dio_cache_interceptor.dart';
import 'package:flutter/foundation.dart';

/// A [CacheStore] that keeps map tiles on DISK, so they survive a cold boot.
///
/// The paper requires the map to keep working where there is poor or no signal.
/// A memory cache cannot do that: it dies with the process, so a commuter who
/// force-closes the app in a dead zone loses every tile they had already
/// loaded. This store writes them to the device instead.
///
/// Written by hand because there is no packaged option: the official
/// `dio_cache_interceptor_file_store` is still pinned to
/// dio_cache_interceptor ^3.x while `flutter_map_cache` 2.x requires ^4.0.0,
/// and the older `flutter_map_cache` 1.x needs flutter_map ^6 against this
/// project's ^7. The two cannot meet, so the store is implemented here.
///
/// ## On-disk format
/// One file per entry, named from a hash of the cache key:
///
/// ```
/// [4 bytes, big-endian: metadata length N][N bytes: JSON metadata][body bytes]
/// ```
///
/// Metadata is JSON so the format stays inspectable; the body stays raw so a
/// PNG is not inflated by ~33% through base64.
///
/// ## Crash safety
/// Every write goes to a `.tmp` file and is then `rename`d into place. Rename
/// is atomic within a filesystem, so a kill mid-write leaves either the old
/// entry or the new one — never half of either. A torn file that does slip
/// through (storage corruption, a truncated `.tmp` promoted by something else)
/// is detected on read and deleted rather than served as a tile.
class TileCacheStore extends CacheStore {
  TileCacheStore(this.directoryPath, {this.maxBytes = defaultMaxBytes});

  /// Directory that holds the cache. Created on first use.
  final String directoryPath;

  /// Ceiling for the cache. Once exceeded, the oldest entries are evicted
  /// until the total is back under [_lowWaterFraction] of this.
  ///
  /// 64 MB holds a few thousand OSM tiles — the NCR corridors a commuter
  /// actually travels — while staying a rounding error against a modern
  /// phone's storage. The cache must never grow without bound: it is a
  /// convenience, and it is not the user's photo library.
  final int maxBytes;

  /// 64 MB.
  static const int defaultMaxBytes = 64 * 1024 * 1024;

  /// Evicting exactly to the limit would re-trigger on the very next write.
  /// Dropping to 80% amortises eviction over many writes instead.
  static const double _lowWaterFraction = 0.8;

  static const String entrySuffix = '.tile';
  static const String tempSuffix = '.tmp';

  Directory get _dir => Directory(directoryPath);

  /// filename → entry bookkeeping. Avoids stat-ing the directory on every
  /// read and gives eviction a total size without touching the disk.
  final Map<String, _IndexEntry> _index = {};

  /// Monotonic write counter. Eviction order within a session is therefore
  /// exact, rather than depending on filesystem mtime resolution (which is
  /// only one second on some filesystems and would make "oldest" ambiguous
  /// for tiles written in the same burst).
  int _seq = 0;

  int _totalBytes = 0;
  Future<void>? _initing;

  /// Scans the directory once, rebuilding the index and sweeping anything a
  /// previous crash left behind.
  Future<void> _ensureInit() {
    return _initing ??= () async {
      try {
        if (!await _dir.exists()) {
          await _dir.create(recursive: true);
          return;
        }
        final found = <_ScanResult>[];
        await for (final e in _dir.list(followLinks: false)) {
          if (e is! File) continue;
          if (e.path.endsWith(tempSuffix)) {
            // A write that never completed. Nothing references it.
            await _quietDelete(e);
            continue;
          }
          if (!e.path.endsWith(entrySuffix)) continue;
          try {
            final stat = await e.stat();
            found.add(_ScanResult(_basename(e.path), stat.size, stat.modified));
          } catch (_) {/* vanished mid-scan — ignore */}
        }
        // Restore a plausible write order across restarts. Within a session
        // the counter below keeps it exact.
        found.sort((a, b) => a.modified.compareTo(b.modified));
        for (final f in found) {
          _index[f.name] = _IndexEntry(size: f.size, seq: _seq++);
          _totalBytes += f.size;
        }
      } catch (e) {
        debugPrint('NavAlert: tile cache init failed — $e');
      }
    }();
  }

  static String _basename(String path) =>
      path.replaceAll('\\', '/').split('/').last;

  /// FNV-1a 64. Cache keys are URLs or opaque tokens containing `/`, `?`, `:`
  /// and `..` — none of which are safe as filenames, and `..` in particular
  /// must never be able to walk out of the cache directory. Hashing makes the
  /// name fixed-length and inert.
  ///
  /// A collision would return the wrong tile, so the full key is stored in the
  /// metadata and re-checked on read; a mismatch is treated as a miss.
  static String _fileNameFor(String key) {
    var hash = 0xcbf29ce484222325;
    for (final b in utf8.encode(key)) {
      hash ^= b;
      hash = hash * 0x100000001b3;
    }
    // Emitted as two UNSIGNED 32-bit halves rather than one toRadixString on
    // the 64-bit value. Dart ints are signed, and `toUnsigned(64)` cannot
    // widen a 64-bit value, so a negative hash formatted as-is produces names
    // like "-1f36cc7a.tile". Those work through Dart's File API but are read
    // as a flag by shell tooling (`rm`, `find`), making the cache directory
    // hostile to inspect or clean up by hand. Splitting keeps all 64 bits and
    // is always 16 plain hex characters.
    final hi = (hash >> 32).toUnsigned(32);
    final lo = hash.toUnsigned(32);
    return '${hi.toRadixString(16).padLeft(8, '0')}'
        '${lo.toRadixString(16).padLeft(8, '0')}$entrySuffix';
  }

  File _fileFor(String key) => File('$directoryPath/${_fileNameFor(key)}');

  Future<void> _quietDelete(FileSystemEntity f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {/* best effort */}
  }

  // ── serialisation ────────────────────────────────────────────────────────

  static Map<String, dynamic> _toMeta(CacheResponse r) => {
        'key': r.key,
        'url': r.url,
        'statusCode': r.statusCode,
        'cacheControl': r.cacheControl.toHeader(),
        'date': r.date?.toIso8601String(),
        'eTag': r.eTag,
        'expires': r.expires?.toIso8601String(),
        'lastModified': r.lastModified,
        'maxStale': r.maxStale?.toIso8601String(),
        'priority': r.priority.index,
        'requestDate': r.requestDate.toIso8601String(),
        'responseDate': r.responseDate.toIso8601String(),
        // Headers are small; base64 keeps them inside the JSON envelope so the
        // body can stay a raw byte run.
        'headers': r.headers == null ? null : base64Encode(r.headers!),
      };

  static CacheResponse _fromMeta(Map<String, dynamic> m, List<int>? body) {
    DateTime? date(String k) {
      final v = m[k];
      return v == null ? null : DateTime.parse(v as String);
    }

    final priorityIndex = m['priority'] as int? ?? CachePriority.normal.index;
    return CacheResponse(
      cacheControl: CacheControl.fromString(m['cacheControl'] as String?),
      content: body,
      date: date('date'),
      eTag: m['eTag'] as String?,
      expires: date('expires'),
      headers: m['headers'] == null
          ? null
          : base64Decode(m['headers'] as String),
      key: m['key'] as String,
      lastModified: m['lastModified'] as String?,
      maxStale: date('maxStale'),
      priority: CachePriority
          .values[priorityIndex.clamp(0, CachePriority.values.length - 1)],
      requestDate: date('requestDate') ?? DateTime.now(),
      responseDate: date('responseDate') ?? DateTime.now(),
      url: m['url'] as String? ?? '',
      statusCode: m['statusCode'] as int? ?? 200,
    );
  }

  /// Reads and parses one entry, or null when it is absent or unreadable.
  /// A corrupt entry is deleted: serving half a PNG as a map tile is worse
  /// than a cache miss, and leaving it there would fail on every future read.
  Future<CacheResponse?> _read(String key, {bool wantBody = true}) async {
    await _ensureInit();
    final file = _fileFor(key);
    Uint8List bytes;
    try {
      if (!await file.exists()) return null;
      bytes = await file.readAsBytes();
    } catch (_) {
      return null;
    }
    try {
      if (bytes.length < 4) throw const FormatException('truncated header');
      final metaLen = ByteData.sublistView(bytes, 0, 4).getUint32(0);
      if (metaLen <= 0 || 4 + metaLen > bytes.length) {
        throw const FormatException('metadata length past end of file');
      }
      final meta = jsonDecode(utf8.decode(bytes.sublist(4, 4 + metaLen)))
          as Map<String, dynamic>;
      // Hash collision: the file is a real entry, just not this key's.
      if (meta['key'] != key) return null;
      final body = wantBody ? bytes.sublist(4 + metaLen) : null;
      return _fromMeta(meta, body);
    } catch (e) {
      debugPrint('NavAlert: dropping corrupt tile cache entry — $e');
      await _forget(file);
      return null;
    }
  }

  /// Removes a file and its bookkeeping together, so the index can never
  /// disagree with the disk about how much is stored.
  Future<void> _forget(File file) async {
    final name = _basename(file.path);
    final entry = _index.remove(name);
    if (entry != null) _totalBytes -= entry.size;
    await _quietDelete(file);
  }

  // ── CacheStore ───────────────────────────────────────────────────────────

  @override
  Future<void> set(CacheResponse response) async {
    await _ensureInit();
    final meta = utf8.encode(jsonEncode(_toMeta(response)));
    final body = response.content ?? const <int>[];
    final header = ByteData(4)..setUint32(0, meta.length);
    final payload = BytesBuilder(copy: false)
      ..add(header.buffer.asUint8List())
      ..add(meta)
      ..add(body);
    final bytes = payload.takeBytes();

    // A single entry that cannot fit under the ceiling would force eviction of
    // everything else and still not fit. Skip it rather than empty the cache.
    if (bytes.length > maxBytes) return;

    final name = _fileNameFor(response.key);
    final target = File('$directoryPath/$name');
    final temp = File('$directoryPath/$name$tempSuffix');
    try {
      await temp.writeAsBytes(bytes, flush: true);
      // Atomic within a filesystem: readers see the old entry or the new one.
      await temp.rename(target.path);
    } catch (e) {
      debugPrint('NavAlert: tile cache write failed — $e');
      await _quietDelete(temp);
      return;
    }

    final previous = _index[name];
    if (previous != null) _totalBytes -= previous.size;
    _index[name] = _IndexEntry(size: bytes.length, seq: _seq++);
    _totalBytes += bytes.length;

    await _evictIfNeeded();
  }

  /// Drops the oldest entries until the cache is back under the low-water
  /// mark. Oldest-first is right for map tiles: the ones a rider is furthest
  /// from in time are the ones they are least likely to need again.
  Future<void> _evictIfNeeded() async {
    if (_totalBytes <= maxBytes) return;
    final target = (maxBytes * _lowWaterFraction).floor();
    final byAge = _index.entries.toList()
      ..sort((a, b) => a.value.seq.compareTo(b.value.seq));
    for (final e in byAge) {
      if (_totalBytes <= target) break;
      await _forget(File('$directoryPath/${e.key}'));
    }
  }

  @override
  Future<CacheResponse?> get(String key) => _read(key);

  @override
  Future<bool> exists(String key) async {
    await _ensureInit();
    if (!_index.containsKey(_fileNameFor(key))) return false;
    // Confirm it is really this key's entry, not a colliding one.
    return await _read(key, wantBody: false) != null;
  }

  @override
  Future<void> delete(String key, {bool staleOnly = false}) async {
    await _ensureInit();
    if (staleOnly) {
      final existing = await _read(key, wantBody: false);
      if (existing == null || !existing.isStaled()) return;
    }
    await _forget(_fileFor(key));
  }

  @override
  Future<List<CacheResponse>> getFromPath(
    RegExp pathPattern, {
    Map<String, String?>? queryParams,
  }) async {
    final out = <CacheResponse>[];
    await _forEachEntry((response, _) async {
      if (pathExists(response.url, pathPattern, queryParams: queryParams)) {
        out.add(response);
      }
    });
    return out;
  }

  @override
  Future<void> deleteFromPath(
    RegExp pathPattern, {
    Map<String, String?>? queryParams,
  }) async {
    await _forEachEntry((response, file) async {
      if (pathExists(response.url, pathPattern, queryParams: queryParams)) {
        await _forget(file);
      }
    });
  }

  @override
  Future<void> clean({
    CachePriority priorityOrBelow = CachePriority.high,
    bool staleOnly = false,
  }) async {
    await _forEachEntry((response, file) async {
      final lowEnough = response.priority.index <= priorityOrBelow.index;
      final removable = lowEnough && (!staleOnly || response.isStaled());
      if (removable) await _forget(file);
    });
  }

  /// Walks every readable entry. Iterates a SNAPSHOT of the index because the
  /// visitor is allowed to delete, which mutates it.
  Future<void> _forEachEntry(
    Future<void> Function(CacheResponse response, File file) visit,
  ) async {
    await _ensureInit();
    for (final name in _index.keys.toList()) {
      final file = File('$directoryPath/$name');
      final response = await _readFile(file);
      if (response == null) continue;
      await visit(response, file);
    }
  }

  /// Parses a file directly, for the whole-cache walks where the key is not
  /// known up front (so [_read]'s key check cannot be used).
  Future<CacheResponse?> _readFile(File file) async {
    try {
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.length < 4) throw const FormatException('truncated header');
      final metaLen = ByteData.sublistView(bytes, 0, 4).getUint32(0);
      if (metaLen <= 0 || 4 + metaLen > bytes.length) {
        throw const FormatException('metadata length past end of file');
      }
      final meta = jsonDecode(utf8.decode(bytes.sublist(4, 4 + metaLen)))
          as Map<String, dynamic>;
      return _fromMeta(meta, bytes.sublist(4 + metaLen));
    } catch (e) {
      debugPrint('NavAlert: dropping corrupt tile cache entry — $e');
      await _forget(file);
      return null;
    }
  }

  @override
  Future<void> close() async {
    // Nothing is held open — every read and write opens and closes its own
    // handle, which is what makes a mid-session kill survivable.
  }

  /// Bytes currently stored. Exposed so the cache can be asserted on and
  /// surfaced, rather than being an invisible consumer of the user's storage.
  Future<int> currentSizeBytes() async {
    await _ensureInit();
    return _totalBytes;
  }
}

class _IndexEntry {
  const _IndexEntry({required this.size, required this.seq});
  final int size;
  final int seq;
}

class _ScanResult {
  const _ScanResult(this.name, this.size, this.modified);
  final String name;
  final int size;
  final DateTime modified;
}
