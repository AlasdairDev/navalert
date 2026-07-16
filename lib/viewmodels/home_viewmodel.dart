import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:uuid/uuid.dart';

import '../services/database_service.dart';
import '../models/models.dart';
import '../services/geocoding_service.dart';
import '../services/route_engine.dart';
import '../services/route_path_service.dart';

/// Home / destination-search / commute-guide ViewModel
/// (Use Case UC-4 — Search & Set Destination and View Commute Guide).
class HomeViewModel extends ChangeNotifier {
  final _geocoder = GeocodingService();
  final _routeEngine = RouteEngine();
  final _routePath = RoutePathService();
  final _db = DatabaseService.instance;
  static const _uuid = Uuid();

  // Current location
  double? currentLat;
  double? currentLng;

  /// Precise reverse-geocoded street address of the current position,
  /// shown instead of the generic "Current Location" label.
  String? currentAddress;

  /// Road geometry of the planned route ([lat, lng] pairs) drawn on the
  /// map like Google Maps. Falls back to a straight origin→destination
  /// segment when the routing service is unreachable.
  List<List<double>> routePath = [];
  bool loadingPath = false;

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
      // UC-4 Exception 2 — prompt for location services/permission
      // instead of failing when they are off or denied.
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        throw const PermissionDeniedException('location');
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          timeLimit: Duration(seconds: 15),
        ),
      );
      currentLat = pos.latitude;
      currentLng = pos.longitude;
    } catch (_) {
      Position? last;
      try {
        last = await Geolocator.getLastKnownPosition();
      } catch (_) {}
      // Default to PUP Sta. Mesa if no fix is available yet.
      currentLat = last?.latitude ?? 14.5979;
      currentLng = last?.longitude ?? 121.0108;
    }
    notifyListeners();
    _reverseLookup();
  }

  /// Resolves the precise street address of the current fix in the
  /// background (non-blocking).
  Future<void> _reverseLookup() async {
    final lat = currentLat;
    final lng = currentLng;
    if (lat == null || lng == null) return;
    try {
      final addr = await _geocoder.reverse(lat, lng);
      if (addr != null && addr.isNotEmpty) {
        currentAddress = addr;
        notifyListeners();
      }
    } catch (_) {/* offline — keep the generic label */}
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
      originLabel: currentAddress ?? 'Current Location',
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

    // Fetch the real road geometry in the background (Figure 21 —
    // route drawn along streets like Google Maps).
    _fetchRoadPath(trip);
  }

  Future<void> _fetchRoadPath(Trip trip) async {
    loadingPath = true;
    routePath = [
      [trip.originLat, trip.originLng],
      [trip.destinationLat, trip.destinationLng],
    ];
    notifyListeners();
    try {
      routePath = await _routePath.roadPath(
        fromLat: trip.originLat,
        fromLng: trip.originLng,
        toLat: trip.destinationLat,
        toLng: trip.destinationLng,
      );
    } catch (_) {
      // Offline — keep the straight-line fallback.
    }
    loadingPath = false;
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
    routePath = [];
    notifyListeners();
  }
}
