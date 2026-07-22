import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

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

class _HomeViewState extends State<HomeView> {
  final _mapController = MapController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final vm = context.read<HomeViewModel>();
      await vm.refreshCurrentLocation();
      if (mounted && vm.currentLat != null) {
        _mapController.move(LatLng(vm.currentLat!, vm.currentLng!), 15);
      }
    });
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
            options: MapOptions(initialCenter: center, initialZoom: 14),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'ph.edu.pup.navalert',
                // Cancels obsolete tile requests while panning/zooming and
                // prefetches a buffer of tiles around the viewport so
                // dragging stays smooth.
                tileProvider: CancellableNetworkTileProvider(),
                panBuffer: 1,
                keepBuffer: 4,
              ),
              MarkerLayer(markers: [
                // Google-Maps-style blue current-location dot.
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
                  Text(_greeting,
                      style: const TextStyle(
                          color: NavAlertColors.textSecondary, fontSize: 14)),
                  const Text('Where are you headed?',
                      style: TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  GestureDetector(
                    onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const SearchView())),
                    child: Container(
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
          Positioned(
            right: 16,
            bottom: 24,
            child: FloatingActionButton(
              backgroundColor: Colors.white,
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                messenger.showSnackBar(const SnackBar(
                    content: Text('Getting your GPS location…'),
                    duration: Duration(seconds: 2)));
                await vm.refreshCurrentLocation();
                if (vm.currentLat != null) {
                  _mapController.move(
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
