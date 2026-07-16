import 'dart:convert';

import 'package:http/http.dart' as http;

/// Fetches the actual road geometry between two points so the map can
/// draw the route along streets — like Google Maps — instead of a
/// straight line. Uses the free, open-source OSRM engine built on
/// OpenStreetMap data (consistent with the paper's free/open-source
/// API stack). Falls back to a straight line when offline.
class RoutePathService {
  static const _base = 'https://router.project-osrm.org/route/v1/driving';
  static const _headers = {
    'User-Agent':
        'NavAlert-Capstone/1.0 (PUP BSIT; contact: navalert@pup.edu.ph)'
  };

  /// Returns the road path as a list of [lat, lng] pairs.
  /// Throws on network failure — callers decide the fallback.
  Future<List<List<double>>> roadPath({
    required double fromLat,
    required double fromLng,
    required double toLat,
    required double toLng,
  }) async {
    final uri = Uri.parse(
        '$_base/$fromLng,$fromLat;$toLng,$toLat?overview=full&geometries=geojson');
    final res = await http
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) {
      throw Exception('OSRM error ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final routes = body['routes'] as List<dynamic>?;
    if (routes == null || routes.isEmpty) {
      throw Exception('No route found');
    }
    final coords = ((routes.first as Map<String, dynamic>)['geometry']
        as Map<String, dynamic>)['coordinates'] as List<dynamic>;
    // GeoJSON is [lng, lat] — flip to [lat, lng].
    return coords
        .map((c) => [
              (c as List<dynamic>)[1] as double,
              c[0] as double,
            ])
        .toList();
  }
}
