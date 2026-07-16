import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:uuid/uuid.dart';

import '../data/database_service.dart';
import '../data/models.dart';
import '../services/geocoding_service.dart';
import '../services/route_engine.dart';

/// Home / destination-search / commute-guide ViewModel
/// (Use Case UC-4 — Search & Set Destination and View Commute Guide).
class HomeViewModel extends ChangeNotifier {
  final _geocoder = GeocodingService();
  final _routeEngine = RouteEngine();
  final _db = DatabaseService.instance;
  static const _uuid = Uuid();

  // Current location
  double? currentLat;
  double? currentLng;

  // Search state
  bool searching = false;
  String? searchError;
  List<PlaceResult> results = [];

  // Selected destination + planned trip
  PlaceResult? destination;
  Trip? plannedTrip;
  List<RouteSuggestion> suggestions = [];
  RouteSuggestion? selectedSuggestion;

  Future<void> refreshCurrentLocation() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      currentLat = pos.latitude;
      currentLng = pos.longitude;
    } catch (_) {
      final last = await Geolocator.getLastKnownPosition();
      // Default to PUP Sta. Mesa if no fix is available yet.
      currentLat = last?.latitude ?? 14.5979;
      currentLng = last?.longitude ?? 121.0108;
    }
    notifyListeners();
  }

  Future<void> search(String query) async {
    searching = true;
    searchError = null;
    notifyListeners();
    try {
      results = await _geocoder.search(query);
      if (results.isEmpty) {
        searchError = 'No results — refine your search or pin on the map.';
      }
    } catch (_) {
      searchError =
          'Network error — the commute guide needs an internet connection.';
      results = [];
    }
    searching = false;
    notifyListeners();
  }

  /// Locks the drop-off point and creates a configured trip with
  /// generated route suggestions honouring the mode priority.
  Future<void> setDestination(
      PlaceResult place, TransportPreferences prefs) async {
    destination = place;
    if (currentLat == null) await refreshCurrentLocation();

    final distanceKm = _routeEngine.haversineKm(
        currentLat!, currentLng!, place.lat, place.lng);

    final trip = Trip(
      tripId: _uuid.v4(),
      originLabel: 'Current Location',
      originLat: currentLat!,
      originLng: currentLng!,
      destinationLabel: place.name,
      destinationLat: place.lat,
      destinationLng: place.lng,
      distanceKm: double.parse(distanceKm.toStringAsFixed(2)),
    );
    await _db.insertTrip(trip);

    suggestions = _routeEngine.buildSuggestions(
      tripId: trip.tripId,
      originLabel: 'Current Location',
      destinationLabel: place.displayName,
      distanceKm: distanceKm,
      prefs: prefs,
    );
    for (final s in suggestions) {
      await _db.insertSuggestion(s);
    }
    selectedSuggestion = suggestions.isEmpty ? null : suggestions.first;
    plannedTrip = trip;
    notifyListeners();
  }

  /// Re-generates suggestions after the rider changes mode priority.
  Future<void> regenerateSuggestions(TransportPreferences prefs) async {
    final trip = plannedTrip;
    final place = destination;
    if (trip == null || place == null) return;
    suggestions = _routeEngine.buildSuggestions(
      tripId: trip.tripId,
      originLabel: trip.originLabel,
      destinationLabel: place.displayName,
      distanceKm: trip.distanceKm,
      prefs: prefs,
    );
    for (final s in suggestions) {
      await _db.insertSuggestion(s);
    }
    selectedSuggestion = suggestions.isEmpty ? null : suggestions.first;
    notifyListeners();
  }

  void selectSuggestion(RouteSuggestion s) {
    selectedSuggestion = s;
    plannedTrip?.selectedRouteSuggestionId = s.suggestionId;
    plannedTrip?.etaMinutes = s.totalDurationMinutes;
    notifyListeners();
  }

  void clearPlan() {
    destination = null;
    plannedTrip = null;
    suggestions = [];
    selectedSuggestion = null;
    results = [];
    notifyListeners();
  }
}
