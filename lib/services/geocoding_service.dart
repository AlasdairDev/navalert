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

  Future<List<PlaceResult>> search(String query) async {
    if (query.trim().isEmpty) return [];
    final uri = Uri.parse(_base).replace(queryParameters: {
      'q': query,
      'format': 'jsonv2',
      'limit': '6',
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
    return results;
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
