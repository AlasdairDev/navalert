import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../core/map_support.dart';
import '../core/theme.dart';
import 'commute_sheet_layout.dart';

/// The live map beneath the commute guide during an active trip.
///
/// The guide-first monitoring layout used to be an opaque list on a gradient
/// wash: a rider following step-by-step directions could read what to do next
/// but had no way to see where they actually were. This is the map that answers
/// that, with the guide floating over it.
///
/// UI/UX MAP (see legend in core/theme.dart):
///  [NEED] NavAlertMap.tiles (the disk-cached offline tile layer) ·
///         NavAlertMap.ncrConstraint · the follow-camera wiring
///         (onPositionChanged → tracker → _mover.animateTo) · the recenter
///         button's onPressed.
///  [EDIT] the blue dot and destination pin styling, the route line colours and
///         widths, the recenter button's look and placement, the follow zoom.
///  [WANT] a heading arrow instead of a plain dot, a "next turn" callout,
///         dimming the route already travelled.
class TripMapView extends StatefulWidget {
  const TripMapView({
    super.key,
    required this.origin,
    required this.destination,
    required this.rider,
    required this.routePath,
    required this.obscuredBottom,
  });

  /// Where the trip started — the camera's opening position, used only until a
  /// real fix lands.
  final LatLng origin;

  /// The trip's destination pin.
  final LatLng destination;

  /// The rider's last real GPS fix, or null when none has landed yet.
  final LatLng? rider;

  /// The planned route, as `[lat, lng]` pairs from HomeViewModel.routePath.
  /// Empty falls back to a straight origin→destination line.
  final List<List<double>> routePath;

  /// Logical pixels covered at the bottom of the map by the guide sheet and the
  /// safety footer. Drives the camera offset so the rider stays centred in what
  /// is actually visible. Listenable because the sheet's height changes under
  /// the rider's finger, and rebuilding the whole map per drag frame would
  /// thrash the tile layer.
  final ValueListenable<double> obscuredBottom;

  @override
  State<TripMapView> createState() => _TripMapViewState();
}

class _TripMapViewState extends State<TripMapView>
    with TickerProviderStateMixin {
  final _mapController = MapController();
  final _tracker = TripCameraTracker();

  /// DO NOT MODIFY LOGIC: built eagerly in initState, NOT as a lazy
  /// `late final`. On a trip where GPS never returns a fix the mover is never
  /// read, so a lazy field would run its initializer for the FIRST time inside
  /// dispose() — building an AnimationController against a deactivated element,
  /// which throws and kills the frame on the way off the trip screen. Same
  /// hazard, same fix, as HomeView's mover.
  late final AnimatedMapMover _mover;

  /// [EDIT] Zoom the camera holds while following. Street-level: close enough
  /// to read which corner is coming, wide enough to see the next turn.
  static const double _followZoom = 16.5;

  /// The fix the camera has already been moved to. Without this the camera
  /// re-animates on EVERY rebuild — and this widget rebuilds on every GPS tick,
  /// every sheet drag frame and every guide advance, so the map would be in
  /// permanent motion and never settle.
  LatLng? _cameraAt;

  /// True once the map has laid out at least once, so the camera can be moved.
  /// Moving a MapController before its FlutterMap is mounted throws.
  bool _mapReady = false;

  /// Coalesces the sheet's drag frames into one camera move — see
  /// [_onObscuredChanged].
  Timer? _obscuredDebounce;
  static const _obscuredSettle = Duration(milliseconds: 140);

  @override
  void initState() {
    super.initState();
    _mover = AnimatedMapMover(_mapController, this);
    // The sheet moves under the rider's finger without any GPS fix arriving, so
    // the camera has to re-centre on drag as well — otherwise the dot slides
    // behind the sheet as it grows.
    widget.obscuredBottom.addListener(_onObscuredChanged);
    // The camera can only be driven once FlutterMap is mounted; MapController
    // throws otherwise. Scheduled once here rather than from build(), which
    // would queue a fresh callback on every GPS tick and every drag frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _mapReady = true;
      _followRider();
    });
  }

  @override
  void dispose() {
    _obscuredDebounce?.cancel();
    widget.obscuredBottom.removeListener(_onObscuredChanged);
    _mover.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TripMapView old) {
    super.didUpdateWidget(old);
    if (!identical(old.obscuredBottom, widget.obscuredBottom)) {
      old.obscuredBottom.removeListener(_onObscuredChanged);
      widget.obscuredBottom.addListener(_onObscuredChanged);
    }
    _followRider();
  }

  /// DO NOT MODIFY LOGIC: debounced, not immediate. The sheet reports its
  /// extent on EVERY frame of a drag and of the snap animation that follows, so
  /// re-aiming the camera on each one restarts the 550 ms ease dozens of times a
  /// second — the map never settles and the rider is reading steps over a
  /// permanently sliding basemap. Waiting for the extent to stop changing gives
  /// exactly one recentre per drag.
  void _onObscuredChanged() {
    _obscuredDebounce?.cancel();
    _obscuredDebounce = Timer(_obscuredSettle, () {
      if (!mounted) return;
      // Re-aim at the fix we are already on, with the new visible band.
      _cameraAt = null;
      _followRider();
    });
  }

  /// Pans the camera to keep the rider centred in the VISIBLE band of map.
  void _followRider() {
    final rider = widget.rider;
    if (!_mapReady || rider == null || !_tracker.following) return;
    // Same coordinate as last time — nothing to do. Re-animating here is what
    // makes the map jitter on every unrelated rebuild.
    final at = _cameraAt;
    if (at != null &&
        at.latitude == rider.latitude &&
        at.longitude == rider.longitude) {
      return;
    }
    _cameraAt = rider;
    _mover.animateTo(rider, _followZoom,
        offset: Offset(0, TripCameraTracker.cameraOffsetY(
            widget.obscuredBottom.value)));
  }

  void _recenter() {
    setState(_tracker.recenter);
    _cameraAt = null;
    _followRider();
  }

  @override
  Widget build(BuildContext context) {
    final rider = widget.rider;
    final path = widget.routePath.isNotEmpty
        ? widget.routePath
            .map((p) => LatLng(p[0], p[1]))
            .toList(growable: false)
        : [widget.origin, widget.destination];

    return Stack(children: [
      FlutterMap(
        mapController: _mapController,
        options: MapOptions(
          initialCenter: rider ?? widget.origin,
          initialZoom: _followZoom,
          // DO NOT MODIFY LOGIC: the same NCR geofence every other map in the
          // app uses — panning into a province the app has no route or fare
          // data for is a dead end.
          cameraConstraint: NavAlertMap.ncrConstraint,
          minZoom: 10,
          maxZoom: 20,
          // DO NOT MODIFY LOGIC: this is what makes follow escapable. A real
          // finger on the map releases the camera so the rider can look ahead
          // down the route; MapController.move (which is what the follow itself
          // uses) reports hasGesture false, so tracking cannot switch itself
          // off. See TripCameraTracker.
          onPositionChanged: (_, hasGesture) {
            if (!hasGesture || !_tracker.following) return;
            setState(() => _tracker.onPositionChanged(hasGesture: true));
          },
        ),
        children: [
          // DO NOT MODIFY LOGIC: NavAlertMap.tiles is the shared, disk-cached
          // (TileCacheStore) offline tile layer — retina handling, the NCR
          // geofence and the tile buffering all live there. Do not inline a
          // replacement TileLayer here: a second provider means a second Dio
          // client and a second cache, which is what the offline map exists to
          // avoid.
          NavAlertMap.tiles(context),
          PolylineLayer(polylines: [
            // White casing under the route line for contrast, exactly as the
            // planning map draws it — the two screens show one route.
            Polyline(points: path, strokeWidth: 9, color: Colors.white),
            Polyline(
                points: path,
                strokeWidth: 5.5,
                color: const Color(0xFF4285F4)),
          ]),
          MarkerLayer(markers: [
            Marker(
              point: widget.destination,
              width: 44,
              height: 44,
              alignment: Alignment.topCenter,
              child: const Icon(Icons.location_pin,
                  color: NavAlertColors.danger,
                  size: 44,
                  shadows: [Shadow(color: Colors.black45, blurRadius: 6)]),
            ),
          ]),
          // DO NOT MODIFY LOGIC: the dot renders ONLY for a real fix. Falling
          // back to the trip's origin would paint a planning coordinate — which
          // can be minutes stale — as "you are here", and it would look
          // identical to a working fix on the screen the rider is navigating
          // by. A missing dot is honest; a confident wrong dot is not.
          if (rider != null)
            LatLngGlide(
              target: rider,
              builder: (context, position) => MarkerLayer(markers: [
                // TODO (UI Team): the current-location dot style. The
                // Google-Maps blue 0xFF4285F4 is a deliberate keep — it is the
                // one colour every rider already reads as "me" — not an
                // oversight against the purple theme.
                Marker(
                  point: position,
                  width: 22,
                  height: 22,
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF4285F4),
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: const [
                        BoxShadow(color: Colors.black38, blurRadius: 4),
                      ],
                    ),
                  ),
                ),
              ]),
            ),
        ],
      ),
      // The way back to tracking. Shown only while the camera is released, so
      // it is never a control that does nothing — and never while there is no
      // fix to return to.
      if (!_tracker.following && rider != null)
        // Rides just above whatever the sheet and footer currently cover, so it
        // is reachable at every drag height instead of only at rest. Watching
        // the notifier directly keeps the tile layer out of the rebuild — the
        // button follows the sheet without the map repainting behind it.
        //
        // Positioned.fill is safe over the map: Align does not absorb hits
        // where it has no child, so panning still reaches FlutterMap beneath.
        Positioned.fill(
          child: ValueListenableBuilder<double>(
            valueListenable: widget.obscuredBottom,
            builder: (context, obscured, child) => Padding(
              padding: EdgeInsets.only(
                  right: 16, bottom: (obscured + 16).clamp(16.0, 600.0)),
              child: Align(alignment: Alignment.bottomRight, child: child),
            ),
            child: FloatingActionButton.small(
              heroTag: 'trip-recenter',
              backgroundColor: Colors.white,
              tooltip: 'Centre on me',
              onPressed: _recenter,
              child: const Icon(Icons.my_location, color: Colors.black87),
            ),
          ),
        ),
    ]);
  }
}
