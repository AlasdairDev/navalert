import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../models/models.dart';
import '../viewmodels/app_viewmodel.dart';
import '../viewmodels/home_viewmodel.dart';
import 'add_favorite_view.dart';
import 'route_view.dart';

/// Figure 31 — Favorites: saved destinations for one-tap trips, with the
/// ⊕ button to add a new favorite from search.
///
/// UI/UX MAP (see legend in core/theme.dart):
///  [NEED] ⊕ AppBar action → AddFavoriteView · list tile onTap →
///         _startFromFavorite (sets destination → RouteView) · star
///         onPressed → _confirmRemove (dialog before delete).
///  [EDIT] empty-state icon/copy, card/list-tile styling, star icon,
///         remove-dialog wording, spacing.
///  [WANT] reorder/drag favorites, custom labels/icons (Home/Work/School),
///         swipe-to-delete, map thumbnail per favorite.
class FavoritesView extends StatefulWidget {
  const FavoritesView({super.key});

  @override
  State<FavoritesView> createState() => _FavoritesViewState();
}

class _FavoritesViewState extends State<FavoritesView> {
  // DO NOT MODIFY LOGIC: in-flight guard. The modal loader below blocks further
  // taps, but its barrier only appears on the NEXT frame — two taps landing in
  // the same frame both got through, each re-acquiring GPS, writing its own
  // trip row and pushing its own RouteView.
  bool _starting = false;

  // DO NOT MODIFY LOGIC: one-tap trip from a saved place — refreshes GPS, sets
  // the destination, and triggers route planning. Keep the flow; the loading
  // spinner and any result screen are [EDIT].
  Future<void> _startFromFavorite(Favorite f) async {
    if (_starting) return;
    _starting = true;
    final home = context.read<HomeViewModel>();
    final app = context.read<AppViewModel>();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()));
    // DO NOT MODIFY LOGIC: a planning failure must SAY so. The exception used
    // to propagate straight out of this method — the loader closed and nothing
    // else happened, so tapping a favourite silently did nothing at all.
    var planned = true;
    try {
      await home.refreshCurrentLocation();
      await home.setDestination(
          PlaceResult(
              name: f.name, displayName: f.address, lat: f.lat, lng: f.lng),
          app.transportPrefs);
    } catch (_) {
      planned = false;
    } finally {
      if (mounted) navigator.pop(); // close loader
      _starting = false;
    }
    if (!mounted) return;
    if (!planned) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Could not plan a route from that favorite — '
              'please try again.')));
      return;
    }
    navigator.push(MaterialPageRoute(builder: (_) => const RouteView()));
  }

  /// Click-to-confirm removal: the favorite is only deleted after the
  /// user explicitly confirms in the dialog.
  Future<void> _confirmRemove(
      BuildContext context, AppViewModel app, Favorite f) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove from Favorites?'),
        content: Text(
          '${f.name}\n\nThis place will be removed from your favorites. '
          'You can add it again anytime.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove',
                style: TextStyle(
                    color: NavAlertColors.danger,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // A storage failure must report itself, not leave a button that appears
    // to do nothing (the success SnackBar below would never be reached).
    try {
      await app.removeFavorite(f.favoriteId);
      messenger.showSnackBar(
          SnackBar(content: Text('${f.name} removed from Favorites.')));
    } catch (_) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Could not remove — storage is '
              'unavailable.')));
    }
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
          // Figure 31 — ⊕ add a favorite via its own dedicated page,
          // fully separate from the Home destination search.
          IconButton(
            icon: const Icon(Icons.add_circle_outline,
                color: NavAlertColors.accent),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const AddFavoriteView())),
          ),
        ],
      ),
      body: favs.isEmpty
          // Figure 31 — the empty state is a single tall rounded panel filling
          // the body, not loose text on the background. Colour comes from the
          // existing `card` token so it matches every other surface.
          ? Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: NavAlertColors.card,
                  borderRadius: BorderRadius.circular(20),
                ),
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    Icon(Icons.explore, size: 120,
                        color: NavAlertColors.primary),
                    SizedBox(height: 24),
                    Text('No favorites yet.',
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w700)),
                    SizedBox(height: 8),
                    Text(
                      'Add favorites from the Home Screen by tapping the star '
                      'on a place. They\'ll show here and for one-tap trips.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: NavAlertColors.textSecondary,
                          fontStyle: FontStyle.italic,
                          fontSize: 13,
                          height: 1.4),
                    ),
                  ],
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: favs.length,
              itemBuilder: (_, i) {
                final f = favs[i];
                return Card(
                  child: ListTile(
                    // Figure 31 rows breathe more than a dense tile — the pin,
                    // the wrapped address and the star each get room.
                    contentPadding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                    leading: const Icon(Icons.location_on,
                        color: NavAlertColors.accent),
                    title: Text(f.name),
                    // The mockup wraps the full address over several lines
                    // rather than truncating it after two.
                    subtitle: Text(f.address,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12,
                            height: 1.35,
                            color: NavAlertColors.textSecondary)),
                    trailing: IconButton(
                      icon: const Icon(Icons.star, color: Colors.amber),
                      tooltip: 'Remove from Favorites',
                      onPressed: () => _confirmRemove(context, app, f),
                    ),
                    onTap: () => _startFromFavorite(f),
                  ),
                );
              },
            ),
    );
  }
}
