import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../models/models.dart';
import '../viewmodels/app_viewmodel.dart';
import '../viewmodels/home_viewmodel.dart';
import 'pin_on_map_view.dart';
import 'route_view.dart';

/// Figure 20 — Destination Search Screen ("Where to?") using the
/// Nominatim API over OpenStreetMap.
class SearchView extends StatefulWidget {
  const SearchView({super.key});

  @override
  State<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<SearchView> {
  final _controller = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () {
      if (q.trim().length >= 3) context.read<HomeViewModel>().search(q);
    });
  }

  Future<void> _select(PlaceResult place) async {
    final home = context.read<HomeViewModel>();
    final app = context.read<AppViewModel>();

    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()));
    try {
      await home.setDestination(place, app.transportPrefs);
    } finally {
      if (mounted) Navigator.of(context).pop(); // close loader
    }
    if (!mounted) return;
    Navigator.of(context)
        .pushReplacement(MaterialPageRoute(builder: (_) => const RouteView()));
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<HomeViewModel>();
    return Scaffold(
      appBar: AppBar(title: const Text('Where to?')),
      body: SafeArea(
        child: Column(
          children: [
            // Figure 20 — origin → destination header: current-location
            // dot connected by a line to the search field. The address is
            // shown Google-Maps style: primary name only, single line.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Column(children: [
                      const SizedBox(height: 5),
                      const Icon(Icons.circle,
                          size: 12, color: NavAlertColors.accent),
                      Expanded(
                        child: Container(
                          width: 2,
                          margin: const EdgeInsets.symmetric(vertical: 3),
                          color: NavAlertColors.surface,
                        ),
                      ),
                      const Icon(Icons.location_on,
                          size: 14, color: NavAlertColors.warning),
                      const SizedBox(height: 18),
                    ]),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              vm.currentAddressShort ?? 'Current Location',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600)),
                          const Text('Your location',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: NavAlertColors.textSecondary)),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _controller,
                            autofocus: true,
                            style: const TextStyle(color: Colors.black87),
                            decoration: const InputDecoration(
                              hintText: 'Search destination…',
                              fillColor: Colors.white,
                              prefixIcon: Icon(Icons.search,
                                  color: Colors.black54),
                            ),
                            onChanged: _onChanged,
                            onSubmitted: (q) =>
                                context.read<HomeViewModel>().search(q),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // UC-4 step 2 — the commuter may pin the exact drop-off
            // point on the map instead of searching by name.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Card(
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.pin_drop,
                      color: NavAlertColors.accent),
                  title: const Text('Pin on the map',
                      style: TextStyle(fontSize: 14)),
                  subtitle: const Text(
                      'Drop a pin at your exact drop-off point.',
                      style: TextStyle(
                          fontSize: 11,
                          color: NavAlertColors.textSecondary)),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () async {
                    final picked = await Navigator.of(context)
                        .push<PlaceResult>(MaterialPageRoute(
                            builder: (_) => const PinOnMapView()));
                    if (picked != null && context.mounted) {
                      await _select(picked);
                    }
                  },
                ),
              ),
            ),
            if (vm.searching) const LinearProgressIndicator(),
            if (vm.searchError != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(vm.searchError!,
                    style: const TextStyle(color: NavAlertColors.warning)),
              ),
            Expanded(
              child: ListView.builder(
                itemCount: vm.results.length,
                itemBuilder: (_, i) {
                  final r = vm.results[i];
                  return ListTile(
                    leading: const CircleAvatar(
                      backgroundColor: NavAlertColors.surface,
                      child: Icon(Icons.navigation,
                          color: NavAlertColors.accent, size: 20),
                    ),
                    title: Text(r.name),
                    subtitle: Text(r.displayName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: NavAlertColors.textSecondary,
                            fontSize: 12)),
                    onTap: () => _select(r),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
