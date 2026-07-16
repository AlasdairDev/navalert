import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/models.dart';

/// Destination search using the free Nominatim API over OpenStreetMap
/// (Specific Objective 6). Results are biased to Metro Manila.
class GeocodingService {
  static const _base = 'https://nominatim.openstreetmap.org/search';
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
      // Metro Manila viewbox (lon,lat top-left → lon,lat bottom-right)
      'viewbox': '120.90,14.80,121.15,14.35',
      'bounded': '0',
      'addressdetails': '0',
    });
    final res = await http.get(uri, headers: _headers).timeout(
          const Duration(seconds: 12),
        );
    if (res.statusCode != 200) {
      throw Exception('Nominatim error ${res.statusCode}');
    }
    final list = jsonDecode(res.body) as List<dynamic>;
    return list.map((e) {
      final m = e as Map<String, dynamic>;
      final display = m['display_name'] as String? ?? '';
      final name = (m['name'] as String?)?.isNotEmpty == true
          ? m['name'] as String
          : display.split(',').first;
      return PlaceResult(
        name: name,
        displayName: display,
        lat: double.parse(m['lat'] as String),
        lng: double.parse(m['lon'] as String),
      );
    }).toList();
  }
}
