import 'dart:math' show Point;

import 'package:dio_cache_interceptor/dio_cache_interceptor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_cache/flutter_map_cache.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import '../services/route_engine.dart';
import '../services/tile_cache_store.dart';

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

  // ── Persistent tile cache ────────────────────────────────────────────────
  // Previously the only caching was `keepBuffer` — memory-only, and gone the
  // moment the process died, so every cold start re-fetched every tile over
  // the network. This adds a disk cache on top.
  //
  // It also makes the map degrade gracefully instead of going blank:
  // `hitCacheOnNetworkFailure` serves the stored tile when the request fails,
  // which is the normal condition on a moving jeepney with patchy signal.
  //
  // Caching is what OSM's tile usage policy asks of clients — this cuts
  // requests to their donated servers rather than adding to them. Nothing here
  // pre-fetches or bulk-downloads; only tiles the rider actually looked at are
  // stored.

  // Backed by [TileCacheStore], which writes tiles to DISK so they outlive the
  // process — the paper's offline requirement. A memory cache cannot satisfy
  // it: a commuter who force-closes the app in a dead zone would lose every
  // tile they had already loaded.
  //
  // No packaged store could do this here (see TileCacheStore's own notes on
  // the dio_cache_interceptor 3.x/4.x split), so it is implemented in-repo.

  static CacheStore? _resolvedStore;

  /// Used only if the disk path cannot be resolved. The map must still render
  /// when storage is unavailable — degraded to session-only, never broken.
  static final CacheStore _memoryFallback =
      MemCacheStore(maxSize: 32 * 1024 * 1024, maxEntrySize: 1024 * 1024);

  static CacheStore get _store => _resolvedStore ?? _memoryFallback;

  /// Resolves the on-disk tile cache. Called from `main()` BEFORE the first
  /// frame, because [tiles] is synchronous and the provider it builds is
  /// created once — if a map were built first it would be stuck with the
  /// memory fallback for the rest of the session.
  ///
  /// The application-support directory, not the cache directory: Android
  /// reclaims cache dirs under storage pressure, which would silently empty
  /// the offline map exactly when a rider is relying on it. The size ceiling
  /// is enforced by [TileCacheStore] instead, so this stays bounded.
  static Future<void> initTileCache() async {
    if (_resolvedStore != null) return;
    try {
      // Timeout for the same reason main() does not await the notification
      // channel: a hung platform channel must not hold the first frame.
      final dir = await getApplicationSupportDirectory()
          .timeout(const Duration(seconds: 3));
      _resolvedStore = TileCacheStore('${dir.path}/tile_cache');
    } catch (e) {
      debugPrint('NavAlert: tile disk cache unavailable, '
          'falling back to memory — $e');
    }
  }

  /// Built once and reused. [tiles] is called from build methods, so creating
  /// a provider per call would spin up a fresh Dio and interceptor chain on
  /// every rebuild — and a brand-new cache client each time, which would
  /// defeat the point of caching at all.
  static TileProvider? _provider;

  static TileProvider get _tileProvider => _provider ??= CachedTileProvider(
        store: _store,
        maxStale: const Duration(days: 30),
        // OSM blocks clients without a valid identifying User-Agent. The
        // default provider derives one from `userAgentPackageName`; a custom
        // provider must carry it itself.
        headers: {'User-Agent': 'ph.edu.pup.navalert (flutter_map)'},
      );

  /// One tile layer for every map.
  ///
  /// DO NOT MODIFY LOGIC (the buffer values): they control how many tiles are
  /// fetched, and OSM's public server is rate-limited.
  ///
  /// `retinaMode` keeps the map sharp on high-density screens, but flutter_map
  /// has no @2x OSM endpoint to use, so it *simulates* retina by fetching one
  /// zoom level deeper — that is 4x the tiles for the same area. It stays
  /// CONDITIONAL on the device: forcing it true would quadruple the tile count
  /// on a low-density screen that cannot show the extra detail. `panBuffer`
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
        // Disk-cached AND cancellable: CachedTileProvider reports
        // supportsCancelLoading, so obsolete requests are still aborted while
        // flinging — the behaviour the previous CancellableNetworkTileProvider
        // existed for is kept, with persistence added on top rather than
        // traded away.
        tileProvider: _tileProvider,
        panBuffer: 0,
        keepBuffer: 8,
      );
}

/// Glides a point toward each new target instead of snapping to it.
///
/// The live GPS stream delivers a fix every couple of seconds (and only once
/// the rider has moved past the 5 m distance filter), so painting the marker
/// straight at each new coordinate made the blue dot cover the whole gap in a
/// single frame — a visible teleport rather than movement.
///
/// Rebuilds only the widget [builder] returns, so wrapping a `MarkerLayer` in
/// one of these animates the dot without touching the camera, the tiles or any
/// other layer. Same hand-rolled approach as [AnimatedMapMover] below —
/// dependency-free, one controller.
class LatLngGlide extends StatefulWidget {
  const LatLngGlide({
    super.key,
    required this.target,
    required this.builder,
    this.duration = const Duration(milliseconds: 400),
  });

  /// The newest real position. Changing it starts a glide from wherever the
  /// dot currently is.
  final LatLng target;

  /// Rebuilt every frame of the glide with the interpolated position.
  final Widget Function(BuildContext context, LatLng position) builder;

  /// Long enough to read as movement, short enough to stay well inside the
  /// ~2 s gap between fixes so the dot is never lagging behind reality.
  final Duration duration;

  @override
  State<LatLngGlide> createState() => _LatLngGlideState();
}

class _LatLngGlideState extends State<LatLngGlide>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  late final CurvedAnimation _curve =
      CurvedAnimation(parent: _anim, curve: Curves.easeOut);

  /// Where this glide started and where it is heading.
  late LatLng _from = widget.target;
  late LatLng _to = widget.target;

  @override
  void didUpdateWidget(covariant LatLngGlide old) {
    super.didUpdateWidget(old);
    final t = widget.target;
    // The ViewModel notifies for reasons other than movement — a reverse-geocode
    // landing, a banner clearing — so an unchanged coordinate must not restart
    // the animation and re-glide the dot over ground it already covered.
    if (t.latitude == _to.latitude && t.longitude == _to.longitude) return;
    // Re-aim from the CURRENT painted position, not from the previous target:
    // a fix landing mid-glide would otherwise snap the dot back to where the
    // last glide began before setting off again.
    _from = _current;
    _to = t;
    _anim.forward(from: 0);
  }

  LatLng get _current {
    final t = _curve.value;
    return LatLng(
      _from.latitude + (_to.latitude - _from.latitude) * t,
      _from.longitude + (_to.longitude - _from.longitude) * t,
    );
  }

  @override
  void dispose() {
    _curve.dispose();
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _anim,
        builder: (context, _) => widget.builder(context, _current),
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

  /// Eases the camera so [dest] ends up [offset] logical pixels from the centre
  /// of the map widget. The default of [Offset.zero] is the original behaviour,
  /// so Home is unaffected; the trip map passes a negative dy to lift the rider
  /// clear of the commute-guide sheet covering the bottom of the screen.
  void animateTo(LatLng dest, double destZoom, {Offset offset = Offset.zero}) {
    final cam = controller.camera;
    // DO NOT MODIFY LOGIC: the offset is resolved into a camera CENTRE once,
    // here, and the tween below then runs on plain centres. Passing `offset:`
    // to `move()` on every tick instead looks equivalent and is not: each tick
    // would re-apply the shift relative to wherever the camera already sits, so
    // the first frame jumps by the offset and every subsequent GPS fix shifts
    // the map another screen-half further — the camera walks off the rider
    // within a few fixes.
    final target = _centreFor(cam, dest, destZoom, offset);
    final startLat = cam.center.latitude;
    final startLng = cam.center.longitude;
    final startZoom = cam.zoom;
    final curve = CurvedAnimation(parent: _anim, curve: Curves.easeInOutCubic);

    void tick() {
      final t = curve.value;
      controller.move(
        LatLng(
          startLat + (target.latitude - startLat) * t,
          startLng + (target.longitude - startLng) * t,
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

  /// The camera centre that puts [dest] at [offset] from the widget centre.
  ///
  /// flutter_map documents `Offset(100, 100)` as moving the intended centre
  /// 100 px down and right, which leaves the actual centre 100 px up and left —
  /// so in projected pixel space the centre is the target MINUS the offset.
  /// Projection is done at [zoom], not the live camera zoom, because that is
  /// the zoom the offset has to be correct at when the move lands.
  static LatLng _centreFor(
      MapCamera cam, LatLng dest, double zoom, Offset offset) {
    if (offset == Offset.zero) return dest;
    final p = cam.project(dest, zoom);
    return cam.unproject(Point(p.x - offset.dx, p.y - offset.dy), zoom);
  }

  void dispose() => _anim.dispose();
}
