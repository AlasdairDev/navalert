import 'dart:math' show cos, sin, pi;

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
          content: Text('Could not plan a route from that favorite - '
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
    final confirmed = await showNavAlertConfirmDialog(
      context,
      title: 'Remove from Favorites?',
      message: '${f.name}\n\nThis place will be removed from your favorites. '
          'You can add it again anytime.',
      confirmLabel: 'Remove',
      destructive: true,
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
          const SnackBar(content: Text('Could not remove - storage is '
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
                  children: [
                    SizedBox(
                      height: 160,
                      width: 160,
                      child: Stack(
                        alignment: Alignment.center,
                        clipBehavior: Clip.none,
                        children: [
                          Container(
                            height: 140,
                            width: 140,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                center: Alignment(-0.3, -0.3),
                                colors: [
                                  NavAlertColors.accent,
                                  NavAlertColors.primary,
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(
                            height: 140,
                            width: 140,
                            child: CustomPaint(painter: _CompassPainter()),
                          ),
                          const Positioned(
                              top: 4,
                              right: 4,
                              child: Icon(Icons.star,
                                  size: 32, color: NavAlertColors.accent)),
                          const Positioned(
                              bottom: 22,
                              left: 2,
                              child: Icon(Icons.star,
                                  size: 12, color: NavAlertColors.accent)),
                          const Positioned(
                              top: 28,
                              left: 8,
                              child: Icon(Icons.star,
                                  size: 10, color: NavAlertColors.accent)),
                          const Positioned(
                              bottom: 6,
                              right: 28,
                              child: Icon(Icons.star,
                                  size: 14, color: NavAlertColors.accent)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
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

/// Compass rose for the empty-Favorites illustration: rim tick marks plus a
/// two-tone diamond needle, drawn directly rather than a stock Material icon
/// (those bake in their own ring/hash-mark styling that didn't match).
class _CompassPainter extends CustomPainter {
  const _CompassPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2;

    final tickPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.55)
      ..strokeWidth = 1.5;
    for (var i = 0; i < 16; i++) {
      final angle = (i * 2 * pi) / 16;
      final dir = Offset(cos(angle), sin(angle));
      final outer = center + dir * (radius - 4);
      final inner = center + dir * (radius - (i % 4 == 0 ? 16 : 9));
      canvas.drawLine(inner, outer, tickPaint);
    }

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(-pi / 4);
    final needleLen = radius * 0.72;
    final needleWidth = radius * 0.2;

    canvas.drawPath(
      Path()
        ..moveTo(0, -needleLen)
        ..lineTo(-needleWidth, 0)
        ..lineTo(needleWidth, 0)
        ..close(),
      Paint()..color = Colors.white.withValues(alpha: 0.9),
    );
    canvas.drawPath(
      Path()
        ..moveTo(0, needleLen)
        ..lineTo(-needleWidth, 0)
        ..lineTo(needleWidth, 0)
        ..close(),
      Paint()..color = NavAlertColors.background,
    );
    canvas.restore();

    canvas.drawCircle(center, radius * 0.07, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
