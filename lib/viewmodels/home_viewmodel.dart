import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:uuid/uuid.dart';

import '../services/database_service.dart';
import '../models/guide_leg.dart';
import '../models/models.dart';
import '../services/geocoding_service.dart';
import '../services/route_engine.dart';
import '../services/routing_isolate.dart';
import '../services/route_path_service.dart';
import '../core/geo.dart';
import '../services/route_shape_service.dart';

/// Thrown when a trip cannot be planned because the commuter's own position is
/// not actually known — only the hardcoded map-centre fallback is available.
///
/// Carries a message written for the commuter, not a stack trace: the UI shows
/// [message] verbatim, so it must name what to do (turn GPS on, drop a pin)
/// rather than describe what failed.
class UnknownOriginException implements Exception {
  const UnknownOriginException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Home / destination-search / commute-guide ViewModel
/// (Use Case UC-4 — Search & Set Destination and View Commute Guide).
class HomeViewModel extends ChangeNotifier {
  HomeViewModel({
    Stream<Position> Function(LocationSettings settings)? positionStreamFactory,
  }) : _positionStreamFactory = positionStreamFactory;

  final _geocoder = GeocodingService();
  final _routeEngine = RouteEngine();
  final _routePath = RoutePathService();
  final _db = DatabaseService.instance;
  static const _uuid = Uuid();

  /// Null in production, so live tracking uses the real
  /// `Geolocator.getPositionStream`. A test supplies a mock stream to drive the
  /// dot deterministically — same injection seam as [TripViewModel].
  final Stream<Position> Function(LocationSettings settings)?
      _positionStreamFactory;

  StreamSubscription<Position>? _liveSub;

  // DO NOT MODIFY LOGIC: almost everything here is a long async round trip —
  // a GPS fix, a Nominatim lookup, the routing isolate — and each one calls
  // notifyListeners() when it resumes. If the app is torn down while one is
  // still in flight, that resume lands on a disposed ChangeNotifier and throws
  // "A HomeViewModel was used after being disposed". Swallowing the notify
  // after dispose is the correct behaviour: there is no longer anything
  // listening, so the result has nowhere to go.
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    // Without this the GPS stream keeps delivering fixes into a dead
    // ChangeNotifier — the same "used after being disposed" fault the guard
    // above exists for, except it would repeat for the life of the process and
    // hold the location hardware awake with it.
    _liveSub?.cancel();
    _liveSub = null;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  // Current location
  double? currentLat;
  double? currentLng;

  /// Precise reverse-geocoded street address of the current position,
  /// shown instead of the generic "Current Location" label.
  String? currentAddress;

  /// Google-Maps-style short form of [currentAddress]: only the primary
  /// place name + area (first two components), fit for a single line.
  String? get currentAddressShort {
    final a = currentAddress;
    if (a == null || a.isEmpty) return null;
    final parts = a.split(',').map((p) => p.trim()).toList();
    return parts.take(2).join(', ');
  }

  /// Road geometry of the planned route ([lat, lng] pairs) drawn on the
  /// map like Google Maps. Falls back to a straight origin→destination
  /// segment when the routing service is unreachable.
  List<List<double>> routePath = [];
  bool loadingPath = false;

  /// Guide legs per suggestion id, rebuilt on each search. Memory-only.
  final Map<String, List<GuideLeg>> _legsBySuggestion = {};

  // Search state
  bool searching = false;
  String? searchError;
  List<PlaceResult> results = [];

  /// Set when the origin could not actually be measured (GPS switched off or
  /// permission denied) and the map is showing a fallback position. The View
  /// must surface this: a silently wrong origin produces a commute guide for
  /// a journey the rider is not making.
  String? locationError;

  /// Set when the trip falls outside Metro Manila, so the View can explain
  /// why no routes are listed (the alarm itself still works anywhere).
  String? guideUnavailableReason;

  /// True when the current suggestions came from the SYNTHETIC fallback (no
  /// direct GTFS route), so the UI can label them as estimates rather than
  /// implying an exact named terminal. False for real GTFS-matched routes.
  bool suggestionsAreEstimates = false;

  /// True while [currentLat]/[currentLng] hold a placeholder rather than a
  /// real fix, so callers can block trip confirmation (UC-4 Exception 2).
  bool locationIsFallback = false;

  // Selected destination + planned trip
  PlaceResult? destination;
  Trip? plannedTrip;
  List<RouteSuggestion> suggestions = [];
  RouteSuggestion? selectedSuggestion;

  /// [promptIfDisabled] controls UC-4 Exception 2's hand-off to the system
  /// location settings page. It must stay TRUE for anything the rider explicitly
  /// asked for (the locate button, picking a destination, a favourite shortcut)
  /// — there, being sent to the toggle is the expected, useful response.
  ///
  /// DO NOT MODIFY LOGIC: it must be FALSE for the unprompted first-frame
  /// acquisition on Home. That call runs the instant the tab builds, so on a
  /// fresh install with location services off the rider was ejected into
  /// Android's Settings app before ever seeing NavAlert — no explanation, no
  /// action of theirs that asked for it, and the app left sitting in the
  /// background. A background bootstrap must fall back to the banner (which
  /// already offers Retry and Settings) rather than hijack the foreground.
  Future<void> refreshCurrentLocation({bool promptIfDisabled = true}) async {
    locationError = null;
    locationIsFallback = false;
    try {
      // UC-4 Exception 2 — "Location Services Disabled". The GPS hardware
      // toggle is separate from the app permission: a rider can grant the
      // permission and still have location switched off system-wide, so both
      // must be checked. openLocationSettings() is the system prompt the use
      // case calls for.
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (!promptIfDisabled) throw const LocationServiceDisabledException();
        await Geolocator.openLocationSettings();
        if (!await Geolocator.isLocationServiceEnabled()) {
          throw const LocationServiceDisabledException();
        }
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        throw const PermissionDeniedException('location');
      }
      // Two-stage acquisition. bestForNavigation wants a real GNSS fix, which
      // frequently never arrives indoors or under a jeepney roof — on a real
      // phone that meant a timeout and a silent drop to the fallback. Fall
      // back to a coarser network/fused fix first: an approximate real position
      // is far more useful than a hardcoded one.
      // bestForNavigation is geolocator's highest accuracy; the reverse-geocoded
      // street address is only as precise as this fix. The fallback stays at
      // *high* (not medium) so even a slow-GNSS retry stays building-accurate —
      // a coarse fix would resolve to the wrong street entirely.
      var pos = await _tryFix(LocationAccuracy.bestForNavigation, 12);
      pos ??= await _tryFix(LocationAccuracy.high, 10);
      if (pos == null) throw TimeoutException('no position fix');
      currentLat = pos.latitude;
      currentLng = pos.longitude;
    } catch (e) {
      Position? last;
      try {
        last = await Geolocator.getLastKnownPosition();
      } catch (_) {}
      if (last != null) {
        // A stale fix is still the rider's own location — usable, but say so.
        currentLat = last.latitude;
        currentLng = last.longitude;
        locationIsFallback = true;
        locationError = 'Using your last known location - turn on GPS for an '
            'accurate starting point.';
      } else {
        // No fix at all. Keep the map centred somewhere sensible, but never
        // let this pass as the rider's real position: routes and fares would
        // be computed for a trip they are not taking.
        currentLat = RouteEngine.ncrCenterLat;
        currentLng = RouteEngine.ncrCenterLng;
        locationIsFallback = true;
        locationError = e is LocationServiceDisabledException
            ? 'Location is turned off. Enable GPS to set your starting point.'
            : 'Could not get your location. Check GPS and location permission.';
      }
    }
    notifyListeners();
    _reverseLookup();
  }

  // ─── R2 / UC-4: live location tracking ────────────────────────────────────
  // [refreshCurrentLocation] above takes a SNAPSHOT. That is the right shape
  // for the two moments it serves — the first-frame bootstrap and the locate
  // button — but it was the only thing that ever wrote currentLat/currentLng,
  // so the "you are here" dot was pinned to wherever the rider stood when the
  // app booted and never moved again. On the screen whose whole job is showing
  // them where they are, the marker went stale the moment they started walking.
  //
  // The stream below is what makes it follow them. It is deliberately gentler
  // than the one TripViewModel runs: this is a browsing screen, not an armed
  // trip, so it asks for `high` rather than `bestForNavigation`, filters out
  // sub-5-metre jitter, and requests no foreground-service notification or
  // wake lock. Trip monitoring keeps its own stream and its own settings —
  // nothing here touches the alarm path.

  /// Metres the rider must move before the reverse-geocoded street address is
  /// looked up again. Without a gate the address would be re-resolved on every
  /// fix, hammering Nominatim several times a second for a label that only
  /// changes street to street.
  static const double addressRefreshMetres = 200;

  double? _lastGeocodedLat;
  double? _lastGeocodedLng;

  /// True while the blue dot is following a live GPS stream.
  bool get isTrackingLive => _liveSub != null;

  /// Begins moving the map's current-location marker with the device.
  ///
  /// Safe to call repeatedly — a second subscription would double every tick
  /// and leak on dispose, so an existing one short-circuits.
  void startLiveTracking() {
    if (_liveSub != null) return;
    const settings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5,
    );
    final factory = _positionStreamFactory;
    final stream = factory != null
        ? factory(settings)
        : Geolocator.getPositionStream(
            locationSettings: _liveSettings() ?? settings);
    _liveSub = stream.listen(
      _onLiveFix,
      // Losing signal must not blank the map or crash the tab. The last real
      // position stays painted — it is still the best answer available — and
      // the subscription stays open so the dot resumes when GPS returns.
      onError: (e) => debugPrint('NavAlert: live location stream error — $e'),
      cancelOnError: false,
    );
  }

  /// Detaches the stream and releases the location hardware.
  Future<void> stopLiveTracking() async {
    final sub = _liveSub;
    _liveSub = null;
    await sub?.cancel();
  }

  /// Android wants an explicit interval; elsewhere the plain settings apply.
  /// No ForegroundNotificationConfig and no wake lock — unlike trip monitoring
  /// this must not keep the device awake or post a persistent notification just
  /// because the rider has Home open.
  LocationSettings? _liveSettings() {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    return AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5,
      intervalDuration: const Duration(seconds: 2),
    );
  }

  void _onLiveFix(Position pos) {
    currentLat = pos.latitude;
    currentLng = pos.longitude;
    // A measured fix has arrived, so the map is no longer showing a guess and
    // the "using your last known location" banner must come down. Leaving the
    // flag set would also keep search results from being ranked by distance —
    // `search()` deliberately passes null coordinates while it is true.
    locationIsFallback = false;
    locationError = null;
    notifyListeners();
    _refreshAddressIfMoved();
  }

  /// Re-resolves the street address only once the rider has actually travelled
  /// [addressRefreshMetres], so a live stream cannot turn into a geocoder flood.
  void _refreshAddressIfMoved() {
    final lat = currentLat;
    final lng = currentLng;
    if (lat == null || lng == null) return;
    final lastLat = _lastGeocodedLat;
    final lastLng = _lastGeocodedLng;
    if (lastLat != null &&
        lastLng != null &&
        Geolocator.distanceBetween(lastLat, lastLng, lat, lng) <
            addressRefreshMetres) {
      return;
    }
    _lastGeocodedLat = lat;
    _lastGeocodedLng = lng;
    _reverseLookup();
  }

  /// One positioning attempt. Returns null instead of throwing so the caller
  /// can try a coarser accuracy before giving up on a real fix entirely.
  Future<Position?> _tryFix(LocationAccuracy accuracy, int seconds) async {
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: accuracy,
          timeLimit: Duration(seconds: seconds),
        ),
      );
    } catch (_) {
      return null;
    }
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
      // Rank against the rider's OWN position so nearby places win ties.
      // DO NOT MODIFY LOGIC: null when the fix is a fallback. Ranking by the
      // placeholder centre would sort every result around a location the rider is
      // not at, which is worse than not ranking by distance at all.
      results = await _geocoder.search(query,
          nearLat: locationIsFallback ? null : currentLat,
          nearLng: locationIsFallback ? null : currentLng);
      if (results.isEmpty) {
        searchError = 'No results - refine your search or pin on the map.';
      }
    } catch (_) {
      searchError =
          'Network error - the commute guide needs an internet connection.';
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

    // DO NOT MODIFY LOGIC: a FALLBACK position must never become the trip
    // origin.
    //
    // When no fix can be obtained at all, refreshCurrentLocation parks the map
    // on a hardcoded Metro Manila centre so the screen is not blank, and flags
    // it with locationIsFallback. That flag was honoured when biasing search
    // results and when drawing the blue dot, but NOT here — so a commuter with
    // GPS off picked a destination and got a complete, confident-looking plan
    // measured from a place they had never been: wrong distance, wrong
    // boarding points, wrong fare, and a Trip row written to history saying
    // they started there.
    //
    // Retry once, because the usual cause is a cold GPS that simply had not
    // fixed yet when the screen opened. If it still cannot place them, refuse
    // to plan and say why. A commuter who is told to turn GPS on can act; one
    // handed a plausible route from the wrong origin cannot tell anything is
    // wrong until they are on the vehicle.
    if (currentLat == null || locationIsFallback) {
      await refreshCurrentLocation();
    }
    if (currentLat == null || locationIsFallback) {
      throw UnknownOriginException(locationError ??
          'Could not get your location. Turn on GPS, or drop a pin to set '
              'your starting point.');
    }

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

    suggestions = await _composeSuggestions(trip, place, prefs);
    for (final s in suggestions) {
      await _db.insertSuggestion(s);
    }
    plannedTrip = trip;
    // plannedTrip must be assigned first: _selectDefaultSuggestion writes the
    // chosen id onto it.
    _selectDefaultSuggestion();
    notifyListeners();

    // Fetch the real road geometry in the background (Figure 21 —
    // route drawn along streets like Google Maps).
    _fetchRoadPath(trip);
  }

  /// Commute guide (R6): prefer REAL Metro Manila jeepney/bus routes matched
  /// in the bundled GTFS feed (named routes + actual boarding/alighting stops),
  /// falling back to the synthetic route engine when no direct GTFS route
  /// serves the trip or the feed is unavailable.
  Future<List<RouteSuggestion>> _composeSuggestions(
      Trip trip, PlaceResult place, TransportPreferences prefs) async {
    _legsBySuggestion.clear();
    // The resolved geometry describes THOSE legs; it must never outlive them.
    _legPathCache.clear();
    guideUnavailableReason = null;

    // Scope limit: the fare matrix is the LTFRB Metro Manila rate structure and
    // the GTFS feed covers NCR only. Outside it, say so plainly rather than
    // inventing a route and a fare the rider would actually try to pay.
    final originInNcr = RouteEngine.isWithinNcr(trip.originLat, trip.originLng);
    final destInNcr =
        RouteEngine.isWithinNcr(trip.destinationLat, trip.destinationLng);
    if (!originInNcr || !destInNcr) {
      // DO NOT MODIFY LOGIC: name the end that is ACTUALLY out of range. The
      // old copy always implied the destination was unsupported, so a rider
      // starting in Bulacan/Cavite/Rizal and travelling INTO Metro Manila — a
      // very common commute — was told their perfectly valid destination was
      // the problem. Lead with what still works: the alarm is the product, the
      // commute guide is the convenience.
      final which = !originInNcr && !destInNcr
          ? 'Your starting point and destination are'
          : !originInNcr
              ? 'Your starting point is'
              : 'Your destination is';
      guideUnavailableReason =
          '$which outside Metro Manila. Route and fare data cover NCR only, '
          'so there is no commute guide for this trip - but your destination '
          'alarm will still work normally.';
      return [];
    }

    try {
      // R6 — Dijkstra over the real GTFS network, in a worker isolate. Handles
      // transfers, which the paper's own source (Narboneta & Teknomo, 2016)
      // found commuters need: three modes per trip on average.
      final anyMode =
          prefs.busEnabled || prefs.jeepneyEnabled || prefs.uvExpressEnabled;
      final journeys = await RoutingIsolate.instance.plan(RouteRequest(
        originLat: trip.originLat,
        originLng: trip.originLng,
        destLat: trip.destinationLat,
        destLng: trip.destinationLng,
        allowJeepney: prefs.jeepneyEnabled || !anyMode,
        allowBus: prefs.busEnabled || !anyMode,
      ));
      if (journeys.isNotEmpty) {
        final built = _routeEngine.buildFromJourneys(
          tripId: trip.tripId,
          destinationLabel: place.displayName,
          journeys: journeys,
          legsOut: _legsBySuggestion,
        );
        if (built.isNotEmpty) {
          // Real GTFS routes: boarding/alighting stops are actual named
          // terminals, so the UI can show them as exact locations.
          suggestionsAreEstimates = false;
          return built;
        }
      }
    } catch (_) {/* fall through to synthetic */}
    // No GTFS match — fall back to the synthetic engine. Its "terminals" are
    // generic ("nearest boarding point"), so the UI must label these estimates.
    suggestionsAreEstimates = true;
    return _routeEngine.buildSuggestions(
      tripId: trip.tripId,
      originLabel: trip.originLabel,
      destinationLabel: place.displayName,
      distanceKm: trip.distanceKm,
      prefs: prefs,
      legsOut: _legsBySuggestion,
      originLat: trip.originLat,
      originLng: trip.originLng,
      destinationLat: trip.destinationLat,
      destinationLng: trip.destinationLng,
    );
  }

  /// Live commute-guide legs for a suggestion, held in memory only (Table 24
  /// has no coordinate columns and is not being changed). Returns an empty list
  /// for an unknown id, so the trip screen simply shows no guide.
  List<GuideLeg> legsFor(String? suggestionId) =>
      suggestionId == null ? const [] : (_legsBySuggestion[suggestionId] ?? const []);

  /// Resolved per-leg geometry, keyed by suggestion id. Cleared whenever
  /// suggestions are recomposed, so it can never outlive the legs it describes.
  final Map<String, List<GuideLeg>> _legPathCache = {};

  /// The same legs as [legsFor], each carrying the road geometry for ITS OWN
  /// segment.
  ///
  /// This is what lets the trip map draw one leg at a time. The planning map
  /// draws a single polyline for the whole journey, which is right for choosing
  /// a route — but wrong once the trip starts, because a rider walking to the
  /// terminal is shown the entire jeepney ride as well and cannot tell which
  /// part of the line is the part they are on. A whole-journey polyline cannot
  /// be cut up after the fact either: nothing in it marks where the walk ends
  /// and the ride begins.
  ///
  /// Resolved once per suggestion and cached, because it reads the bundled
  /// shapes database and the geometry cannot change during a trip.
  Future<List<GuideLeg>> legsWithGeometryFor(String? suggestionId) async {
    if (suggestionId == null) return const [];
    final cached = _legPathCache[suggestionId];
    if (cached != null) return cached;
    final legs = legsFor(suggestionId);
    if (legs.isEmpty) return const [];
    final out = <GuideLeg>[];
    for (final leg in legs) {
      out.add(leg.withPath(await _pathForLeg(leg)));
    }
    _legPathCache[suggestionId] = out;
    return out;
  }

  /// Road geometry for one leg, or an empty list when the leg's own endpoints
  /// are not both known (a synthetic middle leg between fictional transfer
  /// points — there is no honest line to draw between two invented places).
  ///
  /// A RIDE leg is drawn from the bundled shape of the route the guide names,
  /// trimmed to the stops the rider actually boards and alights at. Keyed on
  /// the NAME rather than on proximity for the same reason the planning map is:
  /// proximity draws whichever route runs near both ends, which is not
  /// necessarily the one the rider was told to board.
  ///
  /// A WALK leg is drawn as a straight line between its endpoints, deliberately
  /// and not as a fallback. Walking geometry would have to come off the
  /// network, and this runs at Start Trip — the moment a commuter is least
  /// likely to have signal and least willing to wait. A straight line over a
  /// two-hundred-metre walk visibly ignores the road, which reads as the
  /// approximation it is; a road path that silently failed to load would not.
  Future<List<List<double>>> _pathForLeg(GuideLeg leg) async {
    if (!leg.hasStart || !leg.canAutoAdvance) return const [];
    final straight = <List<double>>[
      [leg.startLat!, leg.startLng!],
      [leg.endLat!, leg.endLng!],
    ];
    if (leg.step.transportMode == 'walk') return straight;
    try {
      final name = routeNameFromInstruction(leg.step.instruction);
      if (name == null) return straight;
      final path = await RouteShapeService.instance.pathForName(
        name,
        fromLat: leg.startLat!,
        fromLng: leg.startLng!,
        toLat: leg.endLat!,
        toLng: leg.endLng!,
      );
      if (path == null || path.length < 2) return straight;
      final trimmed = trimPolyline(path, leg.startLat!, leg.startLng!,
          leg.endLat!, leg.endLng!);
      return trimmed.length >= 2 ? trimmed : straight;
    } catch (e) {
      debugPrint('NavAlert: leg geometry unavailable — $e');
      return straight;
    }
  }

  Future<void> _fetchRoadPath(Trip trip) async {
    loadingPath = true;
    routePath = [
      [trip.originLat, trip.originLng],
      [trip.destinationLat, trip.destinationLng],
    ];
    notifyListeners();

    // Bundled shapes first. They are pre-computed at build time
    // (tool/gen_shapes.py), so this is the only path that works on a commute
    // with no signal — which is precisely when the network is worst and the
    // map used to degrade to the straight line above without saying so.
    final local = await _localRoadPath(trip);
    if (local != null) {
      routePath = local;
      loadingPath = false;
      notifyListeners();
      return;
    }

    try {
      routePath = await _routePath.roadPath(
        fromLat: trip.originLat,
        fromLng: trip.originLng,
        toLat: trip.destinationLat,
        toLng: trip.destinationLng,
      );
    } catch (_) {
      // Offline and no bundled shape — keep the straight-line fallback.
    }
    loadingPath = false;
    notifyListeners();
  }


  /// The bundled road geometry for the PUV leg the commuter was actually told
  /// to ride, trimmed to the part they ride.
  ///
  /// Keyed on the SELECTED suggestion, not on proximity. Matching by proximity
  /// drew whichever route happened to pass within range of both ends of the
  /// trip - so a walking suggestion drew a jeepney route nobody was riding,
  /// offset from both the origin and the destination. A shape is only honest
  /// here if it is the route the guide names.
  ///
  /// Returns null for a walk-only suggestion. There is no PUV geometry to draw
  /// for a walk, and drawing one would assert a ride that was never suggested.
  Future<List<List<double>>?> _localRoadPath(Trip trip) async {
    try {
      final steps = selectedSuggestion?.steps;
      if (steps == null || steps.isEmpty) return null;

      for (final step in steps) {
        if (step.transportMode == 'walk') continue;
        final name = routeNameFromInstruction(step.instruction);
        if (name == null) continue;
        final path = await RouteShapeService.instance.pathForName(
          name,
          fromLat: trip.originLat,
          fromLng: trip.originLng,
          toLat: trip.destinationLat,
          toLng: trip.destinationLng,
        );
        if (path == null || path.length < 2) continue;
        return trimPolyline(path, trip.originLat, trip.originLng,
            trip.destinationLat, trip.destinationLng);
      }
      return null;
    } catch (e) {
      debugPrint('NavAlert: bundled road path unavailable — $e');
      return null;
    }
  }

  /// Re-generates suggestions after the rider changes mode priority.
  Future<void> regenerateSuggestions(TransportPreferences prefs) async {
    final trip = plannedTrip;
    final place = destination;
    if (trip == null || place == null) return;
    suggestions = await _composeSuggestions(trip, place, prefs);
    for (final s in suggestions) {
      await _db.insertSuggestion(s);
    }
    _selectDefaultSuggestion();
    notifyListeners();
  }

  /// The top-ranked route is pre-selected, so it must be recorded on the trip
  /// exactly as an explicit tap would be. Without this, a rider who simply
  /// accepts the default — the common case — leaves Table 22's
  /// selected_route_suggestion_id (and its foreign key) null, losing which
  /// route the trip actually followed.
  void _selectDefaultSuggestion() {
    if (suggestions.isEmpty) {
      selectedSuggestion = null;
      return;
    }
    selectSuggestion(suggestions.first);
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
    _legsBySuggestion.clear();
    _legPathCache.clear();
    notifyListeners();
  }
}
