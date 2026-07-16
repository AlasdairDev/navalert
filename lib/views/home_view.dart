import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../viewmodels/app_viewmodel.dart';
import '../viewmodels/home_viewmodel.dart';
import 'onboarding_flow.dart';
import 'search_view.dart';

/// Figure 19 — Main Screen: greeting, destination search bar and an
/// interactive OpenStreetMap view with a locate button.
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
              ),
              MarkerLayer(markers: [
                Marker(
                  point: center,
                  width: 40,
                  height: 40,
                  child: const Icon(Icons.my_location,
                      color: NavAlertColors.primary, size: 30),
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
                  // Incomplete-setup prompt (app_state, Table 15):
                  // onboarding was skipped without emergency contacts.
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
                await vm.refreshCurrentLocation();
                if (vm.currentLat != null) {
                  _mapController.move(
                      LatLng(vm.currentLat!, vm.currentLng!), 15.5);
                }
              },
              child: const Icon(Icons.location_on, color: Colors.black87),
            ),
          ),
        ],
      ),
    );
  }
}
