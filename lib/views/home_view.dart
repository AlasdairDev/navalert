import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../core/map_support.dart';
import '../core/theme.dart';
import '../viewmodels/app_viewmodel.dart';
import '../viewmodels/home_viewmodel.dart';
import 'onboarding_flow.dart';
import 'search_view.dart';

/// Figure 19 — Main Screen: greeting, destination search bar and an
/// interactive OpenStreetMap view with a locate button.
///
/// UI/UX MAP (see legend in core/theme.dart):
///  [NEED] FlutterMap + TileLayer (OSM tiles, paper API) · locate FAB's
///         onPressed refreshCurrentLocation() · search bar's onTap →
///         SearchView · the incomplete-setup MaterialBanner logic.
///  [EDIT] greeting text/logic (_greeting), "Where are you headed?" copy,
///         search-bar pill shape/color, marker dot style/size, FAB icon,
///         header card blur/rounding, all paddings.
///  [WANT] animate the marker, add a compass/zoom control, richer greeting.
class HomeView extends StatefulWidget {
  const HomeView({super.key});

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> with TickerProviderStateMixin {
  final _mapController = MapController();

  // DO NOT MODIFY LOGIC: the mover is built eagerly in initState, NOT as a lazy
  // `late final` field initializer. When GPS never returns a fix the mover is
  // never read, so a lazy field would run its initializer for the FIRST time
  // inside dispose() below — constructing an AnimationController against an
  // already-deactivated element. That throws "Looking up a deactivated widget's
  // ancestor is unsafe" and kills the frame on the way out of the Home tab,
  // which is exactly the no-signal case the rider is most likely to hit.
  late final AnimatedMapMover _mover;

  @override
  void initState() {
    super.initState();
    _mover = AnimatedMapMover(_mapController, this);
    // DO NOT MODIFY LOGIC: first-frame GPS acquisition + animated recenter.
    // This is the R2/UC-4 location bootstrap; the map has nothing to show
    // until refreshCurrentLocation() returns. Restyle the map/markers freely,
    // but leave this callback and the animateTo call intact.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final vm = context.read<HomeViewModel>();
      await vm.refreshCurrentLocation();
      if (mounted && vm.currentLat != null) {
        _mover.animateTo(LatLng(vm.currentLat!, vm.currentLng!), 16);
      }
    });
  }

  @override
  void dispose() {
    _mover.dispose();
    super.dispose();
  }

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good Morning,';
    if (h < 18) return 'Good Afternoon,';
    return 'Good Evening,';
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<HomeViewModel>();
    final center = LatLng(vm.currentLat ?? 14.5979, vm.currentLng ?? 121.0108);

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: center,
              initialZoom: 14,
              // Panning is fenced to NCR — the app has no route or fare data
              // for anywhere else, so scrolling into a province is a dead end.
              cameraConstraint: NavAlertMap.ncrConstraint,
              minZoom: 10,
              maxZoom: 20,
            ),
            children: [
              // DO NOT MODIFY LOGIC: NavAlertMap.tiles / ncrConstraint come
              // from core/map_support.dart (retina tiles, NCR geofence, tile
              // buffering). Restyle markers/overlays, but don't inline-replace
              // these — they keep the map crisp and inside the service area.
              NavAlertMap.tiles(context),
              MarkerLayer(markers: [
                // TODO (UI Team): the current-location dot style.
                // Google-Maps-style blue is intentional and widely recognised;
                // this 0xFF4285F4 is a deliberate keep, not theme purple.
                Marker(
                  point: center,
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
            ],
          ),
          // Greeting + search header
          SafeArea(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              decoration: BoxDecoration(
                color: NavAlertColors.background.withValues(alpha: 0.94),
                borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(24)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // TODO (UI Team): greeting + heading typography. Consider a
                  // theme text style instead of inline fontSize/weight.
                  Text(_greeting,
                      style: const TextStyle(
                          color: NavAlertColors.textSecondary, fontSize: 14)),
                  const Text('Where are you headed?',
                      style: TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  GestureDetector(
                    // DO NOT MODIFY LOGIC: opens the destination search (UC-4).
                    // Restyle the pill below, but keep this onTap → SearchView.
                    onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const SearchView())),
                    child: Container(
                      // TODO (UI Team): the search pill's shape/padding/color.
                      // USE THEME: this white-on-map pill is deliberate for
                      // contrast over the map — if you restyle, keep it legible
                      // against OSM tiles (a theme token is fine if you add one).
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 13),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: const Row(children: [
                        Icon(Icons.search, color: Colors.black54, size: 20),
                        SizedBox(width: 8),
                        Text('Search',
                            style: TextStyle(color: Colors.black54)),
                      ]),
                    ),
                  ),
                  // UC-4 Exception 2 — the map is showing a fallback position,
                  // not the rider's own. This MUST be visible here: Home is
                  // where the map is, and silently centring on PUP Sta. Mesa
                  // looks exactly like a working GPS fix.
                  if (vm.locationIsFallback && vm.locationError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: MaterialBanner(
                        padding: const EdgeInsets.all(10),
                        backgroundColor: NavAlertColors.surface,
                        content: Text(vm.locationError!,
                            style: const TextStyle(fontSize: 12)),
                        leading: const Icon(Icons.location_off,
                            color: NavAlertColors.warning),
                        actions: [
                          TextButton(
                            onPressed: () => vm.refreshCurrentLocation(),
                            child: const Text('Retry'),
                          ),
                          TextButton(
                            onPressed: () => Geolocator.openAppSettings(),
                            child: const Text('Settings'),
                          ),
                        ],
                      ),
                    ),
                  // Incomplete-setup prompt (app_state, Table 15): onboarding
                  // was skipped without emergency contacts.
                  if (context.watch<AppViewModel>().showIncompleteSetupPrompt)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: MaterialBanner(
                        padding: const EdgeInsets.all(10),
                        backgroundColor: NavAlertColors.surface,
                        content: const Text(
                          'Setup incomplete — add emergency contacts so the '
                          'SOS feature can protect you.',
                          style: TextStyle(fontSize: 12),
                        ),
                        leading: const Icon(Icons.warning_amber,
                            color: NavAlertColors.warning),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) => const ContactsSetupView(
                                        inOnboarding: false))),
                            child: const Text('Add now'),
                          ),
                          TextButton(
                            onPressed: () => context
                                .read<AppViewModel>()
                                .dismissIncompleteSetupPrompt(),
                            child: const Text('Dismiss'),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          // Locate me button
          // TODO (UI Team): FAB position/size/icon/color are free to restyle.
          Positioned(
            right: 16,
            bottom: 24,
            child: FloatingActionButton(
              backgroundColor: Colors.white,
              // DO NOT MODIFY LOGIC: re-fetches GPS and re-centres the map
              // (UC-4). Keep refreshCurrentLocation() + animateTo; the snackbar
              // copy is [EDIT].
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                messenger.showSnackBar(const SnackBar(
                    content: Text('Getting your GPS location…'),
                    duration: Duration(seconds: 2)));
                await vm.refreshCurrentLocation();
                if (vm.currentLat != null) {
                  _mover.animateTo(
                      LatLng(vm.currentLat!, vm.currentLng!), 16.5);
                  messenger.hideCurrentSnackBar();
                }
              },
              child: const Icon(Icons.my_location, color: Colors.black87),
            ),
          ),
        ],
      ),
    );
  }
}
