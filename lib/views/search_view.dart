import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../models/models.dart';
import '../viewmodels/app_viewmodel.dart';
import '../viewmodels/home_viewmodel.dart';
import 'route_view.dart';

/// Figure 20 — Destination Search Screen ("Where to?") using the
/// Nominatim API over OpenStreetMap.
///
/// When [pickForFavorite] is true (Figure 31 — Favorites ⊕) the selected
/// place is saved as a favorite instead of starting trip planning.
class SearchView extends StatefulWidget {
  const SearchView({super.key, this.pickForFavorite = false});
  final bool pickForFavorite;

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

    // Figure 31 — ⊕ Add Favorite: save the place and return.
    if (widget.pickForFavorite) {
      final messenger = ScaffoldMessenger.of(context);
      await app.addFavorite(
          place.name, place.displayName, place.lat, place.lng);
      messenger.showSnackBar(
          SnackBar(content: Text('${place.name} added to Favorites.')));
      if (mounted) Navigator.of(context).pop();
      return;
    }

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
      appBar: AppBar(
          title:
              Text(widget.pickForFavorite ? 'Add Favorite' : 'Where to?')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Column(children: [
                // Precise reverse-geocoded address of where the commuter
                // currently is (falls back to the generic label offline).
                Row(children: [
                  const Icon(Icons.circle,
                      size: 10, color: NavAlertColors.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(vm.currentAddress ?? 'Current Location',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: NavAlertColors.textSecondary,
                            fontSize: 12)),
                  ),
                ]),
                const SizedBox(height: 10),
                TextField(
                  controller: _controller,
                  autofocus: true,
                  style: const TextStyle(color: Colors.black87),
                  decoration: const InputDecoration(
                    hintText: 'Search destination…',
                    fillColor: Colors.white,
                    prefixIcon: Icon(Icons.search, color: Colors.black54),
                  ),
                  onChanged: _onChanged,
                  onSubmitted: (q) => context.read<HomeViewModel>().search(q),
                ),
              ]),
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
