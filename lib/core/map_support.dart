import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:latlong2/latlong.dart';

import '../services/route_engine.dart';

/// Shared map configuration so Home, Pin-on-map and Route screens agree on
/// region, tile quality and buffering.
///
/// The National Capital Region box is taken from [RouteEngine] — the single
/// source of truth also used by the Dijkstra graph, the Nominatim viewbox and
/// pin validation, so "in the service area" means the same thing everywhere.
class NavAlertMap {
  const NavAlertMap._();

  static final LatLngBounds ncrBounds = LatLngBounds(
    LatLng(RouteEngine.ncrMinLat, RouteEngine.ncrMinLng),
    LatLng(RouteEngine.ncrMaxLat, RouteEngine.ncrMaxLng),
  );

  /// Keeps panning inside NCR — the rider cannot scroll into a province the
  /// app has no route or fare data for.
  static final CameraConstraint ncrConstraint =
      CameraConstraint.contain(bounds: ncrBounds);

  static bool isWithinNcr(LatLng p) =>
      RouteEngine.isWithinNcr(p.latitude, p.longitude);

  /// One tile layer for every map.
  ///
  /// DO NOT MODIFY LOGIC (the buffer values): they control how many tiles are
  /// fetched, and OSM's public server is rate-limited.
  ///
  /// `retinaMode` keeps the map sharp on high-density screens, but flutter_map
  /// has no @2x OSM endpoint to use, so it *simulates* retina by fetching one
  /// zoom level deeper — that is 4x the tiles for the same area. `panBuffer`
  /// multiplies on top of that: every extra ring widens the grid in BOTH
  /// directions, so panBuffer 2 turned a ~3x5 viewport (15 tiles) into 7x9
  /// (63) — about 250 tiles per load once retina is applied, which is why the
  /// map took so long to appear. panBuffer 0 fetches only what is on screen;
  /// `keepBuffer` (memory-only, it never fetches) still holds tiles after they
  /// scroll off, so panning back is instant.
  static TileLayer tiles(BuildContext context) => TileLayer(
        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
        userAgentPackageName: 'ph.edu.pup.navalert',
        retinaMode: RetinaMode.isHighDensity(context),
        maxNativeZoom: 19,
        maxZoom: 20,
        // Cancels obsolete requests while flinging, and dedupes in-flight
        // tiles — the main network-latency win without a native cache DB.
        tileProvider: CancellableNetworkTileProvider(),
        panBuffer: 0,
        keepBuffer: 8,
      );
}

/// Smoothly interpolates a [MapController] between camera positions instead of
/// jumping. Attach one per map state and dispose it in `dispose()`.
///
/// Deliberately dependency-free: a hand-rolled tween over the existing
/// controller, rather than pulling in flutter_map_animations for a single
/// eased move.
class AnimatedMapMover {
  AnimatedMapMover(this.controller, TickerProvider vsync)
      : _anim = AnimationController(
          vsync: vsync,
          duration: const Duration(milliseconds: 550),
        );

  final MapController controller;
  final AnimationController _anim;

  void animateTo(LatLng dest, double destZoom) {
    final cam = controller.camera;
    final startLat = cam.center.latitude;
    final startLng = cam.center.longitude;
    final startZoom = cam.zoom;
    final curve = CurvedAnimation(parent: _anim, curve: Curves.easeInOutCubic);

    void tick() {
      final t = curve.value;
      controller.move(
        LatLng(
          startLat + (dest.latitude - startLat) * t,
          startLng + (dest.longitude - startLng) * t,
        ),
        startZoom + (destZoom - startZoom) * t,
      );
    }

    _anim
      ..removeListener(tick)
      ..reset()
      ..addListener(tick)
      ..forward();
  }

  void dispose() => _anim.dispose();
}
