import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../models/models.dart';
import '../viewmodels/app_viewmodel.dart';
import '../viewmodels/home_viewmodel.dart';
import 'route_view.dart';
import 'search_view.dart';

/// Figure 31 — Favorites: saved destinations for one-tap trips, with the
/// ⊕ button to add a new favorite from search.
class FavoritesView extends StatelessWidget {
  const FavoritesView({super.key});

  Future<void> _startFromFavorite(BuildContext context, Favorite f) async {
    final home = context.read<HomeViewModel>();
    final app = context.read<AppViewModel>();
    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()));
    try {
      await home.refreshCurrentLocation();
      await home.setDestination(
          PlaceResult(
              name: f.name, displayName: f.address, lat: f.lat, lng: f.lng),
          app.transportPrefs);
    } finally {
      if (context.mounted) Navigator.of(context).pop();
    }
    if (!context.mounted) return;
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const RouteView()));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppViewModel>();
    final favs = app.favorites;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Favorites'),
        automaticallyImplyLeading: false,
        actions: [
          // Figure 31 — ⊕ add a favorite via place search (saves the
          // selected place instead of starting trip planning).
          IconButton(
            icon: const Icon(Icons.add_circle_outline,
                color: NavAlertColors.accent),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const SearchView(pickForFavorite: true))),
          ),
        ],
      ),
      body: favs.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(mainAxisSize: MainAxisSize.min, children: const [
                  Icon(Icons.explore, size: 96, color: NavAlertColors.primary),
                  SizedBox(height: 18),
                  Text('No favorites yet.',
                      style: TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w700)),
                  SizedBox(height: 6),
                  Text(
                    'Add favorites from the Home Screen by tapping the star on '
                    'a place. They\'ll show here and for one-tap trips.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: NavAlertColors.textSecondary,
                        fontStyle: FontStyle.italic,
                        fontSize: 13),
                  ),
                ]),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: favs.length,
              itemBuilder: (_, i) {
                final f = favs[i];
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.location_on,
                        color: NavAlertColors.accent),
                    title: Text(f.name),
                    subtitle: Text(f.address,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12,
                            color: NavAlertColors.textSecondary)),
                    trailing: IconButton(
                      icon: const Icon(Icons.star, color: Colors.amber),
                      onPressed: () => app.removeFavorite(f.favoriteId),
                    ),
                    onTap: () => _startFromFavorite(context, f),
                  ),
                );
              },
            ),
    );
  }
}
