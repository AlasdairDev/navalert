import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/models.dart';

/// Destination search using the free Nominatim API over OpenStreetMap
/// (Specific Objective 6). Results are biased to Metro Manila.
class GeocodingService {
  static const _base = 'https://nominatim.openstreetmap.org/search';
  static const _reverseBase = 'https://nominatim.openstreetmap.org/reverse';
  // Nominatim usage policy requires an identifying User-Agent.
  static const _headers = {
    'User-Agent': 'NavAlert-Capstone/1.0 (PUP BSIT; contact: navalert@pup.edu.ph)'
  };

  /// Most results the rider is shown. Over-fetching and trimming locally is
  /// deliberate — see [_rank].
  static const int maxResults = 5;

  /// Returns at most [maxResults] places, ranked locally.
  ///
  /// DO NOT MODIFY LOGIC: Nominatim orders by its own "importance" score, which
  /// surfaces large distant landmarks above the small nearby place the rider
  /// actually typed — the reported "too many irrelevant results". We over-fetch
  /// and re-rank instead of trusting that order. [nearLat]/[nearLng] are the
  /// rider's position and MUST be null when the position is a fallback, or the
  /// list gets sorted around a location they are nowhere near.
  Future<List<PlaceResult>> search(String query,
      {double? nearLat, double? nearLng}) async {
    if (query.trim().isEmpty) return [];
    final uri = Uri.parse(_base).replace(queryParameters: {
      'q': query,
      'format': 'jsonv2',
      // Over-fetch, then rank locally down to maxResults. Still one API call,
      // so this costs nothing against the Nominatim usage policy.
      'limit': '10',
      'countrycodes': 'ph',
      // NCR viewbox (lon,lat), aligned to RouteEngine's NCR bounds so search,
      // map panning and pin validation all share one region definition.
      // bounded:1 makes this a HARD limit, not a soft bias — the app routes
      // NCR only (Scope and Limitations), so a Baguio result would be a dead
      // end. Previously '0', which let out-of-region addresses through.
      'viewbox': '120.88,14.82,121.18,14.30',
      'bounded': '1',
      'addressdetails': '0',
    });
    final res = await http.get(uri, headers: _headers).timeout(
          const Duration(seconds: 12),
        );
    if (res.statusCode != 200) {
      throw Exception('Nominatim error ${res.statusCode}');
    }
    final list = jsonDecode(res.body) as List<dynamic>;
    // DO NOT MODIFY LOGIC: parse defensively. double.parse THROWS on anything
    // unexpected, and one malformed entry used to take down the whole search
    // with a FormatException instead of simply being skipped — the rider would
    // see a failed search rather than the results that did parse.
    final results = <PlaceResult>[];
    for (final e in list) {
      if (e is! Map<String, dynamic>) continue;
      final lat = double.tryParse('${e['lat']}');
      final lng = double.tryParse('${e['lon']}');
      if (lat == null || lng == null) continue;
      final display = e['display_name'] as String? ?? '';
      final name = (e['name'] as String?)?.isNotEmpty == true
          ? e['name'] as String
          : (display.isEmpty ? 'Unnamed place' : display.split(',').first);
      results.add(PlaceResult(
          name: name, displayName: display, lat: lat, lng: lng));
    }
    _rank(results, query, nearLat, nearLng);
    return results.length <= maxResults
        ? results
        : results.sublist(0, maxResults);
  }

  /// Sorts in place: better text match first, then nearer to the rider.
  ///
  /// The score is deliberately coarse and totally ordered so the sort is stable
  /// and predictable: 0 = the place name starts with what was typed, 1 = the
  /// name contains it, 2 = only the full address contains it, 3 = no textual
  /// match at all (Nominatim matched on something we are not showing).
  static void _rank(
      List<PlaceResult> results, String query, double? lat, double? lng) {
    final q = query.trim().toLowerCase();

    int textScore(PlaceResult p) {
      final name = p.name.toLowerCase();
      if (name.startsWith(q)) return 0;
      if (name.contains(q)) return 1;
      if (p.displayName.toLowerCase().contains(q)) return 2;
      return 3;
    }

    // Squared degree distance. Real haversine is unnecessary to ORDER
    // candidates that are all inside one metro region, and this avoids the
    // trig on every comparison.
    double proximity(PlaceResult p) {
      if (lat == null || lng == null) return 0;
      final dLat = p.lat - lat;
      final dLng = p.lng - lng;
      return dLat * dLat + dLng * dLng;
    }

    results.sort((a, b) {
      final byText = textScore(a).compareTo(textScore(b));
      if (byText != 0) return byText;
      return proximity(a).compareTo(proximity(b));
    });
  }

  /// Reverse-geocodes coordinates into a precise street address
  /// (Nominatim /reverse) so "Current Location" can show the actual
  /// place the commuter is standing at.
  Future<String?> reverse(double lat, double lng) async {
    final uri = Uri.parse(_reverseBase).replace(queryParameters: {
      'lat': '$lat',
      'lon': '$lng',
      'format': 'jsonv2',
      'zoom': '18', // building level — the most precise reverse result
      'addressdetails': '0',
    });
    final res = await http.get(uri, headers: _headers).timeout(
          const Duration(seconds: 10),
        );
    if (res.statusCode != 200) return null;
    final m = jsonDecode(res.body) as Map<String, dynamic>;
    return m['display_name'] as String?;
  }
}
